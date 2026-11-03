// Charts.swift. Small live charts. The line glides left between samples so it never jumps.
import SwiftUI

struct Series {
    var values: [Double]
    var tint: Color
    var dashed = false
}

/// Scrolling line chart. `max` fixes the top (1 for percentages); nil scales to the data.
/// The line is drawn once per sample and slides one step left at a constant speed until the next sample. Nothing runs while the panel is closed.
struct LiveChart: View {
    @ObservedObject var monitor: Monitor
    let series: [Series]
    var max: Double? = 1
    var slots = 30
    var fill = true
    var lineWidth: CGFloat = 1.6
    @State private var shift: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { g in
            let step = g.size.width / CGFloat(slots - 1)
            Canvas { ctx, size in
                let top = max ?? Swift.max(series.flatMap(\.values).max() ?? 1, 0.0001) * 1.15
                for s in series { draw(s, top: top, step: step, ctx: &ctx, size: size) }
            }
            .frame(width: g.size.width + step, height: g.size.height)
            .drawingGroup()
            .offset(x: reduceMotion ? -step : shift)
            .frame(width: g.size.width, height: g.size.height, alignment: .leading)
            .clipped()
            .onAppear { shift = -step }
            .onChange(of: monitor.sampleAt) { _, _ in
                guard !reduceMotion else { return }
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { shift = 0 }
                // The line slides at a steady speed for the whole interval, so the next sample arrives just as it lands: no stepping.
                withAnimation(.linear(duration: monitor.interval)) { shift = -step }
            }
        }
    }

    private func draw(_ s: Series, top: Double, step: CGFloat, ctx: inout GraphicsContext, size: CGSize) {
        var v = Array(s.values.suffix(slots + 2))
        guard let first = v.first else { return }
        // Not enough history yet: extend the oldest value to the left so the line always fills the whole graph.
        if v.count < slots + 2 { v.insert(contentsOf: Array(repeating: first, count: slots + 2 - v.count), at: 0) }
        let n = v.count
        func pt(_ i: Int) -> CGPoint {
            CGPoint(x: size.width - CGFloat(n - 1 - i) * step,
                    y: size.height - CGFloat(Swift.min(1, v[i] / top)) * (size.height - 2) - 1)
        }
        var line = Path()
        line.move(to: pt(0))
        for i in 1..<n {
            let a = pt(i - 1), b = pt(i), mid = (a.x + b.x) / 2
            line.addCurve(to: b, control1: CGPoint(x: mid, y: a.y), control2: CGPoint(x: mid, y: b.y))
        }
        if fill {
            var area = line
            area.addLine(to: CGPoint(x: pt(n - 1).x, y: size.height)); area.addLine(to: CGPoint(x: pt(0).x, y: size.height)); area.closeSubpath()
            ctx.fill(area, with: .linearGradient(Gradient(colors: [s.tint.opacity(0.28), s.tint.opacity(0.02)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        }
        ctx.stroke(line, with: .color(s.tint), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round,
                                                                   dash: s.dashed ? [3, 3] : []))
    }
}

/// A flat bar split into named parts (e.g. app, system, free).
struct SegmentBar: View {
    struct Part: Identifiable { let id = UUID(); var label: String; var value: Double; var tint: Color }
    let parts: [Part]
    var height: CGFloat = 8
    var body: some View {
        GeometryReader { g in
            let total = Swift.max(parts.reduce(0) { $0 + $1.value }, 0.0001)
            HStack(spacing: 1.5) {
                ForEach(parts) { p in
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(p.tint)
                        .frame(width: Swift.max(0, g.size.width * CGFloat(p.value / total) - 1.5))
                }
            }
            .frame(width: g.size.width, alignment: .leading)
        }
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Pal.box))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .animation(.spring(duration: 0.5, bounce: 0.1), value: parts.map(\.value))
    }
}

struct Legend: View {
    let parts: [SegmentBar.Part]
    let value: (SegmentBar.Part) -> String
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 4) {
            ForEach(parts) { p in
                HStack(spacing: 5) {
                    Circle().fill(p.tint).frame(width: 7, height: 7)
                    Text(p.label).font(.mono(10.5)).foregroundStyle(Pal.mute)
                    Text(value(p)).font(.mono(10.5, .medium)).foregroundStyle(Pal.ink)
                }
            }
        }
    }
}

/// Thin progress bar.
struct MiniBar: View {
    let value: Double
    var tint: Color = Pal.accent
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Pal.box)
                Capsule().fill(tint).frame(width: Swift.max(height, g.size.width * CGFloat(Swift.min(1, Swift.max(0, value)))))
            }
        }
        .frame(height: height)
        .animation(.spring(duration: 0.5, bounce: 0.1), value: value)
    }
}
