import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One page as a picture, on its way to a model that can look at it.
///
/// OCR is where this product's stubborn errors live: a tariff `64039993900` read as
/// `54039993900`, a part number `S1PL ESD` glued into `SIPLESD`. A model only ever copies what
/// OCR handed it, which is why two models three sizes apart make the same mistakes. A model
/// that can see the page does not inherit them.
public struct PageImage: Sendable, Equatable {
    public var data: Data
    /// `image/png` or `image/jpeg` — what the backend must declare to the provider.
    public var mediaType: String
    /// Which page this is, so a finding can name it.
    public var pageIndex: Int

    public init(data: Data, mediaType: String, pageIndex: Int) {
        self.data = data
        self.mediaType = mediaType
        self.pageIndex = pageIndex
    }

    /// Encodes a rendered page as PNG. `nil` when the image cannot be encoded at all.
    public init?(_ image: CGImage, pageIndex: Int) {
        let buffer = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                buffer, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        self.init(data: buffer as Data, mediaType: "image/png", pageIndex: pageIndex)
    }
}
