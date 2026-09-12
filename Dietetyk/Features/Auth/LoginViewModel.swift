import Foundation

@MainActor
final class LoginViewModel: ObservableObject {
    /// Krok przepływu logowania - backend może po prostu zalogować, albo
    /// zażądać jednego z trzech dodatkowych kroków (patrz `LoginOutcome`).
    enum Stage: Equatable {
        case credentials
        case twoFactorCode(tempToken: String)
        case twoFactorSetup(tempToken: String, qrCode: String, secret: String)
        case forcedPasswordChange(tempToken: String)
    }

    @Published var username = ""
    @Published var password = ""
    @Published var code = ""
    @Published var newPassword = ""
    @Published var newPasswordConfirm = ""
    @Published private(set) var stage: Stage = .credentials
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    var canSubmitCredentials: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    func submitCredentials() async {
        guard canSubmitCredentials else { return }
        await run {
            let outcome = try await APIClient.shared.login(username: self.username, password: self.password)
            try self.handle(outcome)
        }
    }

    func submitTwoFactorCode() async {
        guard case .twoFactorCode(let tempToken) = stage, !code.isEmpty else { return }
        await run {
            let token = try await APIClient.shared.loginTwoFactor(tempToken: tempToken, code: self.code)
            try self.appState.markAuthenticated(token: token)
        }
    }

    func confirmTwoFactorSetup() async {
        guard case .twoFactorSetup(let tempToken, _, _) = stage, !code.isEmpty else { return }
        await run {
            let token = try await APIClient.shared.verifyTwoFactorSetup(tempToken: tempToken, code: self.code)
            try self.appState.markAuthenticated(token: token)
        }
    }

    func submitNewPassword() async {
        guard case .forcedPasswordChange(let tempToken) = stage else { return }
        guard newPassword.count >= 8 else {
            errorMessage = "Nowe hasło musi mieć co najmniej 8 znaków."
            return
        }
        guard newPassword == newPasswordConfirm else {
            errorMessage = "Podane hasła się różnią."
            return
        }
        await run {
            let outcome = try await APIClient.shared.changePasswordForced(tempToken: tempToken, newPassword: self.newPassword)
            try self.handle(outcome)
        }
    }

    /// Powrót z kroku 2FA/zmiany hasła do formularza logowania (np. gdy
    /// użytkownik zacznie od nowa albo wpisał błędny `tempToken`-zależny krok).
    func cancelTwoStepFlow() {
        stage = .credentials
        code = ""
        newPassword = ""
        newPasswordConfirm = ""
        errorMessage = nil
    }

    private func handle(_ outcome: LoginOutcome) throws {
        switch outcome {
        case .authenticated(let token):
            try appState.markAuthenticated(token: token)
        case .requiresTwoFactor(let tempToken):
            stage = .twoFactorCode(tempToken: tempToken)
            code = ""
        case .requiresTwoFactorSetup(let tempToken, let qrCode, let secret):
            stage = .twoFactorSetup(tempToken: tempToken, qrCode: qrCode, secret: secret)
            code = ""
        case .requiresPasswordChange(let tempToken):
            stage = .forcedPasswordChange(tempToken: tempToken)
            // Czyścimy `code` tak samo jak przy przejściu do kroków 2FA -
            // poprzednio zostawało tu wpisane wcześniej (np. błędne) hasło
            // jednorazowe, mimo że ten etap go już nie używa.
            code = ""
        }
    }

    private func run(_ operation: @escaping () async throws -> Void) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
