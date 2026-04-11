# ProxyJump Analysis: v0.12.0 Native vs Blink's Current Approach

## Status (2026-05-01)

**Option A is what shipped in `patches-v0.12.0` (commit `180edcde`, Patch 04).**

The selector path was forced rather than env-var-gated: `ssh_libssh_proxy_jumps()` in
`src/misc.c` now hard-returns `false`, so `ssh_config_parse_proxy_jump()` always
synthesizes a ProxyCommand line, which routes through the
`set_proxycommand_function` callback. No environment variable to set, no chance of a
host application forgetting it.

Companion changes also in Patch 04:
- `ssh_socket_connect_proxycommand` was restructured so the callback path always
  compiles (even with `WITH_EXEC=OFF`), and falls cleanly to `SSH_ERROR` if no callback
  is registered. The `WITH_EXEC` fork/exec branch is gated, and `thread_ssh_execute_command`
  / `ssh_execute_command` are likewise gated behind `WITH_EXEC`.
- `client.c` no longer wraps the proxycommand call in `#ifdef WITH_EXEC` — the call site
  always compiles; only the body branches.

Option B (application-level jump connections via `SSH_OPTIONS_FD`) and the matching
`ssh_socket_set_fd` two-line fix described at the bottom of this doc are **deferred**.
They remain the recommended long-term direction but were not needed to ship 0.12.0.

The native v0.12.0 ProxyJump path (`ssh_socket_connect_proxyjump` + `jump_thread_func`)
is unreachable but still compiled — Q1/Q2 from the original review are resolved by the
selector flip rather than by patching the dispatch path.

---

## How v0.12.0 Implements ProxyJump Natively

v0.12.0 added a complete native ProxyJump implementation:

1. **Thread-based**: Spawns a detached pthread (`jump_thread_func`)
2. **Nested session**: Creates a fresh `ssh_session` for the jump host
3. **Socket pair**: `socketpair()` bridges main thread ↔ proxy thread
4. **Connector forwarding**: Uses `ssh_connector` + `ssh_event_dopoll()` to relay
   data between the socketpair fd and an `ssh_channel_open_forward()` tunnel
5. **Callback hooks**: `ssh_jump_callbacks_struct` with:
   - `before_connection(session, userdata)` — configure the jump session before connect
   - `verify_knownhost(session, userdata)` — custom host key verification
   - `authenticate(session, userdata)` — custom auth (default: `ssh_userauth_publickey_auto`)
6. **Chaining**: Remaining jumps are moved to the nested session, which recurses

```
Main Thread (dispatch/RunLoop)         Proxy Thread (pthread)
┌─────────────────────┐                ┌──────────────────────────┐
│ ssh_session (main)   │                │ ssh_session (jump)        │
│ socket fd = pair[1] ←┼── socketpair ──┼→ connector ↔ fd pair[0]  │
│ dispatch IO          │                │ ssh_channel_open_forward  │
│                      │                │ ssh_event_dopoll() loop   │
└─────────────────────┘                └──────────────────────────┘
```

## Why v0.12.0 Native ProxyJump CANNOT Work With Dispatch Mode

There are **two fundamental blockers**:

### Blocker 1: Main thread side — poll handle is NULL

`ssh_socket_connect_proxyjump()` at line 1986 (socket.m) does:
```c
h = ssh_socket_get_poll_handle(s);   // Returns NULL in dispatch mode!
if (h == NULL) {
    return SSH_ERROR;                 // ← Fails here
}
ssh_socket_set_connected(s, h);
```

In dispatch mode, `ssh_socket_get_poll_handle()` always returns NULL because the
dispatch path uses the `IO` Objective-C class, not poll handles. **ProxyJump would
fail immediately with SSH_ERROR.**

This is fixable — we'd need a dispatch-mode path in `ssh_socket_connect_proxyjump()`
that sets up the IO/NSStream objects for `pair[1]` instead of a poll handle.

### Blocker 2: Jump thread session — no RunLoop

The jump thread calls `ssh_connect(jump_session)`. Since `HAVE_DISPATCH_H` is a
compile-time flag, the jump session will also try to use dispatch/RunLoop mode.
But the jump thread is a plain pthread — it has no RunLoop.

The jump session's socket would try to create NSStream/CFSocket objects and schedule
them on a RunLoop that doesn't exist. Everything after `ssh_connect()` would break.

Even if we created a RunLoop on the jump thread, the thread then runs
`ssh_event_dopoll()` (poll-based), not a RunLoop event loop. The two models are
fundamentally incompatible within the same thread.

## How Blink Currently Handles ProxyJump

Blink's approach (with the old v0.9.8 patches):

1. User configures `ProxyJump` in Blink's host settings
2. Blink passes it to libssh via `SSH_OPTIONS_PROXYJUMP`
3. In v0.9.8 (old patch), libssh converts ProxyJump → ProxyCommand string:
   `ssh -l user -p port -W '[%h]:%p' hostname`
4. libssh calls `set_proxycommand_function` callback
5. Blink's callback (`SSHClient.swift:275`) receives the command string
6. Blink executes it via `ios_system()` in the shell environment

This works because:
- The proxy connection is an external SSH process, not a nested libssh session
- No threading conflict with dispatch/RunLoop
- Authentication happens in the external SSH process
- BUT: requires `ios_system` and a shell-level SSH for the jump

## Options Going Forward

### Option A: Keep the ProxyCommand Callback Approach

**How:** In v0.12.0, when `HAVE_DISPATCH_H` is defined, convert ProxyJump back into
a ProxyCommand string and use the callback.

v0.12.0 has a runtime selector for this: `ssh_libssh_proxy_jumps()` in `src/misc.c`
returns `false` when `OPENSSH_PROXYJUMP=1` is set in the environment, which triggers
the ProxyCommand path in `ssh_config_parse_proxy_jump()` (config.c:599-620).

**What we shipped:** rather than relying on the env var, Patch 04 makes
`ssh_libssh_proxy_jumps()` hard-return `false` unconditionally. This removes the
runtime dependency and guarantees the ProxyCommand callback path is taken regardless
of the host application's environment.

**Pros:**
- Known working approach from v0.9.8
- No changes to Blink's Swift code
- No threading/RunLoop issues

**Cons:**
- Depends on `ios_system` and external SSH binary for jump
- Doesn't leverage native libssh connection (extra process overhead)
- Need to keep the `set_proxycommand_function` callback patch

**Implementation (chosen):** Modify `ssh_libssh_proxy_jumps()` to return `false`
unconditionally — see `src/misc.c` in Patch 04 (`180edcde`). Hard-return rather than
HAVE_DISPATCH_H gating keeps it simple: there is no scenario in this fork where the
native pthread-based ProxyJump is desired.

### Option B: Make Blink Handle Jump Connections at the Application Level

**How:** Blink already manages SSH connections via `SSHClient`/`SSHPool`. Instead of
letting libssh handle ProxyJump internally, Blink would:

1. Parse the ProxyJump chain itself (or extract it from the config)
2. Create a first `SSHClient` connection to the jump host (full Blink connection with
   dispatch, agent, keys, etc.)
3. Open a port-forward channel on the jump connection
4. Pass the channel's fd (or a socketpair wired to it) to the main `SSHClient` via
   `SSH_OPTIONS_FD`
5. The main session connects over that fd

**Pros:**
- Full control over jump host authentication (Blink keys, SE keys, agent)
- Full control over jump host config (Blink host settings, not just ssh_config)
- Each connection uses dispatch/RunLoop natively
- No external process needed
- Supports Blink-specific features on jump hosts (connection pooling, etc.)
- Clean architecture — no libssh patching needed for proxy

**Cons:**
- Significant new code in Blink's SSH layer
- Must handle chained jumps (A → B → C) recursively
- Must manage jump connection lifecycle (keep alive, reconnect, cleanup)
- Config resolution challenge: Blink has its own host database, and needs to resolve
  jump host settings from it (not from ssh_config)

**Config resolution challenge (your concern):**
The jump host name from ProxyJump (e.g., "bastion") needs to be resolved to a full
connection config (hostname, port, user, keys, etc.). Currently:
- Blink's host DB (`BKHosts`) stores per-host configs
- `ssh_config` is generated from BKHosts
- The jump host name might be a Blink alias or an ssh_config Host

To resolve this, Blink would need to:
1. Look up the jump host name in BKHosts first
2. Fall back to ssh_config parsing if not found
3. Build an `SSHClientConfig` for the jump host
4. This is essentially what `SSHPool.dial()` already does for any host

### Option C: Fix Dispatch Mode to Support Native ProxyJump

**How:** Make the dispatch mode work with the pthread-based ProxyJump:

1. Fix `ssh_socket_connect_proxyjump()` for the main thread side: set up the IO
   object with `pair[1]` instead of a poll handle (similar to how `ssh_socket_connect`
   sets up IO for a newly connected fd)
2. For the jump thread: make `HAVE_DISPATCH_H` a runtime flag (per-session) instead
   of compile-time, so the jump session uses poll mode while the main session uses
   dispatch
3. OR: Create a RunLoop on the jump thread, but replace `ssh_event_dopoll()` with
   a RunLoop-based forwarding loop

**Pros:**
- Uses native v0.12.0 ProxyJump without modification
- Jump callbacks for auth/knownhost customization

**Cons:**
- Very complex — requires making dispatch/poll a per-session runtime choice
- The jump thread's `ssh_event_dopoll()` connector loop is deeply poll-based
- Risk of subtle threading issues between RunLoop and poll
- Every future libssh upgrade needs to maintain this dual-mode code

## Recommendation

**Option B (application-level jump connections) is the strongest long-term choice.**

Rationale:
1. Blink already has the SSH connection machinery (`SSHClient`, `SSHPool`)
2. Blink already needs to resolve hosts from its own config — this is inescapable
   regardless of which option we choose
3. The config resolution problem you identified isn't unique to this option — even
   with the ProxyCommand callback, the external `ssh` process needs to find the
   right config for the jump host
4. With Option B, each connection in the chain is a first-class Blink connection:
   proper key management, agent support, SE keys, connection pooling
5. Eliminates the `set_proxycommand_function` callback patch and `ios_system` dependency
   for jumps
6. No libssh patching needed for proxy functionality

**However, Option A is the pragmatic short-term choice** if you want to ship the
v0.12.0 upgrade quickly without reworking the jump architecture. Just force the
OpenSSH ProxyCommand fallback in dispatch mode.

### Suggested Implementation Sketch for Option B

```swift
// In SSHClient or SSHPool
func dialWithJumps(config: SSHClientConfig) -> AnyPublisher<SSHClient, Error> {
    guard let proxyJump = config.proxyJump else {
        // Direct connection
        return SSHClient.dial(config)
    }
    
    // Parse jump chain: "bastion1,bastion2" → ["bastion1", "bastion2"]
    let jumps = parseJumpChain(proxyJump)
    
    // Build connection chain: jump1 → jump2 → ... → target
    return jumps.reduce(nil) { prevClient, jumpHost in
        let jumpConfig = resolveHostConfig(jumpHost)  // From BKHosts or ssh_config
        
        if let prev = prevClient {
            // Open port-forward on previous jump, get fd
            return prev.openForward(to: nextHost, port: nextPort)
                .flatMap { fd in
                    var targetConfig = config  // or next jump's config
                    targetConfig.fd = fd
                    return SSHClient.dial(targetConfig)
                }
        } else {
            return SSHClient.dial(jumpConfig)
        }
    }
}
```

The key piece is `resolveHostConfig(jumpHost)` — this queries BKHosts for the jump
host name, falls back to ssh_config, and builds an `SSHClientConfig`. This is the
same resolution that happens today for any `ssh` command in Blink.

## SSH_OPTIONS_FD and the Dispatch Path — The Missing Piece

Blink already implements a variation of Option B: it creates SSHClient connections for
jump hosts and wires them through ProxyCommand callbacks. The natural evolution is to
pass a pre-connected fd directly via `SSH_OPTIONS_FD` instead. However, **this path is
currently broken in dispatch mode**.

### What Happens Today

When `ssh_connect()` sees a pre-configured fd (`session->opts.fd != SSH_INVALID_SOCKET`),
it calls `ssh_socket_set_fd()` (client.c:621-623):

```c
if (session->opts.fd != SSH_INVALID_SOCKET) {
    session->session_state = SSH_SESSION_STATE_SOCKET_CONNECTED;
    ret = ssh_socket_set_fd(session->socket, session->opts.fd);
```

In socket.m, `ssh_socket_set_fd` has this dispatch path (line 979):

```objc
#ifdef HAVE_DISPATCH_H
    IO *io = (__bridge IO*)s->io;
    s->state = SSH_SOCKET_CONNECTING;
    // [io setupWithFD:fd];           ← COMMENTED OUT
#else
    // ... poll-based setup that works ...
#endif
```

The fd is stored but the IO object is never told about it. No CFSocket/NSStream is
created, no RunLoop source is scheduled. **The connection will hang — nothing reads
from the fd.**

### Why ProxyCommand Works But SSH_OPTIONS_FD Doesn't

`ssh_socket_connect_proxycommand` has a working dispatch path (socket.m ~line 1636):

```objc
#ifdef HAVE_DISPATCH_H
    IO *io = (__bridge IO*)s->io;
    ssh_socket_set_fd(s, pair[1]);
    s->state = SSH_SOCKET_CONNECTED;
    s->fd_is_socket = 0;
    [io connectedWithInFd:pair[1] fdOut:pair[1]];   // ← THIS WORKS
#else
```

`connectedWithInFd:fdOut:` creates a CFSocket with a read callback, schedules it on
the RunLoop in both default and LibSSHBlockRunLoop modes, and stores the output fd.
This is exactly what `ssh_socket_set_fd` needs to do in dispatch mode.

### The Fix

In `ssh_socket_set_fd` (socket.m), replace the broken dispatch path:

```diff
 int ssh_socket_set_fd(ssh_socket s, socket_t fd)
 {
     s->fd = fd;
 
 #ifdef HAVE_DISPATCH_H
     IO *io = (__bridge IO*)s->io;
-    s->state = SSH_SOCKET_CONNECTING;
-    // [io setupWithFD:fd];
+    s->state = SSH_SOCKET_CONNECTED;
+    [io connectedWithInFd:fd fdOut:fd];
 #else
     ssh_poll_handle h = NULL;
 
     if (s->poll_handle) {
```

This is the same `connectedWithInFd:fdOut:` call that ProxyCommand uses. It:
1. Captures the current RunLoop
2. Creates a CFSocket wrapping the fd with a read callback
3. Schedules the CFSocket source on both `NSDefaultRunLoopMode` and
   `LibSSHBlockRunLoopMode`
4. Stores the output fd for writes

### What This Enables for Blink

With this fix, Blink's Option B ProxyJump implementation becomes:

```
1. Parse ProxyJump chain from Blink's host config
2. For each jump host, resolve config from BKHosts
3. Create SSHClient to jump host (normal dispatch/RunLoop connection)
4. Open ssh_channel_open_forward() tunnel to next hop
5. Create a socketpair, wire one end to the channel
6. Pass the other end to the next session via SSH_OPTIONS_FD
7. ssh_connect() → ssh_socket_set_fd() → [io connectedWithInFd:fd fdOut:fd]
8. RunLoop picks up the fd, SSH protocol runs transparently over it
```

Each connection in the chain is a first-class Blink SSHClient with full dispatch/RunLoop
support, Secure Enclave keys, agent callbacks, and connection pooling.

### Impact on Patches

This fix belongs in **Patch 02 (Dispatch RunLoop)**. It's a 2-line change in
`ssh_socket_set_fd`. No other patches are affected. The fix also resolves the
`ssh_socket_connect_proxyjump` blocker (Q1/Q2 from REVIEW.md) — while we won't use
libssh's native ProxyJump, fixing `ssh_socket_set_fd` means any code path that sets
an fd will work correctly in dispatch mode.

---

## Summary

| | Option A (ProxyCommand CB) | Option B (App-level) | Option C (Fix dispatch) |
|---|---|---|---|
| **Effort** | Low | Medium | High |
| **Risk** | Low | Medium | High |
| **Blink features on jump** | No (external ssh) | Yes | Partial (callbacks) |
| **Config resolution** | External ssh handles | Blink resolves | libssh resolves |
| **Patches needed** | Keep callback patch | Fix ssh_socket_set_fd | Complex dual-mode |
| **Long-term** | Tech debt | Clean | Fragile |

**Option B with the `ssh_socket_set_fd` fix is the recommended path.** Blink already
does most of this work today through ProxyCommand callbacks. The fix unblocks the
cleaner `SSH_OPTIONS_FD` approach with a 2-line change in Patch 02.
