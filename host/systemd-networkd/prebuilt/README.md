# Prebuilt patched systemd-networkd

`systemd-networkd` rebuilt with
`../0001-network-support-IPv6-resolved-IPv4-gateway-192.0.0.1.patch`
applied (see `../README.md`), published as **release assets** rather than
committed here, to keep clones lean. They save the ~30-minute source build;
the patch remains the source of truth. **arm64 only** — for x86_64/amd64 (or
any other systemd release) rebuild from source per `../README.md`.

## Fedora

Fedora 44, rebuilt from the distribution SRPM:

    curl -LO https://github.com/remcovanmook/v4-with-v6-nh/releases/download/prebuilt-arm64/systemd-networkd-259.7-1.fc44.aarch64.rpm
    sudo rpm -Uvh --force systemd-networkd-259.7-1.fc44.aarch64.rpm

Same NVR as the stock package, hence `--force`. It installs to
`/usr/lib/systemd/systemd-networkd` with the correct SELinux label and runs
under enforcing. A later `dnf upgrade` that bumps systemd will replace it
with the stock binary — reinstall (or rebuild) afterwards.

## Ubuntu / Debian

Ubuntu 26.04, rebuilt from `apt-get source` (networkd is not split out, so
this is the whole `systemd` package):

    curl -LO https://github.com/remcovanmook/v4-with-v6-nh/releases/download/prebuilt-arm64/systemd_259.5-0ubuntu3_arm64.deb
    sudo dpkg -i systemd_259.5-0ubuntu3_arm64.deb

Same version as the stock package (a reinstall). A later `apt upgrade` that
bumps systemd replaces it with the stock binary — reinstall (or rebuild)
afterwards.
