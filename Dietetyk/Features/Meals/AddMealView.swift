import SwiftUI
import PhotosUI

struct AddMealView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: AddMealViewModel
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var showCamera = false

    let onSaved: () -> Void

    init(appState: AppState, date: Date, onSaved: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: AddMealViewModel(appState: appState, date: date))
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Opis posiłku") {
                    TextEditor(text: $viewModel.rawText)
                        .frame(minHeight: 100)
                    Text("Opcjonalny, jeśli dodajesz zdjęcie - AI rozpozna danie samodzielnie.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Zdjęcie") {
                    if let image = viewModel.selectedImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 220)
                        Button("Usuń zdjęcie", role: .destructive) {
                            viewModel.selectedImage = nil
                            photoPickerItem = nil
                        }
                    }
                    Button {
                        showCamera = true
                    } label: {
                        Label("Zrób zdjęcie", systemImage: "camera")
                    }
                    PhotosPicker(selection: $photoPickerItem, matching: .images) {
                        Label("Wybierz z galerii", systemImage: "photo.on.rectangle")
                    }
                }

                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Nowy posiłek")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Anuluj") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            if await viewModel.save() {
                                onSaved()
                                dismiss()
                            }
                        }
                    } label: {
                        if viewModel.isSaving {
                            ProgressView()
                        } else {
                            Text("Zapisz")
                        }
                    }
                    .disabled(!viewModel.canSave || viewModel.isSaving)
                }
            }
            .disabled(viewModel.isSaving)
            // Wczytanie zdjęcia z galerii potrafi się nie udać (plik w iCloud
            // bez pobranej kopii, uszkodzony/nieobsługiwany format, cofnięta
            // zgoda). Wcześniej `try?` + `guard ... else { return }` połykały
            // każdy z tych przypadków bez śladu: użytkownik wybierał zdjęcie,
            // arkusz nie pokazywał NICZEGO i nie było wiadomo, czy zdjęcie
            // zostało dodane. Teraz każdy nieudany odczyt kończy się
            // komunikatem w tej samej sekcji błędów, co reszta ekranu.
            .onChange(of: photoPickerItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    do {
                        guard let data = try await newItem.loadTransferable(type: Data.self),
                              let uiImage = UIImage(data: data) else {
                            viewModel.errorMessage = "Nie udało się wczytać wybranego zdjęcia. Wybierz inne albo zrób nowe aparatem."
                            return
                        }
                        viewModel.selectedImage = uiImage
                        viewModel.errorMessage = nil
                    } catch {
                        viewModel.errorMessage = "Nie udało się wczytać wybranego zdjęcia: \(error.localizedDescription)"
                    }
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker(image: $viewModel.selectedImage, isPresented: $showCamera)
                    .ignoresSafeArea()
            }
        }
    }
}
