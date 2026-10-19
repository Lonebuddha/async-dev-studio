# Async Dev Studio for macOS

A native Swift application for macOS 14 or later, with a project workspace and compiled-in terminal, Claude, Codex, browser, Teams, text editor, and image viewer plugins. macOS 14 is required for WebKit’s independent persistent profiles.

## Using the app

1. Choose **Create Project** or press **⌘N**, enter a name, and choose **Create**.
2. Select the project, then choose **Add Terminal** from the toolbar or its context menu.
3. Enter a terminal name, shell path, working directory, and optional startup commands. Choose **Add** to save its definition without starting a shell.
4. Expand the project in the sidebar, then select the terminal instance to start it and open its tab.

Each terminal has its own PTY, shell process, emulator, and scrollback. Open multiple instances in a project and switch between their tabs. Switching projects keeps sessions alive and restores that project's tabs for the current application session. Reopening an already open instance reuses its tab and shell.

**Configure…** in an instance's context menu changes its name and parameters; parameter changes apply on the next shell start. **Stop…** is available from the tab's context menu. A stopped or exited shell has a **Start** button. Closing a running tab asks before stopping the shell and its foreground commands, while retaining the definition. **Delete…** removes the definition after confirmation. Quitting asks before stopping running sessions and waits for shutdown.

The default shell is `/bin/zsh`, and the default directory is the user's home directory. `/bin/bash` and `/bin/sh` are also supported. Custom shells must accept POSIX-style startup syntax and the `-i` and `-l` options. Startup commands are entered one per line and queued as one compound command for the interactive login shell to read after its normal startup files. They run once per fresh shell start in that same shell, preserving activated environments, local variables, functions, and directory changes. A failed command ends the session; long-running commands should be last. Use `export` for environment values that child processes need to inherit.

Project and app instance names are trimmed, nonempty, and unique without regard to case within their respective scope. Configuration uses absolute paths; the form includes a native directory picker. The project itself has only a name, not a working directory.

Right-click a project for **Rename…** or **Delete…**. Renaming validates the name and updates the tree and header while keeping its instances, browser profiles, and running sessions. Deleting asks for confirmation, identifies running terminals that will stop, and resolves unsaved editor changes. It removes the project and its instance definitions, stops its sessions, and removes browser profiles and remembered logins. Source files and editor folders remain in place.

Cancellation and workspace-save failures keep the project and its open tabs. Browser state is checkpointed before committing the deletion; metadata is saved before resources are closed. A subsequent browser-profile cleanup error is reported explicitly even though the project definition has been deleted. The interface shows progress during deletion and blocks overlapping shutdown/restart. Deleting an inactive project keeps the current selection; deleting the active one selects another project if available.

**File → Restart**, immediately below **New Project…**, closes and relaunches the application from its current location. It follows the normal quit workflow: save/discard/cancel for modified editor files, confirmation before stopping terminals, and browser state saving. Cancelling or a shutdown error cancels the restart. A short-lived system helper waits for the old process to exit before reopening the same app bundle; direct executable launches restart that executable. Restart restores saved definitions and browser profiles, with the same tab/buffer limits as ordinary quit and launch.

## Codex instances

Choose **Add Codex** in the project context menu, toolbar, or overview. Configure a name, shell, and working folder. It shares the terminal base with Claude and starts `codex --no-alt-screen --dangerously-bypass-approvals-and-sandbox`. Inline mode preserves native terminal scrollback on new and resumed sessions. After a completed response, the instance remembers its conversation and uses `codex resume <session ID>` on subsequent starts. Only normal Terminal instances expose Startup commands. Codex CLI must be installed on the login shell's PATH and signed in.

The CLI's per-process notification callback records only the session ID and working folder under `~/Library/Application Support/AsyncDevStudio/CodexSessions/<instance UUID>/session.json`. This overrides `notify` for this process only; global configuration and built-in TUI notifications remain unchanged. A new conversation interrupted before its first completed response has no saved ID yet. See [Codex plugin details](../docs/codex-plugin.md).

## Claude instances

Choose **Add Claude** in the project context menu, toolbar, or overview. Configure a name, shell, and working folder. It starts `claude --permission-mode bypassPermissions` and resumes this instance's previous conversation when history is available. Only normal Terminal instances expose Startup commands. Claude Code must be installed on the login shell's PATH and signed in as needed.

`TerminalPlugin` and `ClaudePlugin` both inherit `TerminalAppPlugin` and share the PTY, emulator, selection, clipboard, tab, stop/start, and shutdown handling. A structured SessionStart hook records the session ID, folder, and transcript path under `~/Library/Application Support/AsyncDevStudio/ClaudeSessions/<instance UUID>/session.json`. Records are private and written atomically. CLI hooks must remain enabled. See [Claude plugin details](../docs/claude-plugin.md).

## Browser instances and remembered logins

Choose **Add Browser** in a selected project, enter a name and initial website, then open the instance directly under its project in the tree. The address bar supports HTTP/HTTPS URLs, back/forward, reload, and stop. Addresses without a scheme default to HTTPS. Each instance runs in its own tab. Login popups open in native windows using the same profile.

Each browser instance has a persistent WebKit profile identified by its saved instance UUID. Cookies, local storage, and IndexedDB belong to that profile; two instances can use different accounts on the same website. These profiles are separate from Safari and other browsers. Renaming an instance keeps its profile.

Cookie changes and completed navigations trigger a Keychain snapshot. Both session and persistent cookies are saved with their original expiry and security attributes; expired cookies are excluded. This preserves session-only login cookies and avoids WebKit’s delayed disk flush when quitting immediately after a login. Restoration finishes before the first page request. Logging out updates the snapshot, so reopening does not restore the old login. Closing a tab and normal application shutdown wait for saving; a save failure is shown and blocks that close/quit attempt.

Close and reopen the app, then select the same browser instance: it restores its last visited page and existing login state. Open-tab layout itself is not restored automatically. The initial website is used only when there is no saved page; editing it or the instance name does not reset the current session. **Delete…** removes the definition, WebKit profile, remembered cookies, and last-page metadata after confirmation.

Website expiry, server-side logout, enterprise authentication policies, or an identity provider rejecting embedded browsers can still require a new login. This does not keep server sessions alive or store passwords. Tab-only `sessionStorage`, page memory, history, popup windows, downloads, and unsaved forms are not restored. Forced termination or power loss can interrupt a snapshot; normal quit waits for it.

## Teams instances

Choose **Add Teams** from the project context menu, toolbar, or overview. Enter an instance name and, if needed, a different Teams starting URL. Open the instance directly under its project; it displays the official Microsoft Teams icon.

`TeamsPlugin` subclasses the open `BrowserPlugin` class. It inherits URL validation and configuration, and reuses the browser’s WebKit controller, tabs, popup windows, independent persistent profiles, Keychain cookie snapshots, close/quit handling, and profile deletion. Its overrides provide Teams defaults, Safari identification, and recovery from saved Teams rejection pages. The generic browser applies no Teams identification or URL rewriting. Existing Browser instances remain Browser instances; create a Teams instance for Teams-specific behavior.

The Teams plugin identifies desktop WebKit using the installed Safari version, including in login popups. Generic WKWebView identification omits Safari’s browser/version tokens, which can cause Teams to reject it before sign-in. Saved Teams “unsupported browser” pages are retried from the Teams entry point when the instance reopens. Existing profiles and login cookies are retained. An isolated comparison on macOS 14.2.1/Safari 17.2.1 reproduced the rejection with generic WebKit and reached Microsoft sign-in with Safari identification; authenticated chats and calls were not tested.

This changes browser identification, not the underlying WebKit engine. Keep Safari/macOS updated for compatibility with evolving websites. Microsoft officially supports the [latest two Safari versions for Teams](https://learn.microsoft.com/en-us/microsoftteams/teams-client-web).

## Text editor instances

Choose **Add Text Editor** in a project, give it a name, and choose its folder. Opening its instance directly under its project opens an instance tab containing a resizable split view: the folder’s files and subfolders on the left, and file tabs plus the editor on the right.

Click a file to open it. Reopening the same file selects its existing tab; files with the same name in different subfolders stay separate. Every file keeps its own undo history, caret, and scroll position while switching files, editor instances, or projects. Modified files show a dot in their tab. Each instance has independent buffers, even if two instances use the same folder.

The native AppKit text control provides selection, copy/paste, undo/redo, and a find/replace bar. The editor adds monospaced text, line numbers, basic syntax coloring for common programming languages, four-space Tab insertion, automatic continuation of indentation, and a path/encoding/caret status bar. New lines preserve CRLF when the file uses it. Syntax coloring is deliberately approximate and is disabled above 100,000 characters.

- **Save**: ⌘S. **Save All** in this instance: ⌥⌘S.
- **Find / Replace**: ⌘F; expand the native find bar to use replacement.
- **Undo / Redo**: ⌘Z / ⇧⌘Z.
- **Close the focused file**: ⌘W, or its tab’s close button.
- **New file**: the folder pane’s plus button, or a subfolder’s context menu. Existing files are never overwritten by creation.
- **Reload from Disk** and **Reveal in Finder**: a file tab’s context menu.
- **Refresh files**: the folder pane’s refresh button. Directory contents load when expanded; hidden files are included.

Closing a dirty file, closing/deleting an editor instance, changing its folder, or quitting asks **Save / Don’t Save / Cancel** for each modified file. A cancellation keeps the remaining buffers open; a save error keeps the edited text and blocks the close. Cancelling a later prompt does not discard files from earlier prompts. Files already saved stay saved. Renaming an instance keeps its open files; changing its folder closes its current runtime after approval. Deleting an editor definition never deletes its folder or source files.

UTF-8 (with or without BOM) and UTF-16 with a little/big-endian BOM are supported, with the original encoding preserved. Binary and unsupported encodings are rejected without opening an editable buffer. Files are limited to 10 MB. Saving compares the current disk bytes with the version originally loaded, rejects external changes/removals, then writes atomically and preserves Unix permissions. On a conflict, the local buffer remains available to copy/compare; **Reload from Disk** explicitly discards it after confirmation. Changes made by another editor instance use the same conflict check.

The instance’s name and folder are persisted in workspace metadata. Open files, unsaved buffers, undo history, and the editor’s pane/tab layout last for the running application session. There is no crash recovery or background autosave. The file tree refreshes manually; external file content changes require reload. Symlinks resolving outside the configured folder cannot be opened, and symlink directories are not traversed. File/folder rename/delete, language servers, completion, multi-cursor editing, and Sublime packages are outside this basic editor.

## Image viewer instances

Choose **Add Image Viewer** in the project menu, toolbar, or overview, then configure a name and folder. The left pane shows the folder tree and supported image files. Click a folder name to show its image thumbnails, or expand the disclosure arrow to browse its children. Images use natural filename order (for example, image2 before image10).

Click a thumbnail or image in the tree to open it. The image initially fits fully inside the right pane, keeping its aspect ratio and enlarging small images. Scroll the mouse wheel or trackpad to zoom around the pointer; drag with the left mouse button to pan. Press **←** and **→** to browse the previous or next image in that directory. Navigation stops at either end. **Fit to Pane** resets zoom and pan; **Directory** returns to the thumbnail grid.

Thumbnails decode in the background with a bounded cache. Supported formats come from macOS ImageIO, including PNG and JPEG; animated files show their first frame. Unsupported files are omitted and damaged images show an error. The viewer is read-only, and symlinks are omitted from the tree. Refresh reloads the listings and previews. The instance name and configured folder persist with the project; current selection and zoom are temporary. Closing or deleting an instance leaves image files intact.

## Build and launch

From the repository directory:

```sh
./macos/scripts/build-app.sh
open "$HOME/Applications/Async Dev Studio.app"
```

Apple Command Line Tools with Swift 5.10 or later are sufficient. Full Xcode is optional; open `macos/Package.swift` to work on the package there. The first build downloads pinned Swift packages, so it requires GitHub access. Subsequent builds use cached dependencies.

The script builds an optimized executable in a standard macOS `.app` bundle, applies an ad-hoc development signature, and installs it into `~/Applications/Async Dev Studio.app`. Each build stages and verifies the complete bundle before replacing the installed version. The build copy remains in `macos/.build`. Distribution signing and notarization are not configured. Internal app modules are compiled into the product executable; platform frameworks and third-party dependencies follow their own linking model. SwiftTerm's MIT license and the Teams icon attribution are included in the bundle's resources. The build script also installs the Teams image resource bundle. Build output stays in the ignored `macos/.build` directory.

## Tests

```sh
./macos/scripts/test.sh
```

Tests are a Swift executable with assertions and a nonzero exit code on failure, so they work without XCTest or full Xcode. Use this script rather than `swift test`. Project, terminal, browser, and editor behavior tests were written before their implementation. The default suite has 69 tests. Opt-in WebKit integration tests verify the Teams Safari identity visible to JavaScript and browser profiles across process restarts:

```sh
STUDIO_WEBKIT_INTEGRATION=1 ./macos/scripts/test.sh
```

The integration test creates temporary named WebKit profiles and fake cookies in Keychain, verifies restoration in a separate process, checks profile isolation, and deletes its test data. It needs access to the user’s WebKit and Keychain storage. It does not log into a real service.

Native editor integration tests run against hidden AppKit controls and temporary files to check editing, separate per-file undo/redo, and indentation/CRLF handling:

```sh
STUDIO_EDITOR_NATIVE_TESTS=1 ./macos/scripts/test.sh
```

The default suite plus native editor checks passes all 71 tests. Enable both integration flags to run all 73 tests.

Coverage includes project rename validation and identity preservation, rename/delete persistence, failed-save rollback, tab and selection behavior, retaining source files during deletion, restart cancellation, launch failures, target validation, waiting for the old process to exit, exact executable and bundle locations (including paths with shell metacharacters), project creation and validation, persistence and storage failures, legacy workspace compatibility, plugin registration, independent terminal definitions, configuration/rename/delete, tab identity and project switching, actual interactive PTY input/output, resize, startup once, working-directory handling, initialization failure, foreground-process shutdown, next-start configuration, and executable launch failure. Teams coverage includes inheritance, defaults and validation, isolation from generic browser policy, independent instance persistence, icon packaging, Safari version metadata validation, and error-page recovery. Browser coverage includes URL validation, stable profile identity, cookie security/expiry, restore ordering, logout, isolation, persistence failures, concurrent logout during close, and last-page restoration. Editor coverage includes folder validation and definition persistence, lazy tree listing, path/symlink containment, independent file tabs, dirty-state tracking, save/discard/cancel, external-edit conflicts, reload, encoding/BOM preservation, binary rejection, non-overwriting new files, write failures, executable permissions, and cancellation of a workspace close.

Tests use temporary files and short-lived `/bin/sh` sessions without modifying the normal workspace. The optimized app bundle builds successfully; interactive UI inspection was unavailable because the computer-use service could not start. The PTY and session checks run against real local processes rather than a mocked terminal.

## Microkernel structure

```text
Sources/StudioPlatform/        Native application restart coordination and process launcher
Sources/StudioKernel/          Projects, generic app instances, registry, storage
Sources/StudioPresentation/    Main-actor workspace state and tab routing
Sources/TerminalPlugin/        Configuration, PTY sessions, emulator views, runtime factory
Sources/ClaudePlugin/          Terminal subclass, Claude launch policy and session metadata
Sources/CodexPlugin/           Terminal subclass, Codex launch policy and session metadata
Sources/EditorPlugin/          Folder/file models, atomic text storage, AppKit editor, nested tree/tabs
Sources/ImagePlugin/           Folder browser, thumbnail grid, ImageIO loading, native zoom/pan canvas
Sources/TeamsPlugin/           Browser subclass, Teams compatibility policies, official icon resource
Sources/BrowserPlugin/         WebKit views, isolated profiles, Keychain snapshots, navigation storage
Sources/PTYSupport/            Small C bridge for async-signal-safe fork/exec and PTY operations
Sources/AsyncDevStudio/        SwiftUI shell and platform composition root
Tests/                        Behavioral and PTY integration tests
ThirdParty/                   Dependency notices
scripts/                      Test and application-bundle build commands
```

`StudioKernel` depends only on Foundation. `AppPlugin` provides a descriptor and configuration validation; `PluginRegistry` registers built-in implementations explicitly. Generic instance definitions store opaque configuration, keeping terminal, browser, and editor behavior outside the kernel. The terminal module uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm/tree/v1.5.1) for AppKit rendering and terminal emulation; our PTY session handles shell launch, input/output, resize, and bounded shutdown. SwiftTerm 1.5.1 is pinned for compatibility with Swift 5.10. Its demo dependency, Swift Argument Parser, is pinned to 1.5.0 but is not linked into the application.

The shell registers all seven plugins at startup and composes its native configuration and runtime views. There is no dynamic product plugin discovery or separately installed product plugin binary. Every instance owns an independent controller; view selection does not start another shell.

`ProjectStore` is an injected kernel service. The initial workspace uses an atomic JSON file instead of the architecture's proposed SQLite store. Definitions are saved at:

```text
~/Library/Application Support/AsyncDevStudio/projects.json
```

The storage document now writes version 2, while still reading existing version-1 documents. Projects without an `instances` field load with an empty list. Each instance stores an ID, app type, name, and encoded configuration data; JSON represents the opaque data as Base64. Each plugin’s configuration is versioned JSON. Older builds that only accept document version 1 will reject the updated workspace instead of silently discarding terminal definitions.

Corrupt or unsupported workspace files produce a startup error rather than being overwritten. Create/update/delete commands publish changes only after saving succeeds. Terminal processes, terminal output, and tab layout are not persisted: after restart, definitions remain in the tree and opening an instance starts a fresh shell. No startup commands run solely because the app launches.

Browser definitions use the same version-2 workspace document with app type `browser` and versioned URL configuration. WebKit manages website storage in its platform-owned data directories; instance UUIDs address those profiles through its public API. Cookie snapshots are stored in macOS Keychain under service `dev.asyncstudio.browser.session-cookies` and the instance UUID, with device-only accessibility. Credentials are not written into `projects.json`. Last-page URLs are separate atomic JSON files under `~/Library/Application Support/AsyncDevStudio/BrowserNavigation/`. An ad-hoc development build may trigger Keychain access prompts after rebuilding; distribution signing should use a stable signing identity.

## Current limits

Projects can be hidden using **Archive** in their context menu. **File → Show Archived Project** is a checkable setting, remembered across launches, that includes archived projects in the sidebar with an archive icon. Their context menu offers **Restore** to remove the archive flag. Archiving preserves definitions, open tabs, editor buffers, browser profiles, and running terminal sessions. Hiding the selected project selects another visible project when available. The archive flag is saved atomically in `projects.json`; older projects default to unarchived, and renaming preserves the flag.

Clicking inside a terminal restores its native keyboard focus, including after another control has taken focus. This does not depend on SwiftUI rebuilding the selected tab.

The build and test scripts run `prepare-dependencies.sh` after resolving packages. It corrects SwiftTerm 1.5.1's selection extraction and duplicated scrollback offset, records the initial mouse-down position for precise dragging, preserves selection across unrelated output, and supports Shift-drag selection when applications request mouse reporting. Selection follows retained buffer lines through scrollback rollover and clears when selected text is changed, evicted, or the active buffer changes. The patches are idempotent and fail if source no longer matches; review them when upgrading SwiftTerm. For native terminal selection, keyboard, and clipboard checks, run `STUDIO_TERMINAL_NATIVE_TESTS=1 scripts/test.sh` with macOS clipboard access. The clipboard test restores existing contents. Select terminal text and use **Command-C**, **Edit → Copy**, or right-click **Copy**. Hold **Shift while dragging** when a terminal program uses the mouse.

Terminal output and open-tab layout are retained only during the running application session. Startup-command input treats each nonempty line as a command; use a script file for multiline constructs. Detached jobs which deliberately leave the shell's session are outside managed terminal shutdown. Terminal escape sequences cannot write the clipboard automatically; user-initiated copy/paste is supported.

The small JSON store saves synchronously on the main actor. Concurrent application processes sharing a workspace are unsupported; use normal `open` to reuse the application rather than `open -n`. This development build runs shells with the user's normal permissions and does not enable an application sandbox.

### Shared terminal scrolling

Every `TerminalAppPlugin` subclass uses the same terminal controller and wheel handling. With mouse reporting off, the wheel and trackpad scroll the emulator’s history. When a program requests mouse input, wheel-up/down events are sent to that program so it can scroll its own interface. **Shift-scroll** bypasses reporting and scrolls local history, including macOS’s Shift-wheel horizontal-axis mapping. Alternate-screen programs have no native scrollback; their own mouse or keyboard navigation controls their history. Codex starts with `--no-alt-screen` so its transcript remains in the normal terminal buffer.

### Shared terminal text encoding

All terminal plugins send and render UTF-8 text. Shell startup validates the effective character encoding from `LC_ALL`, `LC_CTYPE`, and `LANG`, using locale objects without changing the app’s global locale. Existing valid UTF-8 settings are preserved. Missing, invalid, or legacy encodings are replaced with a valid UTF-8 locale, retaining the region where possible and falling back to `en_US.UTF-8`. This includes Finder launches with no locale variables. The shared native terminal accepts both plain and attributed text from macOS input methods. Restart existing terminal sessions after upgrading to apply the shell environment change; user shell configuration can still override these startup settings.

### Folder selection in configuration sheets

Terminal, Claude, Codex, Text Editor, and Image Viewer configurations share an asynchronous native folder picker. The Choose button opens the picker as a sheet on its own configuration window, without a nested blocking modal loop or reliance on the app’s key window. Repeated clicks cannot open duplicate pickers. Cancel leaves the configured path unchanged, and dismissing the configuration cancels its picker and ignores late callbacks. Run `STUDIO_PICKER_NATIVE_TESTS=1 scripts/test.sh` for native window-ownership, cancellation, stale-callback, and disabled-control tests. The tests use a controlled panel presenter; an interactive system-dialog check is separate.
