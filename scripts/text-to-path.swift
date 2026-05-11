#!/usr/bin/env swift
// Emit SVG <path> elements for the icon's three glyphs (E / 0 / 5)
// using CoreText. Hardcoded to Helvetica-Bold @ 320pt to match the
// design, then translated so each glyph's visual center lands at the
// authored (x, y) — equivalent to text-anchor="middle" +
// dominant-baseline="central". Run once when the letters change:
//   swift scripts/text-to-path.swift
// Then paste the output over the <text> block in Resources/icon.svg.

import AppKit
import CoreText

struct GlyphSpec {
    let char: Character
    let x: CGFloat
    let y: CGFloat
}

let fontSize: CGFloat = 320
guard let font = NSFont(name: "HelveticaNeue-Bold", size: fontSize) else {
    FileHandle.standardError.write(Data("error: HelveticaNeue-Bold not available on this system\n".utf8))
    exit(1)
}
let ctFont = font as CTFont

let specs: [GlyphSpec] = [
    GlyphSpec(char: "E", x: 512, y: 440),
    GlyphSpec(char: "0", x: 380, y: 770),
    GlyphSpec(char: "5", x: 644, y: 770),
]

func formatNumber(_ n: CGFloat) -> String {
    String(format: "%.2f", n)
}

for spec in specs {
    let utf16 = Array(String(spec.char).utf16)
    var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
    let ok = CTFontGetGlyphsForCharacters(ctFont, utf16, &glyphs, utf16.count)
    guard ok, let path = CTFontCreatePathForGlyph(ctFont, glyphs[0], nil) else {
        FileHandle.standardError.write(Data("error: glyph extraction failed for \(spec.char)\n".utf8))
        exit(1)
    }
    // X centering uses inked bbox midX (text-anchor=middle).
    // Y: WebKit treats dominant-baseline=central as placing the
    // alphabetic baseline at spec.y for this font (verified by
    // WKWebView snapshot vs CoreText cap-height bbox), so just
    // anchor the baseline (font y=0) at spec.y in SVG.
    let bbox = path.boundingBox
    let dx = spec.x - bbox.midX
    let dy = spec.y

    var d = ""
    path.applyWithBlock { elementPtr in
        let elem = elementPtr.pointee
        let pts = elem.points
        switch elem.type {
        case .moveToPoint:
            d += "M\(formatNumber(pts[0].x + dx)) \(formatNumber(-pts[0].y + dy)) "
        case .addLineToPoint:
            d += "L\(formatNumber(pts[0].x + dx)) \(formatNumber(-pts[0].y + dy)) "
        case .addQuadCurveToPoint:
            d += "Q\(formatNumber(pts[0].x + dx)) \(formatNumber(-pts[0].y + dy)) "
            d += "\(formatNumber(pts[1].x + dx)) \(formatNumber(-pts[1].y + dy)) "
        case .addCurveToPoint:
            d += "C\(formatNumber(pts[0].x + dx)) \(formatNumber(-pts[0].y + dy)) "
            d += "\(formatNumber(pts[1].x + dx)) \(formatNumber(-pts[1].y + dy)) "
            d += "\(formatNumber(pts[2].x + dx)) \(formatNumber(-pts[2].y + dy)) "
        case .closeSubpath:
            d += "Z "
        @unknown default:
            FileHandle.standardError.write(Data(
                "[text-to-path] unknown CGPathElement \(elem.type.rawValue) for \(spec.char)\n".utf8))
            exit(1)
        }
    }
    print("    <!-- \(spec.char) at (\(Int(spec.x)), \(Int(spec.y))) -->")
    print("    <path d=\"\(d.trimmingCharacters(in: .whitespaces))\"/>")
}
