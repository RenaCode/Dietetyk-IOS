import Foundation

/// Pojedynczy trening - pole `workouts` w odpowiedzi backendu jest na razie
/// ZAWSZE pustą tablicą (hardcoded w `backend/routes/dashboard.js`), więc ten
/// typ nigdy faktycznie nie jest dekodowany z realnych danych. Zostawiony
/// jako przygotowanie na przyszłość, gdyby backend zaczął zwracać treningi.
struct Workout: Codable, Identifiable, Hashable {
    var id = UUID()
    let type: String?
    let durationMinutes: Double?
    let calories: Double?

    private enum CodingKeys: String, CodingKey {
        case type, durationMinutes, calories
    }
}

/// Podsumowanie dnia z `GET /api/dashboard` - kalorie/makro, aktywność,
/// sen/gotowość (Oura), skład ciała (Withings/Apple Health), nawodnienie.
/// Kształt zweryfikowany 1:1 z `backend/routes/dashboard.js` (`res.json` na
/// końcu handlera) - kolejność pól odpowiada kodowi źródłowemu.
struct DashboardSummary: Decodable {
    // Cele - target_calories/protein/carbs/fat NIE mają fallbacku w backendzie
    // (mogą przyjść jako null, jeśli użytkownik nigdy nie ustawił celów),
    // pozostałe cele (steps/active_calories/sleep_duration/active_minutes/
    // water_ml) oraz bmr mają fallback i są zawsze liczbą.
    let targetCalories: Double?
    let targetProtein: Double?
    let targetCarbs: Double?
    let targetFat: Double?
    @LenientRequiredInt var targetSteps: Int
    let targetActiveCalories: Double
    let targetSleepDuration: Double
    let targetActiveMinutes: Double
    @LenientRequiredInt var targetWaterMl: Int
    let bmr: Double

    // Bilans kaloryczny dnia
    let caloriesEaten: Double
    let caloriesBurnedActive: Double
    let caloriesBurnedTotal: Double
    let netCalories: Double
    let eatenProtein: Double
    let eatenCarbs: Double
    let eatenFat: Double

    // Aktywność
    @LenientRequiredInt var steps: Int
    let activeMinutes: Double
    let workouts: [Workout]
    let lastSync: String?

    // Sen i gotowość (Oura) - null, jeśli brak integracji albo brak
    // jakichkolwiek danych historycznych do dociągnięcia.
    let sleepScore: Double?
    let sleepDuration: Double?
    let sleepDeep: Double?
    let sleepRem: Double?
    let readinessScore: Double?
    let hrv: Double?
    let rhr: Double?
    let temperatureDeviation: Double?

    // Skład ciała (Withings / Apple Health)
    let weight: Double?
    let fatRatio: Double?
    let muscleMass: Double?

    // Nawodnienie - aktualne spożycie dzisiaj (cel to targetWaterMl powyżej).
    // `var`, nie `let`: po `POST /api/water/add|reset` aktualizujemy tę
    // wartość lokalnie z odpowiedzi endpointu, bez ponownego odpytywania
    // całego /api/dashboard (patrz `DashboardViewModel.addWater`).
    @LenientRequiredInt var waterMl: Int

    // Flagi podłączonych integracji
    let hasOura: Bool
    let hasWithings: Bool
}

/// Pełna odpowiedź `GET /api/dashboard?date=YYYY-MM-DD`.
struct DashboardResponse: Decodable {
    let date: String
    var summary: DashboardSummary
    let meals: [Meal]
    let aiAdvice: String?
}
