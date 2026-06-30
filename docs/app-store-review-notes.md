# App Store Review Notes Draft

Use this as the starting point for App Review notes. Update the bundle id,
test account details, and public privacy policy URL before submission.

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

## Privacy notes

- Dictation audio is recorded by the iOS host app and sent to the user-paired
  Mac Bridge for transcription.
- The host app uses the background audio mode to keep a user-visible microphone
  session ready for keyboard dictation after the user enables it. The keyboard
  extension does not record audio directly.
- The keyboard may send selected text or nearby text context only when the user
  explicitly starts dictation, a repair command, or a refine action.
- Keyboard learning data is stored locally in the app group and can be reset
  from Keyboard Settings.
- Typeforme does not use tracking.

## Known review blockers to resolve before submission

- Confirm App Review notes clearly explain the background audio mode as the
  user-visible host microphone session for keyboard dictation.
- Replace the default `com.example` bundle prefix with a real App Store bundle
  prefix owned by the developer team.
