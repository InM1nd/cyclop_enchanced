import SwiftUI

struct PomodoroPane: View {
    @ObservedObject var pomodoro: PomodoroStore

    var body: some View {
        VStack(spacing: 10) {
            presets
            clock
            controls
            steppers
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Presets

    private var presets: some View {
        HStack(spacing: 6) {
            ForEach(PomodoroStore.Preset.allCases) { preset in
                Button {
                    pomodoro.selectPreset(preset)
                } label: {
                    Text(title(for: preset))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(pomodoro.preset == preset ? .white : Theme.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(
                                pomodoro.preset == preset ? Theme.surfaceHover : Theme.surface
                            )
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Clock

    private var clock: some View {
        VStack(spacing: 6) {
            Text(pomodoro.phaseTitle.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.tertiary)

            Text(pomodoro.clock)
                .font(.system(size: 44, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .animation(.linear(duration: 0.2), value: pomodoro.clock)

            HStack(spacing: 5) {
                ForEach(0..<PomodoroStore.roundsUntilLongBreak, id: \.self) { index in
                    Circle()
                        .fill(index < pomodoro.roundIndexInSet ? Color.white.opacity(0.85) : Theme.hairline)
                        .frame(width: 6, height: 6)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Transport

    private var controls: some View {
        HStack(spacing: 14) {
            Button { pomodoro.reset() } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(NotchButtonStyle(size: 30))
            .help(localized("Reset"))

            Button { pomodoro.toggle() } label: {
                Image(systemName: pomodoro.isRunning ? "pause.fill" : "play.fill")
            }
            .buttonStyle(NotchButtonStyle(size: 40, prominent: true))

            Button { pomodoro.skip() } label: {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(NotchButtonStyle(size: 30))
            .help(localized("Skip"))
        }
    }

    // MARK: - Durations

    private var steppers: some View {
        HStack(spacing: 14) {
            stepper(
                label: localized("Focus"),
                value: pomodoro.workMinutes,
                decrement: { pomodoro.adjustWork(by: -1) },
                increment: { pomodoro.adjustWork(by: 1) }
            )
            stepper(
                label: localized("Break"),
                value: pomodoro.shortBreakMinutes,
                decrement: { pomodoro.adjustShortBreak(by: -1) },
                increment: { pomodoro.adjustShortBreak(by: 1) }
            )
            stepper(
                label: localized("Long"),
                value: pomodoro.longBreakMinutes,
                decrement: { pomodoro.adjustLongBreak(by: -1) },
                increment: { pomodoro.adjustLongBreak(by: 1) }
            )
        }
    }

    private func stepper(
        label: String,
        value: Int,
        decrement: @escaping () -> Void,
        increment: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Theme.tertiary)
            HStack(spacing: 6) {
                Button(action: decrement) {
                    Image(systemName: "minus")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Theme.surface))
                }
                .buttonStyle(.plain)

                Text("\(value)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(minWidth: 18)

                Button(action: increment) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Theme.surface))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func title(for preset: PomodoroStore.Preset) -> String {
        switch preset {
        case .classic: return localized("Classic")
        case .short: return localized("Short")
        case .long: return localized("Long")
        case .custom: return localized("Custom")
        }
    }
}
