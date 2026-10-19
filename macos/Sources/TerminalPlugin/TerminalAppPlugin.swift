import Foundation
import StudioKernel

/// Shared terminal plugin base. Concrete plugins supply their configuration and launch policy.
/// Every subclass uses the same controller and emulator: wheel events scroll native
/// history or are reported to mouse-aware programs; Shift-wheel bypasses reporting.
open class TerminalAppPlugin: AppPlugin {
    public let descriptor: AppDescriptor
    public init(id: String, name: String) { descriptor = AppDescriptor(id: id, name: name) }
    open var supportsStartupCommands: Bool { false }
    open var configurationSummary: String? { nil }
    open func decodeConfiguration(_ data: Data) throws -> TerminalConfiguration {
        throw TerminalError.invalidConfiguration("This terminal plugin must provide its configuration.")
    }
    open func configurationData(shell: String, workingDirectory: String, startupCommands: [String]) throws -> Data {
        throw TerminalError.invalidConfiguration("This terminal plugin must provide its configuration.")
    }
    public func validate(configuration: Data) throws { try decodeConfiguration(configuration).validate() }
    open func launchConfiguration(for instance: AppInstance) throws -> TerminalConfiguration {
        try decodeConfiguration(instance.configuration)
    }
    @MainActor public func makeController(for instance: AppInstance) throws -> TerminalController {
        TerminalController(configuration: try decodeConfiguration(instance.configuration),
                           prepareForStart: { try self.launchConfiguration(for: instance) })
    }
    @MainActor public func configure(_ controller: TerminalController, instance: AppInstance) throws {
        try controller.configureForNextStart(try decodeConfiguration(instance.configuration),
                                            preparation: { try self.launchConfiguration(for: instance) })
    }
}
