# Rosetta: how to make it work way better

Review date: 2026-10-31. Three independent read-throughs of the full codebase
(Model/, Capture/ + Data/, App/ + Board/) against `rosetta_spec.md`, merged
and deduplicated. Every item below was verified by reading the code; the
calibration claim was also checked by simulating the exact fit algorithm.
Nothing was built or run on device (no Xcode in the review environment), so
anything marked "verify on device" is a strong inference, not a measurement.

Severity reflects product impact for the family, not code aesthetics.

---

## TL;DR: the ten things to do first

| # | Finding | Why it matters | Effort |
|---|---------|----------------|--------|
| 1 | Data Protection class Complete on DB and clips | Every utterance captured while the counter phone is locked is silently dropped | Small |
| 2 | No audio interruption / route-change handling | One phone call kills capture for hours; indicator stays green | Small |
| 3 | Board TTS is recorded as the child's speech | Training set gets poisoned with the synthesizer's voice | Small |
| 4 | Confirm card rebuilds on every new segment | Dismissed guesses come back; unticked chips re-tick. Breaks principle 4 | Small |
| 5 | Maturity gate: leave-one-out leaks across same-session chips | A word looks "mature" after a single exchange | Small |
| 6 | Calibrator cannot discriminate in the real cosine band | "Rejection tightens the threshold" is not actually true on device | Medium |
| 7 | Energy VAD latches on sustained noise; no max utterance | TV on = back-to-back 90 s "segments" all day, flooded Review | Small |
| 8 | Confirm clobbers freshly computed embeddings with nil | New exemplars don't count until the next relaunch, which may be weeks | Small |
| 9 | Global top-k before per-intent filtering | "Top-3" is usually top-1; one dismissal empties the card | Small |
| 10 | Hour-of-day prior uses confirm time, not capture time | Evening Review labelling makes every word look like a 8 pm word | Small |

Items 1 to 4 and 7 to 8 are each an afternoon's work and together are the
difference between "a week of daily use accumulates 50+ exemplars" (Phase 1
acceptance) and the family quietly giving up.

---

## A. Capture reliability (the data has to arrive first)

### A1. CRITICAL: Data Protection class Complete makes capture fail while locked
`Data/FileLocations.swift:24-33`, `Capture/SegmentWriter.swift:23, 42-45`,
`Data/Database.swift:10`, `Capture/CaptureController.swift:89, 131`

Root, clips and photos directories are created with `.complete`. New files
inherit the directory class, so the SQLite file, its journal, and every m4a
are Complete-class and cannot be created, read or written while the device is
locked. A counter-top iPhone locks within minutes; nothing sets
`isIdleTimerDisabled`. While locked: `AVAudioFile(forWriting:)` throws, the
segment is never inserted, session insert/close are `try?` and vanish. The
engine keeps running and the indicator stays green.

This is a deliberate deviation from spec section 6 and worth telling the
family about: always-on capture and class Complete are incompatible.

Fix:
```swift
// FileLocations.prepare
try fm.createDirectory(at: root,   ..., attributes: [.protectionKey: .completeUntilFirstUserAuthentication])
try fm.createDirectory(at: clips,  ..., attributes: [.protectionKey: .completeUnlessOpen])
try fm.createDirectory(at: photos, ..., attributes: [.protectionKey: .completeUntilFirstUserAuthentication])
```
Drop the per-file `setAttributes` in SegmentWriter. Set
`UIApplication.shared.isIdleTimerDisabled = isListening` in
`CaptureController`. Replace `try?` on session insert/close with a real
failure path that stops listening and shows a persistent error.

### A2. CRITICAL: No interruption, route-change, or engine-reconfiguration handling
`Capture/AudioCaptureEngine.swift:28-64`, `Capture/CaptureController.swift:10, 50-72`,
`App/Components/RecordingIndicator.swift`

Grep confirms no observer for `AVAudioSession.interruptionNotification`,
`routeChangeNotification`, `AVAudioEngineConfigurationChange`, or
`mediaServicesWereResetNotification`. A phone call, Siri, alarm, FaceTime on
the same Apple ID, headphones, or a Bluetooth speaker pairing stops the engine
and it never restarts. `isListening` is a flag set once, so the green
indicator lies.

Second-order effect: `SessionBuffer`'s clock is the sample counter, so no
frames means no time. An open session never closes (`activeSessionId` stuck,
Listen shows "In an exchange" forever). If frames resume, `streamStartDate +
streamTime` is wrong by the gap, shifting every later `startedAt`, which is
also the 24 h review-expiry clock and the hour-of-day prior input.

Fix: subscribe to the four notifications in `AudioCaptureEngine`. On
interruption-began / config change: remove tap, stop engine, call `onStalled`.
On ended-with-`.shouldResume` / route change: rebuild the converter from the
new `inputNode.outputFormat(forBus: 0)` (sample rate can change) and restart.
In `CaptureController`, `onStalled` triggers `buffer.interrupt()` and a fresh
`SessionBuffer` with `streamStartDate = Date()` on resume. Derive the
indicator from `engine.isRunning`, not a cached flag. Consider stamping each
delivered chunk with `Date()` in the tap so wall time never depends on an
unbroken sample stream.

### A3. HIGH: The Board's own speech is captured as the child's
`Capture/AudioCaptureEngine.swift:35-37`, `Board/SpeechOutput.swift:19-27`,
`Board/BoardView.swift:38-44`, `App/ConfirmCardView.swift:141-158`,
`Capture/VoiceActivityDetector.swift:40-50`

The session is `.playAndRecord` + `.defaultToSpeaker` with `mode: .default`
(no echo cancellation). `AVSpeechSynthesizer` plays through that same session.
Nothing gates the VAD while the app speaks. A loud, close "banana" from the
speaker trivially clears the energy VAD, so every Board tap during listening
produces a segment. In the Ask flow it is worse: the tap confirms and clears
segments, then about 0.6 s later the TTS segment arrives as a fresh Confirm
chip with the exact word the parent just saw, the single most likely thing to
be labelled without listening. Phase 2 then learns the synthesizer's voice.

Fix: make `SpeechOutput` an `AVSpeechSynthesizerDelegate` exposing a
`selfSpeakingUntil` date (end + ~300 ms tail). In the capture handler, feed
zeros into `SessionBuffer` while speaking so the session clock still advances.
Belt and braces: `engine.inputNode.setVoiceProcessingEnabled(true)` before
installing the tap (adds AEC; check the format change), and mark any segment
overlapping a `boardTap` event as `.discarded` in `segmentCaptured`.

### A4. HIGH: Energy VAD latches on sustained noise; no maximum utterance length
`Capture/VoiceActivityDetector.swift:42-45`, `Capture/SessionBuffer.swift:136-141, 194-197`

The noise floor only updates when `!speech`. If ambient level rises above the
threshold and stays there (TV, dishwasher, siblings), every frame is "speech"
forever and the floor can never adapt. The floor also resets on every
`startListening`. There is no `maxUtterance`, so a latched utterance ends only
at the 90 s session cap, then a new session opens on the next frame:
back-to-back 90 s segments all day (~5.7 MB Float32 each in memory), a flooded
Review queue, zero useful exemplars.

Spec sections 5.1 and 10 call for Silero VAD with a SoundAnalysis fallback;
neither exists. `docs/silero-vad-conversion.md` is a plan only (the plan is
sound).

Fix now:
```swift
if speech {
    noiseFloor = 0.995 * noiseFloor + 0.005 * rms   // absorbs sustained noise in ~6 s
} else {
    noiseFloor = 0.95 * noiseFloor + 0.05 * rms
}
```
Add `Tuning.maxUtterance = 8` and cut when `utteranceSamples.count >=
maxUtterance * sampleRate`. Add a live RMS/threshold readout on Listen so the
family can see whether he registers at all (verify on device: `minimumRMS =
0.01` with no AGC may miss a soft-spoken child 2-3 m away). Then implement
Silero behind the existing protocol; it is the real fix for TV and siblings.

### A5. MEDIUM: Unsynchronized access between main thread and capture queue
`Capture/CaptureController.swift:68-72, 88`, `Capture/AudioCaptureEngine.swift:57-67`

`pauseListening` calls `buffer.interrupt()` on main while the capture queue
may be inside `buffer.ingest` (`SessionBuffer` has no locking; concurrent
array mutation is memory-unsafe). `engine.stop()` nils `converter` and
`onSamples` from the caller's thread while `convertAndDeliver` reads them on
the queue. `stationName` (`@Observable`) is read on the capture queue.

Fix: the engine's serial queue is the only mutator. `stop()` removes the tap,
stops the engine, then `queue.sync { converter = nil; onSamples = nil }`.
Expose `perform(_:)` and route `buffer.interrupt()` through it. Snapshot
`stationName` into a `let` at `startListening`.

### A6. MEDIUM: Segment persistence is not crash or disk-full safe
`Capture/SegmentWriter.swift:23-40`, `Capture/CaptureController.swift:99-107`

AAC is written directly at its final URL; the moov atom lands on close, so a
kill mid-write leaves an unplayable file. A kill between write and
`insertSegment` leaves an orphan. No free-space check, no fsync.

Fix: write to `<id>.m4a.tmp`, close, then atomic `moveItem`. Sweep `*.tmp` and
row-less files at launch. Check `volumeAvailableCapacityForImportantUsage`
before and during listening; below ~200 MB pause with a persistent message.

### A7. MEDIUM: Segment cutting clips word endings; noise blips extend sessions
`Capture/SessionBuffer.swift:130, 175-176`

The full hangover (480 ms) is trimmed from the tail, so low-energy word-final
consonants (/s/, /t/, /f/) that the energy VAD already classes as silence are
cut. There is pre-roll but no post-roll. `lastSpeechSample` updates on every
speech frame including sub-onset blips, so clatter keeps resetting the 10 s
silence timer and unrelated moments share a session.

Fix: `Tuning.postRoll = 0.15` and `removeLast(max(0, trailingSilence -
postRollSamples))`. Only update `lastSpeechSample` once onset is crossed.
Consider hangover 0.7-0.8 s once Silero reduces false positives.

### A8. LOW-MEDIUM: Microphone permission is never requested explicitly
No `AVAudioApplication.requestRecordPermission` anywhere. The first
`startListening` races the system prompt and surfaces "CaptureError error 0".
Request in `FirstRunView` and map `CaptureError` cases to plain language.

---

## B. Data integrity, deletion, backup

### B1. HIGH: Confirming overwrites the segment row with a stale snapshot, erasing embeddings
`Data/Stores.swift:94-121`, `Capture/CaptureController.swift:108-121`,
`App/ConfirmCardView.swift:194-213`, `Model/SuggestionEngine.swift:62-72, 85-94`

The embedding is computed asynchronously after insert and patched into
`recentSegments`. The Confirm card's model is a snapshot taken when ids last
changed, so its copy has `embedding == nil`. On confirm, `updated.update(db)`
writes every column, including nil over the embedding the capture path
persisted. The exemplar is inserted with nil too. `reload()` does not
re-embed; only `EmbeddingBackfill` at launch does. On a rarely-relaunched
counter phone those exemplars do not count toward kNN or maturity for days.
Progress says "learning, 4 of 5" while Dictionary says 5.

Fix:
```swift
let fresh = try SegmentRecord.fetchOne(db, key: segment.id) ?? segment
let exemplar = ExemplarRecord(..., embedding: fresh.embedding, ...)
try exemplar.insert(db)
try db.execute(sql: "UPDATE segments SET state = ?, labelledAt = ? WHERE id = ?",
               arguments: [SegmentState.labelled.rawValue, now, segment.id])
```
Also have `SuggestionEngine.reload()` embed any exemplar still missing a vector.

### B2. HIGH: No restore/import path; the "include audio in backups" toggle reverts every launch
`Data/Export.swift`, `Data/FileLocations.swift:24, 33`, `Data/Database.swift:10`,
`App/ListenView.swift:179-183`

There is no importer anywhere. One old phone holds the entire dataset; if it
dies the family has a zip no build can read. Separately, `Database.open` calls
`FileLocations.prepare()` with the default `includeAudioInBackup: false`, which
re-excludes clips from backup on every launch regardless of the Settings
toggle. Audio is never in an iCloud backup even when opted in, and a restore
yields rows pointing at missing files.

Fix: `prepare(includeAudioInBackup: UserDefaults.standard.bool(forKey:
"includeAudioInBackup"))`. Add `RosettaImporter.import(zipURL:)` via
`.fileImporter`, decode `rosetta.json`, merge with `INSERT OR IGNORE` by id in
one transaction, copy missing clips/photos. Add an export → wipe → import
round-trip test.

### B3. MEDIUM-HIGH: "Delete this word and its clips" never deletes a clip; copy overclaims
`Data/Stores.swift:51-77, 145-147`, `App/DictionaryView.swift:135-141, 164-174`,
`App/FirstRunView.swift:31-35`, `App/ReviewView.swift:83`, `Data/Export.swift:88-105`

`isClipReferenced` counts the `segments` row, which always exists for an
exemplar's clip, so every file is "referenced" and nothing is removed.
Exemplar prune deletes the row only. Review "Discard" only flips state. The
only path that removes audio is wipe-all, and wipe-all does not `VACUUM`, so
deleted labels and embeddings remain in SQLite free pages. The family is told
otherwise in three places. Spec section 8 promises full local deletion.

Fix: `deleteForever` marks the segment rows discarded, then removes files
unconditionally. `ExemplarStore.delete` takes `deleteClip:`. Review Discard
deletes the file and keeps the row as a tombstone. `PRAGMA secure_delete = ON`
in `prepareDatabase`; `VACUUM` after wipe. Align FirstRun copy.

### B4. MEDIUM: Wipe-all leaves the app in a dead state
`Data/Export.swift:88-105`, `App/ListenView.swift:221-228`

`hasCompletedSetupInterview` stays true (no way back into setup; empty Board
and Dictionary). `recentSegments`/`activeSessionId` still point at deleted
rows, so the next `insertSegment` fails the FK. The in-memory suggestion index
still holds deleted exemplars.

Fix in the wipe handler: pause listening, `clearRecentSegments()`,
`await suggestions.reload()`, `hasCompletedSetupInterview = false`.

### B5. MEDIUM: Unbounded storage growth; export triples disk use on the main thread
`Data/Export.swift:50-57`, `App/ListenView.swift:190`

Discarded, "not him" and expired clips are kept forever with no storage meter.
Export copies clips and photos to tmp, zips (second copy), then copies the zip
(third), synchronously on the main thread from a Button.

Fix: launch-time retention sweep (delete clip files for discarded/notHim older
than 7 days, keep the row with a tombstone `clipRef`). "N clips, X MB" in
Settings. Export on `Task.detached`, stage with `linkItem` (hard links), show
progress.

### B6. LOW-MEDIUM: Smaller data items
- Expiry sweep runs only when Review loads (`Stores.swift:495`); the Confirm
  card and live guesses operate on pending segments older than 24 h. Run it at
  launch and on `sessionOpened`.
- `confirmLatencies` and the Progress chart bucket by UTC date; evening
  confirmations in North America land on tomorrow. Bucket with
  `Calendar.current`.
- Sessions left open by a force-quit never get `endedAt`. Sweep at launch.
- Missing indexes on `segments.sessionId`, `negatives.rejectedIntentId`,
  `clipRef`. Cheap v3 migration.
- Review expiry logic itself is correct and DST-safe.

---

## C. Ranking quality (Phase 2 actually learning)

### C1. CRITICAL: The calibrator cannot learn in the score band real embeddings produce
`Model/Calibration.swift:25-55`, `Model/IntentRanker.swift:61, 78`,
`Model/SuggestionEngine.swift:162-164`

Calibrator input is raw cosine (times prior). Mean-pooled Whisper encoder
states are strongly anisotropic: cosines between any two speech clips cluster
roughly in 0.80-0.95, so the useful signal is a ~0.05-0.10 wide band. The fit
regularizes slope toward 4 and the data gradient on slope is proportional to
score spread, so with a narrow band the regularizer wins. Simulating the exact
algorithm with perfectly separable history (4 accepts at ~0.92, 4 rejects at
~0.86, 600 or 5000 iterations) gives slope 3.65, p(0.86)=0.49, p(0.92)=0.55:
no discrimination, every guess shows 2 dots.
`CalibrationTests.testRejectionTightensTheThreshold` passes only because its
accepts sit at 0.8 and rejects at 0.3, a spread the encoder never produces.
The Phase 2 acceptance criterion "a wrong-and-rejected guess measurably
tightens that word's threshold" is not met.

Fix: calibrate a standardized feature. In `IntentRanker.rank` compute mean and
std of weighted similarity over the index once per call and return
`z = (bestSim - meanSim) / max(stdSim, 1e-3)`. In `Calibration.fit`
regularize slope toward 0 with a small lambda, not toward 4. Add a test with
accepts at 0.92 ± 0.01 and rejects at 0.86 ± 0.01 asserting p(0.86) < 0.3.
Log the real similarity distribution from a handful of on-device clips before
tuning any threshold.

### C2. CRITICAL: Leave-one-out maturity leaks across same-session duplicates
`Model/MaturityGate.swift:42-49`, `Data/Stores.swift:94-121`, `App/ConfirmViewModel.swift:35`

Confirm writes one exemplar per selected chip, all chips are pre-selected, and
the chips of one exchange are the same utterance repeated seconds apart in the
same acoustics. LOO leaves one out but its siblings remain, so the held-out
query trivially finds its own intent. One exchange with 5 chips passes
`minExemplars = 5` and scores LOO ≈ 1.0: the gate opens after a single
confirmation, exactly what section 5.6 exists to prevent. The kNN agreement
bonus also rewards these duplicates.

Fix: carry `sessionId` on `ExemplarVector` (already in `contextJSON`, or add a
column), require ≥ 3 distinct sessions, and do leave-one-session-out:
```swift
let sessions = Dictionary(grouping: own, by: \.sessionId)
guard own.count >= minExemplars, sessions.count >= minSessions else { ... }
for (sid, held) in sessions {
    let rest = index.filter { $0.sessionId != sid }
    for q in held { hit += top3(q, rest).contains(intentId) ? 1 : 0 }
}
```
Add a `MaturityGateTests` case with 5 near-identical vectors sharing one
session, asserting not suggestible.

### C3. HIGH: "His rejection is final" breaks inside one exchange
`App/ConfirmCardView.swift:35, 194-213`, `App/ConfirmViewModel.swift:25, 35`,
`App/ListenView.swift:84, 120-123`, `Model/SuggestionEngine.swift:132-136`

`dismissedIntentIds` lives only in `ConfirmViewModel`, and `reload()` builds a
new model whenever the segment id list changes, i.e. every time he says
another thing mid-exchange. The spec's exchange is "many no's then a yes": the
parent dismisses "Maybe: banana?", he repeats himself, a new segment lands,
and banana is back on screen. Unticked chips ("that was his sister") re-tick
too. Listen's live guesses never pass `excluding:` at all. The negatives table
has `exchangeId` for exactly this purpose but nothing in Model/ reads it.

Fix, two layers:
1. `ConfirmViewModel.absorb(newSegments:)` mutates in place when
   `exchangeId` matches; only build a new model when the exchange changes.
2. Make the engine own exclusion: in `suggestions(for:)` union the caller's
   set with `SELECT rejectedIntentId FROM negatives WHERE exchangeId = ?`,
   cached per exchange. Then Confirm and Listen both honour principle 4
   regardless of view lifecycle.
Add a test: dismiss → append segment → rebuild → intent still absent.

### C4. HIGH: Global top-k collapses the candidate set; one dismissal empties the card
`Model/IntentRanker.swift:64-66`, `Model/SuggestionEngine.swift:158-159`

The 4 nearest exemplars across the whole index vote. A well-trained word with
20 exemplars fills all 4 slots, so "top-3" is top-1. Dismissed and
non-suggestible filtering happens after the k cut, so dismissing that one
intent yields an empty result even though the next-best intent is fine.
Section 4.5 expects the next guesses to surface after a no.

Fix: exclude dismissed intents' exemplars before kNN, and score per intent
(best of its own k nearest plus agreement bonus) so every mature intent gets a
score. `RankingTests.testOnlyKNeighboursVote` encodes the current behaviour
and needs rewriting (assert banana ranks below water, not that it is absent).

### C5. HIGH: Hour-of-day prior uses confirmation time, not capture time
`Model/SuggestionEngine.swift:104-111` vs `Data/Stores.swift:97-101, 111`

`ExemplarStore.confirm` stores the correct `hourOfDay` from
`segment.startedAt` in `contextJSON` but stamps `timestamp: now`.
`buildState` ignores `contextJSON` and buckets on `exemplar.timestamp`.
Section 4.4's evening batch labelling makes every reviewed clip look like a
20:00 word, and the 30-minute "just confirmed" recency boost fires for
whatever was last labelled in the batch. The spec's headline example (banana
at 7 am vs 9 pm) is built on this prior.

Fix: decode `contextJSON.hourOfDay` (or add a `capturedAt` column in a v3
migration) and use it for both the bucket and `lastConfirmed`. Test with a
segment captured at 07:00 and confirmed at 20:00.

### C6. HIGH: Context prior magnitude swamps the acoustic score
`Model/ContextPriors.swift:67-80`

With 30 intents, 10 confirmations in a bucket all "banana", smoothing 2,
temper 0.5: banana's lift is ×5.0 per condition, ×25 with station; every other
word ×0.41 / ×0.17. Combined with C1 (acoustic scores within 0.85-0.95), a
cosine-0.86 banana beats a cosine-0.95 water by two orders of magnitude. The
prior is the whole ranker in routine contexts, and calibrator inputs drift as
counts grow. Spec says "cheap accuracy", not "the decider".

Fix: clamp per-condition lift (e.g. `min(max(lift, 0.5), 2.0)`) or lower
temper to ~0.25. Calibrate the acoustic feature and apply the clamped prior to
the probability for ranking only, so stored observations stay comparable.
Test that the combined multiplier stays bounded.

### C7. HIGH (latency): Each segment is encoded up to three times; every chip toggle re-encodes
`Capture/CaptureController.swift:111-121`, `App/ListenView.swift:84, 118-125`,
`App/ConfirmCardView.swift:162-170, 203-213`, `Model/SuggestionEngine.swift:175-184`

Capture embeds in a background Task. Before that lands, Listen calls
`suggestions(for:)`, finds `embedding == nil`, and runs the encoder again. The
Confirm model's snapshot never receives the capture-time blob (ids unchanged,
no rebuild), so every `refreshGuesses` (each toggle, each dismiss) reloads the
m4a and re-runs the encoder, serially, on the non-Sendable `WhisperKit`
instance concurrently with capture. `ClipAudioLoader.loadSamples` runs
synchronously on the main actor there. On an old phone without ANE this is
seconds per refresh; the 1 s budget (section 5.7) is gone.

Fix: an engine-level cache of in-flight/completed embeddings keyed by segment
id (`[String: Task<Data?, Never>]`), consulted by capture, `suggestions(for:)`
and backfill. Make `WhisperKitEmbedder` an `actor` so encoder calls serialize.

### C8. MEDIUM: Mean-pooling the exchange's segments into one query reintroduces prototype averaging
`Model/Embeddings.swift:58-67`, `Model/SuggestionEngine.swift:138-146`

Section 5.2 rejects class prototypes because apraxic speech is multimodal. The
same child will say the word two distinct ways within one exchange; the mean
sits near neither. One un-deselected sibling chip drags the whole query.

Fix: rank each segment separately and aggregate per intent (mean of
per-segment best scores, or vote count).

### C9. MEDIUM: Most of the learning signal is dropped
`App/ConfirmCardView.swift:88-105, 172-184`, `Model/SuggestionEngine.swift:199-209`

If three guesses are shown and the parent confirms from the grid or board, no
calibration observation is written: neither the implicit rejection of the
three wrong guesses nor the accept if the confirmed word was among them.
Section 4.5 calls precisely this case "extra-valuable training signal". The
history is biased toward accepts, and `fit` demands ≥ 1 reject before it does
anything.

Fix: on confirm, iterate `topGuesses` and `recordOutcome(accepted: guess.id ==
confirmed.id)` for each. Do it in `ConfirmViewModel` so `ConfirmFlowTests`
covers it.

### C10. MEDIUM (perf): Maturity evaluation is O(N²·d) on every confirm, review, and prune
`Model/MaturityGate.swift:42-49`, `Model/SuggestionEngine.swift:62-72, 117-122`

Per reload: for every exemplar, an N-element filter, a full cosine pass and an
N log N sort. At N = 3000, d = 384 that is ~3.5 GFLOP plus 3000 sorts,
triggered by every `reload()` call site. Multi-second on an iPhone 8-class
station, while the parent is mid-exchange, and the index is stale until it
finishes.

Fix: stack normalized vectors and compute the N×N similarity once with
`cblas_sgemm` (~0.2 s at N = 3000), derive every intent's LOO from matrix
rows, cache keyed on the exemplar id set. Performance test at N = 2000.

### C11. MEDIUM: Startup ordering starves suggestions until the whole backfill finishes
`Model/SuggestionEngine.swift:51-58`, `App/RosettaApp.swift:11-19`

`start()` awaits the entire backfill before the first `reload()`, and
`capture.embedSamples` is wired only after `start()` returns. On first Phase 2
launch (or after a checkpoint change) that is minutes with a few hundred
clips, during which the index is empty and new segments get no embedding.
Also: negatives are embedded but never read; exemplar and segment rows share a
`clipRef` and are each encoded; rows whose clip is gone are retried every
launch.

Fix: load encoder → `reload()` → wire `embedSamples` → backfill → `reload()`.
Copy embeddings with one `UPDATE ... FROM segments` before encoding.

### C12. MEDIUM: Zero-score neighbours still vote; the probability floor is dead code
`Model/IntentRanker.swift:61, 64-66`, `Model/SuggestionEngine.swift:40, 165`

Negative cosines are clamped to 0 but still occupy k slots, ties broken
alphabetically. The uncalibrated calibrator gives p(0) = 0.119 > the 0.05
floor, so the floor never filters anything. A noise segment, or mixed-dimension
vectors after a checkpoint change (`cosine` silently returns 0 on count
mismatch), yields a confident-looking "Maybe: Apple?" for the alphabetically
first mature intent.

Fix: drop `weightedSim <= 0` before the k cut; in `buildState` drop vectors
whose dimension differs from the modal one; define the floor on the
standardized feature from C1.

### C13. MEDIUM: Recency decay to zero interacts badly with absolute calibration thresholds
`Model/IntentRanker.swift:34-38, 61`

Weight multiplies similarity and tends to 0. A word confirmed heavily six
months ago has all its raw scores quartered, its calibrator (fitted on last
spring's scores) assigns it low probability, and it drops out of top-3 even
though its LOO still passes. Section 5.4 wants old evidence to fade, not
vanish.

Fix: floor the weight (`0.25 + 0.75 * pow(0.5, age / halfLife)`), and refit
calibrators on scores recomputed under current decay during reload.

### C14. LOW-MEDIUM: LabelSimilarity misses inflected and multi-word forms, over-flags 3-letter words
`Model/LabelSimilarity.swift:34-53`

Cluster matching is exact-token on the whole label: "snacks", "want food",
"go potty" never hit the snack/bathroom clusters, while the edit-distance rule
flags "dad"/"mad". Fix: tokenize, strip stopwords and trailing "s", test
cluster membership per token; require length ≥ 5 for distance-1 matches; add
`NLEmbedding.wordEmbedding(for: .english)` (on-device, no network) as a
semantic fallback.

---

## D. UX and product principles

### D1. HIGH: Board column count follows size class, so rotation reflows the grid (principle 3)
`Board/BoardView.swift:26-31`, `project.yml:51-54`

iPhone Plus/Max are `.regular` width in landscape; iPad becomes `.compact` in
Split View. A rotation flips 2 → 4 columns and every button moves.
`BoardLayout` is correctly append-only, but the renderer undoes it.

Fix: lock orientation on iPhone (`UISupportedInterfaceOrientations~iphone:
[Portrait]`) and derive column count from device idiom or a persisted
per-device constant. Add a `BoardLayoutTests` case asserting index → (row,
col) is a pure function of a fixed column count.

### D2. HIGH: Full-resolution camera JPEGs decoded on the main thread in every Board cell
`App/Components/PhotoCapture.swift:64-74`, `Board/BoardView.swift:98-104`,
`App/ConfirmCardView.swift:295-301`, `App/DictionaryView.swift:81-82, 209-210`

`originalImage` is saved at full size. `UIImage(contentsOfFile:)` is called
inside `body` with no cache, so every render re-decodes 12 MP JPEGs (~48 MB
decoded each) for a 120 pt thumbnail. Eight visible cells ≈ 400 MB on the old
phone: a jetsam kill, and the decode lands on the thread that must deliver the
< 100 ms press feedback.

Fix: downsample to ~800 px max edge at save time; add a small
`NSCache`-backed `PhotoCache` with `preparingForDisplay()` used by all four
call sites.

### D3. MEDIUM-HIGH: Abandoned-exchange rate is not measured (principle 9)
`App/ProgressTabView.swift:34-53, 138-139`, `Capture/CaptureController.swift:86-95`

Time-to-understanding is real. Abandoned-exchange rate is absent, and a
session that is never confirmed and then displaced by the next session logs
nothing, so a future computation cannot distinguish "resolved in Review" from
"abandoned".

Fix: log an abandon event in `sessionOpened` when the previous session's
segments are still pending. Add `EventLog.abandonedRate(since:)` and a second
stat card framed positively ("exchanges that got there").

### D4. MEDIUM: Setup interview is not resumable
`App/SetupInterviewView.swift:10-11, 118-129, 134-145`

Everything lives in `@State` and is inserted only at Finish. Launching the
camera is the classic memory-pressure kill on an old phone; 15 minutes of work
dies with the process and captured photos are orphaned. The SLP share is only
reachable on the summary step; section 12 anticipates the SLP wanting the list
after a week of data.

Fix: insert `IntentRecord` on "Add word"; on launch, if intents exist but the
flag is false, resume at the summary. Move `slpSummary()` to a DB-backed
function and add "Share seed list for his SLP" in Settings.

### D5. MEDIUM: Ask flow (section 4.3) is half-implemented
`App/RootView.swift:33-40`, `App/ConfirmCardView.swift:130-131, 141-158`

The in-Confirm Ask path works. But the common path, he walks to the counter
phone mid-exchange and taps "banana" himself, stores only an event. The parent
gets no benefit and the model gets no data.

Fix that keeps principle 2: read `boardTap` events for the current exchange
and render "He tapped: banana" as a pinned guess above the top-3 (tap →
confirm). Allow "Ask on his board" from the empty state when a session is
open or recently closed.

### D6. MEDIUM: Confirm card state bugs
`App/ConfirmCardView.swift:20-26, 49-53, 62, 125, 172-185`, `App/ConfirmViewModel.swift:35`

- The "Saved N clips as ..." banner can never appear: it renders only inside
  `card(model)`, but confirm clears segments and the view switches to the
  empty state. The parent's only feedback is the card vanishing.
- Long-press dismiss calls `model.dismiss` but not `refreshGuesses` or
  `recordOutcome(accepted: false)`; a dismissed intent can stay on screen as a
  top guess and tapping it silently does nothing.
- Only the last 5 chips are shown (`suffix(5)`) but every segment in the
  session is selected and saved. A 90 s session can hold 15 segments; the
  parent audits 5 and labels 15 unseen.
- A segment labelled or "not him"-ed in Review while still on the Confirm
  card can be labelled twice. Re-read state from the DB in `reload()`.

### D7. MEDIUM: Board speech is inconsistent and cold
`Board/SpeechOutput.swift:10, 19-27`, `Board/BoardView.swift:21`

When listening is off the session is `.soloAmbient`, which obeys the ring/silent
switch, so a muted counter phone has a silent Board until someone taps Listen.
A new `AVSpeechSynthesizer` is created every time `BoardView` is re-created;
in the Ask sheet the struct is torn down right after the tap, likely cutting
the word off. First utterance pays voice-load latency.

Fix: one long-lived `SpeechOutput` owned by `AppEnvironment`, pre-warmed on
board appear; ensure a playback-capable category when capture isn't running.
Consider a 250 ms same-intent debounce.

### D8. LOW-MEDIUM: Honesty items in copy
- `App/FirstRunView.swift:29` says "iOS enforces" no network access. iOS has no
  outbound-network entitlement; `CODE_SIGN_ENTITLEMENTS: ""` restricts nothing.
  Behaviour is honest; the claim is not. Reword to "Rosetta never connects to
  the internet; there is no account, no cloud, and no code path that sends
  audio anywhere."
- See B3 for the "delete in one tap" claims.

### D9. LOW: Smaller UX items
- `IntentCell` uses `onTapGesture`/`onLongPressGesture`: no button trait, no
  pressed feedback, long-press unreachable with VoiceOver. Make it a `Button`
  with `.contextMenu`. Fixed point sizes in `ProgressTabView:86` and
  `BoardView:110` ignore Dynamic Type.
- Unstructured, uncancelled `Task`s per segment/toggle in Listen and Confirm
  can resolve out of order and show stale guesses. Keep one handle and cancel.
- `ForEach(perIntent, id: \.label)` in Progress: "Keep both" in setup allows
  identical labels → duplicate ids.
- `childMode` isn't persisted; a relaunch of the counter phone lands in the
  parent tabs.
- Section 7's lock-screen Live Activity for Confirm is absent; a
  `.badge(pendingCount)` on the Confirm tab is a cheap interim win.
- Guest surface groundwork that exists: `respondNote`, read-only live guess
  strip, `labeller` tagging. Missing: any role/lock concept, a read-only
  dictionary view, and the SLP summary as a DB-backed document.

---

## E. Test gaps that would let all of this regress

- No engine-level test (`SuggestionEngine` against an in-memory `AppDatabase`
  with fixture embeddings on segments). C3, C4, C5, C7, C9, C12 are invisible
  to the current suite.
- `CalibrationTests` never uses a realistic narrow score band or prior-inflated
  scores > 1; never asserts finite slope at extremes.
- `MaturityGateTests` never includes same-session duplicates (C2).
- `ContextPriorTests` asserts direction only, never magnitude (a ×25 lift
  passes), and never capture-vs-confirm hour.
- `RankingTests` never tests that dismissing the top intent yields the next
  one, mixed-dimension vectors, or all-zero scores.
- `WhisperKitEmbedder.meanPool` is a pure static function (strides,
  `maxFrames`, float16 path) and is untested; it is the only code touching the
  padding pitfall.
- `SessionBufferTests` use noise deliberately below the VAD floor, so nothing
  exercises floor adaptation (A4). No test for sub-onset blips extending the
  silence timer, or trailing-tail preservation (A7).
- No `SegmentWriter` round trip (write → `ClipAudioLoader.loadSamples`).
- No test that `ExemplarStore.confirm` preserves an embedding written after
  the card's snapshot (B1).
- No export → wipe → import round trip (B2); no test that `deleteForever`
  removes files (B3); no `CaptureController` test with a fake engine for
  interrupt ordering (A5).
- `ConfirmFlowTests` tests a static model only, so C3's rebuild bug is
  invisible.

---

## F. What is actually good (leave it alone)

- `SessionBuffer` as a pure sample-clock state machine with deterministic
  fixture-driven tests is the right design. Pre-roll, onset debounce, the
  10 s / 90 s rules and the `.interrupted` close are implemented correctly.
- `AudioCaptureEngine`'s converter use is correct: one stateful
  `AVAudioConverter`, one-shot input block, 4096-frame tap (~85 ms at 48 kHz).
  Segments are persisted the moment they are cut, on the capture queue.
- `ExemplarStore.confirm` is the single write path, reached only from Confirm,
  Review, and Ask. Principle 2 holds structurally.
- `BoardLayout` is exactly right: append-only slots, gaps as blanks, no move
  API, covered by tests.
- `ConfirmViewModel` is clean, UI-free, idempotent per exchange, and refuses
  dismissed intents; hard-negative-per-selected-segment and the confirm
  latency stamp are correct and tested.
- `WhisperKitEmbedder.meanPool` reads the (1, dim, 1, frames) layout via
  strides, handles float16, and pools only over `ceil(seconds * 50)` real
  frames, so the padded-30 s-window dilution pitfall is already handled.
  Sample-rate handling is consistent end to end.
- `VectorMath` guards every denominator and uses vDSP correctly;
  `EmbeddingCodec` is a clean Float32 round trip; `recencyWeight` is exactly
  `0.5^(age/halfLife)` with the decay-exempt escape hatch.
- `ContextPriors` is exactly 1 with no history and Laplace-smoothed.
- `EmbeddingBackfill` is idempotent and kill-safe (row-at-a-time writes).
- Migrations are versioned via `DatabaseMigrator` with FK cascades and
  sensible indexes on the hot paths; embeddings are compact raw Float32 blobs.
- Clips are excluded from backup by default, `UIBackgroundModes: audio` and
  `.mixWithOthers` are set, no network framework is linked, and WhisperKit is
  correctly pinned to `download: false` with Phase 1 behaviour when no model
  is bundled.
- All model copy is tentative ("Maybe: ...?"), the recording indicator is on
  every parent surface, pause is one tap, and `HoldToExitButton` is a
  thoughtful solution to the guarded-exit problem.

---

## Suggested order of work

1. **Week 1, capture actually captures:** A1, A2, A3, A4 (quick VAD fix +
   max utterance), A8, B1. These are all small and together unblock Phase 1
   acceptance.
2. **Week 2, the card and the store behave:** C3 (both layers), C4, D6, B3,
   B4, D2, D1.
3. **Week 3, ranking learns for real:** C1, C2, C5, C6, C7, C9, C12. Add the
   engine-level test harness first; most of these are invisible without it.
4. **Then:** B2 (import), D3, D4, D5, A5, A6, A7, B5, C10, C11, C13, Silero
   VAD, and the remaining low items.
