import Foundation
import Security

/// Przechowuje token sesji w Keychain - to jedyny sekret, jaki ta apka trzyma
/// na urządzeniu (adres serwera i cele kaloryczne to dane nie-sekretne, patrz
/// `APIConfig` / `UserDefaults`).
enum KeychainStore {
    private static let service = "com.renacode.dietetyk.session"
    private static let account = "sessionToken"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// Zwraca `false`, gdy Keychain odmówił zapisu. Wcześniej wynik `SecItemAdd`
    /// był ignorowany, a zapis potrafi realnie się nie udać - build bez podpisu
    /// (`CODE_SIGNING_ALLOWED=NO`, czyli m.in. cały nasz CI) nie ma uprawnienia
    /// do Keychain i dostaje `errSecMissingEntitlement`. Aplikacja uznawała
    /// wtedy użytkownika za zalogowanego, mimo że token nigdzie nie trafił, i
    /// każde kolejne żądanie wracało z 401.
    @discardableResult
    static func saveToken(_ token: String) -> Bool {
        let data = Data(token.utf8)

        // Usuń istniejący wpis przed zapisem nowego - prościej i bardziej
        // przewidywalne niż SecItemUpdate przy zmianie atrybutów.
        SecItemDelete(baseQuery as CFDictionary)

        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        // Dostępny po pierwszym odblokowaniu urządzenia, nawet w tle - potrzebne,
        // żeby ewentualna synchronizacja w tle (np. przyszłe powiadomienia) mogła
        // odczytać token bez wymogu, by urządzenie było aktualnie odblokowane.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func loadToken() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        return token
    }

    static func deleteToken() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    static var hasToken: Bool {
        loadToken() != nil
    }
}

/// Miejsce przechowywania tokenu sesji. Istnieje po to, żeby `AppState` dało
/// się przetestować bez Keychain: w buildzie bez podpisu (CI) `SecItemAdd`
/// zwraca `errSecMissingEntitlement`, więc test oparty o prawdziwy Keychain
/// nie sprawdzałby logiki wylogowania, tylko obecność uprawnień.
protocol SessionTokenStore {
    /// `false`, jeśli zapis się nie powiódł.
    @discardableResult
    func save(_ token: String) -> Bool
    func load() -> String?
    func delete()
}

/// Produkcyjna implementacja - Keychain.
struct KeychainSessionTokenStore: SessionTokenStore {
    func save(_ token: String) -> Bool { KeychainStore.saveToken(token) }
    func load() -> String? { KeychainStore.loadToken() }
    func delete() { KeychainStore.deleteToken() }
}
