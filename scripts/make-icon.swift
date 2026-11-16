#!/usr/bin/env swift
// Draws the app icon with CoreGraphics — no image tools, no downloads. Tweak the numbers and re-run.
//
//   swift scripts/make-icon.swift --previews design/icon-candidates   # 512 px PNG of each candidate + a size sheet
//   swift scripts/make-icon.swift --iconset build/AppIcon.iconset [--candidate a|b|c]   # input for `iconutil -c icns`
//
// Candidates (all on the macOS rounded-square grid: 824 px shape on a 1024 px canvas):
//   a  "Orbit"       — night-blue tile, a pale planet with a tilted orbit; the bright part of the orbit is a gauge.
//   b  "Gauge"       — light tile, a small ringed planet inside a thick round disk-usage gauge.
//   c  "Phase"       — dusk tile, a planet whose lit crescent is the gauge, one thin orbit with a satellite.
//   p  "Cosmonaut"   — Prune's icon: a cosmonaut holding a cube whose face is the icon itself (a, b, c are Major Tom's).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The candidate wired into the app (scripts/bundle.sh).
let chosenCandidate = "p"

// MARK: - Helpers

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

/// macOS app-icon shape: a superellipse ("squircle") close to Apple's continuous-corner rounded square.
func squircle(_ rect: CGRect, exponent n: CGFloat = 5.2) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2, cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// Draws the tile (shadow + clipped background) and runs `content` clipped to it. Units are 1024-canvas units.
func tile(_ ctx: CGContext, background: (CGContext, CGRect) -> Void, content: (CGContext) -> Void) {
    let shape = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = squircle(shape)
    ctx.saveGState()
    // Shadow geometry is in device pixels (the CTM doesn't scale it), so scale it by hand.
    let k = ctx.ctm.a
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 24 * k, color: rgb(0x000000, 0.30))
    ctx.addPath(path)
    ctx.setFillColor(rgb(0x000000))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    background(ctx, shape)
    content(ctx)
    // A hairline inner edge so the tile holds its shape on any background.
    ctx.addPath(path)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.10))
    ctx.setLineWidth(4)
    ctx.strokePath()
    ctx.restoreGState()
}

func sphere(_ ctx: CGContext, center: CGPoint, radius r: CGFloat, light: UInt32, mid: UInt32, dark: UInt32) {
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
    ctx.clip()
    ctx.drawRadialGradient(gradient([rgb(light), rgb(mid), rgb(dark)], [0, 0.55, 1]),
                           startCenter: CGPoint(x: center.x - r * 0.35, y: center.y + r * 0.4), startRadius: 0,
                           endCenter: center, endRadius: r * 1.05, options: [.drawsAfterEndLocation])
    ctx.restoreGState()
}

/// An arc along an ellipse (center, radii, rotation), from angle a0 to a1 (radians, counter-clockwise).
func ellipseArc(center: CGPoint, rx: CGFloat, ry: CGFloat, rotation: CGFloat, from a0: CGFloat, to a1: CGFloat) -> CGPath {
    let t = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: rotation).scaledBy(x: 1, y: ry / rx)
    let path = CGMutablePath()
    path.addArc(center: .zero, radius: rx, startAngle: a0, endAngle: a1, clockwise: false, transform: t)
    return path
}

func ellipsePoint(center: CGPoint, rx: CGFloat, ry: CGFloat, rotation: CGFloat, angle: CGFloat) -> CGPoint {
    let p = CGPoint(x: rx * cos(angle), y: ry * sin(angle))
    return CGPoint(x: center.x + p.x * cos(rotation) - p.y * sin(rotation),
                   y: center.y + p.x * sin(rotation) + p.y * cos(rotation))
}

func stroke(_ ctx: CGContext, _ path: CGPath, width: CGFloat, color: CGColor, cap: CGLineCap = .round) {
    ctx.addPath(path)
    ctx.setLineWidth(width)
    ctx.setLineCap(cap)
    ctx.setStrokeColor(color)
    ctx.strokePath()
}

func dot(_ ctx: CGContext, _ p: CGPoint, _ r: CGFloat, _ color: CGColor) {
    ctx.setFillColor(color)
    ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
}

// MARK: - Candidates
// `small` is true at 16/32 px: strokes get heavier and faint details are dropped so the shape still reads.

/// a — Orbit: night tile, pale planet, tilted orbit whose bright arc is the gauge, a satellite at its tip.
func drawOrbit(_ ctx: CGContext, small: Bool) {
    tile(ctx, background: { ctx, r in
        ctx.drawLinearGradient(gradient([rgb(0x24386E), rgb(0x0E1836)]), start: CGPoint(x: 0, y: r.maxY),
                               end: CGPoint(x: 0, y: r.minY), options: [])
        ctx.drawRadialGradient(gradient([rgb(0x5B7BD6, 0.35), rgb(0x5B7BD6, 0)]), startCenter: CGPoint(x: 512, y: 560),
                               startRadius: 0, endCenter: CGPoint(x: 512, y: 560), endRadius: 420, options: [])
    }, content: { ctx in
        let c = CGPoint(x: 512, y: 500)
        let rx: CGFloat = 318, ry: CGFloat = 112, rot: CGFloat = 0.36
        let w: CGFloat = small ? 46 : 30
        let lit = rgb(0x7FE7D8), faint = rgb(0xFFFFFF, 0.16)
        // The orbit's upper half (0…π) is the far side, behind the planet; the lower half (π…2π) passes in front.
        // The gauge runs from the left, round the front, to the right-hand tip where the satellite sits (~60%).
        let gaugeStart: CGFloat = .pi * 0.88, gaugeEnd: CGFloat = 2 * .pi + 0.12
        func arc(_ a0: CGFloat, _ a1: CGFloat) -> CGPath { ellipseArc(center: c, rx: rx, ry: ry, rotation: rot, from: a0, to: a1) }
        if !small { stroke(ctx, arc(0, .pi), width: w, color: faint) }
        stroke(ctx, arc(gaugeStart, .pi), width: w, color: lit, cap: .round)
        stroke(ctx, arc(0, gaugeEnd - 2 * .pi), width: w, color: lit, cap: .butt)
        sphere(ctx, center: c, radius: small ? 186 : 172, light: 0xFFF8EC, mid: 0xD9D3E6, dark: 0x8C8FB8)
        stroke(ctx, arc(.pi, 2 * .pi), width: w, color: lit, cap: .butt)
        let tip = ellipsePoint(center: c, rx: rx, ry: ry, rotation: rot, angle: gaugeEnd)
        dot(ctx, tip, small ? 42 : 32, rgb(0xFFFFFF))
    })
}

/// b — Gauge: light tile, thick round gauge around a small ringed planet.
func drawGauge(_ ctx: CGContext, small: Bool) {
    tile(ctx, background: { ctx, r in
        ctx.drawLinearGradient(gradient([rgb(0xFBFCFE), rgb(0xDDE3EE)]), start: CGPoint(x: 0, y: r.maxY),
                               end: CGPoint(x: 0, y: r.minY), options: [])
    }, content: { ctx in
        let c = CGPoint(x: 512, y: 512)
        let radius: CGFloat = 292, w: CGFloat = small ? 92 : 70
        let track = CGMutablePath()
        track.addArc(center: c, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        stroke(ctx, track, width: w, color: rgb(0x1E2A4A, 0.10))
        // Progress: from 12 o'clock clockwise, 72%.
        let start: CGFloat = .pi / 2, end: CGFloat = .pi / 2 - 2 * .pi * 0.72
        let arc = CGMutablePath()
        arc.addArc(center: c, radius: radius, startAngle: start, endAngle: end, clockwise: true)
        ctx.saveGState()
        ctx.addPath(arc)
        ctx.setLineWidth(w)
        ctx.setLineCap(.round)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(gradient([rgb(0x3D7BF2), rgb(0x2EC5B6)]), start: CGPoint(x: 220, y: 820),
                               end: CGPoint(x: 820, y: 220), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
        // Planet with a thin ring.
        let pr: CGFloat = small ? 150 : 128
        let rot: CGFloat = 0.42
        if !small { stroke(ctx, ellipseArc(center: c, rx: 205, ry: 58, rotation: rot, from: 0, to: .pi), width: 16, color: rgb(0x1E2A4A, 0.55)) }
        sphere(ctx, center: c, radius: pr, light: 0x5D74B8, mid: 0x2B3A6E, dark: 0x141C3A)
        if !small { stroke(ctx, ellipseArc(center: c, rx: 205, ry: 58, rotation: rot, from: .pi, to: 2 * .pi), width: 16, color: rgb(0x1E2A4A, 0.85)) }
    })
}

/// c — Phase: dusk tile, a planet whose lit crescent is the gauge, one thin orbit and a satellite.
func drawPhase(_ ctx: CGContext, small: Bool) {
    tile(ctx, background: { ctx, r in
        ctx.drawLinearGradient(gradient([rgb(0x3A3170), rgb(0x141233)]), start: CGPoint(x: 0, y: r.maxY),
                               end: CGPoint(x: 0, y: r.minY), options: [])
        if !small {
            for (x, y, s) in [(250.0, 770.0, 7.0), (770.0, 300.0, 6.0), (690.0, 800.0, 5.0)] {
                dot(ctx, CGPoint(x: x, y: y), s, rgb(0xFFFFFF, 0.55))
            }
        }
    }, content: { ctx in
        let c = CGPoint(x: 500, y: 500), r: CGFloat = small ? 250 : 230
        // Dark side.
        sphere(ctx, center: c, radius: r, light: 0x3B3F78, mid: 0x262A58, dark: 0x171A3C)
        // Lit crescent: the planet minus an offset disc.
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.clip()
        let lit = CGMutablePath()
        lit.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        lit.addEllipse(in: CGRect(x: c.x - r + r * 0.62, y: c.y - r - r * 0.18, width: 2 * r, height: 2 * r))
        ctx.addPath(lit)
        ctx.clip(using: .evenOdd)
        ctx.drawLinearGradient(gradient([rgb(0xFFF3D6), rgb(0xF2B880)]), start: CGPoint(x: c.x - r, y: c.y + r),
                               end: CGPoint(x: c.x, y: c.y - r), options: [])
        ctx.restoreGState()
        // Orbit + satellite.
        let orbit = CGMutablePath()
        orbit.addArc(center: c, radius: r + (small ? 90 : 78), startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        stroke(ctx, orbit, width: small ? 22 : 10, color: rgb(0xFFFFFF, small ? 0.5 : 0.35))
        let a: CGFloat = .pi * 0.25
        dot(ctx, CGPoint(x: c.x + (r + (small ? 90 : 78)) * cos(a), y: c.y + (r + (small ? 90 : 78)) * sin(a)), small ? 42 : 28, rgb(0xFFFFFF))
    })
}

// MARK: - Candidate P: "Cosmonaut" (Prune)
//
// A cosmonaut in a blue flight suit holds a white cube in front of the Earth and a space station. The face of the
// cube is this very icon, so the picture repeats inside itself. A cartoon homage to Dumitru Prunariu, the first
// Romanian in space: flat shapes, no attempt at a portrait.

func spaceBackground(_ ctx: CGContext, _ shape: CGRect) {
    ctx.drawLinearGradient(gradient([rgb(0x04060E), rgb(0x0A1F45), rgb(0x123A78)], [0, 0.6, 1]),
                           start: CGPoint(x: 512, y: shape.maxY), end: CGPoint(x: 512, y: shape.minY), options: [])
    // Stars.
    for (x, y, r) in [(180.0, 860.0, 4.0), (300, 800, 3), (730, 880, 4), (860, 760, 3), (820, 600, 3), (160, 620, 3),
                      (640, 820, 2.5), (420, 890, 2.5), (890, 500, 2.5), (130, 460, 2.5)] {
        dot(ctx, CGPoint(x: x, y: y), r, rgb(0xFFFFFF, 0.75))
    }
    // The Earth's limb along the bottom, with a thin band of atmosphere.
    let earth = CGRect(x: 512 - 1150, y: 400 - 2300, width: 2300, height: 2300)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 40 * ctx.ctm.a, color: rgb(0x7FC4FF, 0.9))
    ctx.setFillColor(rgb(0x2E7BD6))
    ctx.fillEllipse(in: earth)
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: earth)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0x6DB7F2), rgb(0x2A72C8), rgb(0x143F86)], [0, 0.25, 1]),
                           start: CGPoint(x: 512, y: 400), end: CGPoint(x: 512, y: 80), options: [.drawsAfterEndLocation])
    // Cloud streaks.
    ctx.setFillColor(rgb(0xFFFFFF, 0.22))
    for (x, y, w, h) in [(120.0, 300.0, 240.0, 24.0), (700, 320, 200, 20), (380, 200, 320, 28), (720, 180, 180, 20)] {
        ctx.fillEllipse(in: CGRect(x: x, y: y, width: w, height: h))
    }
    ctx.restoreGState()
}

func spaceStation(_ ctx: CGContext) {
    ctx.saveGState()
    ctx.translateBy(x: 285, y: 800)
    ctx.rotate(by: -0.30)
    ctx.scaleBy(x: 0.72, y: 0.72)
    // Solar arrays in pairs along the truss.
    for x in [-250.0, -165, 165, 250] {
        for y in [22.0, -112] {
            let panel = CGRect(x: x - 32, y: y, width: 64, height: 90)
            ctx.setFillColor(rgb(0x2B55A8))
            ctx.fill(panel)
            ctx.setStrokeColor(rgb(0xA9C2F2, 0.8))
            ctx.setLineWidth(3)
            ctx.stroke(panel)
            ctx.move(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x, y: y + 90)); ctx.strokePath()
        }
    }
    ctx.setFillColor(rgb(0xC9CED8))
    ctx.fill(CGRect(x: -300, y: -8, width: 600, height: 16))             // truss
    ctx.addPath(CGPath(roundedRect: CGRect(x: -60, y: -34, width: 120, height: 68), cornerWidth: 22, cornerHeight: 22, transform: nil))
    ctx.fillPath()                                                        // core module
    ctx.setFillColor(rgb(0xE9ECF2))
    ctx.addPath(CGPath(roundedRect: CGRect(x: -22, y: -120, width: 44, height: 110), cornerWidth: 18, cornerHeight: 18, transform: nil))
    ctx.fillPath()                                                        // docked module
    ctx.restoreGState()
}

/// Everything inside the tile, in 1024-canvas units. `depth` is how many more times the icon repeats on the cube.
func cosmonautScene(_ ctx: CGContext, depth: Int, detail: Bool) {
    let suit = rgb(0x2458C8), suitDark = rgb(0x163A8E), skin = rgb(0xE3AE8E), skinShade = rgb(0xC98F70)
    if detail { spaceStation(ctx) }

    // Shoulders and chest.
    let torso = CGMutablePath()
    torso.move(to: CGPoint(x: 250, y: 60))
    torso.addCurve(to: CGPoint(x: 420, y: 545), control1: CGPoint(x: 240, y: 380), control2: CGPoint(x: 300, y: 520))
    torso.addLine(to: CGPoint(x: 700, y: 545))
    torso.addCurve(to: CGPoint(x: 900, y: 60), control1: CGPoint(x: 830, y: 520), control2: CGPoint(x: 905, y: 380))
    torso.closeSubpath()
    ctx.saveGState()
    ctx.addPath(torso)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0x2F68DE), suit, suitDark], [0, 0.45, 1]),
                           start: CGPoint(x: 400, y: 560), end: CGPoint(x: 700, y: 60), options: [])
    // Zip.
    ctx.setStrokeColor(rgb(0x0F2A6B, 0.9))
    ctx.setLineWidth(7)
    ctx.move(to: CGPoint(x: 560, y: 520)); ctx.addLine(to: CGPoint(x: 566, y: 60)); ctx.strokePath()
    ctx.restoreGState()

    // Neck, black collar, head.
    ctx.setFillColor(skinShade)
    ctx.fill(CGRect(x: 510, y: 520, width: 100, height: 80))
    ctx.setFillColor(rgb(0x14161B))
    let collar = CGMutablePath()
    collar.move(to: CGPoint(x: 430, y: 548))
    collar.addCurve(to: CGPoint(x: 690, y: 548), control1: CGPoint(x: 500, y: 470), control2: CGPoint(x: 620, y: 470))
    collar.addCurve(to: CGPoint(x: 430, y: 548), control1: CGPoint(x: 630, y: 590), control2: CGPoint(x: 490, y: 590))
    ctx.addPath(collar)
    ctx.fillPath()

    let head = CGRect(x: 458, y: 560, width: 204, height: 238)
    ctx.setFillColor(skin)
    ctx.fillEllipse(in: CGRect(x: 440, y: 650, width: 36, height: 62))    // ears
    ctx.fillEllipse(in: CGRect(x: 644, y: 650, width: 36, height: 62))
    ctx.fillEllipse(in: head)
    // Grey hair: a cap over the top of the head and down the sides.
    ctx.saveGState()
    ctx.addEllipse(in: head.insetBy(dx: -8, dy: -8))
    ctx.clip()
    ctx.setFillColor(rgb(0x9A9CA3))
    let hair = CGMutablePath()
    hair.move(to: CGPoint(x: 440, y: 700))
    hair.addCurve(to: CGPoint(x: 560, y: 760), control1: CGPoint(x: 470, y: 760), control2: CGPoint(x: 510, y: 770))
    hair.addCurve(to: CGPoint(x: 680, y: 700), control1: CGPoint(x: 615, y: 770), control2: CGPoint(x: 655, y: 755))
    hair.addLine(to: CGPoint(x: 690, y: 830))
    hair.addLine(to: CGPoint(x: 430, y: 830))
    hair.closeSubpath()
    ctx.addPath(hair)
    ctx.fillPath()
    ctx.restoreGState()
    if detail {
        ctx.setFillColor(rgb(0x2A2320))
        ctx.fillEllipse(in: CGRect(x: 510, y: 672, width: 20, height: 22))   // eyes
        ctx.fillEllipse(in: CGRect(x: 592, y: 672, width: 20, height: 22))
        ctx.setStrokeColor(rgb(0x7B7D84))
        ctx.setLineWidth(9)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: 498, y: 708)); ctx.addQuadCurve(to: CGPoint(x: 540, y: 710), control: CGPoint(x: 520, y: 720)); ctx.strokePath()
        ctx.move(to: CGPoint(x: 582, y: 710)); ctx.addQuadCurve(to: CGPoint(x: 624, y: 708), control: CGPoint(x: 602, y: 720)); ctx.strokePath()
        ctx.setStrokeColor(rgb(0xA8674F))
        ctx.setLineWidth(8)
        ctx.move(to: CGPoint(x: 522, y: 618)); ctx.addQuadCurve(to: CGPoint(x: 600, y: 618), control: CGPoint(x: 561, y: 592)); ctx.strokePath()
        ctx.setStrokeColor(skinShade)
        ctx.setLineWidth(7)
        ctx.move(to: CGPoint(x: 561, y: 668)); ctx.addQuadCurve(to: CGPoint(x: 566, y: 640), control: CGPoint(x: 578, y: 648)); ctx.strokePath()
    }

    // Round mission patch and name tag on the chest.
    ctx.setFillColor(rgb(0xF4F5F7))
    ctx.fillEllipse(in: CGRect(x: 372, y: 440, width: 92, height: 92))
    ctx.setFillColor(rgb(0xD23B3B))
    ctx.fill(CGRect(x: 393, y: 482, width: 25, height: 24))
    ctx.setFillColor(rgb(0xF2C230))
    ctx.fill(CGRect(x: 418, y: 482, width: 25, height: 24))
    ctx.setFillColor(rgb(0x3A6FD8))
    ctx.fill(CGRect(x: 393, y: 462, width: 50, height: 14))
    ctx.setFillColor(rgb(0xE8C860))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 622, y: 452, width: 126, height: 36), cornerWidth: 6, cornerHeight: 6, transform: nil))
    ctx.fillPath()
    ctx.setFillColor(rgb(0x5A4A12))
    ctx.fill(CGRect(x: 638, y: 466, width: 94, height: 8))

    // The cube: top and side faces, then the front face carrying the icon itself.
    let front = CGRect(x: 268, y: 112, width: 276, height: 276)
    let lift = CGPoint(x: 52, y: 46)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8 * ctx.ctm.a), blur: 22 * ctx.ctm.a, color: rgb(0x000000, 0.45))
    let silhouette = CGMutablePath()
    silhouette.addLines(between: [CGPoint(x: front.minX, y: front.minY), CGPoint(x: front.maxX, y: front.minY),
                                  CGPoint(x: front.maxX + lift.x, y: front.minY + lift.y),
                                  CGPoint(x: front.maxX + lift.x, y: front.maxY + lift.y),
                                  CGPoint(x: front.minX + lift.x, y: front.maxY + lift.y), CGPoint(x: front.minX, y: front.maxY)])
    silhouette.closeSubpath()
    ctx.addPath(silhouette)
    ctx.setFillColor(rgb(0xD9DCE3))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.setFillColor(rgb(0xFFFFFF))                                        // top
    ctx.addLines(between: [CGPoint(x: front.minX, y: front.maxY), CGPoint(x: front.maxX, y: front.maxY),
                           CGPoint(x: front.maxX + lift.x, y: front.maxY + lift.y), CGPoint(x: front.minX + lift.x, y: front.maxY + lift.y)])
    ctx.fillPath()
    ctx.setFillColor(rgb(0xC3C8D2))                                        // side
    ctx.addLines(between: [CGPoint(x: front.maxX, y: front.minY), CGPoint(x: front.maxX, y: front.maxY),
                           CGPoint(x: front.maxX + lift.x, y: front.maxY + lift.y), CGPoint(x: front.maxX + lift.x, y: front.minY + lift.y)])
    ctx.fillPath()
    ctx.setFillColor(rgb(0xEEF0F4))                                        // front
    ctx.addPath(CGPath(roundedRect: front, cornerWidth: 26, cornerHeight: 26, transform: nil))
    ctx.fillPath()

    // The icon on the cube: the whole tile again, scaled into the front face.
    let label = front.insetBy(dx: 30, dy: 30)
    ctx.saveGState()
    ctx.translateBy(x: label.minX, y: label.minY)
    ctx.scaleBy(x: label.width / 824, y: label.height / 824)
    ctx.translateBy(x: -100, y: -100)
    let shape = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.addPath(squircle(shape))
    ctx.clip()
    spaceBackground(ctx, shape)
    if depth > 0 { cosmonautScene(ctx, depth: depth - 1, detail: depth > 1) }
    ctx.restoreGState()

    // Arms come round the cube; cuffs and hands rest on its edges.
    func arm(_ from: CGPoint, _ control: CGPoint, _ to: CGPoint) {
        let p = CGMutablePath()
        p.move(to: from)
        p.addQuadCurve(to: to, control: control)
        stroke(ctx, p, width: 100, color: suitDark)
        stroke(ctx, p, width: 84, color: suit)
    }
    arm(CGPoint(x: 318, y: 440), CGPoint(x: 185, y: 400), CGPoint(x: 232, y: 232))
    arm(CGPoint(x: 838, y: 430), CGPoint(x: 880, y: 170), CGPoint(x: 668, y: 176))
    // The Romanian flag on the sleeve.
    ctx.saveGState()
    ctx.translateBy(x: 846, y: 380)
    ctx.rotate(by: -0.12)
    ctx.scaleBy(x: 0.86, y: 0.86)
    ctx.setFillColor(rgb(0x0F1E55))
    ctx.fill(CGRect(x: -46, y: -31, width: 92, height: 62))
    for (i, c) in [0x1E3FA8, 0xF2C230, 0xD2303A].enumerated() {
        ctx.setFillColor(rgb(UInt32(c)))
        ctx.fill(CGRect(x: -42 + CGFloat(i) * 28, y: -27, width: 28, height: 54))
    }
    ctx.restoreGState()
    func hand(_ center: CGPoint, _ angle: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: angle)
        ctx.setFillColor(rgb(0x14161B))
        ctx.addPath(CGPath(roundedRect: CGRect(x: -86, y: -44, width: 40, height: 88), cornerWidth: 12, cornerHeight: 12, transform: nil))
        ctx.fillPath()
        ctx.setFillColor(skin)
        ctx.addPath(CGPath(roundedRect: CGRect(x: -52, y: -40, width: 104, height: 80), cornerWidth: 36, cornerHeight: 36, transform: nil))
        ctx.fillPath()
        if detail {
            ctx.setStrokeColor(skinShade)
            ctx.setLineWidth(5)
            ctx.setLineCap(.round)
            for y in [-14.0, 6, 24] {
                ctx.move(to: CGPoint(x: 6, y: y)); ctx.addLine(to: CGPoint(x: 44, y: y)); ctx.strokePath()
            }
        }
        ctx.restoreGState()
    }
    hand(CGPoint(x: 276, y: 204), -0.5)
    hand(CGPoint(x: 600, y: 180), .pi + 0.1)
}

func drawCosmonaut(_ ctx: CGContext, small: Bool) {
    tile(ctx, background: spaceBackground) { ctx in
        cosmonautScene(ctx, depth: small ? 0 : 3, detail: !small)
    }
}

let candidates: [String: (CGContext, Bool) -> Void] = ["a": drawOrbit, "b": drawGauge, "c": drawPhase, "p": drawCosmonaut]

// MARK: - Rendering

func render(_ name: String, pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    let scale = CGFloat(pixels) / 1024
    ctx.scaleBy(x: scale, y: scale)
    candidates[name]!(ctx, pixels <= 32)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "make-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "can't write \(url.path)"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "make-icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "can't write \(url.path)"])
    }
}

/// One strip per candidate at 16, 32, 64, 128 and 256 px on a light and a dark band — for judging small sizes.
func sizeSheet() -> CGImage {
    let sizes = [16, 32, 64, 128, 256]
    let rowHeight = 300, width = 40 + sizes.reduce(0) { $0 + $1 + 40 }
    let names = candidates.keys.sorted()
    let ctx = CGContext(data: nil, width: width, height: rowHeight * names.count * 2, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for (i, name) in names.enumerated() {
        for (j, bg) in [rgb(0xF2F2F5), rgb(0x1E1E22)].enumerated() {
            let y = (names.count * 2 - 1 - (i * 2 + j)) * rowHeight
            ctx.setFillColor(bg)
            ctx.fill(CGRect(x: 0, y: y, width: width, height: rowHeight))
            var x = 40
            for s in sizes {
                ctx.draw(render(name, pixels: s), in: CGRect(x: x, y: y + (rowHeight - s) / 2, width: s, height: s))
                x += s + 40
            }
        }
    }
    return ctx.makeImage()!
}

// MARK: - Main

let args = CommandLine.arguments
func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

do {
    if let dir = value("--previews") {
        let folder = URL(filePath: dir, directoryHint: .isDirectory)
        for name in candidates.keys.sorted() {
            try writePNG(render(name, pixels: 512), to: folder.appending(path: "\(name)-512.png"))
        }
        if let sheet = value("--sheet") { try writePNG(sizeSheet(), to: URL(filePath: sheet)) }
        print("Wrote previews to \(folder.path)")
    } else if let dir = value("--iconset") {
        let name = value("--candidate") ?? chosenCandidate
        guard candidates[name] != nil else { throw NSError(domain: "make-icon", code: 3, userInfo: [NSLocalizedDescriptionKey: "unknown candidate \(name)"]) }
        let folder = URL(filePath: dir, directoryHint: .isDirectory)
        for base in [16, 32, 128, 256, 512] {
            try writePNG(render(name, pixels: base), to: folder.appending(path: "icon_\(base)x\(base).png"))
            try writePNG(render(name, pixels: base * 2), to: folder.appending(path: "icon_\(base)x\(base)@2x.png"))
        }
        print("Wrote \(folder.path) (candidate \(name))")
    } else {
        print("usage: swift scripts/make-icon.swift --previews <dir> [--sheet <png>] | --iconset <dir> [--candidate a|b|c]")
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("make-icon: \(error.localizedDescription)\n".utf8))
    exit(1)
}
