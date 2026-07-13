# Silero VAD: ONNX → Core ML conversion

Phase 1 ships `EnergyVAD` behind the `VoiceActivityDetector` protocol.
Phase 2 swaps in Silero VAD. Spec §10 requires the conversion step to be
documented; this is it.

## Option A (preferred): Core ML conversion

Silero VAD v5 is distributed as `silero_vad.onnx` (~2 MB) in the
[snakers4/silero-vad](https://github.com/snakers4/silero-vad) repository.
Convert on a Mac with Python 3.11:

```sh
pip install coremltools onnx
```

```python
import coremltools as ct

# coremltools consumes ONNX indirectly; for opset >= 16 the reliable path is
# ONNX -> PyTorch trace via the silero repo, then ct.convert:
import torch
model, _ = torch.hub.load("snakers4/silero-vad", "silero_vad", onnx=False)
model.eval()

# The model is stateful (h/c recurrent state). Trace with explicit state I/O.
example = (torch.zeros(1, 512), torch.zeros(2, 1, 128), torch.tensor(16000))
traced = torch.jit.trace(model, example, strict=False)

mlmodel = ct.convert(
    traced,
    inputs=[
        ct.TensorType(name="audio", shape=(1, 512)),        # 32 ms @ 16 kHz
        ct.TensorType(name="state", shape=(2, 1, 128)),
        ct.TensorType(name="sr", shape=(1,)),
    ],
    minimum_deployment_target=ct.target.iOS17,
    compute_units=ct.ComputeUnit.CPU_AND_NE,
)
mlmodel.save("SileroVAD.mlpackage")
```

Drop `SileroVAD.mlpackage` into `Capture/` and add it to the Rosetta target.
Implement `SileroVoiceActivityDetector: VoiceActivityDetector` that:

1. Rebuffers our 480-sample frames into the model's 512-sample windows.
2. Threads the recurrent state between calls; resets it in `reset()`.
3. Applies the standard thresholds (speech > 0.5, with the same
   onset/hangover debouncing already implemented in `SessionBuffer`, which
   stays unchanged).

## Option B: onnxruntime

Add the `onnxruntime-objc` (or `onnxruntime-swift-package-manager`) package
and run `silero_vad.onnx` directly. Larger binary (~15 MB) but zero
conversion risk. Same protocol wrapper as above.

## Fallback: Apple SoundAnalysis

`SNClassifySoundRequest` with the built-in classifier's "speech" class works
as a coarse gate (spec §5.1). Latency and granularity are worse than Silero;
use only if both options above are blocked.

## Why the seam is safe

`VoiceActivityDetector` is a two-method protocol over 30 ms frames.
`SessionBuffer` owns all debouncing, session logic, and timing, so VAD
replacement cannot change exchange semantics — only detection quality.
