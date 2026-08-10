import UIKit

/// Presentation-only ordinary keyboard key. The controller owns actions,
/// committed characters, layout membership, Shift/Rime state, and hit routing.
final class KeyboardTextKeyControl: UIButton {
    private var renderedTitle = ""
    private var renderedSecondaryTitle: String?
    private var renderedImageName: String?
    private var renderedRole: KeyboardTextKeyRole = .normal
    private var renderedStyle: UIUserInterfaceStyle = .light

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            setNeedsUpdateConfiguration()
            applyCurrentConfiguration()
        }
    }

    func render(
        title: String,
        secondaryTitle: String? = nil,
        imageName: String?,
        role: KeyboardTextKeyRole,
        style: UIUserInterfaceStyle
    ) {
        renderedTitle = title
        renderedSecondaryTitle = secondaryTitle
        renderedImageName = imageName
        renderedRole = role
        renderedStyle = style
        overrideUserInterfaceStyle = style
        accessibilityLabel = title.isEmpty ? imageName : title
        accessibilityValue = secondaryTitle == nil ? nil : title
        applyCurrentConfiguration()
    }

    func refreshAppearance(style: UIUserInterfaceStyle) {
        guard renderedStyle != style || overrideUserInterfaceStyle != style else {
            applyCurrentConfiguration()
            return
        }
        renderedStyle = style
        overrideUserInterfaceStyle = style
        applyCurrentConfiguration()
    }

    private func configure() {
        titleLabel?.adjustsFontSizeToFitWidth = true
        titleLabel?.minimumScaleFactor = 0.7
        titleLabel?.numberOfLines = 1
        titleLabel?.lineBreakMode = .byClipping
    }

    override func updateConfiguration() {
        super.updateConfiguration()
        applyCurrentConfiguration()
    }

    private func applyCurrentConfiguration() {
        let isPressed = isHighlighted
        configuration = makeConfiguration(isPressed: isPressed, isEnabled: isEnabled)
        applyLayerStyle(isPressed: isPressed, isEnabled: isEnabled)
    }

    private func makeConfiguration(isPressed: Bool, isEnabled: Bool) -> UIButton.Configuration {
        let typography = KeyboardTextKeyVisualPolicy.typography(
            title: renderedTitle,
            hasImage: renderedImageName != nil,
            role: renderedRole
        )
        var configuration = UIButton.Configuration.filled()
        let showsSecondaryTitle = renderedSecondaryTitle?.isEmpty == false
        configuration.title = showsSecondaryTitle ? renderedSecondaryTitle : renderedTitle
        configuration.subtitle = showsSecondaryTitle ? renderedTitle : nil
        configuration.image = renderedImageName.flatMap { UIImage(systemName: $0) }
        if renderedImageName != nil {
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
                pointSize: CGFloat(KeyboardTextKeyVisualPolicy.iconPointSize),
                weight: .regular
            )
        }
        configuration.titleLineBreakMode = .byClipping
        configuration.cornerStyle = .fixed
        configuration.background.cornerRadius = CGFloat(KeyboardTextKeyVisualPolicy.cornerRadius)
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: showsSecondaryTitle ? 1 : CGFloat(typography.topInset),
            leading: CGFloat(KeyboardTextKeyVisualPolicy.horizontalContentInset),
            bottom: showsSecondaryTitle ? 1 : CGFloat(typography.bottomInset),
            trailing: CGFloat(KeyboardTextKeyVisualPolicy.horizontalContentInset)
        )
        configuration.baseForegroundColor = foregroundColor(isEnabled: isEnabled)
        configuration.baseBackgroundColor = backgroundColor(
            isPressed: isPressed,
            isEnabled: isEnabled
        )
        configuration.background.strokeWidth = isPressed ? 0 : 0.35
        configuration.background.strokeColor = UIColor.separator.withAlphaComponent(
            renderedStyle == .dark ? 0.18 : 0.10
        )
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            if showsSecondaryTitle {
                outgoing.font = .systemFont(ofSize: 10, weight: .regular)
                outgoing.foregroundColor = .secondaryLabel
                return outgoing
            }
            let weight: UIFont.Weight = typography.weight == .medium ? .medium : .regular
            outgoing.font = .systemFont(ofSize: CGFloat(typography.pointSize), weight: weight)
            return outgoing
        }
        if showsSecondaryTitle {
            configuration.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                let weight: UIFont.Weight = typography.weight == .medium ? .medium : .regular
                outgoing.font = .systemFont(
                    ofSize: CGFloat(max(17, typography.pointSize - 1)),
                    weight: weight
                )
                outgoing.foregroundColor = .label
                return outgoing
            }
        }
        return configuration
    }

    private func applyLayerStyle(isPressed: Bool, isEnabled: Bool) {
        layer.cornerRadius = CGFloat(KeyboardTextKeyVisualPolicy.cornerRadius)
        layer.cornerCurve = .continuous
        layer.masksToBounds = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: isPressed ? 0 : 0.3)
        layer.shadowRadius = 0
        let baseOpacity = Float(KeyboardTextKeyVisualPolicy.shadowOpacity(
            role: renderedRole,
            isDark: renderedStyle == .dark
        ))
        let enabledOpacity = isEnabled ? baseOpacity : baseOpacity * 0.45
        layer.shadowOpacity = isPressed ? enabledOpacity * 0.4 : enabledOpacity
        layer.borderWidth = isPressed ? 0.5 : 0
        layer.borderColor = UIColor.label.withAlphaComponent(
            renderedStyle == .dark ? 0.08 : 0.05
        ).cgColor
    }

    private func foregroundColor(isEnabled: Bool) -> UIColor {
        let role = renderedRole
        return UIColor { traits in
            guard isEnabled else {
                return traits.userInterfaceStyle == .dark
                    ? UIColor.white.withAlphaComponent(0.35)
                    : UIColor.black.withAlphaComponent(0.28)
            }
            return role == .action ? .white : .label
        }
    }

    private func backgroundColor(isPressed: Bool, isEnabled: Bool) -> UIColor {
        let role = renderedRole
        return UIColor { traits in
            if role == .action, isEnabled {
                return isPressed
                    ? UIColor.systemBlue.withAlphaComponent(0.76)
                    : UIColor.systemBlue
            }
            if traits.userInterfaceStyle == .dark {
                return UIColor(
                    white: isPressed && isEnabled ? 0.42 : 68.0 / 255.0,
                    alpha: 1
                )
            }
            return UIColor(white: isPressed && isEnabled ? 0.78 : 1, alpha: 1)
        }
    }
}
