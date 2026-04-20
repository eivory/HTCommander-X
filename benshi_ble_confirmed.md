# Benshi Radio — Confirmed BLE Protocol Reference

**Scope:** This document records *only* what has been empirically confirmed to work over Bluetooth Low Energy with a paired Benshi-family handheld radio (BTECH UV-PRO and equivalents). It deliberately excludes the audio path (RFCOMM SPP), unsolved problems, and speculation.

It is intended as a clean-slate briefing for a new investigation.

---

## 1. Hardware family

The same protocol is used by all of these radios (all from the same Benshi OEM design):

- BTECH UV-PRO (primary test target)
- RadioOddity GA-5WB
- Vero VR-N76
- Vero VR-N7500
- BTech GMRS-Pro

The radio acts as a **dual-mode Bluetooth peripheral**: it advertises a BLE GATT service for control/telemetry, and in parallel exposes a Bluetooth Classic SPP (RFCOMM) channel for audio. The two transports are independent.

**Everything in this document concerns the BLE GATT control link only.**

---

## 2. GATT service and characteristics

The radio exposes a single proprietary 128-bit Benshi service:

| Role         | UUID                                       | Properties        |
|--------------|--------------------------------------------|-------------------|
| Service      | `00001100-d102-11e1-9b23-00025b00a5a5`     | primary           |
| Write        | `00001101-d102-11e1-9b23-00025b00a5a5`     | Write (with response) |
| Indicate     | `00001102-d102-11e1-9b23-00025b00a5a5`     | Indicate          |

Notes confirmed in practice:
- The host writes commands to the **Write** characteristic with response.
- The host enables indications on the **Indicate** characteristic; the radio pushes both *replies* and *spontaneous notifications* on this characteristic.
- There is **no audio characteristic**. Audio is not carried over BLE on this radio.
- Pairing is not strictly required to discover the service, but a stable, paired bond is required for reliable indication delivery in normal use. If the bond is broken (e.g. host re-pairs), the radio will appear "BT connected" but writes will be silently dropped until the bond is re-established.

---

## 3. Frame format (GAIA over BLE)

Every BLE write payload, and every indication payload, is one **GAIA frame**:

```
+------+------+-------+--------+--------------+----------+
| 0xFF | 0x01 | flags | n_pay  | cmd_grp/cmd  | payload  |
+------+------+-------+--------+--------------+----------+
   1B     1B     1B      1B         4B           n_pay B
```

- Bytes 0..1: literal `FF 01` (GAIA SOF / vendor stamp)
- Byte 2: **flags** — `0x00` for normal command frames in observed traffic
- Byte 3: **n_payload** — number of payload bytes that follow the 4-byte command header. (i.e. excludes `command_group` and `command_id`)
- Bytes 4..7: 4-byte command header (see §4)
- Bytes 8..(8+n_payload-1): command-specific payload

There is no checksum and no end-of-frame marker on BLE; one BLE attribute write = one complete GAIA frame. (RFCOMM transport adds its own framing on top, irrelevant here.)

---

## 4. Command header

Bytes 4..7 of every frame are:

```
+------------------+-----------------+
| command_group    | command_id      |
|     uint16 BE    |   uint16 BE     |
+------------------+-----------------+
```

Two confirmed groups are in use:

| group value | name      |
|-------------|-----------|
| `0x0002`    | BASIC     |
| `0x000A`    | EXTENDED  |

For replies the high bit of `command_id` is set by the radio, i.e. reply `command_id = request_command_id | 0x8000`. (Mirrors GAIA conventions and is consistent with observed frames.)

---

## 5. BASIC command IDs (group `0x0002`)

These are the command IDs that have been confirmed to round-trip with the UV-PRO and to drive the documented behavior. They are taken from the working HTCommander implementation (`src/radio/Radio.cs` enum `RadioBasicCommand`) and benlink (`benlink/protocol`):

| ID  | Name                       | Confirmed use                                     |
|-----|----------------------------|---------------------------------------------------|
|  1  | GET_DEV_ID                 | returns radio device identifier                   |
|  4  | GET_DEV_INFO               | returns device info struct (model, fw, etc.)     |
|  5  | READ_STATUS                | snapshot of radio status                          |
|  6  | REGISTER_NOTIFICATION      | subscribe to a notification class (see §7)       |
|  7  | CANCEL_NOTIFICATION        | unsubscribe                                       |
|  8  | GET_NOTIFICATION           | poll a notification value                         |
|  9  | EVENT_NOTIFICATION         | (radio→host) push event; carries notification ID  |
| 10  | READ_SETTINGS              | read full settings block                          |
| 11  | WRITE_SETTINGS             | write settings block                              |
| 12  | STORE_SETTINGS             | persist current settings to NVRAM                 |
| 13  | READ_RF_CH                 | read one channel's config (channel index in payload) |
| 14  | WRITE_RF_CH                | write one channel's config                        |
| 15  | GET_IN_SCAN                | scan state                                        |
| 16  | SET_IN_SCAN                | enable/disable scan                               |
| 20  | GET_HT_STATUS              | handheld status (PTT, RX, channel, etc.)         |
| 21  | SET_HT_ON_OFF              | radio power on/off                                |
| 22  | GET_VOLUME                 | speaker volume                                    |
| 23  | SET_VOLUME                 | speaker volume                                    |
| 31  | HT_SEND_DATA               | send TNC/data packet over the air                 |
| 32  | SET_POSITION               | push GPS position to radio                        |
| 33  | READ_BSS_SETTINGS          | read BSS / data-mode settings                     |
| 34  | WRITE_BSS_SETTINGS         | write BSS / data-mode settings                    |
| 41  | STOP_RINGING               | silence incoming-call ring                        |
| 53  | PLAY_TONE                  | sound a beep                                      |
| 57  | RX_DATA                    | (radio→host) inbound TNC/data packet              |
| 60  | SET_REGION                 | switch region/band plan                           |
| 67  | SET_MSG / 68 GET_MSG       | text-message slot R/W                             |
| 69  | BLE_CONN_PARAM             | tune BLE connection parameters                    |
| 70  | SET_TIME                   | set radio RTC                                     |
| 71  | SET_APRS_PATH / 72 GET     | APRS path string                                  |
| 73  | READ_REGION_NAME           | region name string                                |
| 74  | SET_DEV_ID                 | set device ID                                     |
| 76  | GET_POSITION               | last known GPS position from radio                |

Other BASIC IDs exist in the firmware (the full enum 0..76) but only the above have been exercised end-to-end and seen to behave correctly.

---

## 6. EXTENDED command IDs (group `0x000A`)

Smaller surface, fewer confirmed:

| ID    | Name                 | Notes                                 |
|-------|----------------------|---------------------------------------|
| 769   | GET_BT_SIGNAL        | RSSI of BT link                       |
| 16387 | GET_DEV_STATE_VAR    | generic state variable getter         |
| 1825  | DEV_REGISTRATION     | observed during initial bind          |

---

## 7. Notifications (asynchronous radio→host events)

The host calls `REGISTER_NOTIFICATION` (BASIC 6) with a notification-class byte in the payload. Thereafter the radio pushes `EVENT_NOTIFICATION` (BASIC 9) frames whose payload begins with that class byte and is followed by class-specific data. Confirmed classes:

| ID | Class                   | Payload meaning                                    |
|----|-------------------------|----------------------------------------------------|
|  1 | HT_STATUS_CHANGED       | encoded `HtStatus` block (PTT/RX/channel/etc.)     |
|  2 | DATA_RXD                | inbound TNC frame body                             |
|  5 | HT_CH_CHANGED           | active channel index changed                       |
|  6 | HT_SETTINGS_CHANGED     | settings block changed                             |
|  7 | RINGING_STOPPED         |                                                    |
|  8 | RADIO_STATUS_CHANGED    |                                                    |
|  9 | USER_ACTION             | hardware key/button press                          |
| 10 | SYSTEM_EVENT            | misc system events                                 |
| 11 | BSS_SETTINGS_CHANGED    |                                                    |
| 12 | DATA_TXD                | tx of TNC frame completed                          |
| 13 | POSITION_CHANGE         | new GPS fix from radio                             |

---

## 8. Confirmed end-to-end behaviors over BLE

The following have been observed working in the field with HTCommander on Windows and on macOS:

- Connect → discover service → enable indications on `…1102` → write `GET_DEV_INFO` → receive correctly-decoded device info.
- Read full channel table by iterating `READ_RF_CH` for indices 0..N. Channel names round-trip; e.g. channel 29 named "APRS" decodes correctly.
- `SET_VOLUME` / `GET_VOLUME` round-trip and audibly change radio volume.
- `READ_SETTINGS` / `WRITE_SETTINGS` round-trip without corrupting the radio.
- `REGISTER_NOTIFICATION` for class 1 (HT_STATUS_CHANGED) reliably produces push events whenever PTT is keyed or the user changes channel from the radio's keypad.
- `HT_SEND_DATA` successfully sends an AX.25/APRS frame over the air, and inbound AX.25 frames arrive as `RX_DATA` (BASIC 57) or as a `DATA_RXD` notification depending on subscription state.
- `SET_POSITION` / `GET_POSITION` and `SET_TIME` work.
- BLE link survives long sessions (hours) when the host respects MTU and does not flood writes.

---

## 9. Reference implementations (online)

Two independent open-source implementations of this BLE protocol exist and agree on the framing, UUIDs, command IDs, and notifications above. All file links below resolve directly on github.com — no clone required.

### benlink (Python, `bleak`-based; cross-platform)

- Repo: https://github.com/khusmann/benlink
- BLE link layer (UUIDs, write/indicate plumbing): https://github.com/khusmann/benlink/blob/main/src/benlink/link.py
- Protocol package (frame, message, command definitions): https://github.com/khusmann/benlink/tree/main/src/benlink/protocol
  - Command/message catalog: https://github.com/khusmann/benlink/blob/main/src/benlink/protocol/command/__init__.py
  - GAIA frame definition: https://github.com/khusmann/benlink/tree/main/src/benlink/protocol/command
- High-level controller API (good map of which commands map to which behaviors): https://github.com/khusmann/benlink/blob/main/src/benlink/controller.py
- Author's note that audio (RFCOMM) is unfinished and Linux-only: https://github.com/khusmann/benlink/blob/main/src/benlink/audio.py

### HTCommander (C# / .NET; Windows + macOS via CoreBluetooth P/Invoke)

- Repo: https://github.com/Ylianst/HTCommander
- Command-group / command-id / notification enums (the authoritative C# list mirroring §5–§7 of this doc): https://github.com/Ylianst/HTCommander/blob/main/src/radio/Radio.cs
- Windows BLE transport (WinRT GATT): https://github.com/Ylianst/HTCommander/blob/main/src/radio/RadioBluetooth.cs
- macOS BLE transport (CoreBluetooth via Objective-C runtime P/Invoke): https://github.com/Ylianst/HTCommander/blob/main/src/radio/MacBluetoothBle.cs

### Cross-checks

- The two implementations were written independently and agree on:
  - the three UUIDs in §2,
  - the `FF 01 <flags> <n_pay> <cmd_grp:u16> <cmd_id:u16> <payload>` frame in §3,
  - the BASIC=2 / EXTENDED=10 split in §4,
  - the notification subscription model in §7.

If a third implementation is built, it should be considered correct only when it round-trips `GET_DEV_INFO`, `READ_RF_CH`, and a `REGISTER_NOTIFICATION` for HT_STATUS_CHANGED against a real radio.

### Background / community context (optional reading)

- HTCommander project page (UI screenshots, supported features list): https://github.com/Ylianst/HTCommander#readme
- benlink project page (protocol notes, motivation): https://github.com/khusmann/benlink#readme
- Original GAIA framing convention (Qualcomm/CSR Bluetooth audio chips — same `FF 01` SOF used here): https://github.com/JC-Connell/CSR-GAIA-Protocol

