import AppKit
import SwiftUI

// MARK: - Surfaces

/// Fill, pixel border and (optionally) a hard drop shadow, all on the stepped
/// outline. The shadow is drawn outside the layout bounds, so adding one never
/// moves anything.
struct PixelSurface: ViewModifier {
  var fill: Color
  var border: Color
  var borderWidth: CGFloat = Pixel.border
  var steps: Int = 1
  var shadow: Color?
  var shadowOffset: CGFloat = Pixel.shadow

  func body(content: Content) -> some View {
    content
      .background { PixelRect(step: borderWidth, steps: steps).fill(fill) }
      .overlay {
        PixelBorder(width: borderWidth, steps: steps)
          .fill(border, style: FillStyle(eoFill: true))
          .allowsHitTesting(false)
      }
      .background {
        if let shadow {
          PixelRect(step: borderWidth, steps: steps).fill(shadow).offset(y: shadowOffset)
        }
      }
  }
}

extension View {
  func pixelSurface(
    fill: Color, border: Color, borderWidth: CGFloat = Pixel.border, steps: Int = 1,
    shadow: Color? = nil, shadowOffset: CGFloat = Pixel.shadow
  ) -> some View {
    modifier(
      PixelSurface(
        fill: fill, border: border, borderWidth: borderWidth, steps: steps, shadow: shadow,
        shadowOffset: shadowOffset))
  }

  /// The system's own focus ring is a smooth blue capsule; the pixel controls draw
  /// their own square one instead.
  @ViewBuilder func pixelFocusEffect() -> some View {
    if #available(macOS 14.0, *) {
      focusEffectDisabled()
    } else {
      self
    }
  }
}

/// A content card: the panel's unit of grouping.
struct PixelCard<Content: View>: View {
  enum Tone { case plain, active }

  var tone: Tone = .plain
  @ViewBuilder let content: Content

  init(tone: Tone = .plain, @ViewBuilder content: () -> Content) {
    self.tone = tone
    self.content = content()
  }

  var body: some View {
    content
      .padding(.horizontal, Pixel.Space.l)
      .padding(.vertical, Pixel.Space.m)
      .frame(maxWidth: .infinity, alignment: .leading)
      .pixelSurface(
        fill: tone == .active ? Ink.accentSoft : Ink.surface,
        border: tone == .active ? Ink.accent : Ink.line,
        shadow: Ink.shadow)
  }
}

/// The square focus ring, two points outside the control.
struct PixelFocusRing: View {
  var isVisible: Bool

  var body: some View {
    PixelBorder(width: Pixel.border, steps: 1)
      .fill(Ink.accent, style: FillStyle(eoFill: true))
      .padding(-(Pixel.border + 1))
      .opacity(isVisible ? 1 : 0)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

// MARK: - Buttons

/// The panel's text button: a raised pixel key that sinks two points when pressed.
///
/// The shadow's space is reserved below the face whether or not it is drawn, so a
/// press, a hover or a disabled state never shifts the layout around the button.
struct PixelButtonStyle: ButtonStyle {
  enum Kind { case primary, secondary, danger, quiet }

  var kind: Kind = .secondary
  var fillsWidth = false
  var icon: PixelIcon?

  func makeBody(configuration: Configuration) -> some View {
    PixelButtonFace(configuration: configuration, kind: kind, fillsWidth: fillsWidth, icon: icon)
  }
}

private struct PixelButtonFace: View {
  let configuration: ButtonStyleConfiguration
  let kind: PixelButtonStyle.Kind
  let fillsWidth: Bool
  let icon: PixelIcon?

  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.isFocused) private var isFocused
  @State private var isHovered = false

  var body: some View {
    let pressed = configuration.isPressed && isEnabled
    HStack(spacing: Pixel.Space.s) {
      if let icon { PixelIconView(icon) }
      configuration.label
        .font(.pixel())
        .lineLimit(1)
    }
    .foregroundStyle(foreground)
    .padding(.horizontal, kind == .quiet ? Pixel.Space.s : Pixel.Space.l)
    .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: Pixel.controlHeight)
    .background { if let fill = fill(pressed: pressed) { PixelRect().fill(fill) } }
    .overlay {
      if let border {
        PixelBorder().fill(border, style: FillStyle(eoFill: true)).allowsHitTesting(false)
      }
    }
    .background {
      PixelRect().fill(Ink.shadowHard).offset(y: Pixel.shadow)
        .opacity(showsShadow && !pressed ? 1 : 0)
    }
    .offset(y: pressed && showsShadow ? Pixel.shadow : 0)
    .padding(.bottom, kind == .quiet ? 0 : Pixel.shadow)
    .overlay { PixelFocusRing(isVisible: isFocused && isEnabled) }
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
  }

  private var showsShadow: Bool { isEnabled && kind != .quiet }

  private var foreground: Color {
    guard isEnabled else { return Ink.textFaint }
    switch kind {
    case .primary: return Ink.onAccent
    case .danger: return Ink.onDanger
    case .secondary: return Ink.text
    case .quiet: return isHovered ? Ink.text : Ink.accent
    }
  }

  private func fill(pressed: Bool) -> Color? {
    guard isEnabled else { return kind == .quiet ? nil : Ink.sunken }
    switch kind {
    case .primary: return Ink.accent
    case .danger: return Ink.danger
    case .secondary: return isHovered || pressed ? Ink.raisedHover : Ink.raised
    case .quiet: return isHovered || pressed ? Ink.raised : nil
    }
  }

  private var border: Color? {
    guard isEnabled else { return kind == .quiet ? nil : Ink.lineSoft }
    switch kind {
    case .primary, .danger, .secondary: return Ink.control
    case .quiet: return nil
    }
  }
}

/// An icon-only button. The tile appears on hover so a row of them reads as a
/// toolbar rather than a row of boxes; the 28-point target is there either way.
struct PixelIconButtonStyle: ButtonStyle {
  enum Context { case chrome, surface }

  var context: Context = .surface
  var destructive = false
  var size: CGFloat = Pixel.hitTarget

  func makeBody(configuration: Configuration) -> some View {
    PixelIconButtonFace(
      configuration: configuration, context: context, destructive: destructive, size: size)
  }
}

private struct PixelIconButtonFace: View {
  let configuration: ButtonStyleConfiguration
  let context: PixelIconButtonStyle.Context
  let destructive: Bool
  let size: CGFloat

  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.isFocused) private var isFocused
  @State private var isHovered = false

  var body: some View {
    let pressed = configuration.isPressed && isEnabled
    configuration.label
      .foregroundStyle(foreground)
      .offset(y: pressed ? 1 : 0)
      .frame(width: size, height: size)
      .background {
        if isEnabled, isHovered || pressed {
          PixelRect().fill(tile(pressed: pressed))
        }
      }
      .overlay { PixelFocusRing(isVisible: isFocused && isEnabled).padding(Pixel.border + 1) }
      .contentShape(Rectangle())
      .onHover { isHovered = $0 }
  }

  private func tile(pressed: Bool) -> Color {
    switch context {
    case .chrome: pressed ? Ink.chromeWell : Ink.chromeHover
    case .surface: pressed ? Ink.raisedHover : Ink.raised
    }
  }

  private var foreground: Color {
    switch context {
    case .chrome:
      return isEnabled ? Ink.chromeText : Ink.chromeMuted.opacity(0.45)
    case .surface:
      guard isEnabled else { return Ink.textFaint }
      if destructive { return Ink.danger }
      return isHovered ? Ink.text : Ink.textMuted
    }
  }
}

/// A text-like button for headers and disclosures: no face, colour on hover.
struct PixelPlainButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    PixelPlainButtonFace(configuration: configuration)
  }
}

private struct PixelPlainButtonFace: View {
  let configuration: ButtonStyleConfiguration
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.isFocused) private var isFocused
  @State private var isHovered = false

  var body: some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.7 : 1)
      .background {
        if isHovered, isEnabled {
          PixelRect(step: 1).fill(Ink.raised).padding(-Pixel.Space.xxs)
        }
      }
      .overlay { PixelFocusRing(isVisible: isFocused && isEnabled) }
      .contentShape(Rectangle())
      .onHover { isHovered = $0 }
  }
}

// MARK: - Tabs

/// One segment of a pixel tab well. Selected segments are raised keycaps; the
/// others sit flush in the well and light up on hover.
struct PixelTabStyle: ButtonStyle {
  enum Context { case chrome, surface }

  let isSelected: Bool
  var context: Context = .chrome

  func makeBody(configuration: Configuration) -> some View {
    PixelTabFace(configuration: configuration, isSelected: isSelected, context: context)
  }
}

private struct PixelTabFace: View {
  let configuration: ButtonStyleConfiguration
  let isSelected: Bool
  let context: PixelTabStyle.Context

  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.isFocused) private var isFocused
  @State private var isHovered = false

  var body: some View {
    configuration.label
      .font(.pixel())
      .lineLimit(1)
      .foregroundStyle(foreground)
      .padding(.horizontal, Pixel.Space.m)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background { background }
      .overlay { PixelFocusRing(isVisible: isFocused && isEnabled).padding(Pixel.border + 1) }
      .contentShape(Rectangle())
      .onHover { isHovered = $0 }
  }

  @ViewBuilder private var background: some View {
    switch (context, isSelected) {
    case (.chrome, true):
      PixelRect()
        .fill(Ink.chromeTab)
        .overlay(alignment: .bottom) {
          Rectangle().fill(Ink.accent).frame(height: Pixel.border).padding(.horizontal, Pixel.border)
        }
    case (.surface, true):
      PixelRect().fill(Ink.accentSoft)
        .overlay { PixelBorder().fill(Ink.accent, style: FillStyle(eoFill: true)) }
    case (.chrome, false):
      if isHovered || configuration.isPressed { PixelRect().fill(Ink.chromeHover) }
    case (.surface, false):
      if isHovered || configuration.isPressed { PixelRect().fill(Ink.raised) }
    }
  }

  private var foreground: Color {
    switch (context, isSelected) {
    case (.chrome, true): Ink.chromeTabText
    case (.chrome, false): isHovered ? Ink.chromeText : Ink.chromeMuted
    case (.surface, true): Ink.accent
    case (.surface, false): isHovered ? Ink.text : Ink.textMuted
    }
  }
}

/// The recessed strip a row of tabs sits in.
struct PixelTabWell<Content: View>: View {
  var context: PixelTabStyle.Context = .chrome
  @ViewBuilder let content: Content

  init(context: PixelTabStyle.Context = .chrome, @ViewBuilder content: () -> Content) {
    self.context = context
    self.content = content()
  }

  var body: some View {
    HStack(spacing: Pixel.Space.xxs) { content }
      .padding(Pixel.border + Pixel.Space.xxs)
      .pixelSurface(
        fill: context == .chrome ? Ink.chromeWell : Ink.sunken,
        border: context == .chrome ? Ink.chromeLine : Ink.control)
  }
}

// MARK: - Text input

/// A labelled pixel text field. The label is pixel type; what the user types is
/// in the system font (monospaced for URLs, IDs and keys), because input has to
/// be read exactly.
struct PixelTextField<Accessory: View>: View {
  let title: String
  var note: String?
  @Binding var text: String
  let placeholder: String
  var monospaced = false
  var secure = false
  @ViewBuilder var accessory: Accessory

  @FocusState private var isFocused: Bool

  /// The placeholder in the faint ink, so an empty field never reads as filled.
  private var prompt: Text {
    Text(placeholder).foregroundColor(Ink.textFaint)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Pixel.Space.xs) {
      HStack(alignment: .firstTextBaseline, spacing: Pixel.Space.s) {
        Text(title).font(.pixel()).foregroundStyle(Ink.textMuted)
        if let note {
          Text(note).font(.uiCaption).foregroundStyle(Ink.textFaint).lineLimit(1)
        }
      }
      HStack(spacing: Pixel.Space.xxs) {
        Group {
          if secure {
            SecureField(text: $text, prompt: prompt) { Text(title) }
          } else {
            TextField(text: $text, prompt: prompt) { Text(title) }
          }
        }
        .textFieldStyle(.plain)
        .labelsHidden()
        .font(monospaced ? .uiMono : .uiBody)
        // No foreground style here: it would also tint the placeholder, and a
        // placeholder in the text colour reads as a value already filled in.
        .focused($isFocused)
        accessory
      }
      .padding(.leading, Pixel.Space.m)
      .padding(.trailing, Pixel.Space.xxs + Pixel.border)
      .frame(height: 28)
      .background {
        PixelRect().fill(Ink.sunken)
          .overlay(alignment: .top) {
            // A one-point shade under the top edge: the field sits below the card.
            Rectangle().fill(Ink.lineSoft).frame(height: 1)
              .padding(.top, Pixel.border).padding(.horizontal, Pixel.border)
          }
      }
      .overlay {
        PixelBorder()
          .fill(isFocused ? Ink.accent : Ink.control, style: FillStyle(eoFill: true))
          .allowsHitTesting(false)
      }
    }
  }
}

extension PixelTextField where Accessory == EmptyView {
  init(
    title: String, note: String? = nil, text: Binding<String>, placeholder: String,
    monospaced: Bool = false, secure: Bool = false
  ) {
    self.init(
      title: title, note: note, text: text, placeholder: placeholder, monospaced: monospaced,
      secure: secure, accessory: { EmptyView() })
  }
}

// MARK: - Disclosure

/// A collapsible section with a pixel triangle.
struct PixelDisclosure<Content: View>: View {
  let title: String
  @Binding var isExpanded: Bool
  @ViewBuilder let content: Content

  init(_ title: String, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
    self.title = title
    _isExpanded = isExpanded
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Pixel.Space.m) {
      Button {
        isExpanded.toggle()
      } label: {
        HStack(spacing: Pixel.Space.xs) {
          PixelIconView(isExpanded ? .chevronDown : .chevronRight)
          Text(title).font(.pixel())
        }
        .foregroundStyle(Ink.textMuted)
        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
      }
      .buttonStyle(PixelPlainButtonStyle())
      .pixelFocusEffect()
      .accessibilityValue(isExpanded ? L10n.Common.expanded : L10n.Common.collapsed)
      if isExpanded { content }
    }
  }
}

// MARK: - Progress

/// Overrides the system's Reduce Motion setting for the views below it. Nil, the
/// default, follows the system; the renders set it to show the still variants,
/// because the system value cannot be set from code.
struct ReduceMotionOverrideKey: EnvironmentKey {
  static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
  var reduceMotionOverride: Bool? {
    get { self[ReduceMotionOverrideKey.self] }
    set { self[ReduceMotionOverrideKey.self] = newValue }
  }
}

/// A busy indicator in whole quarter turns — a retro spinner, and one that never
/// leaves the pixel grid. Its phase starts from its own appearance, so the first
/// frame matches the resting icon. With Reduce Motion it is a still hourglass.
///
/// Driven by a `TimelineView`, never by a repeating animation: an animation that
/// never completes is inherited by whatever re-lays-out beside it, and the panel's
/// title once slid for as long as the app ran because of exactly that.
struct PixelSpinner: View {
  var icon: PixelIcon = .refresh
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.reduceMotionOverride) private var reduceMotionOverride
  @State private var start = Date()

  private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

  private static let frameDuration: TimeInterval = 0.15

  var body: some View {
    if reduceMotion {
      PixelIconView(.hourglass)
    } else {
      TimelineView(.periodic(from: start, by: Self.frameDuration)) { context in
        PixelIconView(icon)
          .rotationEffect(.degrees(Double(frame(at: context.date)) * 90))
      }
    }
  }

  private func frame(at date: Date) -> Int {
    max(0, Int(date.timeIntervalSince(start) / Self.frameDuration)) % 4
  }
}

// MARK: - Feedback

/// A message strip: the outcome of an action, or a problem with the data.
struct PixelNotice: View {
  enum Tone { case error, warning, success, info }

  let text: String
  let tone: Tone
  var actionTitle: String?
  var actionDisabled = false
  var action: (() -> Void)?

  var body: some View {
    HStack(alignment: .top, spacing: Pixel.Space.m) {
      PixelIconView(icon)
        .foregroundStyle(strong)
        .padding(.top, 1)
      Text(text)
        .font(.uiCaption)
        .foregroundStyle(Ink.text)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
      if let actionTitle, let action {
        Button(actionTitle, action: action)
          .buttonStyle(PixelButtonStyle(kind: .secondary))
          .pixelFocusEffect()
          .disabled(actionDisabled)
      }
    }
    .padding(.horizontal, Pixel.Space.l)
    .padding(.vertical, Pixel.Space.m)
    .pixelSurface(fill: soft, border: strong)
    .accessibilityElement(children: .combine)
  }

  private var icon: PixelIcon {
    switch tone {
    case .error: .cross
    case .warning: .warning
    case .success: .check
    case .info: .info
    }
  }

  private var strong: Color {
    switch tone {
    case .error: Ink.danger
    case .warning: Ink.warning
    case .success: Ink.success
    case .info: Ink.textMuted
    }
  }

  private var soft: Color {
    switch tone {
    case .error: Ink.dangerSoft
    case .warning: Ink.warningSoft
    case .success: Ink.successSoft
    case .info: Ink.sunken
    }
  }
}

/// A small tag for an identifier: a model, a key fragment, a credential style.
struct PixelChip: View {
  let text: String
  var monospaced = true

  var body: some View {
    Text(text)
      .font(monospaced ? .uiMono : .pixel())
      .lineLimit(1)
      .truncationMode(.middle)
      .foregroundStyle(Ink.textMuted)
      .padding(.horizontal, 5)
      .frame(height: 18)
      .background { PixelRect(step: 1).fill(Ink.sunken) }
      .overlay {
        PixelBorder(width: 1, steps: 1).fill(Ink.lineSoft, style: FillStyle(eoFill: true))
      }
  }
}

/// A 6 × 6 status lamp.
struct PixelLamp: View {
  let color: Color

  var body: some View {
    PixelArtView(glyph: PixelArt.lamp, palette: ["#": color])
  }
}

/// A one-point dashed rule.
struct PixelDivider: View {
  var color: Color = Ink.lineSoft

  var body: some View {
    PixelDashes()
      .fill(color)
      .frame(height: 1)
      .accessibilityHidden(true)
  }
}

private struct PixelDashes: Shape {
  var dash: CGFloat = 2
  var gap: CGFloat = 2

  func path(in rect: CGRect) -> Path {
    var path = Path()
    var x = rect.minX
    while x < rect.maxX {
      path.addRect(CGRect(x: x, y: rect.minY, width: min(dash, rect.maxX - x), height: rect.height))
      x += dash + gap
    }
    return path
  }
}

/// A card's title row: icon, pixel title, and whatever belongs on the right.
struct PixelSectionHeader<Trailing: View>: View {
  let icon: PixelIcon?
  let title: String
  @ViewBuilder let trailing: Trailing

  init(icon: PixelIcon? = nil, title: String, @ViewBuilder trailing: () -> Trailing) {
    self.icon = icon
    self.title = title
    self.trailing = trailing()
  }

  var body: some View {
    HStack(spacing: Pixel.Space.s) {
      if let icon { PixelIconView(icon).foregroundStyle(Ink.textMuted) }
      Text(title).font(.pixel()).foregroundStyle(Ink.text)
      Spacer(minLength: Pixel.Space.s)
      trailing
    }
    .frame(minHeight: 16)
  }
}

extension PixelSectionHeader where Trailing == EmptyView {
  init(icon: PixelIcon? = nil, title: String) {
    self.init(icon: icon, title: title, trailing: { EmptyView() })
  }
}

// MARK: - Dialog

/// A confirmation box drawn inside the panel, over a dimmed backdrop that blocks
/// the controls beneath it. Escape cancels. The destructive button is never the
/// default, so Return cannot delete anything by accident.
struct PixelDialog: View {
  let title: String
  let message: String
  let confirmTitle: String
  let cancelTitle: String
  var destructive = true
  let onConfirm: () -> Void
  let onCancel: () -> Void

  var body: some View {
    ZStack(alignment: .top) {
      Ink.canvas.opacity(0.82)
        .contentShape(Rectangle())
        .onTapGesture {}
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Pixel.Space.l) {
        HStack(alignment: .top, spacing: Pixel.Space.m) {
          PixelIconView(.warning)
            .foregroundStyle(destructive ? Ink.danger : Ink.warning)
          Text(title)
            .font(.pixel())
            .foregroundStyle(Ink.text)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
        }
        Text(message)
          .font(.uiCaption)
          .foregroundStyle(Ink.textMuted)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: Pixel.Space.m) {
          Spacer(minLength: 0)
          Button(cancelTitle, action: onCancel)
            .buttonStyle(PixelButtonStyle(kind: .secondary))
            .pixelFocusEffect()
            .keyboardShortcut(.cancelAction)
          Button(confirmTitle, action: onConfirm)
            .buttonStyle(PixelButtonStyle(kind: destructive ? .danger : .primary))
            .pixelFocusEffect()
        }
      }
      .padding(Pixel.Space.xxl)
      .frame(width: 344)
      .pixelSurface(fill: Ink.surface, border: Ink.line, steps: 2, shadow: Ink.shadowHard, shadowOffset: 4)
      .padding(.top, 36)
      .accessibilityElement(children: .contain)
      .accessibilityAddTraits(.isModal)
    }
  }
}

// MARK: - Illustration

/// The small terminal shown when there is nothing else to show. Loading lights
/// three blocks in turn (still with Reduce Motion); the empty state waits at a
/// prompt; an error shows an alert sign. The empty and error states do not move:
/// motion there would only be decoration.
struct TerminalIllustration: View {
  enum Mode { case empty, loading, error }

  let mode: Mode
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.reduceMotionOverride) private var reduceMotionOverride
  @State private var start = Date()

  private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

  private static let scale: CGFloat = 2
  private static let blockDuration: TimeInterval = 0.25

  var body: some View {
    ZStack(alignment: .topLeading) {
      PixelArtView(
        glyph: PixelArt.terminal,
        palette: ["d": Ink.line, "h": Ink.raised, "n": Ink.brandNight],
        scale: Self.scale)
      screen
        .offset(
          x: CGFloat(PixelArt.screenOrigin.x) * Self.scale,
          y: CGFloat(PixelArt.screenOrigin.y) * Self.scale)
    }
    .accessibilityHidden(true)
  }

  @ViewBuilder private var screen: some View {
    switch mode {
    case .empty:
      ZStack {
        PixelArtView(glyph: PixelArt.screenPrompt, palette: ["c": Ink.brandCyan], scale: Self.scale)
        PixelArtView(glyph: PixelArt.screenCursor, palette: ["c": Ink.brandCyan], scale: Self.scale)
      }
    case .loading:
      if reduceMotion {
        blocks(lit: nil)
      } else {
        TimelineView(.periodic(from: start, by: Self.blockDuration)) { context in
          blocks(lit: max(0, Int(context.date.timeIntervalSince(start) / Self.blockDuration)) % 3)
        }
      }
    case .error:
      PixelArtView(glyph: PixelArt.screenAlert, palette: ["y": Ink.fixed(0xFFC86E)], scale: Self.scale)
    }
  }

  /// `lit` is the block shown at full strength; nil shows all three evenly.
  private func blocks(lit: Int?) -> some View {
    ZStack {
      ForEach(0..<PixelArt.screenBlocks.count, id: \.self) { index in
        PixelArtView(
          glyph: PixelArt.screenBlocks[index],
          palette: ["c": Ink.brandCyan.opacity(lit == nil || lit == index ? 1 : 0.3)],
          scale: Self.scale)
      }
    }
  }
}
