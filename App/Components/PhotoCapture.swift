import SwiftUI
import UIKit

/// Camera / library picker for intent photos — real photos of his actual
/// objects beat clipart (§7). Saves a JPEG under FileLocations.photos and
/// returns the photo ref.
///
/// The photo is downsampled to `maxEdge` pixels on its longest side before
/// saving (D2): a 12 MP camera JPEG decodes to ~48 MB and the Board shows
/// eight at once on an old phone; 800 px is plenty for a 120 pt cell on a
/// 3× screen and decodes in a few MB.
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

    /// Longest edge, in pixels, of a saved photo.
    static let maxEdge: CGFloat = 800

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

    /// Scales `image` so its longest side is at most `maxEdge` pixels,
    /// normalizing orientation on the way. Returns the image unchanged when
    /// it is already small enough.
    static func downsampled(_ image: UIImage, maxEdge: CGFloat = PhotoCapture.maxEdge) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longest = max(pixelWidth, pixelHeight)
        guard longest > maxEdge, longest > 0 else { return image }
        let factor = maxEdge / longest
        let target = CGSize(
            width: max(1, (pixelWidth * factor).rounded()),
            height: max(1, (pixelHeight * factor).rounded())
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

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
            let small = PhotoCapture.downsampled(image)
            guard let data = small.jpegData(compressionQuality: 0.8) else { return nil }
            do {
                // No per-file protection class: the file inherits the photos
                // directory's class (see FileLocations), which stays
                // readable while the counter phone is locked.
                try data.write(to: url, options: .atomic)
                PhotoCache.shared.invalidate(ref: ref)
                return ref
            } catch {
                return nil
            }
        }
    }
}
