import AppKit
import SwiftUI

public enum TeamsAssets {
    public static var iconURL: URL? {
        // SwiftPM's generated accessor assumes a command-line layout. A desktop
        // bundle places this resource bundle under Contents/Resources instead.
        if let url = Bundle.main.resourceURL?.appendingPathComponent("AsyncDevStudioMacOS_TeamsPlugin.bundle"),
           let bundle = Bundle(url: url) { return bundle.url(forResource: "Teams", withExtension: "png") }
        return Bundle.module.url(forResource: "Teams", withExtension: "png")
    }
}
public struct TeamsIcon: View {
    public init() {}
    public var body: some View {
        if let url = TeamsAssets.iconURL, let icon = NSImage(contentsOf: url) {
            Image(nsImage: icon).renderingMode(.original).resizable().scaledToFit().frame(width: 18, height: 18).accessibilityHidden(true)
        }
    }
}
