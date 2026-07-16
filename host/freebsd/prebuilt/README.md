# Prebuilt v4gwd

A compiled `../v4gwd.c` for FreeBSD 15.1/arm64 is published as a **release
asset** (not committed here). Building it yourself is a one-liner (`make`,
or `cc -O2 -o v4gwd v4gwd.c`); this just saves that step, and the C source
is authoritative.

Download — **arm64**, FreeBSD 15.1 (on amd64, rebuild):

    fetch https://github.com/remcovanmook/v4-with-v6-nh/releases/download/prebuilt-arm64/v4gwd-freebsd-arm64
    install -m 755 v4gwd-freebsd-arm64 /usr/local/sbin/v4gwd
