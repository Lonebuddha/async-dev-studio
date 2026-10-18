import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import StudioKernel
import ImagePlugin

final class ImageTests {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("Image viewer \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    private func makeImage(_ url: URL, orientation: Int = 1) throws -> CGImage {
        let context = CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0.3, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        try expectTrue(CGImageDestinationFinalize(destination))
        return image
    }
    @MainActor func testListingNavigationAndRefresh() throws {
        try fixture { root in
            let nested = root.appendingPathComponent("Subfolder")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let first = root.appendingPathComponent("image2.png"), last = root.appendingPathComponent("image10.png")
            _ = try makeImage(last); _ = try makeImage(first)
            try Data("text".utf8).write(to: root.appendingPathComponent("notes.txt"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: root.deletingLastPathComponent())
            let workspace = try ImageWorkspace(folder: root)
            try expectEqual(workspace.images.map(\.name), ["image2.png", "image10.png"])
            try expectEqual(workspace.listing[workspace.root]?.first?.name, "Subfolder")
            try expectEqual(workspace.listing[workspace.root]?.count, 3)
            try expectNil(workspace.selectedImage)
            workspace.select(first); workspace.move(-1); try expectEqual(workspace.selectedImage, try workspace.files.contained(first))
            workspace.move(1); try expectEqual(workspace.selectedImage, try workspace.files.contained(last))
            workspace.move(1); try expectEqual(workspace.selectedImage, try workspace.files.contained(last))
            workspace.move(-1); try expectEqual(workspace.selectedImage, try workspace.files.contained(first))
            workspace.showDirectory(nested); try expectTrue(workspace.images.isEmpty); try expectNil(workspace.selectedImage)
            workspace.showDirectory(root); workspace.select(last)
            try FileManager.default.removeItem(at: last); workspace.refresh()
            try expectNil(workspace.selectedImage); try expectEqual(workspace.images.map(\.name), ["image2.png"])
            try expectThrows(try workspace.files.contained(root.deletingLastPathComponent()))
            workspace.showDirectory(root.deletingLastPathComponent()); try expectNotNil(workspace.error)
            try expectEqual(workspace.directory, workspace.root)
        }
    }
    func testDecodingThumbnailsAndCorruptFiles() throws {
        try fixture { root in
            let file = root.appendingPathComponent("sample.png")
            _ = try makeImage(file)
            let image = try ImageFileSystem.decode(file)
            try expectEqual(image.width, 80); try expectEqual(image.height, 40)
            let thumbnail = try ImageFileSystem.decode(file, maximumPixels: 20)
            try expectEqual(thumbnail.width, 20); try expectEqual(thumbnail.height, 10)
            let corrupt = root.appendingPathComponent("corrupt.png")
            try Data("not image data".utf8).write(to: corrupt)
            try expectThrows(try ImageFileSystem.decode(corrupt))
        }
    }
    func testFitZoomAndPan() throws {
        var viewport = ImageViewport()
        let image = CGSize(width: 1000, height: 500), pane = CGSize(width: 400, height: 400)
        viewport.fit(image: image, pane: pane)
        try expectEqual(viewport.scale, 0.4)
        try expectEqual(viewport.origin, CGPoint(x: 0, y: 100))
        let anchor = CGPoint(x: 100, y: 200)
        let imageX = (anchor.x - viewport.origin.x) / viewport.scale
        let imageY = (anchor.y - viewport.origin.y) / viewport.scale
        viewport.zoom(factor: 2, anchor: anchor, image: image, pane: pane)
        try expectEqual(viewport.scale, 0.8)
        try expectEqual((anchor.x - viewport.origin.x) / viewport.scale, imageX)
        try expectEqual((anchor.y - viewport.origin.y) / viewport.scale, imageY)
        let origin = viewport.origin
        viewport.pan(dx: 15, dy: -20)
        try expectEqual(viewport.origin, CGPoint(x: origin.x + 15, y: origin.y - 20))
        viewport.zoom(factor: 1e12, anchor: anchor, image: image, pane: pane)
        try expectEqual(viewport.scale, 0.4 * 64)
        viewport.zoom(factor: 1e-12, anchor: anchor, image: image, pane: pane)
        try expectEqual(viewport.scale, 0.4 * 0.05)
        viewport.fit(image: CGSize(width: 100, height: 200), pane: pane)
        try expectEqual(viewport.scale, 2); try expectEqual(viewport.origin, CGPoint(x: 100, y: 0))
    }
    @MainActor func testConfigurationPersistenceAndRuntimeIsolation() throws {
        try fixture { root in
            let registry = PluginRegistry(); try registry.register(ImagePlugin())
            let store = JSONProjectStore(fileURL: root.appendingPathComponent("workspace.json"))
            let kernel = try ProjectKernel(store: store, plugins: registry)
            let project = try kernel.createProject(name: "Photos")
            let data = try ImageConfiguration(folder: root.path).encoded()
            let first = try kernel.createInstance(projectID: project.id, appTypeID: "images", name: "First", configuration: data)
            let second = try kernel.createInstance(projectID: project.id, appTypeID: "images", name: "Second", configuration: data)
            try expectEqual(try ProjectKernel(store: store, plugins: registry).projects[0].instances, [first, second])
            let runtime = ImageRuntime(); try runtime.open(first); try runtime.open(second)
            try expectFalse(runtime.controllers[first.id] === runtime.controllers[second.id])
            let controller = runtime.controllers[first.id]!
            try runtime.open(first); try expectTrue(runtime.controllers[first.id] === controller)
            runtime.close(first.id); try expectNil(runtime.controllers[first.id]); try expectNotNil(runtime.controllers[second.id])
            var future = ImageConfiguration(folder: root.path); future.version = 2
            try expectThrows(try ImagePlugin().validate(configuration: future.encoded()))
            try expectThrows(try ImagePlugin().validate(configuration: ImageConfiguration(folder: "relative").encoded()))
        }
    }
    @MainActor func testNativeCanvasNavigationAndFit() throws {
        _ = NSApplication.shared
        try fixture { root in
            let image = try makeImage(root.appendingPathComponent("native.png"))
            let view = ImageCanvasView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
            view.display(image, fitRequest: 0)
            try expectEqual(view.viewport.scale, 5)
            var offsets: [Int] = []; view.move = { offsets.append($0) }
            for code: UInt16 in [124, 123] {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
                view.keyDown(with: event)
            }
            try expectEqual(offsets, [1, -1])
            let original = view.viewport.origin
            let dragEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                mouseCursorPosition: .zero, mouseButton: .left)!
            dragEvent.setIntegerValueField(.mouseEventDeltaX, value: 20)
            dragEvent.setIntegerValueField(.mouseEventDeltaY, value: -10)
            view.mouseDragged(with: NSEvent(cgEvent: dragEvent)!)
            try expectEqual(view.viewport.origin, CGPoint(x: original.x + 20, y: original.y + 10))
            let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0)!
            view.scrollWheel(with: NSEvent(cgEvent: scroll)!)
            try expectTrue(view.viewport.scale > 5)
            view.display(image, fitRequest: 1)
            try expectEqual(view.viewport.origin, CGPoint(x: 0, y: 100))
            view.setFrameSize(NSSize(width: 200, height: 100)); try expectEqual(view.viewport.scale, 2.5)
        }
    }
}
