import AppKit
import SwiftUI

struct LiveConfigView: View {
  @ObservedObject var model: LiveConfigViewModel
  @State private var pendingDelete: StoredProvider?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let problem = model.readProblem {
        Notice(text: problem, style: .error)
      }
      if let error = model.errorMessage {
        Notice(text: error, style: .error)
      } else if let status = model.statusMessage {
        Notice(text: status, style: .success)
      }
      if let note = codexFileNote {
        Notice(text: note, style: .info)
      }
      if model.liveConfigIsUnmanaged {
        importBanner
      }
      providerList
      if model.draftMode != .none { draftForm }
    }
    .padding(.horizontal, 14)
    .padding(.bottom, 12)
    .onAppear { model.loadOnce() }
    .onChange(of: model.app) { _ in
      if model.draftMode != .none { model.cancelDraft() }
    }
    .confirmationDialog(
      "删除供应商「\(pendingDelete?.name ?? "")」？",
      isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
      titleVisibility: .visible
    ) {
      Button("删除", role: .destructive) {
        if let provider = pendingDelete { model.delete(provider) }
        pendingDelete = nil
      }
      Button("取消", role: .cancel) { pendingDelete = nil }
    } message: {
      Text(
        pendingDelete?.app == .codex
          ? "会从供应商库和 ~/.codex/config.toml 一并移除；如果它正在使用，Codex 会切回官方 OpenAI。"
          : "只从供应商库移除，Claude Code 当前生效的配置保持不变。")
    }
  }

  private var codexFileNote: String? {
    guard model.app == .codex else { return nil }
    switch model.codexState {
    case .noCodexHome: return "没有找到 ~/.codex，Codex 可能还没在这台 Mac 上运行过。可以先保存供应商，运行一次 Codex 后再切换。"
    case .absent: return "还没有 ~/.codex/config.toml。切换到自定义供应商时会自动创建。"
    case .ready, .unreadable: return nil
    }
  }

  private var importBanner: some View {
    HStack(spacing: 8) {
      Image(systemName: "tray.and.arrow.down")
        .foregroundStyle(ConsoleInk.accent)
      Text(model.app == .codex ? "config.toml 中有未保存到供应商库的供应商。" : "当前生效的配置还没有保存为供应商。")
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 4)
      Button("导入") { model.importLiveConfig() }
        .buttonStyle(.borderless)
        .disabled(model.isBusy)
    }
    .font(.caption)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(
      ConsoleInk.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private var providerList: some View {
    VStack(alignment: .leading, spacing: 8) {
      if model.app == .codex {
        officialCodexCard
      }
      ForEach(model.visibleProviders) { provider in
        providerCard(provider)
      }
      if model.visibleProviders.isEmpty && !model.liveConfigIsUnmanaged {
        Text(model.app == .codex ? "还没有保存自定义供应商。" : "还没有保存的供应商。")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(.vertical, 6)
      }
      if model.draftMode == .none {
        addProviderButton
      }
    }
  }

  private var addProviderButton: some View {
    Button {
      model.beginCreate()
    } label: {
      Label("新增供应商", systemImage: "plus")
        .font(.caption.weight(.medium))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
  }

  private var officialCodexCard: some View {
    let isActive = model.codexUsesOfficialLogin
    return SurfaceCard(compact: true, active: isActive) {
      HStack(alignment: .center, spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text("官方 OpenAI").font(.subheadline.weight(.semibold))
          Text("ChatGPT 账号或 auth.json 登录")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        ProviderSwitchSlot(isActive: isActive) {
          model.useCodexOfficial()
        }
        .disabled(model.isBusy || model.codexState != .ready)
      }
    }
  }

  private func providerCard(_ provider: StoredProvider) -> some View {
    let isActive = model.activeProviderID == provider.id
    return SurfaceCard(compact: true, active: isActive) {
      HStack(alignment: .top, spacing: 8) {
        VStack(alignment: .leading, spacing: 5) {
          Text(provider.name)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
          Text(provider.baseURL)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(provider.baseURL)
          HStack(spacing: 8) {
            Text(provider.model.isEmpty ? "未指定模型" : provider.model)
              .lineLimit(1)
            Text(provider.maskedAPIKey)
            if provider.app == .claude, provider.credential == .authToken, !provider.apiKey.isEmpty
            {
              Text("Bearer")
            }
          }
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.tertiary)
          probeResult(for: provider)
        }
        Spacer(minLength: 4)
        VStack(spacing: 4) {
          ProviderSwitchSlot(isActive: isActive) {
            model.activate(provider)
          }
          .disabled(model.isBusy)
          HStack(spacing: 4) {
            probeButton(for: provider)
            cardIconButton(systemName: "pencil", help: "编辑") {
              model.beginEdit(provider)
            }
            cardIconButton(systemName: "trash", help: "删除", destructive: true) {
              pendingDelete = provider
            }
          }
          .frame(width: 80, alignment: .center)
        }
      }
    }
  }

  private func cardIconButton(
    systemName: String,
    help: String,
    destructive: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.caption2.weight(.medium))
        .foregroundStyle(destructive ? Color.red : Color.secondary)
        .frame(width: 24, height: 20)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(model.isBusy)
    .help(help)
    .accessibilityLabel(help)
  }

  @ViewBuilder
  private func probeButton(for provider: StoredProvider) -> some View {
    if model.isProbing(provider) {
      ProgressView()
        .controlSize(.mini)
        .frame(width: 24, height: 20)
    } else {
      cardIconButton(systemName: "bolt.circle", help: "测试端点") {
        model.test(provider)
      }
    }
  }

  @ViewBuilder
  private func probeResult(for provider: StoredProvider) -> some View {
    if let result = model.probeResult(for: provider) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          Image(systemName: result.symbolName)
          Text(result.summary)
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(probeColor(result.verdict))
        if !result.isHealthy {
          // The actionable half: the real status and the server's own words,
          // in place of the CLI's misleading "selected model" complaint.
          Text(result.detail)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .help(result.detail)
    }
  }

  private func probeColor(_ verdict: EndpointProbeResult.Verdict) -> Color {
    switch verdict {
    case .healthy: .green
    case .needsAuth, .rejected: .orange
    case .badRoute, .unsupported, .unreachable: .red
    }
  }

  // MARK: - Draft

  private var draftForm: some View {
    SurfaceCard {
      VStack(alignment: .leading, spacing: 8) {
        Text(model.draftMode == .create ? "新增供应商" : "编辑供应商")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        labeledField("名称", text: $model.draftName, placeholder: "例如 公司网关")
        if model.app == .codex {
          if let editing = model.editingProvider {
            HStack(spacing: 4) {
              Text("ID").foregroundStyle(.secondary)
              Text(editing.slug).font(.system(.caption, design: .monospaced))
              Text("· config.toml 中的段名，保存后不可修改").foregroundStyle(.tertiary)
            }
            .font(.caption)
          } else {
            labeledField(
              "ID（config.toml 中的段名，可留空自动生成）", text: $model.draftSlug,
              placeholder: "例如 company-gateway", monospaced: true)
          }
        }
        labeledField(
          "Base URL", text: $model.draftBaseURL, placeholder: "https://…/v1", monospaced: true)
        labeledField("模型", text: $model.draftModel, placeholder: "留空则不修改模型", monospaced: true)
        keyField
        if model.app == .claude {
          credentialPicker
          perProviderEnvSection
        }
        HStack {
          Button {
            model.saveDraft(activate: false)
          } label: {
            Label("保存", systemImage: "square.and.arrow.down")
          }
          Button {
            model.saveDraft(activate: true)
          } label: {
            Label("保存并切换", systemImage: "arrow.triangle.2.circlepath")
          }
          .keyboardShortcut(.defaultAction)
          Spacer()
          Button("取消") { model.cancelDraft() }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
        }
        .font(.caption)
        .controlSize(.small)
        .disabled(model.isBusy)
      }
    }
  }

  private var keyField: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("API Key").font(.caption).foregroundStyle(.secondary)
      HStack {
        Group {
          let placeholder = model.draftMode == .create ? "sk-…" : "留空则保留现有 Key"
          if model.revealDraftKey {
            TextField(placeholder, text: $model.draftAPIKey)
          } else {
            SecureField(placeholder, text: $model.draftAPIKey)
          }
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(.caption, design: .monospaced))
        Button {
          model.revealDraftKey.toggle()
        } label: {
          Image(systemName: model.revealDraftKey ? "eye.slash" : "eye")
        }
        .buttonStyle(.borderless)
        .help(model.revealDraftKey ? "隐藏 Key" : "显示已输入内容")
        .accessibilityLabel(model.revealDraftKey ? "隐藏 Key" : "显示已输入内容")
      }
    }
  }

  private var credentialPicker: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("认证方式").font(.caption).foregroundStyle(.secondary)
      Picker("认证方式", selection: $model.draftCredential) {
        ForEach(ClaudeCredential.allCases, id: \.self) { credential in
          Text(credential.label).tag(credential)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .controlSize(.small)
      Text(
        model.draftCredential == .apiKey
          ? "写入 ANTHROPIC_API_KEY，以 x-api-key 头发送；官方 API 用这种方式。"
          : "写入 ANTHROPIC_AUTH_TOKEN，以 Bearer 头发送；多数中转站用这种方式。"
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// Per-provider `settings.json` keys. Collapsed by default: most providers only
  /// need the base URL, model and key above.
  private var perProviderEnvSection: some View {
    DisclosureGroup {
      VStack(alignment: .leading, spacing: 8) {
        Text("留空表示这个供应商不接管该 Key，切换时会交还给声明它的供应商。列表以外的 env 项始终原样保留。")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        ForEach(ClaudeLiveSettingsStore.perProviderKeys, id: \.self) { key in
          labeledField(key, text: extraEnvBinding(key), placeholder: "未接管", monospaced: true)
        }
        HStack(spacing: 8) {
          Button {
            model.fillFamilyModelsWithProviderModel()
          } label: {
            Label("模型别名 = 上方模型", systemImage: "wand.and.stars")
          }
          .help("把上面填写的模型写入全部 Claude Code 模型别名。只服务单一模型的中转站通常需要这样设置。")
          .disabled(model.draftModel.trimmingCharacters(in: .whitespaces).isEmpty)
          Button("全部清空") { model.clearDraftExtraEnv() }
          Spacer()
        }
        .font(.caption2)
        .buttonStyle(.borderless)
      }
      .padding(.top, 6)
    } label: {
      Text("高级配置（Claude Code 环境变量）")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }
    .font(.caption)
  }

  private func extraEnvBinding(_ key: String) -> Binding<String> {
    Binding(
      get: { model.draftExtraEnv[key] ?? "" },
      set: { model.draftExtraEnv[key] = $0 }
    )
  }

  private func labeledField(
    _ title: String,
    text: Binding<String>,
    placeholder: String,
    monospaced: Bool = false
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      TextField(placeholder, text: text)
        .textFieldStyle(.roundedBorder)
        .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
    }
  }
}

/// A one-line message in the config panel: the outcome of the last action, or a
/// problem with one of the files it depends on.
private struct Notice: View {
  enum Style { case error, success, info }

  let text: String
  let style: Style

  var body: some View {
    Label {
      Text(text).fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: symbol).foregroundStyle(color)
    }
    .font(.caption)
    .foregroundStyle(style == .error ? Color.primary : Color.secondary)
    .frame(maxWidth: .infinity, alignment: .leading)
    .textSelection(.enabled)
  }

  private var symbol: String {
    switch style {
    case .error: "exclamationmark.triangle.fill"
    case .success: "checkmark.circle.fill"
    case .info: "info.circle"
    }
  }

  private var color: Color {
    switch style {
    case .error: .orange
    case .success: .green
    case .info: .secondary
    }
  }
}

private struct ProviderSwitchSlot: View {
  let isActive: Bool
  let action: () -> Void
  @Environment(\.isEnabled) private var isEnabled

  private let slotWidth: CGFloat = 76
  private let slotHeight: CGFloat = 30

  var body: some View {
    Group {
      if isActive {
        Label("使用中", systemImage: "checkmark.circle.fill")
          .font(.caption.weight(.semibold))
          .labelStyle(.titleAndIcon)
          .foregroundStyle(ConsoleInk.onAccent)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        Button(action: action) {
          Text("切换")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("切换到这个供应商")
      }
    }
    .frame(width: slotWidth, height: slotHeight)
    .background {
      if isActive {
        Capsule().fill(ConsoleInk.accent)
      } else {
        CapsuleRing().fill(Color.primary.opacity(0.18), style: FillStyle(eoFill: true))
      }
    }
    .contentShape(Capsule())
    .opacity(isEnabled || isActive ? 1 : 0.55)
    .accessibilityLabel(isActive ? "正在使用" : "切换到这个供应商")
  }
}

/// A one-point capsule outline drawn as a filled ring. A stroked capsule picks up
/// stray vertical marks at its ends when the panel is rendered off screen, which is
/// how the README screenshots are made.
private struct CapsuleRing: Shape {
  var width: CGFloat = 1

  func path(in rect: CGRect) -> Path {
    var path = Capsule().path(in: rect)
    path.addPath(Capsule().path(in: rect.insetBy(dx: width, dy: width)))
    return path
  }
}
