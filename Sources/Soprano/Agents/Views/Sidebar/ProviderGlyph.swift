import AppKit
import SopranoAgentsCore

/// Provider marks as T3 Code draws them (`components/Icons.tsx`: `OpenAI`, `ClaudeAI`), rendered
/// from the original SVG path data, plus omp's "π". Codex and omp are template images (tint with
/// `contentTintColor`); Claude keeps its brand orange (`Palette.claudeBrand`).
@MainActor
enum ProviderGlyph {
    /// The mark at `size` points.
    static func image(for kind: ProviderKind, size: CGFloat = 14) -> NSImage {
        let key = "\(kind.rawValue)-\(size)-\(PaletteCenter.shared.palette.isDark)"
        if let cached = cache[key] { return cached }
        let image: NSImage
        switch kind {
        case .omp:
            image = renderPi(size: size)
            image.isTemplate = true
        case .codex:
            image = render(openAIPath, viewBox: CGRect(x: 100, y: 100, width: 411, height: 411), evenOdd: true, size: size, color: .black)
            image.isTemplate = true
        case .claude:
            image = render(claudePath, viewBox: CGRect(x: 0, y: 0, width: 256, height: 257), evenOdd: false, size: size, color: PaletteCenter.shared.palette.claudeBrand)
        }
        image.accessibilityDescription = kind.displayName
        cache[key] = image
        return image
    }

    private static var cache: [String: NSImage] = [:]

    /// omp (oh-my-pi) has no vector mark: a bold "π" set in the system font, template-rendered.
    private static func renderPi(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let font = NSFont.systemFont(ofSize: size * 1.05, weight: .heavy)
            let text = NSAttributedString(string: "π", attributes: [.font: font, .foregroundColor: NSColor.black])
            let bounds = text.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin, .usesFontLeading])
            text.draw(at: NSPoint(x: (rect.width - bounds.width) / 2, y: (rect.height - bounds.height) / 2 - size * 0.06))
            return true
        }
    }

    private static func render(_ pathData: String, viewBox: CGRect, evenOdd: Bool, size: CGFloat, color: NSColor) -> NSImage {
        let path = SVGPath.parse(pathData)
        path.windingRule = evenOdd ? .evenOdd : .nonZero
        return NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
            let transform = NSAffineTransform()
            transform.translateX(by: (rect.width - viewBox.width * scale) / 2, yBy: (rect.height - viewBox.height * scale) / 2)
            transform.scale(by: scale)
            transform.translateX(by: -viewBox.minX, yBy: -viewBox.minY)
            guard let scaled = path.copy() as? NSBezierPath else { return false }
            scaled.transform(using: transform as AffineTransform)
            color.setFill()
            scaled.fill()
            return true
        }
    }

    // OpenAI mark, viewBox 100 100 411 411, even-odd.
    private static let openAIPath = """
        M252.794 108.802C289.191 99.0484 326.265 110.305 351.148 135.135C385.113 126.072 422.85 134.862 449.492 161.50\
        5C476.136 188.149 484.925 225.888 475.862 259.85V259.854C500.696 284.735 511.95 321.81 502.198 358.207C492.447\
         394.602 464.161 421.084 430.215 430.217C421.083 464.162 394.603 492.448 358.206 502.199C321.812 511.951 284.7\
        34 500.693 259.852 475.864C225.887 484.927 188.15 476.137 161.507 449.495C134.864 422.851 126.073 385.111 135.\
        136 351.149C110.304 326.266 99.0496 289.192 108.801 252.795C118.552 216.4 146.84 189.918 180.784 180.785C189.9\
        17 146.841 216.396 118.553 252.794 108.802ZM374.292 407.145C374.292 411.271 372.092 415.086 368.517 417.148L28\
        3.723 466.102C302.487 480.585 327.555 486.459 352.217 479.852C386.997 470.532 410.068 439.312 410.555 405.006V\
        317.717C410.555 315.08 409.125 312.621 406.843 311.303L374.292 292.509V407.145ZM251.868 415.897C248.296 417.95\
        9 243.893 417.959 240.317 415.897L155.526 366.942C152.366 390.436 159.811 415.08 177.866 433.136H177.863C203.3\
        25 458.594 241.896 462.962 271.85 446.232L347.449 402.586C349.735 401.268 351.148 398.8 351.148 396.163V358.57\
        9L251.868 415.897ZM368.602 220.628C366.319 219.309 363.474 219.318 361.191 220.637L328.641 239.431L427.921 296\
        .749C431.496 298.811 433.697 302.627 433.697 306.752V404.661C455.622 395.654 473.244 376.881 479.851 352.218C4\
        89.169 317.442 473.668 281.85 444.201 264.274L368.602 220.628ZM177.303 206.34C155.377 215.348 137.756 234.122 \
        131.148 258.783C121.832 293.561 137.331 329.153 166.799 346.727L242.398 390.373C244.68 391.692 247.525 391.684\
         249.807 390.366L282.357 371.572L183.078 314.253C179.504 312.189 177.303 308.375 177.303 304.251V206.34ZM259.8\
        49 279.145V331.858L305.5 358.213L351.15 331.858V279.145L305.5 252.789L259.849 279.145ZM327.276 144.9C308.512 1\
        30.418 283.445 124.543 258.782 131.15C224.002 140.471 200.931 171.691 200.445 205.995V293.286C200.445 295.923 \
        201.875 298.381 204.158 299.7L236.707 318.493V203.856C236.707 199.731 238.909 195.916 242.483 193.853L327.276 \
        144.9ZM433.137 177.867C407.675 152.407 369.103 148.038 339.149 164.769L263.55 208.415C261.265 209.734 259.852 \
        212.202 259.852 214.838V252.423L359.132 195.105C362.703 193.041 367.108 193.041 370.682 195.105L455.473 244.06\
        C458.635 220.567 451.189 195.922 433.135 177.867H433.137Z
        """

    // Claude mark, viewBox 0 0 256 257.
    private static let claudePath = """
        m50.228 170.321 50.357-28.257.843-2.463-.843-1.361h-2.462l-8.426-.518-28.775-.778-24.952-1.037-24.175-1.296-6.\
        092-1.297L0 125.796l.583-3.759 5.12-3.434 7.324.648 16.202 1.101 24.304 1.685 17.629 1.037 26.118 2.722h4.148l\
        .583-1.685-1.426-1.037-1.101-1.037-25.147-17.045-27.22-18.017-14.258-10.37-7.713-5.25-3.888-4.925-1.685-10.758\
         7-7.713 9.397.649 2.398.648 9.527 7.323 20.35 15.75L94.817 91.9l3.889 3.24 1.555-1.102.195-.777-1.75-2.917-14\
        .453-26.118-15.425-26.572-6.87-11.018-1.814-6.61c-.648-2.723-1.102-4.991-1.102-7.778l7.972-10.823L71.42 0 82.0\
        5 1.426l4.472 3.888 6.61 15.101 10.694 23.786 16.591 32.34 4.861 9.592 2.592 8.879.973 2.722h1.685v-1.556l1.36\
        -18.211 2.528-22.36 2.463-28.776.843-8.1 4.018-9.722 7.971-5.25 6.222 2.981 5.12 7.324-.713 4.73-3.046 19.768-\
        5.962 30.98-3.889 20.739h2.268l2.593-2.593 10.499-13.934 17.628-22.036 7.778-8.749 9.073-9.657 5.833-4.601h11.\
        018l8.1 12.055-3.628 12.443-11.342 14.388-9.398 12.184-13.48 18.147-8.426 14.518.778 1.166 2.01-.194 30.46-6.4\
        81 16.462-2.982 19.637-3.37 8.88 4.148.971 4.213-3.5 8.62-20.998 5.184-24.628 4.926-36.682 8.685-.454.324.519.\
        648 16.526 1.555 7.065.389h17.304l32.21 2.398 8.426 5.574 5.055 6.805-.843 5.184-12.962 6.611-17.498-4.148-40.\
        83-9.721-14-3.5h-1.944v1.167l11.666 11.406 21.387 19.314 26.767 24.887 1.36 6.157-3.434 4.86-3.63-.518-23.526-\
        17.693-9.073-7.972-20.545-17.304h-1.36v1.814l4.73 6.935 25.017 37.59 1.296 11.536-1.814 3.76-6.481 2.268-7.13-\
        1.297-14.647-20.544-15.1-23.138-12.185-20.739-1.49.843-7.194 77.448-3.37 3.953-7.778 2.981-6.48-4.925-3.436-7.\
        972 3.435-15.749 4.148-20.544 3.37-16.333 3.046-20.285 1.815-6.74-.13-.454-1.49.194-15.295 20.999-23.267 31.43\
        3-18.406 19.702-4.407 1.75-7.648-3.954.713-7.064 4.277-6.286 25.47-32.405 15.36-20.092 9.917-11.6-.065-1.686h-\
        .583L44.07 198.125l-12.055 1.555-5.185-4.86.648-7.972 2.463-2.593 20.35-13.999-.064.065Z
        """
}

/// Minimal SVG path-data parser: M L H V C Z (absolute and relative) with implicit repeats.
enum SVGPath {
    static func parse(_ data: String) -> NSBezierPath {
        let path = NSBezierPath()
        var scanner = Tokens(Array(data.utf8))
        var current = NSPoint.zero
        var start = NSPoint.zero
        var command: UInt8 = 0
        while let next = scanner.nextCommandOrNumber() {
            if case let .command(letter) = next {
                command = letter
                if letter == UInt8(ascii: "Z") || letter == UInt8(ascii: "z") {
                    path.close()
                    current = start
                    continue
                }
            } else {
                scanner.rewindNumber()
            }
            let relative = command >= UInt8(ascii: "a")
            func point() -> NSPoint? {
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                return relative ? NSPoint(x: current.x + x, y: current.y + y) : NSPoint(x: x, y: y)
            }
            switch command | 0x20 {
            case UInt8(ascii: "m"):
                guard let target = point() else { return path }
                path.move(to: target)
                current = target
                start = target
                // Further pairs after a moveto are implicit linetos.
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
            case UInt8(ascii: "l"):
                guard let target = point() else { return path }
                path.line(to: target)
                current = target
            case UInt8(ascii: "h"):
                guard let x = scanner.number() else { return path }
                current = NSPoint(x: relative ? current.x + x : x, y: current.y)
                path.line(to: current)
            case UInt8(ascii: "v"):
                guard let y = scanner.number() else { return path }
                current = NSPoint(x: current.x, y: relative ? current.y + y : y)
                path.line(to: current)
            case UInt8(ascii: "c"):
                guard let control1 = point(), let control2 = point(), let target = point() else { return path }
                path.curve(to: target, controlPoint1: control1, controlPoint2: control2)
                current = target
            default:
                return path
            }
        }
        return path
    }

    private enum Token {
        case command(UInt8)
        case number
    }

    private struct Tokens {
        let bytes: [UInt8]
        var index = 0
        private var numberStart = 0

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
        }

        private mutating func skipSeparators() {
            while index < bytes.count, bytes[index] == UInt8(ascii: " ") || bytes[index] == UInt8(ascii: ",") || bytes[index] == UInt8(ascii: "\n") {
                index += 1
            }
        }

        mutating func nextCommandOrNumber() -> Token? {
            skipSeparators()
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            if (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")) || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")), byte != UInt8(ascii: "e") {
                index += 1
                return .command(byte)
            }
            numberStart = index
            return .number
        }

        mutating func rewindNumber() {
            index = numberStart
        }

        /// Next number; handles "1.5-2", ".5.5" and exponents.
        mutating func number() -> CGFloat? {
            skipSeparators()
            let begin = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") { index += 1 }
            var sawDot = false
            while index < bytes.count {
                let byte = bytes[index]
                if byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
                    index += 1
                } else if byte == UInt8(ascii: "."), !sawDot {
                    sawDot = true
                    index += 1
                } else if byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") {
                    index += 1
                    if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") { index += 1 }
                } else {
                    break
                }
            }
            guard index > begin, let text = String(bytes: bytes[begin..<index], encoding: .ascii), let value = Double(text) else { return nil }
            return CGFloat(value)
        }
    }
}
