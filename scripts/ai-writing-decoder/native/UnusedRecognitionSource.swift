// The diagnostic exercises text normalization only. Any accidental call into
// device speech discovery must fail rather than fabricate a supported language.
enum RecognitionSource: Equatable {
    case appleSpeech
    func supportedLanguages() -> [ASRLanguageOption] {
        fatalError("Speech discovery is outside this text-only diagnostic")
    }
}
