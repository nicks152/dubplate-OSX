# QA

## What has and has not been run

This repository was built in a Linux container with no Apple toolchain. **No Swift
code in it has been compiled, and no test in it has been executed.** Saying otherwise
would be the single most damaging thing this document could do, so it is said first.

What *has* been run, and what it establishes:

| Check | Result | What it establishes |
| --- | --- | --- |
| `python3 Tools/swiftcheck.py` | 110 files, 16,778 lines, **0 errors, 0 warnings** | Delimiters balance; no duplicate declarations; every import matches a declared dependency; ~2,000 capitalised identifiers all resolve, per file, against what that file's own imports make visible or a reviewed platform symbol; every `@Model` obeys CloudKit's rules, including that every relationship has an inverse; every `@Environment` read has a matching injection in each application, and every type injected is `@Observable`; every public struct built from another module has a public initialiser; no module reaches for a SwiftUI-only collection helper without importing SwiftUI; no Logger message is built by concatenation; no closure that captures `self` — including an escaping `Task { … }`, which captures it without saying so — uses a member without writing `self.`; no force unwraps, `try!`, `as!`, `print(`, or oversized files |
| `python3 Tools/pbxcheck.py` | 95 objects, 4 targets, **0 problems** | The Xcode project parses as an OpenStep plist; every object reference resolves; every file reference exists on disk; every target has a sources phase and compiles at least one file |
| `python3 Tools/heuristics_reference.py` | **35/35 cases pass** | The filename and version-matching rules behave as intended on a table of real bounce names |
| BS.1770 coefficients, checked numerically | max error 4e-14 vs the published 48 kHz values | The K-weighting filters are correct, so loudness numbers are not all wrong by a constant |
| Gapless fixture continuity | boundary step 0.028782 vs 0.028794 max in-file | The two halves of the test tone join with no discontinuity, so a click at a track boundary would be the player's fault |
| WAV fixtures re-parsed with Python's `wave` | all 8 valid | The synthetic audio is well-formed at every rate and depth |

Five of these checks were verified the only way a check can be: by deliberately
breaking the code — deleting an `.environment()` injection, removing a relationship's
`inverse:`, calling a method that does not exist, dropping `@Observable` from a type
the environment carries, calling SwiftUI's `move(fromOffsets:toOffset:)` from the
model layer, joining two halves of a log message with `+` — and confirming the
checker named the exact line that would have failed. The last three were added after
a real build produced exactly those errors, which is the only reason they exist:
each was a gap the checker did not know it had. The last of those was added because critic
round 5 found two real compile errors that nothing here would have caught; it has
since caught two more of the same kind.

**What that does not establish:** that it compiles. `swiftcheck.py` cannot type-check
an expression, resolve an overload, or know whether a SwiftUI modifier exists on the
view it is applied to. Expect to fix compiler diagnostics on a first build. The
checks above are designed to make those diagnostics few and local rather than
structural.

## First run on a Mac

1. `open Apps/Dubplate.xcodeproj`, set a development team on both application
   targets, build the **Dubplate Mac** scheme.
2. `python3 Tools/make_test_audio.py && python3 Tools/make_placeholder_art.py`
3. `swift test` for the module tests, then the two `xcodebuild test` invocations in
   the README.

If the iCloud container does not exist in your developer account, the application
falls back to a local store and shows one sentence about it. That is the intended
behaviour, not a failure — Dubplate is useful without iCloud.

## The acceptance journey

The product is done when this is excellent. Each step lists what to look for, not
just what to press.

| # | Step | What must be true |
| --- | --- | --- |
| 1 | Launch Dubplate on the Mac | Window is a wall of covers, not a file list. Empty library says something useful. |
| 2 | ⌘N, choose Album | Sheet is four fields, focus is already in the title. |
| 3 | Type "NO SIGNAL" | — |
| 4 | Type an artist | Pre-filled from the last release. |
| 5 | Drag artwork onto the well | Cover appears immediately. |
| 6 | Drag 8 WAVs in | Sequenced from the numbers in the filenames; the sheet says which signal it used. Under 30 seconds from step 2. |
| 7 | Drag track 6 above track 3 | Reorder animates; numbers renumber; no edit mode to enter first. |
| 8 | Press Play | Audio starts within a beat. Mini player fills in. |
| 9 | Drop another bounce onto track 4 | Sheet offers three choices with *Add as New Version* pre-selected; suggestion line names the track and why it thinks so. |
| 10 | Wait for sync | Mac says "Syncing" briefly, then nothing. |
| 11 | Open Dubplate on iPhone | Release is there with artwork. |
| 12 | Album appears | Covers, not filenames. |
| 13 | Play it | Starts within a beat. |
| 14 | Lock the phone | — |
| 15 | Check the Lock Screen | Correct artwork, track, artist, album, duration and a moving position. |
| 16 | Walk around | Playback continues; the track advances by itself. |
| 17 | Connect AirPods | Audio follows; unplugging wired headphones pauses instead of playing out loud. |
| 18 | Listen through a track change | **No gap.** Same sample rate throughout. |
| 19 | Switch track 4 back to an earlier version | Plays from the same moment, not from the top. |
| 20 | Keep listening | The rest of the record continues; the Mac shows the change. |

## Scenarios to run by hand

Grouped by what they are trying to break. Everything here came from a specific
concern in the design, not from a checklist.

### Import
- Drop 1 file. Drop 40. Drop a folder. Drop a folder of folders.
- Drop the same file twice — the second is recognised as a duplicate, not stored again.
- Drop a 1.4 GB 45-minute 96/24 master — the interface must not freeze; progress must move.
- Drop a `.logicx` bundle and a `.txt` — skipped by name, reported in the sheet.
- Drop a file that is valid audio with a zero-length body.
- Drop while the previous import is still running.
- Drop 8 files with no numbers, in a random Finder sort.
- Drop 8 files where two share a number.
- Rename the source file in Finder after import; playback still works (Dubplate copied it).
- Delete the source file after import; playback still works.

### Playback
- Play a whole album through without touching anything.
- Skip forward rapidly 20 times.
- Skip backwards from the first track.
- Scrub while playing; scrub while paused; scrub to the last second of a track.
- Play an album where track 3 is 96 kHz and everything else is 48 — the transition
  into and out of it is the one that cannot be gapless.
- Play a mono file after a stereo one.
- Play a 32-bit float file.
- Switch version mid-track and confirm the position holds.
- Switch version of a track that is *not* playing and confirm the queue updates.
- Delete the version that is currently playing.
- Play a record whose audio is still in iCloud: it holds and says so, and the track
  that *was* playing stops rather than continuing under a paused interface.
- Play a record where every file is unreadable, with repeat on: it stops with an
  error after one pass rather than cycling.
- Play a truncated WAV — one whose header promises more than the file holds. It
  should move on after about three seconds, not count to a length that is not there.
- Pause for a minute, then press play. It must resume, not skip.
- Unplug headphones at the exact moment of a track change.
- Drop a new mix onto track 8 while track 3 is playing: track 3 keeps playing.

### System integration
- Lock screen: artwork, all four text fields, scrub, next, previous.
- Control Centre: play/pause, position.
- Take a phone call mid-track — pauses, and resumes afterwards.
- Ask Siri something — pauses, resumes.
- Unplug wired headphones — pauses. Never plays out of the speaker.
- Connect and disconnect AirPods mid-track.
- AirPlay to a speaker and back.
- Bluetooth in a car; skip with the steering wheel controls.
- Background the app for 30 minutes and come back.

### Sync
- Mac → iPhone: a new release, a reorder, a retitle, a new version, a deleted track.
- iPhone → Mac: switching which version is current.
- Both offline, both edit the sequence, both come back — no track is lost.
- Both offline, both add a version — both bounces survive, numbered 6 and 7.
- Airplane mode for the whole session; then turn it off.
- Sign out of iCloud mid-session — nothing local is removed.
- Sign back in — everything queues for upload.
- Kill the app mid-upload; relaunch; the upload resumes.
- Fill iCloud storage and import.

### Offline
- Download a release, enable airplane mode, play it end to end.
- Remove the download; confirm the release is still listed and the cover still shows.
- Try to remove a download for a release that has not finished uploading — refused.
- Play a track that has not been downloaded — it is skipped with an explanation and
  the rest of the record keeps playing.

### Data
- 100 releases, 1,000 tracks, several versions each: the library scrolls at 60fps.
- Artwork at 6000 × 6000: the grid does not stutter (ImageIO downsamples on decode).
- A corrupt JPEG as artwork.
- A release with no artwork, no year, no genre and no track titles — still a record.
- Titles in Japanese, Arabic and emoji.
- A 300-character track title.
- Quit during an import.

### Mac conventions
- ⌘N from the library, from a release, and with the cursor in a release title — the
  last of these must make a release, not type an "n".
- Space with the cursor in a release title types a space. Space anywhere else is
  play/pause.
- ⌘I on the library: greyed out. ⌘I on a release: the importer opens.
- Choose Dubplate from Finder's Open With for one WAV, and for eight at once.
- Quit with a release open; relaunch; the same release is open.
- Set Appearance to Dark on a Light Mac and open Settings and the iPhone window.

### Accessibility
- VoiceOver through the library, a release, and Now Playing — every control has a
  label; track rows read as "Track 6, Midnight, 3:42, 4 versions".
- Dynamic Type at every step including the accessibility sizes: type actually grows,
  nothing clips, and a sleeve title wraps to three lines rather than shrinking.
- VoiceOver: the mini player is a button and opens the player; the Explicit switch
  is named; a toast is announced when it appears; a cover that will not decode says
  so rather than reading as a record with no artwork.
- Reduce Motion: the playing indicator stops animating; transitions flatten.
- Keyboard only on the Mac: sidebar, grid, track list, transport.
- Contrast: check secondary and tertiary text against the ground at both appearances.

## Known limitations

1. **Nothing has been compiled.** See the top of this document.
2. A sample-rate change between two consecutive tracks cannot be gapless — the engine
   detects it in advance and logs it, but the transition has a short gap.
3. Watch folders are modelled (`Release.watchFolderBookmark`) but not implemented.
4. CarPlay is architecturally prepared — the audio layer has no interface dependency —
   but there is no CarPlay scene.
5. There is no Share Sheet extension on iOS; files come in through the Files importer.
6. Loudness measurement is opt-in and reads each file once; it is not incremental.
7. `MediaTransferService` reports per-file progress, not per-byte progress within a
   file, so a single very large upload shows as one long item.
8. Swift 6 language mode is not enabled — see `ARCHITECTURE.md`.
