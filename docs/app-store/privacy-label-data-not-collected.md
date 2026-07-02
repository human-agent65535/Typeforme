# App Privacy Label: Data Not Collected

Use this file as the source of truth for App Store Connect App Privacy answers
for the current Typeforme design.

## App Store Connect Answer

- Do you or your third-party partners collect data from this app?
  - No, we do not collect data from this app.
- Tracking:
  - No tracking.
- Tracking domains:
  - None.

## Rationale

Typeforme does not operate a server that receives, stores, or analyzes user
audio, text, identifiers, diagnostics, or usage data from the App Store app.
The iOS app, iOS keyboard extension, and macOS app process data locally or send
requests only to destinations configured and controlled by the user:

- The user's iPhone.
- The user's paired Mac Bridge.
- User-configured external LLM or compatible endpoints.
- Apple Speech, only when the user enables Apple Speech features.

Under Apple's App Privacy definition, data processed only on device is not
collected. Data sent to service a request and not retained by the developer
beyond real-time servicing is not collected by the developer. In Typeforme's
current App Store design, no Typeforme-operated backend receives or retains this
data.

## Data Still Processed For App Functionality

These are not App Store "collected data" for Typeforme under the current design,
but they must be described in the privacy policy and review notes:

- Audio Data: microphone recordings used for dictation.
- Other User Content: dictated text, selected text, nearby text context, prompts,
  and refinement results.
- Identifiers: pairing token and local keychain/app group identifiers.
- Diagnostics: local logs and optional debug captures stored on the user's
  device.
- Product Interaction: local settings and keyboard learning data stored on the
  user's device.

## Conditions That Would Require Updating The Label

Change the App Store privacy label before release if any of these become true:

- Typeforme adds developer-operated sync, account, analytics, crash reporting,
  telemetry, support upload, or logging services.
- Typeforme receives or stores user audio, text, prompts, identifiers,
  diagnostics, or usage data on infrastructure operated by the developer.
- A third-party SDK is added that collects analytics, diagnostics, identifiers,
  or other app data.
- Debug captures or support bundles can be uploaded to the developer from inside
  the app.
- Any data is used for advertising, marketing, measurement, or tracking.

## App Store Connect Notes

If App Review asks why the label is Data Not Collected:

Typeforme is local-first. The iOS app and keyboard extension send dictation
requests only to the user's paired Mac Bridge or to endpoints the user
explicitly configures. Typeforme does not operate a backend that receives,
stores, analyzes, or tracks app data. Debug captures and keyboard learning data
are local-only.
