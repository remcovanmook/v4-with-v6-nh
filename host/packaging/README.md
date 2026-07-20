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

Short URLs at <https://remcovanmook.github.io/v4-with-v6-nh/> track the current
release.

Debian / Ubuntu:

    wget https://remcovanmook.github.io/v4-with-v6-nh/v4gwd.deb
    sudo apt install ./v4gwd.deb

Fedora / RHEL:

    wget https://remcovanmook.github.io/v4-with-v6-nh/v4gwd.rpm
    sudo dnf install ./v4gwd.rpm

The versioned assets (`v4gwd_0.2.0_all.deb`, `v4gwd-0.2.0-1.noarch.rpm`) are
also on the [`prebuilt`](https://github.com/remcovanmook/v4-with-v6-nh/releases/tag/prebuilt)
release.

Then `journalctl -u v4gwd -f` to watch it act when the sentinel appears. On a
pre-5.2 kernel the daemon selects the static-neighbor fallback on its own.

## Build

    sh build.sh [VERSION]        # needs dpkg-deb + rpmbuild; noarch, any host arch

Both artifacts land in `dist/`.
