import AppKit
import SwiftUI

struct LiveConfigView: View {
    @ObservedObject var model: LiveConfigViewModel
    @State private var showsAdvanced: Bool

    init(model: LiveConfigViewModel, initialShowsAdvanced: Bool = false) {
        self.model = model
        _showsAdvanced = State(initialValue: initialShowsAdvanced)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Pixel.Space.m) {
            if let problem = model.readProblem {
                PixelNotice(text: problem, tone: .error)
            }
            if let error = model.errorMessage {
                PixelNotice(text: error, tone: .error)
            } else if let status = model.statusMessage {
                PixelNotice(text: status, tone: .success)
            }
            if let note = codexFileNote {
                PixelNotice(text: note, tone: .info)
            }
            if model.liveConfigIsUnmanaged {
                PixelNotice(
                    text: model.app == .codex ? L10n.Config.unmanagedCodex : L10n.Config.unmanagedClaude,
                    tone: .info,
                    actionTitle: L10n.Config.importAction,
                    actionDisabled: model.isBusy,
                    action: { model.importLiveConfig() }
                )
            }
            providerList
            if model.draftMode != .none { draftForm }
        }
        .padding(.horizontal, Pixel.Space.xl)
        .padding(.top, Pixel.Space.l)
        .padding(.bottom, Pixel.Space.xl)
        .onAppear { model.loadOnce() }
        .onChange(of: model.app) { _ in
            if model.draftMode != .none { model.cancelDraft() }
        }
    }

    private var codexFileNote: String? {
        guard model.app == .codex else { return nil }
        switch model.codexState {
        case .noCodexHome: return L10n.Config.noCodexHome
        case .absent: return L10n.Config.noCodexConfig
        case .ready, .unreadable: return nil
        }
    }

    // MARK: - Providers

    private var providerList: some View {
        VStack(alignment: .leading, spacing: Pixel.Space.m) {
            officialCard
            ForEach(model.visibleProviders) { provider in
                providerCard(provider)
            }
            if model.visibleProviders.isEmpty && !model.liveConfigIsUnmanaged {
                Text(model.app == .codex ? L10n.Config.noCustomProviders : L10n.Config.noProviders)
                    .font(.uiCaption)
                    .foregroundStyle(Ink.textMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, Pixel.Space.xs)
            }
            if model.draftMode == .none {
                Button {
                    model.beginCreate()
                } label: {
                    Text(L10n.Config.addProvider)
                }
                .buttonStyle(PixelDashedButtonStyle(icon: .plus))
                .pixelFocusEffect()
                .panelID(PanelID.configAddProvider)
            }
        }
    }

    /// The tool's own login, as the first entry of the list. For Codex it switches
    /// back to the built-in OpenAI provider; for Claude Code it clears the keys
    /// providers write, which asks first because unsaved keys would be lost.
    @ViewBuilder private var officialCard: some View {
        switch model.app {
        case .codex:
            OfficialLoginCard(
                title: L10n.Config.officialOpenAI,
                detail: L10n.Config.officialOpenAIDetail,
                isActive: model.codexUsesOfficialLogin,
                isDisabled: model.isBusy || model.codexState != .ready,
                action: { model.useCodexOfficial() })
        case .claude:
            OfficialLoginCard(
                title: L10n.Config.officialAnthropic,
                detail: L10n.Config.officialAnthropicDetail,
                isActive: model.claudeUsesOfficialLogin,
                isDisabled: model.isBusy || model.claudeReadError != nil,
                action: { model.requestClearClaudeOverlay() })
        }
    }

    private func providerCard(_ provider: StoredProvider) -> some View {
        let isActive = model.activeProviderID == provider.id
        return PixelCard(tone: isActive ? .active : .plain) {
            VStack(alignment: .leading, spacing: Pixel.Space.s) {
                HStack(alignment: .center, spacing: Pixel.Space.m) {
                    VStack(alignment: .leading, spacing: Pixel.Space.xxs) {
                        Text(provider.name)
                            .font(.pixel())
                            .foregroundStyle(Ink.text)
                            .lineLimit(1)
                        Text(provider.baseURL)
                            .font(.uiMono)
                            .foregroundStyle(Ink.textMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(provider.baseURL)
                    }
                    Spacer(minLength: Pixel.Space.xs)
                    ProviderSwitch(isActive: isActive, help: L10n.Config.switchHelp) {
                        model.activate(provider)
                    }
                    .disabled(model.isBusy)
                }
                HStack(spacing: Pixel.Space.s) {
                    if provider.model.isEmpty {
                        PixelChip(text: L10n.Config.noModel, monospaced: false)
                    } else {
                        PixelChip(text: provider.model)
                    }
                    PixelChip(text: provider.maskedAPIKey)
                    if provider.app == .claude, provider.credential == .authToken, !provider.apiKey.isEmpty {
                        PixelChip(text: L10n.Config.credentialAuthToken, monospaced: false)
                    }
                    Spacer(minLength: Pixel.Space.xs)
                    probeButton(for: provider)
                    cardIconButton(.pencil, help: L10n.Config.edit) {
                        model.beginEdit(provider)
                    }
                    cardIconButton(.trash, help: L10n.Config.delete, destructive: true) {
                        model.requestDelete(provider)
                    }
                }
                probeResult(for: provider)
            }
        }
    }

    private func cardIconButton(
        _ icon: PixelIcon,
        help: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            PixelIconView(icon)
        }
        .buttonStyle(PixelIconButtonStyle(context: .surface, destructive: destructive, size: 26))
        .pixelFocusEffect()
        .disabled(model.isBusy)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private func probeButton(for provider: StoredProvider) -> some View {
        if model.isProbing(provider) {
            PixelSpinner()
                .foregroundStyle(Ink.textMuted)
                .frame(width: 26, height: 26)
                .help(L10n.Probe.running)
                .accessibilityLabel(L10n.Probe.running)
        } else {
            cardIconButton(.bolt, help: L10n.Config.test) {
                model.test(provider)
            }
        }
    }

    @ViewBuilder
    private func probeResult(for provider: StoredProvider) -> some View {
        if model.isProbing(provider) {
            HStack(spacing: Pixel.Space.s) {
                PixelLamp(color: Ink.textFaint)
                Text(L10n.Probe.running).foregroundStyle(Ink.textMuted)
            }
            .font(.pixel())
        } else if let result = model.probeResult(for: provider) {
            VStack(alignment: .leading, spacing: Pixel.Space.xxs) {
                HStack(spacing: Pixel.Space.s) {
                    PixelLamp(color: probeColor(result.severity))
                    Text(result.verdictLabel).foregroundStyle(probeColor(result.severity))
                    Text(result.summary).foregroundStyle(Ink.textMuted)
                }
                .font(.pixel())
                if !result.isHealthy {
                    // The actionable half: the real status and the server's own words,
                    // in place of the CLI's misleading "selected model" complaint.
                    Text(result.detail)
                        .font(.uiCaption)
                        .foregroundStyle(Ink.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .help(result.detail)
            .accessibilityElement(children: .combine)
        }
    }

    private func probeColor(_ severity: EndpointProbeResult.Severity) -> Color {
        switch severity {
        case .ok: Ink.success
        case .caution: Ink.warning
        case .failure: Ink.danger
        }
    }

    // MARK: - Draft

    private var draftForm: some View {
        PixelCard {
            VStack(alignment: .leading, spacing: Pixel.Space.l) {
                PixelSectionHeader(
                    icon: model.draftMode == .create ? .plus : .pencil,
                    title: model.draftMode == .create ? L10n.Config.createTitle : L10n.Config.editTitle)
                PixelTextField(
                    title: L10n.Config.name, text: $model.draftName, placeholder: L10n.Config.namePlaceholder)
                if model.app == .codex {
                    if let editing = model.editingProvider {
                        VStack(alignment: .leading, spacing: Pixel.Space.xs) {
                            HStack(alignment: .firstTextBaseline, spacing: Pixel.Space.s) {
                                Text(L10n.Config.providerID).font(.pixel()).foregroundStyle(Ink.textMuted)
                                Text(L10n.Config.providerIDLockedNote).font(.uiCaption).foregroundStyle(
                                    Ink.textFaint)
                            }
                            PixelChip(text: editing.slug)
                        }
                    } else {
                        PixelTextField(
                            title: L10n.Config.providerID, note: L10n.Config.providerIDNote,
                            text: $model.draftSlug, placeholder: L10n.Config.providerIDPlaceholder,
                            monospaced: true)
                    }
                }
                PixelTextField(
                    title: L10n.Config.baseURL, text: $model.draftBaseURL,
                    placeholder: L10n.Config.baseURLPlaceholder, monospaced: true)
                PixelTextField(
                    title: L10n.Config.model, text: $model.draftModel,
                    placeholder: L10n.Config.modelPlaceholder, monospaced: true)
                keyField
                if model.app == .claude {
                    credentialPicker
                    advancedSection
                }
                HStack(spacing: Pixel.Space.m) {
                    Button(L10n.Config.save) {
                        model.saveDraft(activate: false)
                    }
                    .buttonStyle(PixelButtonStyle(kind: .secondary, icon: .save))
                    .pixelFocusEffect()
                    .panelID(PanelID.configSave)
                    Button(L10n.Config.saveAndSwitch) {
                        model.saveDraft(activate: true)
                    }
                    .buttonStyle(PixelButtonStyle(kind: .primary, icon: .swap))
                    .pixelFocusEffect()
                    .keyboardShortcut(.defaultAction)
                    .panelID(PanelID.configSaveAndSwitch)
                    Spacer(minLength: 0)
                    Button(L10n.Config.cancel) { model.cancelDraft() }
                        .buttonStyle(PixelButtonStyle(kind: .quiet))
                        .panelID(PanelID.configCancelDraft)
                        .pixelFocusEffect()
                        .keyboardShortcut(.cancelAction)
                }
                .disabled(model.isBusy)
            }
        }
    }

    private var keyField: some View {
        PixelTextField(
            title: L10n.Config.apiKey,
            text: $model.draftAPIKey,
            placeholder: model.draftMode == .create
                ? L10n.Config.apiKeyPlaceholder : L10n.Config.keepKeyPlaceholder,
            monospaced: true,
            secure: !model.revealDraftKey
        ) {
            Button {
                model.revealDraftKey.toggle()
            } label: {
                PixelIconView(model.revealDraftKey ? .eyeOff : .eye)
            }
            .buttonStyle(PixelIconButtonStyle(context: .surface, size: 22))
            .pixelFocusEffect()
            .help(model.revealDraftKey ? L10n.Config.hideKey : L10n.Config.revealKey)
            .accessibilityLabel(model.revealDraftKey ? L10n.Config.hideKey : L10n.Config.revealKey)
        }
    }

    private var credentialPicker: some View {
        VStack(alignment: .leading, spacing: Pixel.Space.xs) {
            Text(L10n.Config.credential).font(.pixel()).foregroundStyle(Ink.textMuted)
            PixelTabWell(context: .surface) {
                ForEach(ClaudeCredential.allCases, id: \.self) { credential in
                    let isSelected = model.draftCredential == credential
                    Button(credential.label) { model.draftCredential = credential }
                        .buttonStyle(PixelTabStyle(isSelected: isSelected, context: .surface))
                        .pixelFocusEffect()
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .frame(height: 30)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.Config.credential)
            Text(model.draftCredential.help)
                .font(.uiCaption)
                .foregroundStyle(Ink.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Per-provider `settings.json` keys. Collapsed by default: most providers only
    /// need the base URL, model and key above.
    private var advancedSection: some View {
        PixelDisclosure(L10n.Config.advanced, isExpanded: $showsAdvanced) {
            VStack(alignment: .leading, spacing: Pixel.Space.m) {
                Text(L10n.Config.advancedHelp)
                    .font(.uiCaption)
                    .foregroundStyle(Ink.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(ClaudeLiveSettingsStore.perProviderKeys, id: \.self) { key in
                    PixelTextField(
                        title: key, text: extraEnvBinding(key), placeholder: L10n.Config.notOwned,
                        monospaced: true)
                }
                HStack(spacing: Pixel.Space.m) {
                    Button(L10n.Config.fillAliases) {
                        model.fillFamilyModelsWithProviderModel()
                    }
                    .buttonStyle(PixelButtonStyle(kind: .quiet, icon: .wand))
                    .pixelFocusEffect()
                    .help(L10n.Config.fillAliasesHelp)
                    .disabled(model.draftModel.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button(L10n.Config.clearAll) { model.clearDraftExtraEnv() }
                        .buttonStyle(PixelButtonStyle(kind: .quiet))
                        .pixelFocusEffect()
                    Spacer(minLength: 0)
                }
            }
        }
        .panelID(PanelID.configAdvanced)
    }

    private func extraEnvBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { model.draftExtraEnv[key] ?? "" },
            set: { model.draftExtraEnv[key] = $0 }
        )
    }
}

/// The tool's own login as a list entry.
private struct OfficialLoginCard: View {
    let title: String
    let detail: String
    let isActive: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        PixelCard(tone: isActive ? .active : .plain) {
            HStack(alignment: .center, spacing: Pixel.Space.m) {
                VStack(alignment: .leading, spacing: Pixel.Space.xxs) {
                    Text(title).font(.pixel()).foregroundStyle(Ink.text)
                    Text(detail).font(.uiCaption).foregroundStyle(Ink.textMuted)
                }
                Spacer(minLength: Pixel.Space.m)
                ProviderSwitch(isActive: isActive, help: L10n.Config.switchToOfficialHelp, action: action)
                    .disabled(isDisabled)
            }
        }
    }
}

/// Which entry is live, as a row of keys: the live one is pressed in — sunk two
/// points, lit, no shadow — and every other one is a raised "Switch" key. Exactly one
/// is pressed at a time, like a radio button made of keycaps.
private struct ProviderSwitch: View {
    let isActive: Bool
    let help: String
    let action: () -> Void

    private let width: CGFloat = 76

    var body: some View {
        Group {
            if isActive {
                HStack(spacing: Pixel.Space.xs) {
                    PixelIconView(.check)
                    Text(L10n.Config.active).font(.pixel())
                }
                .foregroundStyle(Ink.onAccent)
                .frame(width: width, height: Pixel.controlHeight)
                .pixelSurface(fill: Ink.accent, border: Ink.control)
                .offset(y: Pixel.shadow)
                .padding(.bottom, Pixel.shadow)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.Config.activeAccessibility)
            } else {
                Button(L10n.Config.switchAction, action: action)
                    .buttonStyle(PixelButtonStyle(kind: .secondary, fillsWidth: true))
                    .pixelFocusEffect()
                    .frame(width: width)
                    .help(help)
                    .accessibilityLabel(help)
            }
        }
    }
}

/// A dashed, full-width button for adding something to a list.
struct PixelDashedButtonStyle: ButtonStyle {
    var icon: PixelIcon?

    func makeBody(configuration: Configuration) -> some View {
        PixelDashedButtonFace(configuration: configuration, icon: icon)
    }
}

private struct PixelDashedButtonFace: View {
    let configuration: ButtonStyleConfiguration
    let icon: PixelIcon?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Pixel.Space.s) {
            if let icon { PixelIconView(icon) }
            configuration.label.font(.pixel())
        }
        .foregroundStyle(isEnabled ? (isHovered ? Ink.text : Ink.accent) : Ink.textFaint)
        .frame(maxWidth: .infinity, minHeight: 30)
        .background {
            if isHovered || configuration.isPressed { PixelRect().fill(Ink.surface) }
        }
        .overlay {
            PixelDashedBorder().fill(isHovered ? Ink.accent : Ink.control).allowsHitTesting(false)
        }
        .overlay { PixelFocusRing(isVisible: isFocused && isEnabled) }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}
