import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Photos and screenshots go to the backend as base64 JPEG (`image_base64`), downscaled so a
/// 12 MP photo doesn't become a 5 MB request body.
enum ImageEncoding {
    static let maxDimension: CGFloat = 1280
    static let jpegQuality: CGFloat = 0.7

    /// Any image data PhotosPicker hands back (HEIC, PNG, JPEG) -> downscaled base64 JPEG.
    static func jpegBase64(from data: Data) -> String? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        return jpegBase64(from: image)
        #else
        return nil
        #endif
    }

    #if canImport(UIKit)
    static func jpegBase64(from image: UIImage) -> String? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: jpegQuality)?.base64EncodedString()
    }
    #endif
}
