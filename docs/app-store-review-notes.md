# App Store Review Notes

Use this as the starting point for App Review notes. Update the bundle id and
any public test details before submission.

Privacy Policy URL: https://github.com/human-agent65535/Typeforme/blob/main/docs/app-store/privacy-policy.md

## What the reviewer needs

- Install the iOS app and enable the Typeforme keyboard in iOS Settings.
- Turn on Full Access for the Typeforme keyboard. Full Access is required so
  the keyboard extension can connect to the Typeforme host app over the local
  loopback bridge, sync settings, and send dictation or refine requests.
- Pair with a Mac running Typeforme in Server mode. The iOS app needs a Bridge
  pairing token and at least one enabled `lan_bridge_urls` or `public_bridge_url`
  value.

## Suggested review setup

1. Launch the Mac app.
2. Switch This Mac to Server.
3. Enable Bridge and LAN access.
4. Open Pair Clients and copy the pairing JSON.
5. On iPhone, open Typeforme, paste the pairing JSON, and save.
6. Enable the Typeforme keyboard with Full Access.
7. Open any text field, switch to the Typeforme keyboard, and use the mic button
   to dictate. If iOS opens Typeforme to prepare microphone access, wait for
   the ready toast, then use the system back/swipe affordance to return to the
   previous app.
8. If Keyboard Settings uses PiP capture, start the visible Typeforme Picture
   in Picture session before returning to the text field. The microphone opens
   only after the user presses the keyboard mic button.

## Privacy notes

- App Privacy is submitted as Data Not Collected. Typeforme does not operate a
  backend that receives, stores, analyzes, or tracks app data.
- Dictation audio is recorded by the iOS host app and sent to the user-paired
  Mac Bridge for transcription. The paired Mac is configured and controlled by
  the user.
- The host app uses the background audio mode for keyboard dictation readiness:
  Background Mic keeps a user-visible host audio session ready after the user
  enables it, and PiP capture keeps a visible Typeforme Picture in Picture
  session active so the keyboard can reach the host without switching apps.
  The microphone opens only during user-initiated recording. The keyboard
  extension does not record audio directly.
- The keyboard may send selected text or nearby text context only when the user
  explicitly starts dictation, a repair command, or a refine action.
- If the user configures an external LLM-compatible endpoint, Typeforme sends
  the relevant prompt and text to that user-selected endpoint. Typeforme does
  not proxy that traffic through developer infrastructure.
- Keyboard learning data is stored locally in the app group and can be reset
  from Keyboard Settings.
- Typeforme does not use tracking.

## Before submission checklist

- Replace the default `com.example` bundle prefix with a real App Store bundle
  prefix owned by the developer team.
- Keep the background audio mode explanation aligned with the shipped Keyboard
  Settings capture options.
- Publish the privacy policy URL before submitting for App Review.
- Revisit `docs/app-store/privacy-label-data-not-collected.md` before release if
  any analytics, crash reporting, support upload, sync, account, or
  developer-operated backend is added.
