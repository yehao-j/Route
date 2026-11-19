import MetalKit
import UIKit
import simd

private struct RouteCamera {
    let rotation: SIMD4<Float>
    let viewport: SIMD4<Float>
    let scene: SIMD4<Float>
    let styling: SIMD4<Float>

    init(size: CGSize, pixels: CGSize, yaw: Float, pitch: Float, flat: Float) {
        let span = min(size.width * 0.79, size.height * 0.83)
        let scale = Float(pixels.width / size.width)
        rotation = SIMD4(cos(yaw), sin(yaw), cos(pitch), sin(pitch))
        viewport = SIMD4(Float(pixels.width), Float(pixels.height), Float(span) * scale, 0.46 * (1 - flat))
        scene = SIMD4(0, -0.08, 1 - flat, 0.125)
        styling = SIMD4(scale, 0, 0, 0)
    }

    func point(_ position: SIMD3<Float>) -> CGPoint {
        let horizontal = position.x * rotation.x + position.z * rotation.y
        let depth = -position.x * rotation.y + position.z * rotation.x
        let elevation = position.y * scene.z
        let vertical = elevation * rotation.z - depth * rotation.w
        let towardCamera = elevation * rotation.w + depth * rotation.z
        let scale = viewport.z / (1 - towardCamera * viewport.w)
        return CGPoint(
            x: CGFloat((viewport.x * (0.5 + 0.5 * scene.x) + horizontal * scale) / styling.x),
            y: CGFloat((viewport.y * (0.5 - 0.5 * scene.y) - vertical * scale) / styling.x)
        )
    }
}

/// A Metal-backed preview of a GPS path that can be embedded in a UIKit layout.
public final class Route3DView: UIView {
    public enum Presentation: Equatable {
        case threeDimensional
        case overhead
    }

    public struct State: Equatable {
        public fileprivate(set) var presentation: Presentation = .threeDimensional
        /// The requested playback state, preserved across view and interaction changes.
        public fileprivate(set) var isAutoplayEnabled: Bool
        public fileprivate(set) var isManualRotationEnabled = false
    }

    private static let openingYaw: Float = 43 * .pi / 180
    private static let orbitDuration: Double = 14
    private static let markerDuration: Double = 16
    private static let orbitPitch: Float = 25.5 * .pi / 180

    public let path: Route3DPath
    private let metalView: RouteMetalView
    private let renderer: RouteRenderer
    private let highLabel: ElevationFlag
    private let lowLabel: ElevationFlag
    private let marker = CALayer()
    private let markerCore = CALayer()
    private let rotationHint = UILabel()
    private var displayLink: CADisplayLink?
    private var lastFrame: CFTimeInterval?
    private var yaw = openingYaw
    private var pitch = orbitPitch
    private var elapsed: Double = 0
    private var flat: Float = 0
    private var transition: (from: Float, elapsed: CFTimeInterval)?
    private let rotationGesture = UIPanGestureRecognizer()

    /// Called when the presentation, playback preference, or interaction mode changes.
    public var onStateChange: ((State) -> Void)?
    public private(set) var state = State(isAutoplayEnabled: !UIAccessibility.isReduceMotionEnabled) {
        didSet {
            guard state != oldValue else { return }
            rotationGesture.isEnabled = state.isManualRotationEnabled
            rotationHint.isHidden = !state.isManualRotationEnabled
            updateAccessibilityDescription()
            updateFrameClock()
            onStateChange?(state)
        }
    }

    /// Set to false while the host covers the preview or scrolls it offscreen.
    public var isRenderingEnabled = true {
        didSet {
            guard isRenderingEnabled != oldValue else { return }
            updateFrameClock()
            if isRenderingEnabled { render() }
        }
    }

    public var yawDegrees: Double { Double(yaw) * 180 / .pi }
    public var pitchDegrees: Double { Double(pitch) * 180 / .pi }

    /// Initialize with the bundle that contains the compiled RouteShaders.metal library.
    public init(path: Route3DPath, shaderBundle: Bundle = .main) async throws {
        let renderer = try await RouteRenderer(track: path.track, shaderBundle: shaderBundle)
        self.path = path
        self.renderer = renderer
        metalView = RouteMetalView(frame: .zero, device: renderer.device)
        highLabel = ElevationFlag(elevation: path.maximumElevationMeters, isHigh: true)
        lowLabel = ElevationFlag(elevation: path.minimumElevationMeters, isHigh: false)
        super.init(frame: .zero)

        metalView.isOpaque = false
        metalView.backgroundColor = .clear
        metalView.layer.isOpaque = false
        metalView.clearColor = MTLClearColorMake(0, 0, 0, 0)
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = false
        metalView.isUserInteractionEnabled = false
        metalView.renderFrame = { [weak self] view in self?.drawFrame(in: view) }
        addSubview(metalView)
        addSubview(highLabel)
        addSubview(lowLabel)

        marker.bounds = CGRect(x: 0, y: 0, width: 7, height: 7)
        marker.cornerRadius = 3.5
        marker.backgroundColor = UIColor(red: 1, green: 0.66, blue: 0.16, alpha: 0.27).cgColor
        marker.shadowColor = UIColor(red: 1, green: 0.58, blue: 0.10, alpha: 1).cgColor
        marker.shadowRadius = 5
        marker.shadowOpacity = 0.95
        marker.shadowOffset = .zero
        marker.shadowPath = CGPath(ellipseIn: marker.bounds, transform: nil)
        markerCore.bounds = CGRect(x: 0, y: 0, width: 5.6, height: 5.6)
        markerCore.cornerRadius = 2.8
        markerCore.position = CGPoint(x: 3.5, y: 3.5)
        markerCore.backgroundColor = UIColor(red: 1, green: 0.77, blue: 0.40, alpha: 1).cgColor
        marker.addSublayer(markerCore)
        layer.addSublayer(marker)

        rotationGesture.addTarget(self, action: #selector(panRoute(_:)))
        rotationGesture.maximumNumberOfTouches = 1
        rotationGesture.isEnabled = false
        addGestureRecognizer(rotationGesture)

        rotationHint.text = "Drag to rotate"
        rotationHint.font = .preferredFont(forTextStyle: .footnote)
        rotationHint.adjustsFontForContentSizeCategory = true
        rotationHint.textColor = UIColor.white.withAlphaComponent(0.75)
        rotationHint.textAlignment = .center
        rotationHint.isHidden = true
        rotationHint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rotationHint)
        NSLayoutConstraint.activate([
            rotationHint.centerXAnchor.constraint(equalTo: centerXAnchor),
            rotationHint.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            rotationHint.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            rotationHint.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)
        ])
        isAccessibilityElement = true
        accessibilityValue = "Highest \(Int(path.maximumElevationMeters)) meters, lowest \(Int(path.minimumElevationMeters)) meters"
        updateAccessibilityDescription()

        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneDidActivate(_:)), name: UIScene.didActivateNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneWillDeactivate(_:)), name: UIScene.willDeactivateNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(motionPreferenceChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil
        )
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("Use init(path:shaderBundle:)") }

    public override func layoutSubviews() {
        super.layoutSubviews()
        metalView.frame = bounds
        render()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        updateFrameClock()
        render()
    }

    public override var isHidden: Bool {
        didSet {
            guard isHidden != oldValue else { return }
            updateFrameClock()
            if !isHidden { render() }
        }
    }

    /// Updates the automatic rotation preference, including while manual mode is active.
    public func setAutoplayEnabled(_ enabled: Bool) {
        state.isAutoplayEnabled = enabled
    }

    /// Shows the route in 3D or from overhead. Overhead mode exits manual rotation.
    public func setPresentation(_ presentation: Presentation, animated: Bool = true) {
        guard presentation != state.presentation else { return }
        let overhead = presentation == .overhead
        if !animated || UIAccessibility.isReduceMotionEnabled {
            flat = overhead ? 1 : 0
            transition = nil
        } else {
            transition = (flat, 0)
        }
        var next = state
        next.presentation = presentation
        if overhead { next.isManualRotationEnabled = false }
        state = next
        render()
    }

    /// Enables one-finger camera rotation in 3D and suspends autoplay until turned off.
    public func setManualRotationEnabled(_ enabled: Bool) {
        guard !enabled || state.presentation == .threeDimensional else { return }
        state.isManualRotationEnabled = enabled
    }

    /// Give manual rotation priority over scrolling when the preview is inside a scroll view.
    public func prioritizeRotation(in scrollView: UIScrollView) {
        scrollView.panGestureRecognizer.require(toFail: rotationGesture)
    }

    /// Sets the camera angle in degrees. Pitch is clamped to the interactive range.
    public func setCamera(yawDegrees: Double, pitchDegrees: Double) {
        guard yawDegrees.isFinite, pitchDegrees.isFinite else { return }
        yaw = Float(yawDegrees.truncatingRemainder(dividingBy: 360) * .pi / 180)
        pitch = min(max(Float(pitchDegrees * .pi / 180), 0.14), 1.17)
        render()
    }

    /// Returns the camera to its opening angle.
    public func resetCamera() {
        yaw = Self.openingYaw
        pitch = Self.orbitPitch
        render()
    }

    private func updateAccessibilityDescription() {
        accessibilityLabel = state.presentation == .overhead ? "Overhead trail route" : "3D trail route"
        accessibilityHint = state.isManualRotationEnabled
            ? "Drag to change the route angle."
            : "Use the route controls to change the preview."
    }

    @objc private func motionPreferenceChanged() {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        if reduceMotion {
            flat = state.presentation == .overhead ? 1 : 0
            transition = nil
            render()
        }
        state.isAutoplayEnabled = !reduceMotion
        updateFrameClock()
    }

    @objc private func sceneDidActivate(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === window?.windowScene else { return }
        updateFrameClock()
        render()
    }

    @objc private func sceneWillDeactivate(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === window?.windowScene else { return }
        suspend()
    }

    private var canRender: Bool {
        isRenderingEnabled && !isHidden && window?.windowScene?.activationState == .foregroundActive
    }

    private var shouldAutoplay: Bool {
        state.presentation == .threeDimensional && state.isAutoplayEnabled && !state.isManualRotationEnabled
    }

    private func updateFrameClock() {
        let isAnimating = transition != nil || shouldAutoplay
        guard canRender, isAnimating else {
            suspend()
            return
        }
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(animate(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func suspend() {
        displayLink?.invalidate()
        displayLink = nil
        lastFrame = nil
    }

    @objc private func animate(_ link: CADisplayLink) {
        guard canRender else {
            suspend()
            return
        }
        let time = link.targetTimestamp
        let delta = lastFrame.map { min(max(time - $0, 0), 0.1) } ?? 0
        lastFrame = time
        if var transition {
            transition.elapsed += delta
            let progress = Float(min(transition.elapsed / 0.55, 1))
            let target: Float = state.presentation == .overhead ? 1 : 0
            flat = transition.from + (target - transition.from) * progress * progress * (3 - 2 * progress)
            self.transition = progress == 1 ? nil : transition
        }
        if shouldAutoplay {
            yaw = (yaw - Float(delta / Self.orbitDuration) * 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
            elapsed += delta
        }
        render()
        updateFrameClock()
    }

    private func render() {
        guard canRender, bounds.width > 0, bounds.height > 0 else { return }
        metalView.draw()
    }

    private func drawFrame(in view: MTKView) {
        guard canRender, view.drawableSize.width > 0, view.drawableSize.height > 0 else { return }
        let camera = RouteCamera(
            size: bounds.size, pixels: view.drawableSize, yaw: yaw,
            pitch: pitch + (.pi / 2 - pitch) * flat, flat: flat
        )
        guard renderer.draw(camera: camera, in: view) else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let markerPhase = elapsed.truncatingRemainder(dividingBy: Self.markerDuration) / Self.markerDuration
        // The course is open-ended. Fade the marker through the finish-to-start reset.
        let markerFade = min(1, (1 - markerPhase) * 40, markerPhase * 40 + (elapsed < 0.5 ? 1 : 0))
        let pulse = CGFloat(0.5 + 0.5 * sin(elapsed * 2 * .pi / 1.15))
        marker.position = camera.point(path.position(at: markerPhase))
        marker.opacity = Float(markerFade) * (1 - flat)
        marker.shadowRadius = 4 + pulse * 3
        marker.shadowOpacity = Float(0.68 + pulse * 0.28)
        marker.transform = CATransform3DMakeScale(1 + pulse * 0.28, 1 + pulse * 0.28, 1)

        let high = camera.point(path.high.position)
        let low = camera.point(path.low.position)
        highLabel.place(at: high, in: bounds)
        lowLabel.place(at: low, in: bounds, avoiding: highLabel.captionFrame)
        highLabel.alpha = CGFloat(1 - flat)
        lowLabel.alpha = CGFloat(1 - flat)
        CATransaction.commit()
    }

    public override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === rotationGesture else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        return state.isManualRotationEnabled && canRender && transition == nil
    }

    @objc private func panRoute(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed, .ended:
            let delta = recognizer.translation(in: self)
            recognizer.setTranslation(.zero, in: self)
            yaw = (yaw + Float(delta.x) * 0.009).truncatingRemainder(dividingBy: 2 * .pi)
            pitch = min(max(pitch + Float(delta.y) * 0.004, 0.14), 1.17)
            render()
        default:
            break
        }
    }
}

private final class RouteMetalView: MTKView {
    var renderFrame: ((MTKView) -> Void)?

    override func draw(_ rect: CGRect) {
        renderFrame?(self)
    }
}

private final class RouteRenderer {
    let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let points: any MTLBuffer
    private let count: Int
    private let curtain: any MTLRenderPipelineState
    private let stroke: any MTLRenderPipelineState

    init(track: [SIMD4<Float>], shaderBundle: Bundle) async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let points = device.makeBuffer(bytes: track, length: track.count * MemoryLayout<SIMD4<Float>>.stride)
        else { throw RenderError.unavailable }

        let library = try device.makeDefaultLibrary(bundle: shaderBundle)

        self.device = device
        self.queue = queue
        self.points = points
        count = track.count
        curtain = try await Self.pipeline(device: device, library: library, name: "routeCurtain")
        stroke = try await Self.pipeline(device: device, library: library, name: "routeStroke")
    }

    private static func pipeline(
        device: any MTLDevice, library: any MTLLibrary, name: String
    ) async throws -> any MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = name
        descriptor.vertexFunction = library.makeFunction(name: name + "Vertex")
        descriptor.fragmentFunction = library.makeFunction(name: name + "Fragment")
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        color.isBlendingEnabled = true
        // Overlapping trail segments must not add brightness to the curtain or outline.
        color.rgbBlendOperation = .max
        color.alphaBlendOperation = .max
        color.sourceRGBBlendFactor = .one
        color.destinationRGBBlendFactor = .one
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .one
        return try await device.makeRenderPipelineState(descriptor: descriptor)
    }

    fileprivate func draw(camera: RouteCamera, in view: MTKView) -> Bool {
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        var camera = camera
        encoder.setVertexBuffer(points, offset: 0, index: 0)
        encoder.setVertexBytes(&camera, length: MemoryLayout<RouteCamera>.stride, index: 1)
        encoder.setFragmentBytes(&camera, length: MemoryLayout<RouteCamera>.stride, index: 1)
        if camera.scene.z > 0 {
            encoder.setRenderPipelineState(curtain)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: count * 2)
        }
        encoder.setRenderPipelineState(stroke)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count - 1)
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
        return true
    }

    private enum RenderError: Error { case unavailable }
}

private final class ElevationFlag: UIView {
    private let caption: UIImageView
    private let leader = CAShapeLayer()
    var captionFrame: CGRect { caption.frame.offsetBy(dx: frame.minX, dy: frame.minY) }

    init(elevation: Double, isHigh: Bool) {
        let value = "\(isHigh ? "▲" : "▼")\(Int(elevation.rounded()))m"
        let font = UIFont.systemFont(ofSize: 9.5, weight: .heavy, width: .expanded)
        let text = NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: UIColor.white])
        let ink = UIColor(white: 0.03, alpha: 0.96)
        let outline = NSAttributedString(
            string: value,
            attributes: [.font: font, .foregroundColor: ink, .strokeColor: ink, .strokeWidth: -20]
        )
        let textSize = text.size()
        let size = CGSize(width: ceil(textSize.width) + 4, height: ceil(textSize.height) + 4)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            let origin = CGPoint(x: 2, y: 2)
            outline.draw(at: origin)
            text.draw(at: origin)
        }
        caption = UIImageView(image: image)
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        leader.lineWidth = 0.55
        leader.strokeColor = UIColor.white.withAlphaComponent(0.62).cgColor
        layer.addSublayer(leader)
        addSubview(caption)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(elevation:isHigh:)") }

    func place(at point: CGPoint, in viewport: CGRect, avoiding other: CGRect? = nil) {
        let size = caption.bounds.size
        let x = min(max(6, point.x - 6), viewport.width - size.width - 6)
        var y = point.y - size.height - 18
        if let other, CGRect(origin: CGPoint(x: x, y: y), size: size).insetBy(dx: -3, dy: -2).intersects(other) {
            y = other.minY - size.height - 4
        }
        frame = CGRect(x: x, y: y, width: size.width, height: point.y - y)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 6, y: size.height))
        path.addLine(to: CGPoint(x: point.x - x, y: bounds.height))
        leader.path = path
    }
}
