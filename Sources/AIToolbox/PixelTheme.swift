import AppKit
import CoreText
import SwiftUI

/// The pixel design system's grid.
///
/// One art pixel is one point. Every border, corner step, icon cell and pixel-font
/// pixel therefore lands on whole points — two device pixels on a Retina display,
/// one on a standard one — and stays crisp on both. Anything that would need a
/// fractional point (a 1.5× font, a scaled icon) is avoided rather than smoothed.
enum Pixel {
  /// Container border thickness and corner-step size.
  static let border: CGFloat = 2
  /// Data marks, dividers and the outline of small chips.
  static let hairline: CGFloat = 1
  /// Offset of the hard drop shadow under raised controls.
  static let shadow: CGFloat = 2
  /// Smallest pointer target for icon buttons.
  static let hitTarget: CGFloat = 28
  /// Standard control height (button face, text field, tab).
  static let controlHeight: CGFloat = 26

  /// The spacing scale. Everything sits on a 2-point rhythm.
  enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 6
    static let m: CGFloat = 8
    static let l: CGFloat = 10
    static let xl: CGFloat = 12
    static let xxl: CGFloat = 16
  }
}

/// The palette: a small, fixed set of inks with a day and a night value each, and a
/// stronger value for the system's Increase Contrast setting where the default is
/// deliberately quiet. Taken from the app icon — midnight navy, cyan, blue, violet —
/// so the panel, the menu-bar mark and the icon read as one product.
///
/// Text inks meet WCAG AA (4.5:1) on the surfaces they are used on; chart fills and
/// control borders meet the 3:1 non-text minimum. `textFaint` is for disabled and
/// decorative text only.
enum Ink {
  private static func ink(
    _ light: UInt32, _ dark: UInt32, contrastLight: UInt32? = nil, contrastDark: UInt32? = nil
  ) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let match = appearance.bestMatch(from: [
          .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
        ])
        let hex: UInt32
        switch match {
        case .darkAqua: hex = dark
        case .accessibilityHighContrastAqua: hex = contrastLight ?? light
        case .accessibilityHighContrastDarkAqua: hex = contrastDark ?? dark
        default: hex = light
        }
        return NSColor(
          srgbRed: Double((hex >> 16) & 0xFF) / 255,
          green: Double((hex >> 8) & 0xFF) / 255,
          blue: Double(hex & 0xFF) / 255,
          alpha: 1
        )
      })
  }

  /// Fixed colours that do not change with the appearance.
  static func fixed(_ hex: UInt32) -> Color {
    Color(
      .sRGB,
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255
    )
  }

  // Surfaces
  static let canvas = ink(0xE9EEF6, 0x14172A)
  static let surface = ink(0xFFFFFF, 0x1D2138)
  static let sunken = ink(0xF1F4FA, 0x171A2E)
  static let raised = ink(0xEEF2F9, 0x283058)
  static let raisedHover = ink(0xE2E8F4, 0x323B6A)

  // Lines and shadows
  static let line = ink(0x1E2547, 0x4E5990, contrastLight: 0x000000, contrastDark: 0xA9B3CD)
  static let lineSoft = ink(0xC2CBDA, 0x2D3458, contrastLight: 0x4A5577, contrastDark: 0x6F7BB3)
  static let control = ink(0x1E2547, 0x6F7BB3, contrastLight: 0x000000, contrastDark: 0xC9D1EA)
  static let shadow = ink(0xC3CCDD, 0x0B0D19)
  static let shadowHard = ink(0x1E2547, 0x07080F)

  // Text
  static let text = ink(0x161B36, 0xEEF1FA, contrastLight: 0x000000, contrastDark: 0xFFFFFF)
  static let textMuted = ink(0x4A5577, 0xA9B3CD, contrastLight: 0x2B3352, contrastDark: 0xD4DAEA)
  static let textFaint = ink(0x7C87A3, 0x727DA0, contrastLight: 0x4A5577, contrastDark: 0xA9B3CD)

  // Chrome (header band)
  static let chrome = ink(0x26306B, 0x1F2858)
  static let chromeWell = ink(0x18204E, 0x121838)
  static let chromeLine = ink(0x10163A, 0x0B0F26)
  static let chromeText = ink(0xF3F5FF, 0xF3F5FF)
  static let chromeMuted = ink(0xB4BDE3, 0xA3AEDB, contrastLight: 0xDDE2F6, contrastDark: 0xD7DDF3)
  static let chromeHover = ink(0x313D80, 0x2C3770)
  static let chromeTab = ink(0xF3F5FF, 0x3A4890)
  static let chromeTabText = ink(0x161B36, 0xFFFFFF)
  static let chromeTabEdge = ink(0xFFFFFF, 0x5262B0)

  // Accent and its companions
  static let accent = ink(0x08707F, 0x6FE7F2, contrastLight: 0x04525D, contrastDark: 0x9DF3FA)
  static let accentFill = ink(0x0E8FA2, 0x3A9AA8)
  static let accentSoft = ink(0xDDF3F6, 0x163A47)
  static let onAccent = ink(0xFFFFFF, 0x0E1324)

  // Data series
  static let cacheRead = ink(0x3557C8, 0x7398FF)
  static let cacheWrite = ink(0x7547D6, 0xB596FF)
  static let uncached = ink(0x8692AE, 0x6B769C)
  static let inputSeries = ink(0x5F6B8A, 0x8A95B5)

  // Status
  static let success = ink(0x14733F, 0x7FE095)
  static let successSoft = ink(0xDFF3E7, 0x173A29)
  static let warning = ink(0x9A5800, 0xFFC86E)
  static let warningSoft = ink(0xFBEFD9, 0x3A2F16)
  static let danger = ink(0xBE2F45, 0xFF8592)
  static let dangerSoft = ink(0xFBE3E7, 0x3F1C25)
  static let onDanger = ink(0xFFFFFF, 0x0E1324)

  // Brand marks, identical in both appearances
  static let brandCyan = fixed(0x5CE1F0)
  static let brandBlue = fixed(0x4C8DF6)
  static let brandViolet = fixed(0x8B6CF7)
  static let brandNight = fixed(0x141A45)
  static let claude = fixed(0xD97757)
}

/// The bundled pixel typeface: Ark Pixel 12px Proportional, Simplified Chinese
/// variant (SIL Open Font License 1.1, see `ArkPixel-OFL.txt`).
///
/// It covers Latin, digits and 18,000+ CJK ideographs on a 12-pixel grid, so the
/// interface's titles and labels can be pixel type in Chinese, not only in ASCII.
/// Its digits share one advance width, so numbers do not shift as they change.
/// Anything it lacks falls back through Core Text's cascade to the system font —
/// never a missing-glyph box.
enum PixelFont {
  static let postScriptName = "Ark-Pixel-12px-Prop-zh-Hans-Regular"
  static let resourceName = "ark-pixel-12px-proportional-zh_hans"
  static let resourceExtension = "woff2"
  /// The size the glyphs are drawn for. Only whole multiples are pixel-exact.
  static let designSize: CGFloat = 12

  /// Registers the font for this process on first use. False when the file is
  /// missing or cannot be read; text then renders in the system font.
  static let isAvailable: Bool = {
    guard let url = AppResources.url(resourceName, resourceExtension) else { return false }
    var error: Unmanaged<CFError>?
    if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return true }
    // Already registered (a second test bundle, a relaunch within one process).
    return NSFont(name: postScriptName, size: designSize) != nil
  }()

  /// Every character the font draws itself. Used by tests to prove the interface's
  /// pixel-type strings never fall back mid-word.
  static var characterSet: CharacterSet? {
    guard isAvailable, let font = NSFont(name: postScriptName, size: designSize) else { return nil }
    return CTFontCopyCharacterSet(font as CTFont) as CharacterSet
  }
}

extension Font {
  /// The pixel font at `multiple` × its 12-point design size.
  static func pixel(_ multiple: Int = 1) -> Font {
    _ = PixelFont.isAvailable
    return .custom(PixelFont.postScriptName, fixedSize: PixelFont.designSize * CGFloat(multiple))
  }

  /// Running text — notices, explanations, error messages — stays in the system
  /// font, which reads better than any 12-pixel face at paragraph length.
  static let uiBody = Font.system(size: 12)
  static let uiCaption = Font.system(size: 11)
  /// Identifiers the user may compare character by character: URLs, model IDs,
  /// key fragments, environment variable names.
  static let uiMono = Font.system(size: 11, design: .monospaced)
}

/// Locates bundled resources without ever touching `Bundle.module` in a packaged
/// app. SwiftPM's generated accessor stops the process when its bundle is not where
/// the build left it, which is exactly the case for an app assembled by
/// `package-app.sh`; there the files are copied into `Contents/Resources` and
/// `Bundle.main` finds them.
enum AppResources {
  private final class Token {}

  private static let bundleName = "AIToolbox_AIToolbox.bundle"

  private static let resourceBundle: Bundle? = {
    let candidates = [
      Bundle.main.resourceURL?.appending(path: bundleName),
      Bundle.main.bundleURL.appending(path: bundleName),
      // Tests: the module is linked into the .xctest, which sits beside the bundle.
      Bundle(for: Token.self).bundleURL.deletingLastPathComponent().appending(path: bundleName),
    ]
    for case let url? in candidates {
      if let bundle = Bundle(url: url) { return bundle }
    }
    return nil
  }()

  static func url(_ name: String, _ ext: String) -> URL? {
    Bundle.main.url(forResource: name, withExtension: ext)
      ?? resourceBundle?.url(forResource: name, withExtension: ext)
  }
}
