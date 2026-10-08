#!/bin/sh
# Installs the zanity binary for this machine from its GitHub releases:
#
#   curl -fsSL https://raw.githubusercontent.com/benomahony/zanity/main/install.sh | sh
#
# ZANITY_VERSION=0.1.0 installs that release instead of the latest; ZANITY_INSTALL_DIR puts the
# binary somewhere other than ~/.local/bin.
set -eu

repo=benomahony/zanity
dir=${ZANITY_INSTALL_DIR:-$HOME/.local/bin}

fail() {
    echo "zanity install: $*" >&2
    exit 1
}

case $(uname -s) in
Linux) os=linux ;;
Darwin) os=macos ;;
*) fail "there is no prebuilt binary for $(uname -s); on Windows, download zanity-windows-x86_64.exe from https://github.com/$repo/releases, or build from source as the README describes" ;;
esac
case $(uname -m) in
x86_64 | amd64) arch=x86_64 ;;
arm64 | aarch64) arch=aarch64 ;;
*) fail "there is no prebuilt binary for $(uname -m) processors; build from source as the README describes" ;;
esac
asset=zanity-$os-$arch

if [ -n "${ZANITY_VERSION:-}" ]; then
    tag=v${ZANITY_VERSION#v}
    url=https://github.com/$repo/releases/download/$tag/$asset
    api=https://api.github.com/repos/$repo/releases/tags/$tag
else
    url=https://github.com/$repo/releases/latest/download/$asset
    api=https://api.github.com/repos/$repo/releases/latest
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/zanity" "$url" || fail "could not download $url; check that the release exists at https://github.com/$repo/releases"

# GitHub records each release file's SHA-256; check the download against it.
expected=$(curl -fsSL "$api" 2>/dev/null | tr ',' '\n' |
    awk -v name="\"$asset\"" '/"name":/ { mine = index($0, name) > 0 } mine && /"digest":/ { sub(/.*sha256:/, ""); sub(/".*/, ""); print; exit }')
if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$tmp/zanity" | cut -d' ' -f1)
else
    actual=$(shasum -a 256 "$tmp/zanity" | cut -d' ' -f1)
fi
if [ -z "$expected" ]; then
    echo "zanity install: couldn't read the release's SHA-256 from the GitHub API (it may be rate-limited), so this download is unverified" >&2
elif [ "$expected" != "$actual" ]; then
    fail "the download's SHA-256 is $actual, but the release lists $expected; run the install again, and report it if it happens twice"
fi

mkdir -p "$dir"
chmod +x "$tmp/zanity"
mv "$tmp/zanity" "$dir/zanity"
echo "Installed $("$dir/zanity" --version) to $dir/zanity"
case ":$PATH:" in
*":$dir:"*) ;;
*) echo "$dir isn't on your PATH yet; add it, for example with: echo 'export PATH=\"$dir:\$PATH\"' >> ~/.zshrc" ;;
esac
