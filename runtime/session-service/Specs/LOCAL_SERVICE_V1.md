<!-- Author: Timur Isaev -->

# Local runtime API v1

The Swift `AlloyRuntimeAPI` package owns the public request/response types and
`RuntimeClient`. XPC's exported Objective-C protocol exchanges `Data`; within it,
a versioned Codable envelope contains a method and a base64 Codable `Data`
payload. The typed client checks response version and request identity. The CLI
renders the payload as ordinary JSON for inspection. Calls block for at most
30 seconds and belong on a worker thread, never the client UI thread.

## Boundary

The current development service advertises a unique
`com.alloy.development.<random>` Mach service through a temporary user launchd
job. This follows Apple's
[NSXPCListener contract](https://developer.apple.com/documentation/foundation/nsxpclistener/init%28machservicename%3A%29).
A future app can use the same client contract while owning its service lifetime.
No global persistent service or root helper is installed by this package.

The listener checks the kernel-supplied effective UID and valid peer PID; it does
not trust a UID in a request. The router repeats the UID check and requires the
256-bit random capability from a 0600 regular, non-symlink endpoint file under
a 0700 owner-only directory. Requests carry that capability only over local XPC.
Configuration directories are owner-only, non-symlink final entries; filesystem
canonical paths prevent aliased or nested state/content roots. macOS's `/var`
and `/private/var` aliases are legitimate. Hostile concurrent filesystem
mutation and malicious same-UID code able to read the capability are outside
this development boundary; it is not a code-signing or sandbox authorization
claim. The proof uses a wrong capability from an actual peer; another UID is
covered by the router unit test without creating users or invoking sudo.

Application request/reply envelopes are capped at 4 MiB. This is checked before
JSON decoding and before reply publication, not a claim about kernel/XPC queue
allocation. Requests require API version 1, a nonempty ID at most 128 UTF-8 bytes
and a deadline within 30 seconds (one second forward-clock tolerance). Expired
requests, unknown methods, invalid JSON and unsupported versions fail with stable
codes. The client bounds its wait and checks identity; a timeout does not prove
that a future mutating method did not execute. Such methods must use durable
idempotency keys. Unknown envelope fields are ignored as optional v1 extensions;
new required semantics require a new supported version.

## Initial method

`info` takes `{}` and returns `ServiceInfo`: instance UUID, protocol version,
service PID/UID, supported methods and capability booleans. PID is informational;
it never authorizes a session or lease. Every restart creates a new instance UUID.
`developmentOnly` is true and `gameLaunchAvailable` is false.

Replies contain a stable code, message key, support code and retryable bit.
Boundary errors do not echo arbitrary input, paths, credentials or underlying
exception strings. Raw diagnostic capture must keep these same constraints.

The existing profile compiler's `runtimeReady == false` and `notYetLowered`
fields are authoritative. No milestone may silently reinterpret its development
export as a complete Wine policy or permit a real game launch from it.
