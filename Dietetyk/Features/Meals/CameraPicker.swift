import SwiftUI
import UIKit

/// Prosty wrapper na `UIImagePickerController` do robienia zdjęć aparatem.
/// `PhotosPicker` (PhotosUI), używany do wyboru z galerii, obsługuje
/// wyłącznie bibliotekę zdjęć - nie aparat - stąd ten dodatkowy widok.
struct CameraPicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Binding var isPresented: Bool

    /// Aparat nie istnieje na symulatorze ani na części iPadów. Dokumentacja
    /// `UIImagePickerController` wymaga sprawdzenia dostępności ZANIM ustawi
    /// się `sourceType` - przypisanie niedostępnego źródła jest błędem
    /// programisty i kończy się wyjątkiem w czasie działania, a nie pustym
    /// ekranem. Tu schodzimy wtedy do biblioteki zdjęć; `AddMealView` i tak
    /// chowa przycisk "Zrób zdjęcie", więc w praktyce to zabezpieczenie
    /// drugiego rzutu.
    static var isCameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = Self.isCameraAvailable ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let uiImage = info[.originalImage] as? UIImage {
                parent.image = uiImage
            }
            parent.isPresented = false
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.isPresented = false
        }
    }
}
