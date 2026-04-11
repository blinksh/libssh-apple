# SFTP Async API: v0.9.8 vs v0.12.0 — Migration Analysis

## Status (2026-05-01)

**libssh-apple side: done.** The custom `sftp_async_write` / `sftp_async_write_end`
patch was not carried into the 0.12.0 series. Its previous slot is preserved as
`0004-Patch-06-SFTP-async-write.patch.old` for archival reference; it is excluded from
`apply-patches.sh`.

**Blink side: in flight.** The migration patch (`blink-sftp-aio-migration.patch`,
sibling of this doc) captures the changes needed in `SSH/SFTP.swift` to switch reads
and writes from `sftp_async_*` to `sftp_aio_*`. Apply that to Blink before/with the
next libssh-apple bump — the deprecated `sftp_async_write` / `sftp_async_write_end`
prototypes are gone from libssh-apple's headers, so the Swift code will not compile
until migrated.

The "Migration Path" and per-file changes below describe the same migration that the
patch encodes; keep this doc as the rationale, the patch as the mechanical form.

---

## Context

Blink's `SSH/SFTP.swift` uses a pipelined async SFTP pattern with up to 20 concurrent
in-flight operations. It currently uses:

- **Reads:** `sftp_async_read_begin()` + `sftp_async_read()` (deprecated in v0.12.0)
- **Writes:** `sftp_async_write()` + `sftp_async_write_end()` (custom patch, not in upstream)

v0.12.0 provides a native replacement: the `sftp_aio_*` API.

---

## API Comparison

### Old API (v0.9.8 / deprecated)

```
Read:  id = sftp_async_read_begin(file, len)        → returns int request ID
       n  = sftp_async_read(file, buf, len, id)      → returns bytes read, 0=EOF, SSH_AGAIN

Write: rc = sftp_async_write(file, buf, count, &id)  → returns SSH_OK, id via out-param  [CUSTOM PATCH]
       rc = sftp_async_write_end(file, id, blocking)  → returns SSH_OK/SSH_ERROR/SSH_AGAIN [CUSTOM PATCH]
```

**Characteristics:**
- Request ID is a bare `uint32_t` (or `int` for reads — overflow risk noted in patch TODO)
- No server limit capping — caller must know/respect `max_read_length` / `max_write_length`
- Blocking controlled per-call for writes, per-file for reads
- No automatic memory management of request state

### New API (v0.12.0 native)

```
Read:  n  = sftp_aio_begin_read(file, len, &aio)    → returns bytes requested (after limit cap)
       n  = sftp_aio_wait_read(&aio, buf, buf_size)  → returns bytes read, SSH_AGAIN, SSH_ERROR

Write: n  = sftp_aio_begin_write(file, buf, len, &aio) → returns bytes queued (after limit cap)
       n  = sftp_aio_wait_write(&aio)                   → returns bytes written, SSH_AGAIN, SSH_ERROR
```

**Characteristics:**
- Opaque `sftp_aio` handle instead of bare ID (struct with file, id, len)
- Automatic limit capping: `begin_*` returns actual bytes after `MIN(len, server_limit)`
- `wait_*` frees the aio handle automatically (except on SSH_AGAIN)
- Blocking controlled by `file->nonblocking` for both read and write
- `ssize_t` return type throughout (no int/uint32_t mismatch)

---

## Key Behavioral Differences

| Behavior | Old API | New API (aio) |
|----------|---------|---------------|
| **Limit capping** | None — caller's problem | Automatic in `begin_*`, returns actual length |
| **EOF signaling (read)** | Returns 0 | Returns SSH_OK (not 0!), sets `file->eof` |
| **Success return (write)** | SSH_OK (0) | Returns bytes written (positive) |
| **Handle lifetime** | Caller tracks ID manually | Library frees on wait (except AGAIN) |
| **Buffer sizing (read)** | Caller guesses | `begin_read` returns exact size needed for buffer |
| **Blocking control (write)** | Per-call `blocking` param | Per-file `nonblocking` flag |

### EOF Handling — Breaking Change

This is the most significant behavioral change for Blink:

```
Old:  sftp_async_read() returns 0 on EOF
New:  sftp_aio_wait_read() returns SSH_OK (which is 0) on EOF, but also on success with 0 bytes
      Must check file->eof flag or rely on the return value semantics
```

Actually, looking more carefully: `sftp_aio_wait_read` returns `SSH_OK` (0) on EOF and
positive byte count on success. So the check `n == 0` still signals EOF — the semantics
are effectively the same as the old API.

---

## Blink SFTP.swift — Current Usage

### Read Pattern (lines 556–651)

```swift
// Schedule phase — queue up to 20 reads
while inflightReads.count < maxConcurrentOps {
    let id = sftp_async_read_begin(file, UInt32(blockSize))  // 32KB chunks
    inflightReads.append(UInt32(id))
}

// Harvest phase — collect completed reads
for block in inflightReads {
    let n = sftp_async_read(file, buf, UInt32(blockSize), block)
    if n > 0      → append data
    if n == 0     → EOF
    if SSH_AGAIN  → break (try again later)
    if n < 0      → error
}
```

### Write Pattern (lines 656–759)

```swift
// Schedule phase — queue up to 20 writes
while inflightWrites.count < maxConcurrentOps && data remains {
    sftp_async_write(file, bytes, length, &asyncRequest)  // [CUSTOM PATCH]
    inflightWrites.append(asyncRequest)
}

// Harvest phase — collect acknowledgments
for block in inflightWrites {
    let rc = sftp_async_write_end(file, block, 0)  // non-blocking
    if SSH_OK    → completed
    if SSH_AGAIN → break
    else         → error
}
```

Both phases run in a RunLoop-scheduled loop that alternates harvesting and scheduling.

---

## Migration Path: Old → New API

### Read Migration

```swift
// OLD
let id = sftp_async_read_begin(file, UInt32(blockSize))
inflightReads.append(UInt32(id))
// ...
let n = sftp_async_read(file, buf, UInt32(blockSize), block)

// NEW
var aio: sftp_aio? = nil
let requested = sftp_aio_begin_read(file, blockSize, &aio)
inflightReads.append(aio!)  // Store sftp_aio instead of UInt32
// ...
let n = sftp_aio_wait_read(&aio, buf, requested)  // aio freed automatically
```

**Changes required:**
1. `inflightReads` type: `[UInt32]` → `[sftp_aio]` (or `[sftp_aio?]`)
2. Use return value of `begin_read` to size the read buffer
3. `wait_read` takes `&aio` (pointer-to-pointer) and frees handle
4. Remove harvested entries differently — aio is set to nil on completion
5. EOF check: `n == 0` still works (SSH_OK == 0)

### Write Migration

```swift
// OLD (custom patch)
sftp_async_write(file, bytes, length, &asyncRequest)
inflightWrites.append(asyncRequest)
// ...
let rc = sftp_async_write_end(file, block, 0)  // 0 = non-blocking

// NEW
var aio: sftp_aio? = nil
let written = sftp_aio_begin_write(file, bytes, length, &aio)
inflightWrites.append(aio!)
// ...
let n = sftp_aio_wait_write(&aio)  // blocking controlled by file->nonblocking
```

**Changes required:**
1. `inflightWrites` type: `[UInt32]` → `[sftp_aio]`
2. `begin_write` return value gives actual bytes queued (after server limit cap)
3. No `blocking` parameter on `wait_write` — must set `sftp_file_set_nonblocking(file)`
   (Blink already does this at line 494, so this should just work)
4. `wait_write` returns bytes written (positive) instead of SSH_OK (0) on success
5. Handle auto-freed except on SSH_AGAIN

### Structural Changes to SFTP.swift

The core pipelining pattern stays the same. Main refactoring:

1. **Type change:** Replace `[UInt32]` arrays with `[sftp_aio?]` arrays
2. **Removal pattern:** Instead of removing by index after harvest, nil-check after wait
   (wait sets the aio to nil on completion)
3. **Buffer sizing:** Use `begin_read` return value for read buffer allocation
4. **Write success check:** Check `n > 0` instead of `rc == SSH_OK`
5. **Limit handling:** Remove any manual limit capping — `begin_*` handles it

---

## Recommendation

**Switch to the native `sftp_aio_*` API and drop Patch 06 entirely.**

Reasons:
1. Eliminates custom patch maintenance — one less thing to port on every libssh upgrade
2. Automatic server limit capping prevents oversized requests
3. Better memory safety with opaque handles vs bare IDs
4. The old `sftp_async_*` API is marked `SSH_DEPRECATED` and may be removed in future versions
5. The migration is straightforward — same pipelining pattern, different types

The Blink SFTP.swift changes are moderate: mainly type changes from `UInt32` to `sftp_aio`
and adjusting return value checks. The pipelining architecture (20 concurrent ops, RunLoop
scheduling, harvest/schedule loop) stays identical.
