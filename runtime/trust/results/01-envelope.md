# Envelope milestone evidence

Author: Timur Isaev

6 October 2026, Apple Silicon, Xcode macOS 27 SDK. Three Swift tests passed:
independent known answers; distinct-key threshold and type/payload binding;
malformed and noncanonical inputs. Node/OpenSSL independently verified the
committed signature, canonical payload and PAE, and rejected a changed message.
The vector has no private key. Test signing keys are generated in memory.

The initial sandboxed build could not write Xcode's module cache; the same
command with cache access passed. No runtime/shared Wine tree was used.
