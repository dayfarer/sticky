// Live math in notes: x^2, x_1, sqrt(x), cbrt(x), 1/2, pi, <=, >=, … look like math as you type.
// Display only: the note keeps exactly what you typed. Markers are hidden and symbols swapped at the
// glyph level (TextKit 1), and √ is drawn over the text. Whatever touches the cursor shows as typed,
// so you can see what you're editing.
import AppKit

extension NSAttributedString.Key {
    /// Not drawn and takes no space.
    static let mathHidden = NSAttributedString.Key("StickyMathHidden")
    /// Draw this character's glyph instead of the typed one.
    static let mathGlyph = NSAttributedString.Key("StickyMathGlyph")
    /// On the character that holds a √ (a RadicalMark).
    static let mathRadical = NSAttributedString.Key("StickyMathRadical")
    /// Inside formatted math: don't wrap the line here.
    static let mathKeep = NSAttributedString.Key("StickyMathKeep")
}

final class RadicalMark: NSObject {
    let radicand: NSRange
    let index: String?  // "3" for a cube root
    let color: NSColor
    init(radicand: NSRange, index: String?, color: NSColor) {
        self.radicand = radicand
        self.index = index
        self.color = color
    }
}

enum MathStyle {
    /// Menu bar → Math Formatting (saved in notes-state.json).
    static var enabled = true

    private struct Node {
        enum Kind {
            case sup, sub, root(cube: Bool), symbol(String), fraction
            var isSup: Bool { if case .sup = self { return true } else { return false } }
        }
        var kind: Kind
        var range: NSRange           // the whole thing as typed
        var hide: [NSRange] = []     // markers that vanish when formatted
        var body = NSRange()         // raised / lowered part, radicand, or numerator
        var den = NSRange()          // fraction denominator
        var slot = -1                // root: the "(" that shows the √; fraction: the slash
        var children: [Node] = []
    }

    private static let operators: [(String, String)] = [("<=", "≤"), (">=", "≥"), ("!=", "≠"), ("+-", "±"), ("~=", "≈")]
    private static let words: [(String, String)] = [("theta", "θ"), ("pi", "π"), ("inf", "∞")]

    /// Formats the math in the note (except in `skip`). Returns every math range, and the ones shown
    /// as typed because they touch `caret`.
    @discardableResult
    static func style(_ ts: NSTextStorage, skip: [NSRange], caret: Int?) -> (all: [NSRange], revealed: [NSRange]) {
        var all: [NSRange] = [], revealed: [NSRange] = []
        guard enabled else { return (all, revealed) }
        let s = ts.string as NSString
        var i = 0
        while i < s.length {
            let line = s.lineRange(for: NSRange(location: i, length: 0))
            i = NSMaxRange(line)
            var content = line
            while content.length > 0, isNewline(s.character(at: NSMaxRange(content) - 1)) { content.length -= 1 }
            // Cheap check first: most lines have no math.
            guard content.length > 1, mayHaveMath(s, content) else { continue }
            let nodes = parse(s, content, depth: 0, minus: false).filter { n in
                !skip.contains { NSIntersectionRange($0, n.range).length > 0 }
            }
            apply(ts, nodes, caret: caret, all: &all, revealed: &revealed)
        }
        return (all, revealed)
    }

    // MARK: Parsing

    private static func isLetter(_ c: unichar) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
    private static func isDigit(_ c: unichar) -> Bool { c >= 48 && c <= 57 }
    private static func isWordish(_ c: unichar) -> Bool { isLetter(c) || isDigit(c) || c == 95 }  // _
    private static func isNewline(_ c: unichar) -> Bool { c == 10 || c == 13 || c == 0x2028 }
    /// What a ^ or _ can follow: x^2, (a+b)^2, |x|^2, f'^2, π^2.
    private static func isBase(_ c: unichar) -> Bool {
        isLetter(c) || isDigit(c) || ")]}|'".utf16.contains(c)
            || (c > 127 && CharacterSet.letters.contains(Unicode.Scalar(c) ?? " "))
    }

    private static func mayHaveMath(_ s: NSString, _ r: NSRange) -> Bool {
        let t = s.substring(with: r)
        return t.contains(where: { "^_/<>=!~+*".contains($0) }) || t.contains("sqrt") || t.contains("cbrt")
            || t.contains("pi") || t.contains("theta") || t.contains("inf") || t.contains("deg")
    }

    private static func ch(_ s: NSString, _ i: Int, _ lo: Int, _ end: Int) -> unichar? {
        i >= lo && i < end ? s.character(at: i) : nil
    }

    /// The bracket that closes the one at `open` ( "(" or "{" ), on this line.
    private static func matching(_ s: NSString, _ open: Int, _ end: Int) -> Int? {
        let o = s.character(at: open)
        guard o == 40 || o == 123 else { return nil }
        let c: unichar = o == 40 ? 41 : 125
        var depth = 0
        for j in open..<end {
            let x = s.character(at: j)
            if x == o { depth += 1 } else if x == c { depth -= 1; if depth == 0 { return j } }
        }
        return nil
    }

    private static func parse(_ s: NSString, _ r: NSRange, depth: Int, minus: Bool) -> [Node] {
        guard depth < 5 else { return [] }
        var out: [Node] = []
        let lo = r.location, end = NSMaxRange(r)
        var i = lo
        while i < end {
            if let n = root(s, i, lo, end, depth) ?? script(s, i, lo, end, depth)
                ?? fraction(s, i, lo, end) ?? symbol(s, i, lo, end, depth, minus) {
                out.append(n)
                i = NSMaxRange(n.range)
            } else {
                i += 1
            }
        }
        return out
    }

    /// sqrt(…) or cbrt(…), also with { }.
    private static func root(_ s: NSString, _ i: Int, _ lo: Int, _ end: Int, _ depth: Int) -> Node? {
        guard i + 6 <= end else { return nil }
        let name = s.substring(with: NSRange(location: i, length: 4))
        guard name == "sqrt" || name == "cbrt" else { return nil }
        if let p = ch(s, i - 1, lo, end), isLetter(p) { return nil }
        let open = i + 4
        guard let close = matching(s, open, end), close > open + 1 else { return nil }
        var n = Node(kind: .root(cube: name == "cbrt"), range: NSRange(location: i, length: close + 1 - i))
        n.hide = [NSRange(location: i, length: 4), NSRange(location: close, length: 1)]
        n.slot = open
        n.body = NSRange(location: open + 1, length: close - open - 1)
        n.children = parse(s, n.body, depth: depth + 1, minus: true)
        return n
    }

    /// x^2, x^-1, x^(n+1), e^{-x}, e^sqrt(x), x_1, x_n, x_(i+1).
    private static func script(_ s: NSString, _ i: Int, _ lo: Int, _ end: Int, _ depth: Int) -> Node? {
        let c = s.character(at: i)
        guard c == 94 || c == 95, let p = ch(s, i - 1, lo, end), isBase(p), let a0 = ch(s, i + 1, lo, end) else { return nil }
        let sup = c == 94
        let a = i + 1
        var n = Node(kind: sup ? .sup : .sub, range: NSRange())
        func done(_ last: Int) -> Node {  // `last` is one past the end
            n.range = NSRange(location: i, length: last - i)
            n.children = parse(s, n.body, depth: depth + 1, minus: true)
            return n
        }
        if a0 == 40 || a0 == 123 {
            guard let close = matching(s, a, end), close > a + 1 else { return nil }
            n.hide = [NSRange(location: i, length: 1), NSRange(location: a, length: 1), NSRange(location: close, length: 1)]
            n.body = NSRange(location: a + 1, length: close - a - 1)
            return done(close + 1)
        }
        n.hide = [NSRange(location: i, length: 1)]
        if let r = root(s, a, lo, end, depth + 1) {
            n.body = r.range
            n.range = NSRange(location: i, length: NSMaxRange(r.range) - i)
            n.children = [r]
            return n
        }
        var j = a
        if sup, a0 == 45 || a0 == 43, ch(s, j + 1, lo, end) != nil { j += 1 }  // sign
        guard let first = ch(s, j, lo, end) else { return nil }
        if isDigit(first) {
            let start = j
            while let d = ch(s, j, lo, end), isDigit(d) { j += 1 }
            if sup, ch(s, j, lo, end) == 46, let d = ch(s, j + 1, lo, end), isDigit(d) {  // decimals
                j += 1
                while let d = ch(s, j, lo, end), isDigit(d) { j += 1 }
            }
            // Subscripts stay short so IMG_2034 and snake_case_1999 aren't touched.
            if !sup { guard j - start <= 2, !(ch(s, j, lo, end).map(isWordish) ?? false) else { return nil } }
        } else if let w = word(s, j, lo, end) {
            j = NSMaxRange(w.range)
        } else if isLetter(first) {
            j += 1
            if let next = ch(s, j, lo, end), sup ? isLetter(next) : isWordish(next) { return nil }
        } else {
            return nil
        }
        n.body = NSRange(location: a, length: j - a)
        return done(j)
    }

    /// 1/2, 3/4: one digit over one digit, so dates like 11/16 stay as typed.
    private static func fraction(_ s: NSString, _ i: Int, _ lo: Int, _ end: Int) -> Node? {
        guard let a = ch(s, i, lo, end), isDigit(a), ch(s, i + 1, lo, end) == 47,
              let b = ch(s, i + 2, lo, end), isDigit(b) else { return nil }
        if let p = ch(s, i - 1, lo, end), isWordish(p) || p == 47 || p == 46 { return nil }
        if let q = ch(s, i + 3, lo, end) {
            if isWordish(q) || q == 47 { return nil }
            if q == 46, let d = ch(s, i + 4, lo, end), isDigit(d) { return nil }
        }
        var n = Node(kind: .fraction, range: NSRange(location: i, length: 3))
        n.body = NSRange(location: i, length: 1)
        n.slot = i + 1
        n.den = NSRange(location: i + 2, length: 1)
        return n
    }

    /// pi, theta, inf as whole words (2pi works too).
    private static func word(_ s: NSString, _ i: Int, _ lo: Int, _ end: Int) -> Node? {
        if let p = ch(s, i - 1, lo, end), isLetter(p) { return nil }
        for (w, g) in words {
            let len = w.utf16.count
            guard i + len <= end, s.substring(with: NSRange(location: i, length: len)) == w else { continue }
            if let q = ch(s, i + len, lo, end), isLetter(q) { return nil }
            return Node(kind: .symbol(g), range: NSRange(location: i, length: len))
        }
        return nil
    }

    private static func symbol(_ s: NSString, _ i: Int, _ lo: Int, _ end: Int, _ depth: Int, _ minus: Bool) -> Node? {
        let c = s.character(at: i)
        let prev = ch(s, i - 1, lo, end), next = ch(s, i + 1, lo, end)
        // <= >= != +- ~=
        if let n = next {
            for (op, g) in operators where op.utf16.first == c && op.utf16.last == n {
                if let p = prev, "<>=!~+-".utf16.contains(p) { return nil }
                if let q = ch(s, i + 2, lo, end), "<>=-".utf16.contains(q) { return nil }
                if c == 62, depth == 0, i == lo { return nil }  // "> " starts a quote
                return Node(kind: .symbol(g), range: NSRange(location: i, length: 2))
            }
        }
        // 2*3, (a+b) * c → ×. Not ** or markdown *italics*.
        if c == 42 {
            func left(_ x: unichar?) -> Bool { x.map { isLetter($0) || isDigit($0) || $0 == 41 } ?? false }
            func right(_ x: unichar?) -> Bool { x.map { isLetter($0) || isDigit($0) || $0 == 40 } ?? false }
            if left(prev), right(next) { return Node(kind: .symbol("×"), range: NSRange(location: i, length: 1)) }
            if prev == 32, next == 32, left(ch(s, i - 2, lo, end)), right(ch(s, i + 2, lo, end)) {
                return Node(kind: .symbol("×"), range: NSRange(location: i, length: 1))
            }
            return nil
        }
        // 90deg → 90°
        if c == 100, let p = prev, isDigit(p), i + 3 <= end, s.substring(with: NSRange(location: i, length: 3)) == "deg",
           !(ch(s, i + 3, lo, end).map(isLetter) ?? false) {
            return Node(kind: .symbol("°"), range: NSRange(location: i, length: 3))
        }
        if c == 45, minus { return Node(kind: .symbol("−"), range: NSRange(location: i, length: 1)) }
        return word(s, i, lo, end)
    }

    // MARK: Styling

    private static let supRaise: CGFloat = 0.36, subDrop: CGFloat = -0.18, small: CGFloat = 0.72

    private static func apply(_ ts: NSTextStorage, _ nodes: [Node], caret: Int?,
                              all: inout [NSRange], revealed: inout [NSRange]) {
        let dim = NSColor.tertiaryLabelColor
        for n in nodes {
            all.append(n.range)
            let open = caret.map { $0 >= n.range.location && $0 <= NSMaxRange(n.range) } ?? false
            if open { revealed.append(n.range) }
            if !open {
                ts.addAttribute(.ligature, value: 0, range: n.range)
                if n.range.length > 1 {
                    ts.addAttribute(.mathKeep, value: true, range: NSRange(location: n.range.location + 1, length: n.range.length - 1))
                }
            }
            func markers() {
                for h in n.hide { ts.addAttribute(open ? .foregroundColor : .mathHidden, value: open ? dim : true, range: h) }
            }
            switch n.kind {
            case .sup, .sub:
                shrink(ts, n.body, by: small, raise: n.kind.isSup ? supRaise : subDrop)
                markers()
            case .root(let cube):
                markers()
                if !open {
                    let color = (ts.attribute(.foregroundColor, at: n.body.location, effectiveRange: nil) as? NSColor) ?? .labelColor
                    let font = (ts.attribute(.font, at: n.slot, effectiveRange: nil) as? NSFont) ?? Markdown.base
                    var a: [NSAttributedString.Key: Any] = [
                        .mathGlyph: "√", .foregroundColor: NSColor.clear,
                        .mathRadical: RadicalMark(radicand: n.body, index: cube ? "3" : nil, color: color),
                    ]
                    if cube { a[.kern] = font.pointSize * 0.22 }
                    ts.addAttributes(a, range: NSRange(location: n.slot, length: 1))
                }
            case .symbol(let g):
                guard !open, canDraw(g, ts, n.range.location) else { break }
                ts.addAttribute(.mathGlyph, value: g, range: NSRange(location: n.range.location, length: 1))
                if n.range.length > 1 {
                    ts.addAttribute(.mathHidden, value: true, range: NSRange(location: n.range.location + 1, length: n.range.length - 1))
                }
            case .fraction:
                guard !open else { break }
                shrink(ts, n.body, by: 0.7, raise: 0.34)
                shrink(ts, n.den, by: 0.7, raise: 0)
                ts.addAttribute(.mathGlyph, value: "⁄", range: NSRange(location: n.slot, length: 1))
            }
            apply(ts, n.children, caret: caret, all: &all, revealed: &revealed)
        }
    }

    /// Smaller text, raised (or lowered) by a share of the size it had.
    private static func shrink(_ ts: NSTextStorage, _ r: NSRange, by factor: CGFloat, raise: CGFloat) {
        let minSize = Markdown.base.pointSize * 0.45
        ts.enumerateAttributes(in: r) { a, sub, _ in
            let f = (a[.font] as? NSFont) ?? Markdown.base
            let off = CGFloat((a[.baselineOffset] as? NSNumber)?.doubleValue ?? 0)
            ts.addAttributes([.font: NSFontManager.shared.convert(f, toSize: max(f.pointSize * factor, minSize)),
                              .baselineOffset: off + raise * f.pointSize], range: sub)
        }
    }

    private static func canDraw(_ g: String, _ ts: NSTextStorage, _ at: Int) -> Bool {
        let f = (ts.attribute(.font, at: at, effectiveRange: nil) as? NSFont) ?? Markdown.base
        let u = Array(g.utf16)
        var out = [CGGlyph](repeating: 0, count: u.count)
        return CTFontGetGlyphsForCharacters(f as CTFont, u, &out, u.count)
    }

    /// How far the radicand reaches above its baseline, so the bar clears it (and any √ inside).
    static func top(_ ts: NSTextStorage, _ r: NSRange) -> CGFloat {
        var t: CGFloat = 0
        ts.enumerateAttributes(in: r) { a, _, _ in
            guard a[.mathHidden] == nil else { return }
            let f = (a[.font] as? NSFont) ?? Markdown.base
            let off = CGFloat((a[.baselineOffset] as? NSNumber)?.doubleValue ?? 0)
            t = max(t, off + f.capHeight * 1.08)
            if let m = a[.mathRadical] as? RadicalMark { t = max(t, off + top(ts, m.radicand) + f.pointSize * 0.12) }
        }
        return t + Markdown.base.pointSize * 0.14
    }
}

// MARK: - Layout: hidden markers, swapped symbols, drawn √

final class MathLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    func layoutManager(_ lm: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes chars: UnsafePointer<Int>, font: NSFont, forGlyphRange range: NSRange) -> Int {
        guard let ts = textStorage, range.length > 0 else { return 0 }
        let span = NSRange(location: chars[0], length: chars[range.length - 1] - chars[0] + 1)
        guard NSMaxRange(span) <= ts.length else { return 0 }
        var any = false
        ts.enumerateAttributes(in: span) { a, _, stop in
            if a[.mathHidden] != nil || a[.mathGlyph] != nil { any = true; stop.pointee = true }
        }
        guard any else { return 0 }
        var g = Array(UnsafeBufferPointer(start: glyphs, count: range.length))
        var p = Array(UnsafeBufferPointer(start: props, count: range.length))
        for k in 0..<range.length {
            let c = chars[k]
            if ts.attribute(.mathHidden, at: c, effectiveRange: nil) != nil {
                p[k] = .null
            } else if let sub = ts.attribute(.mathGlyph, at: c, effectiveRange: nil) as? String {
                let u = Array(sub.utf16)
                var out = [CGGlyph](repeating: 0, count: u.count)
                if CTFontGetGlyphsForCharacters(font as CTFont, u, &out, u.count) { g[k] = out[0] }
            }
        }
        setGlyphs(g, properties: p, characterIndexes: chars, font: font, forGlyphRange: range)
        return range.length
    }

    /// Keep formatted math on one line (√ and its bar, x^(n+1), …).
    func layoutManager(_ lm: NSLayoutManager, shouldBreakLineByWordBeforeCharacterAt i: Int) -> Bool {
        guard let ts = textStorage, i < ts.length else { return true }
        return ts.attribute(.mathKeep, at: i, effectiveRange: nil) == nil
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let ts = textStorage, ts.length > 0 else { return }
        let shown = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        ts.enumerateAttribute(.mathRadical, in: NSRange(location: 0, length: ts.length)) { v, r, _ in
            guard let mark = v as? RadicalMark, NSMaxRange(mark.radicand) <= ts.length,
                  NSIntersectionRange(NSUnionRange(r, mark.radicand), shown).length > 0 else { return }
            drawRadical(mark, slot: r.location, ts, origin)
        }
    }

    /// The line's baseline at glyph g, in view coordinates (glyph locations include baseline offsets).
    private func baseline(_ g: Int, _ ts: NSTextStorage, _ origin: NSPoint) -> CGFloat {
        let frag = lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        let c = characterIndexForGlyph(at: g)
        let off = CGFloat((ts.attribute(.baselineOffset, at: c, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0)
        return origin.y + frag.minY + location(forGlyphAt: g).y + off
    }

    /// x where glyph g starts, in view coordinates. (boundingRect is off on lines that start with hidden glyphs.)
    private func startX(_ g: Int, _ origin: NSPoint) -> CGFloat {
        origin.x + lineFragmentRect(forGlyphAt: g, effectiveRange: nil).minX + location(forGlyphAt: g).x
    }

    /// x where the glyphs in `part` (all on one line) end.
    private func endX(_ part: NSRange, _ origin: NSPoint) -> CGFloat {
        let next = NSMaxRange(part)
        let frag = lineFragmentRect(forGlyphAt: part.location, effectiveRange: nil)
        if next < numberOfGlyphs, lineFragmentRect(forGlyphAt: next, effectiveRange: nil) == frag {
            return startX(next, origin)
        }
        return origin.x + lineFragmentUsedRect(forGlyphAt: part.location, effectiveRange: nil).maxX
    }

    private func drawRadical(_ mark: RadicalMark, slot: Int, _ ts: NSTextStorage, _ origin: NSPoint) {
        let sg = glyphIndexForCharacter(at: slot)
        let font = (ts.attribute(.font, at: slot, effectiveRange: nil) as? NSFont) ?? Markdown.base
        let off = CGFloat((ts.attribute(.baselineOffset, at: slot, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0)
        let lineBase = baseline(sg, ts, origin)
        let base = lineBase - off  // the √ sits where its own text sits
        let rise = MathStyle.top(ts, mark.radicand)
        let kern = CGFloat((ts.attribute(.kern, at: slot, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0)
        let x0 = startX(sg, origin) + kern, w = endX(NSRange(location: sg, length: 1), origin) - x0
        let xh = font.xHeight, size = font.pointSize
        let lw = max(0.9, size * 0.07)

        // The bar over the radicand, one piece per line it wraps onto.
        var bars: [(minX: CGFloat, maxX: CGFloat, y: CGFloat)] = []
        let rg = glyphRange(forCharacterRange: mark.radicand, actualCharacterRange: nil)
        enumerateLineFragments(forGlyphRange: rg) { _, _, _, lineGlyphs, _ in
            let part = NSIntersectionRange(rg, lineGlyphs)
            guard part.length > 0 else { return }
            bars.append((self.startX(part.location, origin), self.endX(part, origin), self.baseline(part.location, ts, origin)))
        }
        // If a very long radicand still wraps, the √ stays on its own line and each line gets a bar.
        let sameLine = bars.first.map { abs($0.y - lineBase) < 0.5 } ?? false
        let topY = lineBase - rise  // `rise` already counts the radicand's own raise
        let path = NSBezierPath()
        path.lineWidth = lw
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        let hookY = base - 0.45 * xh
        path.move(to: NSPoint(x: x0 + 0.08 * w, y: hookY + 0.06 * xh))
        path.line(to: NSPoint(x: x0 + 0.26 * w, y: hookY - 0.06 * xh))
        path.line(to: NSPoint(x: x0 + 0.5 * w, y: base + 0.04 * size))
        path.line(to: NSPoint(x: x0 + 0.9 * w, y: topY))
        path.line(to: NSPoint(x: max(sameLine ? bars[0].maxX : 0, x0 + w) + 0.06 * size, y: topY))
        mark.color.setStroke()
        path.stroke()
        // The downstroke is a bit heavier, like a typeset √.
        let heavy = NSBezierPath()
        heavy.lineWidth = lw * 1.5
        heavy.lineCapStyle = .round
        heavy.move(to: NSPoint(x: x0 + 0.27 * w, y: hookY - 0.04 * xh))
        heavy.line(to: NSPoint(x: x0 + 0.49 * w, y: base + 0.02 * size))
        heavy.stroke()
        for bar in bars.dropFirst(sameLine ? 1 : 0) {
            let y = bar.y - rise
            let p = NSBezierPath()
            p.lineWidth = lw
            p.move(to: NSPoint(x: bar.minX, y: y))
            p.line(to: NSPoint(x: bar.maxX + 0.06 * size, y: y))
            p.stroke()
        }
        if let index = mark.index {
            let f = NSFontManager.shared.convert(font, toSize: max(size * 0.5, 6))
            let s = NSAttributedString(string: index, attributes: [.font: f, .foregroundColor: mark.color])
            let sz = s.size()
            s.draw(at: NSPoint(x: x0 + 0.3 * w - sz.width, y: hookY - 0.15 * xh - sz.height))
        }
    }
}
