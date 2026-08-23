//
//  alloheadless.swift
//  allonet2
//

/// The place-side transport used to live here, on top of libdatachannel, while the client had a
/// googlewebrtc one. There is only one transport now and it lives in `allonet2`; this target
/// stays so `import alloheadless` keeps compiling, and can be deleted once no consumer says it.
@_exported import allonet2
