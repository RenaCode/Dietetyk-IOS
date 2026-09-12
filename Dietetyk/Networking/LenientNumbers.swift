import Foundation

/// Tolerancyjne dekodowanie liczb z odpowiedzi backendu.
///
/// PO CO: błąd dekodowania w Swift wywala CAŁY obiekt, a nie jedno pole. Przy
/// `[Meal]` albo `DashboardResponse` oznacza to, że jedna nietypowa wartość
/// kasuje cały ekran - użytkownik dostaje "Nie udało się odczytać odpowiedzi
/// serwera" i pustkę, mimo że reszta danych jest w porządku.
///
/// A backend NIE gwarantuje typów liczbowych w kilku miejscach:
///
/// - `health_rating` oraz całe `food_items[]` w odpowiedzi `/api/meals`
///   pochodzą PROSTO z odpowiedzi modelu AI (`analysis_json` rozpakowany przez
///   `...analysis` w `backend/routes/meals.js`). Sanityzacja
///   (`utils/mealSanitize.js`) obejmuje wyłącznie calories/protein/carbs/fat/
///   fiber/sugar/sodium NA POZIOMIE POSIŁKU - `health_rating` i pozycje
///   `food_items` nie przechodzą przez nią wcale. Prompt prosi o liczbę
///   całkowitą, ale model potrafi oddać `7.5`, `"8"` albo `"15 g"`.
/// - cele liczbowe z tabeli `settings` trafiają tam przez `String(val)` i wracają
///   przez `Number(r.value)` - użytkownik może wpisać `10000.5` w polu
///   "Kroki" w webowym UI i dostać ułamek tam, gdzie iOS oczekuje `Int`.
///
/// Dlatego liczby z tych pól czytamy przez poniższe wrappery: akceptują liczbę,
/// liczbę w stringu, pusty string, `null` i brak klucza, a wartość, której nie
/// da się zinterpretować, kasują w JEDNYM polu zamiast wywracać całą odpowiedź.
enum LenientNumber {
    /// Liczba z pola, które może przyjść jako liczba, liczba w stringu,
    /// pusty string albo `null`.
    static func double(from decoder: Decoder) throws -> Double? {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { return nil }
        if let value = try? container.decode(Double.self) { return value }
        guard let text = try? container.decode(String.self) else { return nil }
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        return normalized.isEmpty ? nil : Double(normalized)
    }

    /// `Int(_:)` z `Double` PUŁAPKUJE (crash) przy NaN, nieskończoności i przy
    /// wartości spoza zakresu `Int` - a tu dekodujemy dane z sieci, więc
    /// zakres wejścia nie jest niczym ograniczony.
    static func clampedInt(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        let rounded = value.rounded()
        if rounded >= Double(Int.max) { return .max }
        if rounded <= Double(Int.min) { return .min }
        return Int(rounded)
    }
}

/// `Double?`, które nie wywraca całej odpowiedzi na nieoczekiwanym typie.
@propertyWrapper
struct LenientDouble: Codable, Hashable {
    var wrappedValue: Double?

    init(wrappedValue: Double?) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        wrappedValue = try LenientNumber.double(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

/// `Int?` z pola, które backend deklaruje jako całkowite, ale bywa ułamkiem
/// albo stringiem (np. `health_rating` prosto od modelu AI).
@propertyWrapper
struct LenientInt: Codable, Hashable {
    var wrappedValue: Int?

    init(wrappedValue: Int?) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        wrappedValue = try LenientNumber.double(from: decoder).map(LenientNumber.clampedInt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

/// Nieopcjonalny `Int` - dla pól, które backend ZAWSZE wysyła (ma dla nich
/// wartość domyślną po swojej stronie), ale nie gwarantuje, że będą całkowite.
/// Brak klucza/`null`/śmieci dają `0`, czyli to samo, co backendowe `|| 0`.
@propertyWrapper
struct LenientRequiredInt: Decodable, Hashable {
    var wrappedValue: Int

    init(wrappedValue: Int) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        wrappedValue = try LenientNumber.double(from: decoder).map(LenientNumber.clampedInt) ?? 0
    }
}

// Syntezowane `Decodable` dla property wrappera woła `decode(_:forKey:)`, które
// RZUCA przy brakującym kluczu - nawet gdy opakowana wartość jest opcjonalna.
// Bez tych przeciążeń pole nieobecne w odpowiedzi (np. `date`, którego nie ma
// w posiłkach zagnieżdżonych w `/api/dashboard`) znów wywalałoby całe
// dekodowanie - czyli dokładnie to, czemu te wrappery mają zapobiegać.
extension KeyedDecodingContainer {
    func decode(_ type: LenientDouble.Type, forKey key: Key) throws -> LenientDouble {
        try decodeIfPresent(type, forKey: key) ?? LenientDouble(wrappedValue: nil)
    }

    func decode(_ type: LenientInt.Type, forKey key: Key) throws -> LenientInt {
        try decodeIfPresent(type, forKey: key) ?? LenientInt(wrappedValue: nil)
    }

    func decode(_ type: LenientRequiredInt.Type, forKey key: Key) throws -> LenientRequiredInt {
        try decodeIfPresent(type, forKey: key) ?? LenientRequiredInt(wrappedValue: 0)
    }
}
