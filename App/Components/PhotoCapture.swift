import SwiftUI
import UIKit

/// Camera / library picker for intent photos — real photos of his actual
/// objects beat clipart (§7). Saves a JPEG under FileLocations.photos and
/// returns the photo ref.
struct PhotoCapture: UIViewControllerRepresentable {
    enum Source {
        case camera
        case library

        var pickerSource: UIImagePickerController.SourceType {
            switch self {
            case .camera: return .camera
            case .library: return .photoLibrary
            }
        }
    }

    let source: Source
    let onPhoto: (String?) -> Void

    static func cameraAvailable() -> Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        if UIImagePickerController.isSourceTypeAvailable(source.pickerSource) {
            picker.sourceType = source.pickerSource
        }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPhoto: onPhoto) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPhoto: (String?) -> Void

        init(onPhoto: @escaping (String?) -> Void) {
            self.onPhoto = onPhoto
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            picker.dismiss(animated: true)
            guard let image = info[.originalImage] as? UIImage else {
                onPhoto(nil)
                return
            }
            onPhoto(Self.save(image))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
            onPhoto(nil)
        }

        static func save(_ image: UIImage) -> String? {
            let ref = UUID().uuidString
            let url = FileLocations.photoURL(id: ref)
            guard let data = image.jpegData(compressionQuality: 0.8) else { return nil }
            do {
                try data.write(to: url, options: .completeFileProtection)
                return ref
            } catch {
                return nil
            }
        }
    }
}
