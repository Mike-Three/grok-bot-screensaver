// Grok Bot Screensaver for macOS (fan-made, inspired by the Grok Bot face marks): the ScreenSaver view. It decodes the
// sprite sheets (Contents/Resources/face-<shape>.png) and shows the sprite that Motion.swift composes each frame in a
// Core Animation layer, stepped in time with the display.
import ScreenSaver
import AppKit
import ImageIO
import QuartzCore

@objc(GrokFacesView)
final class GrokFacesView: ScreenSaverView {
    private var saver: Saver<SystemRandomNumberGenerator>?
    private var lastTime: CFTimeInterval = 0
    private var sprite: CGImage?
    private let spriteLayer = CALayer()
    private var willStopObserver: NSObjectProtocol?
    // On macOS 14 and later a CADisplayLink from the view drives the frames (held untyped: the class is macOS 14+);
    // before that the ScreenSaverView timer does.
    private var frameLink: AnyObject?

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        // With the display link the timer only has to stay out of the way (animateOneFrame ignores it).
        if #available(macOS 14, *) { animationTimeInterval = 1 } else { animationTimeInterval = 1.0 / 60.0 }
        setup()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        Faces.decode = GrokFacesView.decode
        saver = Saver(width: Float(max(1, bounds.width)), height: Float(max(1, bounds.height)), rng: SystemRandomNumberGenerator())
        // A black layer with one sprite layer on it: each frame only the sprite's image and position change, so the
        // screen is composited on the GPU instead of being redrawn on the CPU.
        wantsLayer = true
        spriteLayer.minificationFilter = .linear
        spriteLayer.magnificationFilter = .linear
        layer?.addSublayer(spriteLayer)
        makeSprite()
        showSprite()
        lastTime = CACurrentMediaTime()
        // Since macOS 14 the host can skip stopAnimation and keep the saver animating after it ends; the system's
        // willstop notification stops it (and shows the pointer again).
        if !isPreview {
            willStopObserver = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name("com.apple.screensaver.willstop"), object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.stopAnimation() } }
        }
    }

    // One sheet: 8-bit gray distance values plus the eye geometry from its "eyEs" chunk.
    private static func decode(_ name: String) -> Faces.Sheet? {
        let bundle = Bundle(for: GrokFacesView.self)
        guard let url = bundle.url(forResource: "face-" + name, withExtension: "png"),
              let data = try? Data(contentsOf: url), let eyes = Faces.eyeChunk(data),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? Faces.Sheet(width: w, pixels: px, eyes: eyes) : nil
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = CGColor.black }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        spriteLayer.contentsScale = window?.backingScaleFactor ?? 1
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        saver?.resize(width: Float(newSize.width), height: Float(newSize.height))
    }

    private func makeSprite() {
        guard var px = saver?.rgba else { return }
        sprite = px.withUnsafeMutableBytes { buf -> CGImage? in
            guard let ctx = CGContext(data: buf.baseAddress, width: Faces.cell, height: Faces.cell, bitsPerComponent: 8,
                                      bytesPerRow: Faces.cell * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            return ctx.makeImage()
        }
    }

    // Like any screensaver, hide the pointer while it runs (not in the small preview in System Settings). The host can
    // call startAnimation twice or skip stopAnimation, so the view hides the pointer at most once and shows it again
    // when it stops, leaves its window or goes away.
    private var cursorHidden = false

    private func hideCursor() {
        guard !isPreview, !cursorHidden else { return }
        NSCursor.hide(); cursorHidden = true
    }

    private func showCursor() {
        guard cursorHidden else { return }
        NSCursor.unhide(); cursorHidden = false
    }

    override func startAnimation() { super.startAnimation(); hideCursor(); startDisplayLink() }
    override func stopAnimation() { super.stopAnimation(); showCursor(); stopDisplayLink() }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { showCursor(); stopDisplayLink() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, isAnimating { startDisplayLink() }
    }

    deinit {
        if cursorHidden { DispatchQueue.main.async { NSCursor.unhide() } }
        if let o = willStopObserver { DistributedNotificationCenter.default().removeObserver(o) }
        if #available(macOS 14, *) { (frameLink as? CADisplayLink)?.invalidate() }
    }

    private func startDisplayLink() {
        guard #available(macOS 14, *), frameLink == nil, window != nil else { return }
        let link: CADisplayLink = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        link.add(to: .main, forMode: .common)
        frameLink = link
    }

    private func stopDisplayLink() {
        if #available(macOS 14, *) { (frameLink as? CADisplayLink)?.invalidate() }
        frameLink = nil
    }

    // Steps the model to the time this frame will be on screen, so motion matches what the display shows.
    @available(macOS 14, *)
    @objc private func displayLinkFired(_ link: CADisplayLink) {
        advance(to: link.targetTimestamp)
    }

    override func animateOneFrame() {
        if #available(macOS 14, *) { return } // the display link drives the frames
        advance(to: CACurrentMediaTime())
    }

    // Saver.step clamps dt to 0...0.25 s, which covers the first frame and any long gap.
    private func advance(to time: CFTimeInterval) {
        saver?.step(Float(time - lastTime)); lastTime = time
        makeSprite()
        showSprite()
    }

    private func showSprite() {
        guard let s = saver else { return }
        // the model uses a top-left origin; the view's origin is bottom-left
        let c = CGFloat(s.cellPx)
        let x: CGFloat = CGFloat(s.x) - c / 2
        let y: CGFloat = bounds.height - CGFloat(s.y) - c / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.contents = sprite
        spriteLayer.frame = CGRect(x: x, y: y, width: c, height: c)
        CATransaction.commit()
    }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
}
