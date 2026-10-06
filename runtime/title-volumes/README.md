# Per-title writable volumes

Author: Timur Isaev

An Apple SDK-only Swift library and local CLI for game-owned state. Saves and
settings have stable, title-bound identities; cache epochs and session scratch
have separate lifetimes. No runtime-generation deletion can cascade through this
registry. No guest, XPC, UI, cloud integration or diagnostic upload is included.

```sh
swift test --package-path runtime/title-volumes
swift run --package-path runtime/title-volumes alloy-volumes init /private/tmp/my-volumes example-game
swift run --package-path runtime/title-volumes alloy-volumes list /private/tmp/my-volumes example-game
```

Use a canonical absolute root with no symlink components (`/private/tmp`, not
`/tmp`). The parent must already exist. New directories are 0700 and files 0600.
The root can be shared with `AlloyContentStore`; this library owns only
`metadata/title-volumes/` and its registered `volumes/<game-id>/` state.

The CLI also supports `audit ROOT GAME`, `scratch-create ROOT GAME SESSION NOW`,
and `scratch-expire ROOT GAME NOW`. Times are explicit Unix seconds. Library
errors are named, including quota, path, integrity, conflict and registry errors.
Older content-store save-only titles can be explicitly imported with
`adopt-legacy-saves ROOT GAME`; stop legacy writers first. The operation preserves
bytes and tightens owned permissions, refusing unsafe links or extra state.

See [the layout contract](Specs/LAYOUT_V1.md) for ownership and concurrency.
See [save operations](Specs/SAVES_V1.md) for explicit backup/restore commands,
conflict handling, periodic policy and the required quiet write boundary.
See [settings and disposable state](Specs/STATE_V1.md) for versioning, resets,
cache identity inputs and scratch recovery.
The [session-launch handoff](Specs/CONSUMER_HANDOFF.md) defines the C/G/S/T plan,
six compiler volume IDs, lease boundaries and integration responsibilities.
