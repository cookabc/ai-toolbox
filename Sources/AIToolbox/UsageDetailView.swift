import AppKit
import SwiftUI

/// The usage half of the panel: today, the last seven days, the lifetime totals and
/// the models that produced them, for the selected tool.
///
/// Today and the week are always shown — they are what the panel is opened for.
/// The lifetime totals and the model list are details; each folds away, and the
/// choice is remembered.
struct UsageDetailView: View {
  @ObservedObject var model: UsageViewModel
  var openDataDirectory: () -> Void

  @AppStorage(Self.lifetimeExpandedKey) private var lifetimeExpanded = true
  @AppStorage(Self.modelsExpandedKey) private var modelsExpanded = true

  nonisolated static let lifetimeExpandedKey = "usage.lifetimeExpanded"
  nonisolated static let modelsExpandedKey = "usage.modelsExpanded"

  var body: some View {
    if let snapshot = model.snapshot {
      VStack(spacing: Pixel.Space.m) {
        if let warning = model.sourceWarning(model.selectedProvider) {
          PixelNotice(
            text: warning,
            tone: .warning,
            actionTitle: model.errorMessage == nil ? nil : L10n.Usage.retry,
            actionDisabled: model.isRefreshing,
            action: model.errorMessage == nil ? nil : { model.refresh() }
          )
        }
        TodayCard(model: model, today: model.today())
          .panelID(PanelID.todayCard)
        TrendCard(days: model.recentDays(7), today: model.currentDate)
          .panelID(PanelID.trendCard)
        LifetimeCard(model: model, snapshot: snapshot, isExpanded: $lifetimeExpanded)
          .panelID(PanelID.lifetimeCard)
        if !snapshot.models.isEmpty {
          ModelsCard(models: snapshot.models, isExpanded: $modelsExpanded)
            .panelID(PanelID.modelsCard)
        }
        Text(L10n.Usage.footnote)
          .font(.system(size: 10))
          .foregroundStyle(Ink.textMuted)
          .frame(maxWidth: .infinity)
      }
      .padding(.horizontal, Pixel.Space.xl)
      .padding(.top, Pixel.Space.m)
      .padding(.bottom, Pixel.Space.l)
    } else {
      EmptyUsageState(model: model, openDataDirectory: openDataDirectory)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 24)
    }
  }
}

// MARK: - Today

private struct TodayCard: View {
  @ObservedObject var model: UsageViewModel
  let today: UsageTotals?

  var body: some View {
    PixelCard(tone: .active) {
      VStack(alignment: .leading, spacing: Pixel.Space.s) {
        HStack(alignment: .top, spacing: Pixel.Space.xl) {
          VStack(alignment: .leading, spacing: Pixel.Space.xs) {
            Text(L10n.Usage.todayOutput)
              .font(.pixel())
              .foregroundStyle(Ink.accent)
            HeroNumber(text: today.map { Format.token($0.outputTokens) } ?? L10n.Usage.unknown)
              .help(today.map { L10n.Usage.exactTokens(Format.exact($0.outputTokens)) } ?? "")
              .accessibilityLabel(
                L10n.Usage.todayOutputAccessibility(today.map { Format.exact($0.outputTokens) }))
          }
          Spacer(minLength: Pixel.Space.m)
          Grid(alignment: .leading, horizontalSpacing: Pixel.Space.xl, verticalSpacing: Pixel.Space.s) {
            GridRow {
              MetricPair(title: L10n.Usage.input, value: today?.inputTokens, compact: Format.token)
              MetricPair(title: L10n.Usage.requests, value: today?.requests, compact: Format.count)
            }
            GridRow {
              MetricPair(title: L10n.Usage.turns, value: today?.turns, compact: Format.count)
              MetricPair(title: L10n.Usage.toolCalls, value: today?.toolCalls, compact: Format.count)
            }
          }
          .padding(.top, Pixel.Space.xxs)
        }
        if let today, model.reports(.cacheRead) {
          PixelDivider()
          InputComposition(totals: today, showsWrite: model.reports(.cacheWrite))
        }
      }
    }
  }
}

/// The day's headline figure in the pixel font at three times its design size.
///
/// The font's line box is taller than anything it draws — 13 + 3 pixels around a
/// 12-pixel glyph cell — so the box is trimmed by the empty pixel rows, keeping the
/// number tight under its label without clipping a single drawn pixel.
private struct HeroNumber: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.pixel(3))
      .foregroundStyle(Ink.text)
      .lineLimit(1)
      .fixedSize()
      .padding(.top, -3 * 2)
      .padding(.bottom, -3 * 2)
  }
}

private struct MetricPair: View {
  let title: String
  let value: Int64?
  let compact: (Int64) -> String

  var body: some View {
    HStack(spacing: Pixel.Space.s) {
      Text(title).foregroundStyle(Ink.textMuted)
      Text(value.map(compact) ?? L10n.Usage.unknown)
        .foregroundStyle(Ink.text)
    }
    .font(.pixel())
    .lineLimit(1)
    .help(value.map { Format.exact($0) } ?? "")
    .accessibilityElement(children: .combine)
  }
}

/// How much of the prompt was served from cache. On agentic workloads this is
/// usually most of it, which is the single most useful thing to know about input.
private struct InputComposition: View {
  let totals: UsageTotals
  let showsWrite: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: Pixel.Space.s) {
      HStack {
        Text(L10n.Usage.composition).foregroundStyle(Ink.textMuted)
        Spacer()
        Text(
          totals.inputTokens > 0
            ? L10n.Usage.cacheHitRate(Format.percent(totals.cacheReadShare))
            : L10n.Usage.noInputToday
        )
        .foregroundStyle(Ink.textMuted)
      }
      .font(.pixel())
      // An empty bar and a row of zeros say nothing the heading does not.
      if totals.inputTokens > 0 {
        CompositionBar(totals: totals)
          .frame(height: 10)
        HStack(spacing: Pixel.Space.l) {
          Legend(title: L10n.Usage.cacheRead, value: totals.cacheReadTokens, color: Ink.cacheRead)
          if showsWrite {
            Legend(title: L10n.Usage.cacheWrite, value: totals.cacheWriteTokens, color: Ink.cacheWrite)
          }
          Legend(title: L10n.Usage.uncached, value: totals.freshInputTokens, color: Ink.uncached)
          Spacer(minLength: 0)
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      L10n.Usage.compositionAccessibility(
        read: Format.token(totals.cacheReadTokens),
        write: showsWrite ? Format.token(totals.cacheWriteTokens) : nil,
        fresh: Format.token(totals.freshInputTokens)))
  }
}

/// A legend entry: a square swatch — the pixel equivalent of a dot — and the value.
private struct Legend: View {
  let title: String
  let value: Int64
  let color: Color
  var dithered = false

  var body: some View {
    HStack(spacing: Pixel.Space.xs) {
      Swatch(color: color, dithered: dithered)
      Text("\(title) \(Format.token(value))").lineLimit(1)
    }
    .font(.pixel())
    .foregroundStyle(Ink.textMuted)
    .help(L10n.Usage.exactTokens(Format.exact(value)))
  }
}

private struct Swatch: View {
  let color: Color
  var dithered = false

  var body: some View {
    ZStack {
      if dithered {
        DitherPattern(cell: 1).fill(color)
      } else {
        Rectangle().fill(color)
      }
    }
    .frame(width: 8, height: 8)
    .accessibilityHidden(true)
  }
}

/// Cache read, cache write and uncached input side by side, in whole points.
/// `PixelMath.segments` keeps the three widths summing to the bar exactly and
/// keeps any non-zero part at least one point wide.
private struct CompositionBar: View {
  let totals: UsageTotals

  var body: some View {
    GeometryReader { proxy in
      let inner = max(0, Int(proxy.size.width.rounded(.down)) - 2)
      let widths = PixelMath.segments(
        [
          Double(totals.cacheReadTokens),
          Double(min(totals.cacheWriteTokens, max(0, totals.inputTokens - totals.cacheReadTokens))),
          Double(totals.freshInputTokens),
        ],
        total: inner)
      ZStack(alignment: .leading) {
        Rectangle().fill(Ink.sunken)
        HStack(spacing: 0) {
          Rectangle().fill(Ink.cacheRead).frame(width: CGFloat(widths[0]))
          Rectangle().fill(Ink.cacheWrite).frame(width: CGFloat(widths[1]))
          Rectangle().fill(Ink.uncached).frame(width: CGFloat(widths[2]))
        }
        .padding(1)
        PixelBorder(width: 1, steps: 0).fill(Ink.control, style: FillStyle(eoFill: true))
      }
      .frame(width: CGFloat(inner + 2))
    }
    .accessibilityHidden(true)
  }
}

// MARK: - Last seven days

private struct TrendCard: View {
  let days: [DailyUsage]
  let today: Date

  private var peak: Int64 { max(1, days.map(\.totals.outputTokens).max() ?? 1) }
  private var total: Int64 { days.reduce(0) { saturating($0, $1.totals.outputTokens) } }

  var body: some View {
    PixelCard {
      VStack(alignment: .leading, spacing: Pixel.Space.m) {
        PixelSectionHeader(icon: .calendar, title: L10n.Usage.trend) {
          Text(L10n.Usage.trendTotal(Format.token(total)))
            .font(.pixel())
            .foregroundStyle(Ink.textMuted)
            .help(L10n.Usage.exactTokens(Format.exact(total)))
        }
        HStack(alignment: .bottom, spacing: Pixel.Space.s) {
          ForEach(days, id: \.date) { day in
            TrendColumn(
              day: day, peak: peak, isToday: Calendar.current.isDate(day.date, inSameDayAs: today))
          }
        }
        .overlay(alignment: .bottom) {
          // The zero line, under the bars and above the day labels.
          PixelDivider(color: Ink.lineSoft).padding(.bottom, TrendColumn.labelHeight + 2)
        }
      }
    }
  }
}

/// One day: its value above the bar, so the week reads without hovering, and its
/// name below. Bar heights are whole points in proportion to the week's peak; a
/// day with any output gets at least one point, a day with none gets no bar and
/// says 0.
private struct TrendColumn: View {
  let day: DailyUsage
  let peak: Int64
  let isToday: Bool

  static let barHeight = 34
  static let labelHeight: CGFloat = 16

  var body: some View {
    let output = day.totals.outputTokens
    let height = PixelMath.barLength(Double(output), peak: Double(peak), length: Self.barHeight)
    VStack(spacing: Pixel.Space.xxs) {
      Text(Format.token(output))
        .font(.pixel())
        .foregroundStyle(isToday ? Ink.accent : Ink.textMuted)
        .lineLimit(1)
        .fixedSize()
      ZStack(alignment: .bottom) {
        Color.clear
        if height > 0 {
          Rectangle()
            .fill(isToday ? Ink.accent : Ink.accentFill)
            .overlay(alignment: .top) {
              // A one-point highlight on top: the light catching a pixel block.
              if height > 2 { Rectangle().fill(Ink.surface.opacity(0.35)).frame(height: 1) }
            }
            .frame(height: CGFloat(height))
        }
      }
      .frame(height: CGFloat(Self.barHeight))
      .padding(.bottom, Pixel.Space.xxs + 1)
      Text(isToday ? L10n.Usage.today : Format.weekday(day.date))
        .font(.pixel())
        .foregroundStyle(isToday ? Ink.text : Ink.textMuted)
        .frame(height: Self.labelHeight)
    }
    .frame(maxWidth: .infinity)
    .contentShape(Rectangle())
    .help(
      L10n.Usage.dayDetail(
        date: Format.monthDay(day.date), output: Format.exact(output),
        requests: Format.count(day.totals.requests)))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      L10n.Usage.dayAccessibility(date: Format.monthDay(day.date), output: Format.token(output)))
  }
}

// MARK: - Lifetime

private struct LifetimeCard: View {
  @ObservedObject var model: UsageViewModel
  let snapshot: UsageSnapshot
  @Binding var isExpanded: Bool

  var body: some View {
    let totals = snapshot.totals
    PixelCard {
      VStack(alignment: .leading, spacing: Pixel.Space.m) {
        CollapsibleHeader(icon: .clock, title: L10n.Usage.lifetime, isExpanded: $isExpanded) {
          if let first = snapshot.firstActiveDay {
            Text(L10n.Usage.since(Format.day(first)))
              .font(.pixel())
              .foregroundStyle(Ink.textMuted)
          }
        }
        if isExpanded {
          Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: Pixel.Space.s) {
            GridRow {
              StatTile(
                title: L10n.Usage.input, value: Format.token(totals.inputTokens),
                exact: Format.exact(totals.inputTokens), color: Ink.inputSeries)
              StatTile(
                title: L10n.Usage.output, value: Format.token(totals.outputTokens),
                exact: Format.exact(totals.outputTokens), color: Ink.accentFill)
            }
            GridRow {
              StatTile(
                title: L10n.Usage.cacheRead, value: model.display(totals.cacheReadTokens, .cacheRead),
                exact: model.reports(.cacheRead) ? Format.exact(totals.cacheReadTokens) : nil,
                color: Ink.cacheRead)
              // Reasoning is part of output, so it wears output's colour, half-toned.
              StatTile(
                title: L10n.Usage.reasoning, value: model.display(totals.reasoningTokens, .reasoning),
                exact: model.reports(.reasoning) ? Format.exact(totals.reasoningTokens) : nil,
                color: Ink.accentFill, dithered: true)
            }
          }
          Text(
            L10n.Usage.activity(
              requests: Format.count(totals.requests), turns: Format.count(totals.turns),
              toolCalls: Format.count(totals.toolCalls))
          )
          .font(.pixel())
          .foregroundStyle(Ink.textMuted)
          .lineLimit(1)
        }
      }
    }
  }
}

private struct StatTile: View {
  let title: String
  let value: String
  let exact: String?
  let color: Color
  var dithered = false

  var body: some View {
    HStack(spacing: Pixel.Space.s) {
      Swatch(color: color, dithered: dithered)
      Text(title).foregroundStyle(Ink.textMuted)
      Spacer(minLength: Pixel.Space.xs)
      Text(value).foregroundStyle(Ink.text)
    }
    .font(.pixel())
    .lineLimit(1)
    .frame(maxWidth: .infinity)
    .help(exact.map { L10n.Usage.exactTokens($0) } ?? "")
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Models

private struct ModelsCard: View {
  let models: [ModelUsage]
  @Binding var isExpanded: Bool
  private static let limit = 4

  var body: some View {
    let shown = Array(models.prefix(Self.limit))
    let peak = max(1, shown.first?.outputTokens ?? 1)
    PixelCard {
      VStack(alignment: .leading, spacing: Pixel.Space.m) {
        CollapsibleHeader(icon: .chip, title: L10n.Usage.models, isExpanded: $isExpanded) {
          Text(
            models.count > Self.limit
              ? L10n.Usage.topModels(Self.limit, of: models.count) : L10n.Usage.byOutput
          )
          .font(.pixel())
          .foregroundStyle(Ink.textMuted)
        }
        if isExpanded {
          VStack(alignment: .leading, spacing: Pixel.Space.xs) {
            ForEach(shown) { item in
              ModelRow(item: item, peak: peak)
            }
          }
        }
      }
    }
  }
}

private struct ModelRow: View {
  let item: ModelUsage
  let peak: Int64

  var body: some View {
    VStack(alignment: .leading, spacing: Pixel.Space.xxs) {
      HStack(spacing: Pixel.Space.m) {
        Text(item.modelID)
          .font(.uiMono)
          .foregroundStyle(Ink.text)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(item.modelID)
        Spacer(minLength: Pixel.Space.s)
        Text(L10n.Usage.modelRequests(Format.count(item.requests)))
          .font(.pixel())
          .foregroundStyle(Ink.textMuted)
          .lineLimit(1)
        Text(Format.token(item.outputTokens))
          .font(.pixel())
          .foregroundStyle(Ink.text)
          .lineLimit(1)
          .frame(minWidth: 44, alignment: .trailing)
          .help(L10n.Usage.exactTokens(Format.exact(item.outputTokens)))
      }
      GeometryReader { proxy in
        let length = Int(proxy.size.width.rounded(.down))
        let filled = PixelMath.barLength(
          Double(item.outputTokens), peak: Double(peak), length: length)
        ZStack(alignment: .leading) {
          DitherPattern(cell: 1).fill(Ink.lineSoft)
          Rectangle().fill(Ink.accentFill).frame(width: CGFloat(filled))
        }
      }
      .frame(height: 3)
      .accessibilityHidden(true)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      L10n.Usage.modelAccessibility(
        id: item.modelID, output: Format.token(item.outputTokens),
        requests: Format.count(item.requests)))
  }
}

/// A card title that folds the card: the whole row is the button.
private struct CollapsibleHeader<Trailing: View>: View {
  let icon: PixelIcon
  let title: String
  @Binding var isExpanded: Bool
  @ViewBuilder let trailing: Trailing

  var body: some View {
    Button {
      isExpanded.toggle()
    } label: {
      HStack(spacing: Pixel.Space.s) {
        PixelIconView(icon).foregroundStyle(Ink.textMuted)
        Text(title).font(.pixel()).foregroundStyle(Ink.text)
        Spacer(minLength: Pixel.Space.s)
        trailing
        PixelIconView(isExpanded ? .chevronDown : .chevronRight)
          .foregroundStyle(Ink.textMuted)
      }
      .frame(minHeight: 16)
    }
    .buttonStyle(PixelPlainButtonStyle())
    .pixelFocusEffect()
    .help(L10n.Usage.toggleSection(title, expanded: isExpanded))
    .accessibilityLabel(title)
    .accessibilityValue(isExpanded ? L10n.Common.expanded : L10n.Common.collapsed)
    .accessibilityHint(L10n.Usage.toggleSection(title, expanded: isExpanded))
  }
}

// MARK: - States

private struct EmptyUsageState: View {
  @ObservedObject var model: UsageViewModel
  let openDataDirectory: () -> Void

  var body: some View {
    VStack(spacing: Pixel.Space.l) {
      TerminalIllustration(mode: illustration)
      Text(title)
        .font(.pixel())
        .foregroundStyle(Ink.text)
        .multilineTextAlignment(.center)
        .accessibilityAddTraits(.isHeader)
      Text(message)
        .multilineTextAlignment(.center)
        .font(.uiCaption)
        .foregroundStyle(Ink.textMuted)
        .frame(maxWidth: 300)
        .fixedSize(horizontal: false, vertical: true)
      if !model.isRefreshing {
        HStack(spacing: Pixel.Space.m) {
          Button(L10n.Usage.reload) { model.refresh() }
            .buttonStyle(PixelButtonStyle(kind: .secondary, icon: .refresh))
            .pixelFocusEffect()
          Button(L10n.Usage.openRecords, action: openDataDirectory)
            .buttonStyle(PixelButtonStyle(kind: .quiet, icon: .folder))
            .pixelFocusEffect()
        }
        .padding(.top, Pixel.Space.xxs)
      }
    }
  }

  private var illustration: TerminalIllustration.Mode {
    if model.isRefreshing { return .loading }
    return model.errorMessage == nil ? .empty : .error
  }

  private var title: String {
    if model.isRefreshing { return L10n.Usage.loadingTitle }
    return model.errorMessage == nil
      ? L10n.Usage.emptyTitle : L10n.Usage.unreadableTitle(model.selectedProvider.title)
  }

  private var message: String {
    if model.isRefreshing { return L10n.Usage.loadingMessage }
    return model.errorMessage ?? L10n.Usage.emptyMessage(model.selectedProvider.title)
  }
}
