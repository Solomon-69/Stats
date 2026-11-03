// NumberDrum.swift. Preset chips plus one scroll drum for a number (taken from Memo, same look).
import SwiftUI

/// Preset chips plus one scroll drum, for counts like days, items and megabytes.
struct NumberChipDrum: View {
    let title: String
    let value: Int
    let values: [Int]
    let presets: [Int]
    var tint: Color = .accentColor
    let label: (Int) -> String
    let short: (Int) -> String
    let onChange: (Int) -> Void

    private var index: Int { values.firstIndex(of: value) ?? values.indices.min(by: { abs(values[$0] - value) < abs(values[$1] - value) }) ?? 0 }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(label(value)).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(tint)
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: value)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), alignment: .leading, spacing: 6) {
                    ForEach(presets, id: \.self) { p in
                        Chip(text: label(p), selected: p == value, tint: tint) {
                            guard p != value else { return }
                            DrumTick.play()
                            onChange(p)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            DrumWheel(count: values.count, selection: index, wraps: false,
                      text: { short(values[$0]) }, accessibilityName: title, width: 50) { onChange(values[$0]) }
                .frame(width: 58)
                .padding(.horizontal, 4)
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04))
                        RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(0.14))
                            .frame(height: DrumWheel.rowHeight).padding(.horizontal, 4)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        }
    }
}

private struct Chip: View {
    let text: String
    let selected: Bool
    let tint: Color
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: selected ? .semibold : .medium)).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.8)
            .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.85))
            .frame(maxWidth: .infinity).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? tint : Color.primary.opacity(hover ? 0.10 : 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(selected ? Color.clear : Color.primary.opacity(0.10), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture(perform: action)
            .onHover { hover = $0 }
            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: selected)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { action() }
    }
}
