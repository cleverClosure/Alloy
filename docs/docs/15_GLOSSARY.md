# MGCR Glossary

**Version:** 1.0  
**Date:** 20 July 2026

---

## Product and compatibility

**Certified Mode** — Locked, signed, tested runtime state eligible for the strongest product support and approved vendor integrations.

**Competitive Certified** — Certified state plus explicit publisher and anti-cheat/vendor authorization for a defined multiplayer scope.

**Custom Mode** — Isolated user-modifiable runtime state that does not carry Certified guarantees.

**Certification stale** — A prior certification whose exact build, host, component, or evidence-age requirements no longer match.

**Compatibility profile / Game Profile** — Signed declarative object selecting runtime generation, build/host scope, process policies, dependencies, health checks, limitations, and certification.

**Compatibility evidence graph** — Relationships among exact game/launcher/host/runtime/profile changes, tests, results, regressions, fixes, and releases.

**Game runtime generation** — Immutable runtime component composition selected for an exact game/host/profile combination.

**Known limitation** — User-relevant behavior that remains outside the certified scope and is explicitly disclosed.

**LaunchSpecification** — Immutable local result of resolving game build, host class, runtime generation, profile, policy snapshot, volumes, grants, and certification for one session.

**Modern baseline** — MGCR's certified scope floor: x64-only guest executables (WoW64 permitted only for auxiliary helper processes), Direct3D 10/11/12 and Vulkan renderers, Windows 10+ guest OS, storefront-managed installs, a 16 GB certified memory floor, and a rolling current-plus-previous-major macOS host window (ADR-0011).

**Playable** — Certification level in which a defined gameplay path passes with disclosed limitations.

**Policy snapshot** — Compiled read-only representation of a profile used on the process startup hot path.

**Support unit** — The smallest product identity to which compatibility and rollback promises apply; in MGCR, the runtime generation for an exact game/host selection.

**Workaround** — Scoped deviation from default behavior with owner, rationale, evidence, and review/removal condition.

## Runtime and storage

**Bottle / Wine prefix** — Mutable Wine environment with Windows-like filesystem and registry. MGCR does not expose it as the primary support abstraction.

**CAS (content-addressed store)** — Storage in which objects are named by cryptographic digest.

**Derived cache** — Rebuildable data such as shader/PSO or CPU translation cache, keyed by all correctness-affecting inputs.

**Generation activation** — Atomic update of the active reference from one complete runtime generation to another.

**Host capability class** — Stable normalized identity for architecture, macOS build/capabilities, Apple GPU family/features, memory class, and relevant native services.

**Immutable layer** — Verified read-only runtime object, such as host, Wine, dependency, or profile layer.

**Materialization** — Construction of a launchable runtime view from immutable layers and explicit writable volumes.

**Object lease** — Temporary reference preventing a CAS object from being collected during an operation/session.

**Rollback generation** — Retained last-known-good runtime generation available for atomic reactivation.

**Save volume** — Persistent protected storage for game progress, separate from runtime generations and disposable caches.

**Session scratch** — Temporary per-session writable storage that may be deleted after clean completion.

## Windows compatibility

**ARM64EC** — Windows ABI that permits ARM64 code to interoperate with x64-oriented modules and calling conventions.

**COM** — Windows Component Object Model.

**DLL override** — Policy selecting builtin, native, disabled, or precedence behavior for a Windows DLL. Hidden from default users.

**PE** — Windows Portable Executable format.

**Wine** — Open-source implementation of Windows user-mode APIs on non-Windows hosts.

**Wineserver** — Wine process that coordinates Windows object/process semantics.

**WoW64** — Windows-on-Windows architecture for running 32-bit Windows code in a 64-bit environment. In MGCR, WoW64 is permitted only for auxiliary helper processes (launcher, installer, DRM helper) that a supported x64 title requires; 32-bit game executables are out of certified scope (ADR-0011).

## CPU execution

**CPU ExecutionProvider** — Versioned interface used to execute guest x86/x64/ARM64EC code.

**FEX** — Open-source x86/x64-to-ARM64 binary translation project used as the preferred production starting point.

**Guest** — Windows code and its virtual Windows-visible environment.

**Host** — macOS and first-party native ARM64 runtime.

**JIT** — Just-in-time translation/compilation of guest instructions or shaders.

**Translated code cache** — Persistent version-keyed cache of host ARM64 blocks derived from guest binaries.

**W^X** — Memory discipline requiring pages to be writable or executable, but not both simultaneously.

## Graphics

**Argument buffer** — Metal resource-binding mechanism used as part of descriptor virtualization.

**Barrier compiler / optimizer** — Metal12 subsystem that converts D3D12 resource state and synchronization semantics into correct Metal scheduling and hazards.

**D3D / Direct3D** — Microsoft Windows graphics APIs. MGCR certifies Direct3D 10/11/12 and Vulkan (via MoltenVK) only; Direct3D 9 and earlier, DirectDraw, and OpenGL are out of certified scope and the profile schema does not admit them (ADR-0011).

**Descriptor heap** — D3D12 application-visible collection of descriptors; virtualized over Metal resource binding.

**Device loss** — Condition in which graphics execution can no longer continue and the D3D device must report removal/error.

**DXBC / DXIL** — DirectX shader bytecode/intermediate formats.

**DXGI** — Windows graphics infrastructure for adapters, outputs, swap chains, and presentation.

**DXMT** — Metal-native Direct3D 10/11 implementation used as a starting point for the D3D11 path.

**Feature mask / capability preset** — Exact guest-visible graphics features and scoped deviations selected for a game/host/provider.

**GfxIR** — Compact internal command/state representation used by Metal12.

**Metal12** — Working name for MGCR’s owned Direct3D 12-to-Metal provider.

**MoltenVK** — Vulkan implementation over Metal used for games that expose Vulkan directly where certified.

**PSO (pipeline-state object)** — Compiled combination of shaders and graphics/compute state.

**Residency** — Policy deciding which graphics resources remain available under memory budgets/pressure.

**Root signature** — D3D12 definition of shader resource-binding layout.

**Shader prewarming** — Compiling likely shaders/PSOs before latency-sensitive gameplay.

**Swap chain** — Presentation object managing renderable images and display.

**Unified memory** — Apple-silicon architecture in which CPU and GPU share physical memory, requiring a Windows-compatible virtual budget and explicit pressure policy.

## Native services

**CoreAudio** — macOS audio framework.

**GameController** — Apple framework for supported controllers.

**HID** — Human Interface Device protocol used for input devices.

**Media Foundation** — Windows multimedia framework used by games and launchers.

**Metal I/O** — Apple storage-to-GPU-oriented API family considered for advanced storage paths.

**VideoToolbox** — Apple video encode/decode framework.

**XAudio2 / WASAPI** — Windows game audio and audio-device APIs.

**XInput / DirectInput / Raw Input** — Windows input APIs with different device and event semantics. XInput/GameInput-class controllers and Raw Input are certified scope; DirectInput-era input remains whatever upstream Wine provides and is permanently uncertified (ADR-0011).

## Certification and testing

**Canary** — Restricted production release ring used to observe a candidate before stable promotion.

**Differential test** — Test comparing MGCR-observable behavior with a native Windows reference.

**Evidence matrix digest** — Cryptographic identity of the certification matrix and results.

**Host matrix** — Set of macOS/GPU/memory/display/input capability classes required by a test plan.

**Reference oracle** — Native Windows run used to establish observable behavior.

**Scenario** — Versioned deterministic or structured test journey, such as install, launch, save/load, or gameplay scene.

**Stutter event** — Frame-time stall exceeding the title/scenario threshold; measured separately from average FPS.

**Test plan** — Versioned definition of prerequisites, scenarios, metrics, artifacts, and pass policy.

## Security and release

**Attestation / provenance** — Signed statement binding source, build recipe, builder, inputs, and output artifact.

**DSSE** — General signed-envelope pattern binding signatures to typed payloads.

**Hardened Runtime** — macOS code-signing security configuration.

**Release ring** — Development, lab, canary, stable, or quarantined eligibility state.

**Revocation** — Signed instruction preventing future selection of a compromised or unsafe artifact/profile.

**SBOM** — Software bill of materials.

**TUF** — Role-based signed metadata design for secure software updates.

**XPC** — macOS interprocess communication framework used for typed local service boundaries.

## Operations and data

**Certified Successful Play Hours (CSPH)** — Product metric counting play time from exact certified sessions that reached gameplay and avoided severe platform failures.

**Correlation ID** — Stable identifier linking operations, sessions, processes, providers, and optional cloud evidence.

**Diagnostic bundle** — User-previewed, privacy-filtered local package containing session identity and relevant failure evidence.

**Idempotency key** — Identifier allowing a mutating operation to be retried without duplicate side effects.

**Operation journal** — Crash-recovery record for long-running local mutations.

**Quarantine** — Release state in which a candidate/artifact/profile is not selected for new stable sessions.

**SLO / SLI** — Service-level objective and the measured indicator supporting it.

## Partnership

**Publisher design partner** — Publisher collaborating on private builds, tests, findings, and release scope.

**Runtime integrity measurement** — Signed, fresh, scoped statement of selected runtime/profile/provider and modification state for an approved vendor integration.

**Tenant isolation** — Cloud controls preventing one publisher from accessing another publisher’s builds, symbols, reports, or metadata.
