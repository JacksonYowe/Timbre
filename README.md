# Timbre

A system-wide equaliser for macOS on Apple silicon, built for people new to EQ.

> **Built on [SystemEQ for Mac](https://github.com/denzam/SystemEQ-for-Mac) by denzam.** Timbre's audio capture and filter engine are adapted from SystemEQ, and like SystemEQ, Timbre is free software under the GNU GPL v3. Thank you to denzam for the original.

- **True 31-band parametric EQ.** Every band's shape, frequency, gain and width can be edited, through simple tone sliders, a 31-band graphic view or a full parametric table.
- **EQ files.** Imports EqualizerAPO / AutoEQ `ParametricEQ.txt` and `GraphicEQ.txt` files and frequency/gain lists. Hot-swap presets instantly, and edits to files on disk apply live.
- **Knows what's playing.** Reads Spotify (song vs podcast vs ad) and looks up the genre, spots video, calls and games in other apps, and switches presets using rules you set.
- **Your IEMs.** "Set up custom IEM" reads a frequency-response graph from a screenshot and builds a correction plus a tuned version of every auto-switch preset.
- **Per-output gear.** Remembers which headphones are on which output (Bluetooth by name; it asks for the 3.5 mm jack).
- **Safe.** Crossfaded, click-free switching, automatic headroom, an output limiter, and a safety net that gives your sound back if capture fails.

## Requirements
- macOS 15 or later, Apple silicon
- Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Build
```bash
./build.sh
```
This generates the Xcode project, builds a Release copy, installs it to `/Applications` and opens it. To use your own bundle identifier, put it in an untracked `.bundle-id` file, for example `com.yourname.Timbre`.

Run the self-tests with `Timbre.app/Contents/MacOS/Timbre --selftest`.

On first use, macOS asks for **System Audio Recording** (to equalise your sound) and for permission to **control Spotify** (to see what's playing).

## Credits
- The audio capture and filter engine are adapted from [SystemEQ for Mac](https://github.com/denzam/SystemEQ-for-Mac) (GPLv3).
- The neutral in-ear target and file formats come from [AutoEQ](https://github.com/jaakkopasanen/AutoEq).
- Genre data comes from the iTunes Search API.
- Fonts are Manrope, Instrument Serif and JetBrains Mono (SIL Open Font License).

## License
GPL-3.0. See [LICENSE](LICENSE). You're free to use, study, change and share Timbre; if you distribute a modified version, it must also be GPL-3.0 with its source available.
