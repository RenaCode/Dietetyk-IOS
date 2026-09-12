import XCTest
@testable import Dietetyk

/// Jedna nietypowa liczba w odpowiedzi nie może kasować całego ekranu.
///
/// `health_rating` i całe `food_items[]` w `/api/meals` idą PROSTO z odpowiedzi
/// modelu AI - `backend/utils/mealSanitize.js` czyści wyłącznie makro na
/// poziomie posiłku, tych pól nie dotyka wcale. Cele `target_steps`/
/// `target_water_ml` użytkownik wpisuje ręcznie w webowym UI i mogą być
/// ułamkiem. Ponieważ posiłki są zagnieżdżone także w `/api/dashboard`,
/// pojedyncza taka wartość potrafiła zabrać ZARAZEM listę posiłków i Dashboard.
final class LenientNumberDecodingTests: XCTestCase {
    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private func decodeMeals(_ json: String) throws -> [Meal] {
        try decoder().decode([Meal].self, from: Data(json.utf8))
    }

    // MARK: - health_rating (niesanityzowana wartość od modelu AI)

    func testFractionalHealthRatingIsRoundedInsteadOfFailing() throws {
        let meals = try decodeMeals(#"""
        [{"id":1,"date":"2026-09-12","raw_text":"owsianka","calories":420,"health_rating":7.5}]
        """#)

        XCTAssertEqual(meals.count, 1)
        XCTAssertEqual(meals[0].healthRating, 8)
        XCTAssertEqual(meals[0].calories, 420, "reszta posiłku musi przeżyć")
    }

    func testStringHealthRatingIsParsed() throws {
        let meals = try decodeMeals(#"[{"id":1,"health_rating":"8"}]"#)
        XCTAssertEqual(meals[0].healthRating, 8)
    }

    func testUnparsableHealthRatingClearsOnlyThatField() throws {
        let meals = try decodeMeals(#"""
        [{"id":1,"raw_text":"kanapka","calories":300,"health_rating":"bardzo zdrowe"}]
        """#)

        XCTAssertNil(meals[0].healthRating)
        XCTAssertEqual(meals[0].calories, 300)
        XCTAssertEqual(meals[0].rawText, "kanapka")
    }

    func testMissingAndNullHealthRatingDecodeAsNil() throws {
        XCTAssertNil(try decodeMeals(#"[{"id":1}]"#)[0].healthRating)
        XCTAssertNil(try decodeMeals(#"[{"id":1,"health_rating":null}]"#)[0].healthRating)
    }

    /// Jeden felerny posiłek nie może skasować pozostałych z listy.
    func testOneOddMealDoesNotTakeDownTheWholeList() throws {
        let meals = try decodeMeals(#"""
        [{"id":1,"calories":300,"health_rating":6},
         {"id":2,"calories":500,"health_rating":7.5},
         {"id":3,"calories":250,"health_rating":"9"}]
        """#)

        XCTAssertEqual(meals.map(\.id), [1, 2, 3])
        XCTAssertEqual(meals.map(\.healthRating), [6, 8, 9])
    }

    // MARK: - food_items[] (również prosto od modelu AI)

    func testFoodItemNumbersAcceptStringsAndSurviveGarbage() throws {
        let meals = try decodeMeals(#"""
        [{"id":1,"calories":500,"food_items":[
            {"name":"jajko","portion":"2 szt.","calories":"150","protein":"13"},
            {"name":"chleb","portion":"100 g","calories":"250 kcal","protein":8}
        ]}]
        """#)

        let items = try XCTUnwrap(meals[0].foodItems)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].calories, 150, "liczba w stringu ma być odczytana")
        XCTAssertEqual(items[0].protein, 13)
        XCTAssertNil(items[1].calories, "\"250 kcal\" nie jest liczbą - ma zniknąć tylko to pole")
        XCTAssertEqual(items[1].protein, 8, "sąsiednie pole musi przeżyć")
        XCTAssertEqual(meals[0].calories, 500, "posiłek musi przeżyć")
    }

    // MARK: - Cele całkowite z /api/dashboard

    /// Pełna odpowiedź `/api/dashboard` z ułamkowym `target_steps`. Cele
    /// aktywności użytkownik wpisuje ręcznie (`<input type="number">` w webowym
    /// UI), więc `10000.6` da się tam zapisać - a `Int` w Swift odmawia
    /// dekodowania liczby z częścią ułamkową i kasował CAŁY Dashboard.
    func testFractionalIntegerTargetsDoNotBreakDashboard() throws {
        let json = #"""
        {"date":"2026-09-12",
         "summary":{"target_calories":2500,"target_protein":150,"target_carbs":250,"target_fat":80,
           "target_steps":10000.6,"target_active_calories":500,"target_sleep_duration":7.2,
           "target_active_minutes":30,"target_water_ml":2500.4,"bmr":1800,
           "calories_eaten":1200,"calories_burned_active":300,"calories_burned_total":2100,
           "net_calories":-900,"eaten_protein":80,"eaten_carbs":120,"eaten_fat":40,
           "steps":8123,"active_minutes":25,"workouts":[],"last_sync":null,
           "water_ml":1500,"has_oura":false,"has_withings":false},
         "meals":[{"id":1,"raw_text":"owsianka","calories":420,"health_rating":7.5}],
         "aiAdvice":"Pij więcej wody."}
        """#

        let response = try decoder().decode(DashboardResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.summary.targetSteps, 10001)
        XCTAssertEqual(response.summary.targetWaterMl, 2500)
        XCTAssertEqual(response.summary.steps, 8123)
        XCTAssertEqual(response.summary.waterMl, 1500)
        XCTAssertEqual(response.meals.count, 1)
        XCTAssertEqual(response.meals[0].healthRating, 8)
        // Posiłki zagnieżdżone w /api/dashboard NIE mają pola `date` -
        // property wrapper nie może na tym polec.
        XCTAssertNil(response.meals[0].date)
        XCTAssertEqual(response.aiAdvice, "Pij więcej wody.")
    }
}
