import Foundation

/// Globalny stan autoryzacji, współdzielony przez całą apkę przez
/// `@EnvironmentObject`. Token sesji żyje w Keychain (patrz `KeychainStore`)
/// - ten obiekt tylko odzwierciedla, czy token istnieje, żeby `RootView`
/// mógł przełączać się między ekranem logowania i resztą apki.
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var isAuthenticated: Bool

    /// Wstrzykiwalne, żeby testy mogły sprawdzić logikę sesji bez Keychain -
    /// patrz `SessionTokenStore`. Produkcyjnie zawsze Keychain.
    private let tokenStore: SessionTokenStore

    init(tokenStore: SessionTokenStore = KeychainSessionTokenStore()) {
        self.tokenStore = tokenStore
        // Auto-login: jeśli w Keychain jest token z poprzedniej sesji,
        // zakładamy że jest wciąż ważny - dopiero pierwsze żądanie do
        // backendu faktycznie to zweryfikuje. 401 wywoła `requireReauth()`
        // i wróci do ekranu logowania.
        self.isAuthenticated = tokenStore.load() != nil
    }

    /// Rzuca, gdy tokenu NIE udało się zapisać. Wcześniej wynik zapisu był
    /// ignorowany i apka przechodziła na ekran główny z pustym Keychainem -
    /// każde żądanie wracało wtedy z 401, a użytkownik widział "Sesja
    /// wygasła" tuż po poprawnym zalogowaniu, bez żadnej wskazówki dlaczego.
    func markAuthenticated(token: String) throws {
        guard tokenStore.save(token) else {
            throw AppStateError.tokenStorageFailed
        }
        isAuthenticated = true
    }

    /// Świadome wylogowanie przez użytkownika (przycisk w Ustawieniach).
    func logout() {
        Task {
            try? await APIClient.shared.logout()
        }
        tokenStore.delete()
        isAuthenticated = false
    }

    /// Wołane przez ViewModel-e, gdy żądanie zwróci `APIError.unauthorized`
    /// (token wygasł/został unieważniony po stronie backendu) - czyści
    /// lokalny token i wraca do ekranu logowania bez dodatkowego wołania
    /// `/api/logout` (token i tak już nie działa).
    func requireReauth() {
        tokenStore.delete()
        isAuthenticated = false
    }
}

enum AppStateError: LocalizedError {
    case tokenStorageFailed

    var errorDescription: String? {
        switch self {
        case .tokenStorageFailed:
            return "Nie udało się bezpiecznie zapisać sesji na urządzeniu. Spróbuj zalogować się ponownie."
        }
    }
}
