import Foundation

protocol BridgeLanguageOptionRepresentable {
    var id: String { get }
    var displayName: String { get }
}

enum BridgeSettingsNormalization {
    static let asrTimeoutSecondsRange: ClosedRange<Double> = 10...300
    static let correctionTimeoutMillisecondsRange: ClosedRange<Int> = 100...30_000
    static let correctionColdTimeoutMillisecondsRange: ClosedRange<Int> = 1_000...60_000

    static var correctionTimeoutSecondsRange: ClosedRange<Double> {
        secondsRange(for: correctionTimeoutMillisecondsRange)
    }

    static var correctionColdTimeoutSecondsRange: ClosedRange<Double> {
        secondsRange(for: correctionColdTimeoutMillisecondsRange)
    }

    static func clampedASRTimeoutSec(_ value: Double) -> Double {
        clamped(value, to: asrTimeoutSecondsRange)
    }

    static func clampedCorrectionTimeoutMs(_ value: Int) -> Int {
        clamped(value, to: correctionTimeoutMillisecondsRange)
    }

    static func clampedCorrectionColdTimeoutMs(_ value: Int) -> Int {
        clamped(value, to: correctionColdTimeoutMillisecondsRange)
    }

    static func correctionTimeoutMs(fromSeconds value: Double) -> Int {
        milliseconds(fromSeconds: value, range: correctionTimeoutMillisecondsRange)
    }

    static func correctionColdTimeoutMs(fromSeconds value: Double) -> Int {
        milliseconds(fromSeconds: value, range: correctionColdTimeoutMillisecondsRange)
    }

    static func normalizedASRModelIDs(
        currentModelIDs: [String: String],
        incomingModelIDs: [String: String],
        optionsBySource: [String: [BridgeSettingOption]],
        defaultID: (String) -> String
    ) -> [String: String] {
        var normalized = currentModelIDs
        for (sourceID, options) in optionsBySource {
            guard !options.isEmpty else {
                normalized.removeValue(forKey: sourceID)
                continue
            }

            let rawModelID = incomingModelIDs[sourceID]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? defaultID(sourceID)
            if options.contains(where: { $0.id == rawModelID }) {
                normalized[sourceID] = rawModelID
            } else {
                let fallbackID = defaultID(sourceID)
                normalized[sourceID] = options.first(where: { $0.id == fallbackID })?.id ?? options[0].id
            }
        }
        return normalized
    }

    static func normalizedASRTimeoutSeconds(
        currentTimeouts: [String: Double],
        incomingTimeouts: [String: Double]
    ) -> [String: Double] {
        var normalized = currentTimeouts
        for (sourceID, timeout) in incomingTimeouts {
            guard normalized[sourceID] != nil else { continue }
            normalized[sourceID] = clampedASRTimeoutSec(timeout)
        }
        return normalized
    }

    static func clampedASRTimeoutSeconds(_ timeouts: [String: Double]) -> [String: Double] {
        timeouts.mapValues(clampedASRTimeoutSec)
    }

    static func orderedUniqueLanguageOptions<Option: BridgeLanguageOptionRepresentable>(
        _ options: [Option]
    ) -> [Option] {
        var byID: [String: Option] = [:]
        for option in options {
            let id = option.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, byID[id] == nil else { continue }
            byID[id] = option
        }

        var ordered = ASRLanguageSelection.all.compactMap { byID.removeValue(forKey: $0.id) }
        ordered.append(contentsOf: byID.values.sorted {
            let nameOrder = $0.displayName.localizedStandardCompare($1.displayName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return $0.id < $1.id
        })
        return ordered
    }

    static func rimeUserPhrases(from surfaces: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for surface in surfaces {
            let cleaned = surface
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            let key = cleaned.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
            guard seen.insert(key).inserted else { continue }
            output.append(cleaned)
        }
        return output.sorted()
    }

    private static func secondsRange(for range: ClosedRange<Int>) -> ClosedRange<Double> {
        (Double(range.lowerBound) / 1000)...(Double(range.upperBound) / 1000)
    }

    private static func milliseconds(fromSeconds seconds: Double, range: ClosedRange<Int>) -> Int {
        let clampedSeconds = clamped(seconds, to: secondsRange(for: range))
        return clamped(Int((clampedSeconds * 1000).rounded()), to: range)
    }

    private static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private static func clamped(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
