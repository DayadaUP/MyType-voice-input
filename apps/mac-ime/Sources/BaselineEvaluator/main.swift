import Foundation
import Lexicon
import Settings
import TextProcessor

private struct TextBaselineFixture: Decodable {
    let cases: [TextBaselineCase]
}

private struct TextBaselineCase: Decodable {
    let id: String
    let rawText: String
    let expectedFinalText: String
    let userReorderedText: String?
    let options: TextBaselineOptions?

    private enum CodingKeys: String, CodingKey {
        case id
        case rawText = "raw_text"
        case expectedFinalText = "expected_final_text"
        case userReorderedText = "user_reordered_text"
        case options
    }
}

private struct TextBaselineOptions: Decodable {
    let removeFillers: Bool?
    let autoPunctuation: Bool?
    let punctuationStyle: String?
    let preserveCloudRawPunctuation: Bool?

    private enum CodingKeys: String, CodingKey {
        case removeFillers = "remove_fillers"
        case autoPunctuation = "auto_punctuation"
        case punctuationStyle = "punctuation_style"
        case preserveCloudRawPunctuation = "preserve_cloud_raw_punctuation"
    }
}

private struct BaselineThresholds: Decodable {
    let misbreakRateMax: Double
    let punctuationErrorRateMax: Double
    let userSecondRearrangementRateMax: Double
    let e2eTotalP95MsMax: Int
    let firstOutputP95MsMax: Int?

    private enum CodingKeys: String, CodingKey {
        case misbreakRateMax = "misbreak_rate_max"
        case punctuationErrorRateMax = "punctuation_error_rate_max"
        case userSecondRearrangementRateMax = "user_second_rearrangement_rate_max"
        case e2eTotalP95MsMax = "e2e_total_p95_ms_max"
        case firstOutputP95MsMax = "first_output_p95_ms_max"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        misbreakRateMax = try container.decode(Double.self, forKey: .misbreakRateMax)
        punctuationErrorRateMax = try container.decode(Double.self, forKey: .punctuationErrorRateMax)
        userSecondRearrangementRateMax = try container.decode(Double.self, forKey: .userSecondRearrangementRateMax)
        e2eTotalP95MsMax = try container.decode(Int.self, forKey: .e2eTotalP95MsMax)
        firstOutputP95MsMax = try container.decodeIfPresent(Int.self, forKey: .firstOutputP95MsMax)
    }
}

private struct ParsedArguments {
    let textFixturesPath: String
    let pipelineLogsPath: String
    let thresholdsPath: String
}

private struct BaselineMetricsResult: Encodable {
    let caseCount: Int
    let userEditedCaseCount: Int
    let pipelineSampleCount: Int
    let misbreakRate: Double
    let punctuationErrorRate: Double
    let userSecondRearrangementRate: Double
    let firstOutputAvailableCount: Int
    let firstOutputFallbackCount: Int
    let firstOutputP50Ms: Int
    let firstOutputP95Ms: Int
    let stopRecordingP95Ms: Int
    let asrP95Ms: Int
    let textProcessP95Ms: Int
    let finalPolishP95Ms: Int
    let insertionP95Ms: Int
    let e2eTotalP95Ms: Int
    let mismatchedCases: [String]

    private enum CodingKeys: String, CodingKey {
        case caseCount = "case_count"
        case userEditedCaseCount = "user_edited_case_count"
        case pipelineSampleCount = "pipeline_sample_count"
        case misbreakRate = "misbreak_rate"
        case punctuationErrorRate = "punctuation_error_rate"
        case userSecondRearrangementRate = "user_second_rearrangement_rate"
        case firstOutputAvailableCount = "first_output_available_count"
        case firstOutputFallbackCount = "first_output_fallback_count"
        case firstOutputP50Ms = "first_output_p50_ms"
        case firstOutputP95Ms = "first_output_p95_ms"
        case stopRecordingP95Ms = "stop_recording_p95_ms"
        case asrP95Ms = "asr_p95_ms"
        case textProcessP95Ms = "text_process_p95_ms"
        case finalPolishP95Ms = "final_polish_p95_ms"
        case insertionP95Ms = "insertion_p95_ms"
        case e2eTotalP95Ms = "e2e_total_p95_ms"
        case mismatchedCases = "mismatched_cases"
    }
}

private struct GateCheckResult {
    let name: String
    let value: String
    let threshold: String
    let passed: Bool
}

private let sentenceTerminators: Set<Character> = ["。", "！", "？", ".", "!", "?", ";", "；"]
private let punctuationChars: Set<Character> = ["，", "。", "！", "？", "；", "：", "、", ",", ".", "!", "?", ";", ":"]

private func parseArguments() -> ParsedArguments {
    var textFixturesPath: String?
    var pipelineLogsPath: String?
    var thresholdsPath: String?

    var index = 1
    let args = CommandLine.arguments
    while index < args.count {
        let token = args[index]
        switch token {
        case "--text-fixtures":
            index += 1
            if index < args.count {
                textFixturesPath = args[index]
            }
        case "--pipeline-logs":
            index += 1
            if index < args.count {
                pipelineLogsPath = args[index]
            }
        case "--thresholds":
            index += 1
            if index < args.count {
                thresholdsPath = args[index]
            }
        default:
            break
        }
        index += 1
    }

    guard
        let textFixturesPath,
        let pipelineLogsPath,
        let thresholdsPath
    else {
        fputs(
            "Usage: BaselineEvaluator --text-fixtures <path> --pipeline-logs <path> --thresholds <path>\n",
            stderr
        )
        exit(2)
    }

    return ParsedArguments(
        textFixturesPath: textFixturesPath,
        pipelineLogsPath: pipelineLogsPath,
        thresholdsPath: thresholdsPath
    )
}

private func readData(path: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: path))
}

private func sentenceBreakPositions(in text: String) -> Set<Int> {
    var positions: Set<Int> = []
    var cursor = 0
    for char in text {
        cursor += 1
        if sentenceTerminators.contains(char) {
            positions.insert(cursor)
        }
    }
    return positions
}

private func punctuationSequence(in text: String) -> [Character] {
    text.filter { punctuationChars.contains($0) }
}

private func toCharacters(_ text: String) -> [Character] {
    Array(text)
}

private func levenshtein<T: Equatable>(_ lhs: [T], _ rhs: [T]) -> Int {
    if lhs.isEmpty { return rhs.count }
    if rhs.isEmpty { return lhs.count }

    var previous = Array(0...rhs.count)
    var current = Array(repeating: 0, count: rhs.count + 1)

    for (i, leftValue) in lhs.enumerated() {
        current[0] = i + 1
        for (j, rightValue) in rhs.enumerated() {
            let substitutionCost = leftValue == rightValue ? 0 : 1
            current[j + 1] = min(
                current[j] + 1,
                previous[j + 1] + 1,
                previous[j] + substitutionCost
            )
        }
        swap(&previous, &current)
    }

    return previous[rhs.count]
}

private func parseInteger(_ raw: Any?) -> Int? {
    if let value = raw as? Int {
        return value
    }
    if let value = raw as? NSNumber {
        return value.intValue
    }
    if let value = raw as? String {
        return Int(value)
    }
    return nil
}

private func parseBool(_ raw: Any?) -> Bool? {
    if let value = raw as? Bool {
        return value
    }
    if let value = raw as? NSNumber {
        return value.boolValue
    }
    if let value = raw as? String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["1", "true", "yes"].contains(normalized) {
            return true
        }
        if ["0", "false", "no"].contains(normalized) {
            return false
        }
    }
    return nil
}

private struct PipelineTimingSample {
    let stopRecordingMs: Int?
    let asrMs: Int?
    let textProcessMs: Int?
    let finalPolishMs: Int?
    let insertionMs: Int?
    let firstOutputMs: Int?
    let insertedAtStop: Bool?
    let liveInserted: Bool?
    let totalMs: Int?
}

private func extractPipelineSamples(from json: Any) -> [PipelineTimingSample] {
    if let array = json as? [Any] {
        return array.flatMap { extractPipelineSamples(from: $0) }
    }

    if let dictionary = json as? [String: Any] {
        var samples: [PipelineTimingSample] = []

        let sample = PipelineTimingSample(
            stopRecordingMs: parseInteger(dictionary["stopRecordingMs"]),
            asrMs: parseInteger(dictionary["asrMs"]),
            textProcessMs: parseInteger(dictionary["textProcessMs"]),
            finalPolishMs: parseInteger(dictionary["finalPolishMs"]),
            insertionMs: parseInteger(dictionary["insertionMs"]),
            firstOutputMs: parseInteger(dictionary["firstOutputMs"]),
            insertedAtStop: parseBool(dictionary["insertedAtStop"]),
            liveInserted: parseBool(dictionary["liveInserted"]),
            totalMs: parseInteger(dictionary["totalMs"])
        )
        if sample.totalMs != nil
            || sample.firstOutputMs != nil
            || sample.asrMs != nil
            || sample.textProcessMs != nil
            || sample.stopRecordingMs != nil {
            samples.append(sample)
        }

        if let wrappedLogs = dictionary["pipeline_performance_logs"] as? [Any] {
            for item in wrappedLogs {
                if let logLine = item as? String,
                   let lineData = logLine.data(using: .utf8),
                   let nested = try? JSONSerialization.jsonObject(with: lineData) {
                    samples.append(contentsOf: extractPipelineSamples(from: nested))
                } else {
                    samples.append(contentsOf: extractPipelineSamples(from: item))
                }
            }
        }

        return samples
    }

    if let line = json as? String,
       let lineData = line.data(using: .utf8),
       let nested = try? JSONSerialization.jsonObject(with: lineData) {
        return extractPipelineSamples(from: nested)
    }

    return []
}

private func loadPipelineSamples(path: String) throws -> [PipelineTimingSample] {
    let data = try readData(path: path)
    if let object = try? JSONSerialization.jsonObject(with: data) {
        let samples = extractPipelineSamples(from: object)
        if !samples.isEmpty {
            return samples
        }
    }

    guard let asText = String(data: data, encoding: .utf8) else {
        return []
    }

    var samples: [PipelineTimingSample] = []
    for line in asText.split(whereSeparator: \.isNewline) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8) else { continue }
        guard let object = try? JSONSerialization.jsonObject(with: lineData) else { continue }
        samples.append(contentsOf: extractPipelineSamples(from: object))
    }
    return samples
}

private func resolvedFirstOutputMs(sample: PipelineTimingSample) -> (value: Int?, fallbackUsed: Bool) {
    if let firstOutput = sample.firstOutputMs, firstOutput >= 0 {
        return (firstOutput, false)
    }
    if sample.liveInserted == true {
        return (0, true)
    }
    if sample.insertedAtStop == true, let total = sample.totalMs {
        let insertion = max(0, sample.insertionMs ?? 0)
        return (max(0, total - insertion), true)
    }
    return (nil, false)
}

private func percentile(_ values: [Int], p: Int) -> Int {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let bounded = min(max(p, 0), 100)
    if sorted.count == 1 || bounded == 0 {
        return sorted[0]
    }
    let index = Int(ceil((Double(bounded) / 100.0) * Double(sorted.count))) - 1
    return sorted[min(max(index, 0), sorted.count - 1)]
}

private func evaluateTextBaseline(_ fixture: TextBaselineFixture) -> (
    misbreakRate: Double,
    punctuationErrorRate: Double,
    userSecondRearrangementRate: Double,
    userEditedCaseCount: Int,
    mismatchedCases: [String]
) {
    var totalMisbreakError = 0
    var totalMisbreakDenominator = 0

    var totalPunctuationError = 0
    var totalPunctuationDenominator = 0

    var totalUserRearrangementError = 0
    var totalUserRearrangementDenominator = 0
    var userEditedCaseCount = 0
    var mismatchedCases: [String] = []

    for baselineCase in fixture.cases {
        let options = baselineCase.options
        let settings = InMemorySettingsStore()
        settings.set(options?.removeFillers ?? false, forKey: SettingsKeys.removeFillers)
        settings.set(options?.autoPunctuation ?? true, forKey: SettingsKeys.autoPunctuation)
        settings.set(options?.preserveCloudRawPunctuation ?? false, forKey: SettingsKeys.preserveCloudRawPunctuation)
        settings.set(options?.punctuationStyle ?? PunctuationStyle.chinese.rawValue, forKey: SettingsKeys.punctuationStyle)

        let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
        let processed = processor.process(baselineCase.rawText)
        let finalText = processor.polishFinalText(processed)
        let expectedText = baselineCase.expectedFinalText

        if finalText != expectedText {
            mismatchedCases.append(baselineCase.id)
        }

        let expectedBreaks = sentenceBreakPositions(in: expectedText)
        let finalBreaks = sentenceBreakPositions(in: finalText)
        let breakError = expectedBreaks.symmetricDifference(finalBreaks).count
        let breakDenominator = max(expectedBreaks.count, 1)
        totalMisbreakError += breakError
        totalMisbreakDenominator += breakDenominator

        let expectedPunctuation = punctuationSequence(in: expectedText)
        let finalPunctuation = punctuationSequence(in: finalText)
        let punctuationError = levenshtein(expectedPunctuation, finalPunctuation)
        let punctuationDenominator = max(expectedPunctuation.count, 1)
        totalPunctuationError += punctuationError
        totalPunctuationDenominator += punctuationDenominator

        if let userReordered = baselineCase.userReorderedText, !userReordered.isEmpty {
            userEditedCaseCount += 1
            let userDistance = levenshtein(toCharacters(finalText), toCharacters(userReordered))
            let userDenominator = max(toCharacters(userReordered).count, 1)
            totalUserRearrangementError += userDistance
            totalUserRearrangementDenominator += userDenominator
        }
    }

    let misbreakRate = totalMisbreakDenominator > 0
        ? Double(totalMisbreakError) / Double(totalMisbreakDenominator)
        : 0
    let punctuationErrorRate = totalPunctuationDenominator > 0
        ? Double(totalPunctuationError) / Double(totalPunctuationDenominator)
        : 0
    let userSecondRearrangementRate = totalUserRearrangementDenominator > 0
        ? Double(totalUserRearrangementError) / Double(totalUserRearrangementDenominator)
        : 0

    return (
        misbreakRate: misbreakRate,
        punctuationErrorRate: punctuationErrorRate,
        userSecondRearrangementRate: userSecondRearrangementRate,
        userEditedCaseCount: userEditedCaseCount,
        mismatchedCases: mismatchedCases
    )
}

private func buildGateResults(metrics: BaselineMetricsResult, thresholds: BaselineThresholds) -> [GateCheckResult] {
    var gates: [GateCheckResult] = [
        GateCheckResult(
            name: "misbreak_rate",
            value: String(format: "%.4f", metrics.misbreakRate),
            threshold: "<= \(String(format: "%.4f", thresholds.misbreakRateMax))",
            passed: metrics.misbreakRate <= thresholds.misbreakRateMax
        ),
        GateCheckResult(
            name: "punctuation_error_rate",
            value: String(format: "%.4f", metrics.punctuationErrorRate),
            threshold: "<= \(String(format: "%.4f", thresholds.punctuationErrorRateMax))",
            passed: metrics.punctuationErrorRate <= thresholds.punctuationErrorRateMax
        ),
        GateCheckResult(
            name: "user_second_rearrangement_rate",
            value: String(format: "%.4f", metrics.userSecondRearrangementRate),
            threshold: "<= \(String(format: "%.4f", thresholds.userSecondRearrangementRateMax))",
            passed: metrics.userSecondRearrangementRate <= thresholds.userSecondRearrangementRateMax
        ),
        GateCheckResult(
            name: "e2e_total_p95_ms",
            value: "\(metrics.e2eTotalP95Ms)",
            threshold: "<= \(thresholds.e2eTotalP95MsMax)",
            passed: metrics.e2eTotalP95Ms <= thresholds.e2eTotalP95MsMax
        )
    ]

    if let firstOutputLimit = thresholds.firstOutputP95MsMax {
        gates.append(
            GateCheckResult(
                name: "first_output_p95_ms",
                value: "\(metrics.firstOutputP95Ms)",
                threshold: "<= \(firstOutputLimit)",
                passed: metrics.firstOutputP95Ms <= firstOutputLimit
            )
        )
    }

    return gates
}

private func main() throws {
    let arguments = parseArguments()
    let decoder = JSONDecoder()

    let fixtureData = try readData(path: arguments.textFixturesPath)
    let textFixture = try decoder.decode(TextBaselineFixture.self, from: fixtureData)
    guard !textFixture.cases.isEmpty else {
        fputs("Text baseline fixture has no cases.\n", stderr)
        exit(1)
    }

    let thresholdsData = try readData(path: arguments.thresholdsPath)
    let thresholds = try decoder.decode(BaselineThresholds.self, from: thresholdsData)

    let pipelineSamples = try loadPipelineSamples(path: arguments.pipelineLogsPath)
    let totalMsValues = pipelineSamples.compactMap(\.totalMs)
    guard !totalMsValues.isEmpty else {
        fputs("Pipeline performance logs contain no usable totalMs values.\n", stderr)
        exit(1)
    }
    let stopRecordingMsValues = pipelineSamples.compactMap(\.stopRecordingMs)
    let asrMsValues = pipelineSamples.compactMap(\.asrMs)
    let textProcessMsValues = pipelineSamples.compactMap(\.textProcessMs)
    let finalPolishMsValues = pipelineSamples.compactMap(\.finalPolishMs)
    let insertionMsValues = pipelineSamples.compactMap(\.insertionMs)
    let firstOutputResolved = pipelineSamples.map { resolvedFirstOutputMs(sample: $0) }
    let firstOutputMsValues = firstOutputResolved.compactMap(\.value)
    let firstOutputFallbackCount = firstOutputResolved.reduce(0) { partial, item in
        partial + ((item.value != nil && item.fallbackUsed) ? 1 : 0)
    }

    let textMetrics = evaluateTextBaseline(textFixture)
    let result = BaselineMetricsResult(
        caseCount: textFixture.cases.count,
        userEditedCaseCount: textMetrics.userEditedCaseCount,
        pipelineSampleCount: pipelineSamples.count,
        misbreakRate: textMetrics.misbreakRate,
        punctuationErrorRate: textMetrics.punctuationErrorRate,
        userSecondRearrangementRate: textMetrics.userSecondRearrangementRate,
        firstOutputAvailableCount: firstOutputMsValues.count,
        firstOutputFallbackCount: firstOutputFallbackCount,
        firstOutputP50Ms: percentile(firstOutputMsValues, p: 50),
        firstOutputP95Ms: percentile(firstOutputMsValues, p: 95),
        stopRecordingP95Ms: percentile(stopRecordingMsValues, p: 95),
        asrP95Ms: percentile(asrMsValues, p: 95),
        textProcessP95Ms: percentile(textProcessMsValues, p: 95),
        finalPolishP95Ms: percentile(finalPolishMsValues, p: 95),
        insertionP95Ms: percentile(insertionMsValues, p: 95),
        e2eTotalP95Ms: percentile(totalMsValues, p: 95),
        mismatchedCases: textMetrics.mismatchedCases
    )

    let gateResults = buildGateResults(metrics: result, thresholds: thresholds)
    let allPassed = gateResults.allSatisfy(\.passed)

    print("Baseline Evaluation")
    print(
        "cases=\(result.caseCount) user_edited_cases=\(result.userEditedCaseCount) "
            + "pipeline_samples=\(result.pipelineSampleCount)"
    )
    print("misbreak_rate=\(String(format: "%.4f", result.misbreakRate))")
    print("punctuation_error_rate=\(String(format: "%.4f", result.punctuationErrorRate))")
    print("user_second_rearrangement_rate=\(String(format: "%.4f", result.userSecondRearrangementRate))")
    print(
        "first_output_available_count=\(result.firstOutputAvailableCount) "
            + "fallback_count=\(result.firstOutputFallbackCount)"
    )
    print("first_output_p50_ms=\(result.firstOutputP50Ms)")
    print("first_output_p95_ms=\(result.firstOutputP95Ms)")
    print("stop_recording_p95_ms=\(result.stopRecordingP95Ms)")
    print("asr_p95_ms=\(result.asrP95Ms)")
    print("text_process_p95_ms=\(result.textProcessP95Ms)")
    print("final_polish_p95_ms=\(result.finalPolishP95Ms)")
    print("insertion_p95_ms=\(result.insertionP95Ms)")
    print("e2e_total_p95_ms=\(result.e2eTotalP95Ms)")
    if !result.mismatchedCases.isEmpty {
        print("mismatched_cases=\(result.mismatchedCases.joined(separator: ","))")
    }

    print("Gate Check")
    for gate in gateResults {
        print("\(gate.passed ? "PASS" : "FAIL") \(gate.name): value=\(gate.value) threshold=\(gate.threshold)")
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    if let metricsJSON = try? encoder.encode(result), let line = String(data: metricsJSON, encoding: .utf8) {
        print("BASELINE_METRICS_JSON \(line)")
    }

    if !allPassed {
        exit(1)
    }
}

do {
    try main()
} catch {
    fputs("BaselineEvaluator failed: \(error)\n", stderr)
    exit(1)
}
