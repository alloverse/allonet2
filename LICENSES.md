# Third-party licenses

Dependencies vendored into this repository or linked into shipped binaries.

| Component | Version | License | Notes |
|---|---|---|---|
| [libopus](https://opus-codec.org) | 1.4 (`Packages/opus`) | BSD-3-Clause | Vendored as a submodule and built as a SwiftPM C target. Full text in `Packages/opus/COPYING`. |
| [libdatachannel](https://github.com/paullouisageneau/libdatachannel) | 0.24.0 | MPL-2.0 | Via `Packages/AlloDataChannel`. File-level copyleft; used unmodified. |

BSD-3-Clause and MPL-2.0 are both compatible with shipping a closed-source
application, provided the notices are reproduced and MPL-covered files stay
available in source form.
