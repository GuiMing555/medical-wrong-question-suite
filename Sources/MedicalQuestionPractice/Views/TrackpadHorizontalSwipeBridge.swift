import AppKit
import SwiftUI

struct TrackpadHorizontalSwipeBridge: NSViewRepresentable {
    let onSwipeLeft: () -> Void
    let onSwipeRight: () -> Void

    func makeNSView(context: Context) -> SwipeMonitorView {
        let view = SwipeMonitorView()
        view.onSwipeLeft = onSwipeLeft
        view.onSwipeRight = onSwipeRight
        return view
    }

    func updateNSView(_ view: SwipeMonitorView, context: Context) {
        view.onSwipeLeft = onSwipeLeft
        view.onSwipeRight = onSwipeRight
    }

    static func dismantleNSView(_ view: SwipeMonitorView, coordinator: ()) {
        view.stopMonitoring()
    }
}

final class SwipeMonitorView: NSView {
    var onSwipeLeft: (() -> Void)?
    var onSwipeRight: (() -> Void)?

    private var eventMonitor: Any?
    private var accumulatedHorizontal: CGFloat = 0
    private var accumulatedVertical: CGFloat = 0
    private var didTriggerCurrentGesture = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopMonitoring()
        } else {
            startMonitoring()
        }
    }

    deinit {
        stopMonitoring()
    }

    func stopMonitoring() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }

    private func startMonitoring() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        guard event.window === window,
              event.hasPreciseScrollingDeltas,
              event.momentumPhase.isEmpty,
              !event.phase.isEmpty else { return }

        if event.phase.contains(.mayBegin) || event.phase.contains(.began) {
            resetGesture()
        }

        let directionMultiplier: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
        accumulatedHorizontal += event.scrollingDeltaX * directionMultiplier
        accumulatedVertical += event.scrollingDeltaY * directionMultiplier

        if !didTriggerCurrentGesture,
           abs(accumulatedHorizontal) >= 70,
           abs(accumulatedHorizontal) > abs(accumulatedVertical) * 1.25 {
            didTriggerCurrentGesture = true
            if accumulatedHorizontal > 0 {
                onSwipeLeft?()
            } else {
                onSwipeRight?()
            }
        }

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            resetGesture()
        }
    }

    private func resetGesture() {
        accumulatedHorizontal = 0
        accumulatedVertical = 0
        didTriggerCurrentGesture = false
    }
}
