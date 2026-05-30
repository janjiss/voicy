import AppKit
import QuartzCore

// HUDPanel is a small, floating pill near the bottom-center of the screen with
// an animated audio waveform - styled after dictation overlays like Wispr Flow.
// While listening the bars react to the live microphone level; while processing
// they run a calm indeterminate wave. Errors expand the pill into a text label.
final class HUDPanel {
    enum Mode: Equatable {
        case hidden
        case idle
        case listening
        case processing
        case error(String)
    }

    private var panel: NSPanel?
    private var blur: NSVisualEffectView?
    private var waveform: WaveformView?
    private var label: NSTextField?
    private var errorTimer: Timer?

    private enum Content { case waveform, label, handle }

    private let handleSize = NSSize(width: 40, height: 5)
    private let compactSize = NSSize(width: 104, height: 34)
    private let labelFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)

    // MARK: Public API

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode

        errorTimer?.invalidate()
        errorTimer = nil

        switch newMode {
        case .hidden:
            waveform?.stop()
            panel?.orderOut(nil)
        case .idle:
            ensureCreated()
            waveform?.stop()
            layout(for: handleSize, content: .handle)
            present(alpha: 0.4)
        case .listening:
            ensureCreated()
            layout(for: compactSize, content: .waveform)
            waveform?.start(style: .reactive)
            present(alpha: 1.0)
        case .processing:
            ensureCreated()
            layout(for: compactSize, content: .waveform)
            waveform?.start(style: .indeterminate)
            present(alpha: 1.0)
        case .error(let text):
            ensureCreated()
            label?.stringValue = text
            layout(for: errorSize(for: text), content: .label)
            waveform?.stop()
            present(alpha: 1.0)
            // Errors are transient: fall back to the resting handle shortly.
            errorTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
                self?.setMode(.idle)
            }
        }
    }

    func setLevel(_ level: Double) {
        waveform?.setLevel(level)
    }

    func hide() {
        setMode(.hidden)
    }

    private var mode: Mode = .hidden

    // MARK: Internals

    private func present(alpha: CGFloat) {
        panel?.alphaValue = alpha
        panel?.orderFrontRegardless()
    }

    private func errorSize(for text: String) -> NSSize {
        let width = (text as NSString).size(withAttributes: [.font: labelFont]).width
        return NSSize(width: min(max(width + 44, 160), 460), height: 40)
    }

    private func layout(for size: NSSize, content: Content) {
        guard let panel, let blur, let waveform, let label else { return }

        // Anchor by a constant center point so the pill grows/shrinks in place.
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let centerX = visible.midX
            let centerY = visible.minY + 78
            panel.setFrame(
                NSRect(x: centerX - size.width / 2, y: centerY - size.height / 2, width: size.width, height: size.height),
                display: true
            )
        } else {
            panel.setContentSize(size)
        }

        blur.frame = NSRect(origin: .zero, size: size)
        blur.layer?.cornerRadius = size.height / 2

        label.isHidden = content != .label
        waveform.isHidden = content != .waveform

        switch content {
        case .label:
            label.frame = NSRect(x: 18, y: 0, width: size.width - 36, height: size.height)
        case .waveform:
            let wfWidth = waveform.intrinsicWidth
            waveform.frame = NSRect(x: (size.width - wfWidth) / 2, y: 0, width: wfWidth, height: size.height)
        case .handle:
            break
        }
    }

    private func ensureCreated() {
        guard panel == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: compactSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true

        guard let content = panel.contentView else { return }

        let blur = NSVisualEffectView(frame: content.bounds)
        blur.autoresizingMask = [.width, .height]
        blur.blendingMode = .behindWindow
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = compactSize.height / 2
        blur.layer?.masksToBounds = true
        content.addSubview(blur)

        let waveform = WaveformView(frame: blur.bounds)
        blur.addSubview(waveform)

        let label = NSTextField(labelWithString: "")
        label.font = labelFont
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.isHidden = true
        blur.addSubview(label)

        self.panel = panel
        self.blur = blur
        self.waveform = waveform
        self.label = label
    }
}

// WaveformView draws a row of rounded vertical bars and animates them either in
// reaction to a live level or as a calm indeterminate wave.
private final class WaveformView: NSView {
    enum Style { case reactive, indeterminate }

    private let barCount = 13
    private let barWidth: CGFloat = 3
    private let barGap: CGFloat = 3.5
    private let minHeight: CGFloat = 3
    private let maxHeight: CGFloat = 20

    private var bars: [CALayer] = []
    private var heights: [CGFloat] = []
    private var timer: Timer?
    private var style: Style = .reactive
    private var level: CGFloat = 0
    private var phase: CGFloat = 0

    // Bell-shaped profile so the center bars swing more than the edges.
    private lazy var profile: [CGFloat] = {
        (0..<barCount).map { i in
            let t = CGFloat(i) / CGFloat(barCount - 1) // 0...1
            let centered = 1 - abs(t - 0.5) * 2          // 1 at center, 0 at edges
            return 0.45 + 0.55 * centered
        }
    }()

    var intrinsicWidth: CGFloat {
        CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        buildBars()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        positionBars()
    }

    private func buildBars() {
        for _ in 0..<barCount {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
            bar.cornerRadius = barWidth / 2
            layer?.addSublayer(bar)
            bars.append(bar)
            heights.append(minHeight)
        }
        positionBars()
    }

    private func positionBars() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let midY = bounds.midY
        for (i, bar) in bars.enumerated() {
            let x = CGFloat(i) * (barWidth + barGap)
            let h = heights[i]
            bar.frame = CGRect(x: x, y: midY - h / 2, width: barWidth, height: h)
        }
        CATransaction.commit()
    }

    func start(style: Style) {
        self.style = style
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.tick()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for i in heights.indices { heights[i] = minHeight }
        positionBars()
    }

    func setLevel(_ value: Double) {
        // Emphasize quiet speech a little so the bars feel responsive.
        let shaped = pow(max(0, min(1, value)), 0.6)
        level = CGFloat(shaped)
    }

    private func tick() {
        phase += 0.22
        let range = maxHeight - minHeight

        for i in 0..<barCount {
            let target: CGFloat
            switch style {
            case .reactive:
                let idle = 0.12 + 0.10 * sin(phase + CGFloat(i) * 0.7)
                let amount = max(idle, level) * profile[i]
                target = minHeight + range * amount
            case .indeterminate:
                let wave = 0.5 + 0.5 * sin(phase - CGFloat(i) * 0.5)
                target = minHeight + range * (0.25 + 0.45 * wave) * profile[i]
            }
            heights[i] += (target - heights[i]) * 0.35
        }
        positionBars()
    }
}
