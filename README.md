# Dietetyk iOS

Natywny klient iOS (SwiftUI) dla [Dietetyk-AI](https://dietetyk.renacode.com) — apki do liczenia
kalorii/makro z poradami AI. Ten projekt **nie jest jeszcze wdrażany produkcyjnie** — to szkielet
przygotowany pod wdrożenie za kilka miesięcy.

## Status

Szkielet aplikacji: logowanie (z obsługą 2FA i wymuszonej zmiany hasła), dashboard (kalorie/makro,
kroki/aktywność, sen/gotowość/HRV z Oura, skład ciała z Withings/Apple Health), lista i dodawanie
posiłków (tekst + zdjęcie z analizą AI), licznik wody, ustawienia (cele, adres serwera, wylogowanie),
**natywna synchronizacja Apple Health (HealthKit)** — patrz niżej.

### Synchronizacja Apple Health (HealthKit) — zastępstwo webhooka

Apka czyta natywnie z HealthKit (kroki, kalorie aktywne/spoczynkowe, minuty aktywności, dystans
chód+bieg, temperatura nadgarstka, treningi) i wysyła te dane do **tego samego** endpointu, który
dotąd przyjmował payloady z apki trzeciej firmy "Health Auto Export"
(`POST /api/integrations/apple-health/:syncToken`, `backend/routes/appleHealth.js` w repo
`Dietetyk-AI`) — backend nie wymaga żadnych zmian, liczy się tylko kształt JSON-a
(`Models/HealthExportModels.swift` replikuje go 1:1).

- Włącza/wyłącza się w **Ustawienia → Synchronizacja zdrowia** (prosi o zgodę systemową przy
  pierwszym włączeniu, potem działa bez dalszej interakcji).
- Automatyczna synchronizacja: przy starcie/powrocie apki z tła oraz w tle przez
  `HKObserverQuery` + `enableBackgroundDelivery` (`Health/HealthSyncService.swift`) — gdy
  HealthKit dostanie nowe dane (np. z zegarka), apka sama je wysyła, bez potrzeby otwierania jej.
  Jest też przycisk "Synchronizuj teraz" do ręcznego wywołania.
- Token synchronizacji (`sync_token`) pobierany jest automatycznie z `/api/settings` — użytkownik
  nie musi go nigdzie wpisywać.
- Zakres metryk jest dokładnie taki, jaki backend już umie przetworzyć (`METRIC_FIELD_MAP` w
  `appleHealth.js`) — wagi/składu ciała/snu ten webhook NIE obsługuje (to idzie innymi drogami,
  np. Withings), więc HealthKit też ich tędy nie wysyła.

Po pierwszym wdrożeniu na realne urządzenie z Apple Watch/iPhone, ta funkcja pozwala całkowicie
zrezygnować z konfigurowania automatyzacji w apce "Health Auto Export" — Dietetyk iOS staje się
samodzielnym źródłem danych zdrowotnych.

Nie zaimplementowane jeszcze (świadomie odłożone, do dodania przed wdrożeniem):
- logowanie przez Google (wymaga `ASWebAuthenticationSession`),
- panel administratora (Admin Panel),
- wykresy trendów (Trends) — endpoint `/api/health/history` już obsłużony w `APIClient`, brak UI,
- powiadomienia push.

## Wymagania

- macOS z Xcode 16+ (iOS 17 deployment target)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — projekt **nie zawiera** commitowanego
  `.xcodeproj` (plik binarny, konfliktogenny w git), generujemy go z `project.yml`:

  ```
  brew install xcodegen
  ```

## Budowanie

```
cd Dietetyk-iOS
xcodegen generate
open Dietetyk.xcodeproj
```

W Xcode: wybierz swój zespół deweloperski (Signing & Capabilities), wybierz symulator lub urządzenie
i uruchom (Cmd+R).

## Konfiguracja adresu backendu

Domyślny adres backendu to `https://dietetyk.renacode.com` (patrz `Networking/APIConfig.swift`).
Można go zmienić w aplikacji: ekran **Ustawienia → Adres serwera** (zapisywany lokalnie w
`UserDefaults`, nie wymaga przebudowania apki — przydatne np. do testowania na własnym
self-hosted backendzie albo przeciw `localhost` podczas developmentu).

Przyjmowane są wyłącznie adresy `https` i `http` (to drugie na potrzeby lokalnego
`http://localhost:3000` — ATS jest włączone i tak czy inaczej zablokuje zwykłe `http` poza
localhostem). **Zmiana adresu wylogowuje**: token sesji z Keychain należy do konkretnego backendu,
a `APIClient` dokleja go jako `Authorization: Bearer` do każdego żądania pod aktualny adres — bez
czyszczenia tokenu wpisanie cudzego adresu wysłałoby żywy token produkcyjnego konta na obcy host.

## Architektura

- **SwiftUI + MVVM** — każdy ekran ma `View` + `ObservableObject` ViewModel (`@MainActor`,
  `@Published` stan), bez zewnętrznych frameworków DI/reaktywnych (Combine ograniczony do
  `@Published`, networking przez `async/await`).
- **Networking/APIClient.swift** — jeden, prosty klient HTTP nad `URLSession`, bez zewnętrznych
  zależności (Alamofire itd. — niepotrzebne przy tej skali apki). Token sesji wysyłany jako
  `Authorization: Bearer <token>` (zgodnie z `backend/middleware/auth.js` w repo Dietetyk-AI —
  backend NIE używa cookies/sesji przeglądarki, tylko nagłówka Bearer, więc natywny klient nie
  potrzebuje obsługi ciasteczek).
- **Networking/KeychainStore.swift** — token sesji trzymany w Keychain (NIE w `UserDefaults` —
  to jedyny element wymagający bezpiecznego storage; adres serwera i cele to dane nie-sekretne).
- **Models/** — struktury `Codable` z `keyDecodingStrategy = .convertFromSnakeCase`, bo backend
  zwraca JSON w `snake_case` (np. `target_calories`, `active_minutes`), a kod Swift ma być
  idiomatycznie `camelCase` (`targetCalories`, `activeMinutes”) — mapowanie automatyczne, bez
  ręcznych `CodingKeys` w każdym modelu.
- Brak Core Data/SwiftData w tej wersji — apka jest "thin client" nad istniejącym backendem
  (tak jak frontend webowy), dane nie są cache'owane trwale na urządzeniu. Można to dodać później,
  jeśli potrzebny będzie pełny offline mode.

## Kontrakt API (backend `Dietetyk-AI`)

Pełna referencja w kodzie — `Networking/APIClient.swift` ma jedną metodę na endpoint. Najważniejsze:

| Endpoint | Metoda | Auth | Opis |
|---|---|---|---|
| `/api/login` | POST | nie | `{username,password}` → `{token}` albo `{status:"require_2fa"\|"setup_2fa"\|"force_password_change", tempToken}` |
| `/api/login-2fa` | POST | nie | `{tempToken,code}` → `{token}` |
| `/api/verify-2fa-setup` | POST | nie | `{tempToken,code}` → `{token}` (pierwsza konfiguracja 2FA) |
| `/api/change-password-forced` | POST | nie | `{tempToken,newPassword}` → `{token}` lub kolejny krok 2FA |
| `/api/logout` | POST | tak | unieważnia token |
| `/api/dashboard?date=YYYY-MM-DD` | GET | tak | podsumowanie dnia (kalorie/makro/zdrowie) + lista posiłków |
| `/api/meals?date=YYYY-MM-DD` | GET | tak | lista posiłków danego dnia |
| `/api/meals` | POST | tak | `{rawText?, image?(data URL base64), date?}` → analiza AI + zapis (może zwrócić wiele posiłków z jednego zdjęcia) |
| `/api/meals/:id` | DELETE | tak | usuwa posiłek |
| `/api/settings` | GET/POST | tak | cele kaloryczne/makro, sync_token (do Apple Health), klucze integracji |
| `/api/user/profile` | GET/POST | tak | profil, e-mail, avatar, status 2FA/integracji |
| `/api/water/add` `/api/water/reset` | POST | tak | licznik wypitej wody |
| `/api/health/history` | GET | tak | 90 dni metryk zdrowotnych (do przyszłych Trends) |

Autoryzacja: nagłówek `Authorization: Bearer <token>` (token sesji ważny 7 dni, odświeżany przy
każdym żądaniu — patrz `backend/middleware/auth.js`).

## Struktura katalogów

```
Dietetyk/
  App/                  punkt wejścia, AppState (sesja/routing)
  Networking/           APIClient, APIError, KeychainStore, APIConfig
  Models/                struktury Codable
  Health/                HealthKitManager, HealthSyncService, HealthSyncPreferences
  Features/
    Auth/                logowanie, 2FA, wymuszona zmiana hasła
    Dashboard/            ekran główny
    Meals/                lista/dodawanie posiłków
    Settings/             cele, adres serwera, synchronizacja Apple Health, wylogowanie
```
