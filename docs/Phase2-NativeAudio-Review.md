# Phase 2 native audio port — pre-flight review

Snapshot of risks and design notes for porting bendio's RFCOMM audio
+ SBC codec to native Swift, eliminating the Python subprocess from
the macOS app entirely.

Captured before Phase 2 work begins so we can consult it as a
checklist as we make progress, and so successors don't repeat
mistakes from the bendio era.

## Status going in

- **Phase 1 (BLE control via Swift CoreBluetooth):** done.
  ``NativeBluetoothPlugin.swift`` owns scan / connect / write /
  indicate. ``MacOsRadioBluetooth`` still spawns ``bendio`` as a
  subprocess but only for RFCOMM audio JSON-RPC.
- **Mic capture:** already native. ``NativeAudioPlugin.swift`` runs
  AVAudioEngine and ships PCM to Dart, which forwards to bendio's
  ``audio_tx_pcm`` for SBC encode + RFCOMM write.
- **Speaker output, SBC decode, RFCOMM RX, SBC encode:** still in
  bendio.

## Gating risks

### SBC codec is the whole question

Three options, all with tradeoffs:

1. **libsbc (BlueZ).** Actively maintained C library. Build from
   source as a static lib in the Runner target, use a Swift bridging
   header. **Risk:** there is no clean Swift Package; you write the
   build glue yourself. Bit-exact behaviour against ffmpeg has to be
   verified for the radio's exact codec config (32 kHz / 16 blocks /
   mono / loudness / 8 subbands / bitpool 18 / 44-byte frame).
2. **Keep ffmpeg as a subprocess.** Defeats Phase 2's premise —
   we still have a subprocess, just talking to a different IPC. Off
   the table unless libsbc fails the spike and we need a fallback.
3. **Pure-Swift SBC port.** Real risk of bit-bug mush at the receiver,
   weeks of work. Off the table unless libsbc and ffmpeg are both off
   the table.

**Action:** spike libsbc *before* writing any other Phase 2 code.

### IOBluetooth threading on macOS

We learned this the hard way in bendio: ``IOBluetoothRFCOMMChannel``
delegate callbacks (open-complete, data-received, closed) fire on
the **main run loop**. If main is blocked, no callbacks. Same trap
applies in Swift.

- ``RFCOMMChannel.openWithChannelID(_:delegate:)`` returns
  immediately; ``rfcommChannelOpenComplete:status:`` arrives later
  on the main thread. Block main → silent timeout.
- ``writeSync(_:length:)`` is synchronous and thread-safe per Apple,
  but the underlying queue is on main. Calling it from sounddevice's
  audio thread is fine; from a Dart isolate or a tight CPU loop on
  main is not.
- AVAudioEngine has its own audio thread for input/output callbacks
  — that's fine. Only the RFCOMM open / close / write itself is
  main-thread sensitive.

### End-of-TX is a bear trap

The radio stays wedged in TX mode unless we send
``7E 01 00 01 00 00 00 00 00 00 7E`` three times with 50 ms spacing
and wait 1.5 s before closing the channel. If any TX path forgets
this, the radio is unusable until power-cycle.

**Mitigation (mandatory):**
- Single chokepoint: only one Swift method writes audio to RFCOMM.
- That method owns a state machine that always sends EOT on exit
  via Swift ``defer`` so even a ``throw`` mid-TX walks through EOT.
- Unit test: mock RFCOMM write, fire a TX, assert the last 11+
  bytes are the EOT sequence ×3.

### No more fallback once Phase 2 ships

Phase 1 left bendio spawned as the audio fallback — if BLE failed,
audio still worked because both paths existed independently. Phase
2 removes bendio entirely. **Bug in the new plugin = both
directions dead.**

**Mitigation:** keep both code paths behind a ``MacOsNativeAudio``
DataBroker flag for at least one release cycle. Default off, opt
in for testing. Promote to default once we have a couple of QSOs of
real-world use.

## Persistent constraints

These don't change between bendio and native; just reminders.

### Pairing in System Settings → Bluetooth is required

``IOBluetoothDevice.pairedDevices()`` only returns radios already
paired through the macOS Bluetooth pane. RFCOMM open fails on
unpaired devices regardless of language. Need to surface a clear
error message ("Pair the radio in System Settings → Bluetooth and
try again") when the lookup misses.

### Don't open RFCOMM channel 4 (SPP Dev / GAIA control)

Per bendio's ``docs/PROTOCOL_NOTES.md``, opening channel 4 while a
BLE control session is active wedges the radio's dual-mode state
machine. Channel 2 (BS AOC) for audio is the only RFCOMM channel
we ever touch.

### Audio codec parameters are fixed

32 kHz mono SBC, 16 blocks, loudness allocation method, 8 subbands,
bitpool 18 → exactly 44 bytes per frame. Wrap each frame as
``0x7E <cmd 0x00> <44 escaped bytes> 0x7E``. RX comes in 7 frames
per 309-byte packet; TX sends 1 frame per packet.

## Side benefits Phase 2 unlocks

- Once bendio is gone we don't have to handle ``[macos-bt] bendio
  exited (code -15)``-style silent failures any more. Native plugin
  failures surface as Swift exceptions or ``FlutterError``s with
  context. Better signal-to-noise.
- No more JSON hex round-trip: ~10 ms saved per audio chunk in each
  direction, plus the ffmpeg encode/decode warmup that shaves the
  start of each RX burst.
- One less language to debug, one less subprocess to manage, one
  less ``which python3`` hand-holding for new contributors.

## Bendio repo isn't going away

The bendio Python library stays useful as the CLI / Linux
reference / standalone test rig (``bendio rfcomm-play``,
``bendio sniff``, etc.). Phase 2 just stops bundling it as a
runtime dependency of the macOS Flutter app.

## Realistic estimate

- Earlier napkin estimate said "half a day". Sober estimate:
  - **2 days** if libsbc cooperates and AVAudioEngine output behaves
    on the user's box.
  - **A week or more** if libsbc has linker drama or the codec
    output isn't bit-exact and we have to debug bit-by-bit.

## Concrete next step

Do the libsbc spike. Goal: a Swift CLI that decodes one captured SBC
frame to PCM via libsbc, byte-for-byte identical to ``ffmpeg -f sbc -i
frame.bin -f s16le -ar 32000 -ac 1 -``. ~2 hours to either
de-risk Phase 2 or pivot to a Unix-socket-talking ffmpeg subprocess.
