import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers
import StudioKernel

public struct ImageEntry: Identifiable, Equatable {
    public var id: URL { url }
    public let url: URL
    public let isDirectory: Bool
    public var name: String { url.lastPathComponent }
}

public struct ImageFileSystem {
    public let root: URL
    public init(folder: URL) throws {
        try ImageConfiguration(folder: folder.path).validate()
        root = folder.standardizedFileURL.resolvingSymlinksInPath()
    }
    public func contained(_ url: URL) throws -> URL {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard url.isFileURL, resolved.path == root.path || resolved.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") else { throw ImageError.outsideFolder }
        return resolved
    }
    public func entries(in directory: URL) throws -> [ImageEntry] {
        let folder = try contained(directory)
        let supported = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
        return try FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]).compactMap { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            // Avoid recursive links and browsing outside the configured folder.
            guard values.isSymbolicLink != true else { return nil }
            let canonical = try contained(url)
            if values.isDirectory == true { return ImageEntry(url: canonical, isDirectory: true) }
            // LaunchServices may be unavailable in a command-line test process.
            // ImageIO identifiers keep common formats independent of that service.
            let knownTypes = ["png": "public.png", "jpg": "public.jpeg", "jpeg": "public.jpeg", "jpe": "public.jpeg",
                "gif": "com.compuserve.gif", "tif": "public.tiff", "tiff": "public.tiff", "bmp": "com.microsoft.bmp",
                "heic": "public.heic", "heif": "public.heif", "webp": "org.webmproject.webp", "avif": "public.avif",
                "ico": "com.microsoft.ico", "icns": "com.apple.icns", "jp2": "public.jpeg-2000",
                "psd": "com.adobe.photoshop-image", "exr": "com.ilm.openexr-image"]
            let identifier = knownTypes[url.pathExtension.lowercased()] ?? UTType(filenameExtension: url.pathExtension)?.identifier
            guard values.isRegularFile == true, let identifier, supported.contains(identifier) else { return nil }
            return ImageEntry(url: canonical, isDirectory: false)
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.name < $1.name : order == .orderedAscending
        }
    }
    public static func decode(_ url: URL, maximumPixels: Int? = nil) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { throw ImageError.unsupportedImage }
        let nativeSize = max(properties[kCGImagePropertyPixelWidth] as? Int ?? 1, properties[kCGImagePropertyPixelHeight] as? Int ?? 1)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maximumPixels ?? nativeSize,
            kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw ImageError.unsupportedImage }
        return image
    }
}

@MainActor
public final class ImageWorkspace: ObservableObject {
    public let files: ImageFileSystem
    public var root: URL { files.root }
    @Published public private(set) var listing: [URL: [ImageEntry]] = [:]
    @Published public private(set) var directory: URL
    @Published public private(set) var selectedImage: URL?
    @Published public var error: String?
    @Published public private(set) var refreshID = UUID()
    public var images: [ImageEntry] { (listing[directory] ?? []).filter { !$0.isDirectory } }
    public init(folder: URL) throws {
        files = try ImageFileSystem(folder: folder)
        directory = files.root
        listing[directory] = try files.entries(in: directory)
    }
    public func loadDirectory(_ url: URL) {
        do { listing[url] = try files.entries(in: url) }
        catch { self.error = error.localizedDescription }
    }
    public func showDirectory(_ url: URL) {
        do {
            let folder = try files.contained(url)
            let entries = try files.entries(in: folder)
            listing[folder] = entries; directory = folder; selectedImage = nil
        } catch { self.error = error.localizedDescription }
    }
    public func select(_ url: URL) {
        do {
            let file = try files.contained(url)
            let parent = file.deletingLastPathComponent()
            let entries = try files.entries(in: parent)
            guard entries.contains(where: { $0.url == file && !$0.isDirectory }) else { throw ImageError.unsupportedImage }
            listing[parent] = entries; directory = parent; selectedImage = file
        } catch { self.error = error.localizedDescription }
    }
    public func move(_ offset: Int) {
        guard let selectedImage, let index = images.firstIndex(where: { $0.url == selectedImage }) else { return }
        let next = index + offset
        guard images.indices.contains(next) else { return }
        self.selectedImage = images[next].url
    }
    public func refresh() {
        refreshID = UUID()
        let previous = selectedImage
        for folder in Array(listing.keys) { loadDirectory(folder) }
        if let previous, !images.contains(where: { $0.url == previous }) { selectedImage = nil }
    }
}

@MainActor
public final class ImageRuntime: ObservableObject {
    @Published public private(set) var controllers: [UUID: ImageWorkspace] = [:]
    public init() {}
    public func open(_ instance: AppInstance) throws {
        guard instance.appTypeID == "images", controllers[instance.id] == nil else { return }
        let config = try ImageConfiguration.decode(instance.configuration)
        try config.validate()
        controllers[instance.id] = try ImageWorkspace(folder: URL(fileURLWithPath: config.folder))
    }
    public func close(_ id: UUID) { controllers[id] = nil }
}

/// View geometry shared by drawing, mouse handling, and behavioral tests.
public struct ImageViewport {
    public private(set) var scale: CGFloat = 1
    public private(set) var origin = CGPoint.zero
    public init() {}
    public func fittedScale(image: CGSize, pane: CGSize) -> CGFloat {
        guard image.width > 0, image.height > 0, pane.width > 0, pane.height > 0 else { return 1 }
        return min(pane.width / image.width, pane.height / image.height)
    }
    public mutating func fit(image: CGSize, pane: CGSize) {
        scale = fittedScale(image: image, pane: pane)
        origin = CGPoint(x: (pane.width - image.width * scale) / 2, y: (pane.height - image.height * scale) / 2)
    }
    public mutating func zoom(factor: CGFloat, anchor: CGPoint, image: CGSize, pane: CGSize) {
        let base = fittedScale(image: image, pane: pane)
        let next = min(max(scale * factor, base * 0.05), base * 64)
        let ratio = next / scale
        origin = CGPoint(x: anchor.x - (anchor.x - origin.x) * ratio, y: anchor.y - (anchor.y - origin.y) * ratio)
        scale = next
    }
    public mutating func pan(dx: CGFloat, dy: CGFloat) { origin.x += dx; origin.y += dy }
}
