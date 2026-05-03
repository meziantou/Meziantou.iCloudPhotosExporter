import Foundation

@MainActor
final class ExportScheduler {
    private var timer: Timer?
    private var intervalMinutes: Int = 15
    private var action: (() -> Void)?
    private(set) var isPaused: Bool = false

    func configure(intervalMinutes: Int, action: @escaping () -> Void) {
        self.intervalMinutes = max(1, intervalMinutes)
        self.action = action
        restartTimerIfNeeded()
    }

    func setPaused(_ paused: Bool) {
        guard isPaused != paused else {
            return
        }

        isPaused = paused
        restartTimerIfNeeded()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func restartTimerIfNeeded() {
        timer?.invalidate()
        timer = nil

        guard !isPaused, let action else {
            return
        }

        let interval = TimeInterval(intervalMinutes * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            action()
        }
    }
}
