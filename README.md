# Dubplate

Hear your music like it's already out.

Dubplate is a private release simulator for producers. Bounce a record out of Logic,
Pro Tools, Ableton or FL Studio, drag the files into Dubplate on your Mac, add
artwork and a sequence, and then listen to it on your iPhone exactly as though it
had been released — artwork on the Lock Screen, gapless transitions, AirPods,
AirPlay, the car.

It is not a DAW, a distributor, a streaming service, a collaboration tool or a
place to put files. It has one job, and everything in it points at that job.

## What's here

| Path | What it is |
| --- | --- |
| `Apps/DubplateMac` | The Mac application: where records get made |
| `Apps/DubplateiOS` | The iPhone application: where they get heard |
| `Packages/DubplateCore` | Model, import heuristics, media storage |
| `Packages/DubplateAudio` | Gapless playback, Now Playing, format inspection, loudness |
| `Packages/DubplateSync` | CloudKit catalogue sync and media transfer |
| `Packages/DubplateUI` | Design system, shared views, the three preview modes |
| `Tests/` | Unit and UI tests |
| `Documentation/` | Product, architecture, data model, sync, QA, critic reviews |
| `Tools/` | Project generation, static checks, icon and fixture generation |

## Building

Requires **Xcode 16 or later** on macOS. Deployment targets are macOS 15 and
iOS 18 — see `Documentation/ARCHITECTURE.md` for why.

```sh
git clone <this repository>
cd dubplate-OSX
open Apps/Dubplate.xcodeproj
```

Pick the **Dubplate Mac** or **Dubplate iOS** scheme and run. The shared modules are
consumed as a local Swift package, so Xcode resolves them from the `Package.swift`
at the repository root with nothing to install.

The application icon is drawn procedurally rather than committed as art from
somewhere else — `Tools/make_app_icon.py` writes both asset catalogs, and the PNGs
it produces are checked in so a clone builds without running it.

Before the first build on your own machine, set a development team on both
application targets (Signing & Capabilities). A free Apple ID is enough: **Dubplate
ships with sync off** so that it builds and runs on a Personal Team, which cannot
sign an application that asks for iCloud or Push Notifications at all. Everything
except syncing between devices works — library, import, sequencing, artwork,
playback, versions — and the interface says once that it is not syncing.

To turn sync on with a paid membership, see *Turning on iCloud sync* in
`Documentation/SYNC.md`. It is four entitlement keys per target and a container that
exists in your account. iCloud sync additionally needs the
`iCloud.com.dubplate.app` container to exist in your developer account; **without
it Dubplate still runs and still works, entirely locally** — it falls back to a
local store and says so once.

### Running the tests

```sh
swift test                                        # the shared modules
xcodebuild test -scheme "Dubplate Mac"            # modules + Mac UI journey
xcodebuild test -scheme "Dubplate iOS" \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

### Test material

The repository contains no recorded music. Generate the synthetic fixtures — sine
tones, sweeps, and procedurally drawn covers — with:

```sh
python3 Tools/make_test_audio.py           # add --large for the 5- and 45-minute files
python3 Tools/make_placeholder_art.py
```

### Working on the code

```sh
python3 Tools/swiftcheck.py          # whole-program consistency checks
python3 Tools/pbxcheck.py            # validates the Xcode project
python3 Tools/generate_xcodeproj.py  # after adding or removing an application source file
python3 Tools/make_app_icon.py       # redraws the application icon and both asset catalogs
python3 Tools/render_design.py       # redraws Documentation/design/renders (needs Chromium)
```

`swiftcheck.py` is not a substitute for the compiler — it exists so the tree can be
checked for consistency (unresolved type names, module dependencies that do not
match the imports, SwiftData/CloudKit model rules, house style) on any machine, and
quickly in CI. `xcodebuild` remains the authority.

## Supported audio

WAV, AIFF, CAF, FLAC, ALAC, AAC, M4A and MP3, at any sample rate and bit depth the
system can open — 44.1, 48, 88.2 and 96 kHz, 16- and 24-bit, and 32-bit float.

**Dubplate never re-encodes, resamples, normalises or processes your audio.** Files
are copied into managed storage exactly as they were bounced, and played back in
their own format. The original in your bounce folder is never moved, renamed or
deleted.

## Privacy

Everything stays inside your own Apple account. There is no Dubplate server, no
account to create, no analytics SDK, no advertising SDK, and nothing is ever made
public — no shares, no public database records, no URLs that exist outside your
iCloud account. The only network traffic Dubplate makes is to Apple's CloudKit, and
only when you have sync turned on. See `Documentation/SYNC.md`.
