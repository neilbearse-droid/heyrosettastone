# Rosetta: a family-trained communication recognizer

Build spec for Claude Code. Working title only; rename at will.

Platform: iOS 17+, SwiftUI, on-device only.

## 1. What this is

One child. His speech is intelligible to his family and opaque to everyone else. The family decodes him today through a live game of many no's and then a yes. This app captures that game as labelled training data and learns his specific audio-to-meaning mappings, so that the guessing gets shorter for family and becomes possible for people who don't know him.

It is a digitized communication dictionary (an existing SLP tool: what he says, what it means, how to respond) with a learning layer on top. It never attempts transcription. An utterance is an arbitrary audio pattern that means whatever the family confirms it means, which correctly handles dysarthric speech, apraxic variability, and gestalt/echolalic phrases carrying private meaning.

## 2. Product principles

These are panel rulings. Treat them as constraints, not suggestions.

1. Useful on day one. The board and dictionary work before any ML exists. The model earns its way in.
2. Face ID rule. The exemplar store updates only on explicit confirmation. No silent self-training.
3. The child's grid never moves. Button positions are motor patterns. All adaptivity lives on the parent surface.
4. His rejection is final. A dismissed guess is dismissed, regardless of model confidence, and is stored as a hard negative.
5. No demands on the child. No prompts to repeat, no timeouts, no streaks, no rewards pointed at him. The app never gates access to a want behind a tap.
6. The app narrows, the family confirms. All output is phrased as a guess ("Maybe: banana?"), never a declaration.
7. His voice never leaves the device. The app ships with no network entitlement. Privacy is structural, enforced by the OS.
8. Two-tap ceiling for any parent action taken mid-interaction.
9. Success metric is time-to-understanding per exchange, plus abandoned-exchange rate. Model accuracy is an internal diagnostic.

## 3. Surfaces

Child surface. The Board: a fixed grid of large photo buttons. Tapping speaks the word aloud (his choice of voice, age-appropriate) and logs the event. This is his tool; it must feel instant and predictable.

Parent surface. Five tabs: Listen (ambient capture status and pause), Confirm (the in-the-moment labelling card), Review (deferred labelling queue), Dictionary (intent management, exemplar browsing, pruning), Progress (per-word maturity, exemplar counts, time-to-understanding trend).

Guest surface (phase 3). Read-only view for grandparents, EAs, respite workers: the dictionary ("when he says or does X it usually means Y, respond by Z") plus live top-3 guesses. This is the destination product; the family already understands him.

## 4. Core flows

### 4.1 Setup interview

A guided 15-minute onboarding that builds the seed dictionary. Prompts the family for the 20 to 30 things he communicates most often. For each intent: canonical label, a photo taken of his actual object where applicable (his banana, his cup, his bathroom door), an optional "how to respond" note for guests. The app flags near-duplicate labels (snack vs hungry) and asks the family to merge or keep, because inconsistent labels across caregivers poison the classes. Vocabulary seed gets validated by his real SLP; the app includes a shareable one-page summary of the seed list for that conversation.

### 4.2 Exchange capture (the session buffer)

Ambient listening runs on a designated device (an old iPhone on a counter stand beats a muffled pocket phone). A rolling buffer holds audio; voice activity detection segments it into utterances.

An exchange session opens at the first detected utterance and closes after 10 seconds of silence or 90 seconds total, whichever comes first. Within a session, all detected speech segments are retained as waveform chips.

When the exchange resolves (the yes moment), the parent opens the Confirm card:

1. Top: up to five recent segment chips with playback. Default selection is every segment in the session, on the theory that he repeated the same intent through the no's. Parent can deselect chips that were someone else's voice or unrelated.
2. Middle: top-3 intent guesses as large buttons (once the model is live), then a frequency-sorted grid, then search.
3. One tap on the intent saves: each selected segment becomes a confirmed exemplar of that intent. Each guess the parent or child dismissed during the exchange is stored as a hard negative pair.

Two taps total in the common case: confirm chips (pre-selected), tap intent. Anything skipped lands in Review.

### 4.3 Ask flow

For a complex or novel phrase, the parent invokes the Board directly and he selects, or the parent selects on his behalf after resolving it the old way. Either path attaches the session audio and produces labelled exemplars. This doubles as the cold-start data engine: the board is useful communication on day one and every use of it feeds the model.

### 4.4 Review queue

Evening batch labelling. Playback each unlabelled segment, one tap to label, discard, or mark "not him." Segments expire from the queue after 24 hours because parental memory of what he meant goes stale; expired segments are kept on disk but flagged unlabelled.

### 4.5 Ranking in the wild

Once an intent reaches maturity (section 5.6), the parent surface shows live top-3 guesses during an exchange with confidence dots. Copy is always tentative. If the parent or child rejects all three, the exchange proceeds as normal guessing and the eventual confirmation is extra-valuable training signal (the model was wrong; the hard negatives say how).

The child's Board never reorders. If a suggestion strip for him is ever added, it occupies a fixed dedicated row and the grid below stays frozen.

## 5. The model

### 5.1 Pipeline

Capture (AVAudioEngine, 16 kHz mono) → VAD segmentation (Silero VAD via ONNX/Core ML; fallback: Apple SoundAnalysis speech classification as coarse gate) → per-segment embedding (WhisperKit encoder, tiny or base checkpoint, mean-pooled over time to a fixed vector) → cosine k-nearest-neighbour against the exemplar store → context prior multiplication → per-intent calibrated score → top-3.

No gradient training on device in MVP. Learning is append-only exemplar accumulation plus threshold calibration.

### 5.2 Learning rules

On confirm: append (embedding, audio ref, intent, context, timestamp, labeller) to the store.

On reject: append (embedding, rejected intent) to the negatives table. Negatives never move embeddings; they fit a per-intent logistic calibration over accept/reject history so each word learns its own distance threshold.

kNN over all exemplars, small k (3 to 5), rather than class prototypes. Apraxic speech produces multimodal classes (the same word said several distinct ways) and exemplar kNN handles that naturally where prototype averaging destroys it. Exemplars are individually browsable and prunable in Dictionary, so one mislabelled clip can be deleted without corrupting the class.

### 5.3 Context priors

Cheap accuracy. Multiply kNN similarity by a smoothed prior from: hour-of-day bucket, capture device identity (kitchen station vs bathroom station), and short-horizon recency of the same intent. Autistic routines make these priors strong; banana at 7am on the kitchen device should outrank banana at 9pm in the bath.

### 5.4 Drift as he grows

Exponential recency weighting on exemplar distances, half-life around 90 days, tunable. Old exemplars are never auto-deleted; they decay in influence and remain reviewable. Expect his voice to change; the design assumes retraining is permanent and continuous.

### 5.5 Child-voice filtering

MVP: the "not him" toggle in Review and chip deselection in Confirm carry this manually. Phase 3: enrol a speaker embedding for him (ECAPA-TDNN class model converted to Core ML) and pre-filter segments, with siblings as the known hard case.

### 5.6 Maturity gates

An intent becomes suggestible when it has at least 5 confirmed exemplars and leave-one-out top-3 hit rate on its own exemplars clears a threshold (start at 0.7, tune). Expect 5 to 15 exemplars per word before ranking usefully beats chance at home, longer in noise. Progress view shows per-word maturity so the family can see exactly which words the model knows and which need more confirmations.

### 5.7 Performance budget

End-to-end segment-to-ranking under 1 second on an iPhone 12 or newer, ANE where available. Embedding store for a few thousand exemplars is trivially in memory; cosine via Accelerate.

## 6. Data

Storage: GRDB (SQLite) for structured data, m4a clips on disk, iOS Data Protection class Complete, no iCloud backup of audio by default (family-toggleable, default off, with plain-language explanation).

Tables: intents (id, label, photo ref, respond-note, created), exemplars (id, intent id, clip ref, embedding blob, device, context json, labeller, timestamp, decay-exempt flag), negatives (embedding blob, rejected intent id, timestamp), events (exchange id, type: confirm/reject/skip/board-tap, latency ms), sessions (start, end, device).

Export: share-sheet zip of audio plus JSON for backup or moving devices. Wipe-all with confirmation. SLP report export: PDF summary of intent inventory, frequencies, contexts, and growth over time, no raw audio.

No accounts. No analytics SDKs. No third-party network calls. The binary requests no network entitlement.

## 7. UX requirements

Child board. Fixed grid, positions permanent unless a parent explicitly edits layout (with a warning that moving buttons costs him relearning). Touch targets 2.5 cm minimum with generous hit slop; hypotonia makes precision hard. Real photos over clipart. Visual plus audio feedback under 100 ms. Speech output only when he triggers it; no unexpected sounds from the device, ever. High contrast, low clutter, Dynamic Type, VoiceOver.

Parent surfaces. One-handed, glanceable, interruptible; state auto-saves at every step. The Confirm card is reachable from a lock-screen Live Activity or widget in one gesture during an active session.

Recording trust. A persistent, legible on-screen indicator while listening. One-tap pause that takes effect instantly. First-run screen in plain language: what is recorded, where it lives (this device only), how to delete it.

Tone. All model output is tentative. Progress celebrates the family's accumulated knowledge (exemplar counts, words matured, median time-to-understanding falling) and never gamifies the child.

## 8. Consent and dignity

He is a minor who cannot give verbal consent, so the design carries it: visible indicator he can learn to recognize, honoured pause, honoured distress (if he objects to a device, that room goes quiet, no argument), data minimization, full local deletion, structural no-network. The app supplements his AAC and therapy and replaces neither; his SLP stays in the loop via the seed validation and the export report.

## 9. Phases and acceptance criteria

### Phase 1: capture and board, no ML

Setup interview, Board with speech output, session buffering with VAD, Confirm card (chips plus manual intent selection), Review queue with 24h expiry, Dictionary CRUD, local storage and export, recording indicator and pause.

Accept when: a parent completes setup in under 20 minutes; a full exchange (capture, confirm, exemplar saved with correct audio attached) works in two taps; the child can operate the Board with no instruction beyond a demonstration; a week of daily use accumulates 50+ labelled exemplars without anyone touching settings.

### Phase 2: ranking

Embedding pipeline, kNN plus calibration, context priors, maturity gates, top-3 on Confirm card and live parent view, per-word maturity in Progress, recency decay.

Accept when: mature intents hit at least 70 percent top-3 in home conditions on held-out confirmations; suggestion latency under 1 second; a wrong-and-rejected guess measurably tightens that word's threshold; median time-to-understanding trend is visible in Progress.

### Phase 3: the destination

Guest mode, speaker filtering, multi-station sync over Multipeer Connectivity (keeps the no-cloud promise), SLP PDF export, board layout editing with motor-pattern warning.

## 10. Stack and repo

Swift 5.10, SwiftUI, iOS 17+. AVAudioEngine capture. WhisperKit (Argmax) for encoder features. Silero VAD via onnxruntime or Core ML conversion; document the conversion step. GRDB. Accelerate for similarity. No networking frameworks linked.

Repo: `App/` (SwiftUI), `Capture/` (audio engine, VAD, session buffer), `Model/` (embeddings, store, kNN, calibration, priors), `Data/` (GRDB, export), `Board/`, `Tests/`.

Tests that matter most: session buffer stamping (label attaches to the correct segments across a long noisy exchange), kNN with recency weighting against fixture embeddings, board grid immutability, Confirm card two-tap path, expiry logic in Review.

## 11. Claude Code kickoff prompt

> Read rosetta_spec.md in full before writing code. Build Phase 1 only. Respect every constraint in section 2 as a hard requirement; if any implementation choice would violate one, stop and flag it instead of working around it. Start by scaffolding the repo layout in section 10, then implement in this order: data layer, session buffer with VAD, Board, setup interview, Confirm card, Review queue. Write the section 10 tests alongside each component, and use fixture audio files for anything involving capture. Do not add networking, analytics, or any third-party SDK beyond WhisperKit, the VAD runtime, and GRDB.

## 12. Open questions for the family

Which two rooms get listening stations, and is there an old iPhone available for each. The seed list of 20 to 30 intents, with photos. Who labels (both parents, siblings, grandma) so labeller IDs mean something. Which output voice he prefers for the Board, decided by him if he shows a preference. Whether his SLP wants the seed list before or after a week of frequency data.
