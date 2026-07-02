# allonet2 project brief

Project delta to the generic Managed Agent Loop protocol. allonet2 is Alloverse's
reference API + protocol implementation — a Swift Package (macOS/iOS/visionOS), NO
Supabase stack (the loop's own Patch backend is unrelated). Read `MEMORY.md` and
`README.md` first (their notes are load-bearing).

## Verify (the merge gate)

`verify.sh` is the gate:
- `git submodule update --init --recursive` — `Packages/AlloDataChannel` is a submodule; a
  bare worktree has it empty until initialized (provision + reset do this too).
- `swift build` then `swift test`.
- First build pulls `webrtc-xcframework` (a large binary dependency) — provision warms it so
  the gate runs incrementally after.

## Merge convention

Atomic commits, module named in parentheses in the subject, body explains why/how (per the
Koja/Alloverse CLAUDE.md house style). `gh pr merge <n> --merge` (no squash), branch off `main`.

## Gotchas

- Submodules use mixed SSH/HTTPS remotes; the host needs git access to them.
- Some products target visionOS/iOS; the gate builds+tests on macOS. For observable changes,
  use #Previews / an Xcode MCP if one is wired on the host (see the roadmap).
- Keep `MEMORY.md` updated (under 100 lines) as you learn things.
