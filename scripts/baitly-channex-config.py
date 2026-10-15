#!/usr/bin/env python3
"""Provision Channex for the selected Baitly instance without logging credentials."""
import os
from pathlib import Path
import re
import shlex
import sys
import tempfile
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, Request, build_opener


ENDPOINTS = {
    "app.clenzy.fr": "https://staging.channex.io/api/v1",
    "app.baitly.fr": "https://app.channex.io/api/v1",
}


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def configure(path, domain, environ, opener=None):
    if domain not in ENDPOINTS or environ.get("APP_DOMAIN") != domain:
        raise ValueError("Channex: instance target mismatch")
    supplied_key = environ.get("DEPLOY_CHANNEX_API_KEY", "")
    enabled = bool(supplied_key) or environ.get("CHANNEX_ENABLED", "false").lower() == "true"
    key = supplied_key or environ.get("CHANNEX_API_KEY", "")
    updates = {"CHANNEX_BASE_URL": ENDPOINTS[domain]}
    if enabled:
        if not re.fullmatch(r"[A-Za-z0-9._~+/=:\-]+", key):
            raise ValueError("Channex: missing or invalid API key")
        request = Request(ENDPOINTS[domain] + "/properties?pagination[limit]=1",
                          headers={"user-api-key": key, "Accept": "application/json"})
        open_request = opener or build_opener(NoRedirect()).open
        try:
            with open_request(request, timeout=15) as response:
                if response.status != 200:
                    raise ValueError("Channex: unexpected authentication response")
        except HTTPError as exc:
            raise ValueError(f"Channex: authentication check failed (HTTP {exc.code})") from None
        except (URLError, TimeoutError, OSError):
            raise ValueError("Channex: authentication check unavailable") from None
        updates["CHANNEX_WEBHOOK_CALLBACK_URL"] = f"https://{domain}/api/webhooks/channex"
        if supplied_key:
            updates.update(CHANNEX_ENABLED="true", CHANNEX_API_KEY=supplied_key)

    path = Path(path)
    original = path.read_text()
    pattern = re.compile(r"^\s*(?:export\s+)?(" + "|".join(updates) + r")\s*=")
    lines = [line for line in original.splitlines() if not pattern.match(line)]
    content = "\n".join(lines + [f"{key}={shlex.quote(value)}" for key, value in updates.items()]) + "\n"
    if content != original:
        fd, temporary = tempfile.mkstemp(prefix=".baitly-channex-", dir=path.parent)
        try:
            with os.fdopen(fd, "w") as output:
                output.write(content)
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    print(f"Channex: {domain}, {'enabled and authenticated' if enabled else 'disabled'}, configuration ready")


if __name__ == "__main__":
    try:
        configure(sys.argv[1], sys.argv[2], os.environ)
    except ValueError as error:
        sys.exit(str(error))
