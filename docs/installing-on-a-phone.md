# Installing Rosetta on a phone

You need a Mac with Xcode 15 or newer, an iPhone on iOS 17 or newer, a USB
cable, and an Apple ID. A paid developer account is optional (see step 7).

## 1. Get the code and generate the Xcode project

The Xcode project is not checked in; XcodeGen builds it from `project.yml`.

```sh
git clone https://github.com/neilbearse-droid/heyrosettastone
cd heyrosettastone
git checkout claude/rosetta-communication-app-mx93m1
brew install xcodegen
xcodegen generate
open Rosetta.xcodeproj
```

Xcode will resolve the two Swift packages (GRDB, WhisperKit) on first open.

## 2. Optional: bundle the speech encoder

Without it the app runs as Phase 1 only (board, capture, confirm, review):
no guesses. To get Phase 2 ranking, fetch the Whisper tiny checkpoint once:

```sh
pip install "huggingface_hub[cli]"
huggingface-cli download argmaxinc/whisperkit-coreml \
  --include "openai_whisper-tiny/*" --local-dir ./WhisperKitModels
xcodegen generate
```

`project.yml` already references that folder as optional, so re-running
`xcodegen generate` picks it up. Details in `whisperkit-model-bundling.md`.

## 3. Set up signing

In Xcode, select the `Rosetta` target, then Signing & Capabilities:

- Tick "Automatically manage signing".
- Team: your Apple ID. If it isn't listed, add it under Xcode > Settings >
  Accounts first.
- If Xcode complains the bundle identifier is taken, change
  `bundleIdPrefix` in `project.yml` to something unique (for example
  `com.yourname.rosetta`) and re-run `xcodegen generate`.

## 4. Prepare the phone

- Settings > Privacy & Security > Developer Mode > On (phone restarts).
- Plug in with the cable and tap Trust on the phone.

## 5. Build and run

Pick the phone in Xcode's device menu (top bar), then press Run (Cmd+R).

The first build will almost certainly stop on compile errors: this code
was written without a compiler. `improvement-review.md` ends with a short
watch-list of the exact lines most likely to need a touch. Fix, re-run.

## 6. Trust the app on the phone

The first launch may be blocked with "Untrusted Developer". On the phone:
Settings > General > VPN & Device Management > your Apple ID > Trust.

## 7. Keeping it installed

- **Free Apple ID:** the app stops launching after 7 days and must be
  re-run from Xcode. Fine for testing, not for a counter-top station.
- **Paid developer account ($99/yr):** builds last a year, and you can
  push to TestFlight so the family installs it from the TestFlight app on
  each phone with no cable. That's the right setup once it's working.

## 8. First launch checklist on the device

Work through "Verify on device, in this order" at the end of
`improvement-review.md`: locked-phone capture, a phone call mid-session,
a Board tap while listening, a TV in the room, and export/restore.
