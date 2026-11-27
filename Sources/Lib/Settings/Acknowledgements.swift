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
/// (GPL-3.0), AdGuard ExtendedCSS (GPL-3.0) —
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
    OSSCredit(
      id: "sparkle",
      name: "Sparkle",
      license: "MIT License",
      licenseBody: sparkleLicenseBody,
      url: URL(string: "https://github.com/sparkle-project/Sparkle")!,
      description: "In-app software updates (Sparkle.framework)."
    ),
  ]
}

/// Sparkle's LICENSE as shipped with the release `SPARKLE_VERSION` pins,
/// external licenses included — the framework bundles that code too.
private let sparkleLicenseBody = """
  Copyright (c) 2006-2013 Andy Matuschak.
  Copyright (c) 2009-2013 Elgato Systems GmbH.
  Copyright (c) 2011-2014 Kornel Lesiński.
  Copyright (c) 2015-2017 Mayur Pawashe.
  Copyright (c) 2014 C.W. Betts.
  Copyright (c) 2014 Petroules Corporation.
  Copyright (c) 2014 Big Nerd Ranch.
  All rights reserved.

  Permission is hereby granted, free of charge, to any person obtaining a copy of
  this software and associated documentation files (the "Software"), to deal in
  the Software without restriction, including without limitation the rights to
  use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
  the Software, and to permit persons to whom the Software is furnished to do so,
  subject to the following conditions:

  The above copyright notice and this permission notice shall be included in all
  copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
  FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
  COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
  IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
  CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

  =================
  EXTERNAL LICENSES
  =================

  bspatch.c and bsdiff.c, from bsdiff 4.3 <http://www.daemonology.net/bsdiff/>:

  Copyright 2003-2005 Colin Percival
  All rights reserved

  Redistribution and use in source and binary forms, with or without
  modification, are permitted providing that the following conditions
  are met:
  1. Redistributions of source code must retain the above copyright
     notice, this list of conditions and the following disclaimer.
  2. Redistributions in binary form must reproduce the above copyright
     notice, this list of conditions and the following disclaimer in the
     documentation and/or other materials provided with the distribution.

  THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
  IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
  WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
  ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
  DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
  DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
  OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
  HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
  STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
  IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
  POSSIBILITY OF SUCH DAMAGE.

  --

  sais.c and sais.h, from sais-lite (2010/08/07) <https://sites.google.com/site/yuta256/sais>:

  The sais-lite copyright is as follows:

  Copyright (c) 2008-2010 Yuta Mori All Rights Reserved.

  Permission is hereby granted, free of charge, to any person
  obtaining a copy of this software and associated documentation
  files (the "Software"), to deal in the Software without
  restriction, including without limitation the rights to use,
  copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the
  Software is furnished to do so, subject to the following
  conditions:

  The above copyright notice and this permission notice shall be
  included in all copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
  OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
  NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
  HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
  WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
  OTHER DEALINGS IN THE SOFTWARE.

  --

  Portable C implementation of Ed25519, from https://github.com/orlp/ed25519

  Copyright (c) 2015 Orson Peters <orsonpeters@gmail.com>

  This software is provided 'as-is', without any express or implied warranty. In no event will the
  authors be held liable for any damages arising from the use of this software.

  Permission is granted to anyone to use this software for any purpose, including commercial
  applications, and to alter it and redistribute it freely, subject to the following restrictions:

  1. The origin of this software must not be misrepresented; you must not claim that you wrote the
     original software. If you use this software in a product, an acknowledgment in the product
     documentation would be appreciated but is not required.

  2. Altered source versions must be plainly marked as such, and must not be misrepresented as
     being the original software.

  3. This notice may not be removed or altered from any source distribution.

  --

  SUSignatureVerifier.m:

  Copyright (c) 2011 Mark Hamlin.

  All rights reserved.

  Redistribution and use in source and binary forms, with or without
  modification, are permitted providing that the following conditions
  are met:
  1. Redistributions of source code must retain the above copyright
     notice, this list of conditions and the following disclaimer.
  2. Redistributions in binary form must reproduce the above copyright
     notice, this list of conditions and the following disclaimer in the
     documentation and/or other materials provided with the distribution.

  THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
  IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
  WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
  ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
  DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
  DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
  OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
  HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
  STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
  IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
  POSSIBILITY OF SUCH DAMAGE.
  """

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
