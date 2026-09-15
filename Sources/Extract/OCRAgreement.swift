import Foundation

/// How many OCR passes produced this reading, out of how many actually read this
/// part of the page.
///
/// Grounding proves the value is in the OCR text, not that the OCR is right: of 15
/// wrong cells on the best run of a six-page scanned invoice, all 15 were verbatim
/// grounded. Agreement is the signal that was missing — two settings of the same
/// page fail differently (`S1PL ESD` glued under language correction, tariff
/// `64039993900` read as `54039993900` at 300 DPI, a weight token dropped at 400),
/// and a line both passes saw the same way is a different kind of thing from a line
/// they did not.
///
/// A pass that produced nothing for the page is not an observing pass. It failed;
/// it is not a vote against the lines the other pass read.
public struct OCRAgreement: Sendable, Equatable {
    /// Passes whose text at this geometry equals this reading.
    public var matchingPasses: Int
    /// Passes that produced any reading on this page. Empty (failed) passes are
    /// excluded, so they cannot drag the score down.
    public var observingPasses: Int

    public init(matchingPasses: Int, observingPasses: Int) {
        self.matchingPasses = matchingPasses
        self.observingPasses = observingPasses
    }

    /// One pass, or several that all produced this text.
    public var isUnanimous: Bool {
        observingPasses > 0 && matchingPasses == observingPasses
    }

    public static func unanimous(passes: Int) -> OCRAgreement {
        OCRAgreement(matchingPasses: passes, observingPasses: passes)
    }

    /// The weakest score in `agreements` — lowest matching/observing ratio, then
    /// fewest matching passes. Nil when there is nothing to compare.
    public static func weakest(_ agreements: [OCRAgreement]) -> OCRAgreement? {
        agreements.min { a, b in
            let ar = Double(a.matchingPasses) / Double(max(a.observingPasses, 1))
            let br = Double(b.matchingPasses) / Double(max(b.observingPasses, 1))
            if ar != br { return ar < br }
            return a.matchingPasses < b.matchingPasses
        }
    }
}

/// One OCR ingest setting: the knobs that actually change what Vision reads.
///
/// Two passes with the same settings cannot disagree and are dropped. DPI is the
/// raster; `usesLanguageCorrection` is the one that glued `S1PL ESD` into `SIPLESD`
/// on the measured invoice; `recognitionLanguages` is the script the page is in.
public struct OCRPass: Sendable, Equatable {
    public var rasterDPI: Double
    public var recognitionLanguages: [String]
    public var usesLanguageCorrection: Bool

    public init(
        rasterDPI: Double = 300,
        recognitionLanguages: [String] = [],
        usesLanguageCorrection: Bool = true
    ) {
        self.rasterDPI = rasterDPI
        self.recognitionLanguages = recognitionLanguages
        self.usesLanguageCorrection = usesLanguageCorrection
    }
}
