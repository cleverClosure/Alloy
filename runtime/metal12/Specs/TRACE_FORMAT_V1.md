<!-- Author: Timur Isaev -->

# Alloy Metal12 trace format 1.0

## Purpose and scope

Trace 1.0 is a self-contained recording of calls made through the first
Metal12 public command surface. It stores logical object identifiers, resource
descriptors and caller-provided bytes, the compiled metallib, and the ordered
commands needed to reproduce the output. It stores no process pointer,
Objective-C object identity, source path, wall-clock timestamp, or scene code.

The format is a little-endian binary TLV stream. There is no JSON manifest and
therefore no separate schema.

## File header

All integers are unsigned little-endian values.

| Offset | Bytes | Field | Required value |
| ---: | ---: | --- | --- |
| 0 | 8 | Magic | ASCII `AM12TRC1` |
| 8 | 2 | Major | `1` |
| 10 | 2 | Minor | `0` |
| 12 | 4 | Header size | `20` |
| 16 | 4 | Byte-order marker | `0x01020304` |

A reader accepts exactly version 1.0 and rejects a different version, header
size, or byte-order marker. Version 1 readers do not guess.

## Record header

Every record immediately follows the prior payload:

| Bytes | Field |
| ---: | --- |
| 2 | Opcode |
| 2 | Flags; zero in version 1 |
| 4 | Payload byte count |
| N | Payload |

The payload must fit entirely inside the file. A reader rejects truncation,
unknown opcodes, nonzero unsupported flags, duplicate or undeclared logical
identifiers, invalid string lengths, invalid resource ranges, and state
transitions whose recorded `before` state does not match replay state.

## Version 1 opcodes

Fixed structures use the field order shown and contain no padding.

| Opcode | Name | Payload |
| ---: | --- | --- |
| 1 | Device | `u32 width, u32 height, u32 frameCount` |
| 2 | Metallib | Complete metallib byte blob |
| 3 | Create texture | `u32 resource, u64 placedSize`; v1 texture is the device-sized RGBA8 render target |
| 4 | Create buffer | `u32 resource, u64 size`; all bytes initialize to zero |
| 5 | Write resource | `u32 resource, u64 offset, u64 size, u8 contents[size]` |
| 6 | Create pipeline | `u16 vertexNameSize, u16 fragmentNameSize`, then the two un-terminated UTF-8 names; the metallib is opcode 2 |
| 7 | Create CBV | `u32 slot, u32 resource, u32 generation` |
| 8 | Set root table | `u32 slot, u32 generation` |
| 9 | Begin frame | `u32 zeroBasedFrameIndex` |
| 10 | Transition | `u32 resource, u32 beforeState, u32 afterState` |
| 11 | Clear target | `u32 resource, f32 red, f32 green, f32 blue, f32 alpha` |
| 12 | Draw | `u32 resource, u32 vertexCount, u32 instanceCount`; v1 requires exactly `3, 1` |
| 13 | Copy texture to buffer | `u32 source, u32 destination` |
| 14 | Present | `u32 source` |
| 15 | End frame | Empty |
| 16 | Output | `u32 readbackResource` |

Resource identifiers are monotonically assigned starting at one and must be
declared before use. Descriptor generations are monotonically assigned and
must match exactly. Buffer contents are copied into opcode 5 at call time, not
referenced indirectly.

Output-only textures have no fictitious initial-content snapshot. Their
defining clear, draw, copy, and present commands are the content record.

## Canonical order and resource bounds

Preflight validates the entire stream before replay writes the embedded
metallib, creates a Metal device, or allocates a replay resource. The device
record must be first, the metallib second, and the single output declaration
last. Resource identifiers are contiguous from one, resource and pipeline
creation precedes the first frame, frame indices are contiguous from zero, and
every begun frame contains a draw and one present before it ends. The number of
ended frames must equal the device declaration.

Version 1 has these fail-closed limits:

| Quantity | Limit |
| --- | ---: |
| Complete trace | 256 MiB |
| Embedded metallib | 64 MiB |
| Records | 1,000,000 |
| Width or height | 16,384 |
| RGBA image footprint | 256 MiB |
| Frames | 10,000 |
| Draw work per record | 3 vertices, 1 instance |
| Logical resources | 63 |
| Descriptor slots | 256 |
| Barrier-model accesses per frame | 32; draw, copy, and portable present each reserve 2 |
| One pipeline entry name | 1,024 bytes |
| One shared buffer and all shared buffers combined | 256 MiB |
| Placed textures combined | 64 MiB |

All payload, range, row-pitch, image-size, and bitmap-size arithmetic is
checked before use. Preflight also verifies fixed payload sizes, zero flags,
known opcodes, resource kinds and states, buffer ranges, descriptor
generations, finite clear colors, draw prerequisites, copy extent, and defined
output contents.

## Determinism

The writer emits records synchronously in public-call order. The format
contains no timestamp, random identifier, path, or host address. Two captures
of identical calls, inputs, and metallib bytes must be byte-identical.

Capture is observational: enabling it may add CPU I/O time, but it must not
change resource contents, command ordering, or the final image digest.
Capture writes to an exclusive temporary sibling of the destination.
`AM12FinishCapture` flushes and synchronizes it, always attempts `fclose`, and
performs the same complete preflight used by replay before it atomically
publishes with `rename`; a partial or invalid capture does not replace an
existing destination. Destruction with an active frame or no output
declaration closes and removes the temporary sibling. Buffer creation
zero-initializes every byte, so partial writes remain deterministic.

## Replay and compatibility boundary

A replayer performs the complete, side-effect-free structural and semantic
preflight first. Only an accepted trace proceeds to private temporary
metallib storage, Metal device creation, logical-resource reconstruction, and
the same public command functions used by a live client. A generic replayer
must not compile or link the original scene.

Embedding the metallib makes a trace self-contained, not universally portable.
Version 1 evidence is scoped to a compatible Apple GPU, OS, and Metal compiler
epoch. Cross-epoch portability requires a future artifact-compatibility
contract or a versioned shader interchange representation.
