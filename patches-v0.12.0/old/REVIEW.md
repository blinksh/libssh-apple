# libssh-apple Patch Review — v0.12.0 Adaptation

Base: `libssh-0.12.0` (commit `50313883`)
Original patches: written against `libssh-0.9.8`
Adapted: 2026-04-11

---

## Overview

5 patches generated from 6 original patches. One patch dropped entirely.

| New # | Original | Name | Files | Status |
|-------|----------|------|-------|--------|
| 0001 | 01 | Apple build system | 4 | Applied cleanly with offset |
| 0002 | 02 | Dispatch RunLoop | 3 | Major adaptation needed |
| 0003 | 04 | Custom callbacks | 6 | Moderate adaptation |
| 0004 | 06 | SFTP async write | 2 | Adapted to v0.12.0 APIs |
| 0005 | 09 | Knownhosts parsing | 1 | Applied cleanly |
| — | 05 | ProxyJump | — | **DROPPED: native in v0.12.0** |

---

## Patch 0001 — Apple Build System

**Conflicts resolved:** Context line offsets in all 4 files due to upstream restructuring.

**Changes from original:**
- None — same logical changes, just updated line offsets.

**No open questions.**

---

## Patch 0002 — Dispatch RunLoop (socket + session)

This is the largest and most critical patch. It replaces poll-based I/O with
NSStream/CFRunLoop-based I/O on Apple platforms.

### Adaptation decisions

1. **socket.c → socket.m rewrite**: The v0.12.0 `socket.c` has significant new code
   compared to v0.9.8:
   - `ssh_socket_set_connected()` is a new function (not in v0.9.8)
   - `ssh_socket_connect_proxyjump()` is new (v0.12.0 native ProxyJump via pthreads)
   - `ssh_buffer_allocate()` used in `ssh_socket_pollcallback()` (new buffer API)
   - `ssh_strerror()` replaces some `strerror()` calls
   - `WITH_EXEC` preprocessor guard wraps `ssh_execute_command` and `ssh_socket_connect_proxycommand`
   - `ssh_socket_connect_proxyjump` uses pthreads for native proxyjump

   **Decision:** The new socket.m uses v0.12.0 as the base for `#ifndef HAVE_DISPATCH_H`
   blocks, preserving all v0.12.0 additions. The `#ifdef HAVE_DISPATCH_H` Objective-C code
   (IO class, NSStream, CFSocket) comes from the original patch.

2. **session.c → session.m**: Minimal changes — only adds `#ifdef HAVE_DISPATCH_H` blocks
   for `ssh_session_wait()` and dispatch-based `ssh_handle_packets()`. The rest of session.c
   is v0.12.0 code unchanged.

3. **`ssh_socket_connect_proxycommand` signature change**: v0.12.0 wraps this in `#if WITH_EXEC`
   instead of `#ifndef _WIN32`. Our patch changes the signature to accept `ssh_session` (needed
   for the proxycommand callback). This change appears in both socket.h and socket.m.

### Open questions / Review items

- **Q1: `ssh_socket_set_connected()` in dispatch mode**: This new v0.12.0 function sets up
  the poll handle for a connected socket. In dispatch mode, we don't use poll handles. The
  function is currently wrapped in `#ifndef HAVE_DISPATCH_H`. **Verify** that ProxyJump via
  `ssh_socket_connect_proxyjump()` still works — it calls `ssh_socket_set_connected()`.
  Since ProxyJump uses pthreads and the dispatch path replaces poll, this may need a
  dispatch-mode implementation of `ssh_socket_set_connected`.

- **Q2: `ssh_socket_connect_proxyjump()` in dispatch mode**: This function creates a pair
  of sockets and spawns a thread. It then calls `ssh_socket_set_connected()`. In dispatch
  mode, we'd need to set up the IO/NSStream objects for this fd. **Currently not handled.**
  If ProxyJump is used with dispatch, it will likely fail. The old patches didn't have this
  problem because ProxyJump didn't exist in v0.9.8.

- **Q3: `execv`/`fork` commented out for iOS sandbox**: The original patch comments these
  out for iOS. v0.12.0 has a `WITH_EXEC` CMake option that controls this at build time.
  **Consider** using `WITH_EXEC=OFF` in the build instead of commenting out code, which
  would be cleaner.

- **Q4: `thread_ssh_execute_command` function pointer**: This is declared in callbacks.h
  (patch 04) and used in socket.m for custom proxycommand execution. It uses `__thread`
  storage. **Verify** this works correctly on Apple platforms (iOS/macOS).

### socket.c 0.9.8 → 0.12.0 delta — required dispatch additions

Full diff of `src/socket.c` between `libssh-0.9.8` and `libssh-0.12.0` reviewed against
`0002-Patch-02-Dispatch-RunLoop-socket-session.patch`. The functionally relevant deltas:

1. **`ssh_socket_connect_proxyjump()` — NEW, intentionally bypassed via legacy flag.**
   v0.12.0 adds a ~250-line native ProxyJump implementation (`src/socket.c:1422`) that
   opens a `socketpair`, spawns a `pthread` running `jump_thread_func`, then attaches the
   parent fd via the poll path (`set_fd` → `get_poll_handle` → `set_connected`). Under
   `HAVE_DISPATCH_H` none of that is wired through the IO/NSStream wrapper, so a direct
   port would require mirroring the dispatch branch from `ssh_socket_connect_proxycommand`.

   **Decision: do not port. Force the legacy ProxyCommand path instead.** v0.12.0 ships
   a runtime selector for exactly this:
   - `ssh_libssh_proxy_jumps()` (`libssh/src/misc.c:2425`) returns `false` when
     `OPENSSH_PROXYJUMP=1` is set in the environment.
   - `ssh_socket_connect()` (`libssh/src/client.c:626`) only takes the native pthread
     branch when `ssh_libssh_proxy_jumps()` is true; otherwise it falls through to the
     existing `session->opts.ProxyCommand` branch — which the dispatch patch already
     handles.
   - `ssh_config_parse_proxy_jump()` (`libssh/src/config.c:493`), used both by ssh_config
     parsing and by `ssh_options_set(SSH_OPTIONS_PROXYJUMP, ...)`
     (`libssh/src/options.c:1200`), synthesizes a `ssh -W '[%h]:%p' ...` line and stores
     it via `SSH_OPTIONS_PROXYCOMMAND` instead of populating `opts.proxy_jumps` when the
     selector is false. So both config-file and programmatic users converge on the
     ProxyCommand path.

   This makes the native v0.12.0 ProxyJump path fully unreachable, and resolves Q1/Q2
   without code in `socket.m`.

   **Caveats to track:**
   - The synthesized ProxyCommand literally invokes the `ssh` binary; on iOS it cannot
     fork/exec. Blink must handle it through its existing `set_proxycommand_function` /
     `thread_ssh_execute_command` callback (same path used for regular ProxyCommand).
     Confirm Blink's callback understands the synthesized command line.
   - The env var must be set before any session parses config or calls `ssh_options_set`.
     **Safer alternative:** add a tiny patch that makes `ssh_libssh_proxy_jumps()`
     hard-return `false`, removing the runtime dependency and the risk of a host
     application forgetting to set the env var.
   - `ssh_socket_connect_proxyjump()` and `jump_thread_func()` remain compiled (they are
     behind `HAVE_PTHREAD`, not the selector). Consider stubbing them under
     `HAVE_DISPATCH_H` to return `SSH_ERROR` loudly if ever reached, so a future
     regression doesn't silently no-op.

2. **`ssh_socket_set_fd` dispatch branch is a stub.** The patched `#ifdef HAVE_DISPATCH_H`
   path leaves `[io setupWithFD:fd]` commented out, relying on every caller to attach the
   IO wrapper afterward via `[io connectedWithInFd:fdOut:]`. Audit all `ssh_socket_set_fd`
   call sites (`ssh_socket_connect`, `ssh_socket_connect_proxycommand`,
   `ssh_socket_connect_proxyjump`, `ssh_socket_unix`, server-side accept) to confirm each
   pairs `set_fd` with explicit IO setup. If any don't, either uncomment `setupWithFD:`
   or wire IO at those sites.

3. **`ssh_socket_set_connected()` — NEW helper.** Defined unconditionally in the patched
   file. New v0.12.0 call sites are `ssh_socket_pollcallback` POLLOUT path (irrelevant —
   dispatch bypasses pollcallback) and `ssh_socket_connect_proxyjump` (covered by item 1).
   No standalone fix needed; harmless no-op when called with `p == NULL`.

4. **Zero-copy receive in `ssh_socket_pollcallback`** (`ssh_buffer_allocate` +
   `MAX_BUF_SIZE`). Pure poll-path optimization. Dispatch delivers bytes via the
   NSInputStream callback into `s->in_buffer` directly — **not relevant**.

5. **`ssh_socket_unbuffered_read/write` signature widened** (`int len → uint32_t len`).
   Both wrapped in `#ifndef HAVE_DISPATCH_H` by the patch — drift cannot reach dispatch
   builds.

6. **`ssh_socket_write(... uint32_t len)`** — patch already updated.

7. **`WITH_EXEC` cmake guard** wraps `ssh_execute_command` /
   `ssh_socket_connect_proxycommand` in v0.12.0 (replaces our old `#ifndef _WIN32`).
   Already noted as Q3. Strong recommendation to switch to `WITH_EXEC=OFF` at cmake time
   and drop the `pid = 0; /* BLINK fork(); */` hack while we are touching this patch.

8. **Cosmetic** — `ssh_strerror` calls, formatting, comments — no functional impact.

### Action items distilled

- [ ] **Force legacy ProxyJump path** (item 1). Either set `OPENSSH_PROXYJUMP=1` in the
      host process environment before any libssh call, or add a one-line patch making
      `ssh_libssh_proxy_jumps()` hard-return `false`. Verify Blink's
      `set_proxycommand_function` callback handles the synthesized
      `ssh -W '[%h]:%p' ...` line.
- [ ] **Optionally stub `ssh_socket_connect_proxyjump` under `HAVE_DISPATCH_H`** to fail
      loudly, guarding against future regressions in the bypass.
- [ ] **Audit `ssh_socket_set_fd` callers** to confirm every dispatch-path caller wires
      IO afterward, or uncomment `[io setupWithFD:fd]` (item 2).
- [ ] **Switch to `WITH_EXEC=OFF`** instead of commented `fork()/execv()` (item 7).

---

## Patch 0003 — Custom Callbacks

### Adaptation decisions

1. **callbacks.h struct fields**: v0.12.0 restructured `ssh_callbacks_struct`. The new
   fields were inserted at the logical equivalent positions. The struct now has:
   - `set_proxycommand_function` after `connect_status_function`
   - `channel_open_request_forward_function` after `channel_open_request_auth_agent_function`
   - `session_exception_function` after `channel_open_request_forward_function`

2. **`ssh_socket_connect_proxycommand` signature in client.c**: v0.12.0 wraps the
   proxycommand call in `#ifdef WITH_EXEC` instead of `#ifndef _WIN32`. Our change to
   pass `session` is applied inside that guard.

3. **agent.h**: v0.12.0 changed from `#ifndef _WIN32` / `#endif` to `#ifdef __cplusplus`
   guards. The callback/userdata fields added in the same location.

### Open questions / Review items

- **Q5: ABI compatibility of `ssh_callbacks_struct`**: Adding fields to this struct
  changes its layout. The `ssh_callbacks_init` macro sets the struct size, and libssh
  checks it. Since we disabled symbol versioning (patch 01), this should be OK for our
  static build, but **verify** that `ssh_callbacks_init` and the size check in
  `ssh_set_callbacks` still work with the added fields.

- **Q6: `channel_open_request_forward_function` vs v0.12.0 native handling**: v0.12.0
  may already handle `SSH_CHANNEL_FORWARDED_TCPIP` differently than v0.9.8 in
  `ssh_execute_client_request()`. **Verify** that our added handler doesn't conflict
  with existing handling. Check if v0.12.0's messages.c already handles this case.

---

## Patch 0004 — SFTP Async Write

### Adaptation decisions

1. **`sftp_async_write` / `sftp_async_write_end`**: These are new functions not in
   upstream. The implementation was adapted to use v0.12.0 APIs:
   - `sftp_async_write_end` uses `sftp_recv_response_msg()` (v0.12.0's message
     receive API) instead of the old `sftp_dequeue` + `sftp_read_and_dispatch` loop.
   - Uses `SSH_BUFFER_FREE()` macro instead of `ssh_buffer_free()`.

2. **`sftp_async_read` dequeue fix skipped**: The original patch added
   `msg = sftp_dequeue(sftp,id)` before the while loop in `sftp_async_read()`. In
   v0.12.0, `sftp_async_read` was refactored to use `sftp_recv_response_msg()` which
   handles dequeueing correctly. The fix is no longer needed.

### Open questions / Review items

- **Q7: v0.12.0 already has `sftp_aio_begin_write` / `sftp_aio_wait_write`**: The
  upstream v0.12.0 added a complete async I/O API (`sftp_aio_*`) that supersedes the
  old `sftp_async_*` functions (which are now `SSH_DEPRECATED`). Our `sftp_async_write`
  / `sftp_async_write_end` follow the OLD deprecated pattern. **Should we switch Blink
  to use the native `sftp_aio_begin_write` / `sftp_aio_wait_write` instead?** If so,
  this entire patch can be dropped.

- **Q8: TODO comment on id overflow**: The patch adds a TODO about `uint32_t id` being
  converted to `int` in `sftp_async_read_begin`. This is an upstream issue that exists
  in the deprecated API. Not critical if we move to `sftp_aio_*`.

---

## Patch 0005 — Knownhosts Parsing

**Applied cleanly.** No adaptation needed.

**Change:** When `ssh_known_hosts_parse_line()` fails to parse a key, set `rc = SSH_AGAIN`
instead of leaving it as `SSH_ERROR`, so parsing continues to the next entry.

### Open questions / Review items

- **Q9: Upstream behavior change**: Check if v0.12.0 already handles unknown key types
  more gracefully than v0.9.8. If so, this patch may be unnecessary. A quick check shows
  the code path is still the same — the patch is still needed.

---

## Dropped: Patch 05 — ProxyJump

**Reason:** libssh v0.12.0 natively supports ProxyJump:
- `SSH_OPTIONS_PROXYJUMP` exists in the enum
- `ssh_config_parse_proxy_jump()` is non-static and declared in headers
- `ssh_config_parse_uri()` already has the `bool ignore_port` parameter
- `ssh_socket_connect_proxyjump()` implements jump via pthreads
- All test cases from our patch already exist upstream

No action needed.

---

## Summary of Open Questions

| # | Priority | Question | Recommendation |
|---|----------|----------|----------------|
| Q1 | HIGH | `ssh_socket_set_connected` not implemented for dispatch | Needs dispatch-mode impl or guard |
| Q2 | HIGH | `ssh_socket_connect_proxyjump` won't work with dispatch | Need to wire up IO/NSStream for proxyjump fd |
| Q3 | LOW | execv/fork commenting vs WITH_EXEC=OFF | Use CMake option instead |
| Q4 | MEDIUM | `__thread` on Apple platforms | Test on iOS |
| Q5 | LOW | ABI compat of callbacks struct | OK for static build |
| Q6 | MEDIUM | Forward channel callback vs v0.12.0 handling | Verify no conflict |
| Q7 | HIGH | sftp_async_write vs native sftp_aio API | Consider switching to native |
| Q8 | LOW | id overflow TODO | Not critical |
| Q9 | LOW | Knownhosts parsing still needed? | Yes, still needed |

---

## Files Changed Per Patch

```
0001: ConfigureChecks.cmake, DefineOptions.cmake, config.h.cmake, src/CMakeLists.txt
0002: include/libssh/socket.h, src/session.c→session.m, src/socket.c→socket.m
0003: include/libssh/agent.h, include/libssh/callbacks.h, include/libssh/libssh.h,
      src/agent.c, src/client.c, src/messages.c
0004: include/libssh/sftp.h, src/sftp.c
0005: src/knownhosts.c
```

## Temp Branch

The `temp-patches` branch in `libssh/` contains the sequential commits used to generate
these patches. It can be used to inspect intermediate states or rebuild patches.
