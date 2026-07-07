// MARK: - Plato
import Testing
import Foundation
@testable import leanring_buddy

// Regression tests for the response.done usage parse. The usage object
// arrives nested under "response" ({"type":"response.done","response":
// {"usage":{...}}}), but the parser used to read only the top-level
// "usage" key — so every telemetry turn row logged null tokens
// (root-cause report, instrumentation item 4).
struct RealtimeUsageParsingTests {

    private let usageJSON: [String: Any] = [
        "input_tokens": 1200,
        "output_tokens": 340,
        "total_tokens": 1540,
        "input_token_details": ["cached_tokens": 800, "audio_tokens": 150],
        "output_token_details": ["audio_tokens": 300, "reasoning_tokens": 0],
    ]

    @Test func parsesUsageNestedInsideResponseDoneEvent() {
        let responseDoneEvent: [String: Any] = [
            "type": "response.done",
            "response": ["id": "resp_1", "status": "completed", "usage": usageJSON],
        ]
        let usage = RealtimeUsage.parse(from: responseDoneEvent)
        #expect(usage?.input_tokens == 1200)
        #expect(usage?.output_tokens == 340)
        #expect(usage?.total_tokens == 1540)
        #expect(usage?.audio_input_tokens == 150)
        #expect(usage?.cached_input_tokens == 800)
        #expect(usage?.audio_output_tokens == 300)
        #expect(usage?.text_input_tokens == 250)
        #expect(usage?.text_output_tokens == 40)
    }

    @Test func stillParsesTopLevelUsageForOtherEventShapes() {
        let usage = RealtimeUsage.parse(from: ["usage": usageJSON])
        #expect(usage?.input_tokens == 1200)
    }

    @Test func returnsNilWhenNoUsagePresent() {
        let usage = RealtimeUsage.parse(from: ["type": "response.done", "response": ["id": "resp_1"]])
        #expect(usage == nil)
    }
}
