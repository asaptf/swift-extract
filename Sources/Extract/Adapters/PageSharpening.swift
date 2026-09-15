import CoreGraphics
import Foundation

#if canImport(CoreImage)
    import CoreImage
#endif

/// An unsharp mask applied to a rendered page before it is read.
///
/// A scan has soft edges, and a barcode's digits are printed small directly under its bars.
/// macOS 27's text recogniser reads that softness as noise: on the measured six-page invoice
/// one whole article block came back as nothing but its size numbers — no barcode, no
/// country, no weights, no prices — and eleven other barcodes came back with the bars
/// themselves read as accented letters and welded to the digits.
///
/// Sharpening first changes that. Of the 86 barcodes, a plain 600 DPI render yields 75 and the
/// same render through a radius 2.5, intensity 1.5 unsharp mask yields 82, including two rows
/// of the block that had read as blank. It is not free in either direction — too much of it
/// turns the scan's own grain into edges, and radius 4 and above reads *worse* than no
/// sharpening at all — which is why it is a setting with measured numbers behind it rather
/// than something applied to every page by default.
public struct UnsharpMask: Sendable, Equatable {
    /// Radius in pixels of the blur the mask is built from. Measured best near 2.5 at 600 DPI;
    /// 4 and above read worse than not sharpening.
    public var radius: Double
    /// How much of the mask is added back. Measured best near 1.5.
    public var intensity: Double

    public static let measured = UnsharpMask(radius: 2.5, intensity: 1.5)

    public init(radius: Double = 2.5, intensity: Double = 1.5) {
        self.radius = radius
        self.intensity = intensity
    }
}

enum PageSharpening {
    /// `image` with `mask` applied, or `image` unchanged when there is nothing to apply or the
    /// platform cannot do it. Sharpening is an improvement to a reading, never a precondition
    /// for one, so a failure here costs quality rather than the page.
    static func applying(_ mask: UnsharpMask?, to image: CGImage) -> CGImage {
        guard let mask, mask.intensity > 0, mask.radius > 0 else { return image }
        #if canImport(CoreImage)
            let sharpened = CIImage(cgImage: image).applyingFilter(
                "CIUnsharpMask",
                parameters: [kCIInputRadiusKey: mask.radius, kCIInputIntensityKey: mask.intensity])
            guard let made = context.createCGImage(sharpened, from: sharpened.extent) else {
                return image
            }
            return made
        #else
            return image
        #endif
    }

    #if canImport(CoreImage)
        /// One context for the process: creating a `CIContext` per page costs more than the
        /// filter it runs, and every page of a document wants the same one.
        private static let context = CIContext(options: [.useSoftwareRenderer: false])
    #endif
}
