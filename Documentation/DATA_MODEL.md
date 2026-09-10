# Data model

Six entities, stored with SwiftData and mirrored to the user's private CloudKit
database. Every shape here is constrained by what that mirroring supports.

## The CloudKit rules, and what they cost

CloudKit mirroring will refuse a schema that breaks any of these, so all of them are
enforced in the model and checked by `Tools/swiftcheck.py`:

| Rule | Consequence in Dubplate |
| --- | --- |
| No `@Attribute(.unique)` | Identity is a client-generated `UUID`. Duplicate protection is by content checksum, not by a database constraint. |
| Every stored property optional or defaulted | Nothing is non-optional without a default, including `id`. |
| Every relationship optional | `tracks`, `versions`, `artwork` are all optional, so every read goes through a computed accessor rather than a `!`. |
| No `.deny` delete rules | Cascade and nullify only. |
| No ordered relationships | Sequence is an explicit `[String]` of identifiers. |

## Entities

### ArtistProfile
`id · displayName · defaultArtistName · avatar? · createdAt · updatedAt`

One per library. The only thing it does is supply a default credit for new records,
so a producer types their name once.

### Release
`id · title · artistName · releaseTypeRaw · year? · genre? · copyrightText? · notes? ·
createdAt · updatedAt · lastPlayedAt? · trackOrder · watchFolderBookmark? ·
tracks? · artwork? · animatedArtwork?`

`releaseType` is a computed accessor over a stored raw string. Enums are stored as
raw values rather than as `Codable` cases so they survive mirroring intact and can be
used in a `#Predicate`.

**`trackOrder` is the authority on sequence.** `orderedTracks` reads it, then appends
anything present in the relationship that the order has never heard of, in creation
order. That single behaviour is what stops a track added on one device disappearing
because the other device reordered the record.

`watchFolderBookmark` is a security-scoped bookmark. Nothing reads it in V1; it is
there so watch folders do not require a migration.

### Track
`id · title · artistName · featuredArtists? · trackNumber · discNumber · explicitFlag ·
notes? · currentVersionID? · duration · createdAt · updatedAt · release? · versions? · canvas?`

`duration` is denormalised from the current version so a track list never opens a
file. `displayTitle` falls back to the source filename, so a record imported with no
metadata at all still reads as a record.

**`currentVersionID` is the only record of which mix is current.** `currentVersion`
resolves it and falls back to the highest-numbered version when the identifier points
at something that no longer exists — which is what happens when a version is deleted
on another device.

### TrackVersion
`id · versionNumber · label? · notes? · createdAt · importedAt · track? · audioAsset?`

`versionNumber` is monotonic per track: `nextVersionNumber` is `max + 1` and numbers
are never reused, so "play me v3" keeps meaning the same thing after a deletion.
`isCurrent` and `audioAssetID` are computed, not stored.

`label` is filled in from the filename at import — `04 Midnight mix 5.wav` becomes
`Mix 5` — and can be renamed.

### AudioAsset
`id · filename · originalFilename · relativePath · cloudRecordName? · duration ·
sampleRate · bitDepth · channelCount · codec · fileSize · createdAt · checksum ·
availabilityRaw · integratedLoudness? · waveformPeaks?`

`relativePath`, not a URL — see `ARCHITECTURE.md`. `originalFilename` is what the
file was called in Finder and is what people are shown; `filename` is the name inside
managed storage and is never displayed.

`checksum` is a *signature*: the file size plus SHA-256 over three one-megabyte
windows from the head, middle and tail. Hashing a gigabyte to notice a re-import
would be slower than the import. Two different bounces of the same song differ inside
the first window in practice; `Checksum.full` exists where certainty matters more
than speed.

`waveformPeaks` is one byte per bucket, 400 buckets, on a square-root curve so quiet
detail survives 8-bit quantisation — 400 bytes, small enough to live next to the
asset and sync with it.

### ArtworkAsset
`id · kindRaw · filename · originalFilename · relativePath · cloudRecordName? ·
width · height · fileSize · checksum · createdAt · availabilityRaw · loopStart ·
loopDuration · mutesSourceAudio · thumbnailData?`

One entity for three roles — cover, release motion, track canvas — because they are
the same thing to storage and to sync.

`thumbnailData` is a ~40 KB JPEG rendition used in lists, on the Lock Screen and in
Control Centre. It is the reason a phone that has not downloaded a release yet can
still show its cover.

## Relationships

```
ArtistProfile ──1:1?──→ ArtworkAsset (avatar)

Release ──1:many, cascade──→ Track ──1:many, cascade──→ TrackVersion ──1:1?, nullify──→ AudioAsset
   │                          └──1:1?, nullify──→ ArtworkAsset (canvas)
   ├──1:1?, nullify──→ ArtworkAsset (cover)
   └──1:1?, nullify──→ ArtworkAsset (motion)
```

Inverses are declared on the to-many side only. Deleting a release cascades to its
tracks and their versions; the asset rows are nullified, and `LibraryStore` then
removes the files behind them. Assets are nullified rather than cascaded so that a
file is never deleted by a relationship rule — deleting bytes is always an explicit
act.

## Deriving playback

`PlaybackQueueItem` is a flat value type built once, when a record starts. Playback
never holds a `Track`, never faults a relationship and never reads the store, because
the audio path must not depend on a `ModelContext` that may belong to another actor
or may have changed underneath it.

## Enumerations

```
ReleaseType       single · ep · album · mixtape · project
AvailabilityState local · cloudOnly · downloading · available · missing · error
ArtworkKind       staticArtwork · animatedArtwork · trackVideo
```

`AvailabilityState` carries its own copy: `.cloudOnly` says "Available on your Mac"
and `.available` says nothing at all, because most of the time there is nothing worth
saying.

## Migration

The schema is version one. `DubplateSchema` opens the store with an explicit `Schema`
so a `VersionedSchema` and a `SchemaMigrationPlan` can be introduced without changing
any call site. Opening falls back — synced, then local, then in-memory — so a missing
iCloud container or a broken store never stops the application launching with an
explanation.
