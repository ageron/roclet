#!/bin/sh
# Prepare the pinned Zig dependency without changing the supplied Roc checkout.
set -eu
roclet_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
roclet_checkout=${1:-"$roclet_root/../roc"}
roclet_commit=$(sed -n 's/.*"compilerCommit": "\([^"]*\)".*/\1/p' "$roclet_root/compiler.lock.json")
roclet_patch="$roclet_root/compiler-adapter/embedding.patch"
roclet_patch_key=$(git hash-object "$roclet_patch")
roclet_key="$roclet_commit-$roclet_patch_key"
roclet_target="$roclet_root/.toolchain/roc-$roclet_key"
roclet_link="$roclet_root/.toolchain/roc"

git -C "$roclet_checkout" cat-file -e "$roclet_commit^{commit}"
mkdir -p "$roclet_root/.toolchain"
if [ -e "$roclet_link" ] && [ ! -L "$roclet_link" ]; then
    echo "Expected $roclet_link to be a generated symlink; leaving the existing directory untouched." >&2
    exit 1
fi
if [ ! -f "$roclet_target/.roclet-embedding-ready" ]; then
    if [ -e "$roclet_target" ]; then
        mv "$roclet_target" "$roclet_target.incomplete-$$"
    fi
    mkdir "$roclet_target"
    git -C "$roclet_checkout" archive "$roclet_commit" | tar -xf - -C "$roclet_target"
    git -C "$roclet_root" apply --unsafe-paths --directory="$roclet_target" "$roclet_patch"
    echo "$roclet_key" > "$roclet_target/.roclet-embedding-ready"
fi
ln -sfn "$(basename "$roclet_target")" "$roclet_link"
echo "Prepared Roc $roclet_commit with the versioned embedding API additions."
