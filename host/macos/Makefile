# macOS build for v4gwd-arp.  Requires the Command Line Tools (clang);
# full Xcode is not needed.
CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra -Wshadow
PREFIX  ?= /usr/local

v4gwd-arp: v4gwd-arp.c
	$(CC) $(CFLAGS) -o $@ $<

install: v4gwd-arp
	install -d $(PREFIX)/sbin
	install -m 755 v4gwd-arp $(PREFIX)/sbin/v4gwd-arp

clean:
	rm -f v4gwd-arp

.PHONY: install clean
