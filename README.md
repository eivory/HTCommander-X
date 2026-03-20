# HTCommander-X

> Cross-platform fork of [HTCommander](https://github.com/Ylianst/HTCommander)
> by Ylian Saint-Hilaire — adding Linux support and an Avalonia-based UI.

![HTCommander-X screenshot](docs/images/htcommander-x.png)

An Amateur radio license is required to transmit using this software. You can get [information on a license here](https://www.arrl.org/getting-licensed).

### What's New in HTCommander-X

- **Cross-platform** — runs on Linux and Windows
- **Avalonia UI** replaces WinForms, with Light / Dark / Auto themes
- **Linux Bluetooth** via native RFCOMM sockets + BlueZ D-Bus discovery
- **Linux audio** via PortAudio output + parecord mic capture, espeak-ng TTS
- **Real-time spectrogram** visualization
- **Detachable tabs** — right-click any tab to open in a separate window
- **Multi-radio support** with active radio selection submenu
- **Single-instance enforcement** with lock file
- **VFO frequency mode toggle** via channel context menu
- **Drag-and-drop channel copy** between slots
- **AGWPE TCP server** for external TNC clients
- **Built-in SMTP/IMAP** for Winlink email integration
- **Audio clip manager** — record, rename, and transmit WAV clips
- **Recording to WAV files** from radio audio
- **APRS station markers** on map with OpenStreetMap

### Acknowledgements

- **Ylian Saint-Hilaire** — original [HTCommander](https://github.com/Ylianst/HTCommander) author and maintainer
- **Kyle Husmann, KC3SLD** — [benlink](https://github.com/khusmann/benlink) Python library for GAIA protocol decoding, RFCOMM channel discovery, and audio codec reference
- **SarahRoseLives** — [flutter_benlink](https://github.com/SarahRoseLives/flutter_benlink) Flutter/Dart implementation, initialization sequence and VR-N76 quirks reference
- **Lee, K0QED** — [APRS-Parser](https://github.com/k0qed/aprs-parser)
- **OpenStreetMap** — [openstreetmap.org](https://openstreetmap.org), free geographic data for the world

---

## Information below is from the [original project](https://github.com/Ylianst/HTCommander):

### Radio Support

The following radios should work with this application:

- BTech UV-Pro
- BTech UV-50Pro (untested)
- RadioOddity GA-5WB (untested)
- Radtel RT-660 (Contact Developers)
- Vero VR-N75
- Vero VR-N76 (untested)
- Vero VR-N7500 (untested)
- Vero VR-N7600

### Features

Handi-Talky Commander is starting to have a lot of features.

- [Bluetooth Audio](https://github.com/Ylianst/HTCommander/blob/main/docs/Bluetooth.md). Uses audio connectivity to listen and transmit with your computer speakers, microphone or headset.
- [Speech-to-Text](https://github.com/Ylianst/HTCommander/blob/main/docs/Voice.md). Open AI Whisper integration will convert audio to text, a Windows Speech API will convert text to speech.
- [Channel Programming](https://github.com/Ylianst/HTCommander/blob/main/docs/Channels.md). Configure, import, export and drag & drop channels to create the perfect configuration for your usages.
- [APRS support](https://github.com/Ylianst/HTCommander/blob/main/docs/APRS.md). You can receive and sent APRS messages, set APRS routes, send [SMS message](https://github.com/Ylianst/HTCommander/blob/main/docs/APRS-SMS.md) to normal phones, request [weather reports](https://github.com/Ylianst/HTCommander/blob/main/docs/APRS-Weather.md), send [authenticated messages](https://github.com/Ylianst/HTCommander/blob/main/docs/APRS-Auth.md), get details on each APRS message.
- [BSS support](https://github.com/Ylianst/HTCommander/blob/main/docs/BSS-Protocol.md). Support for the propriatary short message binary protocol from Baofeng / BTech.
- [APRS map](https://github.com/Ylianst/HTCommander/blob/main/docs/Map.md). With Open Street Map support, you can see all the APRS stations at a glance.
- [Winlink mail support](https://github.com/Ylianst/HTCommander/blob/main/docs/Mail.md). Send and receive email on the [Winlink network](https://winlink.org/), this includes support to attachments.
- [SSTV](https://github.com/Ylianst/HTCommander/blob/main/docs/SSTV.md) send and receive images. Reception is auto-detected, drag & drop to sent.
- [Torrent file exchange](https://github.com/Ylianst/HTCommander/blob/main/docs/Torrent.md). Many-to-many file exchange with a torrent file transfer system over 1200 Baud FM-AFSK.
- [Address book](https://github.com/Ylianst/HTCommander/blob/main/docs/AddressBook.md). Store your APRS contacts and Terminal profiles in the address book to quick access.
- [Terminal support](https://github.com/Ylianst/HTCommander/blob/main/docs/Terminal.md). Use the terminal to communicate in packet modes with other stations, users or BBS'es.
- [BBS support](https://github.com/Ylianst/HTCommander/blob/main/docs/BBS.md). Built-in support for a BBS. Right now it's basic with WInLink and a text adventure game. Route emails and challenge your friends to get a high score over packet radio.
- [Packet Capture](https://github.com/Ylianst/HTCommander/blob/main/docs/Capture.md). Use this application to capture and decode packets with the built-in packet capture feature.
- [GPS Support](https://github.com/Ylianst/HTCommander/blob/main/docs/GPS.md). Support for the radio's built in GPS if you have radio firmware that supports it.
- [Audio Clips](https://github.com/Ylianst/HTCommander/blob/main/docs/Voice-Clips.md) record and playback short voice clips on demand.
- [AGWPE Protocol](https://github.com/Ylianst/HTCommander/blob/main/docs/Agwpe.md). Supports routing other application's traffic over the radio using the AGWPE protocol.
- [APSK 1200 Software modem](https://github.com/Ylianst/HTCommander/blob/main/docs/SoftModem.md) with ECC/CRC error correction support.

### Installation

Download the [MSI Installer](https://github.com/Ylianst/HTCommander/raw/refs/heads/main/releases/HTCommander-0.59.msi). Except for Open Street Map data, and checking for updates on GitHub, this tool does not sent data on the Internet. Pair your radio to your computer and run the application. If your computer does not have Bluetooth, you can get a inexpensive Bluetooth USB dongle. Make sure Bluetooth LE is supported. Pairing can be a bit tricky, you have to pair TWO Bluetooth devices in quick succession, [Bluetooth pairing instructions here](https://github.com/Ylianst/HTCommander/blob/main/docs/Paring.md).

### Demonstration Video

[![HTCommander - Introduction](https://img.youtube.com/vi/JJ6E7fRQD7o/mqdefault.jpg)](https://www.youtube.com/watch?v=JJ6E7fRQD7o)

### Credits

This tool is based on the decoding work done by Kyle Husmann, KC3SLD and this [BenLink](https://github.com/khusmann/benlink) project which decoded the Bluetooth commands for these radios. Also [APRS-Parser](https://github.com/k0qed/aprs-parser) by Lee, K0QED.

Map data provided by [openstreetmap.org](https://openstreetmap.org), the project that creates and distributes free geographic data for the world.
