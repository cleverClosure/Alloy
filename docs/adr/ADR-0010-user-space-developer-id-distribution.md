# ADR-0010: Distribute as a User-Space Developer ID Application Without Kernel Extension

**Status:** Accepted  
**Date:** 20 July 2026  
**Decision owners:** CTO, Security, Client Platform  
**Related requirements:** RUN-012, NFR-SEC-001, NFR-SEC-002

## Context

The runtime executes user-installed Windows binaries and needs dynamic code generation and scoped game-directory access. Mac App Store constraints are unlikely to fit the initial runtime. Kernel extensions or persistent root daemons expand risk and deployment friction.

## Decision

Distribute outside the Mac App Store using Developer ID signing, notarization, Hardened Runtime, minimum JIT/dynamic-code entitlements, a per-user daemon, and scoped user-approved permissions. Do not install a kernel extension or persistent root daemon.

## Rationale

The model supports required execution while preserving least privilege and mainstream Mac installation expectations.

## Consequences

### Positive

- Smaller attack surface.
- No reboot or system-extension approval.
- Easier uninstall.
- Clear user-level data ownership.
- Compatible with the signed update model.

### Negative / cost

- Some isolation controls available only to App Sandbox may require custom brokerage.
- JIT entitlement and notarization require careful design.
- No kernel-driver anti-cheat.
- System-wide optimizations are unavailable.

## Alternatives considered

1. **Mac App Store:** likely incompatible with runtime, dynamic-code, and file behavior.
2. **Privileged daemon:** unnecessary for core use.
3. **Kernel/system extension:** rejected unless a future separate capability has overwhelming value and security approval.
4. **Full VM:** a different product.

## Validation and implementation notes

Install under a standard user account, audit entitlements/binaries, run JIT W^X tests, revoke folder grants, uninstall cleanly, and pass notarization/Hardened Runtime checks.

## Revisit triggers

Only if Apple platform policy changes or a narrowly scoped capability cannot be delivered safely in user space. Such a change requires a new security architecture and PRD approval.
