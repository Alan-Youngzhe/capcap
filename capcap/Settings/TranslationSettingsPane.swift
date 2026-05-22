import AppKit

/// Content of the Settings "翻译" tab: one editable config card per AI
/// translation provider. The target language follows the app language.
final class TranslationSettingsPane: NSView {
    private var providerCards: [TranslationProviderCard] = []
    private var providersHeaderLabel: NSTextField!
    private var providersStack: NSStackView!

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI()
        NotificationCenter.default.addObserver(
            self, selector: #selector(onLanguageChanged),
            name: .languageDidChange, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func buildUI() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // Providers header.
        providersHeaderLabel = makeLabel(L10n.translationProvidersHeader, size: 12, weight: .semibold, alpha: 0.62)
        stack.addArrangedSubview(providersHeaderLabel)

        // Provider cards.
        providersStack = NSStackView()
        providersStack.orientation = .vertical
        providersStack.alignment = .leading
        providersStack.spacing = 12
        providersStack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(providersStack)
        providersStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        for kind in TranslationConfigStore.orderedKinds() {
            let card = TranslationProviderCard(kind: kind)
            card.translatesAutoresizingMaskIntoConstraints = false
            card.onMoveUp = { [weak self] kind in self?.moveProvider(kind, offset: -1) }
            card.onMoveDown = { [weak self] kind in self?.moveProvider(kind, offset: 1) }
            providerCards.append(card)
            providersStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: providersStack.widthAnchor).isActive = true
        }
        refreshMoveButtons()

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -22),
        ])
    }

    @objc private func onLanguageChanged() {
        providersHeaderLabel.stringValue = L10n.translationProvidersHeader
        for card in providerCards { card.refreshLocalization() }
    }

    private func moveProvider(_ kind: TranslationProviderKind, offset: Int) {
        guard
            let from = providerCards.firstIndex(where: { $0.kind == kind })
        else { return }

        let to = from + offset
        guard providerCards.indices.contains(to) else { return }

        let card = providerCards.remove(at: from)
        providerCards.insert(card, at: to)
        refreshProviderStack()
        refreshMoveButtons()
        TranslationConfigStore.setProviderOrder(providerCards.map(\.kind))
    }

    private func refreshProviderStack() {
        for view in providersStack.arrangedSubviews {
            providersStack.removeArrangedSubview(view)
        }
        for card in providerCards {
            providersStack.addArrangedSubview(card)
        }
    }

    private func refreshMoveButtons() {
        for (index, card) in providerCards.enumerated() {
            card.setMoveAvailability(
                canMoveUp: index > 0,
                canMoveDown: index < providerCards.count - 1
            )
        }
    }
}

// MARK: - Pasteable text field

/// Text field that honors Cmd+C/V/X/A in a menu-less LSUIElement app.
private final class TKTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        let action: Selector
        switch event.charactersIgnoringModifiers {
        case "x": action = #selector(NSText.cut(_:))
        case "c": action = #selector(NSText.copy(_:))
        case "v": action = #selector(NSText.paste(_:))
        case "a": action = #selector(NSText.selectAll(_:))
        default: return super.performKeyEquivalent(with: event)
        }
        return NSApp.sendAction(action, to: nil, from: nil)
    }
}

// MARK: - Provider card

private final class TranslationProviderCard: NSView {
    let kind: TranslationProviderKind
    var onMoveUp: ((TranslationProviderKind) -> Void)?
    var onMoveDown: ((TranslationProviderKind) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let enableSwitch = NSSwitch()
    private let moveUpButton = NSButton()
    private let moveDownButton = NSButton()
    private let apiKeyField = RevealableSecureField()
    private let modelField = TKTextField()
    private let endpointField = TKTextField()
    private let apiKeyLabel = NSTextField(labelWithString: "")
    private let modelLabel = NSTextField(labelWithString: "")
    private let endpointLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "", target: nil, action: nil)
    private let clearButton = NSButton(title: "", target: nil, action: nil)
    private let bodyContainer = ClippingView()
    private var bodyHeightConstraint: NSLayoutConstraint!
    private var measuredBodyHeight: CGFloat = 0
    private var isExpanded: Bool

    init(kind: TranslationProviderKind) {
        self.kind = kind
        self.isExpanded = TranslationConfigStore.isEnabled(kind)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor
        layer?.borderWidth = 1
        buildUI()
        loadFromStore()
        enableSwitch.state = isExpanded ? .on : .off
        bodyContainer.alphaValue = isExpanded ? 1 : 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildUI() {
        let outer = NSStackView()
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 10
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        pin(outer, to: self, inset: 14)

        // Header.
        titleLabel.stringValue = kind.displayName
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.94)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        enableSwitch.controlSize = .small
        enableSwitch.target = self
        enableSwitch.action = #selector(switchToggled)
        enableSwitch.translatesAutoresizingMaskIntoConstraints = false

        configureIconButton(moveUpButton, symbolName: "chevron.up", label: L10n.translationMoveUp)
        moveUpButton.target = self
        moveUpButton.action = #selector(moveUpTapped)

        configureIconButton(moveDownButton, symbolName: "chevron.down", label: L10n.translationMoveDown)
        moveDownButton.target = self
        moveDownButton.action = #selector(moveDownTapped)

        let header = NSStackView(views: [titleLabel, flexSpacer(), moveUpButton, moveDownButton, enableSwitch])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false
        outer.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true

        // Body.
        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 10
        body.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.wantsLayer = true
        bodyContainer.layer?.masksToBounds = true
        bodyContainer.addSubview(body)

        bodyHeightConstraint = bodyContainer.heightAnchor.constraint(equalToConstant: 0)
        bodyHeightConstraint.priority = .required
        bodyHeightConstraint.isActive = true

        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            body.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            {
                let c = body.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor)
                c.priority = .defaultHigh
                return c
            }(),
        ])

        body.addArrangedSubview(makeFieldRow(apiKeyLabel, apiKeyField,
                                             label: L10n.translationApiKey,
                                             placeholder: "sk-…", width: body))
        if !kind.isDeepL {
            body.addArrangedSubview(makeFieldRow(modelLabel, modelField,
                                                 label: L10n.translationModel,
                                                 placeholder: modelPlaceholder(), width: body))
        }
        body.addArrangedSubview(makeFieldRow(endpointLabel, endpointField,
                                             label: endpointLabelText(),
                                             placeholder: endpointPlaceholder(), width: body))

        saveButton.title = L10n.translationSave
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .small
        saveButton.target = self
        saveButton.action = #selector(saveTapped)

        clearButton.title = L10n.translationClear
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small
        clearButton.target = self
        clearButton.action = #selector(clearTapped)

        let footer = NSStackView(views: [flexSpacer(), clearButton, saveButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false
        body.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true

        outer.addArrangedSubview(bodyContainer)
        bodyContainer.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
    }

    override func layout() {
        super.layout()
        if measuredBodyHeight == 0, bounds.width > 0 {
            bodyHeightConstraint.isActive = false
            bodyContainer.layoutSubtreeIfNeeded()
            measuredBodyHeight = bodyContainer.fittingSize.height
            bodyHeightConstraint.isActive = true
            bodyHeightConstraint.constant = isExpanded ? measuredBodyHeight : 0
        }
    }

    private func makeFieldRow(_ label: NSTextField, _ field: any ProviderFieldInput,
                              label labelText: String, placeholder: String,
                              width: NSView) -> NSView {
        label.stringValue = labelText
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = NSColor.white.withAlphaComponent(0.74)
        label.alignment = .right
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true

        field.placeholderString = placeholder
        field.font = NSFont.systemFont(ofSize: 12)
        field.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        return row
    }

    // MARK: Field metadata

    private func modelPlaceholder() -> String {
        return kind.defaultModel.isEmpty ? "e.g. gpt-4o-mini" : kind.defaultModel
    }

    private func endpointLabelText() -> String {
        kind.endpointRequired ? L10n.translationEndpoint : L10n.translationEndpointOptional
    }

    private func endpointPlaceholder() -> String {
        if kind.isDeepL {
            return "Auto: api-free.deepl.com for :fx keys"
        }
        return kind.defaultEndpoint.isEmpty
            ? "https://api.example.com/v1/chat/completions"
            : kind.defaultEndpoint
    }

    // MARK: Persistence

    private func loadFromStore() {
        let cfg = TranslationConfigStore.load(kind)
        apiKeyField.stringValue = cfg.apiKey
        modelField.stringValue = cfg.model
        endpointField.stringValue = cfg.endpoint
    }

    private func currentConfig() -> TranslationConfig {
        TranslationConfig(
            apiKey: apiKeyField.stringValue,
            model: kind.isDeepL ? "" : modelField.stringValue,
            endpoint: endpointField.stringValue
        )
    }

    @objc private func switchToggled() {
        let on = enableSwitch.state == .on
        if on { TranslationConfigStore.save(currentConfig(), for: kind) }
        TranslationConfigStore.setEnabled(on, for: kind)
    }

    @objc private func toggleExpanded() {
        setExpanded(!isExpanded, animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        toggleExpanded()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        if let result, isPassThrough(result) { return self }
        return result
    }

    private func isPassThrough(_ view: NSView) -> Bool {
        if view === self { return false }
        var v: NSView? = view
        while let cur = v, cur !== self {
            if cur is NSSwitch { return false }
            if let btn = cur as? NSButton, btn.isEnabled { return false }
            if let tf = cur as? NSTextField, tf.isEditable { return false }
            if cur is NSTextView { return false }
            if cur is NSScrollView { return false }
            v = cur.superview
        }
        return true
    }

    private func setExpanded(_ expanded: Bool, animated: Bool) {
        isExpanded = expanded
        if measuredBodyHeight == 0 {
            bodyHeightConstraint.isActive = false
            bodyContainer.layoutSubtreeIfNeeded()
            measuredBodyHeight = bodyContainer.fittingSize.height
            bodyHeightConstraint.isActive = true
        }

        let target: CGFloat = expanded ? measuredBodyHeight : 0
        let alpha: CGFloat = expanded ? 1 : 0
        let updates = {
            self.bodyHeightConstraint.constant = target
            self.bodyContainer.alphaValue = alpha
            self.window?.contentView?.layoutSubtreeIfNeeded()
        }

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                updates()
            }
        } else {
            updates()
        }
    }

    @objc private func moveUpTapped() {
        onMoveUp?(kind)
    }

    @objc private func moveDownTapped() {
        onMoveDown?(kind)
    }

    @objc private func saveTapped() {
        let config = currentConfig()
        TranslationConfigStore.save(config, for: kind)

        // Nothing to test against without an API key — just confirm the save.
        guard !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            flashButton(saveButton, to: L10n.translationConfigSaved, restore: L10n.translationSave)
            return
        }

        saveButton.isEnabled = false
        clearButton.isEnabled = false
        saveButton.title = L10n.translationTesting

        let testedKind = kind
        Task { [weak self] in
            let error = await TranslationService.verify(kind: testedKind, config: config)
            await MainActor.run {
                guard let self else { return }
                self.saveButton.isEnabled = true
                self.clearButton.isEnabled = true
                if let error {
                    flashButton(self.saveButton, to: L10n.translationTestFailed,
                                restore: L10n.translationSave)
                    self.showTestFailure(error)
                } else {
                    flashButton(self.saveButton, to: L10n.translationTestPassed,
                                restore: L10n.translationSave)
                }
            }
        }
    }

    /// Reports a failed connection test. The config was already saved.
    private func showTestFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.translationTestFailedTitle
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        if let window = window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    @objc private func clearTapped() {
        apiKeyField.stringValue = ""
        modelField.stringValue = ""
        endpointField.stringValue = ""
        TranslationConfigStore.clear(kind)
    }

    func refreshLocalization() {
        titleLabel.stringValue = kind.displayName
        apiKeyLabel.stringValue = L10n.translationApiKey
        modelLabel.stringValue = L10n.translationModel
        endpointLabel.stringValue = endpointLabelText()
        saveButton.title = L10n.translationSave
        clearButton.title = L10n.translationClear
        moveUpButton.toolTip = L10n.translationMoveUp
        moveUpButton.setAccessibilityLabel(L10n.translationMoveUp)
        moveDownButton.toolTip = L10n.translationMoveDown
        moveDownButton.setAccessibilityLabel(L10n.translationMoveDown)
    }

    func setMoveAvailability(canMoveUp: Bool, canMoveDown: Bool) {
        moveUpButton.isEnabled = canMoveUp
        moveUpButton.alphaValue = canMoveUp ? 1.0 : 0.35
        moveDownButton.isEnabled = canMoveDown
        moveDownButton.alphaValue = canMoveDown ? 1.0 : 0.35
    }
}

private final class ClippingView: NSView {
    override var wantsDefaultClipping: Bool { true }
}
