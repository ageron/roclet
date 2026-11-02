#!/bin/sh
# Install the latest Roclet server, or pass a version such as 0.2.0.
set -eu
fail() { printf '%s\n' "$*" >&2; exit 1; }
[ "$#" -le 1 ] || fail 'Usage: sh install.sh [VERSION]'
for tool in curl tar awk; do command -v "$tool" >/dev/null || fail "Required command: $tool"; done
case "$(uname -s)" in Darwin) os=macos ;; Linux) os=linux ;; *) fail 'Supported systems: macOS and Linux.' ;; esac
case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; x86_64|amd64) arch=x64 ;; *) fail 'Supported architectures: ARM64 and x64.' ;; esac
base=https://github.com/ageron/roclet/releases
version=${1:-}
if [ -z "$version" ]; then
    latest=$(curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' -o /dev/null -w '%{url_effective}' "$base/latest")
    case "$latest" in "$base/tag/server-v"*) version=${latest##*/server-v} ;; *) fail 'No latest server release found. Pass a server version explicitly.' ;; esac
fi
printf '%s\n' "$version" | awk '/^[0-9]+\.[0-9]+\.[0-9]+$/ {ok=1} END {exit !ok}' || fail 'Expected a version such as 0.2.0.'
root=$HOME/.local/share/roclet
bin=$HOME/.local/bin
command_path=$bin/roclet
if [ -e "$command_path" ] || [ -L "$command_path" ]; then
    grep -q '^# Roclet installer launcher$' "$command_path" || fail "$command_path already exists and is not managed by this installer. Move it first."
fi
destination=$root/versions/$version-$os-$arch
if [ -e "$destination" ]; then
    if [ -f "$destination/roclet" ] && [ -f "$command_path" ] && grep -Fq "versions/$version-$os-$arch/roclet" "$command_path"; then
        printf 'Roclet %s is already installed. Run: roclet serve\n' "$version"
        exit 0
    fi
    fail "$destination already exists; move it before reinstalling this version."
fi
mkdir -p "$root/versions" "$bin"
# Stage on the same filesystem as the installation for an atomic directory move.
tmp=$(mktemp -d "$root/.install.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
url=$base/download/server-v$version
fetch() { curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' "$url/$1" -o "$tmp/$1"; }
fetch SHA256SUMS
archive=roclet-$version-$os-$arch.tar.gz
expected=$(awk -v name="$archive" '$2 == name {print $1}' "$tmp/SHA256SUMS")
# Releases predating versioned asset names remain installable.
if [ -z "$expected" ]; then
    archive=roclet-$os-$arch.tar.gz
    expected=$(awk -v name="$archive" '$2 == name {print $1}' "$tmp/SHA256SUMS")
fi
[ "${#expected}" -eq 64 ] || fail 'Archive missing from release checksums.'
fetch "$archive"
if command -v sha256sum >/dev/null; then
    actual=$(sha256sum "$tmp/$archive" | awk '{print $1}')
else
    actual=$(shasum -a 256 "$tmp/$archive" | awk '{print $1}')
fi
[ "$actual" = "$expected" ] || fail 'Checksum mismatch; installation cancelled.'
tar -xzf "$tmp/$archive" -C "$tmp"
[ -f "$tmp/roclet/roclet" ] && [ -f "$tmp/roclet/index.html" ] || fail 'Incomplete server archive.'
mv "$tmp/roclet" "$destination"
cat > "$tmp/launcher" <<LAUNCHER
#!/bin/sh
# Roclet installer launcher
exec "\$HOME/.local/share/roclet/versions/$version-$os-$arch/roclet" "\$@"
LAUNCHER
chmod 755 "$tmp/launcher"
mv "$tmp/launcher" "$command_path"
printf 'Installed Roclet %s.\n' "$version"
case ":$PATH:" in *":$bin:"*) ;; *) printf 'Add this line to ~/.zshrc or ~/.bashrc, then open a new terminal:\n  export PATH="$HOME/.local/bin:$PATH"\n' ;; esac
printf 'Run: roclet serve\n'
