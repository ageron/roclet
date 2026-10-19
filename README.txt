Roclet offline distribution

Serve this directory over HTTPS or localhost. With the included host-platform server:
  ./roclet-serve . 4173
Then open http://127.0.0.1:4173/web/studio.html
Choose File > Offline & storage > Prepare for offline use before disconnecting.
No Node, npm, Python, external CDN or account is required.

Headless runner (host platform): ./roclet run notebook.roc (or notebook.md).
JSON stdout uses the same core and evaluation contract as the browser. Exit 1 means diagnostics/failure; 0 means success. Bound execution time in your job supervisor for untrusted/nonterminating programs. Imports remain limited to the pinned adapter capabilities.
The native binary is specific to the platform in artifacts/manifest.json.

Roclet is licensed under UPL-1.0. See LICENSE and THIRD_PARTY_NOTICES.md. See docs/installation.md for setup and demos/README.md for examples. Only Chrome has been tested.
