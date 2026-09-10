# Dubplate — the product

## The idea

A folder containing

```
Track 1 mix 5.wav
Track 2 FINAL 7.wav
Track 3 new master.wav
```

does not feel like an album. The same three files, sequenced, with a cover, a title
and a credit, played back on a phone with the artwork on the Lock Screen, do.

Dubplate exists to perform that transformation, for music that is not finished and
may never come out. Everything in it is judged against one sentence:

> **Hear your music like it's already out.**

## Who it is for

A producer with bounces. Someone who has to leave the studio to know whether a mix
works, who has ten versions of track four, and who wants to hear the record in the
car the way a listener eventually will.

## What Dubplate is not

Not a DAW. Not a distributor. Not a mastering service. Not a streaming platform, a
social network, a collaboration tool, or a place to store files. Not "Dropbox for
musicians", not Frame.io, not SoundCloud. Those are adjacent categories with their
own products; being a worse version of any of them would make Dubplate worse at the
one thing it does.

## The two applications

**The Mac makes records.** Import, artwork, metadata, sequencing, versions,
previewing, and syncing. It should feel like a professional creative application
that happens to be beautiful, not like project-management software.

**The iPhone hears them.** Browse, play, lock the phone, walk around, plug into a
car. It is deliberately less capable: the only editing it offers is switching which
mix of a track is playing, and even that lives behind an ellipsis where every other
music application puts its secondary actions.

## The ten decisions that define it

1. **Artwork before information.** Every list is a wall of covers first. When there
   is no cover, the placeholder is the release title set on a ground derived from
   the title — never a music-note icon.
2. **Nothing is required.** A record with no artwork, no year, no genre and no
   track titles still plays, still syncs and still looks like a record.
3. **Versions are a list, not a graph.** Current at the top, the rest underneath.
   Add, rename, make current, delete. No branches, no merges, no history view.
4. **Dubplate proposes, never applies.** The filename heuristics can be confident
   enough to suggest "New version of Midnight?" — they are never confident enough
   to do it silently.
5. **Adding is always the default.** Dropping a bounce on a track adds a version
   and starts playing it. Replacing, which destroys a file, is offered but never
   pre-selected.
6. **The original file is theirs.** Dubplate copies, never moves. The file in the
   bounce folder can be renamed, moved or deleted without breaking a record.
7. **Audio is never touched.** No re-encoding, no resampling, no normalisation, no
   loudness matching. The loudness number in the inspector is informational and
   opt-in.
8. **Sync is invisible until it isn't.** No cloud icons on every row. Status appears
   only when it changes what a person can do right now.
9. **Removing a download can never lose a mix.** The button says where the other
   copy is, and the code refuses to delete anything that is not in iCloud yet.
10. **Errors are sentences.** "This track hasn't finished syncing to this device
    yet", never `CKError 15`.

## The MVP journey

This is the whole product. Everything else is in service of it.

```
Pro Tools / Logic / Ableton → bounce WAVs → drag into Dubplate on the Mac
→ artwork + title → sequence → sync → open Dubplate on iPhone
→ headphones / car / AirPlay → listen like it's released
→ back to the studio → bounce a new track 4 → drop it on track 4
→ the new version becomes current → sync → listen again
```

`Documentation/QA.md` walks it step by step, with what to look for at each one.

## Deliberately not built

Watch folders, A/B comparison as a dedicated mode, reference tracks, timestamped
listening notes, Apple Watch, CarPlay, shareable release packages, release-readiness
checks, spatial audio, a menu-bar quick drop, and any kind of DAW plugin.

The architecture leaves room for all of them — the audio layer is already separate
from the interface for CarPlay's sake, the model already carries a watch-folder
bookmark, and switching versions already preserves playback position, which is most
of A/B. None of them ship in V1, because none of them are the sentence at the top of
this file.
