# Sync

## What a person should experience

> I changed my album on the Mac. It appeared on my phone.

Not "I synchronised some files". Sync has no screen of its own, no progress list
anyone has to watch, and no icon on every row.

## The shape

Three things travel, and they travel differently.

| What | How | Where |
| --- | --- | --- |
| Metadata — releases, tracks, versions, sequence, which mix is current | SwiftData + CloudKit mirroring | Automatic, everywhere |
| The *catalogue* of media — what files exist, their size, name and checksum | `CKSyncEngine`, record type `DubplateMedia` | Automatic, everywhere |
| The **bytes** — the actual WAVs and covers | `MediaTransferService`, record type `DubplateMediaFile` | On request |

All three live in the same private CloudKit database, in the user's own account.
There is no Dubplate server.

### Why the bytes are separate

`CKSyncEngine` fetches every change in a zone as soon as it appears. For a few
hundred bytes of description that is exactly right. For a forty-minute 96/24 master
it is exactly wrong: a phone would fill up with an entire back catalogue nobody asked
it to hold, over cellular, without being asked.

So the engine syncs descriptions and the transfer service moves bytes when something
asks it to. This is also what makes the availability vocabulary honest: a track whose
description has arrived but whose audio has not is precisely what the interface calls
**"Available on your Mac"**.

The Mac uploads what it imports, immediately. The phone downloads what it is told
to — by **Download Release**, or by playing something.

### Why CloudKit rather than iCloud Drive

The metadata already goes through CloudKit via SwiftData. Putting the media in an
iCloud Drive ubiquity container would mean two transports, two failure modes, two
notions of "available", and a folder of the producer's unreleased music sitting
visible in the Files app. One account, one database, one set of rules.

The cost is that CloudKit's per-record asset handling has to be driven explicitly.
That is `MediaTransferService`, and it is about two hundred lines.

## Status

Six states. Five of them are worth mentioning; the sixth is what people see almost
always.

| State | Shown as | When |
| --- | --- | --- |
| `synced` | *nothing* | Everything is where it should be |
| `syncing` | "Syncing" | Changes are going out |
| `waiting` | "Waiting" | Queued behind something |
| `availableOnOtherDevice` | "Available on your Mac" | Description arrived, bytes did not |
| `downloading` | "Downloading" | Bytes are arriving |
| `offline` | "Offline" | No account, or sync turned off |

`SyncStatus.isWorthMentioning` is `false` for `synced`, and the interface honours it:
the Mac toolbar shows nothing, and a track row with playable audio has no badge.

## Conflicts

Two devices editing one record is normal for this product: the Mac is where records
are made and the phone is where they are heard, and both can write.

### Metadata — most recent edit wins

CloudKit mirroring merges property by property, last writer wins. For a title, an
artist name, a year or a note, that is what a person means. Dubplate does not
second-guess it.

### Sequence — order from the winner, membership from the store

The reorderable list is the case where last-writer-wins is not enough. A track added
on the Mac while the phone was dragging track four to the top would vanish if the
phone's array simply won.

So: **the winning array decides order, and the relationship decides membership.**
`TrackOrderMerge.reconcile` takes the merged order, keeps every identifier in it that
still exists, appends anything present that the order never knew about in creation
order, and drops duplicates. Then `LibraryRepair` renumbers.

Tested by `Tests/SyncTests/ConflictResolutionTests.swift`.

### Versions — both bounces survive, always

Two devices adding a bounce while offline both produce a "v6". Nothing is deleted to
resolve that. `VersionNumbering.resolveCollisions` gives the number to whichever
version was created first and moves the other to the next free number — ordered by
creation date, and by identifier when the timestamps tie, so both devices reach the
same answer without talking to each other. A producer who has been saying "v6" all
week still means the same file.

### Which mix is current — last writer wins, and it self-heals

`currentVersionID` is a single value, so mirroring resolves it. If it ends up
pointing at a version deleted elsewhere, `Track.currentVersion` falls back to the
newest version that does exist, and `LibraryRepair` writes that back. A track is
never left unplayable by a merge.

### Media — never resolved by deleting

An asset record is immutable: its record name is the asset identifier, and an
asset's contents never change once written. A `serverRecordChanged` on upload
therefore means "someone already put this there", which is a success. Nothing in the
sync layer deletes a media file; only `LibraryStore` does, and only when a person
deletes the thing that owns it.

### Deletions

Deleting a release deletes its tracks and versions by cascade, removes the media
files, and queues the descriptions and file records for deletion in CloudKit.
Deleting a *download* is not a deletion: it removes local bytes only, and
`removeLocalCopies` refuses outright to remove a file that has not been uploaded yet,
so the button can never destroy the only copy of a mix.

## Failure

| What happens | What Dubplate does |
| --- | --- |
| Not signed in to iCloud | Works entirely locally. Says so once, in a sentence. |
| Signs out mid-session | Local library untouched. Nothing is removed. |
| Signs in later | Everything on the device is queued for upload. |
| Network drops mid-transfer | `CKSyncEngine` retries on its own schedule; the file index remembers what is still outstanding across a relaunch. |
| Upload interrupted by a relaunch | Re-queued at launch from the durable index. |
| iCloud storage full | The upload is deferred and logged; no local file is touched. |
| Sync state file unreadable | Discarded, and everything is re-fetched. Slow, correct, never fatal. |
| Media index unreadable | Rebuilt from the library. Worst case is re-uploading bytes CloudKit already has. |
| A file has gone missing under Dubplate | Dropped from the upload queue rather than failing that batch and every batch behind it. |

## What runs after a merge

`LibraryRepair.repair(release:in:)` runs when a release is opened and when a
download lands. It reconciles the order, renumbers tracks, resolves version-number
collisions, repairs a dangling `currentVersionID` and re-denormalises duration.

It is idempotent, it never deletes anything, and — importantly — **it does not touch
a release that is already consistent**, because a pointless write would sync straight
back out again and wake every other device. `LibraryRepairTests` asserts exactly
that.

## Network dependencies, in full

CloudKit, in the `iCloud.com.dubplate.app` container, private database only. That is
the complete list. No analytics, no crash reporting service, no advertising, no
remote configuration, no third-party SDK of any kind. Nothing is written to the
public database, nothing is shared, and no URL to a person's audio exists outside
their own account.
