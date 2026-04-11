# Reverse Port Forward Callback: Custom vs Upstream — Migration Analysis

## Status (2026-05-01)

**libssh-apple side: done.** The custom typedef
(`ssh_channel_open_request_forward_callback`), the corresponding struct field, and the
`ssh_execute_client_request()` dispatch branch have been removed from Patch 04
(`0003-Patch-04-Custom-callbacks.patch`, commit `180edcde`). Net removal as previewed
below — 3 lines in `callbacks.h`, 11 lines in `messages.c`.

**Blink side: pending.** `SSH/SSHClient.swift:requestReverseForward` still uses the old
typedef and field name; this will fail to compile against the new libssh-apple headers
until the closure signature and field assignment are migrated to
`ssh_channel_open_request_forwarded_tcpip_callback` /
`channel_open_request_forwarded_tcpip_function`. See "Blink side — `SSHClient.swift`"
below for the exact diff.

The "current state" and "rollout order" sections below describe how we got here; the
diff preview under "drop the custom callback from Patch 0003" reflects the change
already applied.

---

## Context

Blink registers a callback to accept incoming `forwarded-tcpip` channels (server-initiated
reverse-forward connections). Historically it used a custom callback added in Blink's
Patch 04 for libssh 0.9.8, because upstream 0.9.8 parsed these channel-open requests but
exposed **no client-side dispatcher** for them.

libssh 0.12.0 added a native, richer callback for the same use case. The custom callback
and the upstream callback now coexist in `struct ssh_callbacks_struct` and in
`ssh_execute_client_request()`. The upstream API supersedes ours; the custom path is
**deprecated from Blink's perspective** and should be dropped.

---

## API Comparison

### Old API (Blink custom patch, still active)

```c
// include/libssh/callbacks.h
typedef ssh_channel (*ssh_channel_open_request_forward_callback)
    (ssh_session session,
     uint16_t destination_port,
     void *userdata);

struct ssh_callbacks_struct {
    ...
    ssh_channel_open_request_forward_callback channel_open_request_forward_function;
    ...
};
```

**Characteristics:**
- Port-only: callback only receives the destination port, nothing else.
- `uint16_t` port, narrower than what the protocol carries on the wire.
- Originator host/port and destination address are discarded before the callback runs.
- No upstream counterpart in libssh 0.9.8 — this was invented by Blink.

### New API (libssh 0.12.0 native)

```c
// include/libssh/callbacks.h
typedef ssh_channel (*ssh_channel_open_request_forwarded_tcpip_callback)
    (ssh_session session,
     const char *destination_address, int destination_port,
     const char *originator_address, int originator_port,
     void *userdata);

struct ssh_callbacks_struct {
    ...
    ssh_channel_open_request_forwarded_tcpip_callback channel_open_request_forwarded_tcpip_function;
};
```

**Characteristics:**
- Full protocol payload: destination address + port AND originator address + port.
- `int` for both ports (widened from `uint16_t`).
- Official, upstream-maintained — no Blink patch to carry forward on future libssh bumps.

---

## Dispatch Chain (intermediate state, before the libssh-apple drop)

This section captures the layout when both callbacks coexisted in `Patch 0003`. After
the drop (described in "drop the custom callback from Patch 0003" below — applied in
commit `180edcde`), only the upstream `else if` branch remains.

In `src/messages.c:ssh_execute_client_request()` the two callbacks were checked in
sequence. Upstream's runs first:

```c
} else if (msg->channel_request_open.type == SSH_CHANNEL_FORWARDED_TCPIP
           && ssh_callbacks_exists(..., channel_open_request_forwarded_tcpip_function)) {
    channel = ... channel_open_request_forwarded_tcpip_function(session, dest, destPort,
                                                                orig, origPort, userdata);
    return ssh_reply_channel_open_request(msg, channel);
} else if (msg->channel_request_open.type == SSH_CHANNEL_FORWARDED_TCPIP
           && ssh_callbacks_exists(..., channel_open_request_forward_function)) {
    channel = ... channel_open_request_forward_function(session, destPort, userdata);
    ...
}
```

Whichever callback the caller registers is the one that runs. Blink currently registers
only the old one, so dispatch lands on the custom branch. After migration, Blink will
register the upstream one, the old branch will be unreachable, and the custom branch can
be deleted from Patch 0003 entirely.

### Semantic Equivalence — Verified

Before migrating, we need to be certain the upstream branch fires under **the same
conditions** and behaves **the same way** as Blink's custom branch. Both checks pass:

**1. Trigger conditions — identical.**
Both branches in `ssh_execute_client_request()` guard on the exact same three
predicates:
- `msg->type == SSH_REQUEST_CHANNEL_OPEN`
- `msg->channel_request_open.type == SSH_CHANNEL_FORWARDED_TCPIP`
- the respective callback field is non-NULL

The parser that decides those predicates is the same for both callbacks —
`messages.c:1465-1479` (the `"forwarded-tcpip"` branch in the channel-open parser) fills
in `destination`, `destination_port`, `originator`, `originator_port`, and sets
`msg->channel_request_open.type = SSH_CHANNEL_FORWARDED_TCPIP` before either callback is
ever consulted. The upstream callback simply gets access to fields that were always
populated but that Blink's custom signature didn't expose.

**2. Post-callback behavior — identical.**
Our custom branch handles the `channel == NULL` case inline:
```c
channel = channel_open_request_forward_function(...);
if (channel != NULL) {
    rc = ssh_message_channel_request_open_reply_accept_channel(msg, channel);
    return rc;
} else {
    ssh_message_reply_default(msg);
}
return SSH_OK;
```
The upstream branch does the same thing through a helper
(`ssh_reply_channel_open_request`, `messages.c:395-404`):
```c
static int ssh_reply_channel_open_request(ssh_message msg, ssh_channel channel)
{
    if (channel != NULL) {
        return ssh_message_channel_request_open_reply_accept_channel(msg, channel);
    }
    ssh_message_reply_default(msg);
    return SSH_OK;
}
```
Byte-for-byte the same logic. No behavioral drift between the two dispatch paths — the
only user-visible difference is the callback signature and which struct field the caller
writes to.

---

## Blink — Current Usage

Single call site: `SSH/SSHClient.swift:751-809` in `requestReverseForward(bindTo:port:)`.

```swift
let cb: ssh_channel_open_request_forward_callback = { (session, port, userdata) in
    let ctxt = Unmanaged<SSHClient>.fromOpaque(userdata!).takeUnretainedValue()
    ctxt.log.message("REVERSE Forward callback", SSH_LOG_INFO)

    let port = Int32(port)

    // If there is no associated port, check if it may be on 0
    if ctxt.reversePorts[port] == nil {
        if let _ = ctxt.reversePorts[0] {
            ctxt.reversePorts[port] = ctxt.reversePorts.removeValue(forKey: 0)
        }
    }

    guard let pub = ctxt.reversePorts[port] else { return nil }
    guard let channel = ssh_channel_new(ctxt.session) else { return nil }
    ssh_channel_set_blocking(channel, 0)

    let stream = Stream(channel, on: ctxt)
    pub.send(stream)

    return channel
}

return connection()
    .tryOperation { session -> Int32 in
        ...
        if self.callbacks.channel_open_request_forward_function == nil {
            self.callbacks.channel_open_request_forward_function = cb
            ssh_set_callbacks(session, &self.callbacks)
        }
        return port
    }
    ...
```

**What Blink actually uses from the callback payload:** only `destination_port`. The
originator address/port and destination address are not consumed anywhere.

---

## Migration Path: Old → New API

### Blink side — `SSHClient.swift`

```swift
// OLD
let cb: ssh_channel_open_request_forward_callback = { (session, port, userdata) in
    ...
    let port = Int32(port)
    ...
}

self.callbacks.channel_open_request_forward_function = cb
ssh_set_callbacks(session, &self.callbacks)

// NEW
let cb: ssh_channel_open_request_forwarded_tcpip_callback = {
    (session, destAddr, destPort, origAddr, origPort, userdata) in
    ...
    let port = destPort  // already Int32 (C int maps to Int32 on all Apple 64-bit targets)
    ...
}

self.callbacks.channel_open_request_forwarded_tcpip_function = cb
ssh_set_callbacks(session, &self.callbacks)
```

**Changes required:**
1. Typedef: `ssh_channel_open_request_forward_callback` → `ssh_channel_open_request_forwarded_tcpip_callback`
2. Closure signature: add `destAddr: UnsafePointer<CChar>?`, rename `port` →
   `destPort` with type `Int32`, add `origAddr: UnsafePointer<CChar>?`, add `origPort: Int32`.
3. Drop the `Int32(port)` cast — upstream already passes `int`.
4. Field name: `channel_open_request_forward_function` →
   `channel_open_request_forwarded_tcpip_function`.
5. Three unused parameters (`destAddr`, `origAddr`, `origPort`) can be ignored with `_`
   in the closure if desired.

**No behavioral changes.** Blink's reverse-forward semantics (the `reversePorts` dict
lookup with port=0 fallback) are preserved verbatim — all the logic reads `port` only.

### libssh side — drop the custom callback from Patch 0003

The migration also lets us shrink Patch 0003 by deleting the custom typedef, struct
field, and dispatch branch. **Applied** as part of commit `180edcde` (Patch 04). The
diff preview below matches what landed.

```diff
diff --git a/include/libssh/callbacks.h b/include/libssh/callbacks.h
--- a/include/libssh/callbacks.h
+++ b/include/libssh/callbacks.h
@@ -160,9 +160,6 @@ typedef ssh_channel (*ssh_channel_open_request_auth_agent_callback) (ssh_session
  * @returns NULL if the request should not be allowed
  * @warning The channel pointer returned by this callback must be closed by the application.
  */
-typedef ssh_channel (*ssh_channel_open_request_forward_callback) (ssh_session session, uint16_t destination_port,
-      void *userdata);
-
 typedef void (*ssh_session_set_proxycommand_callback) (const char *command, socket_t in, socket_t out, void *userdata);

 typedef void (*ssh_session_exception_callback) (ssh_session session, void *userdata);
@@ -221,7 +218,6 @@ struct ssh_callbacks_struct {
   /** This function will be called when an incoming "auth-agent" request is received.
    */
   ssh_channel_open_request_auth_agent_callback channel_open_request_auth_agent_function;
-  ssh_channel_open_request_forward_callback channel_open_request_forward_function;
   ssh_session_exception_callback session_exception_function;
   /**
    * This function will be called when an incoming "forwarded-tcpip"

diff --git a/src/messages.c b/src/messages.c
--- a/src/messages.c
+++ b/src/messages.c
@@ -435,17 +435,6 @@ static int ssh_execute_client_request(ssh_session session, ssh_message msg)
                 session->common.callbacks->userdata);

         return ssh_reply_channel_open_request(msg, channel);
-    } else if (msg->type == SSH_REQUEST_CHANNEL_OPEN
-               && msg->channel_request_open.type == SSH_CHANNEL_FORWARDED_TCPIP
-               && ssh_callbacks_exists(session->common.callbacks, channel_open_request_forward_function)) {
-      channel = session->common.callbacks->channel_open_request_forward_function(session, msg->channel_request_open.destination_port, session->common.callbacks->userdata);
-      if (channel != NULL) {
-        rc = ssh_message_channel_request_open_reply_accept_channel(msg, channel);
-        return rc;
-      } else {
-        ssh_message_reply_default(msg);
-      }
-      return SSH_OK;
     }

     return rc;
```

Net removal: 3 lines in `callbacks.h`, 11 lines in `messages.c`. Patch 0003 shrinks by
14 lines and one typedef. No other patch references `channel_open_request_forward_*`.

---

## Rollout Order

The originally planned sequence kept libssh-apple and Blink on compatible headers at
every step. We collapsed steps 1 and 4 into a single libssh-apple release, which means
Blink **must** migrate before/with the next libssh-apple bump or the Swift code will
not compile.

1. ~~**Merge libssh-apple 0.12.0 with Patch 0003 as-is** (both callbacks present).~~
   *(skipped — libssh-apple ships with the upstream-only state directly)*
2. **Migrate Blink's `SSHClient.swift:requestReverseForward`** to the upstream callback
   (`ssh_channel_open_request_forwarded_tcpip_callback`). Test reverse-forward end-to-end
   against a real server (`ssh -R`). **← current step**
3. **Ship Blink + libssh-apple together.** Both must update in lockstep because the old
   typedef and struct field no longer exist.

If a staggered rollout is needed for any reason, the original 4-step plan above can be
recreated by temporarily reverting the drop hunks in Patch 04 — but at this point that's
not the plan.

---

## Recommendation

**Migrate Blink to the upstream callback, then drop the custom one from Patch 0003.**

Reasons:
1. Eliminates custom patch maintenance — one less thing to port on every libssh upgrade.
2. Aligns with upstream API, which is better documented and gets more scrutiny.
3. Richer callback payload (originator + destination address) enables future features —
   e.g., audit logging, per-origin policy — without another libssh patch.
4. Mechanical Blink change: one closure signature, one field name. ~6 lines edited.
5. Shrinks Patch 0003 by 14 lines and simplifies the dispatch chain in `messages.c`.

The only cost is coordinating the rollout order above. Given Blink and libssh-apple are
released together, this is low-friction.
