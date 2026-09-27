import Foundation
import Testing

@testable import Extract

@Suite("Text layer quality")
struct TextLayerQualityTests {
    @Test("empty text scores zero")
    func emptyIsZero() {
        #expect(TextLayerQuality.score("") == 0)
        #expect(TextLayerQuality.score("   \n") == 0)
    }

    @Test("a clean invoice text layer scores above the default threshold")
    func cleanInvoiceIsHigh() {
        let text = """
            INVOICE
            Vendor: Acme Supplies Co.
            Total due: 1250.00 USD
            Line: Widget Pro
            Quantity 2 Amount 500.00
            """
        let score = TextLayerQuality.score(text)
        #expect(score >= 0.85)
        #expect(
            TextLayerQuality.shouldOCR(text: text, policy: .auto, threshold: 0.85) == false
        )
    }

    @Test("garbled OCR-layer junk scores below the default threshold")
    func garbledIsLow() {
        let text = String(repeating: "~~ @@ ## xx $$ ", count: 40) + "\u{FFFD}\u{FFFD}"
        let score = TextLayerQuality.score(text)
        #expect(score < 0.85)
        #expect(TextLayerQuality.shouldOCR(text: text, policy: .auto, threshold: 0.85))
    }

    @Test("replacement characters cap the score")
    func replacementCapsScore() {
        let text = "INVOICE Vendor Acme Supplies Total 1250.00 \u{FFFD}"
        #expect(TextLayerQuality.score(text) <= 0.3)
    }

    @Test(
        "a control code a text layer should never hold caps the score",
        arguments: [0x01, 0x07, 0x1B, 0x7F, 0x9B] as [UInt32]
    )
    func controlCodeCapsScore(value: UInt32) throws {
        let code = Character(try #require(Unicode.Scalar(value)))
        #expect(TextLayerQuality.score("INVOICE Vendor Acme Supplies Total 1250.00 \(code)") <= 0.3)
    }

    @Test("a Latin page with a soft hyphen keeps its text layer")
    func softHyphenKeepsTextLayer() {
        let text = """
            INVOICE
            Vendor: Acme Supplies Co.
            Total due: 1250.00 USD
            Payment due within 30 days of the in\u{AD}voice date
            """
        #expect(TextLayerQuality.score(text) >= 0.85)
        #expect(TextLayerQuality.shouldOCR(text: text, policy: .auto, threshold: 0.85) == false)
    }

    /// Bidi marks, embeddings, overrides and isolates; the joiners; soft hyphen; byte-order mark;
    /// word joiner.
    @Test(
        "a format character is invisible to the score",
        arguments: [
            0x200E, 0x200F, 0x061C, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069,
            0x200C, 0x200D, 0x00AD, 0xFEFF, 0x2060,
        ] as [UInt32]
    )
    func formatCharacterIsInvisible(value: UInt32) throws {
        let mark = Character(try #require(Unicode.Scalar(value)))
        let clean = "INVOICE\nVendor: Acme Supplies Co.\nTotal due: 1250.00 USD\nWidget Pro 2 500.00"
        let marked = """
            \(mark)INVOICE
            Vendor: Acme Sup\(mark)plies Co.
            Total due: \(mark)1250.00 USD\(mark)
            Widget Pro 2 500.00
            """
        #expect(TextLayerQuality.score(marked) == TextLayerQuality.score(clean))
        #expect(TextLayerQuality.score(marked) >= 0.85)
    }

    @Test("a format character does not hide a control code")
    func formatCharacterBesideControlCodeStillCaps() {
        #expect(TextLayerQuality.score("INVOICE Vendor Acme Supplies Total\u{200F} 1250.00 \u{7}") <= 0.3)
        #expect(TextLayerQuality.score("INVOICE Vendor Acme Sup\u{AD}plies Total 1250.00 \u{FFFD}") <= 0.3)
    }

    @Test("policy always never OCRs; policy never always OCRs")
    func policies() {
        let clean = "INVOICE Vendor Acme Supplies Co. Total 1250.00 USD"
        let empty = ""
        #expect(TextLayerQuality.shouldOCR(text: clean, policy: .always, threshold: 0.85) == false)
        #expect(TextLayerQuality.shouldOCR(text: empty, policy: .always, threshold: 0.85) == false)
        #expect(TextLayerQuality.shouldOCR(text: clean, policy: .never, threshold: 0.85))
        #expect(TextLayerQuality.shouldOCR(text: empty, policy: .never, threshold: 0.85))
    }

    @Test("a Latin word is judged exactly as before")
    func latinVerdictsUnchanged() {
        let words = [
            "INVOICE", "Vendor:", "Co.", "USD", "1250.00", "12", "2026/09/21",
            "Widget-Pro", "ﬁnance", "Straße", "don't",
        ]
        for token in words {
            #expect(TextLayerQuality.isWellFormed(token), "\(token)")
        }
        // No vowel, one letter, or no letters at all.
        for token in ["xx", "~~", "Mkf", "LLC", "kg", "A", "$1,250"] {
            #expect(!TextLayerQuality.isWellFormed(token), "\(token)")
        }
    }

    /// Measured on 2026-09-27, every one of these was malformed: the vowel rule knew a, e, i, o, u
    /// and y, and of their accented forms only the ones German, French and Italian use.
    @Test(
        "a Latin word whose vowel carries a mark, or is a letter of its own, is well formed",
        arguments: [
            "más", "já",  // Spanish and Portuguese á
            "být", "tří",  // Czech ý and í
            "în",  // Romanian î
            "są", "fő",  // Polish ą, Hungarian ő
            "Được",  // Vietnamese: a horn on the u, a horn and a dot on the o
            "ılık",  // Turkish dotless ı
            "rød", "bær",  // Danish and Norwegian ø and æ
            "şəhər",  // Azerbaijani ə
            "lɛlɔ",  // Lingala open e and open o
        ])
    func markedLatinVowelIsWellFormed(token: String) {
        // Precomposed or spelled with combining marks, it is the same word.
        #expect(TextLayerQuality.isWellFormed(token.precomposedStringWithCanonicalMapping))
        #expect(TextLayerQuality.isWellFormed(token.decomposedStringWithCanonicalMapping))
    }

    /// Taking the marks off to find the vowel under them finds none under a consonant.
    @Test(
        "a Latin word without a vowel is malformed, whatever marks its consonants carry",
        arguments: ["xx", "Mkf", "kg", "čšž", "ŁŹĆ", "ďť", "ñç", "ßł", "đŋ", "þð"])
    func markedConsonantsAreMalformed(token: String) {
        #expect(!TextLayerQuality.isWellFormed(token.precomposedStringWithCanonicalMapping))
        #expect(!TextLayerQuality.isWellFormed(token.decomposedStringWithCanonicalMapping))
    }

    /// The rule may count more words than it did, never fewer.
    @Test("every vowel the rule knew before still counts")
    func earlierVowelsStillCount() {
        for vowel in "aeiouAEIOUäöüÄÖÜàèéìòùyY" {
            #expect(TextLayerQuality.isWellFormed("k\(vowel)"), "\(vowel)")
        }
    }

    /// Measured on 2026-09-27, before vowels with marks counted: the Vietnamese page scored 0.71,
    /// and the Azerbaijani one 0.846, just under the threshold.
    @Test(
        "a well-read Latin page in a language that marks its vowels scores above the default threshold",
        arguments: [
            Page(
                script: "Vietnamese",
                text: """
                    HÓA ĐƠN GIÁ TRỊ GIA TĂNG
                    Số: 1493952
                    Ngày 21 tháng 09 năm 2026
                    Đơn vị bán hàng: Công ty TNHH Thương mại Được Phát
                    Tên hàng hóa, dịch vụ Số lượng Đơn giá
                    Cà phê hạt 12 1.250.000
                    Tổng cộng tiền thanh toán: 15.000.000 đồng
                    """),
            Page(
                script: "Azerbaijani",
                text: """
                    HESAB-FAKTURA № 1493952
                    Satıcı: Acme Təchizat MMC
                    Tarix: 21.09.2026
                    Məhsul Miqdar Qiymət
                    Qəhvə dənələri 12 ədəd
                    Cəmi ödəniləcək məbləğ: 1.250,00 manat
                    """),
        ])
    func markedLatinPageIsHigh(page: Page) {
        #expect(TextLayerQuality.score(page.text) >= 0.85)
        #expect(TextLayerQuality.shouldOCR(text: page.text, policy: .auto, threshold: 0.85) == false)
    }

    // MARK: - Scripts other than Latin

    /// A page as its text layer gives it back: one run of text per cell.
    struct Page: Sendable, CustomTestStringConvertible {
        var script: String
        var text: String
        var testDescription: String { script }
    }

    /// Measured on 2026-09-25: a correctly read Arabic invoice page scored 0.57, and the same page
    /// read as English, with every Arabic word gone and only the Latin codes left, scored 0.68. A
    /// word counted only if it had a Latin vowel, so no Arabic, Cyrillic or Chinese word ever did,
    /// and under `.auto` a good text layer in any of them was thrown away for OCR.
    @Test(
        "a well-read page in a script other than Latin scores above the default threshold",
        arguments: [
            Page(
                script: "Arabic",
                text: """
                    فاتورة ضريبية
                    المورد: شركة الأمل للتجارة
                    رقم الفاتورة: 1493952
                    التاريخ: 2026/09/21
                    الكمية 12 الوزن 1,285
                    الإجمالي المستحق: 1,250.00 ريال
                    شُكْرًا لِتَعامُلِكُم مَعَنا
                    """),
            Page(
                script: "Arabic and English",
                text: """
                    TAX INVOICE فاتورة ضريبية
                    Invoice No. 1493952 رقم الفاتورة
                    Supplier: Al Amal Trading LLC المورد: شركة الأمل للتجارة
                    Total 1,250.00 SAR الإجمالي
                    """),
            Page(
                script: "Hebrew",
                text: """
                    חשבונית מס 1493952
                    ספק: אקמה אספקה בע״מ
                    תאריך: 21/09/2026
                    כמות 12 משקל 1,285
                    סה״כ לתשלום: 1,250.00 ש״ח
                    """),
            Page(
                script: "Cyrillic",
                text: """
                    СЧЁТ-ФАКТУРА № 1493952
                    Поставщик: ООО «Ромашка»
                    Дата: 21.09.2026
                    Количество 12 Вес 1,285
                    Итого к оплате: 1 250,00 руб.
                    """),
            Page(
                script: "Greek",
                text: """
                    ΤΙΜΟΛΟΓΙΟ ΠΑΡΟΧΗΣ ΥΠΗΡΕΣΙΩΝ
                    Προμηθευτής: Ακμή Προμήθειες Α.Ε.
                    Ημερομηνία: 21/09/2026
                    Ποσότητα 12 Βάρος 1,285
                    Σύνολο: 1.250,00 ευρώ
                    """),
            Page(
                script: "Chinese",
                text: """
                    增值税专用发票
                    发票号码 1493952
                    开票日期 2026年09月21日
                    购买方 上海晨光贸易有限公司
                    数量 12 重量 1,285
                    价税合计 1,250.00
                    """),
            Page(
                script: "Japanese",
                text: """
                    請求書
                    株式会社サンプル 御中
                    お支払い期限 2026年10月31日
                    品名 コーヒー豆 数量 12
                    ご請求金額 ¥1,250
                    """),
            Page(
                script: "Korean",
                text: """
                    세금계산서
                    공급자 주식회사 한빛상사
                    작성일자 2026-09-21
                    수량 12 중량 1,285
                    합계금액 1,250,000원
                    """),
            Page(
                script: "Thai",
                text: """
                    ใบกำกับภาษี เลขที่ 1493952
                    ผู้ขาย บริษัท แอคมี จำกัด
                    วันที่ 21/09/2026
                    จำนวน 12 น้ำหนัก 1,285
                    รวมทั้งสิ้น 1,250.00 บาท
                    """),
            Page(
                script: "Devanagari",
                text: """
                    कर बीजक संख्या 1493952
                    विक्रेता: एक्मे सप्लाइज़ प्राइवेट लिमिटेड
                    दिनांक: 21/09/2026
                    मात्रा 12 वज़न 1,285
                    कुल राशि: 1,250.00 रुपये
                    """),
        ])
    func nonLatinPageIsHigh(page: Page) {
        #expect(TextLayerQuality.score(page.text) >= 0.85)
        #expect(TextLayerQuality.shouldOCR(text: page.text, policy: .auto, threshold: 0.85) == false)
    }

    @Test("a Persian page with zero-width non-joiners and Persian figures keeps its text layer")
    func persianPageKeepsTextLayer() {
        let text = """
            صورت\u{200C}حساب فروش کالا و خدمات
            شماره: ۱۴۰۵۰۷۱۲
            تاریخ: ۱۴۰۵/۰۷/۰۵
            فروشنده: شرکت بازرگانی آلفا
            خریدار: فروشگاه نور
            شرح کالا تعداد مبلغ
            خودکار آبی ۲ ۵۰۰٬۰۰۰
            جمع کل: ۱٬۲۵۰٬۰۰۰ ریال
            مبلغ ظرف ۳۰ روز پرداخت می\u{200C}شود
            """
        #expect(TextLayerQuality.score(text) >= 0.85)
        #expect(TextLayerQuality.shouldOCR(text: text, policy: .auto, threshold: 0.85) == false)
    }

    @Test("an Arabic page with a right-to-left mark and Arabic-Indic figures keeps its text layer")
    func arabicPageKeepsTextLayer() {
        let text = """
            \u{200F}فاتورة ضريبية
            رقم الفاتورة: ٢٠٢٦٠٩٢٧
            التاريخ: ٢٠٢٦/٠٩/٢٧
            المورد: شركة الأمل للتجارة
            الوصف الكمية المبلغ
            أقلام حبر ٢ ٥٠٠٫٠٠
            الإجمالي: ١٬٢٥٠٫٠٠ ريال
            """
        #expect(TextLayerQuality.score(text) >= 0.85)
        #expect(TextLayerQuality.shouldOCR(text: text, policy: .auto, threshold: 0.85) == false)
    }

    /// Mostly figures, as a table of line items is: with Persian figures counted as junk, this page
    /// scored 0.696 and was OCR'd.
    @Test("a Persian table of line items keeps its text layer")
    func persianLineItemsKeepTextLayer() {
        let text = """
            ردیف شرح تعداد فی مبلغ
            ۱ خودکار ۲ ۲۵۰٬۰۰۰ ۵۰۰٬۰۰۰
            ۲ دفتر ۵ ۱۲۰٬۰۰۰ ۶۰۰٬۰۰۰
            ۳ مداد ۱۰ ۱۵٬۰۰۰ ۱۵۰٬۰۰۰
            جمع ۱٬۲۵۰٬۰۰۰
            مالیات ۱۱۲٬۵۰۰
            قابل پرداخت ۱٬۳۶۲٬۵۰۰
            """
        #expect(TextLayerQuality.score(text) >= 0.85)
        #expect(TextLayerQuality.shouldOCR(text: text, policy: .auto, threshold: 0.85) == false)
    }

    @Test(
        "a figure in any script's digits is a number, Arabic separators and all",
        arguments: ["۱٬۲۵۰٬۰۰۰", "٥٠٠٫٠٠", "۱۴۰۵/۰۷/۰۵", "١,٢٥٠.٠٠", "१,२५०.००"]
    )
    func nonASCIIFigureIsWellFormed(token: String) {
        #expect(TextLayerQuality.isWellFormed(token))
    }

    /// The inversion as measured, on the line from the 0.8.4 note: read as English,
    /// `الكمية 12 الوزن 1,285` came back as `1,285 ja|| 12 tall`, and the misreading used to
    /// score higher.
    @Test("a line read in its own script scores above the same line misread as English")
    func ownScriptBeatsMisreading() {
        let read = TextLayerQuality.score("الكمية 12 الوزن 1,285")
        let misread = TextLayerQuality.score("1,285 ja|| 12 tall")
        #expect(read > misread)
    }

    @Test(
        "a word in one script other than Latin is well formed, marks and all",
        arguments: [
            "شُكْرًا",  // Arabic, vowelled
            "\u{FED3}\u{FE8E}\u{FE97}\u{FEEE}\u{FEAD}\u{FE93}",  // فاتورة in presentation forms
            "שלום", "Ημερομηνία", "Количество",
            "молоко\u{0301}",  // a stress mark
            "м\u{02BC}ясо",  // Ukrainian apostrophe, a modifier letter
            "请求书", "コーヒー", "お支払い",  // kanji and kana together are one word in Japanese
            "大韓민국",  // so are hanja and hangul in Korean
            "สวัสดี", "नमस्ते", "Բարև",
        ])
    func nonLatinWordIsWellFormed(token: String) {
        #expect(TextLayerQuality.isWellFormed(token))
    }

    @Test("a single letter is no more a word in another script than in Latin")
    func singleLetterIsNotAWord() {
        #expect(!TextLayerQuality.isWellFormed("ك"))
        #expect(!TextLayerQuality.isWellFormed("Ж"))
    }

    /// A text layer whose font maps some glyphs to the wrong script gives words like these: a
    /// Latin letter inside an Arabic word, a Cyrillic letter drawn like a Latin one.
    @Test(
        "a word that mixes scripts is malformed",
        arguments: [
            "فاتTورة", "\u{0410}cme", "Счёtт", "ΤΙΜΟLΟΓΙΟ", "发Ж票", "مرحباשלום", "Привет世界", "カ한",
        ])
    func mixedScriptIsMalformed(token: String) {
        #expect(!TextLayerQuality.isWellFormed(token))
    }

    @Test("a page of mixed-script junk scores below the default threshold")
    func mixedScriptPageIsLow() {
        let text = String(repeating: "فاتTورة \u{0410}cme Счёtт ΤΙΜΟLΟΓΙΟ 发Ж票 Привет世界\n", count: 10)
        #expect(TextLayerQuality.score(text) < 0.85)
        #expect(TextLayerQuality.shouldOCR(text: text, policy: .auto, threshold: 0.85))
    }

    @Test("punctuation on its own scores zero in any script")
    func isolatedPunctuationIsZero() {
        let text = String(repeating: "، ؛ ؟ « » 。 、 ・ ： ! ? · ; ", count: 20)
        #expect(TextLayerQuality.score(text) == 0)
    }

    @Test("replacement characters cap a page in any script")
    func replacementCapsNonLatin() {
        #expect(TextLayerQuality.score("فاتورة ضريبية رقم الفاتورة 1493952 \u{FFFD}") <= 0.3)
        #expect(TextLayerQuality.score("Поставщик ООО Ромашка Итого 1250,00 \u{FFFD}") <= 0.3)
        #expect(TextLayerQuality.score("增值税专用发票 发票号码 1493952 \u{FFFD}") <= 0.3)
    }

    // MARK: - Chinese, Japanese and Korean, written without spaces

    /// Chinese and Japanese put no spaces between words, so a text layer gives a line of theirs
    /// back as one run, broken only between the page's cells: `开票日期：2026年09月21日` is one
    /// token, and one colon or figure in it failed the whole line. Measured on 2026-09-27 with
    /// 0.15.0's scorer, these pages scored 0.78, 0.85, 0.81, 0.69 and 0.80.
    @Test(
        "a CJK page as its text layer runs it together scores above the default threshold",
        arguments: [
            Page(
                script: "Chinese",
                text: """
                    增值税专用发票
                    发票代码：3100212130 发票号码：14939520
                    开票日期：2026年09月21日
                    购买方名称：上海晨光贸易有限公司
                    纳税人识别号：91310000MA1FL0XK2P
                    地址、电话：上海市浦东新区世纪大道100号 021-12345678
                    货物或应税劳务、服务名称 规格型号 单位 数量 单价 金额
                    *咖啡*咖啡豆 1kg 袋 12 104.17 1250.00
                    价税合计（大写）壹仟肆佰壹拾贰元伍角整 （小写）¥1412.50
                    销售方名称：北京咖啡进出口有限公司
                    收款人：王芳 复核：李强 开票人：张伟
                    """),
            Page(
                script: "Traditional Chinese",
                text: """
                    統一發票（三聯式）
                    發票號碼：AB-12345678
                    中華民國115年9月21日
                    買受人：晨光貿易股份有限公司
                    統一編號：12345678
                    品名 數量 單價 金額
                    咖啡豆（一公斤） 12 1,250 15,000
                    銷售額合計 15,000
                    營業稅 750
                    總計 15,750
                    總計新臺幣（中文大寫）壹萬伍仟柒佰伍拾元整
                    """),
            Page(
                script: "Japanese",
                text: """
                    請求書
                    株式会社サンプル御中
                    請求日：2026年9月27日 請求番号：INV-2026-0042
                    下記の通りご請求申し上げます。
                    品名 数量 単価 金額
                    コーヒー豆（200g） 12 1,250 15,000
                    配送料 1 500 500
                    小計 15,500
                    消費税（10%） 1,550
                    合計金額 ¥17,050
                    お支払い期限：2026年10月31日
                    振込先：三菱UFJ銀行 渋谷支店 普通 1234567
                    株式会社アクメ 〒150-0002 東京都渋谷区渋谷2丁目1番1号
                    """),
            Page(
                script: "Japanese, in full-width figures",
                text: """
                    請求書
                    株式会社サンプル　御中
                    請求日：２０２６年９月２７日
                    請求番号：ＩＮＶ－２０２６－００４２
                    品名　数量　単価　金額
                    コーヒー豆（２００ｇ）　１２　１，２５０　１５，０００
                    小計　１５，５００
                    消費税（１０％）　１，５５０
                    合計金額　￥１７，０５０
                    お支払い期限：２０２６年１０月３１日
                    """),
            Page(
                script: "Korean",
                text: """
                    세금계산서
                    등록번호: 123-45-67890
                    상호: 주식회사 한빛상사 대표자: 김민준
                    작성일자: 2026년 9월 21일
                    품목 수량 단가 공급가액 세액
                    원두커피(1kg) 12 104,170 1,250,000 125,000
                    합계금액: 1,375,000원
                    위 금액을 영수(청구)함
                    """),
        ])
    func unspacedCJKPageIsHigh(page: Page) {
        #expect(TextLayerQuality.score(page.text) >= 0.85)
        #expect(TextLayerQuality.shouldOCR(text: page.text, policy: .auto, threshold: 0.85) == false)
    }

    /// A paragraph of Chinese is a handful of tokens, each a sentence or more; measured on
    /// 2026-09-27 with 0.15.0's scorer, this one scored 0.63.
    @Test("Chinese prose scores above the default threshold")
    func chineseProseIsHigh() {
        let text = """
            根据双方签订的采购合同，买方应于收到发票后三十日内支付全部货款。如逾期付款，卖方有权按照
            每日万分之五的标准收取违约金。货物运抵买方指定仓库后，买方应在三个工作日内完成验收；如有
            质量问题，应以书面形式通知卖方。
            """
        #expect(TextLayerQuality.score(text) >= 0.85)
    }

    /// A heading spaced out a character at a time, and a text layer that set every glyph apart.
    /// Measured on 2026-09-27 with 0.15.0's scorer, they scored 0.66 and 0.51.
    @Test(
        "a CJK page with a space between its characters scores above the default threshold",
        arguments: [
            Page(
                script: "letter-spaced heading",
                text: """
                    御　見　積　書
                    株式会社サンプル　御中
                    件名：オフィス用品一式
                    見積金額　￥１５，０００
                    有効期限：発行日より３０日
                    """),
            Page(
                script: "every glyph apart",
                text: """
                    增 值 税 专 用 发 票
                    发 票 号 码 ： 14939520
                    开 票 日 期 ： 2026 年 09 月 21 日
                    购 买 方 名 称 ： 上 海 晨 光 贸 易 有 限 公 司
                    价 税 合 计 ¥1412.50
                    """),
        ])
    func spacedCJKPageIsHigh(page: Page) {
        #expect(TextLayerQuality.score(page.text) >= 0.85)
    }

    /// Broken where a script with spaces would have put them, each piece judged as a token of its
    /// own would be. A code, a unit or an amount after a currency sign fails as it does standing
    /// alone in a Latin page, and takes only its own share with it.
    @Test(
        "a run of CJK text counts for the share of it that is words",
        arguments: [
            ("开票日期：2026年09月21日", 1.0),
            ("地址、电话：上海市浦东新区世纪大道100号", 1.0),
            ("振込先：三菱UFJ銀行", 1.0),  // a Latin name set against kanji, as CJK text writes one
            ("发票No", 1.0),
            ("영수(청구)함", 1.0),
            ("1,375,000원", 1.0),
            ("請求番号：INV-2026-0042", 0.5),
            ("원두커피(1kg)", 0.5),
            ("（小写）¥1412.50", 0.5),
            ("合計金額￥１７，０５０", 0.5),  // a currency sign is where an amount starts
            ("합계금액₩1,250", 0.5),
        ])
    func cjkRunCountsItsWords(token: String, share: Double) {
        #expect(TextLayerQuality.wellFormedShare(token) == share)
    }

    /// A Chinese character is a word or the root of one, and a hangul block a whole syllable, not a
    /// letter of an alphabet.
    @Test("one CJK character is a word", arguments: ["袋", "年", "위", "및", "請"])
    func oneCJKCharacterIsAWord(token: String) {
        #expect(TextLayerQuality.wellFormedShare(token) == 1)
    }

    /// Real CJK text sets only punctuation, figures and Latin letters against its own. A broken font
    /// map sends glyphs anywhere, and a Cyrillic, Greek or Latin Extended letter inside a run of
    /// Han is its mark: such a run is not broken there, and no piece of it counts.
    @Test(
        "a letter of another script set against CJK letters keeps them junk",
        arguments: ["发Ж票", "请求ΣΔ书", "丁ƂЖ万", "Привет世界", "ÇĐ丁ÂƂ", "カ한"])
    func cjkAgainstAnotherScriptIsJunk(token: String) {
        #expect(TextLayerQuality.wellFormedShare(token) == 0)
    }

    @Test("a page of CJK set against other scripts' letters scores below the default threshold")
    func cjkAgainstAnotherScriptPageIsLow() {
        let text = String(repeating: "发Ж票 请求ΣΔ书 丁ƂЖ万 カ한 Привет世界 ÇĐ丁ÂƂ\n", count: 10)
        #expect(TextLayerQuality.score(text) < 0.85)
        #expect(TextLayerQuality.shouldOCR(text: text, policy: .auto, threshold: 0.85))
    }

    @Test(
        "a figure in full-width digits is a number, full-width separators and all",
        arguments: ["１，２５０", "１５，０００．００", "２０２６／０９／２７", "１２．５％"])
    func fullWidthFigureIsWellFormed(token: String) {
        #expect(TextLayerQuality.isWellFormed(token))
    }

    /// Nothing in a token without a CJK letter is broken up or judged any differently.
    @Test(
        "a token without a CJK letter counts all or nothing, as it did",
        arguments: ["INVOICE", "Vendor:", "1250.00", "Количество", "xx", "INV-2026-0042", "$1,250", "〒150-0002"])
    func tokenWithoutCJKIsAllOrNothing(token: String) {
        #expect(TextLayerQuality.wellFormedShare(token) == (TextLayerQuality.isWellFormed(token) ? 1 : 0))
    }
}
