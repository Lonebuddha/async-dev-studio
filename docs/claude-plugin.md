# Claude plugin for macOS

Create a Claude instance with **Add Claude** in the project context menu, toolbar, or overview. Configure its name, shell, and working folder. Claude Code must be installed and available on the login shell's PATH. Its normal sign-in applies.

## Shared terminal implementation

`TerminalPlugin` and `ClaudePlugin` inherit `TerminalAppPlugin`, the extensible terminal base. They share one runtime, controller, native emulator, PTY implementation, input/selection/copy/paste behavior, tabs, resizing, stop/start, close, and application shutdown handling. The kernel still stores opaque plugin configuration. Both implementations are compiled into the product executable.

Normal Terminal instances retain their existing configuration and Startup commands. Claude configuration contains only a version, shell, and working folder; it has no configurable startup commands. Its launch policy runs:

```sh
claude --permission-mode bypassPermissions
```

The actual command also supplies session-tracking hook settings and adds `--resume <session-id>` when there is a saved conversation to restore. It uses `exec` after login-shell initialization, so exiting Claude ends the terminal session. **Start** relaunches Claude using the latest saved metadata and configuration.

## Remembering the conversation

The plugin uses Claude's documented [SessionStart hook](https://code.claude.com/docs/en/hooks#sessionstart), whose structured input includes `session_id`, `transcript_path`, and `cwd`. It does not parse ANSI terminal output or depend on the exit notice being printed. Capturing at startup also retains the identifier if the application later stops the CLI before an exit notice appears. SessionStart also tracks `/clear` and `/resume` conversation changes.

The hook is supplied using the CLI's `--settings` option and does not change global or project Claude settings. A unique temporary file and atomic rename publish metadata at:

```text
~/Library/Application Support/AsyncDevStudio/ClaudeSessions/<instance UUID>/session.json
```

Directories use private permissions and record files use mode 0600. Separate instances keep separate records, even in the same working folder. Renaming and archiving preserve instance identity and its record. Claude manages its own conversation transcripts; the application stores only hook metadata, not a second copy of conversations. Deleting an instance removes its definition and stops its process; the metadata record and Claude-owned history are retained and are not reused by newly created instances with different IDs.

At each fresh start, the plugin reads the latest record and uses [`--resume <session-id>`](https://code.claude.com/docs/en/cli-reference) if the folder matches and the transcript exists and is nonempty. Exiting an empty conversation may leave no transcript; a new conversation then starts. A removed transcript also causes a new conversation. Changing the working folder starts a new conversation there. Corrupt or unreadable metadata is shown as a startup error rather than selecting an unrelated conversation. Claude hooks must remain enabled for recording session changes.

## Verification

The installed Claude Code 2.1.231 CLI help was checked for `--permission-mode`, `--settings`, and `--resume`. Automated tests use a controlled local CLI fixture to exercise the actual generated hook command through a PTY, persist metadata, stop and recreate processes, resume by ID, isolate multiple instances, change folders, and report invalid metadata. They make no paid model requests. Native tests additionally exercise the shared controller and terminal regressions.
