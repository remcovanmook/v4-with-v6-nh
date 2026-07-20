#!/bin/sh
# Build architecture-independent v4gwd packages from the committed sources.
# The daemon is pure Python (pyroute2), so both the .deb and the .rpm are
# noarch/all and install on any CPU. Needs dpkg-deb and rpmbuild; the build
# host's own architecture is irrelevant.
#
# Usage: build.sh [VERSION]      # default below; artifacts land in ./dist/
#   dist/v4gwd_<version>_all.deb
#   dist/v4gwd-<version>-1.noarch.rpm
#
# The package installs the daemon as /usr/bin/v4gwd with a matching systemd
# unit; the committed unit's /usr/local/bin path is for the manual install.
set -eu

VERSION="${1:-0.2.0}"
NAME=v4gwd
MAINT="Remco van Mook <remco.vanmook@gmail.com>"
URL="https://github.com/remcovanmook/v4-with-v6-nh"
SUMMARY="IPv6-Resolved IPv4 Gateway daemon"
BLURB="Host-side reference implementation of
draft-vanmook-intarea-ipv6-resolved-gateway (Section 4): a host with
192.0.0.11 as its IPv4 default gateway resolves the next hop from the IPv6
neighbor cache (RFC 4861/4191) instead of ARP. Pure Python; noarch."

here=$(cd "$(dirname "$0")" && pwd)
src="$here/.."
out="$here/dist"
rm -rf "$out"; mkdir -p "$out"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Shared payload: the filesystem both packages lay down.
payload="$work/payload"
install -D -m 755 "$src/v4gwd.py" "$payload/usr/bin/v4gwd"
mkdir -p "$payload/usr/lib/systemd/system"
sed 's#^ExecStart=.*#ExecStart=/usr/bin/v4gwd#' \
    "$src/systemd/v4gwd.service" > "$payload/usr/lib/systemd/system/v4gwd.service"
chmod 644 "$payload/usr/lib/systemd/system/v4gwd.service"

# -------- .deb (Architecture: all) --------
deb="$work/deb"
mkdir -p "$deb/DEBIAN"
cp -a "$payload"/. "$deb"/
cat > "$deb/DEBIAN/control" <<EOF
Package: $NAME
Version: $VERSION
Architecture: all
Maintainer: $MAINT
Depends: python3 (>= 3.6), python3-pyroute2
Section: net
Priority: optional
Homepage: $URL
Description: $SUMMARY
 $(echo "$BLURB" | sed 's/^$/./; s/^/ /' | sed '1s/^ //')
EOF
cat > "$deb/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = configure ]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable v4gwd.service >/dev/null 2>&1 || true
    if [ -d /run/systemd/system ]; then
        if [ -z "$2" ]; then
            systemctl start v4gwd.service >/dev/null 2>&1 || true
        else
            systemctl try-restart v4gwd.service >/dev/null 2>&1 || true
        fi
    fi
fi
EOF
cat > "$deb/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = remove ] || [ "$1" = deconfigure ]; then
    systemctl stop v4gwd.service >/dev/null 2>&1 || true
fi
EOF
cat > "$deb/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = remove ] || [ "$1" = purge ]; then
    systemctl disable v4gwd.service >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
fi
EOF
chmod 755 "$deb/DEBIAN/postinst" "$deb/DEBIAN/prerm" "$deb/DEBIAN/postrm"
dpkg-deb --root-owner-group --build "$deb" \
    "$out/${NAME}_${VERSION}_all.deb" >/dev/null

# -------- .rpm (BuildArch: noarch) --------
rpmtop="$work/rpm"
mkdir -p "$rpmtop/BUILD"
cat > "$work/$NAME.spec" <<EOF
Name:           $NAME
Version:        $VERSION
Release:        1
Summary:        $SUMMARY
License:        GPL-2.0-only
URL:            $URL
BuildArch:      noarch
Requires:       python3
Requires:       python3-pyroute2

%description
$BLURB

%install
install -D -m 755 $payload/usr/bin/v4gwd %{buildroot}/usr/bin/v4gwd
install -D -m 644 $payload/usr/lib/systemd/system/v4gwd.service \\
        %{buildroot}/usr/lib/systemd/system/v4gwd.service

%files
/usr/bin/v4gwd
/usr/lib/systemd/system/v4gwd.service

%post
systemctl daemon-reload >/dev/null 2>&1 || true
if [ \$1 -eq 1 ]; then
    systemctl enable --now v4gwd.service >/dev/null 2>&1 || true
else
    systemctl try-restart v4gwd.service >/dev/null 2>&1 || true
fi

%preun
if [ \$1 -eq 0 ]; then
    systemctl disable --now v4gwd.service >/dev/null 2>&1 || true
fi

%postun
systemctl daemon-reload >/dev/null 2>&1 || true
EOF
rpmbuild --define "_topdir $rpmtop" -bb "$work/$NAME.spec" >/dev/null
find "$rpmtop/RPMS" -name '*.rpm' -exec cp {} "$out/" \;

echo "Built:"
ls -1 "$out"
