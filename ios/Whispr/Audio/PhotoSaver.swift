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

    /// At least this much taller than wide already looks shot on a phone (matches the brain).
    private static let portraitRatio: CGFloat = 1.15

    /// Asks for add-only photo access ahead of time, so the prompt never pops up mid-conversation.
    static func requestAccessIfNeeded() async {
        if PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
    }

    /// Downloads the photo and makes it vertical, like a phone shot.
    static func download(from url: URL) async throws -> UIImage {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let image = UIImage(data: data) else { throw Failure.notAnImage }
        return portrait(image)
    }

    /// Adds the photo to the camera roll, where it shows up as the newest photo.
    static func addToLibrary(_ image: UIImage) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.accessDenied }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }

    /// Centre-crops a landscape or square photo to 3:4 portrait, the shape of a phone photo.
    /// Vertical photos are left alone.
    static func portrait(_ image: UIImage) -> UIImage {
        let size = image.size // Already corrected for EXIF orientation.
        guard size.width > 0, size.height < size.width * portraitRatio else { return image }
        let target = CGSize(width: (size.height * 3 / 4).rounded(.down), height: size.height.rounded(.down))
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(at: CGPoint(x: (target.width - size.width) / 2, y: 0))
        }
    }
}
