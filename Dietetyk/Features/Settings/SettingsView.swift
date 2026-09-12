import SwiftUI

struct SettingsView: View {
    @StateObject private var viewModel: SettingsViewModel

    init(appState: AppState) {
        _viewModel = StateObject(wrappedValue: SettingsViewModel(appState: appState))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let profile = viewModel.profile {
                    Section {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.username)
                                .font(.headline)
                            if let email = profile.email {
                                Text(email)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Cele dzienne") {
                    goalField("Kalorie (kcal)", text: $viewModel.targetCaloriesText)
                    goalField("Białko (g)", text: $viewModel.targetProteinText)
                    goalField("Węglowodany (g)", text: $viewModel.targetCarbsText)
                    goalField("Tłuszcz (g)", text: $viewModel.targetFatText)
                    goalField("Woda (ml)", text: $viewModel.targetWaterMlText)

                    Button {
                        Task { await viewModel.saveGoals() }
                    } label: {
                        if viewModel.isSaving {
                            ProgressView()
                        } else {
                            Text("Zapisz cele")
                        }
                    }
                    .disabled(viewModel.isSaving)
                }

                if viewModel.isHealthDataAvailable {
                    Section {
                        Toggle("Synchronizuj z Apple Health", isOn: Binding(
                            get: { viewModel.healthSyncEnabled },
                            set: { viewModel.setHealthSyncEnabled($0) }
                        ))

                        if viewModel.healthSyncEnabled {
                            HStack {
                                Text("Ostatnia synchronizacja")
                                Spacer()
                                Text(viewModel.lastHealthSyncDate.map { APIDateFormat.displayDateTimeFormatter.string(from: $0) } ?? "—")
                                    .foregroundStyle(.secondary)
                            }

                            Button {
                                Task { await viewModel.syncHealthNow() }
                            } label: {
                                if viewModel.isSyncingHealth {
                                    ProgressView()
                                } else {
                                    Text("Synchronizuj teraz")
                                }
                            }
                            .disabled(viewModel.isSyncingHealth)
                        }

                        if let healthSyncMessage = viewModel.healthSyncMessage {
                            Text(healthSyncMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Synchronizacja zdrowia")
                    } footer: {
                        Text("Zastępuje webhook \"Health Auto Export\" - kroki, kalorie, dystans i treningi z Zdrowia są wysyłane do Twojego konta automatycznie, bez dodatkowej apki.")
                    }
                }

                Section {
                    TextField("https://moj-serwer.pl", text: $viewModel.serverURLText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button("Zapisz adres") {
                        viewModel.saveServerURL()
                    }
                    Button("Przywróć domyślny") {
                        viewModel.resetServerURL()
                    }
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Adres serwera")
                } footer: {
                    Text("Zmiana adresu wylogowuje - token sesji należy do konkretnego serwera i nie jest wysyłany do innego.")
                }

                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                if let successMessage = viewModel.successMessage {
                    Section {
                        Text(successMessage)
                            .font(.footnote)
                            .foregroundStyle(.green)
                    }
                }

                Section {
                    Button("Wyloguj się", role: .destructive) {
                        viewModel.logout()
                    }
                }
            }
            .navigationTitle("Ustawienia")
            .overlay {
                if viewModel.isLoading {
                    ProgressView()
                }
            }
            .task { await viewModel.load() }
            .refreshable { await viewModel.load() }
        }
    }

    private func goalField(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("—", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 100)
        }
    }
}
