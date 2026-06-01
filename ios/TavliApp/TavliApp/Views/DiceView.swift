import SwiftUI
import BoardGeometry
import TavliEngine

private typealias SColor = SwiftUI.Color

/// Which displayed dice have been consumed, matched by the die actually used
/// (not by left-to-right position). The engine has no bear-off overshoot, so a
/// built half-move's die value is exactly its signed point delta. Returns flags
/// parallel to `values`; duplicate values (a pasch) consume the first free slot.
private func usedDiceFlags(values: [Int], built: [HalfMove]) -> [Bool] {
    var flags = [Bool](repeating: false, count: values.count)
    for hm in built {
        let used = hm.color.isWhite
            ? hm.to.position - hm.from.position
            : hm.from.position - hm.to.position
        if let idx = values.indices.first(where: { !flags[$0] && values[$0] == used }) {
            flags[idx] = true
        }
    }
    return flags
}

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

/// A single ivory die face. Pure: driven only by `value`, `isUsed`, and `isHighlighted`.
struct DieFace: View {
    let value: Int
    var isUsed: Bool = false
    var isHighlighted: Bool = false
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
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.107, style: .continuous)
                        .stroke(CaramelPalette.hl, lineWidth: size * 0.057)
                        .opacity(isHighlighted ? 1.0 : 0)
                )

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
        .animation(.easeInOut(duration: 0.2), value: isHighlighted)
    }
}

/// A row of dice (2, or 4 for a pasch). Pure: takes explicit values + a parallel
/// per-die `used` flag array, so it renders any state in previews and greys the
/// die actually consumed (not merely the leftmost).
struct DiceRow: View {
    let values: [Int]
    let used: [Bool]
    var size: CGFloat = 56
    var spacing: CGFloat = 12

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(Array(values.enumerated()), id: \.offset) { idx, val in
                DieFace(value: val, isUsed: idx < used.count && used[idx], size: size)
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

    /// Per-die consumed flags, matched to the die actually played.
    private var used: [Bool] { usedDiceFlags(values: values, built: session.moveBuilder.built) }

    private var canRoll: Bool { session.phase == .awaitingRoll }

    var body: some View {
        DiceRow(values: values, used: used, size: size)
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

/// The dice rendered on the board's center bar (#46 — the traditional placement,
/// freeing the side rails). Two dice straddle the center diagonally; a pasch
/// shows four in a 2×2 cluster. Positioned via `BoardGeometry`, so it registers
/// with the board when overlaid in `PlayableBoardView`. Tap to roll — only while
/// the human is awaiting a roll (`allowsHitTesting`); otherwise the dice display
/// and the board beneath stays interactive. Each committed half-move greys the
/// die actually used. (Roll-feel polish is tracked separately in #24.)
struct BoardDiceView: View {
    @ObservedObject var session: GameSession

    @State private var tumbling = false
    @State private var spin: Double = 0

    /// A pasch shows four dice; otherwise the two rolled values.
    private var values: [Int] {
        let d = session.game.dice
        if d.isPasch { return Array(repeating: d.die1.value, count: 4) }
        return [d.die1.value, d.die2.value]
    }

    private var used: [Bool] { usedDiceFlags(values: values, built: session.moveBuilder.built) }

    private var canRoll: Bool { session.phase == .awaitingRoll }

    var body: some View {
        GeometryReader { proxy in
            let geo = BoardGeometry(rect: CGRect(origin: .zero, size: proxy.size))
            let centers = geo.diceCenters(count: values.count)
            ZStack {
                ForEach(Array(values.enumerated()), id: \.offset) { idx, val in
                    DieFace(value: val, isUsed: idx < used.count && used[idx],
                            isHighlighted: canRoll, size: geo.diceSize)
                        .onTapGesture(perform: roll)
                        .position(centers[idx])
                }
            }
            .rotationEffect(.degrees(tumbling ? spin : 0))
            .scaleEffect(tumbling ? 0.92 : 1.0)
        }
        .aspectRatio(1, contentMode: .fit)
        .allowsHitTesting(canRoll)
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
        DiceRow(values: [3, 5], used: [false, false])
        DiceRow(values: [3, 5], used: [true, false])   // left die (3) consumed
        DiceRow(values: [3, 5], used: [false, true])   // right die (5) consumed
        DiceRow(values: [6, 6, 6, 6], used: [false, false, false, false]) // pasch
        DiceRow(values: [6, 6, 6, 6], used: [true, true, false, false])   // two consumed
        DiceRow(values: [1, 2], used: [true, true])    // all consumed
    }
    .padding(40)
    .background(SColor(red: 138 / 255, green: 74 / 255, blue: 34 / 255))
}

#Preview("Manual control") {
    ManualDiceControl(session: GameSession())
        .padding(40)
}
