import Foundation

/// Pojedynczy zidentyfikowany składnik posiłku (z analizy AI).
/// UWAGA: całe `food_items[]` idzie PROSTO z odpowiedzi modelu AI - backend
/// sanityzuje (`utils/mealSanitize.js`) tylko makro NA POZIOMIE POSIŁKU, nie
/// poszczególne składniki. Model potrafi oddać `"15"` albo `"15 g"` zamiast
/// liczby, a jeden taki składnik wywaliłby dekodowanie CAŁEJ listy posiłków -
/// stąd `@LenientDouble`, patrz `Networking/LenientNumbers.swift`.
struct FoodItem: Codable, Identifiable, Hashable {
    var id = UUID()
    let name: String?
    let portion: String?
    @LenientDouble var calories: Double?
    @LenientDouble var protein: Double?
    @LenientDouble var carbs: Double?
    @LenientDouble var fat: Double?

    // `id` jest lokalny (UUID), nie przychodzi z backendu - wykluczony z
    // CodingKeys, więc Decodable użyje wartości domyślnej z deklaracji
    // powyżej. Pozostałe case'y bez własnej wartości String wciąż korzystają
    // z globalnej strategii `.convertFromSnakeCase` na `JSONDecoder`.
    private enum CodingKeys: String, CodingKey {
        case name, portion, calories, protein, carbs, fat
    }
}

/// Posiłek - zarówno wpis z listy (`GET /api/meals`), jak i element zwrócony
/// po dodaniu (`POST /api/meals` -> `meals: [Meal]`, patrz `AddMealResponse`).
struct Meal: Codable, Identifiable, Hashable {
    let id: Int
    // `date` jest obecne we wpisach z `GET /api/meals`, ale NIE we wpisach
    // zagnieżdżonych w `GET /api/dashboard` (tam mapowanie pomija to pole,
    // patrz `backend/routes/dashboard.js`) - stąd opcjonalne, nie required.
    let date: String?
    let timestamp: String?
    let rawText: String?
    let imageBase64: String?
    let calories: Double?
    let protein: Double?
    let carbs: Double?
    let fat: Double?
    let foodItems: [FoodItem]?
    let dieticianComment: String?
    // Prompt prosi model o liczbę całkowitą 1-10, ale `health_rating` jako
    // JEDYNE pole analizy NIE przechodzi przez `sanitizeNumber` w
    // `backend/routes/meals.js` - do odpowiedzi trafia dokładnie to, co oddał
    // model. `7.5` albo `"8"` wywalało dekodowanie całej listy posiłków, a
    // ponieważ posiłki są zagnieżdżone w `/api/dashboard`, razem z nią ginął
    // też Dashboard.
    @LenientInt var healthRating: Int?
    // Tylko w odpowiedzi POST /api/meals przy rozpoznaniu zdjęcia z wieloma
    // sekcjami (np. "Śniadanie"/"Obiad"/"Kolacja") - brak w GET /api/meals.
    let name: String?
}

/// Żądanie dodania posiłku. `image` to pełny data URL base64
/// (`data:image/jpeg;base64,...`), zgodnie z tym, czego oczekuje
/// `backend/routes/meals.js`. `rawText` lub `image` musi być obecne.
struct AddMealRequest: Encodable {
    let rawText: String?
    let date: String?
    let image: String?
}

/// Odpowiedź na dodanie posiłku - jedno zdjęcie może wygenerować wiele
/// pozycji (np. zrzut ekranu z podziałem na Śniadanie/Obiad/Kolację),
/// dlatego backend zawsze zwraca tablicę, nawet dla wpisu tekstowego.
struct AddMealResponse: Decodable {
    let count: Int
    let meals: [Meal]
}
