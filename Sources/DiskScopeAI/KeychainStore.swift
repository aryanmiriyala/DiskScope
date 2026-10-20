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
import Security

/// Stores BYOK credentials in the login Keychain.
///
/// Design rules:
///
/// * Secrets go in the Keychain, never `UserDefaults` and never a plist.
/// * `kSecAttrAccessibleWhenUnlocked`, so a key is not readable while the Mac
///   is locked and the screen is captured by an attacker.
/// * Keys are stored **per provider** so switching providers cannot leak one
///   into another's slot.
/// * Nothing here is ever logged. `Account` is the provider id; the secret is
///   write-only from this API's perspective and is only ever read back to make
///   a request.
public struct KeychainStore: Sendable {
    /// The service name under which all DiskScope secrets live.
    private static let service = "com.diskscope.credentials"

    public enum Provider: String, Sendable, CaseIterable, Identifiable {
        case openAI
        case anthropic
        /// Any OpenAI-compatible endpoint, which covers most local servers too.
        case openAICompatible

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .openAI: return "OpenAI"
            case .anthropic: return "Anthropic"
            case .openAICompatible: return "OpenAI-compatible endpoint"
            }
        }

        public var defaultBaseURL: URL? {
            switch self {
            case .openAI:
                return URL(string: "https://api.openai.com/v1")
            case .anthropic:
                return URL(string: "https://api.anthropic.com/v1")
            case .openAICompatible:
                // Left blank: this is whatever the user is running locally.
                return nil
            }
        }

        public var keyPlaceholder: String {
            switch self {
            case .openAI: return "sk-..."
            case .anthropic: return "sk-ant-..."
            case .openAICompatible: return "Paste the key your server expects"
            }
        }
    }

    public init() {}

    public func saveKey(_ key: String, for provider: Provider) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KeychainError.emptyKey
        }
        try store(Data(trimmed.utf8), account: provider.rawValue)
    }

    public func key(for provider: Provider) throws -> String? {
        guard let data = try read(account: provider.rawValue) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func deleteKey(for provider: Provider) throws {
        try delete(account: provider.rawValue)
    }

    public func hasKey(for provider: Provider) -> Bool {
        (try? key(for: provider)).map { $0?.isEmpty == false } ?? false
    }

    /// Forget every credential. Used by "remove all keys" in settings, so a
    /// user uninstalling or handing over the Mac has one clear action.
    public func deleteAllKeys() throws {
        for provider in Provider.allCases {
            try delete(account: provider.rawValue)
        }
    }

    // MARK: - Primitives

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }

    private func store(_ data: Data, account: String) throws {
        var query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

public enum KeychainError: LocalizedError, Sendable {
    case emptyKey
    case unexpectedStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .emptyKey:
            return "The API key was empty."
        case .unexpectedStatus(let status):
            // Deliberately does not include the key or any request data.
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "Keychain error \(status): \(message)"
        }
    }
}
