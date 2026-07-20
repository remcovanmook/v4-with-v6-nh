# Packages for v4gwd

`v4gwd.py` is pure Python (pyroute2), so it ships as one architecture-independent
`.deb` and one `.rpm` — the same file runs on any CPU. Both are published as
**release assets**; [`build.sh`](build.sh) rebuilds them from the committed
sources.

The package installs the daemon as `/usr/bin/v4gwd` with a systemd unit, depends
on `python3` + `python3-pyroute2` (pulled automatically), and enables and starts
`v4gwd.service` on install. It is fire-and-forget: managing every ethernet
interface and inert until a DHCPv4 server hands out `192.0.0.11`.

## Install

Debian / Ubuntu:

    curl -LO https://github.com/remcovanmook/v4-with-v6-nh/releases/download/prebuilt/v4gwd_0.2.0_all.deb
    sudo apt install ./v4gwd_0.2.0_all.deb

Fedora / RHEL:

    curl -LO https://github.com/remcovanmook/v4-with-v6-nh/releases/download/prebuilt/v4gwd-0.2.0-1.noarch.rpm
    sudo dnf install ./v4gwd-0.2.0-1.noarch.rpm

Then `journalctl -u v4gwd -f` to watch it act when the sentinel appears. On a
pre-5.2 kernel the daemon selects the static-neighbor fallback on its own.

## Build

    sh build.sh [VERSION]        # needs dpkg-deb + rpmbuild; noarch, any host arch

Both artifacts land in `dist/`.
