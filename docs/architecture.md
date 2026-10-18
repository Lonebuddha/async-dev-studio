# Async Dev Studio — Architecture

## Architectural decisions

Build three completely separate native applications that implement the [same product specification](product.md) and [use cases](scenarios/create-project.md):

| Target | Language | Recommended UI | Build tools |
| --- | --- | --- | --- |
| macOS | Swift | SwiftUI with AppKit for desktop views and integration | Xcode and Swift packages |
| Windows | C#/.NET | WPF | .NET SDK and MSBuild |
| Ubuntu | C++20 | Qt 6 Widgets | CMake and the Ubuntu compiler toolchain |

Each application owns its shell, domain implementation, persistence, microkernel, and internal apps. There is no shared executable core, cross-language bridge, shared backend service, or requirement for compatible plugin binaries. Shared artifacts are the product specification, behavioral contracts, configuration definitions, and acceptance scenarios. Platform teams can organize and implement their code idiomatically.

The experience is consistent in meaning and behavior, with native controls, menus, shortcuts, focus behavior, dialogs, and styling. Pixel-identical presentation is not a goal.

Apple provides [AppKit integration for SwiftUI](https://developer.apple.com/documentation/swiftui/appkit-integration). [WPF](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/overview/) is a Windows desktop UI framework for .NET. [Qt Widgets](https://doc.qt.io/qt-6/qtwidgets-index.html) provides desktop controls and model/view facilities suitable for the Ubuntu tree-and-tabs shell. Qt's platform styling should be checked on the supported Ubuntu desktop environments.

WPF is recommended for its tree and tab controls, desktop integration, and established .NET deployment model. WinUI 3 is also an option; the single-executable requirement does not prohibit its dynamically linked framework dependencies.

## Compile-time plugins and the microkernel

Each application uses a microkernel application architecture: a small infrastructure core and tool modules behind explicit interfaces. This pattern does not imply dynamic loading, a shared implementation across platforms, or an operating-system microkernel.

All internal app plugins are compiled into the application and registered explicitly at startup. Adding, updating, or removing a plugin requires rebuilding and releasing the corresponding platform application. Users create instances of built-in app types; they do not install plugin files. There is no filesystem discovery, dynamic plugin loader, hot replacement, or marketplace.

“Statically linked plugins” means build-time inclusion with direct references to implementations. On Swift and C++, use source modules or static libraries linked into the application. On .NET, compile internal app code into the executable assembly where practical; compile-time referenced assemblies may also be embedded by single-file publishing. Managed bundling is not native static linking, and must not be described as such. In all cases there are no separately distributed internal app plugin DLLs or shared libraries. This restriction applies only to product plugin implementations. Any third-party library or framework may be dynamically linked, including dependencies used by those plugins.

```text
            Native shell: tree, tabs, menus, dialogs
                              |
              Platform-specific microkernel
       Workspace | Runtime lifecycle | Services | Storage
                              |
                 Explicit built-in app registry
                              |
        Terminal | Browser | Text editor | Database client
           Platform-native views and instance controllers
```

The kernel owns identities, project commands, service registration, lifecycle coordination, scoped events, persistence, and diagnostics. The shell owns presentation and selection routing. Internal apps own their parameters, validation, runtime resources, views, and session state. The kernel does not interpret terminal commands, browser URLs, SQL options, or editor buffers.

Modules depend on kernel contracts, not the shell implementation or another app's private code. A registry maps stable app type IDs to compiled-in factories. Each factory creates independent instance controllers; a factory is not a live instance. Registration should detect duplicate type IDs and invalid dependencies before the workspace becomes interactive.

## Platform-specific implementations

### macOS

Use Swift protocols and explicit dependency injection for kernel services and app factories. Build plugin implementations into the application using source targets or static package products. Prefer SwiftUI for ordinary forms and overview views, with AppKit integration for tree navigation, complex tab content, text editing, and desktop window behavior as needed.

Use Swift concurrency for asynchronous operations and keep UI mutations on the main actor. Use application-support directories for storage and Keychain for credentials. The browser can use the system WebKit framework through WKWebView; its actual process model is controlled by the framework. The current macOS implementation requires macOS 14 and uses a named persistent `WKWebsiteDataStore` per browser instance UUID. It restores a Keychain cookie snapshot before navigation, preserves original cookie expiry/security attributes, and checkpoints on cookie changes and close/quit. WebKit retains local storage and IndexedDB; closing a tab keeps its profile, while deleting the instance removes it. Site-controlled expiry and reauthentication still apply. See the [macOS implementation notes](../macos/README.md) and [WebKit profile API](https://webkit.org/blog/14423/building-profiles-with-new-webkit-api/).

The macOS text editor is a compiled-in `EditorPlugin` module. An instance owns a configured folder, lazy directory listings, and independent file document models. Its tab embeds a split view with a file tree and nested file tabs. Each file retains its own AppKit text control and undo manager. The plugin owns encoding, dirty-state tracking, external-edit checks, and atomic file writes; the shell coordinates save/discard/cancel before closing instances or quitting. Workspace metadata stores the folder configuration, while source files remain in their original folders. There are no editor dependencies beyond platform frameworks.

The macOS `TeamsPlugin` subclasses the open `BrowserPlugin` class through public hooks for WebKit configuration and saved-page restoration. Its module owns Teams defaults, Safari identification, Teams error-page recovery, and the Teams icon. The generic browser runtime accepts registered browser-derived factories and injects one into each controller; it contains no Teams domains or type-specific policies. Both app types reuse browser views, persistent profile and Keychain services, and shutdown/deletion handling. The Teams plugin’s source is linked into the product executable; its PNG resource bundle is installed under the application’s resources.

### Windows

Use C# interfaces, explicit factory registration, and dependency injection. Keep app implementations in source namespaces or compile-time modules without reflection-based plugin discovery. Use WPF tree and tab controls, native dialogs, and platform keyboard conventions. Use asynchronous operations and dispatch UI changes to the UI thread.

Use per-user application-data directories and Windows Credential Manager for secrets. Browser integration can use WebView2, subject to its loader and runtime deployment requirements. Its external libraries and runtime are permitted dependencies of the single application executable.

### Ubuntu

Use C++ interfaces and explicit factories, with source modules or static libraries for internal apps. Use Qt Widgets for the shell and views. Keep GUI operations on the GUI thread; move blocking operations to workers. Use the desktop's per-user application-data location and Secret Service for credentials.

Qt and its platform, image-format, database, and other framework plugins may be dynamically linked or loaded as third-party dependencies. A static Qt build is optional, not required by the single-executable rule. Qt documents its [plugin mechanisms](https://doc.qt.io/qt-6/plugins-howto.html). Product internal app factories use ordinary C++ registration and remain compiled into the application regardless of how Qt is deployed.

## Shared behavioral contract

The shared specification describes observable behavior rather than a common binary SDK. Each platform implements equivalent contracts in its own language:

| Contract | Responsibility |
| --- | --- |
| App descriptor and factory | Stable type ID, display name, defaults, independent controllers |
| Configuration provider | Fields or native form, validation, configuration migration |
| Instance controller | Start, stop, restart, status, asynchronous errors, cancellation |
| View provider | Native view for the instance tab |
| Close participant | Unsaved-work detection and save/discard/cancel negotiation |
| Host services | Project context, storage, credential references, events, diagnostics |

Use the same stable app type IDs and configuration field meanings on all platforms. Platform-specific options, such as a shell executable path, should be explicit and documented. Contract names and ownership mechanisms can differ by language.

A specification change must describe its effect on every implementation. Maintain common acceptance cases and example configurations, and execute them separately through each platform's test framework. Identical database files and project portability are not required in the initial release; any future import/export format needs its own versioned specification.

## Domain model and persistence

Use stable UUIDs independently of display names:

| Entity | Important fields |
| --- | --- |
| Project | ID, name, optional default directory, timestamps |
| AppInstance | ID, project ID, stable app type ID, name, configuration version, app-specific values |
| SessionLayout | Project ID, ordered open instance IDs, selected instance ID |
| AppDescriptor | Type ID, implementation version, configuration version, capabilities |

Implement the product's naming rules and display all app instances directly under their project, with icons identifying app types. Recommend SQLite for transactional workspace metadata on each platform, using an appropriate native or managed binding. Configuration values are versioned JSON; each internal app validates and migrates its own values. Database drivers and SQLite bindings may be dynamically linked third-party dependencies; verify their deployment on each supported platform.

Store large profiles and recovery buffers in instance-specific data directories. Store credential references in metadata and actual secrets in OS credential storage. Application data and external working directories are separate from the executable. Project deletion removes workspace definitions, not source files or databases.

Migrate storage transactionally with a recoverable backup. Keep the first release to one application process per user workspace to avoid competing writers. Missing app types in a newer or reduced build leave saved definitions visible as unavailable instead of deleting them.

## Tab routing and lifecycle

1. Selecting an instance resolves its stable ID and switches the active project.
2. The shell reuses its tab or creates one native view and controller.
3. The controller validates configuration and transitions from stopped to starting.
4. Asynchronous initialization ends in running or failed, with an instance-specific error and retry.
5. Further selection only changes focus; it never reruns initialization.

Tabs belong to the active project. Switching projects preserves background sessions and restores that project's last selected tab. Persist tab layout independently of live resources. On application restart, restore placeholders with sessions stopped until the user starts them.

Configuration changes apply on the next start unless the app explicitly supports live updates. Terminal startup commands run once per fresh session, in order, with defined completion and failure semantics. A long-running command should normally be the last step or use a separate instance.

Closing a tab negotiates unsaved work, stops the session, and retains its definition. Cancellation preserves its view and controller. Deleting a project first negotiates all affected closures and checkpoints recoverable state. The macOS shell saves workspace metadata atomically before tearing down sessions, so a workspace-save failure preserves definitions and open controllers. After committing, it stops terminals, releases editor buffers, and removes browser profiles; subsequent profile-cleanup failures are reported explicitly. Source files are never removed by project deletion.

## Internal app implementation and processes

Each platform implements its own app views and tool behavior. Reusing external libraries is an implementation choice, not a requirement for a shared product core.

Text editing owns file loading, dirty buffers, saving, and recovery. Database clients run queries asynchronously with cancellation and connection-specific diagnostics. Terminal views need terminal emulation plus PTY integration on macOS/Ubuntu and ConPTY on supported Windows versions; ordinary redirected subprocess pipes are insufficient.

Plugins execute in the host process and are trusted application code. Their interfaces provide modularity, not a security sandbox or guaranteed crash isolation. Worker threads preserve responsiveness. If an application-owned worker process is necessary, it can launch the same executable in an internal worker mode, rather than distributing another executable. That mechanism is optional and platform-specific.

A single executable does not imply a single process: terminal shells, OS browser services, and framework-owned subprocesses can still run. Browser engines and database drivers require special dependency evaluation; do not promise that compile-time plugin inclusion eliminates their runtime dependencies.

## Single-executable delivery

The requirement is **one product executable per platform and architecture**, containing the shell, microkernel, and all internal app plugin implementations. Third-party libraries and frameworks may be dynamically linked without restriction from this architectural rule. Their DLLs, shared libraries, frameworks, runtime packages, resources, and vendor-provided helper processes may be bundled with the application or supplied by the operating system or installed dependencies.

This is a single application executable, not necessarily a single-file distribution, a fully static binary, or a dependency-free application. Normal platform packaging and runtime extraction are allowed. Product plugins remain compiled in and cannot be installed or updated independently; dynamically linking their third-party dependencies does not change that rule.

| Target | Delivery approach | Permitted dependencies |
| --- | --- | --- |
| macOS | One product executable inside a signed `.app` bundle | System frameworks, bundled third-party frameworks or libraries, resources, and vendor helpers |
| Windows | One product `.exe` with all internal app implementations included; .NET single-file publishing may bundle managed modules | .NET runtime, third-party DLLs, browser runtime, resources, and vendor helpers |
| Ubuntu | One ELF product executable with internal apps compiled or statically linked into it | Dynamically linked Qt, other shared libraries, Qt framework plugins, browser runtime, resources, and vendor helpers |

Microsoft documents [single-file publishing](https://learn.microsoft.com/en-us/dotnet/core/deploying/single-file/overview), including optional native-library bundling through `IncludeNativeLibrariesForSelfExtract`. Bundling third-party dependencies into the executable is optional; shipping them alongside it or using an installed runtime is also acceptable. Internal app modules must still be included in the product executable rather than distributed as independent plugins.

Apple documents the [content of native application bundles](https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle). Bundle metadata, resources, and third-party frameworks surrounding the executable are compatible with this architecture.

Qt WebEngine is again a candidate for the Ubuntu browser because dynamically linked third-party libraries and their helpers are allowed. Its [build configuration](https://github.com/qt/qtwebengine/blob/dev/configure.cmake) rejects static builds, which no longer conflicts with the product requirement. The product's browser plugin implementation remains compiled into the executable while it uses Qt WebEngine as a dynamic dependency. Verify browser embedding and runtime deployment before finalizing that choice.

Release checks must distinguish product modules from third-party dependencies: exactly one product executable, all internal app implementations included, and every required external dependency available. Framework-owned helper processes and terminal shells do not count as separate product applications.

## Repository and verification

Suggested organization within this repository:

```text
apps/macos/          Swift shell, kernel, internal apps, platform tests
apps/windows/        C#/.NET shell, kernel, internal apps, platform tests
apps/ubuntu/         C++ shell, kernel, internal apps, platform tests
specifications/      Future shared schemas, fixtures, and behavioral contracts
docs/                Shared product, architecture, and scenarios
```

Use idiomatic subdirectories inside each application. There is no shared runtime source directory. Build and release each application independently with pinned toolchains and supported OS/CPU baselines.

Begin with a packaging prototype and a simple compiled-in app on each platform. Prove native tree/tab behavior, storage, registration, and independent instances. Then implement real tools, checking packaging again whenever a dependency is introduced. Check framework and third-party license obligations for the selected linking and distribution model, whether libraries are linked statically or dynamically; the repository's Apache-2.0 license does not replace dependency licenses. See [Qt licensing](https://doc.qt.io/qt-6/licensing.html).

CI should run domain, configuration, lifecycle, persistence, and native UI tests for each application. Shared acceptance cases cover first launch, create/rename/delete, duplicate prevention, independent instances, tab identity, cancellation, failed initialization, and restart without command replay. Run equivalent scenarios on each supported OS, allowing platform-native visual differences. Verify release artifacts on clean systems, inspect their dependencies, and confirm no internal app plugin files are needed.

Remaining choices are supported OS versions, how third-party dependencies are bundled or installed, the Ubuntu browser backend, and which app ships first. Platform languages, independent implementations, native experience, one product executable, compile-time internal app plugins, and permission to dynamically link third-party libraries are settled decisions.
