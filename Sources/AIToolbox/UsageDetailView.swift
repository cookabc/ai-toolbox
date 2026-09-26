import AppKit
import SwiftUI

/// The usage half of the panel: today, the last seven days, the lifetime totals and
/// the models that produced them, for the selected tool.
struct UsageDetailView: View {
  @ObservedObject var model: UsageViewModel
  var openDataDirectory: () -> Void

  var body: some View {
    if let snapshot = model.snapshot {
      VStack(spacing: 8) {
        if let warning = model.sourceWarning(model.selectedProvider) {
          WarningBanner(
            text: warning, retry: model.errorMessage == nil ? nil : { model.refresh() },
            isRetrying: model.isRefreshing)
        }
        TodayCard(model: model, today: model.today())
        TrendCard(days: model.recentDays(7), today: model.currentDate)
        LifetimeCard(model: model, snapshot: snapshot)
        if !snapshot.models.isEmpty { ModelsCard(models: snapshot.models) }
        Text("本机日志中记录的用量，不是账单或订阅额度。")
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .frame(maxWidth: .infinity)
      }
      .padding(.horizontal, 14)
      .padding(.bottom, 14)
    } else {
      EmptyUsageState(model: model, openDataDirectory: openDataDirectory)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
    }
  }
}

// MARK: - Today

private struct TodayCard: View {
  @ObservedObject var model: UsageViewModel
  let today: UsageTotals?

  var body: some View {
    SurfaceCard(active: true) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          VStack(alignment: .leading, spacing: 2) {
            Text("今日输出")
              .font(.caption.weight(.bold))
              .foregroundStyle(ConsoleInk.accent)
            Text(today.map { Format.token($0.outputTokens) } ?? "—")
              .font(.system(size: 34, weight: .bold, design: .rounded))
              .tracking(-1)
              .monospacedDigit()
              .contentTransition(.numericText())
              .accessibilityLabel(
                "今日输出 \(today.map { Format.count($0.outputTokens) } ?? "暂无记录") token")
          }
          Spacer(minLength: 8)
          Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            GridRow {
              MetricPair(title: "输入", value: today.map { Format.token($0.inputTokens) })
              MetricPair(title: "请求", value: today.map { Format.count($0.requests) })
            }
            GridRow {
              MetricPair(title: "回合", value: today.map { Format.count($0.turns) })
              MetricPair(title: "工具", value: today.map { Format.count($0.toolCalls) })
            }
          }
        }
        if let today, model.reports(.cacheRead) {
          Divider().opacity(0.55)
          InputComposition(totals: today, showsWrite: model.reports(.cacheWrite))
        }
      }
    }
  }
}

private struct MetricPair: View {
  let title: String
  let value: String?

  var body: some View {
    HStack(spacing: 5) {
      Text(title).foregroundStyle(.secondary)
      Text(value ?? "—")
        .monospacedDigit()
        .fontWeight(.medium)
    }
    .font(.caption)
  }
}

/// How much of the prompt was served from cache. On agentic workloads this is
/// usually most of it, which is the single most useful thing to know about input.
private struct InputComposition: View {
  let totals: UsageTotals
  let showsWrite: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("输入构成")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Text(totals.inputTokens > 0 ? "缓存命中 \(Format.percent(totals.cacheReadShare))" : "今日暂无输入")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      // An empty bar and a row of zeros say nothing the heading does not.
      if totals.inputTokens > 0 {
        CompositionBar(totals: totals)
          .frame(height: 6)
        HStack(spacing: 10) {
          Legend(title: "缓存读", value: totals.cacheReadTokens, color: .cyan)
          if showsWrite { Legend(title: "缓存写", value: totals.cacheWriteTokens, color: .indigo) }
          Legend(title: "未缓存", value: totals.freshInputTokens, color: .gray)
          Spacer(minLength: 0)
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "输入构成：缓存读 \(Format.token(totals.cacheReadTokens))，缓存写 \(Format.token(totals.cacheWriteTokens))，未缓存 \(Format.token(totals.freshInputTokens))"
    )
  }
}

private struct Legend: View {
  let title: String
  let value: Int64
  let color: Color

  var body: some View {
    HStack(spacing: 4) {
      Circle().fill(color).frame(width: 5, height: 5)
      Text("\(title) \(Format.token(value))").lineLimit(1)
    }
    .font(.caption2.monospacedDigit())
    .foregroundStyle(.secondary)
  }
}

private struct CompositionBar: View {
  let totals: UsageTotals

  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      HStack(spacing: 0) {
        Color.cyan.frame(width: width * totals.cacheReadShare)
        Color.indigo.frame(width: width * totals.cacheWriteShare)
        Color.gray.opacity(0.45).frame(width: width * totals.freshInputShare)
      }
      .frame(width: width, alignment: .leading)
      .background(Color.primary.opacity(0.08))
      .clipShape(Capsule())
    }
  }
}

// MARK: - Last seven days

private struct TrendCard: View {
  let days: [DailyUsage]
  let today: Date

  private var peak: Int64 { max(1, days.map(\.totals.outputTokens).max() ?? 1) }
  private var total: Int64 { days.reduce(0) { saturating($0, $1.totals.outputTokens) } }

  var body: some View {
    SurfaceCard(compact: true) {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          SectionHeading(title: "近 7 天输出", icon: "chart.bar.xaxis")
          Spacer()
          Text("合计 \(Format.token(total))")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        HStack(alignment: .bottom, spacing: 6) {
          ForEach(days, id: \.date) { day in
            TrendBar(
              day: day, peak: peak, isToday: Calendar.current.isDate(day.date, inSameDayAs: today))
          }
        }
        .frame(height: 56)
      }
    }
  }
}

private struct TrendBar: View {
  let day: DailyUsage
  let peak: Int64
  let isToday: Bool

  private var fraction: CGFloat {
    CGFloat(Double(day.totals.outputTokens) / Double(peak))
  }

  var body: some View {
    VStack(spacing: 4) {
      GeometryReader { proxy in
        VStack {
          Spacer(minLength: 0)
          RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(isToday ? ConsoleInk.accent : ConsoleInk.accent.opacity(0.4))
            .frame(height: day.totals.outputTokens > 0 ? max(3, proxy.size.height * fraction) : 2)
            .opacity(day.totals.outputTokens > 0 ? 1 : 0.4)
        }
      }
      Text(label)
        .font(.system(size: 9, weight: isToday ? .semibold : .regular))
        .foregroundStyle(isToday ? Color.primary : Color.secondary)
    }
    .frame(maxWidth: .infinity)
    .help(
      "\(Format.monthDay(day.date)) · 输出 \(Format.token(day.totals.outputTokens)) · \(Format.count(day.totals.requests)) 请求"
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(Format.monthDay(day.date))，输出 \(Format.token(day.totals.outputTokens))")
  }

  private var label: String {
    isToday ? "今天" : Format.weekday(day.date)
  }
}

// MARK: - Lifetime

private struct LifetimeCard: View {
  @ObservedObject var model: UsageViewModel
  let snapshot: UsageSnapshot

  var body: some View {
    let totals = snapshot.totals
    SurfaceCard {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          SectionHeading(title: "累计用量", icon: "clock.arrow.circlepath")
          Spacer()
          if let first = snapshot.firstActiveDay {
            Text("自 \(Format.day(first))")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
          GridRow {
            StatTile(title: "输入", value: Format.token(totals.inputTokens), accent: .gray)
            StatTile(
              title: "输出", value: Format.token(totals.outputTokens), accent: ConsoleInk.accent)
          }
          GridRow {
            StatTile(
              title: "缓存读", value: model.display(totals.cacheReadTokens, .cacheRead), accent: .cyan)
            StatTile(
              title: "推理", value: model.display(totals.reasoningTokens, .reasoning), accent: .purple
            )
          }
        }
        Text(
          "\(Format.count(totals.requests)) 请求 · \(Format.count(totals.turns)) 回合 · \(Format.count(totals.toolCalls)) 次工具调用"
        )
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
      }
    }
  }
}

private struct StatTile: View {
  let title: String
  let value: String
  let accent: Color

  var body: some View {
    HStack(spacing: 6) {
      Circle().fill(accent).frame(width: 6, height: 6)
      Text(title).font(.caption).foregroundStyle(.secondary)
      Spacer(minLength: 4)
      Text(value)
        .font(.system(.subheadline, design: .rounded).weight(.semibold))
        .monospacedDigit()
    }
    .frame(maxWidth: .infinity)
  }
}

// MARK: - Models

private struct ModelsCard: View {
  let models: [ModelUsage]
  private static let limit = 4

  var body: some View {
    let shown = Array(models.prefix(Self.limit))
    let peak = max(1, shown.first?.outputTokens ?? 1)
    SurfaceCard(compact: true) {
      VStack(alignment: .leading, spacing: 7) {
        HStack {
          SectionHeading(title: "模型", icon: "cpu")
          Spacer()
          Text(models.count > Self.limit ? "按输出 · 前 \(Self.limit) / \(models.count)" : "按输出排序")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        ForEach(shown) { item in
          ModelRow(item: item, peak: peak)
        }
      }
    }
  }
}

private struct ModelRow: View {
  let item: ModelUsage
  let peak: Int64

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 8) {
        Text(item.modelID)
          .font(.caption.weight(.medium))
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 6)
        Text("\(Format.count(item.requests)) 请求")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.tertiary)
        Text(Format.token(item.outputTokens))
          .font(.caption.monospacedDigit().weight(.semibold))
          .frame(minWidth: 40, alignment: .trailing)
      }
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          Capsule().fill(Color.primary.opacity(0.08))
          Capsule()
            .fill(ConsoleInk.accent.opacity(0.85))
            .frame(
              width: max(3, proxy.size.width * CGFloat(Double(item.outputTokens) / Double(peak))))
        }
      }
      .frame(height: 3)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "\(item.modelID)，输出 \(Format.token(item.outputTokens))，\(Format.count(item.requests)) 请求")
  }
}

// MARK: - States

private struct WarningBanner: View {
  let text: String
  let retry: (() -> Void)?
  let isRetrying: Bool

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      Text(text)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 4)
      if let retry {
        Button("重试", action: retry)
          .buttonStyle(.borderless)
          .disabled(isRetrying)
      }
    }
    .font(.caption)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(
      Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}

private struct EmptyUsageState: View {
  @ObservedObject var model: UsageViewModel
  let openDataDirectory: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      ZStack {
        Circle().fill(ConsoleInk.accent.opacity(0.12)).frame(width: 56, height: 56)
        if model.isRefreshing {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: "tray")
            .font(.title2)
            .foregroundStyle(ConsoleInk.accent)
        }
      }
      Text(title).font(.headline)
      Text(message)
        .multilineTextAlignment(.center)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: 290)
        .fixedSize(horizontal: false, vertical: true)
      if !model.isRefreshing {
        HStack(spacing: 12) {
          Button("重新读取") { model.refresh() }
          Button("打开记录目录", action: openDataDirectory)
            .buttonStyle(.borderless)
        }
        .font(.caption)
      }
    }
  }

  private var title: String {
    if model.isRefreshing { return "正在读取本地记录" }
    return model.errorMessage == nil ? "还没有用量数据" : "暂时读不到 \(model.selectedProvider.title) 的记录"
  }

  private var message: String {
    if model.isRefreshing { return "第一次读取需要扫描全部历史记录，之后只读新增部分。" }
    return model.errorMessage ?? "等 \(model.selectedProvider.title) 写入用量记录后，这里会自动更新。"
  }
}

struct SectionHeading: View {
  let title: String
  let icon: String

  var body: some View {
    Label(title, systemImage: icon)
      .font(.caption.weight(.bold))
      .foregroundStyle(.secondary)
  }
}
