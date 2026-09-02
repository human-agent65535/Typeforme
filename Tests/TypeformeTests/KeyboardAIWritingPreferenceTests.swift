import Testing
@testable import Typeforme

struct KeyboardAIWritingPreferenceTests {
    @Test func keyboardCanSwitchBeforeHostAcknowledges() {
        let host = KeyboardAIWritingPreference(enabled: false)
        let request = KeyboardAIWritingPreference.Request(enabled: true)

        #expect(host.applying(request).enabled)
        #expect(host.applying(request).appliedRequestID == request.id)
        #expect(!host.enabled)
    }

    @Test func delayedHostPublicationDoesNotUndoNewerSwitch() {
        let initial = KeyboardAIWritingPreference(enabled: false)
        let enable = KeyboardAIWritingPreference.Request(enabled: true)
        let disable = KeyboardAIWritingPreference.Request(enabled: false)
        let delayedHost = initial.applying(enable)

        let keyboard = delayedHost.applying(disable)
        #expect(!keyboard.enabled)
        #expect(keyboard.appliedRequestID == disable.id)
        #expect(keyboard.applying(disable) == keyboard)
    }

    @Test func acknowledgedRequestDoesNotOverrideLaterHostSetting() {
        let request = KeyboardAIWritingPreference.Request(enabled: true)
        let host = KeyboardAIWritingPreference(enabled: false, appliedRequestID: request.id)

        #expect(host.applying(request) == host)
    }

    @Test func repeatedChoiceStillAcknowledgesLatestRequest() {
        let first = KeyboardAIWritingPreference.Request(enabled: true)
        let latest = KeyboardAIWritingPreference.Request(enabled: true)
        let host = KeyboardAIWritingPreference(enabled: true, appliedRequestID: first.id)

        #expect(host.applying(latest).enabled)
        #expect(host.applying(latest).appliedRequestID == latest.id)
    }

    @Test func noKeyboardRequestPreservesHostSetting() {
        for enabled in [false, true] {
            let host = KeyboardAIWritingPreference(enabled: enabled)
            #expect(host.applying(nil) == host)
        }
    }
}
