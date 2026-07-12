import UIKit

enum KeyboardVoiceOrbCenterContent {
    case symbol(name: String, pointSize: CGFloat)
    case voiceprint
    case spinner
    case empty
}

struct KeyboardVoiceOrbPresentation {
    let gradient: OrbGradient
    let centerContent: KeyboardVoiceOrbCenterContent
    let pulseTint: UIColor
    let pulsesActive: Bool
}

/// Owns the Voice Orb's UIKit rendering only. Recording lifecycle, Bridge
/// state, input mode, and actions remain in `KeyboardViewController`.
final class KeyboardVoiceOrbControl: UIButton {
    private let hitOutset: CGFloat = 10
    private let orbView = UIView()
    private let gradientLayer = CAGradientLayer()
    private let highlightLayer = CAGradientLayer()
    private let iconView = UIImageView()
    private let voicePrintView = VoicePrintView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private var pulseRings: [CAShapeLayer] = []
    private var smoothedAudioLevel: Float = 0
    private var pulseTint: UIColor = .systemBlue
    private var lastRingBoundsSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return false }
        return bounds.insetBy(dx: -hitOutset, dy: -hitOutset).contains(point)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let diameter = min(bounds.width, bounds.height)
        guard diameter > 0 else { return }

        orbView.layer.cornerRadius = diameter / 2
        gradientLayer.frame = orbView.bounds
        gradientLayer.cornerRadius = diameter / 2

        let highlightWidth = diameter * CGFloat(VoiceOrbVisualPolicy.highlightWidthRatio)
        let highlightHeight = diameter * CGFloat(VoiceOrbVisualPolicy.highlightHeightRatio)
        highlightLayer.frame = CGRect(
            x: diameter * CGFloat(VoiceOrbVisualPolicy.highlightCenterXRatio) - highlightWidth / 2,
            y: diameter * CGFloat(VoiceOrbVisualPolicy.highlightCenterYRatio) - highlightHeight / 2,
            width: highlightWidth,
            height: highlightHeight
        )

        orbView.layer.shadowRadius = diameter * CGFloat(VoiceOrbVisualPolicy.shadowRadiusRatio)
        orbView.layer.shadowOffset = CGSize(
            width: 0,
            height: diameter * CGFloat(VoiceOrbVisualPolicy.shadowOffsetYRatio)
        )

        if lastRingBoundsSize != bounds.size {
            lastRingBoundsSize = bounds.size
            let path = UIBezierPath(ovalIn: bounds).cgPath
            for ring in pulseRings {
                ring.frame = bounds
                ring.path = path
            }
        }
    }

    func render(_ presentation: KeyboardVoiceOrbPresentation, animated: Bool) {
        pulseTint = presentation.pulseTint
        // `OrbGradient.stops` is the UIKit source; use it directly rather than
        // relying on SwiftUI Color resolution in the extension process.
        let stops = presentation.gradient.stops
        let gradientColors = [stops.top.cgColor, stops.bottom.cgColor]
        orbView.layer.shadowColor = stops.bottom.cgColor

        let applyCenterContent = { [self] in
            switch presentation.centerContent {
            case let .symbol(name, pointSize):
                iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
                    pointSize: pointSize,
                    weight: .medium
                )
                iconView.image = Self.symbolImage(named: name)
                iconView.alpha = 1
                voicePrintView.alpha = 0
                voicePrintView.isActive = false
                spinner.alpha = 0
                spinner.stopAnimating()
            case .voiceprint:
                iconView.alpha = 0
                voicePrintView.alpha = 1
                voicePrintView.isActive = true
                spinner.alpha = 0
                spinner.stopAnimating()
            case .spinner:
                iconView.alpha = 0
                voicePrintView.alpha = 0
                voicePrintView.isActive = false
                spinner.alpha = 1
                spinner.startAnimating()
            case .empty:
                iconView.alpha = 0
                voicePrintView.alpha = 0
                voicePrintView.isActive = false
                spinner.alpha = 0
                spinner.stopAnimating()
            }
        }

        if animated, window != nil {
            UIView.transition(
                with: self,
                duration: 0.22,
                options: [.transitionCrossDissolve, .allowUserInteraction],
                animations: applyCenterContent
            )
            let animation = CABasicAnimation(keyPath: "colors")
            animation.fromValue = gradientLayer.colors
            animation.toValue = gradientColors
            animation.duration = 0.22
            gradientLayer.colors = gradientColors
            gradientLayer.add(animation, forKey: "colors")
        } else {
            applyCenterContent()
            gradientLayer.colors = gradientColors
        }

        if presentation.pulsesActive {
            startPulseRings()
        } else {
            stopPulseRings()
        }
    }

    func updateAudioLevel(_ level: Float?) {
        voicePrintView.updateLevel(level)
        let normalized = max(0, min(1, level ?? 0))
        smoothedAudioLevel = Float(VoiceOrbVisualPolicy.pulseAudioPreviousLevelWeight) * smoothedAudioLevel
            + Float(VoiceOrbVisualPolicy.pulseAudioNewLevelWeight) * normalized
        let alpha = min(
            CGFloat(VoiceOrbVisualPolicy.pulseAudioMaximumOpacity),
            CGFloat(VoiceOrbVisualPolicy.pulseAudioBaselineOpacity)
                + CGFloat(smoothedAudioLevel) * CGFloat(VoiceOrbVisualPolicy.pulseAudioLevelContribution)
        )
        let color = pulseTint.resolvedColor(with: traitCollection).withAlphaComponent(alpha).cgColor
        for ring in pulseRings {
            ring.strokeColor = color
        }
    }

    func refreshAppearance(style: UIUserInterfaceStyle) {
        overrideUserInterfaceStyle = style
        let isDark = style == .dark
        orbView.layer.shadowOpacity = isDark ? 0.5 : 0.42
        orbView.layer.borderColor = UIColor.white
            .withAlphaComponent(isDark ? 0.28 : 0.22)
            .cgColor
        let traits = UITraitCollection(userInterfaceStyle: style)
        for ring in pulseRings {
            ring.strokeColor = pulseTint.resolvedColor(with: traits).cgColor
        }
    }

    func animatePressed() {
        UIView.animate(
            withDuration: 0.12,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.orbView.transform = CGAffineTransform(
                scaleX: CGFloat(VoiceOrbVisualPolicy.pressedScale),
                y: CGFloat(VoiceOrbVisualPolicy.pressedScale)
            )
            self.alpha = 1
        }
    }

    func animateReleased(spring: Bool) {
        if spring {
            UIView.animate(
                withDuration: 0.32,
                delay: 0,
                usingSpringWithDamping: 0.55,
                initialSpringVelocity: 0.5,
                options: [.allowUserInteraction, .beginFromCurrentState]
            ) {
                self.orbView.transform = .identity
                self.alpha = 1
            }
        } else {
            UIView.animate(
                withDuration: 0.18,
                delay: 0,
                options: [.allowUserInteraction, .beginFromCurrentState]
            ) {
                self.orbView.transform = .identity
                self.alpha = 1
            }
        }
    }

    func stopActivity() {
        voicePrintView.isActive = false
        stopPulseRings()
    }

    private func configure() {
        orbView.isUserInteractionEnabled = false
        orbView.translatesAutoresizingMaskIntoConstraints = false
        orbView.layer.cornerCurve = .continuous
        orbView.layer.shadowColor = UIColor.systemBlue.cgColor
        orbView.layer.shadowOpacity = 0.42
        orbView.layer.borderWidth = CGFloat(VoiceOrbVisualPolicy.borderWidth)
        orbView.layer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor

        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
        gradientLayer.cornerCurve = .continuous
        gradientLayer.masksToBounds = true
        orbView.layer.insertSublayer(gradientLayer, at: 0)

        highlightLayer.type = .radial
        highlightLayer.colors = [
            UIColor.white.withAlphaComponent(0.32).cgColor,
            UIColor.white.withAlphaComponent(0).cgColor,
        ]
        highlightLayer.locations = [0, 1]
        highlightLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        highlightLayer.endPoint = CGPoint(x: 1, y: 1)
        orbView.layer.addSublayer(highlightLayer)

        for _ in 0..<VoiceOrbVisualPolicy.pulseRingCount {
            let ring = CAShapeLayer()
            ring.fillColor = UIColor.clear.cgColor
            ring.strokeColor = UIColor.systemRed.withAlphaComponent(0.55).cgColor
            ring.lineWidth = CGFloat(VoiceOrbVisualPolicy.pulseRingLineWidth)
            ring.opacity = 0
            layer.insertSublayer(ring, at: 0)
            pulseRings.append(ring)
        }

        addSubview(orbView)

        voicePrintView.translatesAutoresizingMaskIntoConstraints = false
        voicePrintView.isUserInteractionEnabled = false
        voicePrintView.tint = .white
        voicePrintView.alpha = 0
        orbView.addSubview(voicePrintView)

        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = .white
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = Self.symbolImage(named: "mic.fill")
        orbView.addSubview(iconView)

        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        orbView.addSubview(spinner)

        NSLayoutConstraint.activate([
            orbView.leadingAnchor.constraint(equalTo: leadingAnchor),
            orbView.trailingAnchor.constraint(equalTo: trailingAnchor),
            orbView.topAnchor.constraint(equalTo: topAnchor),
            orbView.bottomAnchor.constraint(equalTo: bottomAnchor),

            voicePrintView.widthAnchor.constraint(
                equalTo: orbView.widthAnchor,
                multiplier: CGFloat(VoiceOrbVisualPolicy.voiceprintWidthRatio)
            ),
            voicePrintView.heightAnchor.constraint(
                equalTo: orbView.heightAnchor,
                multiplier: CGFloat(VoiceOrbVisualPolicy.voiceprintHeightRatio)
            ),
            voicePrintView.centerXAnchor.constraint(equalTo: orbView.centerXAnchor),
            voicePrintView.centerYAnchor.constraint(equalTo: orbView.centerYAnchor),

            iconView.widthAnchor.constraint(
                equalTo: orbView.widthAnchor,
                multiplier: CGFloat(VoiceOrbVisualPolicy.iconFrameRatio)
            ),
            iconView.heightAnchor.constraint(
                equalTo: orbView.heightAnchor,
                multiplier: CGFloat(VoiceOrbVisualPolicy.iconFrameRatio)
            ),
            iconView.centerXAnchor.constraint(equalTo: orbView.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: orbView.centerYAnchor),

            spinner.centerXAnchor.constraint(equalTo: orbView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: orbView.centerYAnchor),
        ])
    }

    private func startPulseRings() {
        let color = pulseTint.cgColor
        for (index, ring) in pulseRings.enumerated()
        where ring.animation(forKey: "pulse.scale") == nil {
            ring.strokeColor = color
            ring.opacity = 0

            let begin = CACurrentMediaTime()
                + Double(index) * VoiceOrbVisualPolicy.pulsePhaseOffset
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1.0
            scale.toValue = VoiceOrbVisualPolicy.pulseMaximumScale
            scale.duration = VoiceOrbVisualPolicy.pulseDuration
            scale.beginTime = begin
            scale.repeatCount = .infinity
            scale.timingFunction = CAMediaTimingFunction(name: .easeOut)

            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0.0, VoiceOrbVisualPolicy.pulsePeakOpacity, 0.0]
            opacity.keyTimes = [0.0, 0.15, 1.0]
            opacity.duration = VoiceOrbVisualPolicy.pulseDuration
            opacity.beginTime = begin
            opacity.repeatCount = .infinity

            ring.add(scale, forKey: "pulse.scale")
            ring.add(opacity, forKey: "pulse.opacity")
        }
    }

    private func stopPulseRings() {
        for ring in pulseRings {
            ring.removeAllAnimations()
            ring.opacity = 0
        }
        smoothedAudioLevel = 0
    }

    private static var symbolImageCache: [String: UIImage] = [:]

    private static func symbolImage(named name: String) -> UIImage? {
        if let cached = symbolImageCache[name] { return cached }
        guard let image = UIImage(systemName: name) else { return nil }
        symbolImageCache[name] = image
        return image
    }
}

/// Core Animation voiceprint used by the orb and toolbar. It avoids a
/// per-frame display link because keyboard-extension run loops are unreliable.
final class VoicePrintView: UIView {
    var level: Float = 0 {
        didSet {
            targetLevel = max(0, min(1, level))
            applyLiveLevel()
        }
    }

    var isActive: Bool = false {
        didSet {
            guard isActive != oldValue else { return }
            isActive ? start() : stop()
        }
    }

    var tint: UIColor = .white {
        didSet { barLayers.forEach { $0.backgroundColor = tint.cgColor } }
    }

    func updateLevel(_ level: Float?) {
        guard let level else { return }
        self.level = level
    }

    private let barCount = 9
    private var barLayers: [CALayer] = []
    private var targetLevel: Float = 0
    private var isAnimatingBars = false
    private var animationLevelBucket = -1

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        setupBars()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    isolated deinit {
        stopBarAnimations()
    }

    private func setupBars() {
        for _ in 0..<barCount {
            let layer = CALayer()
            layer.backgroundColor = tint.cgColor
            layer.opacity = 1
            layer.cornerRadius = 2.5
            layer.cornerCurve = .continuous
            self.layer.addSublayer(layer)
            barLayers.append(layer)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutBars()
    }

    private func layoutBars() {
        let width = bounds.width
        let height = bounds.height
        guard width > 0, height > 0 else { return }
        let barWidth: CGFloat = 5
        let totalBars = CGFloat(barCount)
        let gap = (width - totalBars * barWidth) / (totalBars + 1)
        let centerY = height / 2
        let baseHeight = max(6, height * 0.12)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, layer) in barLayers.enumerated() {
            let x = gap + CGFloat(index) * (barWidth + gap)
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.bounds = CGRect(x: 0, y: 0, width: barWidth, height: baseHeight)
            layer.position = CGPoint(x: x + barWidth / 2, y: centerY)
        }
        CATransaction.commit()
        if isActive {
            restartBarAnimations()
        }
    }

    private func start() {
        animationLevelBucket = -1
        setNeedsLayout()
        layoutIfNeeded()
        startBarAnimations()
    }

    private func stop() {
        stopBarAnimations()
        targetLevel = 0
        animationLevelBucket = -1
        layoutBars()
    }

    private func startBarAnimations() {
        guard !isAnimatingBars else { return }
        isAnimatingBars = true
        installBarAnimations(level: targetLevel)
    }

    private func restartBarAnimations() {
        guard isAnimatingBars else { return }
        installBarAnimations(level: targetLevel)
    }

    private func installBarAnimations(level: Float) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let bucket = Int((max(0, min(1, level)) * 6).rounded())
        guard bucket != animationLevelBucket
                || barLayers.contains(where: { $0.animation(forKey: "voiceprint.breathe") == nil })
        else { return }
        animationLevelBucket = bucket
        let normalizedLevel = CGFloat(bucket) / 6.0
        let now = CACurrentMediaTime()
        for (index, layer) in barLayers.enumerated() {
            layer.removeAnimation(forKey: "voiceprint.breathe")
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            let animation = CAKeyframeAnimation(keyPath: "bounds.size.height")
            let duration: CFTimeInterval = 1.08
            let sampleCount = 18
            animation.values = (0..<sampleCount).map { sample in
                let time = Double(sample) / Double(sampleCount - 1)
                return NSNumber(value: Double(Self.barHeight(
                    index: index,
                    barCount: barCount,
                    containerHeight: bounds.height,
                    level: normalizedLevel,
                    phase: time * duration
                )))
            }
            animation.keyTimes = (0..<sampleCount).map { sample in
                NSNumber(value: Double(sample) / Double(sampleCount - 1))
            }
            animation.duration = duration
            animation.beginTime = now
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            animation.calculationMode = .linear
            layer.add(animation, forKey: "voiceprint.breathe")
        }
    }

    private func stopBarAnimations() {
        guard isAnimatingBars else { return }
        isAnimatingBars = false
        for layer in barLayers {
            layer.removeAnimation(forKey: "voiceprint.breathe")
            layer.transform = CATransform3DIdentity
            layer.speed = 1
        }
    }

    private func applyLiveLevel() {
        guard isActive else { return }
        installBarAnimations(level: targetLevel)
    }

    private static func barHeight(
        index: Int,
        barCount: Int,
        containerHeight: CGFloat,
        level: CGFloat,
        phase: CFTimeInterval
    ) -> CGFloat {
        let minimumHeight = max(6, containerHeight * 0.12)
        let maximumHeight = containerHeight * 0.95
        let centerBias = abs(Double(index) - Double(barCount - 1) / 2.0)
            / (Double(barCount - 1) / 2.0)
        let centerBoost = 1.0 - centerBias * 0.30
        let bandPhase = Double(index) * 0.55
        let sine = sin(phase * 5.4 + bandPhase) * 0.55
            + sin(phase * 11.1 + bandPhase * 2.3) * 0.45
        let waveform = CGFloat((sine + 1) / 2)
        let envelope = min(1.0, 0.22 + level * 1.05)
        let modulation = envelope * CGFloat(centerBoost) * (0.35 + 0.65 * waveform)
        return max(
            minimumHeight,
            min(maximumHeight, minimumHeight + (maximumHeight - minimumHeight) * modulation)
        )
    }
}
