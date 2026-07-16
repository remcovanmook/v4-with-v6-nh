# Prebuilt v4gwd-arp

A compiled `../v4gwd-arp.c` for Apple Silicon is published as a **release
asset** (not committed here). Building it yourself is a one-liner (`make`);
this just saves that step, and the C source is authoritative.

Download — **arm64**, macOS 26 / Darwin (on Intel, run `make`):

    curl -LO https://github.com/remcovanmook/v4-with-v6-nh/releases/download/prebuilt/v4gwd-arp-macos-arm64
    sudo install -m 755 v4gwd-arp-macos-arm64 /usr/local/sbin/v4gwd-arp

The binary is unsigned — run it via `sudo`; it needs no entitlements.
