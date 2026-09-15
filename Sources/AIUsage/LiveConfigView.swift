import AppKit
import SwiftUI

struct LiveConfigView: View {
    @ObservedObject var model: LiveConfigViewModel
    @State private var pendingDelete: StoredProvider?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.app == .codex && !model.hasCodexFile {
                Label("未找到 ~/.codex/config.toml", systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if model.liveConfigIsUnmanaged {
                    HStack {
                        Spacer()
                        Button { model.importLiveConfig() } label: {
                            Label("导入当前配置", systemImage: "square.and.arrow.down")
                                .font(.caption)
                        }
                        .help("把当前生效的配置保存为供应商")
                    }
                }
                providerList
            }

            if model.draftMode != .none { draftForm }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .onAppear { model.loadOnce() }
        .onChange(of: model.app) { _ in
            if model.draftMode != .none { model.cancelDraft() }
        }
        .confirmationDialog(
            "删除供应商？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let provider = pendingDelete { model.delete(provider) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete?.app == .codex
                 ? "会从供应商库和 ~/.codex/config.toml 一并移除；若它是当前项，Codex 会切回官方 OpenAI。"
                 : "只从供应商库移除。Claude Code 当前生效的配置保持不变。")
        }
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
                Text("还没有保存的供应商。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
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
                    Text("使用 auth.json / 官方登录")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                ProviderSwitchSlot(isActive: isActive) {
                    model.useCodexOfficial()
                }
                .disabled(model.isBusy)
            }
        }
    }

    private func providerCard(_ provider: StoredProvider) -> some View {
        let isActive = model.activeProviderID == provider.id
        return SurfaceCard(compact: true, active: isActive) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(provider.name).font(.subheadline.weight(.semibold))
                    if !provider.baseURL.isEmpty {
                        Text(provider.baseURL)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    HStack(spacing: 8) {
                        Text(provider.model.isEmpty ? "模型 —" : provider.model)
                        Text(provider.maskedAPIKey)
                    }
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                VStack(spacing: 4) {
                    ProviderSwitchSlot(isActive: isActive) {
                        model.activate(provider)
                    }
                    .disabled(model.isBusy)
                    HStack(spacing: 8) {
                        cardIconButton(systemName: "pencil", help: "编辑") {
                            model.beginEdit(provider)
                        }
                        cardIconButton(systemName: "trash", help: "删除", destructive: true) {
                            pendingDelete = provider
                        }
                    }
                    .frame(width: 76, alignment: .center)
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

    private var draftForm: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.draftMode == .create ? "新增供应商" : "编辑供应商")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                labeledField("名称", text: $model.draftName)
                if model.app == .codex {
                    labeledField("ID（config.toml 中的段名，留空自动生成）", text: $model.draftSlug)
                }
                labeledField("Base URL", text: $model.draftBaseURL)
                labeledField("模型", text: $model.draftModel)
                VStack(alignment: .leading, spacing: 4) {
                    Text("API Key").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Group {
                            if model.revealDraftKey {
                                TextField("留空则保留现有 Key", text: $model.draftAPIKey)
                            } else {
                                SecureField("留空则保留现有 Key", text: $model.draftAPIKey)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        Button {
                            model.revealDraftKey.toggle()
                        } label: {
                            Image(systemName: model.revealDraftKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(model.revealDraftKey ? "隐藏 Key" : "显示已输入内容")
                    }
                }
                HStack {
                    Button { model.saveDraft(activate: false) } label: {
                        Label("保存", systemImage: "square.and.arrow.down")
                    }
                    Button { model.saveDraft(activate: true) } label: {
                        Label("保存并切换", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button { model.cancelDraft() } label: {
                        Label("取消", systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("取消")
                    Spacer()
                }
                .font(.caption)
                .disabled(model.isBusy)
            }
        }
    }

    private func labeledField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
        }
    }
}

private struct ProviderSwitchSlot: View {
    let isActive: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    private let slotWidth: CGFloat = 76
    private let slotHeight: CGFloat = 34

    var body: some View {
        Group {
            if isActive {
                Label("当前", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Button(action: action) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("切换")
            }
        }
        .frame(width: slotWidth, height: slotHeight)
        .background {
            if isActive {
                Capsule().fill(Color.accentColor)
            } else {
                Capsule().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
            }
        }
        .contentShape(Capsule())
        .opacity(isEnabled ? 1 : 0.55)
        .accessibilityLabel(isActive ? "当前生效" : "切换")
    }
}
