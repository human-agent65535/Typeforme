import UIKit

/// Presentation-only ordinary keyboard key. The controller owns actions,
/// committed characters, layout membership, Shift/Rime state, and hit routing.
final class KeyboardTextKeyControl: UIButton {
    private var renderedTitle = ""
    private var renderedSecondaryTitle: String?
    private var renderedImageName: String?
    private var renderedRole: KeyboardTextKeyRole = .normal
    private var renderedVisualProfile: KeyboardTextKeyVisualProfile = .compact
    private var renderedStackedLegendStyle: KeyboardTextKeyStackedLegendStyle = .alternateHint
    private var renderedContentPlacement: KeyboardTextKeyContentPlacement = .centered
    private var renderedStyle: UIUserInterfaceStyle = .light
    private var isFlickAlternateSelected = false

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
        visualProfile: KeyboardTextKeyVisualProfile,
        stackedLegendStyle: KeyboardTextKeyStackedLegendStyle = .alternateHint,
        contentPlacement: KeyboardTextKeyContentPlacement? = nil,
        style: UIUserInterfaceStyle
    ) {
        isFlickAlternateSelected = false
        titleLabel?.layer.removeAllAnimations()
        titleLabel?.transform = .identity
        titleLabel?.alpha = 1
        renderedTitle = title
        renderedSecondaryTitle = secondaryTitle
        renderedImageName = imageName
        renderedRole = role
        renderedVisualProfile = visualProfile
        renderedStackedLegendStyle = stackedLegendStyle
        if let contentPlacement {
            renderedContentPlacement = contentPlacement
        }
        renderedStyle = style
        overrideUserInterfaceStyle = style
        accessibilityLabel = title.isEmpty ? imageName : title
        accessibilityValue = secondaryTitle == nil ? nil : title
        applyCurrentConfiguration()
    }

    /// Promotes the upper legend into the key's primary position once a
    /// downward flick crosses its commit threshold. The button remains the
    /// real hit target; only its configuration content moves, so feedback can
    /// never diverge from the controller's touch geometry.
    func setFlickAlternateSelected(_ selected: Bool, animated: Bool) {
        guard renderedSecondaryTitle?.isEmpty == false else { return }
        guard isFlickAlternateSelected != selected else { return }
        isFlickAlternateSelected = selected

        titleLabel?.layer.removeAllAnimations()
        if !animated {
            titleLabel?.transform = .identity
            titleLabel?.alpha = 1
            applyCurrentConfiguration()
            return
        }

        if selected {
            UIView.performWithoutAnimation {
                self.applyCurrentConfiguration()
                self.layoutIfNeeded()
                self.titleLabel?.transform = CGAffineTransform(translationX: 0, y: -12)
                    .scaledBy(x: 0.72, y: 0.72)
                self.titleLabel?.alpha = 0.68
            }
            UIView.animate(
                withDuration: 0.14,
                delay: 0,
                usingSpringWithDamping: 0.82,
                initialSpringVelocity: 0.2,
                options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
            ) {
                self.titleLabel?.transform = .identity
                self.titleLabel?.alpha = 1
            }
        } else {
            titleLabel?.transform = .identity
            titleLabel?.alpha = 1
            UIView.transition(
                with: self,
                duration: 0.10,
                options: [.transitionCrossDissolve, .beginFromCurrentState, .allowUserInteraction]
            ) {
                self.applyCurrentConfiguration()
            }
        }
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
        applyContentAlignment()
        configuration = makeConfiguration(isPressed: isPressed, isEnabled: isEnabled)
        applyOpticalContentScale()
        applyLayerStyle(isPressed: isPressed, isEnabled: isEnabled)
    }

    private func applyContentAlignment() {
        switch renderedContentPlacement {
        case .centered:
            contentHorizontalAlignment = .center
            contentVerticalAlignment = .center
        case .leadingCenter:
            contentHorizontalAlignment = .leading
            contentVerticalAlignment = .center
        case .trailingCenter:
            contentHorizontalAlignment = .trailing
            contentVerticalAlignment = .center
        case .leadingBottom:
            contentHorizontalAlignment = .leading
            contentVerticalAlignment = .bottom
        case .trailingBottom:
            contentHorizontalAlignment = .trailing
            contentVerticalAlignment = .bottom
        }
    }

    private func applyOpticalContentScale() {
        let scale = KeyboardTextKeyVisualPolicy.contentScale(
            title: renderedTitle,
            role: renderedRole,
            profile: renderedVisualProfile
        )
        titleLabel?.transform = CGAffineTransform(
            scaleX: CGFloat(scale.horizontal),
            y: CGFloat(scale.vertical)
        )
    }

    private func makeConfiguration(isPressed: Bool, isEnabled: Bool) -> UIButton.Configuration {
        let visualProfile = renderedVisualProfile
        let stackedLegendStyle = renderedStackedLegendStyle
        let typography = KeyboardTextKeyVisualPolicy.typography(
            title: renderedTitle,
            hasImage: renderedImageName != nil,
            role: renderedRole,
            profile: visualProfile
        )
        var configuration = UIButton.Configuration.filled()
        let hasSecondaryTitle = renderedSecondaryTitle?.isEmpty == false
        let showsSelectedAlternate = hasSecondaryTitle && isFlickAlternateSelected
        let showsSecondaryTitle = hasSecondaryTitle && !showsSelectedAlternate
        configuration.title = hasSecondaryTitle ? renderedSecondaryTitle : renderedTitle
        configuration.subtitle = showsSecondaryTitle ? renderedTitle : nil
        configuration.image = renderedImageName.flatMap { UIImage(systemName: $0) }
        if renderedImageName != nil {
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
                pointSize: CGFloat(KeyboardTextKeyVisualPolicy.iconPointSize(
                    imageName: renderedImageName,
                    profile: visualProfile
                )),
                weight: .regular
            )
        }
        configuration.titleLineBreakMode = .byClipping
        configuration.cornerStyle = .fixed
        configuration.background.cornerRadius = CGFloat(KeyboardTextKeyVisualPolicy.cornerRadius)
        if showsSecondaryTitle, stackedLegendStyle == .pairedSymbol {
            configuration.titlePadding = 11
        }
        configuration.contentInsets = contentInsets(
            typography: typography,
            showsSecondaryTitle: showsSecondaryTitle
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
            if showsSelectedAlternate {
                outgoing.font = .systemFont(
                    ofSize: CGFloat(max(
                        22,
                        KeyboardTextKeyVisualPolicy.stackedPrimaryPointSize(
                            for: typography,
                            profile: visualProfile,
                            style: stackedLegendStyle
                        )
                    )),
                    weight: .regular
                )
                outgoing.foregroundColor = .label
                return outgoing
            }
            if showsSecondaryTitle {
                outgoing.font = .systemFont(
                    ofSize: CGFloat(KeyboardTextKeyVisualPolicy.stackedSecondaryPointSize(
                        profile: visualProfile,
                        style: stackedLegendStyle
                    )),
                    weight: .regular
                )
                outgoing.foregroundColor = stackedLegendStyle == .alternateHint
                    ? .secondaryLabel
                    : .label
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
                    ofSize: CGFloat(KeyboardTextKeyVisualPolicy.stackedPrimaryPointSize(
                        for: typography,
                        profile: visualProfile,
                        style: stackedLegendStyle
                    )),
                    weight: weight
                )
                outgoing.foregroundColor = .label
                return outgoing
            }
        }
        return configuration
    }

    private func contentInsets(
        typography: KeyboardTextKeyTypography,
        showsSecondaryTitle: Bool
    ) -> NSDirectionalEdgeInsets {
        let centeredHorizontalInset = CGFloat(KeyboardTextKeyVisualPolicy.horizontalContentInset)
        // SF Symbols carry their own optical side bearing. Native iPad keys
        // compensate for it so the visible ink, not the symbol's image box,
        // lands on the 14pt outer margin. Text legends have no such bearing.
        let nativeOuterInset: CGFloat = renderedImageName == nil ? 15 : 12
        switch renderedContentPlacement {
        case .centered:
            return NSDirectionalEdgeInsets(
                top: showsSecondaryTitle ? 1 : CGFloat(typography.topInset),
                leading: centeredHorizontalInset,
                bottom: showsSecondaryTitle ? 1 : CGFloat(typography.bottomInset),
                trailing: centeredHorizontalInset
            )
        case .leadingCenter:
            return NSDirectionalEdgeInsets(
                top: 0,
                leading: nativeOuterInset,
                bottom: 0,
                trailing: centeredHorizontalInset
            )
        case .trailingCenter:
            return NSDirectionalEdgeInsets(
                top: 0,
                leading: centeredHorizontalInset,
                bottom: 0,
                trailing: nativeOuterInset
            )
        case .leadingBottom:
            return NSDirectionalEdgeInsets(
                top: 0,
                leading: nativeOuterInset,
                bottom: renderedImageName == "arrow.right.to.line" ? 8 : 10,
                trailing: centeredHorizontalInset
            )
        case .trailingBottom:
            return NSDirectionalEdgeInsets(
                top: 0,
                leading: centeredHorizontalInset,
                bottom: 10,
                trailing: nativeOuterInset
            )
        }
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
