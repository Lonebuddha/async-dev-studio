import Foundation

// A small runner keeps behavioral tests executable with Command Line Tools alone.
private struct AssertionFailure: Error, CustomStringConvertible {
    let description: String
}

func expectTrue(_ value: Bool, file: String = #filePath, line: Int = #line) throws {
    if !value { throw AssertionFailure(description: "\(file):\(line): expected true") }
}
func expectFalse(_ value: Bool, file: String = #filePath, line: Int = #line) throws {
    try expectTrue(!value, file: file, line: line)
}
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: String = #filePath, line: Int = #line) throws {
    if actual != expected { throw AssertionFailure(description: "\(file):\(line): \(actual) != \(expected)") }
}
func expectNotEqual<T: Equatable>(_ actual: T, _ expected: T, file: String = #filePath, line: Int = #line) throws {
    try expectTrue(actual != expected, file: file, line: line)
}
func expectNil<T>(_ value: T?, file: String = #filePath, line: Int = #line) throws {
    try expectTrue(value == nil, file: file, line: line)
}
func expectNotNil<T>(_ value: T?, file: String = #filePath, line: Int = #line) throws {
    try expectTrue(value != nil, file: file, line: line)
}
func expectThrows<T>(_ expression: @autoclosure () throws -> T,
                     file: String = #filePath, line: Int = #line,
                     verify: (Error) throws -> Void = { _ in }) throws {
    do { _ = try expression() }
    catch { try verify(error); return }
    throw AssertionFailure(description: "\(file):\(line): expected an error")
}

@main
struct Runner {
    @MainActor static func main() async {
        if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--fake-codex" {
            do { try CodexTests.fakeCLI(arguments: Array(CommandLine.arguments.dropFirst(2))) }
            catch { print("Fake Codex failed: \(error)"); exit(1) }
            return
        }
        if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--fake-claude" {
            do { try ClaudeTests.fakeCLI(arguments: Array(CommandLine.arguments.dropFirst(2))) }
            catch { print("Fake Claude failed: \(error)"); exit(1) }
            return
        }
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--browser-probe",
           let id = UUID(uuidString: CommandLine.arguments[3]) {
            do { try await BrowserIntegrationTests.probe(operation: CommandLine.arguments[2], id: id) }
            catch { print("Browser probe failed: \(error)"); exit(1) }
            return
        }
        let kernel = ProjectKernelTests()
        let management = ProjectManagementTests()
        let disk = JSONProjectStoreTests()
        let ui = WorkspaceModelTests()
        let terminal = TerminalTests()
        let browser = BrowserTests()
        let teams = TeamsTests()
        let editor = EditorTests()
        let restart = RestartTests()
        var tests: [(String, () async throws -> Void)] = [
            ("image viewer sorted navigation and refresh", { try ImageTests().testListingNavigationAndRefresh() }),
            ("image viewer decoding and thumbnails", { try ImageTests().testDecodingThumbnailsAndCorruptFiles() }),
            ("image viewer fit, anchored zoom and pan", { try ImageTests().testFitZoomAndPan() }),
            ("image viewer persistence and runtime isolation", { try ImageTests().testConfigurationPersistenceAndRuntimeIsolation() }),
            ("Codex configuration and shared terminal base", { try CodexTests().testConfigurationAndValidation() }),
            ("Codex per-instance resume across process restart", { try await CodexTests().testSessionIsolationAndRestart() }),
            ("Codex notification validation", { try CodexTests().testNotificationRejectsOtherEventsAndMalformedInput() }),
            ("Claude configuration and terminal base", { try ClaudeTests().testConfigurationAndSharedBase() }),
            ("Claude session resume across process restart", { try await ClaudeTests().testNewSessionAndResumeAcrossStoreAndProcessRestart() }),
            ("Claude empty and corrupt session records", { try await ClaudeTests().testEmptyAndCorruptSessionRecords() }),
            ("Claude definitions persistence", { try await ClaudeTests().testClaudeDefinitionsPersist() }),
            ("archive persistence and rename", { try ProjectArchiveTests().testArchiveRestoreAndRenamePersist() }),
            ("legacy project archive compatibility", { try ProjectArchiveTests().testLegacyProjectDefaultsToUnarchived() }),
            ("archive storage rollback", { try ProjectArchiveTests().testArchiveFailureKeepsSelectionAndTabs() }),
            ("archive visibility and retained tabs", { try ProjectArchiveTests().testArchiveVisibilityAndRetainedTabs() }),
            ("all archived and delete selection", { try ProjectArchiveTests().testAllArchivedAndDeletionSelection() }),
            ("live process memory", { try MemoryTests().testReadsLiveProcessMemory() }),
            ("restart cancellation and ordinary quit", { try restart.testCancelAndOrdinaryQuitNeverScheduleRestart() }),
            ("restart launch failure", { try restart.testLaunchFailureCanCancelAndRetry() }),
            ("restart target validation", { try restart.testRejectsMissingTargetAndInvalidPID() }),
            ("restart bundle location", { try await restart.testBundleRelaunchUsesItsExactLocation() }),
            ("restart waits for exit and exact path", { try await restart.testWaitsForExitAndLaunchesExactExecutablePath() }),
            ("project rename identity and persistence", { try management.testRenamePreservesIdentityInstancesAndPersists() }),
            ("project rename validation", { try management.testRenameValidatesNamesAndAllowsSameProjectName() }),
            ("project mutation storage rollback", { try management.testFailedRenameAndDeletePreserveWorkspace() }),
            ("project deletion persistence and source files", { try management.testDeletePersistsAndDoesNotTouchSourceFiles() }),
            ("project rename retains tabs", { try management.testRenameKeepsActiveProjectAndTabs() }),
            ("project deletion selection and tabs", { try management.testDeleteSwitchesSelectionAndClearsOnlyDeletedTabs() }),
            ("project deletion failure keeps tabs", { try management.testFailedDeletePreservesSelectionAndOpenTabs() }),
            ("inactive project deletion", { try management.testDeletingInactiveProjectKeepsCurrentSelection() }),
            ("empty workspace", { try kernel.testFirstWorkspaceIsEmpty() }),
            ("create and save", { try kernel.testCreatesProjectWithNameAndSavesIt() }),
            ("trim name", { try kernel.testTrimsSurroundingWhitespace() }),
            ("reject empty names", { try kernel.testRejectsEmptyNamesWithoutSaving() }),
            ("reject duplicate names", { try kernel.testRejectsDuplicateNamesWithoutChangingProjects() }),
            ("independent identities", { try kernel.testMultipleProjectsHaveIndependentIdentities() }),
            ("save rollback", { try kernel.testSaveFailurePreservesExistingWorkspace() }),
            ("load failure", { try kernel.testLoadFailureIsReported() }),
            ("missing storage", { try disk.testMissingFileMeansEmptyWorkspace() }),
            ("restart persistence", { try disk.testProjectsSurviveNewKernelAndStore() }),
            ("corrupt storage", { try disk.testCorruptFileIsReportedAndNotOverwritten() }),
            ("unsupported version", { try disk.testUnsupportedStorageVersionIsRejected() }),
            ("create and select", { try await ui.testCreateSelectsNewProjectAndClosesForm() }),
            ("cancel creation", { try await ui.testCancelCreatesNothingAndClearsDraftOnNextAttempt() }),
            ("invalid form", { try await ui.testInvalidNameKeepsFormOpenAndShowsError() }),
            ("retry save", { try await ui.testFailedSaveKeepsDraftAndAllowsRetry() }),
            ("plugin registration", { try terminal.testRegistryRejectsDuplicateTypes() }),
            ("independent terminal definitions", { try terminal.testKernelStoresIndependentInstances() }),
            ("invalid terminal definitions", { try terminal.testInvalidConfigurationAndUnknownPluginAreNotSaved() }),
            ("terminal save rollback", { try terminal.testInstanceSaveFailureDoesNotPublish() }),
            ("old workspace compatibility", { try terminal.testOldProjectDocumentStillLoads() }),
            ("terminal persistence", { try terminal.testInstancesSurviveRestart() }),
            ("tab identity and project switching", { try await terminal.testOpeningReusesTabAndProjectsKeepSeparateTabs() }),
            ("interactive PTY and resize", { try await terminal.testInteractivePTYAndResize() }),
            ("startup once and working directory", { try await terminal.testStartupRunsOnceAndUsesWorkingDirectory() }),
            ("startup preserves interactive environment and functions", { try await terminal.testStartupKeepsInteractiveShellState() }),
            ("startup failure", { try await terminal.testStartupFailureEndsSession() }),
            ("terminal shutdown", { try await terminal.testStopCleansUpShellAndForegroundProcess() }),
            ("configure rename and delete", { try terminal.testConfigureRenameAndDeletePersistWithoutChangingIdentity() }),
            ("configuration next start", { try await terminal.testConfigurationChangesWaitForNextStart() }),
            ("exec failure", { try await terminal.testExecFailureHasNoLiveProcess() }),
            ("Teams error-page recovery", { try teams.testRestoringTeamsRejectionPageRetriesWithoutChangingOtherPages() }),
            ("Teams Safari identity", { try teams.testSafariIdentityUsesActualVersionAndRejectsInvalidMetadata() }),
            ("Teams browser inheritance and defaults", { try teams.testTeamsInheritsBrowserValidationAndDefinesOwnDefaults() }),
            ("generic browser policy isolation", { try teams.testGenericBrowserHasNoTeamsPolicy() }),
            ("Teams and browser independent persistence", { try teams.testTeamsAndBrowserDefinitionsPersistIndependently() }),
            ("Teams icon resource", { try teams.testTeamsIconIsBundled() }),
            ("browser URL validation", { try browser.testBrowserConfigurationRejectsUnsafeURLs() }),
            ("browser instance persistence", { try browser.testBrowserInstancesPersistWithStableProfileIDs() }),
            ("session cookie attributes", { try browser.testCookieSnapshotPreservesSessionAndSecurityAttributes() }),
            ("cookie expiry", { try browser.testExpiredCookiesAreNotResurrectedAndPersistentExpiryIsPreserved() }),
            ("session restore and logout", { try await browser.testRestoresCookiesBeforeLoadingAndLogoutClearsSnapshot() }),
            ("browser profile isolation", { try await browser.testProfileSnapshotsAreIsolatedAndPreparationIsIdempotent() }),
            ("browser persistence failure", { try await browser.testStorageFailureIsReportedAndNotSilentlyIgnored() }),
            ("concurrent logout checkpoint", { try await browser.testCloseCheckpointWaitsForConcurrentLogout() }),
            ("last URL persistence", { try browser.testLastURLRestoresPerInstanceAndRejectsUnsafeSavedURL() }),
            ("editor folder configuration", { try editor.testConfigurationAndInstancePersistence() }),
            ("editor file tree and containment", { try editor.testDirectoryListingAndSymlinkContainment() }),
            ("editor independent file tabs", { try editor.testTabsAndIndependentInstances() }),
            ("editor dirty state and save", { try editor.testDirtyStateAndSave() }),
            ("editor close decisions", { try editor.testSaveDiscardCancelOnClose() }),
            ("editor external edit protection", { try editor.testExternalChangesAndReload() }),
            ("editor encoding and binary rejection", { try editor.testEncodingAndBinaryRejection() }),
            ("editor new files", { try editor.testCreateFileWithoutOverwriting() }),
            ("editor save failures", { try editor.testSaveFailureKeepsDirtyTab() }),
            ("editor executable permissions", { try editor.testSavePreservesExecutablePermissions() }),
            ("editor cancelled workspace close", { try editor.testCancelledWorkspaceCloseKeepsDocuments() })
        ]
        if ProcessInfo.processInfo.environment["STUDIO_WEBKIT_INTEGRATION"] == "1" {
            tests.append(("WebKit Teams Safari identity", { try await teams.testSafariIdentityIsVisibleToWebKitJavaScript() }))
            tests.append(("WebKit and Keychain process restart", { try await BrowserIntegrationTests().testProfileSurvivesProcessRestart() }))
        }
        if ProcessInfo.processInfo.environment["STUDIO_EDITOR_NATIVE_TESTS"] == "1" {
            tests.append(("native editor undo and tabs", { try editor.testNativeEditingKeepsUndoSeparateAcrossTabs() }))
            tests.append(("native editor indentation and CRLF", { try editor.testNativeIndentationAndCRLF() }))
        }
        if ProcessInfo.processInfo.environment["STUDIO_IMAGE_NATIVE_TESTS"] == "1" {
            tests.append(("image viewer native canvas keyboard and fit", { try ImageTests().testNativeCanvasNavigationAndFit() }))
        }
        if ProcessInfo.processInfo.environment["STUDIO_TERMINAL_NATIVE_TESTS"] == "1" {
            tests.append(("Codex shared terminal runtime and resume", { try await CodexTests().testSessionIsolationAndRestart(nativeRuntime: true) }))
            tests.append(("Claude shared terminal lifecycle and reconfiguration", { try await ClaudeTests().testSharedRuntimeRestartsAndConfigurationChanges() }))
            let selection = TerminalSelectionTests()
            tests.append(("terminal inherited scrollback and application wheel events", { try selection.testWheelScrollingIsInheritedByAllTerminalPlugins() }))
            tests.append(("terminal click restores keyboard focus", { try selection.testClickRestoresKeyboardFocus() }))
            tests.append(("terminal selection scrollback and rollover", { try selection.testSelectionAfterScrollbackAndRollover() }))
            tests.append(("terminal selection during output and eviction", { try selection.testOutputPreservesSelectionUntilOverwrittenOrEvicted() }))
            tests.append(("terminal Shift selection in mouse reporting modes", { try selection.testShiftSelectionOverridesMouseReporting() }))
            tests.append(("terminal Command-C copies selection", { try terminal.testCommandCopyPreservesSelectionAndClipboard() }))
            tests.append(("terminal tab reattachment preserves screen and process", { try await terminal.testTabReattachmentPreservesScreenAndProcess() }))
        }
        var failures = 0
        if ProcessInfo.processInfo.environment["STUDIO_TERMINAL_SELECTION_RESEARCH"] == "1" {
            tests.append(("terminal selection research probe", { try SelectionResearch.run() }))
        }
        for (name, test) in tests {
            do {
                try disk.setUpWithError()
                defer { try? disk.tearDownWithError() }
                try await test()
                print("PASS: \(name)")
            } catch {
                failures += 1
                print("FAIL: \(name): \(error)")
            }
        }
        print("\(tests.count - failures)/\(tests.count) tests passed")
        if failures > 0 { exit(1) }
    }
}
