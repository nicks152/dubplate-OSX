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

> *You are a ruthless consumer product leader reviewing Dubplate. Evaluate whether this
> actually solves the stated producer problem. Identify unnecessary features, missing
> workflows, friction, confusing terminology and anything that weakens the core promise:
> “Hear your music like it’s already out.” Do not be polite. Prioritize issues by
> severity.*

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

## Round 2 — Design

> *You are a world-class product designer with experience at Apple, Spotify and premium
> creative applications. Review Dubplate visually and interactionally. Find anything that
> feels like generic SwiftUI, SaaS software, developer UI or unfinished product. Focus on
> hierarchy, spacing, typography, artwork presentation, navigation, animation and
> emotional quality.*

Given the eight design renderings in `design/renders/`, the design-system source and
every screen's code. It found the most embarrassing defect in the project and eight
smaller ones.

### The one that mattered

**The Mac was shipping in the user's system accent colour.** Every segmented control,
switch, progress bar, sidebar selection and focus ring rendered in system blue — on
the one surface whose whole palette exists so that nothing competes with the artwork.
A producer whose Mac is set to pink had a pink app. One missing `.tint()` at the root
of the window, and the renderings had not shown it because they were drawn from the
design system's values rather than from AppKit's.

### Implemented

- **The inspector was a settings form.** A persistent filled box under every value is
  what makes a pane read as a database record editor rather than as a page about a
  song. Its own comment claimed it was not one. Now a hairline that lights on focus.
- **The phone advertised permanently that it is a simulator.** A Stream / Gallery /
  Motion pill sat under the artwork in all three modes, and Motion's auto-hide hid
  the transport but left the pill. The mode is a swipe now, with three dots shown for
  a moment after it changes. The explicit picker belongs on the Mac, where the point
  is to compare.
- **The placeholder cover was a grey slab with a 15pt caption.** Every record has one
  on day one, and day one is the day a producer decides whether this app is for them.
  It is a cover now: hue derived from the title's hash, the title itself as the mark
  at 15% of the edge, the credit beneath, and no type at all below 64pt.
- **Gallery was Stream with sixteen more points of cover** — a spacing variant sold as
  an environment. It is the sleeve now: running order beside the artwork with the
  playing track marked, and the credits a release actually carries.
- **12pt metadata sat at 3.3:1**, under AA, and three places nested further opacity on
  top of it. The tertiary token was raised and the nested opacities removed.
- **The grid packed 170pt covers at every window size**, because `adaptive` fills at
  its minimum; and the card's third line of inventory data turned a shelf into a
  listing. Wider bounds, one line less.
- **The Mac preview was a 900pt sheet** that does not fit the laptop most producers
  own. It is its own window.
- **One vocabulary.** A mix is a mix — in every menu, sheet, label and button.

### The beat it found missing

A folder became a record silently, with the folder's name, and giving that record its
first cover was answered with an alert about a filename. Naming is now the first thing
the cursor is in, and a first cover simply appears — replacing one still asks, because
that deletes a file.

### Rejected

**"Give the phone a blurred-artwork background behind Now Playing."** This is the
single most recognisable piece of a competitor's player, and the brief forbids
reproducing one. The player takes its colour from the artwork's own palette instead.

**"Use a serif display face for release titles."** A record's typography belongs to
the record, not to the app showing it. Dubplate stays neutral so the artwork does not
have to argue with it.

---

## Round 3 — Producer workflow

> *You are a professional record producer who works daily in Pro Tools, Logic and Ableton.
> You receive new bounces constantly and test albums repeatedly away from the studio.
> Review Dubplate purely as a working producer. Find every unnecessary click and every
> missing workflow. Focus heavily on bounce → Dubplate → iPhone → listening → replace mix
> → listen again.*

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

> *You are a principal Apple platforms engineer. Review this codebase for architecture
> problems, concurrency issues, sync bugs, memory problems, media playback edge cases,
> CloudKit mistakes, persistence risks and maintainability issues. Assume this app may
> eventually have tens of thousands of users.*

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

---

## Round 5 — Failure testing

> *You are a hostile QA engineer trying to break Dubplate. Test large WAV files, missing
> files, failed iCloud sync, airplane mode, interrupted downloads, app termination,
> audio-route changes, corrupt artwork, malformed metadata, rapid skipping, repeated
> imports, duplicate tracks and concurrent Mac/iPhone edits. Find failures rather than
> confirming success.*

The hardest round, and the one that paid for itself several times over. It returned
twenty-six findings and, unprompted, a numbered fix order: *§0 (it does not compile) →
F1 (loses masters) → F2/F3 (silently discards and corrupts mixes) → F5 (launch hang on
any cloud-only phone) → F6/F7/F8 (playback lies and crashes) → the rest.* That order
was followed exactly.

### §0 — it does not compile

Two compile errors, both introduced by earlier rounds' own fixes and both invisible to
a project with no compiler: `markDirty()` was called at four sites in `MediaIndex` and
defined at none, and `SyncCoordinator` assigned to an `isTransferring` property that a
previous change had deleted. Both were the same mistake — a scripted patch whose
anchor text had already been altered by an earlier patch in the same script, so the
replacement silently did nothing.

Fixing them was not enough. `swiftcheck` gained a self-member resolution rule, which
resolves every `foo(…)` and `self.bar` against the members visible on the enclosing
type, and it was verified the only way that means anything: by reintroducing each of
the two errors and confirming the checker names the exact line. It has since caught
two more of the same class.

### F1 — the path that loses masters

A media descriptor being written to CloudKit was recorded as *uploaded*, which is the
flag that authorises deleting the local bytes. The description record carries the
metadata; a separate asset record carries the audio. Uploading the first and unlinking
the file belonging to the second destroys the only copy of a master.

`isDescribed` and `isUploaded` are now separate facts and only a confirmed asset
upload sets the second. Beyond that, `removeLocalCopies` no longer trusts the index at
all: before anything is unlinked it asks CloudKit whether the file record is really
there, and an index that turns out to be wrong is repaired and reported rather than
acted on.

### F2 / F3 — the import that discards and corrupts mixes

Import treated a 64 KiB head-plus-tail-plus-size signature as proof that two files
were the same audio. Two bounces from one session share a WAV header and very often a
tail of silence, so the signature collides on exactly the files a producer most needs
told apart — and a colliding file was either discarded as a duplicate or used to
"repair" a different asset's path.

The signature is now what it should always have been: a cheap candidate filter.
Identity is decided by reading both files through, and repair additionally requires
the file size and the original filename to match.

### F5 — launch hang on any phone whose library is still in iCloud

`MediaAnalyser` walked the whole library on the main actor and, when an asset's audio
was not on the device, recursed straight into the next one without yielding. On a
phone that had just signed in — every track cloud-only — that is an unbounded
synchronous walk before the first frame. It now tracks what it skipped, yields on
every asset including the skipped ones, and reconsiders the skipped ones when a
download lands.

### F6 – F8, F12, F13 — playback

- **F6.** Reaching a track whose audio had not arrived set `isPlaying = false` and
  left the engine alone, so the previous track kept playing through the headphones
  while the interface showed the new one, paused — and pressing play resumed the old
  track. The engine is stopped before the wait begins.
- **F7.** `PlaybackEngine.start` tore down the player and the schedule *before* trying
  to bring the graph up. A failure left `currentItemID` pointing at a track with
  nothing scheduled and `isPlaying` still true; since seek is built on start, a failed
  scrub left the transport counting through silence. State is cleared first and set
  only once the graph is up.
- **F8.** An unplayable track called `skipUnplayable`, which called
  `startCurrentItem`, which called `skipUnplayable`. With repeat on and a record whose
  files were all unreadable, those two called each other around the queue for ever.
  The controller remembers what it has passed over since the person last asked for
  something, so every track gets one chance and then the record stops with an error.
- **F12.** A file whose header promises more audio than it contains renders what it
  has and stops; `.dataPlayedBack` never fires, because those frames were never played
  back. The transport counted towards a length that did not exist for as long as the
  app stayed open. Three seconds of a still playhead while the transport claims to be
  playing is now the end of that track, and the schedule is rebuilt rather than
  trusted — whatever was queued behind it was stuck on the same node.
- **F13.** The engine restarted itself after rebuilding its graph. A rebuild is also
  what headphones coming out looks like from inside `AVAudioEngine`, and the
  notification that distinguishes the two arrives separately with no ordering
  guarantee — so an unreleased record could come out of a phone's own speaker in a
  room full of people. The engine now always rebuilds silent; the controller decides,
  and never resumes into the built-in speaker music that was on headphones.

### F9, F10, F11, F24 — silence where there should be a sentence

A download for an asset with no descriptor returned without a word, leaving the row
saying "Downloading" for the rest of the session. The Mac waited for a download in
complete silence, looking as though the play button had not registered. Two drops at
once shared one progress slot, so the first to finish hid the second while it was
still copying gigabytes. A drop of more than five hundred files was cut off without
saying so, which is indistinguishable from losing the rest. All four now say what
happened.

### F14, F21, F23, F25 — the library telling people things that are not true

- `TrackVersion.isCurrent` compared identifiers while `Track.currentVersion` healed
  itself, so a version deleted on another device left the newest mix listed under
  *Current* and under *Previous* at once, and nothing in the queue marked as playing.
- "Nobody has looked yet" was answered as "on this device". The commonest way to reach
  that state is a catalogue that has arrived from iCloud and audio that has not, so a
  phone showed play buttons for ten albums it did not have. It answers "not here" now,
  and the look at the file system happens before the first frame rather than after it.
- Match keys threw away every character that was not alphanumeric, so a record named
  with a symbol had no key at all and two bounces of it came in as two separate
  tracks. Pictographs are kept; arithmetic and currency signs still are not.
- Playing a named track that has no audio started the record from the top, which reads
  as a double-click being ignored.

### F15 – F20, F22, F4 — performance and the drop that yanked the record

Planning a drop walked the file system and matched every bounce against every existing
track — quadratic, on the main actor, inside a drop handler. Setting a cover read its
dimensions and built its thumbnail on the main actor, so a 12000px export froze the
window for seconds. A corrupt cover was re-decoded on every pass of the grid, for
ever. The Lock Screen artwork cache held every release ever played, at full size. The
scrub bar expanded four hundred stored peaks inside its `body`, so it did that work
again on every playhead tick and every touch event during a scrub. Every transfer
starting or finishing spawned its own unordered task to report progress, so a backfill
produced a thousand of them and the last snapshot to arrive could be a stale one.

Two more: dropping a mix on track 8 while track 3 was playing jumped the record to
track 8 — through the confirmation sheet it still does, because the sheet says it
will, but a bare drag no longer does. And an import copies bytes into place before it
writes the row, so a force quit in between left a file nothing owned; there is a sweep
at launch now, deliberately conservative — filenames carry the identifier of the asset
that owns them, a name that is not an identifier is left alone, and a fetch that fails
skips the sweep rather than reading "no assets" as "delete everything".

### Rejected

**"Add a retry with exponential backoff around every CloudKit call."** `CKSyncEngine`
and CloudKit's own operations already do this, with the server's rate-limit hints,
which a hand-rolled loop cannot see. A second layer of retries on top would multiply
the request rate at exactly the moment the server is asking for less.

**"Checksum every file on launch to detect corruption."** A library is tens of
gigabytes; hashing all of it at every launch is minutes of disk and battery to detect
something that has never been observed. The checks were put where corruption actually
has consequences — at import, and before deleting a local copy.
