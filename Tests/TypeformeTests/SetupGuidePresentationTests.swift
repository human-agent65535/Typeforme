import Testing
@testable import Typeforme

@Suite("Setup guide presentation")
struct SetupGuidePresentationTests {
    @Test func onlyAutomaticallyPresentsBeforeFirstDismissalOrCompletion() {
        #expect(AppSettings.shouldShowSetupGuide(hasShown: false, completed: false))
        #expect(!AppSettings.shouldShowSetupGuide(hasShown: true, completed: false))
        #expect(!AppSettings.shouldShowSetupGuide(hasShown: false, completed: true))
        #expect(!AppSettings.shouldShowSetupGuide(hasShown: true, completed: true))
    }

    @Test func serverSetupRequiresAtLeastOneReadyASRSource() {
        #expect(!SetupGuideWizardView.isASRConfigurationReady(
            appleSpeechEnabled: false,
            appleSpeechReady: false,
            qwenEnabled: false,
            qwenInstalled: false,
            nvidiaEnabled: false,
            nvidiaInstalled: false
        ))
        #expect(SetupGuideWizardView.isASRConfigurationReady(
            appleSpeechEnabled: false,
            appleSpeechReady: false,
            qwenEnabled: true,
            qwenInstalled: true,
            nvidiaEnabled: false,
            nvidiaInstalled: false
        ))
        #expect(!SetupGuideWizardView.isASRConfigurationReady(
            appleSpeechEnabled: true,
            appleSpeechReady: false,
            qwenEnabled: false,
            qwenInstalled: false,
            nvidiaEnabled: false,
            nvidiaInstalled: false
        ))
    }
}
