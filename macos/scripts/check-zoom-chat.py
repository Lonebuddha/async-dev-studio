#!/usr/bin/env python3
"""Read-only Zoom Team Chat feasibility check; credentials stay in memory."""
import argparse
import base64
import datetime as dt
import hashlib
import getpass
import http.server
import json
import secrets
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser

SCOPES = {
    "sessions": "team_chat:read:list_user_sessions",
    "history": "team_chat:read:list_user_messages",
    "sending": "team_chat:write:user_message",
}


def challenge(verifier):
    return base64.urlsafe_b64encode(hashlib.sha256(verifier.encode("ascii")).digest()).rstrip(b"=").decode("ascii")


def callback_result(path, expected_state):
    parsed = urllib.parse.urlsplit(path)
    query = urllib.parse.parse_qs(parsed.query)
    if parsed.path != "/callback":
        return None
    if query.get("state") != [expected_state]:
        return None
    if query.get("error"):
        return {"error": "Authorization was declined or failed."}
    codes = query.get("code", [])
    return {"code": codes[0]} if len(codes) == 1 and codes[0] else None


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def request_json(url, *, token=None, form=None):
    headers = {"Accept": "application/json"}
    data = None
    if token:
        headers["Authorization"] = "Bearer " + token
    if form is not None:
        data = urllib.parse.urlencode(form).encode("ascii")
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    request = urllib.request.Request(url, data=data, headers=headers)
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        # Never print raw responses, request URLs, tokens, or authorization codes.
        try:
            zoom_code = json.load(error).get("code")
        except (ValueError, AttributeError):
            zoom_code = None
        suffix = f", Zoom code {zoom_code}" if isinstance(zoom_code, int) else ""
        raise RuntimeError(f"Zoom request failed: HTTP {error.code}{suffix}.") from None
    except (urllib.error.URLError, ValueError):
        raise RuntimeError("Zoom request failed: connection or response error.") from None


def authorize(client_id):
    verifier = secrets.token_urlsafe(48)
    state = secrets.token_urlsafe(32)
    result = {}

    class Callback(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            value = callback_result(self.path, state)
            self.send_response(200 if value else 400)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Referrer-Policy", "no-referrer")
            self.end_headers()
            self.wfile.write(b"Return to Async Dev Studio's Zoom check." if value else b"Invalid callback.")
            if value:
                result.update(value)

    with http.server.HTTPServer(("127.0.0.1", 0), Callback) as server:
        server.timeout = 1
        redirect = f"http://127.0.0.1:{server.server_port}/callback"
        url = "https://zoom.us/oauth/authorize?" + urllib.parse.urlencode({
            "response_type": "code", "client_id": client_id,
            "redirect_uri": redirect, "state": state,
            "code_challenge": challenge(verifier), "code_challenge_method": "S256",
        })
        print("Opening your browser for Zoom authorization. This check never posts messages.", flush=True)
        if not webbrowser.open(url):
            raise RuntimeError("Could not open the browser. Set a default browser and retry.")
        deadline = time.monotonic() + 600
        while not result and time.monotonic() < deadline:
            server.handle_request()
        if not result:
            raise RuntimeError("Authorization timed out after ten minutes.")
        if "error" in result:
            raise RuntimeError(result["error"])
    return request_json("https://zoom.us/oauth/token", form={
        "grant_type": "authorization_code", "client_id": client_id,
        "code": result["code"], "redirect_uri": redirect, "code_verifier": verifier,
    })


def api_pages(resource, key, params, token):
    params = dict(params, page_size=100)
    seen = set()
    for _ in range(20):
        response = request_json("https://api.zoom.us/v2/chat/users/me/" + resource + "?" + urllib.parse.urlencode(params), token=token)
        yield from response.get(key, [])
        page = response.get("next_page_token")
        if not page:
            return
        if page in seen:
            raise RuntimeError("Zoom returned a repeated pagination token.")
        seen.add(page)
        params["next_page_token"] = page
    raise RuntimeError("More than 20 pages returned; narrow the date range and retry.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--client-id", required=True, help="Zoom Public Client ID; never a client secret")
    parser.add_argument("--group", help="Exact group name; omit to list recent group sessions")
    parser.add_argument("--channel-id", help="Group/channel ID if already known")
    parser.add_argument("--compare-message", action="store_true", help="Privately enter a known message to verify readable history")
    parser.add_argument("--date", type=dt.date.fromisoformat, default=dt.datetime.now(dt.timezone.utc).date(), help="History date in YYYY-MM-DD (default: today UTC)")
    args = parser.parse_args()
    tokens = authorize(args.client_id)
    token = tokens.get("access_token")
    if not token:
        raise RuntimeError("Zoom did not return an access token.")
    print("PASS: public-client PKCE authorization.")
    print("Refresh credential returned: " + ("yes" if tokens.get("refresh_token") else "no") + "; refresh/restart persistence not tested.")
    granted = set(tokens.get("scope", "").split())
    for label, scope in SCOPES.items():
        print(f"{label.capitalize()} scope: {'granted' if scope in granted else 'not returned'}.")
    channel_id = args.channel_id
    if not channel_id:
        now = dt.datetime.now(dt.timezone.utc)
        stamp = lambda value: value.isoformat(timespec="seconds").replace("+00:00", "Z")
        groups = [s for s in api_pages("sessions", "sessions", {
            "from": stamp(now - dt.timedelta(days=30)), "to": stamp(now),
        }, token) if s.get("type") == "groupchat"]
        print(f"PASS: session access; {len(groups)} group sessions returned for the last 30 days.")
        if not args.group:
            for group in groups:
                print(json.dumps({"name": group.get("name"), "channel_id": group.get("channel_id")}, ensure_ascii=True))
            print("Choose a group with --group or --channel-id and rerun to check history.")
            return
        matches = [g for g in groups if g.get("name") == args.group]
        if len(matches) != 1 or not matches[0].get("channel_id"):
            raise RuntimeError("Group name was absent or ambiguous. Use its exact channel ID; absence here does not prove lack of access.")
        channel_id = matches[0]["channel_id"]
    messages = list(api_pages("messages", "messages", {"to_channel": channel_id, "date": args.date.isoformat()}, token))
    print(f"PASS: history request accepted; {len(messages)} messages returned for {args.date}.")
    placeholders = sum("encrypted message" in str(m.get("message", "")).lower() for m in messages)
    print(f"Possible encrypted-message placeholders: {placeholders}. Confirm readable content against a known message in Zoom.")
    if args.compare_message:
        known = getpass.getpass("Paste a known single-line message from this group/date (input hidden): ")
        if not known:
            print("Readability comparison skipped: no text entered.")
        else:
            found = any(m.get("message") == known for m in messages)
            print("PASS: known message returned as readable text." if found else "INCONCLUSIVE: known text absent; check date, retention, membership, or encryption.")
    print("Message bodies and credentials were not printed or saved. Empty results do not prove readable history.")
    print("Sending is UNTESTED: scope consent alone does not prove permission to post in this group.")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, KeyboardInterrupt) as error:
        print(str(error) if isinstance(error, RuntimeError) else "Check cancelled.")
        raise SystemExit(1)
