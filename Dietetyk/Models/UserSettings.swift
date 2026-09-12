import Foundation

/// `GET /api/settings` zwraca PŁASKI, dynamiczny obiekt - dosłownie wszystkie
/// wiersze z tabeli `settings` (key/value) tego użytkownika, plus `sync_token`
/// z tabeli `users`. Backend nie ma stałego kontraktu (klucze zależą od tego,
/// co użytkownik kiedykolwiek zapisał - może zawierać też klucze integracji
/// jak `oura_client_id`, zamaskowane sekrety jak `gemini_api_key: "********"`
/// itd.). Modelujemy tu tylko pola istotne dla tej apki (cele + token synchro
/// Apple Health) - dekodowanie po prostu ignoruje resztę kluczy.
///
/// UWAGA na TYPY: wartości w tabeli `settings` są trzymane jako tekst, a
/// backend zgaduje typ przy odczycie (`isNaN(r.value) ? r.value : Number(r.value)`
/// w `backend/routes/account.js`). Cel, który użytkownik WYCZYŚCIŁ w webowym
/// UI, jest tam zapisany jako pusty string i - świadomie, patrz komentarz przy
/// `r.value === ''` w tym samym pliku - wraca z API jako `""`, a NIE jako
/// `null` ani brak klucza. Syntezowane `Decodable` przewracało się wtedy na
/// `typeMismatch` i - ponieważ błąd dekodowania wywala CAŁY obiekt, nie jedno
/// pole - zabierało ze sobą ekran Ustawień ORAZ synchronizację Apple Health
/// (`HealthSyncService.syncNow()` zaczyna od `fetchSettings()`, żeby pobrać
/// `sync_token`). Dlatego dekodujemy tu ręcznie i tolerancyjnie: liczba,
/// liczba w stringu i pusty string/`null`/brak klucza są poprawnymi
/// wejściami, a nieoczekiwany typ daje `nil` w JEDNYM polu zamiast błędu
/// całego żądania.
struct UserSettings: Decodable {
    let targetCalories: Double?
    let targetProtein: Double?
    let targetCarbs: Double?
    let targetFat: Double?
    let targetWaterMl: Double?
    /// Tylko do odczytu - używany w adresie webhooka Apple Health
    /// (`backend/routes/appleHealth.js`), nigdy nie wysyłany z powrotem
    /// w żądaniu zapisu (patrz `UpdateSettingsRequest`).
    let syncToken: String?

    // Nazwy case'ów (a nie ich wartości String) są celowo w camelCase -
    // `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase` w `APIClient`
    // przerabia klucz JSON `target_calories` na `targetCalories` ZANIM
    // szuka go wśród CodingKeys. To ten sam mechanizm, z którego korzystało
    // wcześniejsze, syntezowane `Decodable`.
    private enum CodingKeys: String, CodingKey {
        case targetCalories, targetProtein, targetCarbs, targetFat, targetWaterMl, syncToken
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        targetCalories = Self.number(container, .targetCalories)
        targetProtein = Self.number(container, .targetProtein)
        targetCarbs = Self.number(container, .targetCarbs)
        targetFat = Self.number(container, .targetFat)
        targetWaterMl = Self.number(container, .targetWaterMl)
        syncToken = Self.string(container, .syncToken)
    }

    /// Liczba z pola, które backend może oddać jako liczbę, jako liczbę
    /// w stringu ("2500"), jako pusty string (cel wyczyszczony) albo wcale.
    private static func number(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
        guard container.contains(key), (try? container.decodeNil(forKey: key)) == false else { return nil }
        if let value = try? container.decode(Double.self, forKey: key) { return value }
        guard let raw = try? container.decode(String.self, forKey: key) else { return nil }
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        return normalized.isEmpty ? nil : Double(normalized)
    }

    /// `sync_token` idzie prosto z kolumny `users.sync_token`, więc w praktyce
    /// zawsze jest stringiem - ale gdyby kiedyś nie był, ma zniknąć tylko to
    /// jedno pole. `HealthSyncService` zgłasza wtedy czytelne
    /// `HealthSyncError.missingSyncToken` zamiast zdechnąć na dekodowaniu.
    private static func string(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        guard container.contains(key), (try? container.decodeNil(forKey: key)) == false else { return nil }
        return try? container.decode(String.self, forKey: key)
    }
}

/// Payload zapisu ustawień (`POST /api/settings`). Backend iteruje WSZYSTKIE
/// klucze przesłanego obiektu i nadpisuje nimi wiersze w tabeli `settings` -
/// więc wysyłamy tylko pola faktycznie zmieniane. Dzięki synteyzowanemu przez
/// kompilator `Encodable` (które dla `Optional` używa `encodeIfPresent`),
/// pola `nil` są w całości POMIJANE w wynikowym JSON-ie, a nie wysyłane jako
/// `null` - co jest kluczowe, bo backend zapisuje `null` jako literalny string
/// `"null"` (zobacz `String(val)` w `backend/routes/account.js`), co
/// skorumpowałoby ustawienie. Klucze JSON muszą być snake_case - w tym
/// jednym miejscu backend NIE używa camelCase (w przeciwieństwie do
/// auth.js/meals.js).
struct UpdateSettingsRequest: Encodable {
    var targetCalories: Int?
    var targetProtein: Double?
    var targetCarbs: Double?
    var targetFat: Double?
    var targetWaterMl: Int?

    private enum CodingKeys: String, CodingKey {
        case targetCalories = "target_calories"
        case targetProtein = "target_protein"
        case targetCarbs = "target_carbs"
        case targetFat = "target_fat"
        case targetWaterMl = "target_water_ml"
    }
}

/// Profil użytkownika z `GET /api/user/profile` (kształt jawnie zbudowany w
/// `backend/routes/account.js`, snake_case na każdym polu).
struct UserProfile: Decodable {
    let username: String
    let email: String?
    let avatarBase64: String?
    let role: String?
    let totpEnabled: Bool?
    let hasOura: Bool?
    let hasWithings: Bool?
}

/// Pojedynczy wpis z `GET /api/health/history` (90 dni metryk - na potrzeby
/// przyszłego ekranu Trends, na razie bez UI, patrz README). Kolumny 1:1 z
/// `SELECT` w `backend/routes/health.js`.
struct HealthHistoryEntry: Decodable, Identifiable {
    var id: String { date }
    let date: String
    let weight: Double?
    let fatRatio: Double?
    let muscleMass: Double?
    let sleepScore: Double?
    let sleepDuration: Double?
    let readinessScore: Double?
    let steps: Int?
    let activeCalories: Double?
    let totalCaloriesBurned: Double?
    let rhr: Double?
    let hrv: Double?
    let activeMinutes: Double?
}

/// `POST /api/water/add` - body wymaga DOKŁADNIE `amount_ml` (snake_case,
/// `backend/routes/health.js`), stąd jawne `CodingKeys`.
struct WaterAddRequest: Encodable {
    let date: String
    let amountMl: Int

    private enum CodingKeys: String, CodingKey {
        case date
        case amountMl = "amount_ml"
    }
}

struct WaterResetRequest: Encodable {
    let date: String
}

/// Odpowiedź obu endpointów wody - zawiera zaktualizowaną wartość licznika,
/// żeby UI mogło się odświeżyć bez kolejnego round-tripu do `/api/dashboard`.
struct WaterResponse: Decodable {
    let success: Bool?
    let waterMl: Int?
}

/// Generyczna odpowiedź sukcesu (`{"success": true, "message": "..."}`),
/// używana przez endpointy, gdzie nie potrzebujemy nic poza potwierdzeniem
/// (np. usunięcie posiłku).
struct SuccessResponse: Decodable {
    let success: Bool?
    let message: String?
}
