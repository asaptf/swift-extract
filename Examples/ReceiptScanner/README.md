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
| Settings | Apple Intelligence / MLX (download from Hub) / OpenAI / Anthropic (Keychain for keys) |

If no backend is configured, a **setup** screen explains how to enable one. There is no hardcoded success path.

### MLX local models

The demo enables the **MLX** package trait and can download models from Hugging Face:

1. Open **Settings** → choose **MLX (local)**
2. Pick a preset (start with **Qwen2.5 0.5B** on iPhone) or paste any `mlx-community/…` id
3. Tap **Download Model** — progress is shown while weights land in the app cache
4. Run an extraction; generation stays fully on-device

Requires Apple Silicon (iPhone / M‑series Mac). First load after download may take a few seconds while weights map into memory.

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
