# EXC_BAD_ACCESS in `meta::warp::EventThread` / `tryOpenChannel` during connection teardown (DAT iOS 0.7.0)

> Draft for posting to https://github.com/facebook/meta-wearables-dat-ios/discussions
> Fill in the Meta AI app + glasses firmware versions (marked `<FILL IN>`) before posting.

## Summary

Under DAT iOS SDK **0.7.0**, when the glasses link drops (user folds/removes the
glasses, walks out of Bluetooth range) or the app sits idle for a while, the app
intermittently crashes with `EXC_BAD_ACCESS (code=1, address=0x8)` on the SDK's own
WARP transport thread (`DCTEvent`). The faulting frame is a hash-table lookup inside
`tryOpenChannel()` reading from a **freed** channel registry (`datax_list`):

```
EventThread::loop() → tryOpenChannel() → datax_channel_open → datax_list_find
  → std::__hash_table::find   ← reads offset 8 of a NULL/freed hash table (addr 0x8)
```

This looks like a **use-after-free / lifecycle race internal to the SDK's transport
layer**: a `datax::Connection`'s channel list is freed while its WARP `EventThread` is
still scheduled and runs one more `tryOpenChannel()` iteration against the freed object.

## Environment

- DAT iOS SDK: **0.7.0** (`facebook/meta-wearables-dat-ios`, rev `c40db3978a76b97504b85ed9f082be5549c5a486`)
- Device: Meta Ray-Ban (camera `Stream` + on-glasses `Display` capabilities, both attached to one `DeviceSession`)
- Meta AI app version: `<FILL IN>`
- Glasses firmware: `<FILL IN>`
- iOS: `<FILL IN>` / device: `<FILL IN>`
- App uses ephemeral-token Gemini Live for audio+video; the DAT side provides camera frames + a Display HUD.

## Repro

1. Start a `DeviceSession`, attach a camera `Stream` (and, on a Display device, a `Display` capability).
2. While active, drop the link: fold/remove the glasses or walk out of BT range; then re-don / re-enter and let the app re-acquire a session. Repeat a handful of times.
3. Alternatively, leave the session idle for ~10–20+ minutes.

Crash fires intermittently on the `DCTEvent` thread during the disconnect→reconnect churn.

## Evidence — two complete WARP stacks coexist

`bt all` at the crash shows **every WARP transport thread present exactly twice** — i.e.
two live `datax::Connection` / WARP stacks at once. The crashing `DCTEvent` belongs to
the *dying* connection; the second set are a freshly-created connection's threads parked
healthily in `cond_wait`:

| WARP thread | dying stack | new stack |
|---|---|---|
| `xms_inQueue` | #54 | #71 |
| `xms_outQueue` | #55 | #72 |
| `Hera.MediaQualityMonitorManager` | #57 | #74 |
| `Hera.VidRcvImpl` | #103 | #107 |
| `Hera.AudioReceiverImpl` | #104 | #108 |
| `Hera.MessageQueueLinkProvider` | #106 | #110 |
| **`DCTEvent`** | **#105 (crashed)** | #109 |

### Crashing thread (`bt`)

```
thread #105, name = 'DCTEvent', stop reason = EXC_BAD_ACCESS (code=1, address=0x8)
  frame #0: MWDATCore`std::__hash_table<...int, void*...>::find<int>(int const&) const
  frame #1: MWDATCore`datax_list_find + 28
  frame #2: MWDATCore`datax_channel_open + 80
  frame #3: MWDATCore`datax::LocalChannel::Internal::open(datax_connection*, ...) + 92
  frame #4: MWDATCore`datax::LocalChannel::open(datax_connection*, ...) + 116
  frame #5: MWDATCore`datax::Connection::openChannel(datax::LocalChannel&, ...) + 112
  frame #6: MWDATCore`datax::Connection::openChannel(datax::LocalChannel::Configuration) + 88
  frame #7: MWDATCore`-[FWADataXLocalChannel initWithConnection:configuration:] + 304
  frame #8: MWDATCore`-[FWALinkedDeviceConnection openChannel:] + 60
  frame #9: MWDATCore`ConnectionImpl.openChannel(serviceID:onReceived:onError:onClosed:) + 120
 frame #13: MWDATCamera`SUPXMSDeviceConnection::openChannel(...) + 308
 frame #14: MWDATCamera`meta::wearable::xms::WARPDeviceConnectionAdapter::openChannel(...) + 180
 frame #15: MWDATCamera`meta::warp::DeviceConnectionTransport::tryOpenChannel() + 188
 frame #16: MWDATCamera`meta::warp::EventThread::loop(...) + 372
 frame #17-19: std::__thread_proxy / _pthread_start
```

The disassembly at the fault is `ldr x8, [x0, #0x8]` with `x0 == 0x0` → the
`__hash_table` `this` is null/freed; `find` dereferences its bucket pointer at offset 8.

## Likely root cause / requested fix

The WARP `EventThread` issues `tryOpenChannel()` against a `datax::Connection` whose
channel list has already been freed by teardown — the event thread outlives the
connection's `datax_list`. Two things would harden this SDK-side:

1. `datax_list_find` / `tryOpenChannel()` should **null-check the channel list** (and the connection's validity) before the lookup, and bail if teardown has begun.
2. The WARP `EventThread` should be **joined/quiesced before the `datax::Connection` (and its channel registry) is freed**, so no `tryOpenChannel()` iteration can run after the list is destroyed.

## Client-side observation (for repro context)

We can amplify or reduce the crash from the app side by how fast we recreate a session
after a disconnect: creating a new `DeviceSession` while the previous one's WARP threads
are still draining reliably yields the doubled-stack state above. Notably, the SDK
appears to clear its session bookkeeping (a fresh `createSession` succeeds rather than
throwing `.sessionAlreadyExists`) **before** the old connection's WARP threads have
exited — so from the app there's no signal beyond `DeviceSession.stopped` to know the
transport is fully torn down. A "transport fully drained" terminal signal, or joining
the event thread before `.stopped` is reported, would let integrators avoid the race
entirely.
