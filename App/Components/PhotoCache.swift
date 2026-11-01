import ImageIO
import SwiftUI
import UIKit

/// Decoded intent photos, shared by every surface that shows one (Board
/// cells, Confirm grid, Dictionary, setup). Photos are saved at ≤ 800 px
/// (PhotoCapture), decoded once off the main thread with
/// `preparingForDisplay()`, and kept in an NSCache so a Board render never
/// decodes a JPEG on the thread that must deliver his < 100 ms press
/// feedback (§7).
final class PhotoCache {
    static let shared = PhotoCache()

    private let cache = NSCache<NSString, UIImage>()

    init(countLimit: Int = 200) {
        cache.countLimit = countLimit
    }

    /// Synchronous hit test; nil means `load` is needed.
    func cached(ref: String) -> UIImage? {
        cache.object(forKey: ref as NSString)
    }

    /// Loads and decodes the photo off the caller's thread, caching the
    /// display-ready bitmap. Nil when the file is missing or unreadable.
    ///
    /// Decoding goes through ImageIO's thumbnail path with
    /// `PhotoCapture.maxEdge` as the pixel cap: photos saved before
    /// downsampling existed are full 12 MP camera JPEGs, and a cache of
    /// those (~48 MB each decoded) is exactly the jetsam risk D2 removed.
    /// The cap is a no-op for photos already saved small.
    func load(ref: String) async -> UIImage? {
        if let hit = cached(ref: ref) { return hit }
        let url = FileLocations.photoURL(id: ref)
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let raw = Self.decodeDownsampled(at: url, maxEdge: PhotoCapture.maxEdge) else { return nil }
            return raw.preparingForDisplay() ?? raw
        }.value
        if let image {
            cache.setObject(image, forKey: ref as NSString)
        }
        return image
    }

    /// Decodes the JPEG at `url` to at most `maxEdge` pixels on its longest
    /// side, orientation applied, without ever materializing the full-size
    /// bitmap (ImageIO subsamples while decoding). Falls back to a plain
    /// decode if ImageIO cannot read the file.
    static func decodeDownsampled(at url: URL, maxEdge: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return UIImage(contentsOfFile: url.path)
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxEdge),
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return UIImage(contentsOfFile: url.path)
        }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    /// Call after a photo file is replaced or deleted.
    func invalidate(ref: String) {
        cache.removeObject(forKey: ref as NSString)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

/// A photo by ref, from the cache or loaded asynchronously, filling its
/// frame (callers clip and size it). Shows `placeholder` until the bitmap
/// is ready and whenever the file cannot be read.
struct CachedPhoto<Placeholder: View>: View {
    let ref: String
    let placeholder: () -> Placeholder

    @State private var image: UIImage?

    init(ref: String, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.ref = ref
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: ref) {
            if let hit = PhotoCache.shared.cached(ref: ref) {
                image = hit
                return
            }
            let loaded = await PhotoCache.shared.load(ref: ref)
            if !Task.isCancelled {
                image = loaded
            }
        }
    }
}

extension CachedPhoto where Placeholder == Color {
    /// Neutral fill while loading / when the file is missing.
    init(ref: String) {
        self.init(ref: ref) { Color(.tertiarySystemFill) }
    }
}
