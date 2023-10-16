# Allonet2

Very early experimental next iteration of [allonet](https://github.com/alloverse/allonet/),
the fundamental networking library that underpins the distributed and collaborative 3D/VR/AR
workspace [Alloverse](https://alloverse.com/).

Allonet allows the writing of three different kinds of software:

* Alloapps: "widget" apps that run in a 3D space. They run server-side but have an API that
  feels client-side. They're built towards a "UI library" built on top of allonet.
* Visor: The 3D application(s) used to visualize these apps and other uses. Basically a 3D
  web browser.
* Place: The "simulation server"/network hub that users and apps connect to.

## Rationale

Allonet 1 was written in C, because I have decades of experience in C, and I know how to make
it work on pretty much any platform. However, the constant memory corruption, lack of abstraction,
and lack of a standard library worth mentioning is a pain.

Requirements for a rewrite:

* Interfaces with C, so that it can be used with C FFI from C#, lua, C++, Java, etc, and
  integrated with any game engine or app platform
* Language must be modern and object oriented, and also suitable for functional programming,
  good support for async and threading
* Must have a package manager and a wide library of functionality.

Both Swift and Rust match these. Rust won't play well with my brain, despite many tries. So
Swift it is.

## Development

### Windows

1. Install [Swift 5.9](https://www.swift.org/download/)
2. Launch a Developer PowerShell For Visual Studio 2019 in Windows Terminal
3. `swift build`