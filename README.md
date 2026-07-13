# Rosetta

A family-trained communication recognizer. One child, whose speech his family
understands and strangers don't. Rosetta is a digitized communication
dictionary with a learning layer: the family confirms what an utterance meant,
the app accumulates those confirmations, and the guessing gets shorter.

This repository implements **Phases 1 and 2** of
[`rosetta_spec.md`](rosetta_spec.md): capture and board, plus ranking. Read
the spec in full before changing anything — section 2 lists nine product
principles that are hard constraints, not suggestions.

## What works in Phase 1

- **Setup interview** — guided onboarding that builds the seed dictionary
  (20–30 intents, photos of his real objects, respond-notes for guests),
  flags near-duplicate labels, and produces a shareable seed summary for
  his SLP.
- **The Board** — a fixed grid of large photo buttons. Tapping speaks the
  word and logs the event. Positions are motor patterns and never move.
- **Exchange capture** — ambient listening with VAD segmentation. An exchange
  session opens on the first utterance, closes after 10 s of silence or 90 s
  total. Segments are kept as playable chips.
- **Confirm card** — chips pre-selected, one tap on the intent saves every
  selected segment as a confirmed exemplar. Two taps total in the common case.
  Dismissed guesses are stored as hard negatives.
- **Review queue** — evening batch labelling with 24-hour expiry (expired
  segments stay on disk, flagged unlabelled).
- **Dictionary** — intent CRUD, exemplar browsing and pruning.
- **Progress** — exemplar counts and time-to-understanding trend.
- **Recording trust** — persistent on-screen indicator, one-tap pause,
  plain-language first-run screen.

## What Phase 2 adds (ranking)

- **Embeddings** — WhisperKit's audio encoder (tiny checkpoint, encoder
  only, never transcription), mean-pooled to a fixed vector per segment,
  computed near capture time. The checkpoint must be **bundled** — Rosetta
  never downloads it (see
  [`docs/whisperkit-model-bundling.md`](docs/whisperkit-model-bundling.md)).
  Without a bundled model the app runs exactly as Phase 1.
- **kNN ranking** — cosine k-nearest-neighbour over all exemplars (never
  class prototypes; apraxic classes are multimodal), with 90-day half-life
  recency decay and a decay-exempt flag. Old exemplars fade in influence
  but are never deleted.
- **Context priors** — smoothed hour-of-day, station, and just-confirmed
  recency multipliers. Exactly 1 with no history.
- **Per-intent calibration** — a logistic per word over its accept/reject
  history; a wrong-and-rejected guess measurably tightens that word's
  threshold.
- **Maturity gates** — a word is suggested only after 5+ confirmed
  exemplars and a ≥0.7 leave-one-out top-3 hit rate on its own clips.
- **Top-3 in the UI** — "Maybe: banana?" buttons with confidence dots on
  the Confirm card (tap accepts, ✕ dismisses and is final) and read-only
  live guesses on Listen. Progress explains per word whether the model is
  guessing, learning (n of 5), or needs more varied clips.

## What is deliberately absent

- No networking. The app links no networking framework and requests no
  network entitlement; the ML checkpoint ships in the bundle rather than
  downloading. Audio never leaves the device. This is structural, not a
  setting.
- No accounts, no analytics, no third-party SDKs beyond GRDB and WhisperKit.
- No gradient training on device: learning is append-only exemplar
  accumulation plus threshold calibration (§5.1).
- The Silero VAD runtime is still pending; Phase 1's energy VAD serves
  behind the same protocol, and the conversion step is documented in
  [`docs/silero-vad-conversion.md`](docs/silero-vad-conversion.md).
- Phase 3: guest mode, speaker filtering, multi-station sync, SLP PDF
  export, board layout editing.

## Building

Requires Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate
open Rosetta.xcodeproj
```

Run tests with `⌘U` or:

```sh
xcodebuild test -scheme Rosetta -destination 'platform=iOS Simulator,name=iPhone 15'
```

## Layout

| Directory  | Contents |
|------------|----------|
| `App/`     | SwiftUI app, parent tabs, setup interview, confirm/review UI |
| `Board/`   | Child board: fixed grid, layout rules, speech output |
| `Capture/` | Audio engine, VAD, session buffer, segment writer |
| `Model/`   | Embeddings, kNN ranker, calibration, priors, maturity, suggestion engine |
| `Data/`    | GRDB schema, stores, file protection, export |
| `Tests/`   | Section 10 tests: buffer stamping, board immutability, two-tap path, review expiry, kNN with recency weighting on fixture embeddings, calibration, maturity |

## Principles enforced in code

A few of section 2's rulings have direct structural expression here, worth
knowing before you edit:

- **Board immutability** (`Board/BoardLayout.swift`): slot assignment is
  append-only; there is no API that moves an occupied slot. Layout editing is
  Phase 3 and will be an explicit, warned, parent-only flow.
- **Explicit confirmation only** (`Data/Stores.swift`): exemplars are created
  in exactly one place, `ExemplarStore.confirm(...)`, which is only reachable
  from the Confirm card, Review queue, and Ask flow. Nothing self-trains.
- **Rejection is final** (`ConfirmViewModel`): a dismissed guess is removed
  from the candidate set for the rest of the exchange and recorded as a hard
  negative.
- **No sounds at the child** : the only speech output is triggered by his tap
  on the Board. Parent surfaces are silent; chip playback is a parent action.
