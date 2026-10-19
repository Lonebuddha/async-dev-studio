# Repository instructions

## Deliver builds ready for testing

When the requested changes are implemented, the relevant checks pass, and a build is ready for the user to test, commit and push the changes to the remote repository in the same turn, before reporting completion. Do not ask for additional confirmation unless the user explicitly requests a different workflow.

- Include the source code, tests, documentation, and build configuration relevant to the completed work.
- Exclude generated build outputs, local application state, credentials, and unrelated changes.
- Push the current branch to its configured upstream. If it has no upstream, push it to `origin` under the same branch name and set the upstream.
- Never force-push or overwrite remote work. If pushing fails, preserve the local commit and report the blocker clearly.
- In the final response, identify the pushed commit and explain how the user can test the build. If the build or required checks fail, report that it is not ready for testing.
