import Foundation

/// Receipt and invoice evidence in recognized text, in Portuguese (Brazil) and English.
public enum ReceiptText {
    public struct Evidence: Equatable, Sendable {
        public var keywords: [String]
        public var hasAmount: Bool
        public var hasTaxID: Bool

        /// 0...1, combining keyword hits, money amounts and tax IDs (CNPJ/CPF).
        public var score: Double {
            let keywordScore = min(1, Double(keywords.count) * 0.2)
            var miss = 1 - 0.75 * keywordScore
            if hasAmount { miss *= 1 - 0.35 }
            if hasTaxID { miss *= 1 - 0.5 }
            return 1 - miss
        }
    }

    static let keywords: [String] = [
        // Portuguese (Brazil)
        "cnpj", "cpf", "nota fiscal", "nf-e", "nfc-e", "cupom fiscal", "danfe", "valor total", "valor",
        "total", "subtotal", "troco", "desconto", "pagamento", "forma de pagamento", "cartao", "credito",
        "debito", "pix", "recibo", "fatura", "boleto", "vencimento", "icms", "tributos", "qtd", "quantidade",
        "caixa", "operador", "consumidor", "documento auxiliar",
        // English
        "receipt", "invoice", "tax", "vat", "amount", "change", "cash", "visa", "mastercard", "qty",
        "balance due", "order number", "thank you",
    ]

    private static let amountPatterns = [
        #"r\$\s?\d{1,3}([.\s]?\d{3})*,\d{2}"#,     // R$ 1.234,56
        #"\b\d{1,3}(\.\d{3})*,\d{2}\b"#,            // 1.234,56
        #"[$€£]\s?\d+([,.]\d{3})*\.\d{2}\b"#,       // $12.34
    ]
    private static let taxIDPatterns = [
        #"\b\d{2}\.?\d{3}\.?\d{3}/?\d{4}-?\d{2}\b"#,  // CNPJ 12.345.678/0001-90
        #"\b\d{3}\.\d{3}\.\d{3}-\d{2}\b"#,             // CPF 123.456.789-09
    ]

    public static func evidence(in text: String) -> Evidence {
        let folded = normalize(text)
        let hits = keywords.filter { keyword in
            matches(#"(^|[^a-z0-9])"# + NSRegularExpression.escapedPattern(for: keyword) + #"($|[^a-z0-9])"#, in: folded)
        }
        return Evidence(
            keywords: hits,
            hasAmount: amountPatterns.contains { matches($0, in: folded) },
            hasTaxID: taxIDPatterns.contains { matches($0, in: folded) }
        )
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

public enum FilenameHints {
    /// Names given by WhatsApp, Telegram, Signal, Messenger and similar apps when media is saved.
    private static let messagingPatterns = [
        #"^(img|vid|aud|ptt|doc|stk)-\d{8}-wa\d+"#,           // IMG-20240101-WA0001.jpg, PTT-...-WA0003.opus
        #"^whatsapp (image|video|audio|ptt) \d{4}-\d{2}-\d{2}"#, // WhatsApp Image 2024-01-01 at 10.00.00.jpeg
        #"^(photo|video|audio)_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}"#, // Telegram Desktop
        #"^telegram-cloud-(photo|document)"#,
        #"^signal-\d{4}-\d{2}-\d{2}"#,
        #"^received_\d{6,}"#,                                   // Messenger
        #"^fb_img_\d{10,}"#,
        #"^snapchat-\d+"#,
    ]

    private static let screenshotPatterns = [
        #"^screen ?shot"#, #"^screenshot"#, #"^captura de tela"#, #"^captura de pantalla"#,
        #"^simulator screen ?shot"#, #"^bildschirmfoto"#, #"^capture d.ecran"#,
    ]

    private static let screenRecordingPatterns = [
        #"^screen recording"#, #"^grava[cç][aã]o de tela"#, #"^rpreplay"#, #"^bildschirmaufnahme"#,
    ]

    public static func looksLikeMessagingApp(_ filename: String?) -> Bool { matchesAny(messagingPatterns, filename) }
    public static func looksLikeScreenshot(_ filename: String?) -> Bool { matchesAny(screenshotPatterns, filename) }
    public static func looksLikeScreenRecording(_ filename: String?) -> Bool { matchesAny(screenRecordingPatterns, filename) }

    private static func matchesAny(_ patterns: [String], _ filename: String?) -> Bool {
        guard let filename else { return false }
        let name = ReceiptText.normalize(filename)
        return patterns.contains { pattern in
            (try? NSRegularExpression(pattern: pattern))?
                .firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        }
    }
}

public enum ScreenSizes {
    /// Native pixel sizes of iPhone, iPad and common Mac displays (portrait or landscape).
    static let sizes: Set<[Int]> = {
        let list: [(Int, Int)] = [
            (640, 1136), (750, 1334), (1080, 1920), (1242, 2208), (1125, 2436), (828, 1792), (1242, 2688),
            (1080, 2340), (1170, 2532), (1284, 2778), (1179, 2556), (1290, 2796), (1206, 2622), (1320, 2868),
            (1536, 2048), (1668, 2224), (1668, 2388), (2048, 2732), (1620, 2160), (1640, 2360), (1488, 2266),
            (1440, 900), (1680, 1050), (2560, 1600), (2880, 1800), (2560, 1664), (2940, 1912), (3024, 1964),
            (3456, 2234), (2560, 1440), (5120, 2880), (6016, 3384), (4480, 2520),
        ]
        return Set(list.flatMap { [[$0.0, $0.1], [$0.1, $0.0]] })
    }()

    public static func isScreenSize(width: Int?, height: Int?) -> Bool {
        guard let width, let height else { return false }
        return sizes.contains([width, height])
    }

    /// Long edges that WhatsApp, Telegram and other messengers resize photos to.
    static let messagingLongEdges: Set<Int> = [800, 960, 1024, 1280, 1600, 2048, 2560]

    public static func isMessagingSize(width: Int?, height: Int?) -> Bool {
        guard let width, let height else { return false }
        return messagingLongEdges.contains(max(width, height))
    }
}
