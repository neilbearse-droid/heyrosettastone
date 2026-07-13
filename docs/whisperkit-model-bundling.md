# Bundling the WhisperKit encoder model

Rosetta makes no network calls — principle §2.7 is structural. WhisperKit
normally downloads model checkpoints from Hugging Face at first run; Rosetta
never does that (`download: false` is hard-coded in `WhisperKitEmbedder`).
Instead the Core ML model ships inside the app bundle. Without it, the app
runs as pure Phase 1: board, capture, confirm — just no suggestions.

## One-time developer step

On your Mac:

```sh
pip install "huggingface_hub[cli]"
huggingface-cli download argmaxinc/whisperkit-coreml \
  --include "openai_whisper-tiny/*" \
  --local-dir ./WhisperKitModels
```

This produces `WhisperKitModels/openai_whisper-tiny/` containing
`AudioEncoder.mlmodelc`, `MelSpectrogram.mlmodelc`, and friends
(~40 MB for tiny). Only the encoder and mel models are used; the decoder
is loaded but never invoked for transcription.

## Add to the app

1. Drag the `openai_whisper-tiny` folder into the Xcode project navigator,
   into the `Rosetta` app target.
2. Choose **Create folder references** (blue folder), NOT groups — the
   folder structure must survive into the bundle.
3. Build. `WhisperKitEmbedder.bundledModelFolder()` finds it by name.

If you manage sources with XcodeGen, add to the Rosetta target in
`project.yml` instead:

```yaml
    sources:
      - App
      - Board
      - Capture
      - Model
      - Data
      - path: WhisperKitModels/openai_whisper-tiny
        type: folder
```

(and re-run `xcodegen generate`). The folder is gitignored by default —
each developer fetches it once; nothing that large lives in git history.

## Verifying

Run the app, open Progress: words show "learning" state with exemplar
counts once the encoder is live. Console logs nothing on failure by design;
`SuggestionEngine.isModelAvailable` is the programmatic check.

## Upgrading checkpoints

`openai_whisper-base` (~150 MB) improves embedding quality in noise at the
cost of latency; §5.7's budget (< 1 s segment-to-ranking on an iPhone 12)
holds for tiny and base on ANE. Change `WhisperKitEmbedder.modelName` and
bundle the matching folder. Existing exemplar embeddings must be
regenerated after a checkpoint change: Settings → wipe is NOT needed —
delete embeddings (`UPDATE exemplars SET embedding = NULL`) and let the
backfill re-run, or add a migration; embedding spaces of different
checkpoints are not comparable.
