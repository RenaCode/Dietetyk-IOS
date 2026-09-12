import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    // Cele - jako String, żeby dało się je swobodnie edytować w TextField
    // (puste pole = "nie zmieniaj"/"brak celu"), parsowane na liczby przy zapisie.
    @Published var targetCaloriesText = ""
    @Published var targetProteinText = ""
    @Published var targetCarbsText = ""
    @Published var targetFatText = ""
    @Published var targetWaterMlText = ""

    @Published var serverURLText = APIConfig.baseURL.absoluteString
    @Published var profile: UserProfile?

    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?
    @Published var successMessage: String?

    // MARK: - Synchronizacja Apple Health (HealthKit) - zastępstwo webhooka
    // "Health Auto Export", patrz `HealthSyncService`.
    @Published private(set) var healthSyncEnabled = HealthSyncPreferences.isEnabled
    @Published private(set) var isSyncingHealth = false
    @Published var healthSyncMessage: String?
    @Published private(set) var lastHealthSyncDate: Date? = HealthSyncPreferences.lastSyncDate

    var isHealthDataAvailable: Bool {
        HealthKitManager.shared.isHealthDataAvailable
    }

    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let settings = APIClient.shared.fetchSettings()
            async let fetchedProfile = APIClient.shared.fetchProfile()
            apply(try await settings)
            profile = try await fetchedProfile
        } catch APIError.unauthorized {
            appState.requireReauth()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func apply(_ settings: UserSettings) {
        targetCaloriesText = settings.targetCalories.map { String(Int($0)) } ?? ""
        targetProteinText = settings.targetProtein.map(formatted) ?? ""
        targetCarbsText = settings.targetCarbs.map(formatted) ?? ""
        targetFatText = settings.targetFat.map(formatted) ?? ""
        targetWaterMlText = settings.targetWaterMl.map { String(Int($0)) } ?? ""
    }

    private func formatted(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    func saveGoals() async {
        isSaving = true
        errorMessage = nil
        successMessage = nil
        defer { isSaving = false }

        let request = UpdateSettingsRequest(
            targetCalories: Int(targetCaloriesText),
            targetProtein: Double(targetProteinText.replacingOccurrences(of: ",", with: ".")),
            targetCarbs: Double(targetCarbsText.replacingOccurrences(of: ",", with: ".")),
            targetFat: Double(targetFatText.replacingOccurrences(of: ",", with: ".")),
            targetWaterMl: Int(targetWaterMlText)
        )

        do {
            try await APIClient.shared.updateSettings(request)
            successMessage = "Cele zapisane."
        } catch APIError.unauthorized {
            appState.requireReauth()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Zwraca `false`, jeśli wpisany adres nie jest poprawnym URL-em -
    /// widok wtedy pokazuje błąd i nie zamyka edycji.
    ///
    /// Zmiana adresu WYLOGOWUJE. Token sesji z Keychain jest wystawiony przez
    /// konkretny backend i `APIClient` dokleja go jako `Authorization: Bearer`
    /// do KAŻDEGO żądania pod aktualny `APIConfig.baseURL`. Bez tego czyszczenia
    /// wystarczyło namówić użytkownika na wpisanie cudzego adresu w Ustawieniach,
    /// żeby apka sama wysłała żywy token sesji produkcyjnego konta na obcy host
    /// (pierwszym żądaniem po zmianie - np. automatycznym `/api/settings` przy
    /// synchronizacji Apple Health).
    @discardableResult
    func saveServerURL() -> Bool {
        let previousURL = APIConfig.baseURL
        guard APIConfig.setBaseURLString(serverURLText) else {
            errorMessage = "Nieprawidłowy adres serwera. Podaj pełny adres https, np. https://moj-serwer.pl"
            return false
        }
        if APIConfig.baseURL != previousURL {
            // Wraca na ekran logowania - token poprzedniego serwera jest tu bezużyteczny.
            appState.requireReauth()
            return true
        }
        successMessage = "Adres serwera zapisany."
        return true
    }

    func resetServerURL() {
        let previousURL = APIConfig.baseURL
        APIConfig.resetToDefault()
        serverURLText = APIConfig.baseURL.absoluteString
        // Powrót na domyślny backend to też zmiana serwera - patrz `saveServerURL`.
        if APIConfig.baseURL != previousURL {
            appState.requireReauth()
        }
    }

    func logout() {
        appState.logout()
    }

    // MARK: - Synchronizacja Apple Health

    /// Wołane przełącznikiem w UI. Wyłączenie jest natychmiastowe i nie
    /// wymaga sieci; włączenie wymaga zgody systemowej (HealthKit) i
    /// pierwszej synchronizacji, więc dzieje się asynchronicznie - w razie
    /// błędu przełącznik wraca do stanu wyłączonego.
    func setHealthSyncEnabled(_ enabled: Bool) {
        healthSyncEnabled = enabled
        HealthSyncPreferences.isEnabled = enabled
        healthSyncMessage = nil
        guard enabled else { return }
        Task { await enableHealthSync() }
    }

    private func enableHealthSync() async {
        do {
            try await HealthKitManager.shared.requestAuthorization()
            await HealthSyncService.shared.startObservingIfEnabled()
            await syncHealthNow()
        } catch {
            healthSyncEnabled = false
            HealthSyncPreferences.isEnabled = false
            healthSyncMessage = "Nie udało się włączyć synchronizacji: \(error.localizedDescription)"
        }
    }

    func syncHealthNow() async {
        guard healthSyncEnabled else { return }
        isSyncingHealth = true
        healthSyncMessage = nil
        defer { isSyncingHealth = false }
        do {
            let count = try await HealthSyncService.shared.syncNow()
            lastHealthSyncDate = HealthSyncPreferences.lastSyncDate
            healthSyncMessage = count > 0
                ? "Zsynchronizowano (\(count) wpisów)."
                : "Zsynchronizowano - brak nowych danych do wysłania."
        } catch {
            healthSyncMessage = "Błąd synchronizacji: \(error.localizedDescription)"
        }
    }
}
