# Typeforme Privacy Policy

Effective date: 2026-07-02

Typeforme is a local-first dictation and text refinement app for macOS and iOS.
This policy describes the App Store version of Typeforme.

## Summary

Typeforme does not collect data from the app for the developer to access,
store, analyze, sell, or use for advertising. Typeforme does not use tracking,
third-party advertising, or third-party analytics SDKs.

Dictation audio, text context, settings, pairing tokens, keyboard learning data,
and debug captures are processed on devices you control or on services you
explicitly configure. They are not sent to a Typeforme-operated server.

## Data Processed On Your Devices

Typeforme may process the following data locally to provide app functionality:

- Microphone audio used for dictation.
- Transcripts, selected text, and nearby text context used for dictation,
  rewrite, repair, or refine actions that you start.
- Pairing details for the Mac Bridge you configure.
- Keyboard settings, language preferences, and keyboard learning data.
- Local diagnostics, including raw audio and text, only when Debug Capture is
  enabled by you.

This data stays on your iPhone, your Mac, or the user-controlled App Group and
Keychain storage used by Typeforme. Debug captures are stored locally and can be
deleted from the app.

## Paired Mac Bridge

The iOS app and keyboard extension can send dictation audio and text context to
your paired Mac running Typeforme in Server mode. The paired Mac performs speech
recognition, text refinement, and Bridge responses for the iOS app. This is a
user-configured, user-controlled connection. The developer does not receive or
operate this Bridge traffic.

## Optional External Services

If you configure an OpenAI-compatible, Anthropic-compatible, or other external
text refinement endpoint, Typeforme sends the relevant prompt and text to that
service to complete the request. That endpoint is controlled by you or by the
provider you choose, and its privacy practices are governed by that provider's
terms.

When Apple Speech is enabled, speech recognition may be handled by Apple
according to your selected settings and Apple's privacy practices. Typeforme does
not receive Apple Speech data beyond the recognition result returned to the app.

## Permissions

Typeforme asks for permissions only when they are needed:

- Microphone: to record your dictation.
- Speech Recognition: to use Apple Speech when you enable it.
- Local Network: to connect to your paired Mac Bridge or a local endpoint you
  configure.
- Camera on iOS: to scan a pairing QR code shown by the Mac app.
- Full Access for the iOS keyboard: to let the keyboard extension connect to
  the host app, sync settings, and send dictation or refine requests you start.
- Accessibility on macOS: to insert generated text into the active app.

## Retention And Deletion

Typeforme does not retain app data on developer-operated servers. Data stored
locally remains on your devices until you delete it, reset app settings, remove
the app, clear debug captures, or remove local model/runtime files.

You can revoke system permissions in iOS or macOS Settings. You can delete local
debug captures from Typeforme's diagnostics settings.

## Contact

For privacy questions, contact:

typeforme@b1ank.page
