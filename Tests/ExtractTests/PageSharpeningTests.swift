import CoreGraphics
import Foundation
import Testing

@testable import Extract

/// Sharpening a page before reading it, and the wiring that carries the setting to the render.
@Suite("Sharpening a page before it is read")
struct PageSharpeningTests {
    private func grey(_ value: CGFloat) -> CGImage {
        let context = CGContext(
            data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        context.setFillColor(CGColor(gray: value, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 16))
        return context.makeImage()!
    }

    @Test("no mask leaves the page exactly as it was")
    func withoutAMaskNothingHappens() {
        let image = grey(0.5)
        #expect(PageSharpening.applying(nil, to: image) === image)
    }

    @Test("a mask with nothing to add is not an edit")
    func zeroMaskIsNotAnEdit() {
        let image = grey(0.5)
        #expect(PageSharpening.applying(UnsharpMask(radius: 2.5, intensity: 0), to: image) === image)
        #expect(PageSharpening.applying(UnsharpMask(radius: 0, intensity: 1.5), to: image) === image)
    }

    @Test("a mask produces a page of the same shape")
    func maskKeepsTheGeometry() {
        let image = grey(0.5)
        let sharpened = PageSharpening.applying(.measured, to: image)
        #expect(sharpened.width == image.width)
        #expect(sharpened.height == image.height)
    }

    /// The measured setting is the one the invoice was scored with: 82 of 86 barcodes against
    /// 75 for the same render unsharpened. It is recorded here so a later tweak to the numbers
    /// has to be deliberate.
    @Test("the measured mask is the one that was measured")
    func measuredSettingIsRecorded() {
        #expect(UnsharpMask.measured == UnsharpMask(radius: 2.5, intensity: 1.5))
    }

    @Test("the primary pass carries the caller's sharpening")
    func primaryPassCarriesTheMask() {
        var options = ExtractionOptions()
        options.sharpen = .measured
        #expect(options.resolvedOCRPasses().first?.sharpen == .measured)
    }

    @Test("two passes that differ only in sharpening are two passes")
    func sharpeningDistinguishesPasses() {
        var options = ExtractionOptions()
        options.rasterDPI = 600
        options.sharpen = .measured
        options.additionalOCRPasses = [OCRPass(rasterDPI: 600, sharpen: nil)]
        let passes = options.resolvedOCRPasses()
        #expect(passes.count == 2, "the same render read soft and read sharp can disagree")
        #expect(passes.last?.sharpen == nil)
    }
}
