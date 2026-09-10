# Architecture

## Deployment targets

**macOS 15, iOS 18, Swift 5 language mode, Xcode 16 or later.**

Chosen because SwiftData's CloudKit mirroring and the `@Observable` macro are both
materially more dependable at these versions than at 14/17, and because supporting
one version further back would mean either an availability check around a large part
of the interface or a second, older way of doing persistence. Dubplate is a new
product for people who keep their machines current; carrying an extra year of OS
support would cost more than it is worth.

Swift 5 language mode rather than Swift 6 is a deliberate, temporary choice: the
code is written to be data-race safe (actors around file and transfer work, `@MainActor`
on everything that touches the model or the interface, `Sendable` value types across
every boundary), but turning on full Swift 6 enforcement in the same change as the
first working build would mix two kinds of risk. It is the obvious next commit, not
a design position.

> These versions were chosen from the API surface the code uses, not verified
> against a live SDK — this repository was built in an environment with no Apple
> toolchain (see *Verification* below). Confirm against the installed Xcode before a
> first build; nothing in the code depends on a version newer than the ones above.

## Shape

```
Apps/DubplateMac ──┐
                   ├─→ DubplateUI ─→ DubplateAudio ─┐
Apps/DubplateiOS ──┘         │                      ├─→ DubplateCore
                             └─→ DubplateSync ──────┘
```

Four modules, and the dependency arrows only point one way.

**DubplateCore** — the model, the import heuristics, the media store. No AVFoundation,
no CloudKit, no SwiftUI. This is where nearly all of the logic that can be wrong
lives, which is why it is also where nearly all of the tests live.

**DubplateAudio** — playback and everything about files as audio. Depends on Core;
Core does not depend on it, which is why `AudioFileInspecting` is a protocol: the
library needs a file's duration at import time, and that is the one place the arrow
would otherwise have to point backwards.

**DubplateSync** — CloudKit. Split into a catalogue engine and a byte-transfer
service; `SYNC.md` explains why.

**DubplateUI** — the design system, every shared view, and `AppServices`, which is
the object both applications assemble at launch.

The two application targets are thin. `DubplateMacApp.swift` is under a hundred
lines and `DubplateiOSApp.swift` is under forty, because a screen that exists on both
platforms should exist once.

### Why one Swift package for four modules

The manifest at the repository root uses per-target `path:` so the folder layout on
disk is the layout in the documentation: sources under `Packages/`, tests under
`Tests/`. One manifest to keep consistent rather than four, and one package reference
in the Xcode project rather than four.

## The decisions worth arguing about

### Playback: AVAudioEngine, not AVQueuePlayer

Albums, live sets and DJ mixes have to run without a gap between tracks. An
`AVQueuePlayer` cannot promise that: it starts the next item when the previous one
finishes, and "when" is not sample-accurate. A single `AVAudioPlayerNode` with
consecutively scheduled files is — the last frame of one track is followed by the
first frame of the next with nothing in between.

The cost is that Dubplate owns things `AVPlayer` would have handled: the audio
session, the engine restart after a route change, and the position accounting across
scheduled items. That is `PlaybackEngine`, and it is the most carefully written file
in the repository.

The one case that cannot be gapless is a change of sample rate or channel count
between two tracks, because the node's output format has to be rebuilt. Dubplate
detects that before it happens rather than letting someone hear it.

### Storage: relative paths, always

An iOS application container is re-created with a new UUID on every install. An
absolute path persisted today is wrong after the next update. So `AudioAsset` and
`ArtworkAsset` store a path relative to the media store root, and `MediaStore` is the
only type that turns one into a URL. Media lives in Application Support, sharded two
characters deep so a library of thousands of bounces does not produce a directory
listing thousands of entries long, and is excluded from device backup — it is
reproducible from iCloud, and a 40 GB backup is not.

### Ordering: an explicit list

SwiftData relationships are unordered and CloudKit has no ordered to-many. A release
therefore stores `trackOrder` as an array of identifiers, and `orderedTracks`
reconciles it against the relationship on every read, so a track that arrived from
another device shows up at the end instead of disappearing. `SYNC.md` covers the
merge rules.

### `currentVersionID`, and no `isCurrent` flag

The brief describes both a `currentVersionID` on the track and an `isCurrent` flag on
the version. Storing both means two sources of truth for one fact, syncing
independently, and a class of bug where a track has two current versions or none.
`currentVersionID` is the authority; `TrackVersion.isCurrent` is computed from it. It
also self-heals: a track pointing at a version that was deleted on another device
falls back to the newest one it has rather than becoming unplayable.

### Import: plan first, write second

`ImportPlanner` turns a set of dropped URLs into an `ImportPlan` — a value type —
without touching the disk or the store. That is what makes the confirmation sheet
truthful, and what makes the whole of the drag-and-drop behaviour testable without a
`ModelContainer`.

### Not built

No dependency-injection container, no repository protocol per entity, no view-model
layer, no state store. `AppServices` is a struct of five objects. When a view needs
the library it asks the library.

## Concurrency

The main actor owns the model context, the player and every view. Two actors own the
work that must not happen on it: `MediaIngestor` (copying and hashing files) and the
sync actors (transfers and the durable index). Format inspection, waveform generation
and loudness measurement run in detached tasks at utility priority and hand back
value types.

Nothing in the audio path reads from SwiftData. `QueueBuilder` copies what playback
needs into `PlaybackQueueItem` once, when a record starts.

## Verification

This repository was written in a Linux container with no Apple toolchain, so
`xcodebuild` has never run against it. Rather than claim a build that did not happen,
the tree is checked by tools written for the purpose:

- **`Tools/swiftcheck.py`** parses every Swift file — comments and string literals
  stripped, `#if` branches understood — and reports unbalanced delimiters, duplicate
  declarations, imports a target does not depend on, capitalised identifiers that
  resolve to neither a declaration in scope nor the platform allowlist, SwiftData
  models that break CloudKit's rules, and house-style violations. It resolves
  1,900+ type references across 102 files. It is not a compiler and cannot type-check
  an expression, but it catches renames, typos and layering mistakes.
- **`Tools/pbxcheck.py`** parses the Xcode project as an OpenStep plist and checks
  that every object reference resolves, every file reference exists on disk, every
  target has a sources phase and compiles at least one file, and every configuration
  list has both configurations.
- **`Tools/heuristics_reference.py`** is a transliteration of the filename parser and
  version matcher used to exercise the *rules* against a table of real bounce names.
  Four genuine errors in the heuristics were found and fixed this way before the
  Swift was finalised.
- The BS.1770 filter coefficients are checked numerically against the values printed
  in the specification, and the synthetic gapless fixture is checked to be
  sample-continuous across the join.

`QA.md` records exactly what was and was not run, and what needs a Mac.
