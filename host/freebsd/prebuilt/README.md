# Prebuilt v4gwd

A compiled `../v4gwd.c` for FreeBSD 15.1 (`arm64` and `amd64`) is published
as a **release asset** (not committed here). Building it yourself is a
one-liner (`make`, or `cc -O2 -o v4gwd v4gwd.c`); this just saves that step,
and the C source is authoritative.

Download — **arm64 and amd64**, FreeBSD 15.1 (`uname -m` picks the arch):

    fetch https://github.com/remcovanmook/v4-with-v6-nh/releases/download/prebuilt/v4gwd-freebsd-$(uname -m)
    install -m 755 v4gwd-freebsd-$(uname -m) /usr/local/sbin/v4gwd
