// SPDX-License-Identifier: GPL-2.0-only OR MIT
/*
 * gbr_layout (geforce-bar1-resize): lay out the 64-bit prefetchable windows and BARs below a PCIe
 * root port again, so a resized BAR fits behind PCIe switches.
 *
 * The kernel's own resize (resource1_resize) can only grow the window of the port directly above
 * the card: every window further up stays pinned by its other children, so behind a switch the
 * resize fails with ENOSPC. This module releases the whole prefetchable subtree of the root port
 * (children first), sizes it itself bottom-up by first-fit placement, allocates the root port's
 * window from the host bridge with allocate_resource(), claims every child window and BAR at its
 * planned offset, writes the BARs and bridge windows, verifies every resource against config space,
 * and restores the previous state if any step fails.
 *
 * Prior art for the technique: gu64's tools/server-161-bar1-layout in
 * https://github.com/84634E1A607A/gpu-unlock-4090-48g-64g-bar1, which releases, resizes and
 * reprograms the windows for one hard-coded machine. This module is an independent implementation
 * for any topology (planned sizes, refusal rules, dry run, rollback); its register encodings follow
 * the PCI-to-PCI Bridge Architecture and PCI Express Base specifications.
 *
 * All work happens in module_init. On success the caller removes the module with rmmod; on failure
 * init returns an error and nothing stays loaded.
 *
 * Config writes, only to functions below a target's root port: PCI_COMMAND of functions that own
 * a moving resource (memory decode off, on unbound endpoints bus mastering off too, the saved
 * word restored afterwards), the 64-bit memory BAR registers of moving BARs, the prefetchable
 * base/limit registers 0x24/0x28/0x2c of bridges whose window moves, and the BAR size field of
 * each target's ReBAR control register.
 */
#define pr_fmt(fmt) "gbr_layout: " fmt

#include <linux/bitfield.h>
#include <linux/delay.h>
#include <linux/kernel.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/slab.h>
#include <linux/sizes.h>
#include <linux/pm_runtime.h>
#include <linux/string.h>
#include <linux/vgaarb.h>
#ifdef CONFIG_X86
#include <asm/e820/api.h>
#endif

#define RL_VERSION	"0.2"	/* keep equal to PACKAGE_VERSION in dkms.conf */
#ifndef RL_SRC			/* Kbuild passes the first 12 hex of sha256(gbr_layout.c) */
#define RL_SRC		"unknown"
#endif

#define RL_MAX_TARGETS	32
#define RL_MAX_NODES	64
#define RL_MAX_ROOTS	4
#define RL_WIN		6	/* slot of the prefetchable window in rl_node.res[] */
#define RL_NRES		7	/* slots 0..5 are BAR0..5 */
#define RL_WIN_RESNO	PCI_BRIDGE_PREF_MEM_WINDOW

static char *targets;
module_param(targets, charp, 0400);
MODULE_PARM_DESC(targets, "comma-separated full BDFs (DDDD:BB:DD.F) to resize, at most 32");
static int bar = 1;
module_param(bar, int, 0400);
MODULE_PARM_DESC(bar, "BAR index to resize (default 1)");
static int size = -1;
module_param(size, int, 0400);
MODULE_PARM_DESC(size, "ReBAR size index, bytes = 1 MiB << size (required)");
static bool dry_run;
module_param(dry_run, bool, 0400);
MODULE_PARM_DESC(dry_run, "plan and log only; write nothing");

/* Steps in apply order; fail_at= names them (test builds only). */
enum rl_step { RL_SNAPSHOT, RL_QUIESCE, RL_BME, RL_RELEASE, RL_SIZE, RL_REBAR, RL_WINDOW, RL_BAR,
	       RL_PROGRAM, RL_VERIFY, RL_NSTEPS };

#ifdef GBR_LAYOUT_TEST
static const char * const rl_step_name[RL_NSTEPS] = {
	"snapshot", "quiesce", "bme", "release", "size", "rebar", "window", "bar", "program",
	"verify",
};

static char *fake;
module_param(fake, charp, 0400);
MODULE_PARM_DESC(fake, "TEST: <bdf>@<bar>:<bytes>[,...] fake target size for a 1b36 device");
static char *fail_at;
module_param(fail_at, charp, 0400);
MODULE_PARM_DESC(fail_at, "TEST: <step>[:<n>] fail the n-th operation of that step");
static bool fail_rollback;
module_param(fail_rollback, bool, 0400);
MODULE_PARM_DESC(fail_rollback, "TEST: make the rollback report a readback mismatch");
static unsigned int hold_ms;
module_param(hold_ms, uint, 0400);
MODULE_PARM_DESC(hold_ms, "TEST: sleep this long inside the locked region");
static char *test_claim;
module_param(test_claim, charp, 0400);
MODULE_PARM_DESC(test_claim, "TEST: <bdf>@<bar> insert a child resource into that BAR");
static bool check_saved;
module_param(check_saved, bool, 0400);
MODULE_PARM_DESC(check_saved, "TEST: after success compare saved_config_space with live config");

static int fail_step = -1, fail_nth = 1, fail_count;
static struct resource rl_claim = { .name = "gbr_layout_test", .flags = IORESOURCE_MEM };

static bool rl_inject(enum rl_step s)
{
	if (s != fail_step || ++fail_count != fail_nth)
		return false;
	pr_info("test fail_at %s:%d fired\n", rl_step_name[s], fail_nth);
	return true;
}

static void rl_test_fail_report(void)
{
	if (fail_step >= 0 && fail_count < fail_nth)
		pr_info("test fail_at %s:%d not-reached\n", rl_step_name[fail_step], fail_nth);
}
#else
static inline bool rl_inject(enum rl_step s) { return false; }
static inline void rl_test_fail_report(void) { }
#endif

struct rl_target {
	unsigned int dom, bus, devfn;
	int bar, idx;		/* idx: ReBAR size index, -1 for a fake target */
	u64 bytes;
	struct pci_dev *dev;
	int root;		/* index into rl_roots, -1 if none */
};

struct rl_res {
	bool mover, was_assigned;
	u64 start, end;		/* snapshot of the struct resource */
	unsigned long flags;
	struct resource *parent;
	u32 raw[2];		/* snapshot of the BAR register(s) */
	u64 size, align;	/* plan */
	u64 off;		/* plan: offset in the parent window */
	u64 pred;		/* plan: predicted CPU address */
};

struct rl_node {
	struct pci_dev *dev;
	int parent;		/* node whose secondary bus holds this function; -1 for the root */
	bool bridge, locked, quiesced;
	bool pm_ref;		/* holds a runtime-PM usage count (no suspend during the run) */
	u16 cmd;		/* snapshot of PCI_COMMAND */
	u32 pref[3];		/* snapshot of 0x24, 0x28, 0x2c */
	int target;		/* index into rl_tg, -1 if not a target */
	int rebar_pos;		/* ReBAR ctrl register offset, 0 if none */
	u32 rebar_ctrl;		/* snapshot of the ReBAR ctrl register */
	int first, nitems;	/* this window's children in rl_root.item[], in placement order */
	struct rl_res res[RL_NRES];
};

struct rl_item { u8 node, slot; };

struct rl_root {
	struct pci_dev *dev;
	int n;
	struct rl_node node[RL_MAX_NODES];	/* node 0 is the root port, then pre-order */
	struct rl_item item[RL_MAX_NODES * RL_NRES];
	int nitem;
	int err;		/* refusal errno, 0 if none */
	bool noop, planned, fits;
	struct resource *host;	/* host bridge window chosen by the fit simulation */
};

static struct rl_target rl_tg[RL_MAX_TARGETS];
static int rl_ntg;
static struct rl_root *rl_roots[RL_MAX_ROOTS];
static int rl_nroots;

static int rl_resno(int slot)
{
	return slot == RL_WIN ? RL_WIN_RESNO : slot;
}

static struct resource *rl_r(struct rl_node *nd, int slot)
{
	return &nd->dev->resource[rl_resno(slot)];
}

/* Most severe errno first; refusals and fit failures rank below real failures. */
static int rl_worse(int a, int b)
{
	static const int order[] = { -ENOTRECOVERABLE, -EIO, -ENOMEM, -EINVAL, -E2BIG, -EBUSY,
				     -ENOSPC };
	int i;

	for (i = 0; i < ARRAY_SIZE(order); i++)
		if (a == order[i] || b == order[i])
			return order[i];
	return a ? a : b;
}

static __printf(4, 5) void rl_refuse(struct rl_root *rt, struct pci_dev *dev, int err,
				     const char *fmt, ...)
{
	struct va_format vaf;
	va_list args;

	va_start(args, fmt);
	vaf.fmt = fmt;
	vaf.va = &args;
	pr_info("root %s %s %s %pV\n", pci_name(rt->dev), dry_run ? "would-refuse" : "refuse",
		pci_name(dev), &vaf);
	va_end(args);
	rt->err = rl_worse(rt->err, err);
}

/*
 * A window is present when it is a memory window that is not disabled. 7.0 keeps the flags of a
 * disabled window and sets IORESOURCE_DISABLED; 6.14 zeroes them.
 */
static bool rl_win_present(struct resource *r)
{
	return (r->flags & IORESOURCE_MEM) && !(r->flags & IORESOURCE_DISABLED);
}

static bool rl_pref64(struct resource *r)
{
	unsigned long want = IORESOURCE_MEM | IORESOURCE_PREFETCH | IORESOURCE_MEM_64;

	return (r->flags & want) == want;
}

/* pci_release_resource() returns void on 6.14 and int on 7.0 (Kbuild sets RL_RELEASE_INT). */
static int rl_release(struct pci_dev *dev, int resno)
{
#ifdef RL_RELEASE_INT
	return pci_release_resource(dev, resno);
#else
	pci_release_resource(dev, resno);
	return dev->resource[resno].parent ? -EBUSY : 0;
#endif
}

static void rl_label(char *buf, size_t len, int slot)
{
	if (slot == RL_WIN)
		strscpy(buf, "window", len);
	else
		snprintf(buf, len, "BAR%d", slot);
}

/* "DDDD:BB:DD.F", nothing else. */
static int rl_parse_bdf(const char *s, unsigned int *dom, unsigned int *bus, unsigned int *devfn)
{
	unsigned int d, b, sl, f;
	int n = 0;

	if (strlen(s) != 12 || sscanf(s, "%4x:%2x:%2x.%1x%n", &d, &b, &sl, &f, &n) != 4 ||
	    n != 12 || sl > 0x1f || f > 7)
		return -EINVAL;
	*dom = d;
	*bus = b;
	*devfn = PCI_DEVFN(sl, f);
	return 0;
}

static struct rl_target *rl_find_target(unsigned int dom, unsigned int bus, unsigned int devfn)
{
	int i;

	for (i = 0; i < rl_ntg; i++)
		if (rl_tg[i].dom == dom && rl_tg[i].bus == bus && rl_tg[i].devfn == devfn)
			return &rl_tg[i];
	return NULL;
}

static int rl_parse_targets(void)
{
	char *buf, *p, *tok;
	int ret = 0;

	if (!targets || !*targets) {
		pr_err("targets= is required\n");
		return -EINVAL;
	}
	buf = kstrdup(targets, GFP_KERNEL);
	if (!buf)
		return -ENOMEM;
	p = buf;
	while ((tok = strsep(&p, ",")) != NULL) {
		struct rl_target *t;
		unsigned int dom, b, devfn;

		if (!*tok)
			continue;
		if (rl_parse_bdf(tok, &dom, &b, &devfn)) {
			pr_err("bad target '%s' (want DDDD:BB:DD.F)\n", tok);
			ret = -EINVAL;
			break;
		}
		if (rl_find_target(dom, b, devfn))
			continue;
		if (rl_ntg == RL_MAX_TARGETS) {
			pr_err("more than %d targets\n", RL_MAX_TARGETS);
			ret = -EINVAL;
			break;
		}
		t = &rl_tg[rl_ntg++];
		t->dom = dom;
		t->bus = b;
		t->devfn = devfn;
		t->bar = bar;
		t->idx = size;
		t->bytes = (u64)SZ_1M << size;
		t->root = -1;
	}
	kfree(buf);
	if (!ret && !rl_ntg) {
		pr_err("targets= lists no device\n");
		ret = -EINVAL;
	}
	return ret;
}

#ifdef GBR_LAYOUT_TEST
/* "<bdf>@<bar>[:<rest>]": *rest points after the colon, or is NULL without one. */
static int rl_parse_bdf_bar(char *s, unsigned int *dom, unsigned int *b, unsigned int *devfn,
			    int *barno, char **rest)
{
	char *at = strchr(s, '@'), *colon;

	if (!at)
		return -EINVAL;
	*at = 0;
	colon = strchr(at + 1, ':');
	if (colon)
		*colon = 0;
	*rest = colon ? colon + 1 : NULL;
	if (rl_parse_bdf(s, dom, b, devfn) || kstrtoint(at + 1, 10, barno) || *barno < 0 ||
	    *barno > 5)
		return -EINVAL;
	return 0;
}

static int rl_parse_fail_at(void)
{
	char *colon;
	size_t len;
	int i;

	if (!fail_at || !*fail_at)
		return 0;
	colon = strchr(fail_at, ':');
	len = colon ? colon - fail_at : strlen(fail_at);
	for (i = 0; i < RL_NSTEPS; i++)
		if (strlen(rl_step_name[i]) == len && !strncmp(fail_at, rl_step_name[i], len))
			fail_step = i;
	if (fail_step < 0 || (colon && (kstrtoint(colon + 1, 10, &fail_nth) || fail_nth < 1))) {
		pr_err("bad fail_at '%s' (want <step>[:<n>])\n", fail_at);
		return -EINVAL;
	}
	return 0;
}

static int rl_parse_test(void)
{
	char *buf, *p, *tok, *rest, *end;
	unsigned int dom, b, devfn;
	int barno, ret;

	ret = rl_parse_fail_at();
	if (ret || !fake || !*fake)
		return ret;
	buf = kstrdup(fake, GFP_KERNEL);
	if (!buf)
		return -ENOMEM;
	p = buf;
	while (!ret && (tok = strsep(&p, ",")) != NULL) {
		struct rl_target *t;
		u64 bytes;

		if (!*tok)
			continue;
		if (rl_parse_bdf_bar(tok, &dom, &b, &devfn, &barno, &rest) || !rest) {
			ret = -EINVAL;
			break;
		}
		bytes = memparse(rest, &end);
		t = rl_find_target(dom, b, devfn);
		if (*end || !is_power_of_2(bytes) || bytes < SZ_1M || !t) {
			ret = -EINVAL;
			break;
		}
		t->bar = barno;
		t->bytes = bytes;
		t->idx = -1;
	}
	kfree(buf);
	if (ret)
		pr_err("bad fake '%s' (want <bdf>@<bar>:<bytes>, a power of two >= 1M, bdf in targets)\n",
		       fake);
	return ret;
}

static void rl_claim_insert(void)
{
	unsigned int dom, b, devfn;
	struct pci_dev *dev;
	struct resource *r;
	char *buf, *rest;
	int barno, bad;

	if (!test_claim || !*test_claim)
		return;
	buf = kstrdup(test_claim, GFP_KERNEL);
	bad = !buf || rl_parse_bdf_bar(buf, &dom, &b, &devfn, &barno, &rest) || rest;
	kfree(buf);
	if (bad) {
		pr_err("test: bad test_claim '%s' (want <bdf>@<bar>)\n", test_claim);
		return;
	}
	dev = pci_get_domain_bus_and_slot(dom, b, devfn);
	if (!dev) {
		pr_err("test: test_claim device absent\n");
		return;
	}
	r = &dev->resource[barno];
	rl_claim.start = r->start;
	rl_claim.end = min_t(u64, r->end, r->start + SZ_4K - 1);
	if (!r->parent || request_resource(r, &rl_claim))
		pr_err("test: could not insert the claim into %s BAR%d\n", pci_name(dev), barno);
	else
		pr_info("test: claim %s inserted into %s BAR%d\n", rl_claim.name, pci_name(dev),
			barno);
	pci_dev_put(dev);
}

static void rl_claim_remove(void)
{
	if (rl_claim.parent)
		release_resource(&rl_claim);
}
#else
static inline int rl_parse_test(void) { return 0; }
static inline void rl_claim_insert(void) { }
static inline void rl_claim_remove(void) { }
#endif

/* --- discovery and checks ------------------------------------------------------------------- */

static int rl_collect_cb(struct pci_dev *dev, void *data)
{
	struct rl_root *rt = data;
	struct rl_node *nd;
	int i;

	if (rt->n == RL_MAX_NODES) {
		rt->err = -E2BIG;
		return 1;
	}
	nd = &rt->node[rt->n];
	nd->dev = pci_dev_get(dev);
	nd->parent = -1;
	nd->target = -1;
	for (i = 0; i < rt->n; i++)
		if (rt->node[i].dev->subordinate == dev->bus)
			nd->parent = i;
	rt->n++;
	return 0;
}

/* The topmost bridge whose bus is a root bus; NULL for a function on a root bus. */
static struct pci_dev *rl_root_of(struct pci_dev *dev)
{
	struct pci_dev *b = dev->bus->self;

	if (pci_is_root_bus(dev->bus) || !b)
		return NULL;
	while (!pci_is_root_bus(b->bus) && b->bus->self)
		b = b->bus->self;
	return pci_is_root_bus(b->bus) ? b : NULL;
}

/*
 * Resizable BAR extended capability (PCI Express Base Specification): after the capability
 * header, one 8-byte entry per resizable BAR, a capability dword followed by a control dword. In
 * the control dword, bits 2:0 name the BAR and bits 13:8 hold its size; bits 7:5 of the first
 * entry's control dword give the number of entries (1 to 6). Returns the config offset of the
 * control dword for BAR @barno, or 0 when the function has no entry for it.
 */
static int rl_rebar_pos(struct pci_dev *dev, int barno)
{
	int base = pci_find_ext_capability(dev, PCI_EXT_CAP_ID_REBAR);
	int entries, e, ctl_off;
	u32 v;

	if (!base)
		return 0;
	pci_read_config_dword(dev, base + PCI_REBAR_CTRL, &v);
	if (PCI_POSSIBLE_ERROR(v))
		return 0;
	entries = min_t(int, FIELD_GET(PCI_REBAR_CTRL_NBAR_MASK, v), 6);
	for (e = 0; e < entries; e++) {
		ctl_off = base + PCI_REBAR_CTRL + e * 8;
		pci_read_config_dword(dev, ctl_off, &v);
		if (PCI_POSSIBLE_ERROR(v))
			return 0;
		if (FIELD_GET(PCI_REBAR_CTRL_BAR_IDX, v) == barno)
			return ctl_off;
	}
	return 0;
}

static bool rl_is_mover_window(struct rl_root *rt, struct resource *r)
{
	int i;

	for (i = 0; i < rt->n; i++)
		if (rt->node[i].res[RL_WIN].mover && rl_r(&rt->node[i], RL_WIN) == r)
			return true;
	return false;
}

static bool rl_is_mover(struct rl_root *rt, struct resource *r)
{
	int i, s;

	for (i = 0; i < rt->n; i++)
		for (s = 0; s < RL_NRES; s++)
			if (rt->node[i].res[s].mover && rl_r(&rt->node[i], s) == r)
				return true;
	return false;
}

static bool rl_owns_mover(struct rl_node *nd)
{
	int s;

	for (s = 0; s < RL_NRES; s++)
		if (nd->res[s].mover)
			return true;
	return false;
}

/* An endpoint that owns a moving resource and has bus mastering on (left by firmware). */
static bool rl_bme_cleared(struct rl_node *nd)
{
	return !nd->bridge && (nd->cmd & PCI_COMMAND_MASTER);
}

/*
 * PCI_COMMAND while the resources move: memory decode off; for endpoints bus mastering off too.
 * Bridges keep bus mastering (port services use it for MSI). The snapshot word comes back after.
 */
static u16 rl_quiet_cmd(struct rl_node *nd)
{
	return nd->cmd & ~(PCI_COMMAND_MEMORY | (nd->bridge ? 0 : PCI_COMMAND_MASTER));
}

/*
 * Movers, top-down: a window moves when it is assigned and sits in a moving window (the root
 * port's window sits in a host bridge window); a BAR moves when it sits in a moving window; a
 * target's BAR always moves.
 */
static void rl_classify(struct rl_root *rt)
{
	int i, s;

	for (i = 0; i < rt->n; i++) {
		struct rl_node *nd = &rt->node[i];
		struct pci_dev *dev = nd->dev;
		struct resource *w = &dev->resource[RL_WIN_RESNO];

		nd->bridge = !!dev->subordinate;
		if (nd->bridge && rl_win_present(w) && w->parent &&
		    (i == 0 || rl_is_mover_window(rt, w->parent)))
			nd->res[RL_WIN].mover = true;
		for (s = 0; s <= PCI_ROM_RESOURCE; s++) {
			struct resource *r = &dev->resource[s];

			if (!r->parent || !rl_is_mover_window(rt, r->parent))
				continue;
			if (s == PCI_ROM_RESOURCE)
				rl_refuse(rt, dev, -EBUSY,
					  "ROM %pR sits in a prefetchable window", r);
			else
				nd->res[s].mover = true;
		}
		if (nd->target >= 0)
			nd->res[rl_tg[nd->target].bar].mover = true;
	}
}

/* Snapshot one function and apply the per-function refusal rules. Reads only. */
static void rl_snapshot(struct rl_root *rt, struct rl_node *nd, struct pci_dev *vga)
{
	struct pci_dev *dev = nd->dev;
	int s;

	pci_read_config_word(dev, PCI_COMMAND, &nd->cmd);
	if (nd->bridge) {
		pci_read_config_dword(dev, PCI_PREF_MEMORY_BASE, &nd->pref[0]);
		pci_read_config_dword(dev, PCI_PREF_BASE_UPPER32, &nd->pref[1]);
		pci_read_config_dword(dev, PCI_PREF_LIMIT_UPPER32, &nd->pref[2]);
	}
	/*
	 * Refuse a function the hardware says is in D1..D3hot. current_state is not used: the
	 * PCI core leaves it at PCI_UNKNOWN after a driver unbinds, and for functions without a
	 * PM capability. A powered-down, unplugged or link-down function reads all ones: never
	 * restore that.
	 */
	if (dev->pm_cap) {
		u16 pmcsr;

		pci_read_config_word(dev, dev->pm_cap + PCI_PM_CTRL, &pmcsr);
		if (!PCI_POSSIBLE_ERROR(pmcsr) && (pmcsr & PCI_PM_CTRL_STATE_MASK))
			rl_refuse(rt, dev, -EBUSY, "is in D%d (PM control 0x%04x)",
				  pmcsr & PCI_PM_CTRL_STATE_MASK, pmcsr);
	}
	if (PCI_POSSIBLE_ERROR(nd->cmd) || (nd->bridge && PCI_POSSIBLE_ERROR(nd->pref[0])))
		rl_refuse(rt, dev, -EBUSY, "config space reads all ones (powered down or gone)");
	if (dev == vga)
		rl_refuse(rt, dev, -EBUSY, "is the boot VGA device");
	if (dev->is_physfn || dev->is_virtfn)
		rl_refuse(rt, dev, -EBUSY, "has SR-IOV");
	if (dev->hdr_type == PCI_HEADER_TYPE_CARDBUS)
		rl_refuse(rt, dev, -EBUSY, "is a CardBus bridge");
	/* dev.driver is stable only under the device lock; unlocked functions are refused. */
	if (!nd->bridge && nd->locked && dev->dev.driver)
		rl_refuse(rt, dev, -EBUSY, "bound to %s", dev->dev.driver->name);

	for (s = 0; s < RL_NRES; s++) {
		struct rl_res *rr = &nd->res[s];
		struct resource *r = rl_r(nd, s), *c;
		char lbl[8];

		if (!rr->mover)
			continue;
		rl_label(lbl, sizeof(lbl), s);
		rr->start = r->start;
		rr->end = r->end;
		rr->flags = r->flags;
		rr->parent = r->parent;
		rr->was_assigned = !!r->parent;
		if (s != RL_WIN) {
			int reg = PCI_BASE_ADDRESS_0 + 4 * s;

			pci_read_config_dword(dev, reg, &rr->raw[0]);
			if (r->flags & IORESOURCE_MEM_64)
				pci_read_config_dword(dev, reg + 4, &rr->raw[1]);
		}
		if (!rl_pref64(r) || (r->flags & IORESOURCE_PCI_FIXED) ||
		    (s != RL_WIN && !(r->flags & IORESOURCE_SIZEALIGN)))
			rl_refuse(rt, dev, -EBUSY,
				  "%s %pR is not a movable 64-bit prefetchable resource", lbl, r);
		for (c = r->child; c; c = c->sibling) {
			if (rl_is_mover(rt, c))
				continue;
			rl_refuse(rt, dev, -EBUSY, "%s %pR has a foreign child", lbl, r);
			pr_info("root %s   child %s %pR\n", pci_name(rt->dev),
				c->name ? c->name : "?", c);
		}
	}
	/*
	 * Firmware (OVMF, option ROMs) leaves bus mastering on in unbound endpoints. That is safe
	 * to clear for the move and restore afterwards; with a driver bound it is not (a bound
	 * function is refused anyway, above).
	 */
	if (!nd->bridge && rl_owns_mover(nd) && (nd->cmd & PCI_COMMAND_MASTER) && nd->locked &&
	    dev->dev.driver)
		rl_refuse(rt, dev, -EBUSY, "has bus mastering enabled and is bound to %s",
			  dev->dev.driver->name);
}

/* Target rules: endpoint, path windows, ReBAR entry and size (or a test fake). */
static void rl_check_target(struct rl_root *rt, struct rl_node *nd)
{
	struct rl_target *t = &rl_tg[nd->target];
	u64 sizes;
	int p;

	if (nd->bridge) {
		rl_refuse(rt, nd->dev, -EINVAL, "is a bridge, not an endpoint");
		return;
	}
	for (p = nd->parent; p >= 0; p = rt->node[p].parent) {
		struct rl_node *b = &rt->node[p];

		if (!b->dev->pref_64_window || !b->res[RL_WIN].mover)
			rl_refuse(rt, b->dev, -EBUSY, "has no assigned 64-bit prefetchable window");
	}
	if (t->idx < 0) {
#ifdef GBR_LAYOUT_TEST
		if (nd->dev->vendor != PCI_VENDOR_ID_REDHAT ||
		    pci_find_ext_capability(nd->dev, PCI_EXT_CAP_ID_REBAR))
			rl_refuse(rt, nd->dev, -EINVAL,
				  "fake= only applies to 1b36 devices without ReBAR");
		else
			pr_info("test: fake target %s BAR%d 0x%llx\n", pci_name(nd->dev), t->bar,
				t->bytes);
#endif
		return;
	}
	nd->rebar_pos = rl_rebar_pos(nd->dev, t->bar);
	if (!nd->rebar_pos) {
		rl_refuse(rt, nd->dev, -EINVAL, "has no ReBAR entry for BAR%d", t->bar);
		return;
	}
	pci_read_config_dword(nd->dev, nd->rebar_pos, &nd->rebar_ctrl);
	sizes = pci_rebar_get_possible_sizes(nd->dev, t->bar);
	if (!(sizes & BIT_ULL(t->idx)))
		rl_refuse(rt, nd->dev, -EINVAL,
			  "ReBAR offers sizes 0x%llx for BAR%d, not %d (capability not widened?)",
			  sizes, t->bar, t->idx);
}

/*
 * Lock (parents first), pin (runtime PM), classify, snapshot, apply the refusal rules. The
 * usage count blocks any new runtime suspend, so a resume cannot restore the probe-time windows in
 * the middle of the move; it is dropped after the unlock. No driver callback runs under the rescan
 * lock: only an unbound function whose parent is active is resumed, which runs the PCI core's own
 * runtime resume and nothing of a driver. A bound function or bridge that is not runtime-active
 * (suspended, or a suspend already in flight) is refused. Otherwise reads only.
 */
static void rl_check(struct rl_root *rt)
{
	struct pci_host_bridge *host = pci_find_host_bridge(rt->dev->bus);
	struct pci_dev *vga = vga_default_device();
	int i;

	for (i = 0; i < rt->n; i++) {
		struct rl_node *nd = &rt->node[i];

		nd->locked = pci_dev_trylock(nd->dev);
		if (!nd->locked)
			rl_refuse(rt, nd->dev, -EBUSY,
				  "is locked (driver probe, reset or config access in progress)");
	}
	for (i = 0; i < rt->n; i++) {
		struct rl_node *nd = &rt->node[i];
		struct device *d = &nd->dev->dev;

		/* dev.driver is stable under the device lock; the parent is pinned already */
		if (nd->locked && !nd->dev->subordinate && !d->driver && nd->parent >= 0 &&
		    pm_runtime_active(&rt->node[nd->parent].dev->dev)) {
			nd->pm_ref = pm_runtime_resume_and_get(d) >= 0;
		} else {
			pm_runtime_get_noresume(d);
			nd->pm_ref = true;
		}
		if (!nd->pm_ref || !pm_runtime_active(d))
			rl_refuse(rt, nd->dev, -EBUSY, "is runtime-suspended (or suspending)");
	}
	if (host && host->preserve_config)
		rl_refuse(rt, rt->dev, -EBUSY, "host bridge preserves the firmware configuration");
	rl_classify(rt);
	for (i = 0; i < rt->n; i++)
		rl_snapshot(rt, &rt->node[i], vga);
	for (i = 0; i < rt->n; i++)
		if (rt->node[i].target >= 0)
			rl_check_target(rt, &rt->node[i]);
}

/* Every target already has its size and an assigned BAR: nothing to do for this root. */
static bool rl_noop(struct rl_root *rt)
{
	int i;

	for (i = 0; i < rt->n; i++) {
		struct rl_node *nd = &rt->node[i];
		struct rl_target *t;
		struct resource *r;
		u32 cur;

		if (nd->target < 0)
			continue;
		t = &rl_tg[nd->target];
		r = &nd->dev->resource[t->bar];
		if (!r->parent || resource_size(r) != t->bytes)
			return false;
		cur = (nd->rebar_ctrl & PCI_REBAR_CTRL_BAR_SIZE) >> PCI_REBAR_CTRL_BAR_SHIFT;
		if (t->idx >= 0 && (!nd->rebar_pos || cur != t->idx))
			return false;
	}
	return true;
}

/* --- sizing, bottom-up ------------------------------------------------------------------------ */

struct rl_iv { u64 start, end; };

/*
 * Lowest start >= lo, aligned to @align, with [start, start + sz - 1] inside [lo, hi] and clear of
 * the sorted, disjoint intervals: the rule __find_resource_space() applies to a parent's children.
 */
static bool rl_first_fit(const struct rl_iv *iv, int n, u64 lo, u64 hi, u64 sz, u64 align,
			 u64 *out)
{
	u64 start = lo;
	int i;

	for (i = 0; i <= n; i++) {
		u64 gend = hi, a;

		if (i < n) {
			if (iv[i].end < start)
				continue;
			if (iv[i].start > start) {
				gend = min(hi, iv[i].start - 1);
			} else {
				start = iv[i].end + 1;
				if (!start || start > hi)
					return false;
				continue;
			}
		}
		a = ALIGN(start, align);
		if (a >= start && a <= gend && gend - a >= sz - 1) {
			*out = a;
			return true;
		}
		if (i < n) {
			start = iv[i].end + 1;
			if (!start || start > hi)
				return false;
		}
	}
	return false;
}

static void rl_iv_insert(struct rl_iv *iv, int *n, u64 start, u64 end)
{
	int i = *n;

	while (i > 0 && iv[i - 1].start > start) {
		iv[i] = iv[i - 1];
		i--;
	}
	iv[i].start = start;
	iv[i].end = end;
	(*n)++;
}

static int rl_bdf_cmp(struct pci_dev *a, struct pci_dev *b)
{
	if (pci_domain_nr(a->bus) != pci_domain_nr(b->bus))
		return pci_domain_nr(a->bus) < pci_domain_nr(b->bus) ? -1 : 1;
	if (a->bus->number != b->bus->number)
		return a->bus->number < b->bus->number ? -1 : 1;
	if (a->devfn != b->devfn)
		return a->devfn < b->devfn ? -1 : 1;
	return 0;
}

/* Placement order: alignment descending, size descending, BDF, resource index. */
static bool rl_item_before(struct rl_root *rt, struct rl_item a, struct rl_item b)
{
	struct rl_res *ra = &rt->node[a.node].res[a.slot];
	struct rl_res *rb = &rt->node[b.node].res[b.slot];
	int c;

	if (ra->align != rb->align)
		return ra->align > rb->align;
	if (ra->size != rb->size)
		return ra->size > rb->size;
	c = rl_bdf_cmp(rt->node[a.node].dev, rt->node[b.node].dev);
	if (c)
		return c < 0;
	return rl_resno(a.slot) < rl_resno(b.slot);
}

/* Collect window @i's children into rt->item[] in placement order. */
static void rl_collect_items(struct rl_root *rt, int i)
{
	struct rl_node *nd = &rt->node[i];
	int j, s, k;

	nd->first = rt->nitem;
	for (j = i + 1; j < rt->n; j++) {
		if (rt->node[j].parent != i)
			continue;
		for (s = 0; s < RL_NRES; s++) {
			struct rl_item it = { .node = j, .slot = s };

			if (!rt->node[j].res[s].mover)
				continue;
			k = rt->nitem++;
			while (k > nd->first && rl_item_before(rt, it, rt->item[k - 1])) {
				rt->item[k] = rt->item[k - 1];
				k--;
			}
			rt->item[k] = it;
		}
	}
	nd->nitems = rt->nitem - nd->first;
}

/*
 * Bottom-up: place each window's children by first fit in placement order; the window is the
 * highest end rounded up to 1 MiB, aligned to its largest child alignment. The apply claims every
 * child at exactly its planned offset, so the window always holds them.
 */
static int rl_plan(struct rl_root *rt)
{
	struct rl_iv *iv;
	int i, s, k;

	iv = kmalloc_array(RL_MAX_NODES * RL_NRES, sizeof(*iv), GFP_KERNEL);
	if (!iv)
		return -ENOMEM;
	for (i = 0; i < rt->n; i++)
		for (s = 0; s < RL_WIN; s++) {
			struct rl_node *nd = &rt->node[i];
			struct rl_res *rr = &nd->res[s];

			if (!rr->mover)
				continue;
			if (nd->target >= 0 && rl_tg[nd->target].bar == s)
				rr->size = rl_tg[nd->target].bytes;
			else
				rr->size = rr->end - rr->start + 1;
			rr->align = rr->size;
		}
	rt->nitem = 0;
	for (i = rt->n - 1; i >= 0; i--) {
		struct rl_node *nd = &rt->node[i];
		struct rl_res *w = &nd->res[RL_WIN];
		u64 top = 0, align = SZ_1M;
		int niv = 0;

		if (!w->mover)
			continue;
		rl_collect_items(rt, i);
		for (k = nd->first; k < nd->first + nd->nitems; k++) {
			struct rl_res *c = &rt->node[rt->item[k].node].res[rt->item[k].slot];

			if (!rl_first_fit(iv, niv, 0, U64_MAX, c->size, c->align, &c->off)) {
				kfree(iv);
				return -EOVERFLOW;
			}
			rl_iv_insert(iv, &niv, c->off, c->off + c->size - 1);
			top = max(top, c->off + c->size);
			align = max(align, c->align);
		}
		if (nd->nitems) {
			w->size = ALIGN(top, SZ_1M);
			w->align = align;
		} else {
			/* Empty port with an assigned window (hotplug reservation): same size. */
			w->size = w->end - w->start + 1;
			w->align = SZ_1M;
		}
	}
	kfree(iv);
	rt->planned = rt->node[0].res[RL_WIN].mover;
	return 0;
}

static void rl_predict(struct rl_root *rt, int i, u64 base)
{
	struct rl_node *nd = &rt->node[i];
	int k;

	nd->res[RL_WIN].pred = base;
	for (k = nd->first; k < nd->first + nd->nitems; k++) {
		struct rl_item it = rt->item[k];
		struct rl_res *c = &rt->node[it.node].res[it.slot];

		c->pred = base + c->off;
		if (it.slot == RL_WIN)
			rl_predict(rt, it.node, c->pred);
	}
}

/* --- fit against the host bridge -------------------------------------------------------------- */

static bool rl_applies(struct rl_root *rt)
{
	return rt->planned && !rt->noop && rt->fits && (dry_run || !rt->err);
}

/*
 * Does [start, start + size) touch an e820 entry or the BIOS ROM range? x86's allocator never
 * places a window there (arch_remove_reservations() trims both out of every gap it considers), so
 * the fit must not either. Conservative: it does not know whether pci_use_e820 is set.
 */
static bool rl_e820_hit(u64 start, u64 size)
{
#ifdef CONFIG_X86
	return e820__mapped_any(start, start + size, 0) ||
	       (start <= BIOS_ROM_END && start + size > BIOS_ROM_BASE);
#else
	return false;
#endif
}

#define RL_FIT_TRIES	16	/* candidates skipped for touching an e820 range */
#define RL_FIT_GAPS	512	/* free gaps of one host bridge window */
#define RL_FIT_FREE	(RL_FIT_GAPS + RL_MAX_ROOTS)	/* gaps, released root windows */
#define RL_FIT_IV	(RL_FIT_FREE + 1 + RL_MAX_ROOTS + RL_FIT_TRIES)	/* + earlier roots, skips */

struct rl_gaps {
	struct rl_iv *iv;
	int n;
	bool overflow;
};

/*
 * alignf for allocate_resource(): called under resource_lock for every free gap of the parent in
 * address order, after arch_remove_reservations(). It records the gap and declines it ([end,
 * end + 1] never fits in it), so nothing is allocated and the children are never touched unlocked.
 */
#ifdef RL_ALIGNF_EMPTY_RES
static resource_size_t rl_gap_cb(void *data, const struct resource *avail,
				 const struct resource *empty_res, resource_size_t size,
				 resource_size_t align)
#else
static resource_size_t rl_gap_cb(void *data, const struct resource *avail, resource_size_t size,
				 resource_size_t align)
#endif
{
	struct rl_gaps *g = data;

	if (avail->start <= avail->end) {
		if (g->n < RL_FIT_GAPS) {
			g->iv[g->n].start = avail->start;
			g->iv[g->n].end = avail->end;
			g->n++;
		} else {
			g->overflow = true;
		}
	}
	return avail->end;
}

/*
 * Try root @k's window in host bridge window @r, clipped to bus region @reg. The roots before k
 * are already applied: their old windows are released and their new windows placed. k's own old
 * window is released. Every other child of @r stays where it is. The free gaps of @r are read
 * under resource_lock (through allocate_resource() with rl_gap_cb); more gaps than fit counts as
 * no fit. A candidate that touches an e820 range is skipped, as arch_remove_reservations() does.
 */
static int rl_fit_window(int k, struct resource *r, struct pci_bus_region *reg)
{
	struct rl_root *rt = rl_roots[k];
	struct rl_res *w = &rt->node[0].res[RL_WIN];
	struct pci_bus *bus = rt->dev->bus;
	struct resource avail = *r, probe = { .name = "gbr_layout probe", .flags = r->flags };
	struct pci_bus_region br;
	struct rl_gaps g = { };
	struct rl_iv *fr, *iv;
	int j, t, nfr, niv = 0, ret = 0;
	u64 lo, cur;

	pcibios_resource_to_bus(bus, &br, &avail);
	br.start = max(br.start, reg->start);
	br.end = min(br.end, reg->end);
	if (br.end < br.start)
		return 0;
	pcibios_bus_to_resource(bus, &avail, &br);
	lo = avail.start ? avail.start : PCIBIOS_MIN_MEM;
	if (lo > avail.end)
		return 0;

	fr = kmalloc_array(RL_FIT_FREE + RL_FIT_IV, sizeof(*fr), GFP_KERNEL);
	if (!fr)
		return -ENOMEM;
	iv = fr + RL_FIT_FREE;
	g.iv = fr;
	if (!allocate_resource(r, &probe, 2, lo, avail.end, 1, rl_gap_cb, &g)) {
		release_resource(&probe);	/* rl_gap_cb declines every gap; never reached */
		goto out;
	}
	if (g.overflow) {
		pr_info("root %s: %pR has too many children to simulate\n", pci_name(rt->dev), r);
		pr_info("root %s: treated as no fit\n", pci_name(rt->dev));
		goto out;
	}
	/* free space: the gaps plus the windows of k and the earlier roots, which are released */
	nfr = g.n;
	for (j = 0; j <= k; j++) {
		struct resource *ow = rl_r(&rl_roots[j]->node[0], RL_WIN);

		if ((j == k || rl_applies(rl_roots[j])) && ow->parent == r)
			rl_iv_insert(fr, &nfr, ow->start, ow->end);
	}
	/* occupied: everything else in [lo, avail.end], then the earlier roots' new windows */
	cur = lo;
	for (j = 0; j < nfr && cur <= avail.end; j++) {
		if (fr[j].end < cur)
			continue;
		if (fr[j].start > cur)
			rl_iv_insert(iv, &niv, cur, min(fr[j].start - 1, avail.end));
		if (fr[j].end >= avail.end)
			break;
		cur = fr[j].end + 1;
	}
	if (j == nfr && cur <= avail.end)
		rl_iv_insert(iv, &niv, cur, avail.end);
	for (j = 0; j < k; j++) {
		struct rl_res *ow = &rl_roots[j]->node[0].res[RL_WIN];

		if (rl_applies(rl_roots[j]) && rl_roots[j]->host == r)
			rl_iv_insert(iv, &niv, ow->pred, ow->pred + ow->size - 1);
	}
	for (t = 0; t < RL_FIT_TRIES; t++) {
		if (!rl_first_fit(iv, niv, lo, avail.end, w->size, w->align, &w->pred))
			goto out;
		if (!rl_e820_hit(w->pred, w->size))
			break;
		pr_info("root %s: candidate 0x%llx-0x%llx touches an e820 range; skipped\n",
			pci_name(rt->dev), w->pred, w->pred + w->size - 1);
		rl_iv_insert(iv, &niv, w->pred, w->pred + w->size - 1);
	}
	if (t == RL_FIT_TRIES)
		goto out;
	rt->host = r;
	ret = 1;
out:
	kfree(fr);
	return ret;
}

/*
 * Choose the host bridge window for root @k's window, in pci_assign_resource()'s order: type masks
 * outermost, then bus addresses >= 4 GiB before any 64-bit address, then the root bus windows in
 * order. The gaps are read under resource_lock; the tree can still change before the apply, which
 * then fails the pinned allocation and rolls back.
 */
static int rl_fit(int k)
{
	static const unsigned long masks[] = { IORESOURCE_PREFETCH | IORESOURCE_MEM_64,
					       IORESOURCE_PREFETCH, 0 };
	struct pci_bus_region regions[] = { { 0x100000000ULL, U64_MAX }, { 0, U64_MAX } };
	struct rl_root *rt = rl_roots[k];
	unsigned long flags = rt->node[0].res[RL_WIN].flags;
	int m, g, i, ret;

	for (m = 0; m < ARRAY_SIZE(masks); m++)
		for (g = 0; g < ARRAY_SIZE(regions); g++) {
			struct resource *r;

			/* pci_bus_for_each_resource() takes (bus, res, i) on 6.1 and
			 * (bus, res[, i]) on 6.14 and later; this is its body, for both.
			 */
			for (i = 0; (r = pci_bus_resource_n(rt->dev->bus, i)) ||
			     i < PCI_BRIDGE_RESOURCE_NUM; i++) {
				if (!r || (r->flags & (IORESOURCE_UNSET | IORESOURCE_DISABLED)) ||
				    ((flags ^ r->flags) & (masks[m] | IORESOURCE_TYPE_BITS)))
					continue;
				ret = rl_fit_window(k, r, &regions[g]);
				if (ret)
					return ret;
			}
		}
	return 0;
}

/* --- logging ---------------------------------------------------------------------------------- */

static void rl_log_win(struct rl_root *rt, int i, int indent)
{
	struct rl_node *nd = &rt->node[i];
	int k;

	for (k = nd->first; k < nd->first + nd->nitems; k++) {
		struct rl_item it = rt->item[k];
		struct rl_node *c = &rt->node[it.node];
		struct rl_res *cr = &c->res[it.slot];

		if (it.slot == RL_WIN) {
			pr_info("%*s%s window 0x%llx +0x%llx\n", indent, "", pci_name(c->dev),
				cr->size, cr->off);
			rl_log_win(rt, it.node, indent + 2);
		} else if (c->target >= 0 && rl_tg[c->target].bar == it.slot) {
			pr_info("%*s%s BAR%d 0x%llx target (was 0x%llx) +0x%llx\n", indent, "",
				pci_name(c->dev), it.slot, cr->size, cr->end - cr->start + 1,
				cr->off);
		} else {
			pr_info("%*s%s BAR%d 0x%llx +0x%llx\n", indent, "", pci_name(c->dev),
				it.slot, cr->size, cr->off);
		}
	}
}

/* The register writes an apply would make, from the predicted addresses (dry run only). */
static void rl_log_writes(struct rl_root *rt)
{
	int i, s;

	for (i = 0; i < rt->n; i++) {
		struct rl_node *nd = &rt->node[i];
		struct pci_dev *dev = nd->dev;

		if (rl_owns_mover(nd))
			pr_info("  write %s command 0x%04x during the move, then 0x%04x\n",
				pci_name(dev), rl_quiet_cmd(nd), nd->cmd);
		if (nd->target >= 0 && nd->rebar_pos)
			pr_info("  write %s 0x%03x 0x%08x (ReBAR ctrl, was 0x%08x)\n",
				pci_name(dev), nd->rebar_pos,
				(nd->rebar_ctrl & ~PCI_REBAR_CTRL_BAR_SIZE) |
				(rl_tg[nd->target].idx << PCI_REBAR_CTRL_BAR_SHIFT),
				nd->rebar_ctrl);
		for (s = 0; s < RL_NRES; s++) {
			struct rl_res *rr = &nd->res[s];
			struct resource tmp = { .flags = rr->flags };
			struct pci_bus_region br;
			int reg = PCI_BASE_ADDRESS_0 + 4 * s;

			if (!rr->mover)
				continue;
			tmp.start = rr->pred;
			tmp.end = rr->pred + rr->size - 1;
			pcibios_resource_to_bus(dev->bus, &br, &tmp);
			if (s == RL_WIN) {
				u32 l = ((br.start >> 16) & 0xfff0) | (br.end & 0xfff00000);

				pr_info("  write %s 0x24 0x%08x 0x28 0x%08x 0x2c 0x%08x (window)\n",
					pci_name(dev), l, upper_32_bits(br.start),
					upper_32_bits(br.end));
			} else {
				u32 lo = br.start | (rr->flags & ~PCI_BASE_ADDRESS_MEM_MASK);

				pr_info("  write %s 0x%02x 0x%08x 0x%02x 0x%08x (BAR%d)\n",
					pci_name(dev), reg, lo, reg + 4, upper_32_bits(br.start),
					s);
			}
		}
	}
}

static void rl_log_plan(struct rl_root *rt)
{
	struct rl_res *w = &rt->node[0].res[RL_WIN];

	if (rt->fits)
		pr_info("root %s window 0x%llx align 0x%llx predicted 0x%llx\n", pci_name(rt->dev),
			w->size, w->align, w->pred);
	else
		pr_info("root %s window 0x%llx align 0x%llx predicted none\n", pci_name(rt->dev),
			w->size, w->align);
	rl_log_win(rt, 0, 2);
}

static void rl_result(struct rl_root *rt, const char *what)
{
	pr_info("root %s result %s\n", pci_name(rt->dev), what);
}

/* --- apply, verify, rollback ------------------------------------------------------------------ */

/*
 * Prefetchable window registers of a type 1 header (PCI-to-PCI Bridge Architecture
 * Specification): the Prefetchable Memory Base (0x24) and Limit (0x26) words carry address bits
 * 31:20 in their bits 15:4 (the limit's low 20 bits read as ones), and the Upper 32 Bits registers
 * at 0x28/0x2c carry bits 63:32. reg[] holds the dwords at 0x24, 0x28 and 0x2c.
 */
#define RL_PREF_ADDR	GENMASK(15, 4)

static void rl_pref_encode(u64 base, u64 limit, u32 reg[3])
{
	reg[0] = FIELD_PREP(RL_PREF_ADDR, lower_32_bits(base) >> 20) |
		 FIELD_PREP(RL_PREF_ADDR, lower_32_bits(limit) >> 20) << 16;
	reg[1] = upper_32_bits(base);
	reg[2] = upper_32_bits(limit);
}

static void rl_pref_decode(const u32 reg[3], u64 *base, u64 *limit)
{
	*base = (u64)reg[1] << 32 | (u64)FIELD_GET(RL_PREF_ADDR, reg[0]) << 20;
	*limit = (u64)reg[2] << 32 | (u64)FIELD_GET(RL_PREF_ADDR, reg[0] >> 16) << 20 | (SZ_1M - 1);
}

/*
 * The three dwords cannot change at once. The upper limit goes to 0 before anything else, so while
 * the old and the new window both lie above 4 GiB the limit stays below the base until the final
 * write: the bridge forwards nothing in between, never a range mixed from old and new halves.
 */
static void rl_write_window(struct pci_dev *dev, const u32 reg[3])
{
	static const int off[] = { PCI_PREF_LIMIT_UPPER32, PCI_PREF_MEMORY_BASE,
				   PCI_PREF_BASE_UPPER32, PCI_PREF_LIMIT_UPPER32 };
	const u32 val[] = { 0, reg[0], reg[1], reg[2] };
	int i;

	for (i = 0; i < ARRAY_SIZE(off); i++)
		pci_write_config_dword(dev, off[i], val[i]);
}

static void rl_program_window(struct pci_dev *dev)
{
	struct pci_bus_region br;
	u32 reg[3];

	pcibios_resource_to_bus(dev->bus, &br, &dev->resource[RL_WIN_RESNO]);
	rl_pref_encode(br.start, br.end, reg);
	rl_write_window(dev, reg);
}

static bool rl_is_bus_resource(struct pci_bus *bus, struct resource *p)
{
	struct resource *r;
	int i;

	for (i = 0; (r = pci_bus_resource_n(bus, i)) || i < PCI_BRIDGE_RESOURCE_NUM; i++)
		if (r == p)
			return true;
	return false;
}

/* Config readback of a moved window or BAR, as a bus address range. */
static void rl_read_hw(struct pci_dev *dev, int s, u64 *start, u64 *end)
{
	u32 a, b, reg[3];

	if (s == RL_WIN) {
		pci_read_config_dword(dev, PCI_PREF_MEMORY_BASE, &reg[0]);
		pci_read_config_dword(dev, PCI_PREF_BASE_UPPER32, &reg[1]);
		pci_read_config_dword(dev, PCI_PREF_LIMIT_UPPER32, &reg[2]);
		rl_pref_decode(reg, start, end);
	} else {
		pci_read_config_dword(dev, PCI_BASE_ADDRESS_0 + 4 * s, &a);
		pci_read_config_dword(dev, PCI_BASE_ADDRESS_0 + 4 * s + 4, &b);
		*start = ((u64)b << 32) | (a & PCI_BASE_ADDRESS_MEM_MASK);
	}
}

/* Every moved resource: assigned, in the planned parent, planned size and alignment, and config
 * space decodes exactly the resource. Every target's ReBAR ctrl holds the target size.
 */
static int rl_verify(struct rl_root *rt)
{
	int i, s, bad = 0;

	for (i = 0; i < rt->n; i++) {
		struct rl_node *nd = &rt->node[i];
		struct pci_dev *dev = nd->dev;

		for (s = 0; s < RL_NRES; s++) {
			struct rl_res *rr = &nd->res[s];
			struct resource *r = rl_r(nd, s);
			struct pci_bus_region br;
			u64 hw_start, hw_end;
			bool parent_ok;
			char lbl[8];

			if (!rr->mover)
				continue;
			rl_label(lbl, sizeof(lbl), s);
			if (i == 0)
				parent_ok = r->parent && rl_is_bus_resource(dev->bus, r->parent);
			else
				parent_ok = r->parent == rl_r(&rt->node[nd->parent], RL_WIN);
			if (!parent_ok || resource_size(r) != rr->size ||
			    (r->start & (rr->align - 1))) {
				pr_err("verify %s %s %pR: not where planned\n", pci_name(dev), lbl,
				       r);
				pr_err("verify %s %s: planned size 0x%llx align 0x%llx\n",
				       pci_name(dev), lbl, rr->size, rr->align);
				bad++;
				continue;
			}
			pcibios_resource_to_bus(dev->bus, &br, r);
			hw_end = br.end;
			rl_read_hw(dev, s, &hw_start, &hw_end);
			if (hw_start != br.start || hw_end != br.end) {
				pr_err("verify %s %s: config decodes 0x%llx-0x%llx, resource 0x%llx-0x%llx\n",
				       pci_name(dev), lbl, hw_start, hw_end, (u64)br.start,
				       (u64)br.end);
				bad++;
			}
			if (r->start != rr->pred)
				pr_warn("  %s %s 0x%llx at 0x%llx, predicted 0x%llx (allocator differed)\n",
					pci_name(dev), lbl, rr->size, (u64)r->start, rr->pred);
			else
				pr_info("  %s %s 0x%llx at 0x%llx predicted 0x%llx\n",
					pci_name(dev), lbl, rr->size, (u64)r->start, rr->pred);
		}
		if (nd->target >= 0 && nd->rebar_pos) {
			u32 v;

			pci_read_config_dword(dev, nd->rebar_pos, &v);
			if (((v & PCI_REBAR_CTRL_BAR_SIZE) >> PCI_REBAR_CTRL_BAR_SHIFT) !=
			    rl_tg[nd->target].idx) {
				pr_err("verify %s ReBAR ctrl 0x%08x, want size %d\n", pci_name(dev),
				       v, rl_tg[nd->target].idx);
				bad++;
			}
		}
	}
	return bad ? -EIO : 0;
}

static int rl_check_dword(struct pci_dev *dev, int reg, u32 want)
{
	u32 v;

	pci_read_config_dword(dev, reg, &v);
	if (v == want)
		return 0;
	pr_err("rollback: %s 0x%03x reads 0x%08x, saved 0x%08x\n", pci_name(dev), reg, v, want);
	return 1;
}

/* Rollback steps 1-3: resources released children first, ReBAR ctrl, resources reclaimed. */
static int rl_rollback_resources(struct rl_root *rt)
{
	int i, s, bad = 0;

	for (i = rt->n - 1; i >= 0; i--)
		for (s = 0; s < RL_NRES; s++)
			if (rt->node[i].res[s].mover && rl_r(&rt->node[i], s)->parent &&
			    rl_release(rt->node[i].dev, rl_resno(s))) {
				pr_err("rollback: cannot release %s resource %d\n",
				       pci_name(rt->node[i].dev), rl_resno(s));
				bad++;
			}
	/* The ReBAR ctrl first: it sets the BAR's read-only low bits. */
	for (i = 0; i < rt->n; i++)
		if (rt->node[i].target >= 0 && rt->node[i].rebar_pos)
			pci_write_config_dword(rt->node[i].dev, rt->node[i].rebar_pos,
					       rt->node[i].rebar_ctrl);
	for (i = 0; i < rt->n; i++)
		for (s = 0; s < RL_NRES; s++) {
			struct rl_res *rr = &rt->node[i].res[s];
			struct resource *r = rl_r(&rt->node[i], s);

			if (!rr->mover || r->parent)
				continue;
			r->start = rr->start;
			r->end = rr->end;
			r->flags = rr->flags;
			if (!rr->was_assigned)
				continue;
			if (pci_claim_resource(rt->node[i].dev, rl_resno(s)) ||
			    r->parent != rr->parent) {
				pr_err("rollback: cannot claim %s %pR into its old parent\n",
				       pci_name(rt->node[i].dev), r);
				bad++;
			}
		}
	return bad;
}

/* Rollback steps 4-5: saved registers written back with decode off, then compared. */
static int rl_rollback_registers(struct rl_root *rt)
{
	int i, s, k, bad = 0;

	for (i = 0; i < rt->n; i++) {
		struct rl_node *nd = &rt->node[i];

		if (!nd->quiesced)
			continue;
		if (nd->res[RL_WIN].mover)
			rl_write_window(nd->dev, nd->pref);
		for (s = 0; s < RL_WIN; s++) {
			struct rl_res *rr = &nd->res[s];

			if (!rr->mover)
				continue;
			for (k = 0; k < ((rr->flags & IORESOURCE_MEM_64) ? 2 : 1); k++)
				pci_write_config_dword(nd->dev, PCI_BASE_ADDRESS_0 + 4 * (s + k),
						       rr->raw[k]);
		}
	}
	for (i = 0; i < rt->n; i++) {
		struct rl_node *nd = &rt->node[i];

		if (nd->target >= 0 && nd->rebar_pos)
			bad += rl_check_dword(nd->dev, nd->rebar_pos, nd->rebar_ctrl);
		if (!nd->quiesced)
			continue;
		if (nd->res[RL_WIN].mover) {
			bad += rl_check_dword(nd->dev, PCI_PREF_MEMORY_BASE, nd->pref[0]);
			bad += rl_check_dword(nd->dev, PCI_PREF_BASE_UPPER32, nd->pref[1]);
			bad += rl_check_dword(nd->dev, PCI_PREF_LIMIT_UPPER32, nd->pref[2]);
		}
		for (s = 0; s < RL_WIN; s++) {
			struct rl_res *rr = &nd->res[s];

			if (!rr->mover)
				continue;
			for (k = 0; k < ((rr->flags & IORESOURCE_MEM_64) ? 2 : 1); k++)
				bad += rl_check_dword(nd->dev, PCI_BASE_ADDRESS_0 + 4 * (s + k),
						      rr->raw[k]);
		}
	}
	return bad;
}

/*
 * Undo a failed apply (the kernel's own restore order). Memory decode comes back only when every
 * resource and register matches the snapshot; otherwise it stays off and a reboot is required.
 */
static int rl_rollback(struct rl_root *rt)
{
	int i, bad;

	bad = rl_rollback_resources(rt);
	bad += rl_rollback_registers(rt);
#ifdef GBR_LAYOUT_TEST
	if (fail_rollback) {
		pr_info("test: forcing a rollback readback mismatch\n");
		bad++;
	}
#endif
	if (bad) {
		pr_err("root %s rollback incomplete (%d problems): memory decode stays off below it; reboot required\n",
		       pci_name(rt->dev), bad);
		return -ENOTRECOVERABLE;
	}
	for (i = 0; i < rt->n; i++) {
		struct rl_node *nd = &rt->node[i];
		u16 cmd;

		if (!nd->quiesced)
			continue;
		pci_write_config_word(nd->dev, PCI_COMMAND, nd->cmd);
		pci_read_config_word(nd->dev, PCI_COMMAND, &cmd);
		if (cmd != nd->cmd) {
			pr_err("rollback: %s command reads 0x%04x, saved 0x%04x\n",
			       pci_name(nd->dev), cmd, nd->cmd);
			return -ENOTRECOVERABLE;
		}
		nd->quiesced = false;
	}
	pr_info("root %s rolled back: every saved register and resource restored\n",
		pci_name(rt->dev));
	return 0;
}

#ifdef GBR_LAYOUT_TEST
/* Saved state (pci_save_state) against live config: command, BARs, prefetchable window. */
static void rl_check_saved(struct rl_root *rt)
{
	int i, d, bad = 0;

	if (!check_saved)
		return;
	for (i = 0; i < rt->n; i++) {
		struct rl_node *nd = &rt->node[i];
		int last = nd->bridge ? 11 : 9;

		if (!rl_owns_mover(nd))
			continue;
		for (d = 1; d <= last; d++) {
			u32 live, saved = nd->dev->saved_config_space[d];
			u32 mask = d == 1 ? 0xffff : 0xffffffff;

			/* class, BIST etc.; for bridges also bus numbers and other windows */
			if (d == 2 || d == 3 || (nd->bridge && d >= 6 && d <= 8))
				continue;
			pci_read_config_dword(nd->dev, d * 4, &live);
			if ((live ^ saved) & mask) {
				pr_info("check_saved %s off 0x%02x saved 0x%08x live 0x%08x\n",
					pci_name(nd->dev), d * 4, saved, live);
				bad++;
			}
		}
	}
	pr_info("check_saved mismatches=%d\n", bad);
}

/* Fault points per step that applying the current plan passes, for enumerating fail_at=. */
static void rl_test_ops(void)
{
	int ops[RL_NSTEPS] = { 0 }, i, k, s;

	for (k = 0; k < rl_nroots; k++) {
		struct rl_root *rt = rl_roots[k];

		if (rt->n && rt->err != -E2BIG)
			ops[RL_SNAPSHOT]++;
		if (!rt->planned || rt->noop || rt->err || !rt->fits)
			continue;
		ops[RL_VERIFY]++;
		for (i = 0; i < rt->n; i++) {
			struct rl_node *nd = &rt->node[i];

			ops[RL_QUIESCE] += rl_owns_mover(nd);
			ops[RL_BME] += rl_owns_mover(nd) && rl_bme_cleared(nd);
			ops[RL_REBAR] += nd->target >= 0;
			for (s = 0; s < RL_NRES; s++) {
				if (!nd->res[s].mover)
					continue;
				ops[RL_RELEASE] += nd->res[s].was_assigned;
				ops[RL_SIZE]++;
				ops[s == RL_WIN ? RL_WINDOW : RL_BAR]++;
				ops[RL_PROGRAM] += s == RL_WIN;
			}
		}
	}
	pr_info("test ops snapshot=%d quiesce=%d bme=%d release=%d size=%d rebar=%d window=%d bar=%d program=%d verify=%d\n",
		ops[RL_SNAPSHOT], ops[RL_QUIESCE], ops[RL_BME], ops[RL_RELEASE], ops[RL_SIZE],
		ops[RL_REBAR], ops[RL_WINDOW], ops[RL_BAR], ops[RL_PROGRAM], ops[RL_VERIFY]);
}
#else
static inline void rl_check_saved(struct rl_root *rt) { }
static inline void rl_test_ops(void) { }
#endif

/* Release children first: release_resource() detaches a window together with its children. */
static int rl_release_all(struct rl_root *rt)
{
	int i, s, ret;

	for (i = rt->n - 1; i >= 0; i--)
		for (s = 0; s < RL_NRES; s++) {
			if (!rt->node[i].res[s].mover || !rl_r(&rt->node[i], s)->parent)
				continue;
			if (rl_inject(RL_RELEASE))
				return -EIO;
			ret = rl_release(rt->node[i].dev, rl_resno(s));
			if (ret) {
				pr_err("cannot release %s resource %d (%d)\n",
				       pci_name(rt->node[i].dev), rl_resno(s), ret);
				return -EIO;
			}
		}
	return 0;
}

/* New sizes; the placement step below sets the addresses. */
static int rl_set_sizes(struct rl_root *rt)
{
	int i, s;

	for (i = 0; i < rt->n; i++)
		for (s = 0; s < RL_NRES; s++) {
			struct rl_res *rr = &rt->node[i].res[s];
			struct resource *r = rl_r(&rt->node[i], s);

			if (!rr->mover)
				continue;
			if (rl_inject(RL_SIZE))
				return -EIO;
			r->start = 0;
			r->end = rr->size - 1;
			r->flags |= IORESOURCE_UNSET;
		}
	return 0;
}

/*
 * The ReBAR ctrl before any BAR register is written (the kernel's order). pci_rebar_set_size() is
 * not exported, so write the size field directly and require an exact readback.
 */
static int rl_set_rebar(struct rl_root *rt)
{
	int i;

	for (i = 0; i < rt->n; i++) {
		struct rl_node *nd = &rt->node[i];
		u32 v, check;

		if (nd->target < 0)
			continue;
		if (rl_inject(RL_REBAR))
			return -EIO;
		if (!nd->rebar_pos)
			continue;	/* fake target (test build): no ctrl */
		v = (nd->rebar_ctrl & ~PCI_REBAR_CTRL_BAR_SIZE) |
		    (rl_tg[nd->target].idx << PCI_REBAR_CTRL_BAR_SHIFT);
		pci_write_config_dword(nd->dev, nd->rebar_pos, v);
		pci_read_config_dword(nd->dev, nd->rebar_pos, &check);
		if (check != v) {
			pr_err("%s ReBAR ctrl reads 0x%08x after writing 0x%08x\n",
			       pci_name(nd->dev), check, v);
			return -EIO;
		}
	}
	return 0;
}

/*
 * Write a 64-bit memory BAR (PCI Local Bus Specification: the low dword holds address bits 31:4
 * over the read-only type and prefetch bits 3:0, the next dword bits 63:32); decode is off.
 */
static void rl_write_bar(struct pci_dev *dev, int s)
{
	struct resource *r = &dev->resource[s];
	struct pci_bus_region br;
	int reg = PCI_BASE_ADDRESS_0 + 4 * s;

	pcibios_resource_to_bus(dev->bus, &br, r);
	pci_write_config_dword(dev, reg, (u32)br.start | (r->flags & ~PCI_BASE_ADDRESS_MEM_MASK));
	pci_write_config_dword(dev, reg + 4, upper_32_bits(br.start));
}

/* Claim one moving resource at @start in its (already placed) parent window. */
static int rl_claim_at(struct rl_node *nd, int s, u64 start)
{
	struct resource *r = rl_r(nd, s);
	int ret;

	r->start = start;
	r->end = start + nd->res[s].size - 1;
	r->flags &= ~(IORESOURCE_UNSET | IORESOURCE_STARTALIGN | IORESOURCE_DISABLED);
	ret = pci_claim_resource(nd->dev, rl_resno(s));
	if (ret) {
		pr_err("cannot claim %s resource %d at 0x%llx (%d)\n", pci_name(nd->dev),
		       rl_resno(s), start, ret);
		return -EIO;
	}
	if (s != RL_WIN)
		rl_write_bar(nd->dev, s);
	return 0;
}

/*
 * Place top-down. The root window is allocated from the chosen host bridge window at exactly the
 * predicted address (allocate_resource() pinned to [pred, pred + size - 1], no alignf), so the
 * placement is the plan: the kernel clips the gap to that range before arch_remove_reservations(),
 * and the fit already skipped candidates touching an e820 range. A failure means the tree changed
 * since the fit. The kernel's own alignf is not used: on newer kernels (7.3 master, not 6.14/7.0)
 * it moves a window whose size is not a multiple of its alignment below the aligned address.
 * Every other window and BAR is claimed at its planned offset in its parent window, so the result
 * does not depend on the running kernel's allocator.
 */
static int rl_assign_all(struct rl_root *rt)
{
	struct rl_res *w = &rt->node[0].res[RL_WIN];
	struct resource *r = rl_r(&rt->node[0], RL_WIN);
	int i, k, ret;

	if (rl_inject(RL_WINDOW))
		return -EIO;
	r->flags &= ~(IORESOURCE_UNSET | IORESOURCE_STARTALIGN | IORESOURCE_DISABLED);
	ret = allocate_resource(rt->host, r, w->size, w->pred, w->pred + w->size - 1, w->align,
				NULL, NULL);
	if (ret) {
		r->flags |= IORESOURCE_UNSET;
		pr_err("cannot allocate the root window 0x%llx align 0x%llx in %pR (%d)\n", w->size,
		       w->align, rt->host, ret);
		return -EIO;
	}
	for (i = 0; i < rt->n; i++) {
		struct rl_node *nd = &rt->node[i];
		u64 base = rl_r(nd, RL_WIN)->start;

		if (!nd->res[RL_WIN].mover)
			continue;
		for (k = nd->first; k < nd->first + nd->nitems; k++) {
			struct rl_item it = rt->item[k];
			struct rl_node *c = &rt->node[it.node];

			if (rl_inject(it.slot == RL_WIN ? RL_WINDOW : RL_BAR))
				return -EIO;
			ret = rl_claim_at(c, it.slot, base + c->res[it.slot].off);
			if (ret)
				return ret;
		}
	}
	return 0;
}

static int rl_apply(struct rl_root *rt)
{
	int i, ret;

	for (i = 0; i < rt->n; i++) {
		struct rl_node *nd = &rt->node[i];

		if (!rl_owns_mover(nd))
			continue;
		if (rl_inject(RL_QUIESCE))
			return -EIO;
		pci_write_config_word(nd->dev, PCI_COMMAND, rl_quiet_cmd(nd));
		nd->quiesced = true;
		if (rl_bme_cleared(nd)) {
			pr_info("%s: bus mastering off during the move (no driver bound), restored after\n",
				pci_name(nd->dev));
			if (rl_inject(RL_BME))
				return -EIO;
		}
	}
	ret = rl_release_all(rt);
	if (!ret)
		ret = rl_set_sizes(rt);
	if (!ret)
		ret = rl_set_rebar(rt);
	if (!ret)
		ret = rl_assign_all(rt);
	if (ret)
		return ret;
	for (i = 0; i < rt->n; i++) {
		if (!rt->node[i].res[RL_WIN].mover)
			continue;
		if (rl_inject(RL_PROGRAM))
			return -EIO;
		rl_program_window(rt->node[i].dev);
	}
	if (rl_inject(RL_VERIFY))
		return -EIO;
	ret = rl_verify(rt);
	if (ret)
		return ret;
	for (i = 0; i < rt->n; i++) {
		struct rl_node *nd = &rt->node[i];

		if (!nd->quiesced)
			continue;
		pci_write_config_word(nd->dev, PCI_COMMAND, nd->cmd);
		nd->quiesced = false;
		/*
		 * Otherwise a later pci_restore_state() (AER/DPC recovery, reset) would write back
		 * the windows and BARs saved at probe time.
		 */
		pci_save_state(nd->dev);
	}
	rl_check_saved(rt);
	return 0;
}

/* --- driver ----------------------------------------------------------------------------------- */

static int rl_setup_roots(void)
{
	int i, j, ret = 0;

	for (i = 0; i < rl_ntg; i++) {
		struct rl_target *t = &rl_tg[i];
		struct pci_dev *root = rl_root_of(t->dev);

		if (!root) {
			pr_info("target %s is on a root bus: no root port to lay out, refused\n",
				pci_name(t->dev));
			ret = rl_worse(ret, -EINVAL);
			continue;
		}
		for (j = 0; j < rl_nroots; j++)
			if (rl_roots[j]->dev == root)
				break;
		if (j == rl_nroots) {
			if (rl_nroots == RL_MAX_ROOTS) {
				pr_info("target %s: more than %d root ports, refused\n",
					pci_name(t->dev), RL_MAX_ROOTS);
				ret = rl_worse(ret, -E2BIG);
				continue;
			}
			rl_roots[j] = kvzalloc(sizeof(*rl_roots[j]), GFP_KERNEL);
			if (!rl_roots[j])
				return -ENOMEM;
			rl_roots[j]->dev = root;
			rl_nroots++;
		}
		t->root = j;
	}
	return ret;
}

/* Collect, lock, check and plan root @k. Returns -ENOMEM or 0. */
static int rl_prepare(int k)
{
	struct rl_root *rt = rl_roots[k];
	int i, n, ret;

	/* The root port itself is node 0, then the subtree in pre-order (parents first). */
	rl_collect_cb(rt->dev, rt);
	if (rt->dev->subordinate)
		pci_walk_bus(rt->dev->subordinate, rl_collect_cb, rt);
	if (rt->err == -E2BIG) {
		pr_info("root %s has more than %d functions below it\n", pci_name(rt->dev),
			RL_MAX_NODES);
		return 0;
	}
	for (i = 0; i < rl_ntg; i++)
		for (n = 0; rl_tg[i].root == k && n < rt->n; n++)
			if (rt->node[n].dev == rl_tg[i].dev)
				rt->node[n].target = i;
	if (rl_inject(RL_SNAPSHOT))
		return -ENOMEM;
	rl_check(rt);
	rt->noop = rl_noop(rt);
	ret = rl_plan(rt);
	if (ret == -EOVERFLOW)
		pr_info("root %s plan overflows the 64-bit address space\n", pci_name(rt->dev));
	return ret == -ENOMEM ? ret : 0;
}

static void rl_unlock_all(void)
{
	int i, k;

	for (k = rl_nroots - 1; k >= 0; k--)
		for (i = rl_roots[k]->n - 1; i >= 0; i--) {
			struct rl_node *nd = &rl_roots[k]->node[i];

			if (nd->locked)
				pci_dev_unlock(nd->dev);
			nd->locked = false;
			if (nd->pm_ref)
				pm_runtime_put(&nd->dev->dev);
			nd->pm_ref = false;
		}
}

static void rl_free_all(void)
{
	int i, k;

	for (k = 0; k < rl_nroots; k++) {
		for (i = 0; i < rl_roots[k]->n; i++)
			pci_dev_put(rl_roots[k]->node[i].dev);
		kvfree(rl_roots[k]);
	}
	rl_nroots = 0;
	for (i = 0; i < rl_ntg; i++)
		pci_dev_put(rl_tg[i].dev);
}

/* Roots in placement order: largest root window alignment first, then BDF. */
static void rl_sort_roots(void)
{
	int i, j;

	for (i = 1; i < rl_nroots; i++)
		for (j = i; j > 0; j--) {
			struct rl_root *a = rl_roots[j - 1], *b = rl_roots[j];
			u64 aa = a->node[0].res[RL_WIN].align, ba = b->node[0].res[RL_WIN].align;

			if (aa > ba || (aa == ba && rl_bdf_cmp(a->dev, b->dev) < 0))
				break;
			swap(rl_roots[j - 1], rl_roots[j]);
		}
}

/* Plan, fit and log root @k; in apply mode apply it. Returns this root's errno. */
static int rl_do_root(int k, bool *stop)
{
	struct rl_root *rt = rl_roots[k];
	int ret;

	if (rt->noop) {
		pr_info("root %s nothing to do: every target already has its size\n",
			pci_name(rt->dev));
		rl_result(rt, "nothing-to-do");
		return 0;
	}
	if (!rt->planned) {
		if (rt->err != -E2BIG)
			pr_info("root %s has nothing to lay out (no assigned 64-bit prefetchable window)\n",
				pci_name(rt->dev));
		rl_result(rt, "refused");
		return rl_worse(rt->err, -EBUSY);
	}
	ret = rl_fit(k);
	if (ret < 0)
		return ret;
	rt->fits = ret;
	if (rt->fits)
		rl_predict(rt, 0, rt->node[0].res[RL_WIN].pred);
	rl_log_plan(rt);
	if (!rt->fits)
		pr_info("root %s %s: window 0x%llx align 0x%llx fits no host bridge window\n",
			pci_name(rt->dev), dry_run ? "would-refuse" : "refuse",
			rt->node[0].res[RL_WIN].size, rt->node[0].res[RL_WIN].align);
	if (dry_run) {
		if (rt->fits)
			rl_log_writes(rt);
		rl_result(rt, "dry-run");
		return rl_worse(rt->err, rt->fits ? 0 : -ENOSPC);
	}
	if (rt->err) {
		rl_result(rt, "refused");
		return rt->err;
	}
	if (!rt->fits) {
		rl_result(rt, "nospace");
		return -ENOSPC;
	}
	if (*stop) {
		pr_info("root %s not attempted after an earlier failure\n", pci_name(rt->dev));
		rl_result(rt, "skipped");
		return 0;
	}
	if (!rl_apply(rt)) {
		rl_result(rt, "ok");
		return 0;
	}
	*stop = true;
	if (rl_rollback(rt)) {
		rl_result(rt, "rollback-failed");
		return -ENOTRECOVERABLE;
	}
	rl_result(rt, "rolled-back");
	return -EIO;
}

static int rl_run(void)
{
	bool stop = false;
	int rc, k;

	rc = rl_setup_roots();
	if (rc == -ENOMEM)
		return rc;
	for (k = 0; k < rl_nroots; k++)
		if (rl_prepare(k))
			return -ENOMEM;
#ifdef GBR_LAYOUT_TEST
	if (hold_ms) {
		pr_info("test: holding the locks for %u ms\n", hold_ms);
		msleep(hold_ms);
	}
#endif
	rl_sort_roots();
	for (k = 0; k < rl_nroots; k++)
		rc = rl_worse(rc, rl_do_root(k, &stop));
	if (dry_run)
		rl_test_ops();
	return rc;
}

static int __init rl_init(void)
{
	int rc, i;

	if (size < 0 || size > 31 || bar < 0 || bar > 5) {
		pr_err("size= (0..31) is required and bar= must be 0..5\n");
		return -EINVAL;
	}
	rc = rl_parse_targets();
	if (!rc)
		rc = rl_parse_test();
	if (rc)
		return rc;
	pr_info("start version=%s src=%s targets=%d bar=%d size=%d dry_run=%d\n", RL_VERSION,
		RL_SRC, rl_ntg, bar, size, dry_run);
	for (i = 0; i < rl_ntg; i++) {
		struct rl_target *t = &rl_tg[i];

		t->dev = pci_get_domain_bus_and_slot(t->dom, t->bus, t->devfn);
		if (!t->dev) {
			pr_err("target %04x:%02x:%02x.%x not present\n", t->dom, t->bus,
			       PCI_SLOT(t->devfn), PCI_FUNC(t->devfn));
			rc = -EINVAL;
		} else if (!rl_pref64(&t->dev->resource[t->bar])) {
			pr_err("target %s BAR%d is not a 64-bit prefetchable memory BAR\n",
			       pci_name(t->dev), t->bar);
			rc = -EINVAL;
		}
	}
	if (!rc) {
		rl_claim_insert();
		pci_lock_rescan_remove();
		rc = rl_run();
		rl_test_fail_report();
		rl_unlock_all();
		pci_unlock_rescan_remove();
		rl_claim_remove();
	}
	rl_free_all();
	pr_info("done rc=%d\n", rc);
	return rc;
}

static void __exit rl_exit(void)
{
}

module_init(rl_init);
module_exit(rl_exit);
MODULE_LICENSE("Dual MIT/GPL");
MODULE_DESCRIPTION("Lay out the prefetchable windows below a root port again so resized BARs fit");
MODULE_VERSION(RL_VERSION);
