import CoreGraphics
import Foundation
import Testing

@testable import Extract

@Suite("Orientation detector")
struct OrientationDetectorTests {
    @Test("wide high-confidence lines beat tall lines by a large margin")
    func axisScorePrefersWideLines() {
        let wide = [
            line("INVOICE TOTAL QUANTITY AMOUNT", width: 0.8, height: 0.04, confidence: 1)
        ]
        let tall = [
            line("INVOICE TOTAL QUANTITY AMOUNT", width: 0.04, height: 0.8, confidence: 1)
        ]
        let upright = OrientationDetector.axisScore(wide)
        let sideways = OrientationDetector.axisScore(tall)
        #expect(upright > sideways * 5)
        #expect(OrientationDetector.choose(upright: wide, rotated90: tall) == 0)
        #expect(OrientationDetector.choose(upright: tall, rotated90: wide) == 90)
    }

    @Test("character x-order distinguishes 0° from 180°")
    func characterOrderPicks180() {
        let ltr = [line("SHIPMENT NUMBER VL1403649 PAGE", ltr: true)]
        let rtl = [line("SHIPMENT NUMBER VL1403649 PAGE", ltr: false)]
        #expect(OrientationDetector.readingDirection(ltr) > 0)
        #expect(OrientationDetector.readingDirection(rtl) < 0)
        #expect(OrientationDetector.choose(upright: rtl, rotated90: []) == 180)
        #expect(OrientationDetector.choose(upright: [], rotated90: rtl) == 270)
        #expect(OrientationDetector.choose(upright: ltr, rotated90: []) == 0)
    }

    @Test("empty recognitions stay at 0°")
    func emptyStaysUpright() {
        #expect(OrientationDetector.choose(upright: [], rotated90: []) == 0)
        #expect(OrientationDetector.readingDirection([]) == 0)
    }

    private func line(
        _ text: String,
        width: CGFloat = 0.8,
        height: CGFloat = 0.04,
        confidence: Double = 1,
        ltr: Bool = true
    ) -> RecognizedLine {
        let count = max(text.count, 1)
        let xs: [CGFloat] = (0..<count).map { index in
            let t = CGFloat(index) / CGFloat(count)
            return ltr ? 0.1 + 0.8 * t : 0.9 - 0.8 * t
        }
        return RecognizedLine(
            text: text,
            boundingBox: CGRect(x: 0.1, y: 0.2, width: width, height: height),
            confidence: confidence,
            characterXs: xs
        )
    }
}
