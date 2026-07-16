# Prebuilt patched systemd-networkd

Fedora 44's `systemd-networkd`, rebuilt from the distribution SRPM with
`../0001-network-support-IPv6-resolved-IPv4-gateway-192.0.0.1.patch`
applied (see `../README.md`), is published as a **release asset** rather
than committed here, to keep clones lean. It saves the ~30-minute source
build; the patch remains the source of truth.

Download — **aarch64 only** (rebuild from the SRPM for x86_64 or any other
systemd release):

    curl -LO https://github.com/remcovanmook/v4-with-v6-nh/releases/download/prebuilt-arm64/systemd-networkd-259.7-1.fc44.aarch64.rpm
    sudo rpm -Uvh --force systemd-networkd-259.7-1.fc44.aarch64.rpm

Same NVR as the stock package, hence `--force`. It installs to
`/usr/lib/systemd/systemd-networkd` with the correct SELinux label and runs
under enforcing. A later `dnf upgrade` that bumps systemd will replace it
with the stock binary — reinstall (or rebuild) afterwards.
