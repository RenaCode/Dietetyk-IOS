import XCTest
@testable import Dietetyk

/// `GET /api/settings` nie ma sztywnego kontraktu typów: wartości siedzą w
/// tabeli key/value jako tekst, a backend zgaduje typ przy odczycie
/// (`isNaN(r.value) ? r.value : Number(r.value)` w `backend/routes/account.js`).
/// Cel WYCZYSZCZONY w webowym UI jest zapisany jako pusty string i wraca z API
/// jako `""` - nie jako `null`.
///
/// Błąd dekodowania w Swift wywala CAŁY obiekt, nie jedno pole, więc jeden taki
/// `""` zabierał ze sobą ekran Ustawień ORAZ synchronizację Apple Health
/// (`HealthSyncService.syncNow()` startuje od `fetchSettings()`, żeby dostać
/// `sync_token`). Te testy pilnują, że żaden wariant wartości, jaki backend
/// realnie potrafi zwrócić, nie przewraca dekodowania.
final class UserSettingsDecodingTests: XCTestCase {
    /// Ten sam decoder co w `APIClient` - bez `.convertFromSnakeCase` żaden
    /// z kluczy `target_*` by się nie odnalazł.
    private func decode(_ json: String) throws -> UserSettings {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(UserSettings.self, from: Data(json.utf8))
    }

    func testDecodesPlainNumericTargets() throws {
        let settings = try decode(#"""
        {"sync_token":"abc123","target_calories":2500,"target_protein":150,
         "target_carbs":250,"target_fat":80,"target_water_ml":2500}
        """#)

        XCTAssertEqual(settings.targetCalories, 2500)
        XCTAssertEqual(settings.targetProtein, 150)
        XCTAssertEqual(settings.targetCarbs, 250)
        XCTAssertEqual(settings.targetFat, 80)
        XCTAssertEqual(settings.targetWaterMl, 2500)
        XCTAssertEqual(settings.syncToken, "abc123")
    }

    /// REGRESJA: cel wyczyszczony w webowym UI wraca jako `""`.
    /// `frontend/src/components/Settings.jsx` (`value === '' ? '' : Number(value)`)
    /// wysyła pusty string, `backend/routes/account.js` zapisuje go przez
    /// `String(val)` i celowo oddaje z powrotem jako `''`.
    /// Przed poprawką leciało tu `DecodingError.typeMismatch` i CAŁE
    /// `/api/settings` było nie do odczytania.
    func testEmptyStringTargetDecodesAsNilInsteadOfFailingWholeObject() throws {
        let settings = try decode(#"""
        {"sync_token":"abc123","target_calories":"","target_protein":150,
         "target_carbs":250,"target_fat":80,"target_water_ml":2500}
        """#)

        XCTAssertNil(settings.targetCalories, "pusty cel ma dać nil, a nie wysadzić dekodowanie")
        // Reszta obiektu MUSI przeżyć - to jest sedno tej regresji.
        XCTAssertEqual(settings.targetProtein, 150)
        XCTAssertEqual(settings.syncToken, "abc123", "sync_token przepada => ginie synchronizacja Apple Health")
    }

    /// Wszystkie cele naraz puste - stan po wyczyszczeniu całego formularza.
    func testAllTargetsEmptyStillKeepsSyncToken() throws {
        let settings = try decode(#"""
        {"sync_token":"tok","target_calories":"","target_protein":"",
         "target_carbs":"","target_fat":"","target_water_ml":""}
        """#)

        XCTAssertNil(settings.targetCalories)
        XCTAssertNil(settings.targetProtein)
        XCTAssertNil(settings.targetCarbs)
        XCTAssertNil(settings.targetFat)
        XCTAssertNil(settings.targetWaterMl)
        XCTAssertEqual(settings.syncToken, "tok")
    }

    /// Backend oddaje liczbę jako string, jeśli `isNaN()` uzna wartość za
    /// nieliczbową - a także wtedy, gdy wiersz powstał inną drogą niż
    /// formularz. Liczba w stringu ma być odczytana jako liczba.
    func testNumericStringTargetIsParsed() throws {
        let settings = try decode(#"{"target_calories":"2200","target_protein":"120.5"}"#)

        XCTAssertEqual(settings.targetCalories, 2200)
        XCTAssertEqual(settings.targetProtein, 120.5)
    }

    /// Cel nigdy nie ustawiony = brak wiersza w tabeli = brak klucza w JSON.
    /// Osobno: jawny `null`.
    func testMissingAndNullTargetsDecodeAsNil() throws {
        let missing = try decode(#"{"sync_token":"abc"}"#)
        XCTAssertNil(missing.targetCalories)
        XCTAssertNil(missing.targetWaterMl)
        XCTAssertEqual(missing.syncToken, "abc")

        let explicitNull = try decode(#"{"sync_token":null,"target_calories":null}"#)
        XCTAssertNil(explicitNull.targetCalories)
        XCTAssertNil(explicitNull.syncToken)
    }

    /// `/api/settings` to płaski zrzut CAŁEJ tabeli ustawień - lecą tam też
    /// klucze integracji i zamaskowane sekrety. Nadmiarowe klucze (w tym
    /// zagnieżdżone obiekty) nie mogą przeszkadzać.
    func testIgnoresUnrelatedKeysIncludingMaskedSecrets() throws {
        let settings = try decode(#"""
        {"sync_token":"abc","gemini_api_key":"********","oura_client_id":"",
         "weather_location_label":"Warszawa","target_calories":1800,
         "some_future_object":{"a":1}}
        """#)

        XCTAssertEqual(settings.targetCalories, 1800)
        XCTAssertEqual(settings.syncToken, "abc")
    }

    /// Nieoczekiwany typ ma skasować JEDNO pole, nie całą odpowiedź -
    /// inaczej wracamy dokładnie do naprawianej tu awarii.
    func testUnexpectedTypeDegradesSingleFieldOnly() throws {
        let settings = try decode(#"{"sync_token":"abc","target_calories":{"nested":1},"target_protein":150}"#)

        XCTAssertNil(settings.targetCalories)
        XCTAssertEqual(settings.targetProtein, 150)
        XCTAssertEqual(settings.syncToken, "abc")
    }
}
