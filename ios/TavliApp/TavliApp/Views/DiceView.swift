import SwiftUI
import TavliEngine

private typealias SColor = SwiftUI.Color

/// Design palette for the dice (from docs/design — the Caramel board).
private enum DiceStyle {
    static let ivory   = SColor(red: 245 / 255, green: 234 / 255, blue: 208 / 255) // #f5ead0
    static let pip     = SColor(red: 42 / 255, green: 20 / 255, blue: 8 / 255)     // #2a1408
    static let edge    = pip
    static let highlight = SColor.white.opacity(0.7)

    // Normalized pip positions (0…1), per the design's PIP_LAYOUTS.
    static func pips(_ value: Int) -> [CGPoint] {
        switch value {
        case 1: return [CGPoint(x: 0.5, y: 0.5)]
        case 2: return [CGPoint(x: 0.28, y: 0.28), CGPoint(x: 0.72, y: 0.72)]
        case 3: return [CGPoint(x: 0.28, y: 0.28), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.72, y: 0.72)]
        case 4: return [CGPoint(x: 0.28, y: 0.28), CGPoint(x: 0.72, y: 0.28),
                        CGPoint(x: 0.28, y: 0.72), CGPoint(x: 0.72, y: 0.72)]
        case 5: return [CGPoint(x: 0.28, y: 0.28), CGPoint(x: 0.72, y: 0.28), CGPoint(x: 0.5, y: 0.5),
                        CGPoint(x: 0.28, y: 0.72), CGPoint(x: 0.72, y: 0.72)]
        case 6: return [CGPoint(x: 0.28, y: 0.28), CGPoint(x: 0.72, y: 0.28),
                        CGPoint(x: 0.28, y: 0.5), CGPoint(x: 0.72, y: 0.5),
                        CGPoint(x: 0.28, y: 0.72), CGPoint(x: 0.72, y: 0.72)]
        default: return []
        }
    }
}

/// A single ivory die face. Pure: driven only by `value` and `isUsed`.
struct DieFace: View {
    let value: Int
    var isUsed: Bool = false
    var size: CGFloat = 56

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.107, style: .continuous)
                .fill(DiceStyle.ivory)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.107, style: .continuous)
                        .stroke(DiceStyle.edge, lineWidth: size * 0.0214)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.092, style: .continuous)
                        .inset(by: size * 0.018)
                        .stroke(DiceStyle.highlight, lineWidth: size * 0.009)
                )
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.45),
                        radius: size * 0.045, x: 0, y: size * 0.045)

            ForEach(Array(DiceStyle.pips(value).enumerated()), id: \.offset) { _, p in
                Circle()
                    .fill(DiceStyle.pip)
                    .frame(width: size * 0.14, height: size * 0.14)
                    .position(x: p.x * size, y: p.y * size)
            }
            .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .opacity(isUsed ? 0.4 : 1.0)
        .saturation(isUsed ? 0.0 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isUsed)
    }
}

/// A row of dice (2, or 4 for a pasch), with used dice greyed left-to-right.
/// Pure: takes explicit values + used count, so it renders any state in previews.
struct DiceRow: View {
    let values: [Int]
    let usedCount: Int
    var size: CGFloat = 56
    var spacing: CGFloat = 12

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(Array(values.enumerated()), id: \.offset) { idx, val in
                DieFace(value: val, isUsed: idx < usedCount, size: size)
            }
        }
    }
}

/// Live dice bound to a `GameSession`: renders the current roll, greys consumed
/// dice, and rolls on tap with a brief tumble animation.
struct DiceView: View {
    @ObservedObject var session: GameSession
    var size: CGFloat = 56

    @State private var tumbling = false
    @State private var spin: Double = 0

    /// A pasch shows four dice; otherwise the two rolled values.
    private var values: [Int] {
        let d = session.game.dice
        if d.isPasch { return Array(repeating: d.die1.value, count: 4) }
        return [d.die1.value, d.die2.value]
    }

    /// Each committed half-move consumes one die slot, left to right.
    private var usedCount: Int { session.moveBuilder.built.count }

    private var canRoll: Bool { session.phase == .awaitingRoll }

    var body: some View {
        DiceRow(values: values, usedCount: usedCount, size: size)
            .rotationEffect(.degrees(tumbling ? spin : 0))
            .scaleEffect(tumbling ? 0.9 : 1.0)
            .contentShape(Rectangle())
            .onTapGesture(perform: roll)
            .opacity(canRoll ? 1.0 : 0.95)
    }

    private func roll() {
        guard canRoll, !tumbling else { return }
        withAnimation(.easeInOut(duration: 0.09).repeatCount(4, autoreverses: false)) {
            spin += 360
            tumbling = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            tumbling = false
            session.roll()
        }
    }
}

/// Two steppers to enter specific dice, then apply them via the session.
/// Only active while the session is awaiting a roll.
struct ManualDiceControl: View {
    @ObservedObject var session: GameSession

    @State private var d1 = 1
    @State private var d2 = 1

    private var enabled: Bool { session.phase == .awaitingRoll }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                dieStepper("Die 1", value: $d1)
                dieStepper("Die 2", value: $d2)
            }
            Button("Set dice") {
                session.setManualDice(d1, d2)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!enabled)
        }
        .opacity(enabled ? 1.0 : 0.5)
    }

    private func dieStepper(_ label: String, value: Binding<Int>) -> some View {
        VStack(spacing: 6) {
            DieFace(value: value.wrappedValue, size: 40)
            Stepper(label, value: value, in: 1...6)
                .labelsHidden()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Previews

#Preview("Dice — states") {
    VStack(spacing: 28) {
        DiceRow(values: [3, 5], usedCount: 0)
        DiceRow(values: [3, 5], usedCount: 1)          // first die consumed
        DiceRow(values: [6, 6, 6, 6], usedCount: 0)    // pasch → four dice
        DiceRow(values: [6, 6, 6, 6], usedCount: 2)    // pasch, two consumed
        DiceRow(values: [1, 2], usedCount: 2)          // all consumed
    }
    .padding(40)
    .background(SColor(red: 138 / 255, green: 74 / 255, blue: 34 / 255))
}

#Preview("Manual control") {
    ManualDiceControl(session: GameSession())
        .padding(40)
}
