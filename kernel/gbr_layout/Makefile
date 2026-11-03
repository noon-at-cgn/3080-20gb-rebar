# SPDX-License-Identifier: GPL-2.0-only OR MIT
# make [KDIR=/lib/modules/<release>/build] [TEST=1]
KDIR ?= /lib/modules/$(shell uname -r)/build

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean

.PHONY: all clean
