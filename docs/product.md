# Async Dev Studio — Product specification

## Purpose

Async Dev Studio is a native desktop workspace for software developers who work on multiple projects. It brings project-specific tools into one window so that developers can switch projects without repeatedly finding browser pages, reopening files, reconnecting databases, or preparing terminals.

The product has three completely separate applications: Swift for macOS, C#/.NET for Windows, and C++ for Ubuntu. Each implements the same product specification and use cases, with a native experience appropriate to its operating system. Layout, terminology, and behavior are consistent; controls, menus, shortcuts, and visual styling follow platform conventions.

Each application has its own platform-specific microkernel and internal app implementations. Internal apps are plugins in the architectural sense: build-time modules compiled into the application, with explicit registration and no separately installed plugin binaries. Each platform targets one application executable; platform packaging and framework constraints are described in the architecture document.

This document captures the requested product and proposes initial behavior where details have not yet been decided. Proposed defaults can change during implementation. See [Architecture](architecture.md) and [First project scenario](scenarios/create-project.md).

## Concepts

| Concept | Meaning | Example |
| --- | --- | --- |
| Project | A persistent container for tools used for a particular development activity. | Customer Portal |
| Internal app | A built-in tool implementation supplied as a compile-time plugin. | Terminal |
| App instance | A named, independently configured use of an app within a project. | API server terminal |
| Tab | The main-pane presentation of an opened instance. | API server |
| Runtime session | The live resources of an instance, such as a shell process or database connection. | A running shell |

A project can contain several app types and many instances of each type. All instances appear directly beneath the project node, with an icon identifying their app type. Renaming an instance changes its display label, never its identity or app type.

A built-in plugin implementation is shared by all projects. Instance configuration and live state are independent between projects and between instances. Removing an instance from a project does not remove its built-in plugin implementation.

## Window and navigation

The main window has a resizable tree pane on the left and a main pane on the right. A menu and toolbar expose common actions, including creating a project and adding an app instance.

```text
Projects                          Main pane
├── Customer Portal               [API server] [Documentation] [Local database]
│   ├── API server (terminal)      ┌─────────────────────────────────────────┐
│   ├── Tests (terminal)          │ View of the selected internal app       │
│   ├── Documentation (browser)   │ instance                                │
│   └── Local database (database) └─────────────────────────────────────────┘
└── Inventory Service
    └── Notes (text editor)
```

App types shown in parentheses above are represented by icons in the tree. Instances of all types share one list in their project; there is no intermediate app-type node.

Each opened instance has exactly one tab, keyed by its persistent ID. Selecting an instance opens its tab if necessary and activates it. Selecting an already opened instance reuses its tab. Activating a tab selects the corresponding tree node.

Proposed default: tabs belong to the active project. Switching projects displays that project's tabs and restores its last selection. Sessions in other projects continue until explicitly closed or stopped. The tree shows running instances so that background activity remains visible.

Selecting a project shows a project overview when it has no active tab. The project context menu, toolbar, and overview provide actions for adding instances.

## Managing projects and nodes

The user can create, rename, and delete projects, and create, rename, configure, and delete instances of built-in apps directly within them. These actions are available through contextual menus and keyboard-accessible commands.

Project creation requires a display name and optionally a default working directory. Creating a project stores workspace metadata; it does not create a Git repository or modify the chosen directory. An empty project is valid, and no tools start automatically.

Names must be nonempty after trimming whitespace. Proposed default: project names are unique across the workspace and instance names within the same app type in a project, using case-insensitive comparisons. Persistent IDs remain stable through renaming.

Deleting a project also deletes its contained instance definitions. The application lists affected instances and active sessions before proceeding and allows cancellation. Any unsaved changes or active work must be resolved through the relevant app's close workflow. Deleting workspace metadata does not delete source files, databases, browser targets, or working directories.

## Configuring instances

Every instance has a name and initialization parameters defined by its app. The app supplies defaults, field descriptions, validation, and, where necessary, a custom configuration form.

| App | Example initialization parameters |
| --- | --- |
| Browser | Initial URL, browser profile, optional navigation preferences |
| Teams | Initial Teams URL, independent browser profile |
| Text editor | Root folder |
| Database client | Driver, host, port, database name, username, credential reference |
| Terminal | Shell executable, working directory, environment overrides, ordered startup commands |

Projects provide context such as the default working directory. Apps explicitly declare which defaults they inherit; instance overrides take priority. Parameters remain app-specific rather than being interpreted by the shell.

Configuration is validated before saving. A cancelled form leaves the instance unchanged. Saving configuration does not silently restart a running session: changes apply on its next start unless the app supports a clearly identified live update. The user can explicitly restart an instance to apply changes.

Passwords and tokens are stored through the operating system's credential storage. Project metadata stores references to those credentials. Configuration forms distinguish secret fields from ordinary values.

## Teams instances

Teams is a built-in app type derived from the browser. Its instances appear directly under their projects with the Teams icon and open Teams by default. They inherit browser navigation, tab behavior, independent persistent profiles, and remembered logins. Teams-specific browser identification and rejection-page recovery belong to this app type, keeping the generic browser independent of Teams.

## Text editor instances

Each text editor instance is configured with a folder. Inside its instance tab, a resizable left pane shows that folder’s files and subfolders, and a right pane contains a separate tab for each open file. Opening a file again selects its existing tab. Switching files or instances keeps their editing buffers, selections, and undo histories independent.

The basic editor supports plain-text editing, save/save all, undo/redo, find/replace, indentation, line numbers, and basic syntax coloring. Modified file tabs are visibly marked. Closing a file or instance, changing its folder, deleting its definition, or quitting resolves unsaved changes through save/discard/cancel. A failed save keeps the buffer open. External file changes must not be silently overwritten, and deleting an instance never deletes its source files.

## Instance and tab lifecycle

An instance definition exists independently of its tab. Creating it stores configuration; opening it starts a session on demand. A terminal's ordered initialization commands run once for each newly started session, with app-defined completion and failure rules. Changing tab focus never reruns initialization.

Closing a tab requests session shutdown and retains the saved instance definition. The app may ask the user to save changes or resolve running work; cancellation keeps the tab open. A separate **Stop** action ends a session while allowing its tab to remain with a stopped state and a **Start** action.

Restarting the desktop application restores projects, configuration, and tab placeholders. Proposed default: previously open instances remain stopped until the user starts them. Restoring layout alone does not execute terminal commands or reconnect databases. Automatic startup can be considered later as an explicit per-instance setting.

Runtime states include stopped, starting, running, stopping, and failed. A failed instance displays a useful error and a retry action without discarding its configuration. If a saved project refers to an app type omitted from the current build, its nodes remain visible with an unavailable state.

## Product qualities

- Project and instance definitions survive normal shutdown and application restart.
- Local project management works without a cloud account; individual apps may need network access.
- Startup and project navigation remain responsive while tools perform long-running work.
- Keyboard navigation, meaningful focus order, platform shortcuts, screen reader labels, and display scaling are supported.
- Configuration errors identify the affected field; runtime errors identify the affected instance.
- Developers can add a plugin module and rebuild the application without changing project navigation or teaching the kernel app-specific behavior.
