# Alloy Store Identity

**Author:** Timur Isaev

`AlloyStoreIdentity` is the read-only build-identity package for installed
storefront titles. Its first contract promotes the STORE-001 fingerprint from a
one-off spike artifact into a versioned record and a deterministic Swift
scanner.

## Boundary

The package observes an installation; it does not manage one. It may read the
caller-selected game directory and metadata supplied by the caller. It must
never write, rename, delete, lock, or change metadata in that directory or in a
Steam library. It does not launch or automate Steam, use credentials, invoke
depot tooling, or access the network.

The scanner follows neither file nor directory symlinks. It includes hidden
regular files and skips all non-regular filesystem objects. A scan that cannot
establish a stable before-and-after view is refused instead of emitting a
possibly mixed-build identity.

## Fingerprint v1

[`Specs/FINGERPRINT_V1.md`](Specs/FINGERPRINT_V1.md) is the normative contract.
[`Specs/fingerprint.v1.schema.json`](Specs/fingerprint.v1.schema.json) fixes its
persisted JSON shape. The v1 record preserves the existing STORE-001 anchor:

- Steam app, build, and depot-manifest identifiers;
- every included relative path, byte size, and SHA-256 digest;
- exact file count and total bytes; and
- a SHA-256 aggregate over the ordered file records.

The canonical serializer produces compact UTF-8 JSON with lexically sorted
object keys, unescaped slashes, and one trailing line feed. Decoding the
historical anchor and serializing it canonically changes presentation only; the
decoded fingerprint value is exactly preserved.

## Layout

```text
runtime/store-identity/
├── Package.swift
├── Sources/AlloyStoreIdentity/
├── Specs/
│   ├── FINGERPRINT_V1.md
│   └── fingerprint.v1.schema.json
├── Tests/
└── run-fingerprint-parity.sh
```

Later store-identity gates add the metadata parser, watcher, selector registry,
and crash-safety proofs without changing the v1 fingerprint contract.

## Verification

Gate 1 is fixture-only and does not require or inspect a live Steam library:

```sh
swift test --disable-sandbox --package-path runtime/store-identity
runtime/store-identity/run-fingerprint-parity.sh
spikes/STORE-001/steam-readonly/steam-automation-gate.sh
```

The parity proof compares the Swift scanner with both known fixture values and
the historical `tools/steam-fingerprint.py` calculation. Agreement is required
for every file digest and for the aggregate.

## Defensive Steam metadata parsing

The dependency-free parser consumes caller-supplied appmanifest bytes in
memory. It accepts valid UTF-8 only, rejects duplicate keys, parses unsigned
sizes without truncation, and enforces explicit input, nesting, and quoted-token
limits. It performs no storefront discovery or writes.

Every hostile metadata case is paired with the unchanged clean fixture in the
same test invocation:

```sh
runtime/store-identity/run-metadata-parser-proof.sh
```

## Update detection

Gate 3 compares a trusted fingerprint anchor with caller-supplied Steam
metadata and a newly observed fingerprint. It reports metadata, depot, and file
changes separately and names the build whose evidence has been superseded.
Discovery, scheduling, persistence, and storefront writes remain outside this
pure comparison boundary.

The focused proof stages manifest and fingerprint copies derived from the
committed Sir Brante anchor in isolated scratch directories. Each simulated
update or refusal runs only after an unchanged observation returns no detection:

```sh
runtime/store-identity/run-update-watcher-proof.sh
```

## Selector registry and invalidation records

Gate 4 binds promoted evidence to one exact storefront app, build, depot
manifest set, aggregate, and executable-image digest. The committed selector
registry names the existing fingerprint, title-scene result, and launch-policy
artifacts by path and SHA-256 without changing those historical artifacts.

A detected update emits one canonical invalidation record naming every selector
bound to the superseded build. Repeating the same observation is idempotent:
the record identifier and bytes stay fixed and no duplicate file is created.
An unchanged observation produces no record or output file.

```sh
runtime/store-identity/run-selector-invalidation-proof.sh
```

## Self-tested watcher and crash convergence

Gate 5 requires a deterministic scratch perturbation to pass before every real
observation. The production scanner reads an unchanged four-byte `probe.bin`
control, then a copy with exactly one changed byte; the detector must report
that exact game-only delta. A dead or miswired detector refuses the run before
observation. Scratch state is removed after success and every handled failure.

Invalidation publication syncs canonical temporary bytes before atomically
publishing the final record. Reruns reconcile exact stale temporary links,
concurrent emitters converge to one record, and symlink or non-regular targets
are refusals. The fault matrix kills the probe at each publication boundary and
requires a clean rerun to converge without duplicate or partial records.

```sh
runtime/store-identity/run-fault-matrix.sh
```

## Live read-only observation

`AlloyStoreIdentityCLI` is the one-shot production entry point for comparing a
current installed title with a trusted fingerprint anchor. It strictly decodes
the anchor and selector registry, runs the detector self-test before observing
the installation, and refuses an unstable or internally inconsistent view.

The command has one subcommand and five required options:

```sh
AlloyStoreIdentityCLI observe \
  --library-root PATH \
  --app-id APP_ID \
  --anchor PATH \
  --registry PATH \
  --state-root PATH
```

Its exact one-line usage is:

```text
usage: AlloyStoreIdentityCLI observe --library-root PATH --app-id APP_ID --anchor PATH --registry PATH --state-root PATH
```

The state root must be caller-selected and outside the observed Steam library.
The command never rewrites the anchor, registry, manifest, or installed game.
An unchanged observation creates no invalidation JSON and prints exactly:

```text
STATUS appid=<APP_ID> update=unchanged self_test=PASS invalidation=none
```

A changed observation publishes or reuses one deterministic invalidation
record beneath only the selected state root and prints exactly:

```text
STATUS appid=<APP_ID> update=changed self_test=PASS created=<true|false> id=<sha256:...> superseded=<buildid> observed=<buildid>
```

Repeated observation of the same changed build reuses the same identifier and
canonical bytes. Duplicate or unknown options, missing options or values,
unexpected subcommands, and trailing positional arguments are refused. A
refusal writes one `ERROR <message>` line to standard error and exits with
status 1.

The fixture proof invokes both CLI success directions against isolated
synthetic libraries. It requires the exact unchanged line with no invalidation,
then requires one canonical changed invalidation and a byte-identical
`created=false` reuse. It also proves four argument refusals, noncanonical
registry refusal, unsafe `installdir` refusal, manifest and install-root symlink
refusals, disjoint state-root enforcement in both directions, detector
self-test execution, and byte-identical inputs:

```sh
runtime/store-identity/run-cli-fixture-proof.sh
```

The full package tests and earlier focused proofs independently cover changed
detection, selector invalidation, idempotent canonical publication, model and
parser refusals, and crash convergence.

`tools/steam-fingerprint.py` remains the historical fingerprint and parity
reference. Live production observation uses `AlloyStoreIdentityCLI`.
