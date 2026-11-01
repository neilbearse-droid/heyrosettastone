# Silero VAD: ONNX → Core ML conversion and bundling

Rosetta's voice activity detection is `SileroVAD` (Capture/SileroVAD.swift)
behind the `VoiceActivityDetector` protocol, with Phase 1's `EnergyVAD` as
the fallback. Which one runs is decided at the first Listen start by
`VoiceActivityDetectorFactory.makeDefault()`: Silero if a compiled model is
in the app bundle and loads, the energy gate otherwise. Exactly like the
WhisperKit encoder (docs/whisperkit-model-bundling.md), the app ships
without the model unless a developer adds it, and nothing is ever
downloaded (principle §2.7). Spec §10 requires the conversion step to be
documented; this is it.

## What the runner expects

`CoreMLSileroRunner` loads `SileroVAD.mlmodelc` from the bundle root (or
from a `CoreMLModels/` subdirectory, if you add a folder reference
instead) with `MLModelConfiguration.computeUnits = .cpuAndNeuralEngine`.

| Feature | Name | Type | Shape | Notes |
|---|---|---|---|---|
| input | `audio` | float32 | (1, 512) — any shape with 512 elements | one 32 ms window at 16 kHz |
| input | `state` | float32 | (2, 1, 128) — any shape with 256 elements | recurrent (h, c) state; zeros at stream start |
| input | `sr` | int32 (float32/double accepted) | (1,) | optional; filled with 16000 if present |
| output | any name, e.g. `output` | float32/float16/double | 1 element | speech probability 0…1 |
| output | any name, e.g. `stateN` | float32/float16/double | 256 elements | new state, same layout as `state` |

Outputs are matched by element count, not by name, so the ONNX names
(`output`, `stateN`) or anything coremltools substitutes both work. The
state is handled as a flat row-major array of shape (2, 1, 128): element
`[layer, 0, i]` is at index `layer * 128 + i`. Input and output strides are
honoured, so a padded Neural Engine buffer is read correctly.

If the interface differs (wrong input names, a non-float32 audio/state
input, no 1-element and 256-element output pair), `loadIfAvailable()`
returns nil and the energy detector serves — silently, by design. To see
why, call `try CoreMLSileroRunner(contentsOf: url)` from a debug build and
read the thrown `RunnerError`.

## Option A (preferred): Core ML conversion

Silero VAD v5 is distributed as `silero_vad.onnx` (~2 MB) in the
[snakers4/silero-vad](https://github.com/snakers4/silero-vad) repository
(`src/silero_vad/data/silero_vad.onnx`). The ONNX graph has explicit state
I/O (`input`, `state`, `sr` → `output`, `stateN`), which is what we want;
the `.jit` model keeps its state internally and is not suitable.
coremltools no longer converts ONNX directly, so go ONNX → PyTorch →
Core ML. On a Mac with Python 3.11:

```sh
pip install "coremltools>=8" onnx onnx2torch torch numpy
```

```python
import coremltools as ct
import numpy as np
import onnx
import torch
from onnx2torch import convert

onnx_model = onnx.load("silero_vad.onnx")
core = convert(onnx_model).eval()

class SileroWrapper(torch.nn.Module):
    """Fixes the sample rate at 16 kHz so the exported model has only the
    audio and state inputs (the runner treats `sr` as optional)."""
    def __init__(self, core):
        super().__init__()
        self.core = core
        self.sr = torch.tensor(16000, dtype=torch.int64)

    def forward(self, audio, state):
        out, new_state = self.core(audio, state, self.sr)
        return out, new_state

wrapper = SileroWrapper(core)
example = (torch.zeros(1, 512), torch.zeros(2, 1, 128))
traced = torch.jit.trace(wrapper, example, strict=False)

mlmodel = ct.convert(
    traced,
    convert_to="mlprogram",
    inputs=[
        ct.TensorType(name="audio", shape=(1, 512), dtype=np.float32),     # 32 ms @ 16 kHz
        ct.TensorType(name="state", shape=(2, 1, 128), dtype=np.float32),
    ],
    outputs=[
        ct.TensorType(name="output"),   # (1, 1) speech probability
        ct.TensorType(name="stateN"),   # (2, 1, 128) new state
    ],
    minimum_deployment_target=ct.target.iOS17,
    compute_units=ct.ComputeUnit.CPU_AND_NE,
)
mlmodel.save("SileroVAD.mlpackage")
```

If you would rather keep `sr` as an input, trace with a third example
tensor `torch.tensor([16000], dtype=torch.int64)` and add
`ct.TensorType(name="sr", shape=(1,), dtype=np.int32)`; the runner fills
it with 16000 (int32, float32 and double are all accepted).

Sanity-check the result before bundling it:

```python
m = ct.models.MLModel("SileroVAD.mlpackage")
print(m.get_spec().description)  # names, shapes, dtypes as in the table above
state = np.zeros((2, 1, 128), dtype=np.float32)
out = m.predict({"audio": np.zeros((1, 512), dtype=np.float32), "state": state})
print(out)                        # a probability near 0 for silence, and a (2,1,128) state
```

Known risk: `onnx2torch` must handle every op in the Silero graph
(including the `If` on the sample rate and the STFT/convolution front
end). If it fails on an op, try the current `onnx2torch` release first;
otherwise fall back to Option B.

## Add to the app

1. Create `CoreMLModels/` at the repository root and put
   `SileroVAD.mlpackage` in it. The folder is gitignored like
   `WhisperKitModels/`: each developer converts once, nothing that large
   lives in git history.
2. `project.yml` already references `CoreMLModels/SileroVAD.mlpackage` as
   an optional source. Re-run `xcodegen generate`. Xcode compiles the
   package into `SileroVAD.mlmodelc` at the bundle root.
3. `COREML_CODEGEN_LANGUAGE` is set to `None` in `project.yml` on purpose:
   Xcode would otherwise generate a Swift class named `SileroVAD` from the
   file name, colliding with the detector struct. Keep the file name;
   do not re-enable codegen.
4. Do not rename the file: `CoreMLSileroRunner.modelName` is `SileroVAD`.

If you manage the project in Xcode directly, drag the `.mlpackage` into
the `Rosetta` target (as a file, not a folder reference) and set the same
build setting under Build Settings → Core ML Model Class Generation
Language → None.

## Verifying on the phone

- `CaptureController.vadKind` is `.silero` after the first Listen start
  when the model loaded, `.energy` otherwise; the Listen tab shows which
  one once that readout is wired. `VoiceActivityDetectorFactory.activeKind`
  is the same answer from anywhere.
- `CaptureController.liveLevel.confidence` carries the model's last speech
  probability (nil under the energy detector). Speak near the phone: it
  should climb toward 1; a TV in the next room should stay low where the
  energy meter alone would have crossed its threshold.
- First-start latency: the first Listen tap after an install blocks for
  the model load (the OS compiles it for the Neural Engine once, then
  caches). Later starts reuse the loaded detector.

## How the detector runs

`SessionBuffer` feeds 30 ms (480-sample) frames; the network wants 32 ms
(512-sample) windows. `SileroVAD` accumulates frames and runs the model
each time 512 samples are available (about 31 calls per second), threading
the recurrent state between calls and zeroing it in `reset()`. A frame's
answer is the latest probability with hysteresis (`SileroVAD.Tuning`):
speech starts at ≥ 0.5 and ends below 0.35. The decision can therefore lag
the audio by up to one window (32 ms); the buffer's 3-frame onset debounce
and 0.5 s hangover already tolerate that. An `EnergyVAD` runs alongside on
every frame so the Listen tab's RMS/threshold meter keeps its meaning.

Once Silero is in and false positives drop, consider raising
`SessionBuffer.Tuning.hangover` from 0.5 s to 0.7–0.8 s so pauses inside a
word don't split it (see the comment there).

### Fallback behaviour

- No model in the bundle, or it fails to load or validate: `EnergyVAD`
  serves for the whole process; `vadKind == .energy`.
- The model throws on a call: that frame is "not speech", `SileroVAD
  .lastError` holds the reason and `currentConfidence` is nil until the
  next successful call.
- Three failures in a row: the model is abandoned (`isDegraded == true`),
  no further Core ML calls are made, and the detector answers exactly like
  `EnergyVAD` for the rest of the process — the embedded energy detector
  has been learning the room all along, so there is no cold start.
  `reset()` does not re-arm it; a relaunch retries. `vadKind` still reads
  `.silero` in this state; `liveLevel.confidence` being nil is the tell.

## Option B: onnxruntime

Add the `onnxruntime-objc` (or `onnxruntime-swift-package-manager`)
package and run `silero_vad.onnx` directly. Larger binary (~15 MB) but zero
conversion risk. Implement `SileroModelRunner` over an `ORTSession` (the
same 512-sample audio, 256-float state contract) and return it from
`VoiceActivityDetectorFactory.makeDefault()` in place of
`CoreMLSileroRunner`; `SileroVAD` itself needs no change.

## Fallback: Apple SoundAnalysis

`SNClassifySoundRequest` with the built-in classifier's "speech" class works
as a coarse gate (spec §5.1). Latency and granularity are worse than Silero;
use only if both options above are blocked.

## Why the seam is safe

`VoiceActivityDetector` is a small protocol over 30 ms frames.
`SessionBuffer` owns all debouncing, session logic, and timing, so VAD
replacement cannot change exchange semantics — only detection quality.
`Tests/SessionBufferTests.swift` drives the buffer with a `SileroVAD` over a
scripted fake runner and expects the same segments and session close as
with the energy detector; `Tests/SileroVADTests.swift` covers the
rebuffering, state threading, hysteresis and failure handling without
Core ML.
