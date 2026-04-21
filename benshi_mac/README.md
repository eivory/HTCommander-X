# Moved: benshi_mac is now eivory/bendio

The macOS Python library for two-way audio with BTech UV-Pro / Benshi-family
radios that used to live in this directory has been extracted to its own
standalone repository:

## → **https://github.com/eivory/bendio** ←

## Why

It made sense to develop the library alongside this Flutter repo while the
protocol was being reverse-engineered — the library's `docs/PROTOCOL_NOTES.md`
cross-references HTCommander-X's `lib/radio/` and `lib/platform/linux/`
implementations for things like the "BS AOC" audio-service detection and
the exact SBC codec parameters.

Now that the library is stable (full-duplex audio working, tests passing,
CI in place), it graduated to its own repo so that:

- It can be `pip install bendio`-able
- Contributors who only care about the Python library don't have to clone
  this whole Flutter repo
- HTCommander-X can stay focused on its Dart/Flutter audience
- Maintenance on each side doesn't require dual-commits

## History

Git history was preserved via `git subtree split --prefix=benshi_mac`. Every
commit under this directory — from the initial scaffold through the
live-mic-TX milestone — is in `eivory/bendio` with original authors,
dates, and messages.

Up to and including commit `b3c9706` ("Rename package benshi → bendio"),
this directory contained the full library source. The extraction happened
right after that commit.

## Going forward

**Bugs and features in the Python library** → file them against
[eivory/bendio](https://github.com/eivory/bendio/issues).

**HTCommander-X (this fork)** continues to evolve separately as a Flutter
app. See the top-level `README.md` (or the upstream
[`Ylianst/HTCommander`](https://github.com/Ylianst/HTCommander) /
[`dikei100/HTCommander-X`](https://github.com/dikei100/HTCommander-X)).

If HTCommander-X ever gets a native Dart/FFI macOS audio path (it currently
has Linux/Windows FFI bindings but no macOS), the bendio library's
`docs/PROTOCOL_NOTES.md` is the reference for what the radio expects on
the wire.
