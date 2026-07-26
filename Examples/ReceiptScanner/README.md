# ReceiptScanner

Polished multiplatform demo for **swift-extract**.

## Open in one click

```bash
open Examples/ReceiptScanner/ReceiptScanner.xcodeproj
```

Or double-click `ReceiptScanner.xcodeproj` in Finder.

Select the **ReceiptScanner** scheme → **My Mac** or an iOS Simulator → Run.

## What you get

| Screen | Behavior |
| --- | --- |
| Pick | Import PDF/image, Photo Library, Take Photo (iOS), sample fixtures |
| Extracting | Animated progress while the real `Extract` API runs |
| Result | Editable form + raw JSON toggle |
| Settings | Apple Intelligence / MLX / OpenAI / Anthropic (Keychain for keys) |

If no backend is configured, a **setup** screen explains how to enable one. There is no hardcoded success path.

## Fixtures (bundled)

- `invoice.pdf` — digital invoice (text layer)
- `receipt.png` — synthetic paper receipt
- `email_screenshot.png` — order confirmation screenshot

## SPM-only alternative

```bash
cd Examples/ReceiptScanner
swift run ReceiptScanner
```

## Regenerating the Xcode project

If you change targets or package layout:

```bash
cd Examples/ReceiptScanner
xcodegen generate
```

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
