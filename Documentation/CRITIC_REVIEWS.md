# Critic reviews

Six rounds of independent review after the first complete implementation. Each round
was carried out by a separate reviewing agent with no stake in the code, given the
brief's prompt verbatim and read-only access to the repository, the documentation and
the design renderings in `design/renders/`.

Every round records what was found, **what was implemented, what was rejected and
why**. A review that produces only agreement is not a review, and a review where
every finding is accepted is not one either.

Rounds 1, 3 and 4 were gathered concurrently to save wall-clock time; their findings
were then implemented in order, and rounds 2, 5 and 6 each ran against the code as it
stood after the previous round's changes. Nothing was implemented before the round
that found it.

## Standing constraint on every round

There is no Apple toolchain in this environment. No round could build or run the
application; every round reviewed source, copy, flows and — for the design round —
renderings redrawn from the design system's own values. `Tools/swiftcheck.py` and
`Tools/pbxcheck.py` were re-run after every round's changes, and are the only
mechanical verification available. See `QA.md`.

---

## Round 1 — Product

> *You are a ruthless consumer product leader reviewing Dubplate. Evaluate whether
> this actually solves the stated producer problem. Identify unnecessary features,
> missing workflows, friction, confusing terminology and anything that weakens the
> core promise: "Hear your music like it's already out." Do not be polite. Prioritize
> issues by severity.*

The reviewer returned seven severe findings, thirteen major, six minor, a delete
list and a table of copy it judged off-voice. The summary it ended on was fair and
uncomfortable: *"Until pressing Play on the phone reliably plays the record the Mac
just made, nothing else in this product matters — and right now the code path for
that moment skips the track and shows an apology."*

### Implemented

| Finding | What was wrong | What changed |
| --- | --- | --- |
| **S1** A release could never be renamed | `LibraryStore.update(release:)` had no callers, and the fast path — dropping a folder on the library — named the record after the folder, permanently | Title and artist are `TextField`s in the release header on the Mac, committed on submit and on focus loss |
| **S2** Play on the phone never downloaded | `startCurrentItem` reported `.notDownloadedYet` and advanced, so a freshly synced album skipped every track in turn | Playback holds on the track, asks for the file, and continues when it lands. A line says so. `AppServices.fetchAndResume` |
| **S3** Availability was per-device but synced | `availabilityRaw` was a stored, mirrored property, so the phone told the Mac its own master was unavailable — and it flapped every cycle | `localPresence`/`transferState` are `@Transient`; `MediaAvailability` establishes them by looking at the disk |
| **S4** "Remove from Release" destroyed every mix | Wired straight to `delete(track:)`, no confirmation | Split: **Move to Inbox** keeps everything; **Delete Track and Its 4 Mixes…** names the cost and confirms |
| **S5** Deleting a release leaked into iCloud | `SyncCoordinator.forget(assetIDs:)` had no callers | Deletion returns its asset identifiers and `AppServices.delete(release:)` hands them to sync. Confirmation names the track and mix count |
| **S6** Checksum dedupe was library-wide | The same master could not appear on two records, and a lost file could not be restored by re-dropping it — which is what the error copy told you to do | Dedupe is scoped to the target; a match elsewhere reuses the file for a second version; a match whose bytes are gone is treated as a repair |
| **S7** Folders could not be dropped | Every handler filtered on an audio extension, which a directory URL does not have | `DroppedFiles.expand` walks two levels, skips packages, sorts naturally. Tested |
| **M1** Two settings wired to nothing | "Download over cellular" did not restrain anything | `NetworkPath` + `SyncCoordinator.canDownloadNow` make it real; "Keep recently played offline" was deleted |
| **M2** Instrument names as revision markers | `05 Bass.wav` became a nameless track five, and a folder of instrumentals replaced every vocal mix at full confidence | `descriptorWords` only strip when a real word survives; `variantWords` are added as a version but never made current |
| **M4** The core loop was a modal | Dropping a bounce on a track cost a sheet and two clicks, every time | An unambiguous drop lands, becomes current and plays. The sheet is for the ambiguous case |
| **M6** Gapless failures were detected and never mentioned | `lastTransitionWasGapless` had no readers | A line above the sequence: which track, which rate, and what to do about it |
| **M7** The ordering signal was decided by an always-true test | `dropIndex` is `urls.enumerated()`, so `.filename` could never be chosen | Multi-file drops sort by filename, and the sheet says so |
| **M8** A stray image replaced the cover | Instant and destructive | Confirmed, naming the file, saying the old cover is deleted |
| **M9** Only the first file of a track drop was used | The rest were discarded after a success animation | All of them are added, in version order |
| **M10** Lock Screen artwork went stale | `invalidateArtwork` had no callers | Changing a cover invalidates both caches through `LibraryStore.artworkDidChange` |
| **M11** The inspector's track number reverted | Every repair renumbers from list position | Read-only, with a tooltip pointing at the drag list |
| **M12** "Remove Download" silently no-opped | It refuses when nothing is uploaded, and said nothing | A fourth state: **Only Copy Is Here**, disabled, explaining why |
| **M13** A full iCloud was a log line | `DubplateError.storageFull` was never constructed | Raised through the transfer service into the coordinator's error state |
| **N1–N4, N6** | Sidebar "Play" navigated; feature credits were parsed and thrown away; the retry button could never appear; `Image(systemName: "")`; media excluded from Time Machine for local-only users | All fixed |

### Deleted, as recommended

The phone's file importer (it contradicted the product's own sentence and put files
where the phone could not show them), the "Download Quality" row (a setting whose
content was "this is not a setting" — the sentence moved to About), the editable
disc-number field, and four unused columns from a schema that is mirrored to
CloudKit, where an unused column is permanent.

### Rejected

**"Delete two of the three preview modes."** The reviewer had not been given the
brief, which specifies Stream, Gallery and Motion as a deliverable. Its underlying
observation was right, though, and was the real bug: Motion was built around a track
canvas that nothing could set — `setCanvas(from:for:)` had no callers and the drop
handler rejected `.mov` outright. Dropping a video on a track now sets that track's
canvas, dropping one on a release sets the release's motion artwork, and the stored
loop trim is applied.

**"Delete the waveform pipeline."** Also right that it was dead — peaks were measured
on every import, stored, and drawn nowhere. Wired up rather than removed: the shape
of a mix is read faster than a number, and the data was already being paid for.

---

## Round 3 — Producer workflow

> *You are a professional record producer who works daily in Pro Tools, Logic and
> Ableton. You receive new bounces constantly and test albums repeatedly away from
> the studio. Review Dubplate purely as a working producer. Find every unnecessary
> click and every missing workflow.*

This round was asked to count interactions for six specific tasks. Its verdicts:

| Task | Before | After |
| --- | --- | --- |
| 8 bounces → sequenced album with artwork | 4 + a Finder trip, because folders were refused and the two wells filtered each other out | 3, folder in one drag, one well that routes by type |
| New bounce of track 4 becomes current and plays | 3, and the third was needed because nothing played | 1 |
| Yesterday's mix, then back to today's | 5, behind a modal that hid the transport, with no dates to identify "yesterday" | 2, in the inspector, with dates |
| Studio Mac → phone | 3 taps and a blind wait | 1 tap; play fetches what it needs |
| Reordering ten tracks | 1 drag per move | unchanged — it was already right |
| Which file on disk a version came from | 4 clicks, and the answer was a UUID under a shard directory | 0 beyond opening the list; the row shows `Bounces/06 Midnight mix 5.wav` |

### Implemented beyond round 1's overlap

- **Space was bound twice** — on the menu command and on the play button, which sits
  in the player bar on every Mac screen. Typing `NO SIGNAL` into a title toggled
  playback. The button's shortcut is gone.
- **A `Button` nested inside another `Button`'s label** in the phone's version picker
  and on the home screen. On iOS the inner control is unreliable, and it was
  "Set as Current" — the only committing action the phone has.
- **Auditioning a mix of a track that was not playing replaced the whole queue** with
  a single item, so the record stopped at the end of it. `AppServices.audition` now
  swaps in place when the track is already queued.
- **Versions carried no date anywhere**, though the model had two and
  `Formatting.relativeDate` existed with no callers.
- **The version list was modal**, so the scrubber and transport were unreachable
  during exactly the comparison they exist for. It is a pane of the inspector.
- **Downloads covered only the current mix**, so A/B was impossible offline — which
  is most of what the phone is for.
- **The Inbox had no exit** — `move(track:to:)` had no callers.
- **The new-release sheet overrode an explicitly chosen release type** after every
  drop.
- **The track row showed the current mix, not the playing one**, so you could walk
  away believing the record now sounded like what you had just auditioned.
- **Version notes were rendered and could never be written** — `annotate` had no
  callers. Now behind "Add Note…".
- **The loudness setting only affected files imported afterwards.**

### Its trust verdict, kept as a standing test

> *"What is not trustworthy is the layer where a producer's hand meets it:
> destructive actions with no confirmation and no undo, and non-destructive actions
> that silently do nothing. Both failures teach the same lesson, which is not to
> leave anything in Dubplate that isn't also somewhere else."*

Every destructive action now confirms and names what it costs, and every drop
reports what it did — including doing nothing.

---

## Round 4 — Engineering

> *You are a principal Apple platforms engineer. Review this codebase for
> architecture problems, concurrency issues, sync bugs, memory problems, media
> playback edge cases, CloudKit mistakes, persistence risks and maintainability
> issues. Assume this app may eventually have tens of thousands of users.*

The most valuable round. Seven severe findings, seventeen major, twelve minor, and a
separate list of things that would not compile.

### The four that would have shipped as user-visible failures

**Every seek advanced to the next track.** `AVAudioPlayerNode.stop()` fires the
completion handler of everything it had scheduled. `seek` calls `start`, which stops
the node and re-schedules *the same item identifier*; the stale completion then
arrived, matched the new entry, and reported the track as finished. Scrubbing to 0:30
of track 3 started track 4. Completions now carry a per-scheduling generation token.

**Repeat-one played once and went silent.** `advance()` returns `true` without moving,
and the controller then took the "already rendering" branch and scheduled nothing —
while the transport went on claiming to play.

**A failed CloudKit upload was recorded as a success.** `modifyRecords` does not throw
on per-record failure; it returns per-record results, which were discarded with `_ =`.
Quota-exceeded therefore meant "uploaded", and **"Remove Download" would then delete
the only copy of a master.** This is the single most dangerous defect either round
found.

**Four relationships had no inverse.** CloudKit mirroring refuses such a model, the
store fails to open, and `containerWithFallback` would have turned that into a quiet
downgrade to a local-only library where the account looked fine and nothing ever
synced. `swiftcheck.py` now refuses an unpaired relationship; the check was verified
by removing one and confirming it fires.

### Also implemented

Account switches and zone deletions (the old change token was reused against a
different database, and "uploaded" flags referred to records the new account cannot
see); launch blocking on uploading the whole library; the index overwriting its own
uploaded flags so one bounce re-uploaded a twenty-track album; an unbounded artwork
cache (240 covers at 2048px is a gigabyte of bitmaps); Now Playing republished five
times a second; analysis fetching every unanalysed asset to take forty and then
stopping silently; loudness re-summing a 19,200-frame window every 4,800 samples;
media bytes deleted before the row pointing at them was committed; models mutated
after an `await` with no check that a merge had deleted them; a zero-frame file
re-entering `start()` from inside `start()`; a route change while paused restarting
from 0:00; `NWPathMonitor.currentPath` read before the first update, so the first
download after every launch refused itself.

### The compile-risk list

Four of the nine were acted on directly: the `FailedRecordSave` parameter typed as a
tuple; `didSet` observers on stored properties of an `@Observable` class (rewritten as
computed properties over `UserDefaults`, because a preference that silently fails to
persist is worse than none); `MediaStore` declaring `Sendable` while storing a
`FileManager`; and an optional-chained relationship in a `#Predicate`, which SwiftData
translates unreliably. `MainActor.assumeIsolated` in notification observers was
replaced with a `Task { @MainActor in }` hop, and the `deinit` that touched
main-actor state was removed.

The remaining strict-concurrency warnings — capturing `self` in an AVFoundation
completion, and `@MainActor` closures assigned to non-isolated properties — are real
and are the substance of the Swift 6 migration recorded in `ARCHITECTURE.md`. They
are warnings under the Swift 5 language mode this ships in, and fixing them properly
means restructuring the callback boundaries, which is its own change.

### Rejected

**"`open(release:)` should not download."** Round 1 had asked for the opposite. Round
4 was right about the mechanism and round 1 right about the moment: browsing ten
records on a phone must not pull ten albums, but pressing play must not skip. Opening
a release now only repairs and looks; audio arrives when someone presses play, or asks
for the record to be held offline. Both complaints are satisfied by separating them.

**"Delete `Release.watchFolderBookmark`."** Correct that it is unused. Kept, because
the alternative is a schema migration on a mirrored store to add one optional
column later.
