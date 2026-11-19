import UIKit

final class ViewController: UIViewController, UIScrollViewDelegate, UIAdaptivePresentationControllerDelegate {
    private static let amber = UIColor(red: 1, green: 0.65, blue: 0.05, alpha: 1)
    private let scroll = UIScrollView()
    private let content = UIView()
    private let playback = UIButton(type: .system)
    private let share = UIButton(type: .system)
    private let elevationMode = UIButton(type: .system)
    private let planMode = UIButton(type: .system)
    private let manualRotation = UIButton(type: .system)
    private let expand = UIButton(type: .system)
    private let backdrop = RouteBackdrop()
    private let stage = UIView()
    private let controls = UIView()
    private var route: TrailRoute?
    private var preview: Route3DView?
    private var placeholder: UIStackView?
    private var shareController: UIActivityViewController?
    private var details: UIView?
    private var courseHeading: UIStackView?
    private var metricRows: [UIStackView] = []
    private var stageHeight: NSLayoutConstraint?
    private var controlsHeight: NSLayoutConstraint?
    private var pageVisible = false
    private var expanded = false

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        do {
            let route = try TrailRoute()
            self.route = route
            configurePage(route: route)
            loadPreview(for: route)
        } catch {
            let message = makeLabel("Unable to load the course data.", size: 16, weight: .medium, style: .body)
            message.textAlignment = .center
            message.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(message)
            NSLayoutConstraint.activate([
                message.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                message.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                message.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
                message.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor)
            ])
            NSLog("Route data: %@", String(describing: error))
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bottomInset = view.safeAreaInsets.bottom + 24
        if scroll.contentInset.bottom != bottomInset {
            scroll.contentInset.bottom = bottomInset
        }
        updateStageHeight()
        updatePreviewVisibility()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        pageVisible = true
        updatePreviewVisibility()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pageVisible = false
        updatePreviewVisibility()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updatePreviewVisibility()
    }

    private func updatePreviewVisibility() {
        guard let preview else { return }
        let visibleStage = stage.convert(stage.bounds, to: scroll).intersection(scroll.bounds)
        preview.isRenderingEnabled = pageVisible && shareController == nil && !visibleStage.isEmpty
    }

    private func loadPreview(for route: TrailRoute) {
        Task { [weak self] in
            do {
                let preview = try await Route3DView(path: route.path)
                self?.installPreview(preview)
            } catch {
                let status = self?.placeholder?.arrangedSubviews.last as? UILabel
                status?.text = "3D preview unavailable"
                NSLog("Route preview: %@", String(describing: error))
            }
        }
    }

    private func installPreview(_ preview: Route3DView) {
        self.preview = preview
        placeholder?.removeFromSuperview()
        placeholder = nil
        preview.isRenderingEnabled = false
        preview.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(preview)
        preview.prioritizeRotation(in: scroll)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: stage.topAnchor),
            preview.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: stage.bottomAnchor)
        ])
        preview.onStateChange = { [weak self] state in self?.updateModes(for: state) }
        updateModes(for: preview.state)
        playback.isHidden = false
        controls.isHidden = false
        controlsHeight?.constant = 50
        updateStageHeight()
        view.setNeedsLayout()
    }

    private func configurePage(route: TrailRoute) {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.showsVerticalScrollIndicator = false
        scroll.delegate = self
        view.addSubview(scroll)
        scroll.addSubview(content)

        let header = UIView()
        let details = makeDetails(route: route)
        for element in [header, stage, controls, details] {
            element.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(element)
        }
        self.details = details

        let status = makeLabel("Loading 3D preview…", size: 13, weight: .medium, style: .footnote)
        status.textAlignment = .center
        status.textColor = UIColor(white: 0.72, alpha: 1)
        let placeholder = UIStackView(arrangedSubviews: [OverheadRouteView(path: route.path), status])
        placeholder.axis = .vertical
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(placeholder)
        self.placeholder = placeholder

        playback.isHidden = true
        playback.addTarget(self, action: #selector(togglePlayback), for: .touchUpInside)

        var shareStyle = UIButton.Configuration.filled()
        shareStyle.attributedTitle = AttributedString("Share", attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 14, weight: .semibold)]))
        shareStyle.image = UIImage(systemName: "square.and.arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        shareStyle.imagePadding = 6
        shareStyle.cornerStyle = .capsule
        shareStyle.baseBackgroundColor = UIColor(white: 0.18, alpha: 1)
        shareStyle.background.backgroundInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
        shareStyle.baseForegroundColor = .white
        shareStyle.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        share.configuration = shareStyle
        share.accessibilityLabel = "Share GPX"
        share.addTarget(self, action: #selector(shareRoute), for: .touchUpInside)

        configureMode(elevationMode, title: "3D elevation view", isElevation: true, action: #selector(showElevation))
        configureMode(planMode, title: "Overhead route view", isElevation: false, action: #selector(showPlan))
        manualRotation.addTarget(self, action: #selector(toggleManualRotation), for: .touchUpInside)
        configureExpand()
        expand.addTarget(self, action: #selector(toggleExpanded), for: .touchUpInside)
        controls.isHidden = true

        [playback, share].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview($0)
        }
        [manualRotation, elevationMode, planMode, expand].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            controls.addSubview($0)
        }

        let compactWidth = content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        compactWidth.priority = .defaultHigh
        let height = stage.heightAnchor.constraint(equalToConstant: 230)
        let controlsHeight = controls.heightAnchor.constraint(equalToConstant: 0)
        stageHeight = height
        self.controlsHeight = controlsHeight

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.centerXAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerXAnchor),
            scroll.contentLayoutGuide.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            content.widthAnchor.constraint(lessThanOrEqualTo: scroll.frameLayoutGuide.widthAnchor),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 650),
            compactWidth,

            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            header.heightAnchor.constraint(equalToConstant: 44),
            playback.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            playback.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            playback.widthAnchor.constraint(equalToConstant: 44),
            playback.heightAnchor.constraint(equalToConstant: 44),
            share.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            share.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            share.heightAnchor.constraint(equalToConstant: 44),

            stage.topAnchor.constraint(equalTo: header.bottomAnchor),
            stage.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            height,
            placeholder.topAnchor.constraint(equalTo: stage.topAnchor),
            placeholder.leadingAnchor.constraint(equalTo: stage.leadingAnchor, constant: 24),
            placeholder.trailingAnchor.constraint(equalTo: stage.trailingAnchor, constant: -24),
            placeholder.bottomAnchor.constraint(equalTo: stage.bottomAnchor, constant: -16),

            controls.topAnchor.constraint(equalTo: stage.bottomAnchor),
            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            controlsHeight,
            manualRotation.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 8),
            manualRotation.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            manualRotation.widthAnchor.constraint(equalToConstant: 44),
            manualRotation.heightAnchor.constraint(equalToConstant: 44),
            elevationMode.centerXAnchor.constraint(equalTo: controls.centerXAnchor, constant: -30),
            elevationMode.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            planMode.centerXAnchor.constraint(equalTo: controls.centerXAnchor, constant: 30),
            planMode.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            expand.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -8),
            expand.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            expand.widthAnchor.constraint(equalToConstant: 44),
            expand.heightAnchor.constraint(equalToConstant: 44),

            details.topAnchor.constraint(equalTo: controls.bottomAnchor),
            details.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            details.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            details.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (controller: ViewController, _) in controller.updateDetailsLayout()
        }
        updateDetailsLayout()
    }

    private func updateStageHeight() {
        let viewport = scroll.bounds.size
        guard viewport.height > 0 else { return }
        let height: CGFloat
        if preview == nil {
            height = min(230, max(140, viewport.height * 0.46))
        } else if expanded {
            height = max(130, viewport.height - view.safeAreaInsets.bottom - 106)
        } else {
            height = min(content.bounds.width * 0.845, max(160, viewport.height * 0.54), 450)
        }
        if stageHeight?.constant != height {
            stageHeight?.constant = height
        }
    }

    private func configurePlayback(paused: Bool) {
        let symbol = paused ? "play.circle.fill" : "pause.circle.fill"
        playback.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 21, weight: .semibold)), for: .normal)
        playback.tintColor = .white
        playback.accessibilityLabel = paused ? "Play rotation" : "Pause rotation"
    }

    private func configureMode(_ button: UIButton, title: String, isElevation: Bool, action: Selector) {
        button.accessibilityLabel = title
        button.addTarget(self, action: action, for: .touchUpInside)
        button.setImage(RouteModeImage.make(isElevation: isElevation).withRenderingMode(.alwaysTemplate), for: .normal)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 48),
            button.heightAnchor.constraint(equalToConstant: 48)
        ])
    }

    private func updateModes(for state: Route3DView.State) {
        let isElevation = state.presentation == .threeDimensional
        let manual = state.isManualRotationEnabled
        configurePlayback(paused: !state.isAutoplayEnabled)
        elevationMode.tintColor = isElevation ? Self.amber : .white
        planMode.tintColor = isElevation ? .white : Self.amber
        elevationMode.accessibilityTraits = isElevation ? [.button, .selected] : .button
        planMode.accessibilityTraits = isElevation ? .button : [.button, .selected]
        playback.isEnabled = isElevation && !manual
        playback.alpha = playback.isEnabled ? 1 : 0.4

        var style = UIButton.Configuration.plain()
        style.image = UIImage(systemName: "hand.draw", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
        style.baseForegroundColor = manual ? .black : .white
        style.background.backgroundColor = manual ? Self.amber : UIColor(white: 0.21, alpha: 1)
        style.background.cornerRadius = 14
        style.background.backgroundInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        style.contentInsets = .zero
        manualRotation.configuration = style
        manualRotation.isSelected = manual
        manualRotation.isEnabled = isElevation
        manualRotation.alpha = isElevation ? 1 : 0.4
        manualRotation.accessibilityLabel = "Manual rotation"
        manualRotation.accessibilityHint = manual ? "Exit manual rotation." : "Enable dragging to rotate the route."
    }

    private func configureExpand() {
        let symbol = expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        var style = UIButton.Configuration.plain()
        style.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold))
        style.baseForegroundColor = UIColor(white: 0.08, alpha: 1)
        style.background.backgroundColor = .white
        style.background.cornerRadius = 14
        style.background.backgroundInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        style.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        expand.configuration = style
        expand.accessibilityLabel = expanded ? "Exit full screen" : "Expand route"
    }

    private func makeDetails(route: TrailRoute) -> UIView {
        let details = UIView()
        details.preservesSuperviewLayoutMargins = false
        details.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24)
        let guide = details.layoutMarginsGuide

        let source = UIButton(type: .system)
        var sourceStyle = UIButton.Configuration.plain()
        sourceStyle.title = "Official GPX course"
        sourceStyle.titleLineBreakMode = .byWordWrapping
        sourceStyle.image = UIImage(systemName: "checkmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16))
        sourceStyle.imageColorTransformer = UIConfigurationColorTransformer { _ in
            UIColor(red: 0.17, green: 0.76, blue: 0.33, alpha: 1)
        }
        sourceStyle.imagePadding = 7
        sourceStyle.baseForegroundColor = .white
        sourceStyle.contentInsets = .zero
        source.configuration = sourceStyle
        source.addTarget(self, action: #selector(openSource), for: .touchUpInside)
        source.accessibilityHint = "Opens the organizer’s course page"

        let activity = makeLabel(TrailRoute.name, size: 19, weight: .semibold, style: .headline)
        let icon = UIImageView(image: UIImage(systemName: "figure.run"))
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let title = UIStackView(arrangedSubviews: [icon, activity])
        title.alignment = .center
        title.spacing = 7
        let location = makeLabel(TrailRoute.edition, size: 11, weight: .medium, style: .caption2)
        location.textColor = UIColor(white: 0.69, alpha: 1)
        let heading = UIStackView(arrangedSubviews: [title, location])
        courseHeading = heading

        metricRows = [
            UIStackView(arrangedSubviews: [
                RouteMetric(value: route.kilometers, unit: "KM", caption: "DISTANCE"),
                RouteMetric(value: TrailRoute.officialAscent.formatted(), unit: "M", caption: "COURSE ASCENT")
            ]),
            UIStackView(arrangedSubviews: [
                RouteMetric(value: Int(route.path.maximumElevationMeters.rounded()).formatted(), unit: "M", caption: "HIGHEST"),
                RouteMetric(value: Int(route.path.minimumElevationMeters.rounded()).formatted(), unit: "M", caption: "LOWEST")
            ])
        ]
        let metrics = UIStackView(arrangedSubviews: metricRows)
        metrics.axis = .vertical
        metrics.spacing = 20

        let profileTitle = makeLabel("Elevation", size: 19, weight: .semibold, style: .headline)
        let peak = makeLabel("▲\(Int(route.path.maximumElevationMeters.rounded()))m", size: 12, weight: .heavy, style: .caption1, width: .expanded)
        let profile = ElevationProfile(path: route.path)
        [source, heading, metrics, profileTitle, peak, profile].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            details.addSubview($0)
        }
        NSLayoutConstraint.activate([
            source.topAnchor.constraint(equalTo: details.topAnchor),
            source.centerXAnchor.constraint(equalTo: details.centerXAnchor),
            source.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor),
            source.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor),
            source.heightAnchor.constraint(greaterThanOrEqualToConstant: 33),
            heading.topAnchor.constraint(equalTo: source.bottomAnchor, constant: 4),
            heading.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: -6),
            heading.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: 6),
            metrics.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 21),
            metrics.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            metrics.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            profileTitle.topAnchor.constraint(equalTo: metrics.bottomAnchor, constant: 40),
            profileTitle.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            profileTitle.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor),
            peak.topAnchor.constraint(equalTo: profileTitle.bottomAnchor, constant: 15),
            peak.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            peak.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor),
            profile.topAnchor.constraint(equalTo: peak.bottomAnchor, constant: 6),
            profile.leadingAnchor.constraint(equalTo: details.leadingAnchor),
            profile.trailingAnchor.constraint(equalTo: details.trailingAnchor),
            profile.heightAnchor.constraint(equalToConstant: 124),
            profile.bottomAnchor.constraint(equalTo: details.bottomAnchor)
        ])
        return details
    }

    private func makeLabel(
        _ title: String, size: CGFloat, weight: UIFont.Weight, style: UIFont.TextStyle, width: UIFont.Width = .standard
    ) -> UILabel {
        let label = UILabel()
        label.text = title
        let baseFont = UIFont.systemFont(ofSize: size, weight: weight, width: width)
        label.font = UIFontMetrics(forTextStyle: style).scaledFont(for: baseFont, compatibleWith: traitCollection)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textColor = .white
        return label
    }

    private func updateDetailsLayout() {
        let singleColumn = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        courseHeading?.axis = singleColumn ? .vertical : .horizontal
        courseHeading?.alignment = singleColumn ? .fill : .center
        courseHeading?.spacing = singleColumn ? 4 : 10
        let location = courseHeading?.arrangedSubviews.last as? UILabel
        location?.textAlignment = singleColumn ? .natural : .right

        for row in metricRows {
            row.axis = singleColumn ? .vertical : .horizontal
            row.distribution = singleColumn ? .fill : .fillEqually
            row.spacing = singleColumn ? 20 : 40
        }
    }

    @objc private func togglePlayback() {
        guard let preview else { return }
        preview.setAutoplayEnabled(!preview.state.isAutoplayEnabled)
    }

    @objc private func showElevation() {
        preview?.setPresentation(.threeDimensional)
    }

    @objc private func showPlan() {
        preview?.setPresentation(.overhead)
    }

    @objc private func toggleManualRotation() {
        guard let preview else { return }
        preview.setManualRotationEnabled(!preview.state.isManualRotationEnabled)
    }

    @objc private func toggleExpanded() {
        expanded.toggle()
        scroll.isScrollEnabled = !expanded
        scroll.setContentOffset(.zero, animated: false)
        details?.isHidden = expanded
        configureExpand()
        updateStageHeight()
        view.layoutIfNeeded()
    }

    @objc private func openSource() {
        UIApplication.shared.open(TrailRoute.source)
    }

    @objc private func shareRoute() {
        guard let route, shareController == nil, presentedViewController == nil else { return }
        let controller = UIActivityViewController(activityItems: [route.fileURL], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = share
        controller.popoverPresentationController?.sourceRect = share.bounds
        controller.presentationController?.delegate = self
        controller.completionWithItemsHandler = { [weak self, weak controller] _, _, _, _ in
            guard let self, let controller else { return }
            if let coordinator = controller.transitionCoordinator, coordinator.animate(
                alongsideTransition: nil,
                completion: { _ in self.finishSharing(controller) }
            ) {
                return
            }
            self.finishSharing(controller)
        }
        shareController = controller
        updatePreviewVisibility()
        present(controller, animated: true)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        finishSharing(presentationController.presentedViewController)
    }

    private func finishSharing(_ controller: UIViewController) {
        guard shareController === controller else { return }
        shareController = nil
        updatePreviewVisibility()
    }
}

private final class RouteMetric: UIStackView {
    private let number = UILabel()
    private let value: String
    private let unit: String

    init(value: String, unit: String, caption: String) {
        self.value = value
        self.unit = unit
        super.init(frame: .zero)
        axis = .vertical
        spacing = 1
        isAccessibilityElement = true
        accessibilityLabel = caption + ", " + value + (unit == "KM" ? " kilometers" : " meters")

        number.adjustsFontSizeToFitWidth = true
        number.minimumScaleFactor = 0.64
        addArrangedSubview(number)

        let label = UILabel()
        label.text = caption
        label.numberOfLines = 0
        label.textColor = .white
        let baseFont = UIFont.systemFont(ofSize: 11, weight: .medium, width: .expanded)
        label.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(for: baseFont, compatibleWith: traitCollection)
        label.adjustsFontForContentSizeCategory = true
        addArrangedSubview(label)

        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (metric: RouteMetric, _) in metric.updateNumber()
        }
        updateNumber()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Use init(value:unit:caption:)") }

    private func updateNumber() {
        let numberFont = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(
            for: .monospacedSystemFont(ofSize: 37, weight: .regular), compatibleWith: traitCollection
        )
        let unitFont = UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: .monospacedSystemFont(ofSize: 13, weight: .semibold), compatibleWith: traitCollection
        )
        let text = NSMutableAttributedString(string: value, attributes: [.font: numberFont, .foregroundColor: UIColor.white])
        let unitLift = min(15, max(0, numberFont.capHeight - unitFont.capHeight))
        text.append(NSAttributedString(
            string: " " + unit,
            attributes: [.font: unitFont, .baselineOffset: unitLift, .foregroundColor: UIColor.white]
        ))
        number.attributedText = text
    }
}

private final class OverheadRouteView: UIView {
    private let track: [SIMD4<Float>]

    init(path: Route3DPath) {
        track = path.track
        super.init(frame: .zero)
        isOpaque = false
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityLabel = "Overhead trail route"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(path:)") }

    override func draw(_ rect: CGRect) {
        guard let first = track.first else { return }
        let span = min(bounds.width, bounds.height) * 0.94
        func project(_ point: SIMD4<Float>) -> CGPoint {
            CGPoint(x: bounds.midX + CGFloat(point.x) * span, y: bounds.midY + CGFloat(point.z) * span)
        }
        let path = UIBezierPath()
        path.move(to: project(first))
        for point in track.dropFirst() {
            path.addLine(to: project(point))
        }
        path.lineWidth = 2
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        UIColor.white.setStroke()
        path.stroke()
    }
}

private final class RouteBackdrop: UIView {
    private let shading = CAGradientLayer()
    private let textureFade = CAGradientLayer()
    private let texture = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        shading.colors = [
            UIColor(white: 0.092, alpha: 1).cgColor,
            UIColor(white: 0.101, alpha: 1).cgColor,
            UIColor(white: 0.091, alpha: 1).cgColor,
            UIColor.black.cgColor
        ]
        shading.locations = [0, 0.32, 0.55, 0.82]
        layer.addSublayer(shading)

        let tile = UIGraphicsImageRenderer(size: CGSize(width: 5, height: 5)).image { context in
            let colors = [
                UIColor.white.withAlphaComponent(0.016).cgColor,
                UIColor.white.withAlphaComponent(0).cgColor
            ] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: nil)!
            let center = CGPoint(x: 2.5, y: 2.5)
            context.cgContext.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                                endCenter: center, endRadius: 2.5, options: [])
        }
        texture.backgroundColor = UIColor(patternImage: tile).cgColor
        textureFade.colors = [
            UIColor.black.withAlphaComponent(0.4).cgColor, UIColor.black.cgColor,
            UIColor.black.cgColor, UIColor.clear.cgColor
        ]
        textureFade.locations = [0, 0.19, 0.55, 0.73]
        texture.mask = textureFade
        layer.addSublayer(texture)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override func layoutSubviews() {
        super.layoutSubviews()
        shading.frame = bounds
        texture.frame = bounds
        textureFade.frame = bounds
    }
}

private final class ElevationProfile: UIView {
    private let points: [CGPoint]

    init(path: Route3DPath) {
        let high = path.maximumElevationMeters
        let range = max(1, high - path.minimumElevationMeters)
        points = path.samples.map {
            CGPoint(x: $0.distance / path.distanceMeters, y: (high - $0.elevation) / range)
        }
        super.init(frame: .zero)
        isOpaque = false
        accessibilityLabel = "Elevation profile"
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(path:)") }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let first = points.first, let last = points.last else { return }
        let chart = bounds.insetBy(dx: 3, dy: 4)
        func scaled(_ point: CGPoint) -> CGPoint {
            CGPoint(x: chart.minX + chart.width * point.x, y: chart.minY + chart.height * point.y)
        }

        let line = CGMutablePath()
        line.move(to: scaled(first))
        for point in points.dropFirst() { line.addLine(to: scaled(point)) }
        let fill = line.mutableCopy()!
        fill.addLine(to: CGPoint(x: scaled(last).x, y: bounds.maxY))
        fill.addLine(to: CGPoint(x: scaled(first).x, y: bounds.maxY))
        fill.closeSubpath()

        context.saveGState()
        context.addPath(fill)
        context.clip()
        let colors = [UIColor.white.withAlphaComponent(0.19).cgColor, UIColor.white.withAlphaComponent(0.025).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: nil) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: bounds.maxY), options: [])
        }
        context.restoreGState()

        context.addPath(line)
        context.setStrokeColor(UIColor.white.cgColor)
        context.setLineWidth(2.1)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.strokePath()
    }
}

private enum RouteModeImage {
    static func make(isElevation: Bool) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 32, height: 28)).image { _ in
            UIColor.white.setStroke()
            let path = UIBezierPath()
            path.lineWidth = 1.25
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            if isElevation {
                path.move(to: CGPoint(x: 3, y: 25))
                path.addLine(to: CGPoint(x: 29, y: 17))
                path.addLine(to: CGPoint(x: 29, y: 4))
                path.addQuadCurve(to: CGPoint(x: 24, y: 4), controlPoint: CGPoint(x: 28, y: 0))
                path.addLine(to: CGPoint(x: 19, y: 11))
                path.addLine(to: CGPoint(x: 14, y: 11))
                path.addLine(to: CGPoint(x: 8, y: 18))
                path.addLine(to: CGPoint(x: 3, y: 18))
                path.close()
                path.stroke()
                let ridge = UIBezierPath()
                ridge.move(to: CGPoint(x: 3, y: 25))
                ridge.addLine(to: CGPoint(x: 3, y: 18))
                ridge.addLine(to: CGPoint(x: 8, y: 18))
                ridge.addLine(to: CGPoint(x: 14, y: 11))
                ridge.addLine(to: CGPoint(x: 19, y: 11))
                ridge.addLine(to: CGPoint(x: 24, y: 4))
                ridge.lineWidth = 3.4
                ridge.lineCapStyle = .round
                ridge.lineJoinStyle = .round
                ridge.stroke()
            } else {
                path.move(to: CGPoint(x: 6, y: 8))
                path.addLine(to: CGPoint(x: 6, y: 22))
                path.addQuadCurve(to: CGPoint(x: 12, y: 23), controlPoint: CGPoint(x: 8, y: 30))
                path.addCurve(to: CGPoint(x: 20, y: 12), controlPoint1: CGPoint(x: 14, y: 15), controlPoint2: CGPoint(x: 15, y: 17))
                path.addCurve(to: CGPoint(x: 26, y: 7), controlPoint1: CGPoint(x: 23, y: 3), controlPoint2: CGPoint(x: 26, y: 0))
                path.addLine(to: CGPoint(x: 26, y: 19))
                path.append(UIBezierPath(ovalIn: CGRect(x: 3, y: 2, width: 6, height: 6)))
                path.append(UIBezierPath(ovalIn: CGRect(x: 23, y: 19, width: 6, height: 6)))
                path.stroke()
            }
        }
    }
}
