import Foundation
import HealthKit

/// Odpowiada za faktyczną synchronizację: czyta dane z HealthKit (przez
/// `HealthKitManager`) i wysyła je do TEGO SAMEGO endpointu, który dotąd
/// przyjmował payloady z apki "Health Auto Export"
/// (`POST /api/integrations/apple-health/:syncToken`,
/// `backend/routes/appleHealth.js`) - backend nie wymaga żadnych zmian,
/// liczy się tylko kształt JSON-a (`HealthExportPayload`).
///
/// `actor`, bo zapytania do HealthKit i sieci mogą być wywoływane
/// równolegle (manualny "Synchronizuj teraz" w Ustawieniach + automatyczny
/// `HKObserverQuery` w tle) - actor serializuje te wywołania, żeby nie
/// wysyłać dwóch nakładających się payloadów naraz.
actor HealthSyncService {
    static let shared = HealthSyncService()

    private let manager = HealthKitManager.shared
    private var isObserving = false

    /// Ile dni wstecz synchronizujemy przy każdym przebiegu - wystarczająco
    /// dużo, żeby nadrobić zaległości po kilku dniach offline, a jednocześnie
    /// mało, żeby zapytanie było szybkie. Bezpieczne do powtarzania - backend
    /// i tak nadpisuje te same dni idempotentnie (COALESCE per kolumna w
    /// `appleHealth.js`).
    private let syncWindowDays = 14

    private struct MetricSpec {
        let identifier: HKQuantityTypeIdentifier
        /// Nazwa zgodna z `METRIC_FIELD_MAP` w `appleHealth.js`.
        let name: String
        let unitsLabel: String
        let unit: HKUnit
        let options: HKStatisticsOptions
    }

    private static let metricSpecs: [MetricSpec] = {
        var specs: [MetricSpec] = [
            MetricSpec(identifier: .stepCount, name: "step_count", unitsLabel: "count", unit: .count(), options: .cumulativeSum),
            MetricSpec(identifier: .activeEnergyBurned, name: "active_energy", unitsLabel: "kcal", unit: .kilocalorie(), options: .cumulativeSum),
            MetricSpec(identifier: .basalEnergyBurned, name: "basal_energy_burned", unitsLabel: "kcal", unit: .kilocalorie(), options: .cumulativeSum),
            MetricSpec(identifier: .appleExerciseTime, name: "apple_exercise_time", unitsLabel: "min", unit: .minute(), options: .cumulativeSum),
            MetricSpec(identifier: .distanceWalkingRunning, name: "walking_running_distance", unitsLabel: "m", unit: .meter(), options: .cumulativeSum)
        ]
        if #available(iOS 16.0, *) {
            specs.append(
                MetricSpec(identifier: .appleSleepingWristTemperature, name: "wrist_temperature", unitsLabel: "degC", unit: .degreeCelsius(), options: .discreteMostRecent)
            )
        }
        return specs
    }()

    // Poniższe trzy pomocnicze funkcje/wartości są celowo "internal" (nie
    // "private") - to czysta logika (formatowanie dat, mapowanie nazw
    // treningów) bez zależności od żywego HealthKit/sieci, więc warto ją
    // pokryć testami jednostkowymi (DietetykTests, `@testable import
    // Dietetyk`). Nadal nie są częścią publicznego API modułu.
    static let exportDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter
    }()

    /// Główne wejście - czyta HealthKit i wysyła do backendu. Zwraca liczbę
    /// wysłanych "wpisów" (metryki + treningi), tylko do pokazania w UI.
    @discardableResult
    func syncNow() async throws -> Int {
        guard manager.isHealthDataAvailable else { throw HealthSyncError.unavailable }

        let settings = try await APIClient.shared.fetchSettings()
        guard let token = settings.syncToken, !token.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw HealthSyncError.missingSyncToken
        }

        let calendar = Calendar.current
        let end = Date()
        let startOfToday = calendar.startOfDay(for: end)
        guard let start = calendar.date(byAdding: .day, value: -syncWindowDays, to: startOfToday) else {
            throw HealthSyncError.unavailable
        }

        var data = HealthExportData()

        for spec in Self.metricSpecs {
            guard let type = manager.quantityType(spec.identifier) else { continue }
            let points = try await dailyStatistics(for: type, options: spec.options, start: start, end: end)
            guard !points.isEmpty else { continue }
            let metricPoints = points.map { entry in
                HealthExportMetricPoint(
                    date: Self.exportDateString(forDay: entry.date),
                    qty: entry.quantity.doubleValue(for: spec.unit)
                )
            }
            data.metrics.append(HealthExportMetric(name: spec.name, units: spec.unitsLabel, data: metricPoints))
        }

        let workouts = try await fetchWorkouts(start: start, end: end)
        data.workouts = workouts.map(Self.makeExportWorkout)

        // "Ostatnia synchronizacja" stemplujemy WYŁĄCZNIE po udanym wysłaniu.
        // Wcześniej stał tu `defer`, który wykonuje się także przy rzuceniu
        // błędu - więc nieudany upload (brak sieci, 401, błąd serwera) i tak
        // ustawiał znacznik na "teraz". W Ustawieniach wyglądało to na świeżą,
        // udaną synchronizację, a w tle (`syncIfEnabled` oraz handler
        // `HKObserverQuery` - oba połykają błąd przez `try?`) nie było ŻADNEGO
        // innego sygnału, że dane od dni nie docierają do backendu.
        guard !data.metrics.isEmpty || !data.workouts.isEmpty else {
            // Brak nowych danych to poprawny wynik synchronizacji, nie błąd.
            HealthSyncPreferences.lastSyncDate = Date()
            return 0
        }

        let request = HealthExportPayload(data: data)
        _ = try await APIClient.shared.syncAppleHealth(syncToken: token, payload: request)
        HealthSyncPreferences.lastSyncDate = Date()

        return data.metrics.reduce(0) { $0 + $1.data.count } + data.workouts.count
    }

    /// Wołane przy starcie apki i powrocie z tła - synchronizuje tylko,
    /// jeśli użytkownik wcześniej włączył to w Ustawieniach.
    func syncIfEnabled() async {
        guard HealthSyncPreferences.isEnabled else { return }
        _ = try? await syncNow()
    }

    /// Rejestruje `HKObserverQuery` + `enableBackgroundDelivery` dla metryk
    /// kumulatywnych, żeby HealthKit sam wzbudzał synchronizację, gdy
    /// przybędą nowe dane - to jest mechanizm zastępujący webhook (ten
    /// dotąd uruchamiał się tylko wtedy, gdy zewnętrzna apka "Health Auto
    /// Export" sama wysłała żądanie w tle).
    func startObservingIfEnabled() async {
        guard HealthSyncPreferences.isEnabled, manager.isHealthDataAvailable, !isObserving else { return }
        isObserving = true

        let identifiers: [HKQuantityTypeIdentifier] = [.stepCount, .activeEnergyBurned, .basalEnergyBurned, .appleExerciseTime, .distanceWalkingRunning]
        for identifier in identifiers {
            guard let type = manager.quantityType(identifier) else { continue }
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completionHandler, _ in
                Task { [weak self] in
                    _ = try? await self?.syncNow()
                    completionHandler()
                }
            }
            manager.store.execute(query)
            manager.store.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
        }
    }

    func stopObserving() {
        // HKObserverQuery nie ma pojedynczego "stop all" - wyłączenie
        // synchronizacji w Ustawieniach po prostu przestaje wywoływać
        // `syncIfEnabled()`; same zapytania obserwujące są tanie i
        // nieszkodliwe, jeśli zostaną aktywne do końca życia procesu.
        isObserving = false
    }

    // MARK: - HealthKit queries

    private func dailyStatistics(
        for type: HKQuantityType,
        options: HKStatisticsOptions,
        start: Date,
        end: Date
    ) async throws -> [(date: Date, quantity: HKQuantity)] {
        try await withCheckedThrowingContinuation { continuation in
            let calendar = Calendar.current
            let anchor = calendar.startOfDay(for: end)
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: options,
                anchorDate: anchor,
                intervalComponents: DateComponents(day: 1)
            )
            query.initialResultsHandler = { _, collection, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                var results: [(Date, HKQuantity)] = []
                collection?.enumerateStatistics(from: start, to: end) { stats, _ in
                    let quantity = options.contains(.cumulativeSum) ? stats.sumQuantity() : stats.mostRecentQuantity()
                    if let quantity {
                        results.append((stats.startDate, quantity))
                    }
                }
                continuation.resume(returning: results)
            }
            manager.store.execute(query)
        }
    }

    private func fetchWorkouts(start: Date, end: Date) async throws -> [HKWorkout] {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let query = HKSampleQuery(sampleType: .workoutType(), predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            manager.store.execute(query)
        }
    }

    // MARK: - Mapping

    /// Znacznik czasu w POŁUDNIE danego dnia (lokalnie urządzenia) - tak, by
    /// dzień kalendarzowy po stronie backendu (konwersja do Europe/Warsaw w
    /// `dateObjToLocalDateString`) zawsze wypadł na ten sam dzień,
    /// niezależnie od różnicy strefy czasowej między urządzeniem a serwerem.
    static func exportDateString(forDay day: Date) -> String {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: day)
        let noon = calendar.date(byAdding: .hour, value: 12, to: startOfDay) ?? startOfDay
        return exportDateFormatter.string(from: noon)
    }

    private static func makeExportWorkout(_ workout: HKWorkout) -> HealthExportWorkout {
        var energy: HealthExportQuantity?
        if let type = HealthKitManager.shared.quantityType(.activeEnergyBurned),
           let stats = workout.statistics(for: type),
           let sum = stats.sumQuantity() {
            energy = HealthExportQuantity(qty: sum.doubleValue(for: .kilocalorie()), units: "kcal")
        }

        return HealthExportWorkout(
            id: workout.uuid.uuidString,
            name: workoutActivityName(workout.workoutActivityType),
            start: exportDateFormatter.string(from: workout.startDate),
            end: exportDateFormatter.string(from: workout.endDate),
            duration: workout.duration,
            activeEnergyBurned: energy
        )
    }

    static func workoutActivityName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "Running"
        case .walking: return "Walking"
        case .cycling: return "Cycling"
        case .swimming: return "Swimming"
        case .functionalStrengthTraining: return "Functional Strength Training"
        case .traditionalStrengthTraining: return "Traditional Strength Training"
        case .yoga: return "Yoga"
        case .hiking: return "Hiking"
        case .elliptical: return "Elliptical"
        case .rowing: return "Rowing"
        case .coreTraining: return "Core Training"
        case .highIntensityIntervalTraining: return "High Intensity Interval Training"
        case .stairClimbing: return "Stair Climbing"
        case .dance: return "Dance"
        default: return "Workout"
        }
    }
}
