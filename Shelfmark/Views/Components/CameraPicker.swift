import SwiftUI
import UIKit
import UniformTypeIdentifiers
import CoreTransferable

/// System camera for a still photo or a video pan along the shelf.
struct CameraPicker: UIViewControllerRepresentable {
    enum Result { case photo(UIImage), video(URL) }
    let onFinish: (Result?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        picker.videoQuality = .typeHigh
        picker.videoMaximumDuration = 120
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (Result?) -> Void
        init(onFinish: @escaping (Result?) -> Void) { self.onFinish = onFinish }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let url = info[.mediaURL] as? URL {
                onFinish(.video(url))
            } else if let image = info[.originalImage] as? UIImage {
                onFinish(.photo(image))
            } else {
                onFinish(nil)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onFinish(nil) }
    }
}

/// Lets PhotosPicker hand back a video as a file we can read with AVFoundation.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}

/// Presents the system camera directly from UIKit rather than inside a SwiftUI sheet.
/// Embedding UIImagePickerController in a SwiftUI fullScreenCover can leave the camera
/// preview black on some devices; presenting it modally from the top view controller avoids that.
@MainActor
enum CameraPresenter {
    private static var activeDelegate: Delegate?

    static func present(onFinish: @escaping (CameraPicker.Result?) -> Void) {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            onFinish(nil)
            return
        }
        guard let presenter = topViewController() else { return }

        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        picker.cameraCaptureMode = .photo
        picker.videoQuality = .typeHigh
        picker.videoMaximumDuration = 120
        picker.modalPresentationStyle = .fullScreen

        let delegate = Delegate { result in
            picker.dismiss(animated: true) {
                activeDelegate = nil
                onFinish(result)
            }
        }
        activeDelegate = delegate          // UIImagePickerController holds its delegate weakly
        picker.delegate = delegate
        presenter.present(picker, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ??
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
            ?? scene?.windows.first?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    @MainActor
    private final class Delegate: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let finish: (CameraPicker.Result?) -> Void
        init(finish: @escaping (CameraPicker.Result?) -> Void) { self.finish = finish }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let url = info[.mediaURL] as? URL {
                finish(.video(url))
            } else if let image = info[.originalImage] as? UIImage {
                finish(.photo(image))
            } else {
                finish(nil)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { finish(nil) }
    }
}
