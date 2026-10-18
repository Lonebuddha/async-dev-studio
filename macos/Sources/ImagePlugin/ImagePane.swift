import AppKit
import SwiftUI

/// Serial background decoding and a bounded thumbnail cache keep directory
/// browsing from retaining full-size images or decoding every tile at once.
private actor ImageLoader {
    static let shared = ImageLoader()
    private final class CachedImage: NSObject {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }
    private let cache: NSCache<NSString, CachedImage> = {
        let cache = NSCache<NSString, CachedImage>()
        cache.countLimit = 256; cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()
    func load(_ url: URL, thumbnail: Bool) throws -> CGImage {
        try Task.checkCancellation()
        let date = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(url.path):\(date)" as NSString
        if thumbnail, let cached = cache.object(forKey: key) { return cached.image }
        let image = try ImageFileSystem.decode(url, maximumPixels: thumbnail ? 256 : nil)
        if thumbnail { cache.setObject(CachedImage(image), forKey: key, cost: image.bytesPerRow * image.height) }
        return image
    }
}

public struct ImagePane: View {
    @ObservedObject private var workspace: ImageWorkspace
    public init(workspace: ImageWorkspace) { self.workspace = workspace }
    public var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Button { workspace.showDirectory(workspace.root) } label: {
                        Label(workspace.root.lastPathComponent, systemImage: "folder").lineLimit(1)
                    }.buttonStyle(.plain).help(workspace.root.path)
                    Spacer()
                    Button { workspace.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh images")
                }.padding(8)
                List { ImageDirectoryRows(workspace: workspace, directory: workspace.root) }.listStyle(.sidebar)
            }.frame(minWidth: 150, idealWidth: 220, maxWidth: 400)
            VStack(spacing: 0) {
                HStack {
                    if workspace.selectedImage != nil {
                        Button { workspace.showDirectory(workspace.directory) } label: { Label("Directory", systemImage: "square.grid.2x2") }
                        Button { workspace.move(-1) } label: { Image(systemName: "chevron.left") }
                            .disabled(workspace.images.first?.url == workspace.selectedImage).help("Previous image (←)")
                        Button { workspace.move(1) } label: { Image(systemName: "chevron.right") }
                            .disabled(workspace.images.last?.url == workspace.selectedImage).help("Next image (→)")
                    }
                    Text(workspace.selectedImage?.lastPathComponent ?? workspace.directory.lastPathComponent)
                        .lineLimit(1).truncationMode(.middle).help(workspace.selectedImage?.path ?? workspace.directory.path)
                    Spacer()
                    Text("\(workspace.images.count) images").font(.caption).foregroundStyle(.secondary)
                }.padding(8)
                Divider()
                if let url = workspace.selectedImage {
                    SingleImagePane(url: url, move: workspace.move).id(workspace.refreshID)
                } else {
                    ScrollView {
                        if workspace.images.isEmpty {
                            Text("No supported images in this directory").foregroundStyle(.secondary).padding(24)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 180))], spacing: 16) {
                            ForEach(workspace.images) { entry in
                                Button { workspace.select(entry.url) } label: { ImageTile(entry: entry).id(workspace.refreshID) }
                                    .buttonStyle(.plain).help(entry.url.path)
                            }
                        }.padding(16)
                    }
                }
            }.frame(minWidth: 250, maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert("Couldn’t open images", isPresented: Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) {
            Button("OK") { workspace.error = nil }
        } message: { Text(workspace.error ?? "") }
    }
}
private struct ImageDirectoryRows: View {
    @ObservedObject var workspace: ImageWorkspace
    let directory: URL
    var body: some View {
        ForEach(workspace.listing[directory] ?? []) { entry in
            if entry.isDirectory {
                ImageFolderRow(workspace: workspace, entry: entry)
            } else {
                Button { workspace.select(entry.url) } label: {
                    Label(entry.name, systemImage: "photo").lineLimit(1)
                        .foregroundStyle(workspace.selectedImage == entry.url ? Color.accentColor : Color.primary)
                }.buttonStyle(.plain).help(entry.url.path)
            }
        }
    }
}
private struct ImageFolderRow: View {
    @ObservedObject var workspace: ImageWorkspace
    let entry: ImageEntry
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ImageDirectoryRows(workspace: workspace, directory: entry.url)
        } label: {
            Button { workspace.showDirectory(entry.url) } label: {
                Label(entry.name, systemImage: "folder").lineLimit(1)
                    .foregroundStyle(workspace.directory == entry.url ? Color.accentColor : Color.primary)
            }.buttonStyle(.plain)
        }.onChange(of: expanded) { _, value in if value { workspace.loadDirectory(entry.url) } }
    }
}
private struct ImageTile: View {
    let entry: ImageEntry
    @State private var image: CGImage?
    @State private var failed = false
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05))
                if let image { Image(decorative: image, scale: 1).resizable().scaledToFit().padding(4) }
                else if failed { Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary) }
                else { ProgressView().controlSize(.small) }
            }.frame(height: 110)
            Text(entry.name).font(.caption).lineLimit(2).frame(maxWidth: .infinity)
        }.contentShape(Rectangle()).accessibilityLabel(entry.name)
        .task(id: entry.url) {
            do {
                let loaded = try await ImageLoader.shared.load(entry.url, thumbnail: true)
                try Task.checkCancellation(); image = loaded
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}
private struct SingleImagePane: View {
    let url: URL
    let move: (Int) -> Void
    @State private var image: CGImage?
    @State private var error: String?
    @State private var fitRequest = 0
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Fit to Pane") { fitRequest += 1 }
                Text("Scroll to zoom · Drag to pan · ← → to browse").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(6)
            ImageCanvas(image: image, fitRequest: fitRequest, move: move)
                .overlay {
                    if let error { Text(error).foregroundStyle(.secondary).padding() }
                    else if image == nil { ProgressView() }
                }
        }.task(id: url) {
            image = nil; error = nil
            do {
                let loaded = try await ImageLoader.shared.load(url, thumbnail: false)
                try Task.checkCancellation(); image = loaded
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
private struct ImageCanvas: NSViewRepresentable {
    let image: CGImage?
    let fitRequest: Int
    let move: (Int) -> Void
    func makeNSView(context: Context) -> ImageCanvasView { ImageCanvasView() }
    func updateNSView(_ view: ImageCanvasView, context: Context) {
        view.move = move
        view.display(image, fitRequest: fitRequest)
    }
}

public final class ImageCanvasView: NSView {
    public private(set) var viewport = ImageViewport()
    public var move: ((Int) -> Void)?
    private var image: CGImage?
    private var fitRequest = 0
    public override var acceptsFirstResponder: Bool { true }
    public override init(frame: NSRect) { super.init(frame: frame) }
    public convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public func display(_ image: CGImage?, fitRequest: Int) {
        let changed = self.image !== image
        self.image = image
        if changed || self.fitRequest != fitRequest {
            fit(); self.fitRequest = fitRequest
            if changed { focus() }
        }
        needsDisplay = true
    }
    private var imageSize: CGSize { image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero }
    private func fit() { viewport.fit(image: imageSize, pane: bounds.size); needsDisplay = true }
    public override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); fit() }
    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); focus() }
    private func focus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.isKeyWindow, window.attachedSheet == nil else { return }
            window.makeFirstResponder(self)
        }
    }
    public override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        guard let image else { return }
        let rect = CGRect(origin: viewport.origin, size: CGSize(width: imageSize.width * viewport.scale, height: imageSize.height * viewport.scale))
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: image, size: imageSize).draw(in: rect)
    }
    public override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    public override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); NSCursor.closedHand.set() }
    public override func mouseDragged(with event: NSEvent) {
        viewport.pan(dx: event.deltaX, dy: -event.deltaY); needsDisplay = true
    }
    public override func mouseUp(with event: NSEvent) { NSCursor.openHand.set() }
    public override func scrollWheel(with event: NSEvent) {
        guard image != nil else { return }
        window?.makeFirstResponder(self)
        let amount = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.12)
        viewport.zoom(factor: exp(min(max(amount, -2), 2)), anchor: convert(event.locationInWindow, from: nil), image: imageSize, pane: bounds.size)
        needsDisplay = true
    }
    public override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 123: move?(-1)
        case 124: move?(1)
        default: super.keyDown(with: event)
        }
    }
}
