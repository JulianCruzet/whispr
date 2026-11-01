// Saves a proof photo into the camera roll so it can be shown off naturally.

import Photos
import UIKit

enum PhotoSaver {
    enum Failure: LocalizedError {
        case notAnImage, accessDenied
        var errorDescription: String? {
            self == .notAnImage ? "Couldn't read the photo." : "Photo access is off. Turn it on in Settings → Whispr."
        }
    }

    static func save(from url: URL) async throws -> UIImage {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let image = UIImage(data: data) else { throw Failure.notAnImage }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.accessDenied }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
        return image
    }
}
