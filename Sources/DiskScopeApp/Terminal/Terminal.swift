// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Aryan Miriyala
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import DiskScopeCore

/// Terminal presentation helpers.
///
/// DiskScope is a terminal tool first, so output quality is not decoration. A
/// breakdown that a user cannot read at a glance is a breakdown they will not
/// trust, and this app exists because they already do not trust the numbers
/// macOS gives them.
public struct Terminal {
    /// Whether stdout is an interactive terminal.
    public let isInteractive: Bool
    /// Whether to emit ANSI escapes.
    public let useColor: Bool
    public let width: Int

    public init(forceColor: Bool? = nil, forceWidth: Int? = nil) {
        let interactive = isatty(STDOUT_FILENO) == 1

        // Respect the NO_COLOR convention, and the widely honoured habit of
        // piping to a pager.
        let noColorEnv = ProcessInfo.processInfo.environment["NO_COLOR"] != nil
        let wantsColor = forceColor ?? (interactive && !noColorEnv)

        self.isInteractive = interactive
        self.useColor = wantsColor
        self.width = forceWidth ?? Terminal.detectWidth(fallback: interactive ? 100 : 80)
    }

    private static func detectWidth(fallback: Int) -> Int {
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 20 {
            return Int(size.ws_col)
        }
        return fallback
    }

    // MARK: - Styling

    public enum Style: String {
        case bold = "\u{1B}[1m"
        case dim = "\u{1B}[2m"
        case italic = "\u{1B}[3m"
        case red = "\u{1B}[38;5;203m"
        case green = "\u{1B}[38;5;114m"
        case yellow = "\u{1B}[38;5;179m"
        case orange = "\u{1B}[38;5;215m"
        case blue = "\u{1B}[38;5;110m"
        case grey = "\u{1B}[38;5;245m"
        case reset = "\u{1B}[0m"
    }

    /// Wrap `text` in a style, or return it unchanged when colour is off.
    public func paint(_ text: String, _ style: Style) -> String {
        guard useColor else { return text }
        return style.rawValue + text + Style.reset.rawValue
    }

    public func bold(_ text: String) -> String { paint(text, .bold) }
    public func dim(_ text: String) -> String { paint(text, .dim) }

    /// Colour for a risk level, so the danger of an action is visible before it
    /// is taken rather than described in prose afterwards.
    public func paint(risk: RiskLevel) -> String {
        let style: Style
        switch risk {
        case .regenerable: style = .green
        case .disposable: style = .yellow
        case .caution: style = .orange
        case .destructive: style = .red
        case .informational: style = .grey
        }
        return paint(risk.title, style)
    }

    // MARK: - Layout

    /// Visible length, ignoring ANSI escapes.
    ///
    /// Every alignment calculation in the app depends on this being right. If
    /// it counted escape sequences as characters, every right-aligned size
    /// column would be visibly wrong.
    public static func visibleWidth(_ text: String) -> Int {
        var count = 0
        var inEscape = false

        for character in text {
            if inEscape {
                // CSI sequences end with a letter in the range 0x40...0x7E.
                if let ascii = character.asciiValue, (0x40...0x7E).contains(ascii) {
                    inEscape = false
                }
                continue
            }
            if character == "\u{1B}" {
                inEscape = true
                continue
            }
            count += 1
        }
        return count
    }

    public func pad(_ text: String, to width: Int, align: Alignment = .left) -> String {
        let padding = max(0, width - Self.visibleWidth(text))
        switch align {
        case .left: return text + String(repeating: " ", count: padding)
        case .right: return String(repeating: " ", count: padding) + text
        }
    }

    public enum Alignment {
        case left
        case right
    }

    /// Truncate with an ellipsis, respecting the visible width.
    public func truncate(_ text: String, to width: Int) -> String {
        guard Self.visibleWidth(text) > width, width > 1 else { return text }
        return String(text.prefix(width - 1)) + "\u{2026}"
    }

    /// Word-wrap to a column width.
    public func wrap(_ text: String, to width: Int) -> [String] {
        guard width > 10 else { return [text] }

        var lines: [String] = []
        var current = ""

        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            if current.isEmpty {
                current = String(word)
            } else if Self.visibleWidth(current) + 1 + word.count <= width {
                current += " " + word
            } else {
                lines.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.isEmpty ? [""] : lines
    }

    // MARK: - Output

    /// Write a line to stdout.
    public func line(_ text: String = "") {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    /// Write without a trailing newline, for progress spinners.
    public func raw(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    /// A section heading.
    public func heading(_ text: String) {
        line()
        line(bold(text))
        line(dim(String(repeating: "\u{2500}", count: min(text.count, max(20, width - 4)))))
    }
}
