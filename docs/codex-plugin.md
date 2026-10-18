# Codex plugin

The compiled-in macOS Codex plugin inherits `TerminalAppPlugin`, alongside Terminal and Claude. It uses the same PTY, emulator, clipboard, selection, tabs, configuration-on-next-start, and shutdown behavior. Its opaque configuration contains version 1, shell, and working directory. The user configures a name and folder, with no Startup commands field.

A new instance starts `codex --dangerously-bypass-approvals-and-sandbox`. A saved instance starts `codex resume <session UUID> --dangerously-bypass-approvals-and-sandbox`. This matches Claude's unrestricted startup policy. The login shell supplies the executable PATH, environment, and authentication normally used by Codex CLI. The plugin does not select a model, provision credentials, or make API requests itself.

## Session persistence

The CLI receives a process-local `-c notify=[...]` override. Its documented `agent-turn-complete` notification includes a thread ID and working directory. A generated private callback script, interpreted by macOS `/bin/sh`, uses the built-in `plutil` to extract those fields and atomically replace the instance's record. Prompts and assistant text are discarded. No additional product executable, Python installation, terminal-output scraping, session directory scanning, or hook-trust bypass is required.

Metadata lives at `~/Library/Application Support/AsyncDevStudio/CodexSessions/<instance UUID>/session.json`; the generated `notify.sh` is beside it. The folder is created with mode 700, files with mode 600. Codex retains its own history in its normal location, and the plugin preserves the existing Codex home and authentication. No global Codex configuration is edited. The callback replaces any configured external `notify` handler for this process; built-in terminal notifications remain available.

On each start, the plugin validates the saved UUID and compares canonical working directories. It resumes that explicit ID only for the same folder. Two instances using the same folder have separate records; neither uses `resume --last`. Changing folder starts a fresh conversation, and the first completed response updates the record. `/new` or interactive session switching is recorded on the next completed response.

A conversation interrupted before its first completed response has no newly recorded ID. Once recorded, the ID survives tab closure, app shutdown, restart, and forced termination. An interruption immediately after starting a different conversation can leave the previous recorded conversation selected. Deleting CLI history can make a saved ID unavailable; Codex presents its normal error rather than the plugin silently selecting an unrelated conversation. Corrupt metadata is reported as a startup error. Removing an instance does not delete its metadata or CLI history.

## Verification

Behavioral tests launch a local CLI fixture through the real PTY and invoke the actual generated callback. They cover CLI arguments, explicit resume across process recreation, instance isolation in the same folder, folder changes, shell quoting for paths containing spaces and apostrophes, file permissions, minimal metadata, malformed notifications, corrupt records, and configuration validation. Existing terminal tests cover shared native behavior. These tests do not make model requests.

The Homebrew CLI installed during development (`/opt/homebrew/bin/codex`, linked to version 0.106.0) was killed with exit status 137 even for `--version`, both within and outside the sandbox. Live CLI startup could not be verified; the cause needs investigation before live use can be confirmed.

References: [Codex CLI arguments](https://learn.chatgpt.com/docs/developer-commands?surface=cli), [Codex notification configuration](https://learn.chatgpt.com/docs/config-file/config-advanced#notifications).
