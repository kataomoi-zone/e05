import Foundation

/// One acknowledged open-source dependency. Bundled at compile time
/// — the list lives in this file (rather than a resource bundle) so
/// adding a credit is a one-line PR with no plist / Markdown
/// roundtrip and no Resources-copy step in `build_app.sh`.
public struct OSSCredit: Identifiable, Hashable, Sendable {
  public let id: String
  public let name: String
  public let license: String
  public let licenseBody: String
  public let url: URL
  public let description: String

  public init(
    id: String,
    name: String,
    license: String,
    licenseBody: String,
    url: URL,
    description: String
  ) {
    self.id = id
    self.name = name
    self.license = license
    self.licenseBody = licenseBody
    self.url = url
    self.description = description
  }
}

/// Open-source projects whose binaries are bundled with e05. Apple
/// system frameworks (WebKit / AppKit / Foundation / etc.) follow
/// the App Store convention of not requiring per-app credit; the
/// internal adblocker engine, Netscape bookmarks parser, and other
/// in-tree code lives under e05's own LICENSE and is not listed
/// here either.
///
/// e05's own code is MIT, so it ships no GPL *engine* code: concept-
/// only references — Brave's adblock-rust (MPL-2.0), uBlock Origin
/// (GPL-3.0), AdGuard ExtendedCSS (GPL-3.0), zentty (GPL-3.0) —
/// informed the design but were reimplemented rather than bundled, so
/// they are not listed here. The one piece of GPL code that does ship
/// is ghostty's shell-integration (GPL-3.0, derived from Kitty):
/// unavoidable when using ghostty's terminal integration, it is
/// *aggregated* (standalone scripts, not linked into e05's MIT code)
/// and credited below, with its full license bundled under
/// Resources/licenses.
public enum Acknowledgements {
  public static let all: [OSSCredit] = [
    OSSCredit(
      id: "ghostty",
      name: "Ghostty",
      license: "MIT License",
      licenseBody: ghosttyLicenseBody,
      url: URL(string: "https://github.com/ghostty-org/ghostty")!,
      description: "Terminal emulator embedded through libghostty (GhosttyKit.xcframework)."
    ),
    OSSCredit(
      id: "ghostty-shell-integration",
      name: "Ghostty shell integration (derived from Kitty)",
      license: "GPL-3.0-or-later",
      licenseBody: gplShellIntegrationNotice,
      url: URL(string: "https://github.com/ghostty-org/ghostty")!,
      description:
        "Bundled zsh / bash shell-integration scripts (prompt marking, working-directory reporting). Aggregated, not linked into e05's code; e05 appends a one-line PATH-fix hook to them at build time."
    ),
  ]
}

private let ghosttyLicenseBody = """
  MIT License

  Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors

  Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the "Software"), to deal
  in the Software without restriction, including without limitation the rights
  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in all
  copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
  SOFTWARE.
  """

private let gplShellIntegrationNotice = """
  The bundled ghostty shell-integration scripts (derived from Kitty)
  are licensed under the GNU General Public License v3:

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.

  The complete license text is bundled at
  Contents/Resources/licenses/GPL-3.0.txt and at
  https://www.gnu.org/licenses/gpl-3.0.txt.
  """
