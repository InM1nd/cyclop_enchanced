import SwiftUI

/// Full-screen ASCII idle. Style + accent come from `IdleScreenSettings`.
struct IdleScreenView: View {
    @ObservedObject var sessions: ProcessMonitorStore
    @ObservedObject var settings: IdleScreenSettings
    @ObservedObject var session: IdleScreenSession

    @StateObject private var life = LifeBoard()

    private static let frameInterval = 1.0 / 30.0
    private static let matrixGlyphs = Array("ｦｧｨｩｪｫｬｭｮｯｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜﾝ012345789Z:.=*+-<>¦｜")
    private static let starGlyphs = Array(".·+*✦✧⋆")
    private static let logSnippets = [
        "thinking…", "tool: read", "tool: edit", "tool: bash",
        "compiling", "awaiting", "patch ok", "spawned",
        "retry 1/3", "context +2k", "streaming", "done",
        "queued", "lint clean", "tests 12/12", "diff ready",
        "merge base", "fetching", "summarising", "planning",
    ]

    var body: some View {
        // Open/close is AppKit window alpha only. Scaling this Canvas during
        // the transition forced Portrait/Matrix to redraw every spring tick.
        ZStack {
            Color.black
            if session.isLive {
                TimelineView(.animation(minimumInterval: Self.frameInterval)) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let accent = settings.accent
                    ZStack {
                        Canvas { context, size in
                            switch settings.style {
                            case .agents:
                                drawAgents(context: context, size: size, t: t, accent: accent)
                            case .matrix:
                                drawMatrix(context: context, size: size, t: t, accent: accent)
                            case .life:
                                life.sync(t: t, size: size)
                                drawLife(context: context, size: size, accent: accent)
                            case .stars:
                                drawStars(context: context, size: size, t: t, accent: accent)
                            case .portrait:
                                drawPortrait(context: context, size: size, t: t, accent: accent)
                            }
                        }
                        hint(
                            accent: accent.opacity(0.45 + 0.25 * sin(t * 2.0)),
                            portraitResting: settings.style == .portrait ? portraitResting(at: t) : nil
                        )
                    }
                }
            }
        }
        .ignoresSafeArea()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    // MARK: - Agents

    private func drawAgents(context: GraphicsContext, size: CGSize, t: TimeInterval, accent: Color) {
        let sideW: CGFloat = 150
        let logX: CGFloat = sideW + 20
        let lineH: CGFloat = 18
        let speed: Double = 32 // px/s — one line every lineH/speed, in lockstep with content
        let rows = max(Int(size.height / lineH) + 2, 1)
        // Pixel offset and line identity share the same clock, so wrapping a
        // row off the top lands the next line in the same place — no hitch.
        let offset = t * speed
        let lineHDouble = Double(lineH)
        let firstLine = Int(floor(offset / lineHDouble))
        let scroll = offset - Double(firstLine) * lineHDouble

        drawAgentSidebar(context: context, size: size, sideW: sideW, t: t, accent: accent)

        for row in 0..<rows {
            let seed = UInt64(bitPattern: Int64(firstLine &+ row)) &* 2_654_435_761
            let snippet = Self.logSnippets[Int(seed % UInt64(Self.logSnippets.count))]
            let agent = ["claude", "codex ", "cursor"][Int(seed % 3)]
            let tag = ["run", "ok", "wait", "tool"][Int((seed >> 3) % 4)]
            let stamp = String(format: "%02d:%02d.%02d", Int(seed % 24), Int((seed >> 5) % 60), Int((seed >> 11) % 100))
            let line = "[\(tag)] \(agent)  \(snippet)  ·  \(stamp)"
            let y = CGFloat(row) * lineH - CGFloat(scroll)
            let fade = abs(y - size.height * 0.5) / (size.height * 0.55)
            let alpha = max(0.08, 0.58 - fade * 0.5)
            context.draw(
                Text(line)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(accent.opacity(alpha)),
                at: CGPoint(x: logX, y: y),
                anchor: .topLeading
            )
        }

        // Rising “toast” cards — brief status pops. Copy is keyed to the
        // cycle so it does not rewrite mid-flight.
        for i in 0..<4 {
            let cycle = 4.2 + Double(i) * 0.7
            let clock = t * 0.55 + Double(i) * 1.3
            let cycleIndex = Int(floor(clock / cycle))
            let local = clock - Double(cycleIndex) * cycle
            guard local < 2.2 else { continue }
            let rise = local / 2.2
            let msgSeed = UInt64(bitPattern: Int64(cycleIndex &* 31 &+ i &* 17))
            let msg = Self.logSnippets[Int(msgSeed % UInt64(Self.logSnippets.count))]
            let agent = ["claude", "codex", "cursor"][i % 3]
            let y = size.height * 0.78 - CGFloat(rise) * size.height * 0.35
            let alpha = Double(1.0 - rise) * 0.85
            let card = "✦ \(agent): \(msg)"
            context.draw(
                Text(card)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(accent.opacity(alpha)),
                at: CGPoint(x: size.width * 0.55, y: y),
                anchor: .leading
            )
        }
    }

    private func drawAgentSidebar(
        context: GraphicsContext,
        size: CGSize,
        sideW: CGFloat,
        t: TimeInterval,
        accent: Color
    ) {
        let agents: [(String, Int)] = [
            ("claude", sessions.claudeCount),
            ("codex", sessions.codexCount),
            ("cursor", sessions.cursorCount),
        ]
        var y: CGFloat = 36
        context.draw(
            Text("sessions")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(accent.opacity(0.55)),
            at: CGPoint(x: 24, y: y),
            anchor: .topLeading
        )
        y += 28

        for (index, item) in agents.enumerated() {
            let (name, count) = item
            context.draw(
                Text("\(name)  \(count)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(accent.opacity(0.8)),
                at: CGPoint(x: 24, y: y),
                anchor: .topLeading
            )
            y += 18
            // Animated sparkline / activity bar.
            let barW = sideW - 36
            let cells = 12
            for c in 0..<cells {
                let wave = 0.25 + 0.75 * abs(sin(t * (1.6 + Double(index) * 0.3) + Double(c) * 0.45 + Double(index)))
                let h = max(0.15, wave) * (count > 0 ? 1.0 : 0.35)
                let ch = h > 0.75 ? "█" : (h > 0.45 ? "▓" : (h > 0.25 ? "▒" : "░"))
                context.draw(
                    Text(ch)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(accent.opacity(0.25 + h * 0.7)),
                    at: CGPoint(x: 24 + CGFloat(c) * (barW / CGFloat(cells)), y: y),
                    anchor: .topLeading
                )
            }
            y += 34
        }

        // Vertical rule separating sidebar from the log.
        for row in stride(from: 20, to: Int(size.height) - 20, by: 14) {
            context.draw(
                Text("│")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(accent.opacity(0.18)),
                at: CGPoint(x: sideW, y: CGFloat(row)),
                anchor: .center
            )
        }
    }

    // MARK: - Matrix

    private func drawMatrix(context: GraphicsContext, size: CGSize, t: TimeInterval, accent: Color) {
        // Slightly coarser than the old 13 pt grid — fewer Text draws per frame
        // on large displays, which was enough to freeze the main thread.
        let cell: CGFloat = 16
        let cols = max(Int(size.width / cell), 1)
        let rows = max(Int(size.height / cell), 1)
        let glyphs = Self.matrixGlyphs
        let glyphCount = UInt64(glyphs.count)
        let tick = UInt64(max(0, t * 8).rounded(.down))

        for col in 0..<cols {
            let seed = UInt64(col) &* 2_654_435_761
            let speed = 14.0 + Double(seed % 22)
            let length = 10 + Int(seed % 12)
            let head = (t * speed + Double(seed % 2000) * 0.01)
                .truncatingRemainder(dividingBy: Double(rows + length))

            for i in 0..<length {
                let rowF = head - Double(i)
                // Keep row ≥ 0 before any UInt64(...) — converting a negative
                // Int traps and was crashing Matrix on the first off-screen cell.
                guard rowF >= 0, rowF < Double(rows) else { continue }
                let row = Int(rowF)
                let idx = Int((seed &+ UInt64(row &* 31) &+ tick) % glyphCount)
                let ch = String(glyphs[idx])
                let color: Color
                if i == 0 {
                    color = Color.white.opacity(0.95)
                } else if i == 1 {
                    color = accent
                } else {
                    color = accent.opacity(max(0.05, 0.75 - Double(i) * 0.055))
                }
                context.draw(
                    Text(ch)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(color),
                    at: CGPoint(x: CGFloat(col) * cell + 1, y: CGFloat(rowF) * cell),
                    anchor: .topLeading
                )
            }
        }
    }

    // MARK: - Life (Conway)

    private func drawLife(context: GraphicsContext, size: CGSize, accent: Color) {
        let cell = life.cell
        for row in 0..<life.rows {
            for col in 0..<life.cols {
                guard life.alive(col: col, row: row) else { continue }
                let age = life.age(col: col, row: row)
                let ch = age > 4 ? "█" : (age > 2 ? "▓" : (age > 1 ? "▒" : "░"))
                let alpha = min(1.0, 0.45 + Double(age) * 0.12)
                context.draw(
                    Text(ch)
                        .font(.system(size: cell - 2, weight: .medium, design: .monospaced))
                        .foregroundColor(accent.opacity(alpha)),
                    at: CGPoint(x: CGFloat(col) * cell, y: CGFloat(row) * cell),
                    anchor: .topLeading
                )
            }
        }
    }

    // MARK: - Stars

    private func drawStars(context: GraphicsContext, size: CGSize, t: TimeInterval, accent: Color) {
        let count = 160
        let glyphs = Self.starGlyphs
        for i in 0..<count {
            // Independent hashes so X/Y don't share the same modulus lattice.
            let hx = Self.starHash(UInt64(i) &* 0x9E37_79B9_7F4A_7C15 &+ 0xA5A5)
            let hy = Self.starHash(UInt64(i) &* 0xBF58_476D_1CE4_E5B9 &+ 0xC3C3)
            let hs = Self.starHash(UInt64(i) &* 0x94D0_49BB_1331_11EB &+ 0x1111)
            let x = Double(hx % 10_007) / 10_007.0 * size.width
            let y = Double(hy % 9_991) / 9_991.0 * size.height
            let rate = 0.22 + Double(hs % 29) * 0.04
            let phase = Double(hs % 1_373) * 0.01
            let wave = 0.5 + 0.5 * sin(t * rate + phase)
            let twinkle = 0.06 + 0.84 * (wave * wave)
            let idx = Int(hx % UInt64(glyphs.count))
            let fontSize = CGFloat(7 + Int(hy % 12))
            context.draw(
                Text(String(glyphs[idx]))
                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                    .foregroundColor(accent.opacity(twinkle)),
                at: CGPoint(x: x, y: y),
                anchor: .center
            )
        }

        for s in 0..<4 {
            let cycle = 3.2 + Double(s) * 1.4 + Double(s % 2) * 0.7
            let local = (t * (0.9 + Double(s) * 0.12) + Double(s) * 1.9)
                .truncatingRemainder(dividingBy: cycle)
            guard local < 0.7 + Double(s % 3) * 0.15 else { continue }
            let progress = local / (0.7 + Double(s % 3) * 0.15)
            let angle = -0.35 - Double(s) * 0.22 + sin(Double(s) * 2.1) * 0.25
            let startX = size.width * (0.05 + CGFloat((s * 29) % 70) / 100)
            let startY = size.height * (0.08 + CGFloat((s * 37) % 55) / 100)
            let len = size.width * (0.35 + CGFloat(s % 3) * 0.12)
            let x = startX + CGFloat(progress) * len * CGFloat(cos(angle))
            let y = startY + CGFloat(progress) * len * CGFloat(sin(angle))
            let fade = 1.0 - progress
            for k in 0..<10 {
                let back = CGFloat(k) * 8
                context.draw(
                    Text(k == 0 ? "✦" : "·")
                        .font(.system(size: k == 0 ? 13 : 8, weight: .medium, design: .monospaced))
                        .foregroundColor(accent.opacity(fade * (k == 0 ? 0.95 : max(0.05, 0.4 - Double(k) * 0.035)))),
                    at: CGPoint(
                        x: x - back * CGFloat(cos(angle)),
                        y: y - back * CGFloat(sin(angle))
                    ),
                    anchor: .center
                )
            }
        }

        drawMarswalkRocket(context: context, size: size, t: t, accent: accent)
    }

    private func drawMarswalkRocket(
        context: GraphicsContext,
        size: CGSize,
        t: TimeInterval,
        accent: Color
    ) {
        let titlePulse = 0.72 + 0.28 * (0.5 + 0.5 * sin(t * 1.4))
        drawPixelMarswalk(
            context: context,
            center: CGPoint(x: size.width * 0.5, y: size.height * 0.5),
            letterColor: Color.white.opacity(titlePulse),
            dotColor: accent.opacity(titlePulse)
        )

        // Bottom-left → top-right. Rocket art points UP; rotate to match velocity.
        let pathDX = 1.16 * size.width
        let pathDY = -0.78 * size.height
        let heading = atan2(pathDY, pathDX) // screen space (y down)
        let cycle = 9.5
        let local = t.truncatingRemainder(dividingBy: cycle)
        guard local < 7.2 else { return }
        let progress = local / 7.2
        let rocketX = size.width * (-0.08 + CGFloat(progress) * 1.16)
        let rocketY = size.height * (0.82 - CGFloat(progress) * 0.78) + sin(t * 5.5) * 3

        // Local art: nose at top. Rotate so local -Y aligns with heading.
        let rotation = Angle(radians: heading + .pi / 2)

        context.drawLayer { ctx in
            ctx.translateBy(x: rocketX, y: rocketY)
            ctx.rotate(by: rotation)

            // Denser sprite: nose cone, windows, banding, fins, thruster bell.
            let body: [(String, Color)] = [
                ("     /\\     ", accent.opacity(0.95)),
                ("    //\\\\    ", accent.opacity(0.9)),
                ("   |····|   ", Color.white.opacity(0.85)),
                ("   |[==]|   ", accent.opacity(0.95)),
                ("   | ## |   ", accent.opacity(0.9)),
                ("   |[··]|   ", Color.white.opacity(0.8)),
                ("   |====|   ", accent.opacity(0.95)),
                ("  /|    |\\  ", accent.opacity(0.9)),
                (" /_|____|_\\ ", accent.opacity(0.85)),
                ("    /||\\    ", accent.opacity(0.75)),
            ]
            let lineH: CGFloat = 11
            let bodyTop = -CGFloat(body.count) * lineH * 0.55
            for (i, item) in body.enumerated() {
                ctx.draw(
                    Text(item.0)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(item.1),
                    at: CGPoint(x: 0, y: bodyTop + CGFloat(i) * lineH),
                    anchor: .center
                )
            }

            // Exhaust plume — multi-column flicker behind the thruster.
            let flameBaseY = bodyTop + CGFloat(body.count) * lineH - 2
            for k in 0..<12 {
                let trail = CGFloat(k) * 7
                let flicker = 0.4 + 0.6 * sin(t * 22 + Double(k) * 1.3)
                let ch: Character
                if k < 2 { ch = "#" }
                else if k < 5 { ch = "*" }
                else if k < 8 { ch = "+" }
                else { ch = "·" }
                for side in [-1.0, 0.0, 1.0] as [Double] {
                    let spread = side * (2.5 + Double(k) * 0.7) + sin(t * 16 + Double(k) + side) * 1.2
                    ctx.draw(
                        Text(String(ch))
                            .font(.system(size: CGFloat(11 - k / 3), weight: .medium, design: .monospaced))
                            .foregroundColor(accent.opacity((0.8 - Double(k) * 0.055) * flicker)),
                        at: CGPoint(x: spread, y: flameBaseY + trail),
                        anchor: .center
                    )
                }
            }
        }
    }

    private static func starHash(_ value: UInt64) -> UInt64 {
        var x = value
        x &+= 0x9E37_79B9_7F4A_7C15
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        return x ^ (x >> 31)
    }

    /// 5×7 block font for `marswalk.` — letters white, square period in accent.
    private func drawPixelMarswalk(
        context: GraphicsContext,
        center: CGPoint,
        letterColor: Color,
        dotColor: Color
    ) {
        // Rows top→bottom; 1 = pixel on. Period is a 2×2 square in the glyph box.
        let glyphs: [Character: [String]] = [
            "m": [
                "10001",
                "11011",
                "10101",
                "10001",
                "10001",
                "10001",
                "10001",
            ],
            "a": [
                "01110",
                "10001",
                "10001",
                "11111",
                "10001",
                "10001",
                "10001",
            ],
            "r": [
                "11110",
                "10001",
                "10001",
                "11110",
                "10100",
                "10010",
                "10001",
            ],
            "s": [
                "01111",
                "10000",
                "10000",
                "01110",
                "00001",
                "00001",
                "11110",
            ],
            "w": [
                "10001",
                "10001",
                "10001",
                "10101",
                "10101",
                "11011",
                "10001",
            ],
            "l": [
                "10000",
                "10000",
                "10000",
                "10000",
                "10000",
                "10000",
                "11111",
            ],
            "k": [
                "10001",
                "10010",
                "10100",
                "11000",
                "10100",
                "10010",
                "10001",
            ],
            ".": [
                "00000",
                "00000",
                "00000",
                "00000",
                "00000",
                "01100",
                "01100",
            ],
        ]

        let text = Array("marswalk.")
        let px: CGFloat = 4
        let gap: CGFloat = 3
        let letterW = 5 * px
        let letterH = 7 * px
        let strideX = letterW + gap
        let totalW = CGFloat(text.count) * letterW + CGFloat(text.count - 1) * gap
        let originX = center.x - totalW * 0.5
        let originY = center.y - letterH * 0.5

        for (index, ch) in text.enumerated() {
            guard let rows = glyphs[ch] else { continue }
            let fill = ch == "." ? dotColor : letterColor
            let ox = originX + CGFloat(index) * strideX
            for (ry, row) in rows.enumerated() {
                for (cx, bit) in row.enumerated() where bit == "1" {
                    let rect = CGRect(
                        x: ox + CGFloat(cx) * px,
                        y: originY + CGFloat(ry) * px,
                        width: px,
                        height: px
                    )
                    context.fill(Path(rect), with: .color(fill))
                }
            }
        }
    }

    // MARK: - Portrait (animated Cyclop eye)

    private func drawPortrait(context: GraphicsContext, size: CGSize, t: TimeInterval, accent: Color) {
        let cell: CGFloat = 11
        let cols = max(Int(size.width / cell), 1)
        let rows = max(Int(size.height / cell), 1)
        let cx = Double(cols - 1) / 2
        let cy = Double(rows - 1) / 2

        // Gaze — slow wander with occasional quicker saccades.
        let saccade = sin(t * 0.17) * sin(t * 0.41)
        let lookX = sin(t * 0.45) * 0.55 + saccade * 0.35
        let lookY = cos(t * 0.33) * 0.28 + sin(t * 0.9) * 0.08

        // Blink envelope: mostly open, soft close, brief hold, reopen.
        // Occasional double-blink every ~11s.
        let blink: Double = {
            let cycle = t.truncatingRemainder(dividingBy: 5.0)
            let primary: Double
            if cycle > 4.35 && cycle < 4.72 {
                let u = (cycle - 4.35) / 0.37
                primary = u < 0.5 ? u * 2 : (1 - u) * 2
            } else {
                primary = 0
            }
            let dbl = t.truncatingRemainder(dividingBy: 11.0)
            var second = 0.0
            if dbl > 10.35 && dbl < 10.55 {
                let u = (dbl - 10.35) / 0.2
                second = u < 0.5 ? u * 2 : (1 - u) * 2
            }
            return min(1, max(primary, second))
        }()
        let open = 1.0 - blink

        // Eye geometry in cell units (almond). Pupil stays on the old absolute
        // scale so growing the lids/iris does not bloat the white core.
        let span = min(Double(cols), Double(rows))
        let eyeRX = span * 0.40
        // Flatter than a circle even wide open — an eye's aperture is a slit
        // that opens, not a disc, and 0.92 (the old ratio here) read as one.
        let eyeRY = eyeRX * (0.12 + 0.48 * open) // lids squeeze height while blinking
        let irisR = eyeRX * 0.44
        let pupilR = span * 0.28 * 0.52 * (0.38 + 0.04 * sin(t * 1.7))
        let irisCX = cx + lookX * irisR * 0.55
        let irisCY = cy + lookY * irisR * 0.35
        // Lid stroke width in almond-normalized space (was ~0.12 — too thin).
        let rimBand = 0.22

        for row in 0..<rows {
            for col in 0..<cols {
                let x = Double(col)
                let y = Double(row)
                let dx = (x - cx) / max(eyeRX, 0.01)
                // A circle's rim is the same distance from centre all the way
                // round; an eye's corners come to a point. The lid height
                // tapers to zero at dx = ±1 (parabolic, same curve the app
                // icon's lens uses) instead of staying constant like a
                // circle's — that taper is what puts the point at the corners.
                let lidHalfHeight = eyeRY * max(1 - dx * dx, 0)
                let dy = (y - cy) / max(lidHalfHeight, 0.02)
                let almond = max(dx * dx, dy * dy)

                // Soft ambient dust outside the eye.
                if almond > 1.15 {
                    let field = hypot(x - cx, y - cy) / max(Double(cols), 1)
                    guard field < 0.62 else { continue }
                    let twinkle = 0.04 + 0.08 * (0.5 + 0.5 * sin(t * 1.2 + x * 0.3 + y * 0.2))
                    if Int(x + y * 3 + t * 2) % 7 == 0 {
                        context.draw(
                            Text("·")
                                .font(.system(size: cell - 2, weight: .medium, design: .monospaced))
                                .foregroundColor(accent.opacity(twinkle)),
                            at: CGPoint(x: CGFloat(col) * cell, y: CGFloat(row) * cell),
                            anchor: .topLeading
                        )
                    }
                    continue
                }

                guard almond <= 1.02 else { continue }

                // Fully closed lids — a thicker seam so the shut eye still reads.
                if open < 0.08 {
                    let onSeam = abs(y - cy) < 1.35 && abs(dx) < 0.97
                    if onSeam {
                        let seamCh: Character = abs(y - cy) < 0.55
                            ? (abs(dx) > 0.78 ? "." : "═")
                            : (abs(dx) > 0.78 ? "·" : "─")
                        context.draw(
                            Text(String(seamCh))
                                .font(.system(size: cell - 1, weight: .medium, design: .monospaced))
                                .foregroundColor(accent.opacity(0.8)),
                            at: CGPoint(x: CGFloat(col) * cell, y: CGFloat(row) * cell),
                            anchor: .topLeading
                        )
                    }
                    continue
                }

                let idx = irisCX
                let idy = irisCY
                let irisDist = hypot(x - idx, y - idy) / max(irisR, 0.01)
                let pupilDist = hypot(x - idx, y - idy) / max(pupilR, 0.01)

                // Specular glint sits opposite the gaze.
                let glintX = idx - lookX * irisR * 0.35 - irisR * 0.22
                let glintY = idy - lookY * irisR * 0.25 - irisR * 0.28
                let glint = hypot(x - glintX, y - glintY) / max(irisR * 0.18, 0.01)

                let edge = almond // 0 center → 1 rim
                var ch: Character = " "
                var color = accent.opacity(0.2)

                if pupilDist < 1 {
                    ch = pupilDist < 0.45 ? "@" : "0"
                    color = Color.white.opacity(0.92 - pupilDist * 0.15)
                } else if glint < 1 {
                    ch = glint < 0.45 ? "*" : "·"
                    color = Color.white.opacity(0.85 - glint * 0.3)
                } else if irisDist < 1 {
                    // Iris rings — denser toward pupil.
                    let ring = irisDist
                    if ring < 0.35 {
                        ch = "▓"
                        color = accent.opacity(0.95)
                    } else if ring < 0.6 {
                        ch = "▒"
                        color = accent.opacity(0.8)
                    } else if ring < 0.82 {
                        ch = "░"
                        color = accent.opacity(0.65)
                    } else {
                        ch = "·"
                        color = accent.opacity(0.55)
                    }
                    // Radial striations.
                    let angle = atan2(y - idy, x - idx)
                    if sin(angle * 9 + t * 0.4) > 0.7, ring > 0.35, ring < 0.85 {
                        ch = "|"
                        color = accent.opacity(0.75)
                    }
                } else {
                    // Sclera + thicker lid stroke. Rim used to be a 1-cell hairline
                    // (`edge > 0.88`); widen it and stack heavier glyphs toward
                    // the outer edge so the almond reads as a drawn outline.
                    let lidShade = abs(dy)
                    let rimStart = 1.0 - rimBand
                    if edge > rimStart {
                        let depth = (edge - rimStart) / rimBand // 0 inner → 1 outer
                        if abs(dx) > 0.82 {
                            ch = depth > 0.45 ? "," : "."
                        } else if depth > 0.62 {
                            ch = dy < 0 ? "═" : "═"
                        } else if depth > 0.32 {
                            ch = dy < 0 ? "‾" : "_"
                        } else {
                            ch = "─"
                        }
                        color = accent.opacity(0.55 + depth * 0.35)
                    } else if lidShade > 0.62 {
                        ch = "·"
                        color = accent.opacity(0.28)
                    } else {
                        // faint fill so the almond reads as a surface
                        if Int(x * 3 + y) % 4 == 0 {
                            ch = "·"
                            color = accent.opacity(0.14)
                        } else {
                            continue
                        }
                    }
                }

                // Upper/lower lid curtains during blink — hide iris under closing lids.
                let lidCover = (1 - open) * eyeRY * 1.15
                if abs(y - cy) > eyeRY - lidCover, open < 0.95, irisDist < 1.05 {
                    ch = abs(dx) > 0.85 ? "." : "═"
                    color = accent.opacity(0.55 + (1 - open) * 0.25)
                }

                context.draw(
                    Text(String(ch))
                        .font(.system(size: cell - 1, weight: .medium, design: .monospaced))
                        .foregroundColor(color),
                    at: CGPoint(x: CGFloat(col) * cell, y: CGFloat(row) * cell),
                    anchor: .topLeading
                )
            }
        }
    }

    /// 0…1 while the lids are mostly shut — drives caption crossfade.
    private func portraitResting(at t: TimeInterval) -> Double {
        let cycle = t.truncatingRemainder(dividingBy: 5.0)
        let blink: Double
        if cycle > 4.35 && cycle < 4.72 {
            let u = (cycle - 4.35) / 0.37
            blink = u < 0.5 ? u * 2 : (1 - u) * 2
        } else {
            blink = 0
        }
        let dbl = t.truncatingRemainder(dividingBy: 11.0)
        var second = 0.0
        if dbl > 10.35 && dbl < 10.55 {
            let u = (dbl - 10.35) / 0.2
            second = u < 0.5 ? u * 2 : (1 - u) * 2
        }
        let amount = min(1, max(blink, second))
        return max(0, min(1, (amount - 0.55) / 0.45))
    }

    // MARK: - Chrome

    private func hint(accent: Color, portraitResting: Double? = nil) -> some View {
        VStack(spacing: 6) {
            if let resting = portraitResting {
                // Both strings stay laid out — swapping length was making the
                // caption jump on every blink.
                ZStack {
                    Text("cyclop · watching agents")
                        .opacity(1 - resting)
                    Text("cyclop · resting")
                        .opacity(resting)
                }
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(accent.opacity(0.85))
            }
            Text("esc / click — leave")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(accent.opacity(portraitResting == nil ? 1 : 0.7))
        }
        .padding(.bottom, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

// MARK: - Conway board

@MainActor
final class LifeBoard: ObservableObject {
    private(set) var cols = 0
    private(set) var rows = 0
    private(set) var cell: CGFloat = 12
    private var cells: [UInt8] = []
    private var ages: [UInt8] = []
    private var lastGen = -1

    func alive(col: Int, row: Int) -> Bool {
        cells[row * cols + col] > 0
    }

    func age(col: Int, row: Int) -> Int {
        Int(ages[row * cols + col])
    }

    func sync(t: TimeInterval, size: CGSize) {
        let nextCell: CGFloat = 12
        let nextCols = max(Int(size.width / nextCell), 10)
        let nextRows = max(Int(size.height / nextCell), 10)
        if nextCols != cols || nextRows != rows {
            cols = nextCols
            rows = nextRows
            cell = nextCell
            randomize()
            lastGen = Int(t * 4)
        }
        let gen = Int(t * 4)
        var steps = gen - lastGen
        if steps > 8 { steps = 8 }
        if steps > 0 {
            for _ in 0..<steps { tick() }
            lastGen = gen
        }
    }

    private func randomize() {
        let total = cols * rows
        cells = (0..<total).map { _ in UInt8.random(in: 0...4) == 0 ? 1 : 0 }
        ages = cells.map { $0 }
    }

    private func tick() {
        var next = cells
        var nextAges = ages
        for row in 0..<rows {
            for col in 0..<cols {
                var n = 0
                for dy in -1...1 {
                    for dx in -1...1 where !(dx == 0 && dy == 0) {
                        let rr = (row + dy + rows) % rows
                        let cc = (col + dx + cols) % cols
                        n += Int(cells[rr * cols + cc])
                    }
                }
                let i = row * cols + col
                let alive = cells[i] > 0
                let stay = alive && (n == 2 || n == 3)
                let born = !alive && n == 3
                if stay || born {
                    next[i] = 1
                    nextAges[i] = min(ages[i] &+ 1, 9)
                } else {
                    next[i] = 0
                    nextAges[i] = 0
                }
            }
        }
        cells = next
        ages = nextAges
    }
}
