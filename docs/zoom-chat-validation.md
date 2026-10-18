# Zoom chat validation

Status: the API design has been researched; the user's account and target group have **not** been validated. The user has their own Zoom account and no Marketplace app yet. The available browser is not signed in.

## Create a test app

1. Sign in at [Zoom Marketplace](https://marketplace.zoom.us/) with the account that belongs to the target group.
2. Create a General App and choose user-managed authorization. Keep it private for this account.
3. In App Credentials, enable **Use Public Client OAuth** and copy the development **Public Client ID**, not the normal confidential Client ID or secret.
4. Register `http://127.0.0.1:8765/callback` as an OAuth redirect and in the redirect allow list. Zoom's PKCE loopback flow ignores the port when matching, so the checker uses a temporary port.
5. Add these granular scopes: `team_chat:read:list_user_sessions`, `team_chat:read:list_user_messages`, `team_chat:write:user_message`. For private named channels rather than group conversations, discovery may also need `team_chat:read:list_user_channels`.
6. Complete the required app information and enable local testing. Record any policy or account-plan error rather than changing the account plan or encryption settings.

The Public Client ID can be shared for this check. Keep passwords, client secrets, tokens, and authorization codes out of chat and repository files.

## Run the read-only check

From the repository root:

```sh
python3 macos/scripts/check-zoom-chat.py --client-id PUBLIC_CLIENT_ID
```

The checker opens the default browser for consent. Credentials remain in memory; nothing is persisted. It lists group-session names and IDs from the last 30 days. A group missing from those results is inconclusive: an inactive group or named channel may need separate discovery.

Then choose the exact group name and a date when you know it contained messages:

```sh
python3 macos/scripts/check-zoom-chat.py --client-id PUBLIC_CLIENT_ID --group 'Exact group name' --date YYYY-MM-DD --compare-message
```

If needed, use `--channel-id` instead of `--group`. Responses are paginated with a bounded number of requests. Message bodies, tokens, and raw error responses are never printed or written. A successful empty response proves request access only. The placeholder counter is a heuristic; it does not prove plaintext availability. With `--compare-message`, privately paste a known single-line message at the hidden local terminal prompt. The checker reports whether that exact text was returned without displaying it or sending it to Zoom.

## Evidence still needed

| Constraint | Evidence required | Current result |
| --- | --- | --- |
| Account eligibility and app policy | App creation, user consent, successful API request | Not tested |
| Desktop authorization | Public-client PKCE token exchange | Checker prepared; not run live |
| Target group access | Exact group ID and successful history request | Not tested |
| Readable content | Known recent message returned as readable text, not encrypted placeholder | Not tested |
| Sending | Granted write scope and an explicitly approved test message delivered to the target group | Not tested |
| History depth | Requests for dates with known messages; account retention settings | Not tested |
| Staying signed in | Refresh-token exchange and secure credential persistence across restart | Not tested |

The checker has no chat write operation. A write scope alone does not prove delivery permission. Choose the exact text and target group before sending any live test message. Message delivery has no read-only equivalent.

## Sources and constraints

- [OAuth and loopback redirects](https://developers.zoom.us/docs/integrations/oauth/): public-client PKCE supports desktop authorization without a shared secret or backend.
- [Chat API](https://developers.zoom.us/docs/api/chat/): group sessions expose a channel ID; user-level history and sending use `me`. The history endpoint documents a six-month retrieval limit. Retention and membership can further affect available history.
- [Granular scopes](https://developers.zoom.us/docs/integrations/oauth-scopes-granular/): use current-user scopes rather than administrator scopes.
- [Chat API overview](https://developers.zoom.us/docs/api/rest/chat-api/): the getting-started prerequisites specify Pro or higher; actual account eligibility remains to be checked.
- [Advanced Chat Encryption](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0065662): ACE-protected historical messages can remain encrypted placeholders in API responses even after ACE is disabled. Do not change encryption to make a test pass.
- [Private app distribution](https://developers.zoom.us/docs/distribute/sharing-private-and-beta-apps/): private app access is restricted; sharing with other accounts needs the appropriate Zoom approval.
- [WebSockets](https://developers.zoom.us/docs/api/websockets/): events are account-level and use secret-based authentication. Start with periodic REST refreshes for a desktop-only user integration.
