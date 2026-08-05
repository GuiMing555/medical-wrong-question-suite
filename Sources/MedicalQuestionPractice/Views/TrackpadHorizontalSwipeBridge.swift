import AppKit
import SwiftUI

enum TrackpadSwipeDirection: Equatable {
    case left
    case right
}

struct TrackpadHorizontalSwipeBridge: NSViewRepresentable {
    let threshold: CGFloat
    let onProgress: (CGFloat) -> Void
    let onEnded: (TrackpadSwipeDirection?, Bool) -> Void

    func makeNSView(context: Context) -> SwipeMonitorView {
        let view = SwipeMonitorView()
        update(view)
        return view
    }

    func updateNSView(_ view: SwipeMonitorView, context: Context) {
        update(view)
    }

    static func dismantleNSView(_ view: SwipeMonitorView, coordinator: ()) {
        view.stopMonitoring()
    }

    private func update(_ view: SwipeMonitorView) {
        view.threshold = threshold
        view.onProgress = onProgress
        view.onEnded = onEnded
    }
}

final class SwipeMonitorView: NSView {
    var threshold: CGFloat = 110
    var onProgress: ((CGFloat) -> Void)?
    var onEnded: ((TrackpadSwipeDirection?, Bool) -> Void)?

    private var eventMonitor: Any?
    private var accumulatedHorizontal: CGFloat = 0
    private var accumulatedVertical: CGFloat = 0

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
            resetGesture(notify: true)
        }

        let directionMultiplier: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
        accumulatedHorizontal += event.scrollingDeltaX * directionMultiplier
        accumulatedVertical += event.scrollingDeltaY * directionMultiplier

        if abs(accumulatedHorizontal) > abs(accumulatedVertical) * 1.1 {
            // AppKit reports a physical left swipe as a positive horizontal
            // delta. SwiftUI offsets use negative values for leftward motion.
            onProgress?(-accumulatedHorizontal)
        }

        if event.phase.contains(.ended) {
            finishGesture()
        } else if event.phase.contains(.cancelled) {
            onEnded?(nil, false)
            resetGesture(notify: true)
        }
    }

    private func finishGesture() {
        let isHorizontal = abs(accumulatedHorizontal) > abs(accumulatedVertical) * 1.25
        let direction: TrackpadSwipeDirection? = isHorizontal
            ? (accumulatedHorizontal > 0 ? .left : .right)
            : nil
        let crossesThreshold = isHorizontal && abs(accumulatedHorizontal) >= threshold
        onEnded?(direction, crossesThreshold)
        resetGesture(notify: false)
    }

    private func resetGesture(notify: Bool) {
        accumulatedHorizontal = 0
        accumulatedVertical = 0
        if notify { onProgress?(0) }
    }
}
