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

/// A subcommand of the `diskscope` binary.
public protocol Command: Sendable {
    var name: String { get }
    var summary: String { get }
    /// One or two lines of detail, shown by `diskscope help <name>`.
    var discussion: String { get }
    func run(options: Options, terminal: Terminal) async throws -> Int32
}

public extension Command {
    var discussion: String { "" }
}
