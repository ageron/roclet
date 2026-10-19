# MD4C

Vendored from [MD4C release 0.5.2](https://github.com/mity/md4c/tree/release-0.5.2).
License: MIT, in `LICENSE.md`. No package installation or network fetch is needed
when building this copy. Zig compiles the same C parser for native and WASM.

Two local changes to `md4c.c`:

1. Standard-library includes go through `roclet-md.h`, which supplies allocator
   hooks and freestanding sorting/searching helpers for WASM.
2. A callback immediately before rendering a top-level leaf block exposes its
   source range. Nested lists and quotes remain opaque to notebook segmentation.

`compiler-adapter/syntax.zig` owns the callbacks, source spans, and allocations.
Normal MD4C inline callbacks distinguish a paragraph containing exactly one
image, including reference images and URLs containing parentheses. Cell/output
association belongs to the Roc core. The parser enables the GFM table extension.

The build manifest hashes the parser, header, and shim along with adapter inputs.
