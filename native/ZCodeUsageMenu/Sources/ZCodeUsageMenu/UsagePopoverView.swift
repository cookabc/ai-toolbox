import AppKit
import SwiftUI

struct UsagePopoverView: View {
    @ObservedObject var model: UsageViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = model.errorMessage, model.snapshot != nil {
                staleBanner(error)
            }
            if let snapshot = model.snapshot {
                // The model list is bounded to four rows in UsageRepository. A content-driven
                // popover keeps every selected metric visible instead of hiding it in a scroll view.
                VStack(spacing: 6) {
                    todayCard(snapshot.today)
                    lifetimeCard(snapshot.totals)
                    if !snapshot.models.isEmpty { modelsCard(snapshot.models) }
                }
                .padding(10)
            } else {
                emptyState
                    .frame(maxWidth: .infinity, minHeight: 260)
                    .padding(24)
            }
        }
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)
            Text("ZCode 用量")
                .font(.system(.headline, design: .rounded))
            Text(headerStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            OverflowMenuButton(
                isRefreshing: model.isRefreshing,
                refresh: model.refresh,
                openDataDirectory: openDataDirectory,
                quit: { NSApplication.shared.terminate(nil) }
            )
            .frame(width: 28, height: 28)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var headerStatus: String {
        if model.isRefreshing { return "· 正在刷新…" }
        if let date = model.snapshot?.refreshedAt {
            return "· \(date.formatted(date: .omitted, time: .shortened)) 更新"
        }
        return "· 等待读取"
    }

    // MARK: - Today

    private func todayCard(_ totals: UsageTotals) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("今日输出")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        Text(Format.token(totals.outputTokens))
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                    }
                    Spacer(minLength: 8)
                    LazyVGrid(
                        columns: [GridItem(.fixed(82), alignment: .leading), GridItem(.fixed(82), alignment: .leading)],
                        alignment: .leading,
                        spacing: 5
                    ) {
                        compactMetric("输入", Format.token(totals.inputTokens))
                        compactMetric("回合", "\(totals.turns)")
                        compactMetric("请求", Format.token(totals.requests))
                        compactMetric("工具", Format.count(totals.toolCalls))
                    }
                }
                Divider().opacity(0.55)
                inputComposition(totals)
            }
        }
    }

    private func inputComposition(_ totals: UsageTotals) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("输入构成")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if totals.inputTokens > 0 {
                    Text("缓存 \(Format.percent(totals.cacheReadShare))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("暂无输入")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            CompositionBar(totals: totals)
                .frame(height: 6)
                .accessibilityLabel("输入构成：缓存读 \(Format.token(totals.cacheReadInputTokens))，缓存创建 \(Format.token(totals.cacheCreationInputTokens))，非缓存输入 \(Format.token(totals.freshInputTokens))")
            HStack(spacing: 8) {
                compositionLegend("缓存读", totals.cacheReadInputTokens, color: .cyan)
                compositionLegend("创建", totals.cacheCreationInputTokens, color: .indigo)
                compositionLegend("非缓存", totals.freshInputTokens, color: .gray)
            }
        }
    }

    private func compositionLegend(_ title: String, _ value: Int64, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("\(title) \(Format.token(value))")
                .lineLimit(1)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    // MARK: - Lifetime

    private func lifetimeCard(_ totals: UsageTotals) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 7) {
                sectionHeading("累计用量", icon: "clock.arrow.circlepath")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 5) {
                    statTile("输入", Format.token(totals.inputTokens), accent: .cyan)
                    statTile("输出", Format.token(totals.outputTokens), accent: .indigo)
                    statTile("推理", Format.token(totals.reasoningTokens), accent: .purple)
                    statTile("缓存读", Format.token(totals.cacheReadInputTokens), accent: .teal)
                }
                HStack(spacing: 5) {
                    activityMetric("回合", Format.count(totals.turns))
                    Text("·").foregroundStyle(.tertiary)
                    activityMetric("请求", Format.count(totals.requests))
                    Text("·").foregroundStyle(.tertiary)
                    activityMetric("工具", Format.count(totals.toolCalls))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let cost = model.optionalOutputCost {
                    HStack {
                        Text("输出成本估算")
                        Spacer()
                        Text(Format.cost(cost)).monospacedDigit()
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func statTile(_ title: String, _ value: String, accent: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(accent).frame(width: 6, height: 6)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func activityMetric(_ title: String, _ value: String) -> some View {
        Text("\(title) \(value)")
            .monospacedDigit()
    }

    // MARK: - Models

    private func modelsCard(_ models: [ModelUsage]) -> some View {
        SurfaceCard(compact: true) {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeading("模型（按输出排序）", icon: "cpu")
                let maximum = max(1, models.map(\.outputTokens).max() ?? 1)
                ForEach(models) { item in
                    ModelRow(item: item, maximumOutput: maximum)
                }
                Text("仅含完成步骤记录")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - States / helpers

    private func staleBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("显示上次成功数据：\(error)")
                .lineLimit(1)
            Spacer()
            Button("重试") { model.refresh() }
                .buttonStyle(.borderless)
                .disabled(model.isRefreshing)
        }
        .font(.caption)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.10))
    }

    private var emptyState: some View {
        VStack(spacing: 13) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.12)).frame(width: 56, height: 56)
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
            }
            Text("还没有可读的用量数据")
                .font(.headline)
            Text(model.errorMessage ?? "等待 ZCode 首次写入本机用量数据库。")
                .multilineTextAlignment(.center)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 280)
            HStack(spacing: 12) {
                Button("重新读取") { model.refresh() }
                Button("打开数据目录") { openDataDirectory() }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func sectionHeading(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .tracking(0.8)
    }

    private func compactMetric(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit().foregroundStyle(.primary)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openDataDirectory() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appending(path: ".zcode/cli"))
    }
}

private struct SurfaceCard<Content: View>: View {
    let compact: Bool
    @ViewBuilder let content: Content

    init(compact: Bool = false, @ViewBuilder content: () -> Content) {
        self.compact = compact
        self.content = content()
    }

    var body: some View {
        content
            .padding(compact ? 8 : 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }
}

private struct CompositionBar: View {
    let totals: UsageTotals

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let hasInput = totals.inputTokens > 0
            let readWidth = width * totals.cacheReadShare
            let creationWidth = width * totals.cacheCreationShare
            let freshWidth = width * totals.freshInputShare
            HStack(spacing: 2) {
                segment(.cyan, width: readWidth)
                segment(.indigo, width: creationWidth)
                segment(.gray.opacity(0.45), width: freshWidth)
            }
            .frame(width: width, alignment: .leading)
            .background(Color.primary.opacity(hasInput ? 0.05 : 0.10), in: Capsule())
            .clipShape(Capsule())
        }
    }

    private func segment(_ color: Color, width: CGFloat) -> some View {
        color
            .frame(width: max(0, width))
            .opacity(width > 0 ? 0.85 : 0)
    }
}

private struct ModelRow: View {
    let item: ModelUsage
    let maximumOutput: Int64

    private var share: Double {
        guard maximumOutput > 0 else { return 0 }
        return min(1, max(0, Double(item.outputTokens) / Double(maximumOutput)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(item.modelID)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(Format.token(item.outputTokens))
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
            HStack(spacing: 6) {
                Text(item.providerID)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text("\(Format.count(item.requests)) 请求")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(colors: [.indigo, .purple], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, proxy.size.width * share))
                }
            }
            .frame(height: 3)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.modelID)，已记录输出 \(Format.token(item.outputTokens))，\(Format.count(item.requests)) 请求")
    }
}
