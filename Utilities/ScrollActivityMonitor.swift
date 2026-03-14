import AppKit

final class ScrollActivityMonitor {
    private var monitor: Any?
    private var endWorkItem: DispatchWorkItem?
    private let quietPeriod: TimeInterval
    private let onScrollActiveChanged: (Bool) -> Void

    private(set) var isScrolling: Bool = false {
        didSet {
            guard isScrolling != oldValue else { return }
            onScrollActiveChanged(isScrolling)
        }
    }

    init(quietPeriod: TimeInterval = 0.18, onScrollActiveChanged: @escaping (Bool) -> Void) {
        self.quietPeriod = quietPeriod
        self.onScrollActiveChanged = onScrollActiveChanged
    }

    func start() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            self?.handleScrollEvent()
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        endWorkItem?.cancel()
        endWorkItem = nil
        isScrolling = false
    }

    private func handleScrollEvent() {
        if !isScrolling { isScrolling = true }
        endWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.isScrolling = false
        }
        endWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + quietPeriod, execute: work)
    }
}
