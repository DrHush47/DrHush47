#!/usr/bin/env python3
"""Writes src/stats.json - the numbers behind the profile card.

Public GitHub REST API only, no token required:

    /users/{login}                             created_at, public_repos, followers
    /users/{login}/repos?type=owner            stars per repository
    /search/commits?q=author:{login}           commits authored in public repos
    /repos/{owner}/{repo}/stats/contributors   lines added / removed per repository

    python scripts/fetch_stats.py             # refresh src/stats.json
    python scripts/fetch_stats.py --dry-run   # print the result, write nothing

If GITHUB_TOKEN (or GH_TOKEN) is set it is used, which lifts the hourly rate
limit. Optional locally, free in Actions.

GitHub computes /stats/contributors lazily and answers 202 ("not ready") first,
so it is retried. Results are cached per repository under "loc_cache": a refresh
only re-reads repositories whose pushed_at changed. If a repo cannot be read the
previous cached numbers are kept, so the card never loses lines it already had.
"""

from __future__ import annotations

import json
import os
import sys
import time
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build import human_age  # noqa: E402  (same folder, reused for the summary)

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
OUT = SRC / "stats.json"
API = "https://api.github.com"
DEFAULT_LOGIN = "DrHush47"
LOGIN = DEFAULT_LOGIN


class ApiError(Exception):
    def __init__(self, status: int, message: str, meta: dict | None = None):
        super().__init__(f"HTTP {status}: {message}" if status else message)
        self.status = status
        self.meta = meta or {}


def header(meta: dict, name: str) -> str | None:
    for key, value in meta.items():
        if key.lower() == name.lower():
            return value
    return None


def request_headers() -> dict[str, str]:
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": f"{LOGIN}-profile-card",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def get(path: str) -> tuple[object, dict]:
    url = path if path.startswith("https://") else API + path
    request = urllib.request.Request(url, headers=request_headers())
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = response.read()
            data = json.loads(payload) if payload.strip() else None
            return data, dict(response.headers)
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
        try:
            message = json.loads(body).get("message", body)
        except (json.JSONDecodeError, AttributeError):
            message = body or str(exc.reason)
        raise ApiError(exc.code, message, dict(exc.headers or {})) from None
    except urllib.error.URLError as exc:
        raise ApiError(0, f"network error: {exc.reason}") from None


def next_link(meta: dict) -> str | None:
    link = header(meta, "Link")
    if not link:
        return None
    for part in link.split(","):
        if 'rel="next"' in part:
            return part.split(";")[0].strip().strip("<>")
    return None


def remaining(meta: dict) -> int | None:
    value = header(meta, "X-RateLimit-Remaining")
    return int(value) if value and value.isdigit() else None


def owned_repos(user: str) -> list[dict]:
    repos: list[dict] = []
    url: str | None = f"/users/{user}/repos?per_page=100&type=owner&sort=pushed"
    while url:
        data, meta = get(url)
        if not isinstance(data, list):
            raise ApiError(0, "unexpected repository list payload")
        repos.extend(data)
        url = next_link(meta)
    return repos


def commit_count(user: str, previous: dict) -> int:
    """Commits authored in public repos' default branches (search API, 1 request).

    The contribution calendar would need GraphQL and a token; out of scope for
    the token-free tier.
    """
    query = urllib.parse.quote(f"author:{user}")
    try:
        data, _ = get(f"/search/commits?q={query}&per_page=1")
    except ApiError as exc:
        fallback = previous.get("commits")
        print(f"warning: commit search failed ({exc}); keeping {fallback}", file=sys.stderr)
        return int(fallback or 0)
    if not isinstance(data, dict) or "total_count" not in data:
        return int(previous.get("commits") or 0)
    return int(data["total_count"])


def contributors(full_name: str) -> list[dict] | None:
    """Returns None while GitHub is still computing the stats (202)."""
    delay = 2.0
    for attempt in range(4):
        try:
            data, _ = get(f"/repos/{full_name}/stats/contributors")
        except ApiError as exc:
            if exc.status == 409:  # empty repository
                return []
            raise
        if isinstance(data, list):
            return data
        time.sleep(delay)
        delay *= 2
    return None


def loc_totals(repos: list[dict], cache: dict, notes: list[str]) -> tuple[int, int, dict]:
    added = removed = 0
    updated: dict[str, dict] = {}

    for repo in repos:
        if repo.get("fork") or not repo.get("size"):
            continue
        full = str(repo.get("full_name") or "")
        pushed = str(repo.get("pushed_at") or "")
        cached = cache.get(full)

        if isinstance(cached, dict) and cached.get("pushed_at") == pushed:
            updated[full] = cached
            added += int(cached.get("additions") or 0)
            removed += int(cached.get("deletions") or 0)
            continue

        try:
            data = contributors(full)
        except ApiError as exc:
            notes.append(f"{full}: {exc}")
            data = None

        if data is None:
            notes.append(f"{full}: stats not ready, keeping the previous numbers")
            if isinstance(cached, dict):
                updated[full] = cached
                added += int(cached.get("additions") or 0)
                removed += int(cached.get("deletions") or 0)
            continue

        repo_add = repo_del = 0
        for entry in data:
            author = str((entry.get("author") or {}).get("login") or "")
            if author.casefold() != LOGIN.casefold():
                continue
            for week in entry.get("weeks") or []:
                repo_add += int(week.get("a") or 0)
                repo_del += int(week.get("d") or 0)

        updated[full] = {"pushed_at": pushed, "additions": repo_add, "deletions": repo_del}
        added += repo_add
        removed += repo_del

    return added, removed, dict(sorted(updated.items()))


def load_previous() -> dict:
    if not OUT.exists():
        return {}
    try:
        data = json.loads(OUT.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def main() -> None:
    global LOGIN

    try:
        config = tomllib.loads((SRC / "card.toml").read_text(encoding="utf-8-sig"))
        LOGIN = str(config.get("handle") or DEFAULT_LOGIN)
    except (OSError, tomllib.TOMLDecodeError):
        LOGIN = DEFAULT_LOGIN

    previous = load_previous()
    cache = previous.get("loc_cache")
    if not isinstance(cache, dict):
        cache = {}

    try:
        user, _ = get(f"/users/{LOGIN}")
        if not isinstance(user, dict):
            raise ApiError(0, "unexpected user payload")
        repos = owned_repos(LOGIN)
        commits = commit_count(LOGIN, previous)
    except ApiError as exc:
        print(f"error: {exc}", file=sys.stderr)
        print("stats not updated - the card keeps the current src/stats.json", file=sys.stderr)
        raise SystemExit(1) from None

    stars = sum(int(r.get("stargazers_count") or 0) for r in repos if not r.get("fork"))

    notes: list[str] = []
    added, removed, cache = loc_totals(repos, cache, notes)

    stats = {
        "generated_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "created_at": user.get("created_at"),
        "repos": int(user.get("public_repos") or 0),
        "stars": stars,
        "commits": commits,
        "followers": int(user.get("followers") or 0),
        "loc": added - removed,
        "loc_add": added,
        "loc_del": removed,
        "loc_cache": cache,
    }

    for note in notes:
        print(f"warning: {note}", file=sys.stderr)

    print(f"{LOGIN}  (account since {stats['created_at'][:10]}, {human_age(stats['created_at'])})")
    print(f"  repos      {stats['repos']:,}")
    print(f"  stars      {stats['stars']:,}")
    print(f"  commits    {stats['commits']:,}")
    print(f"  followers  {stats['followers']:,}")
    print(f"  lines      {stats['loc']:,}  ({stats['loc_add']:,}++, {stats['loc_del']:,}--)")

    text = json.dumps(stats, ensure_ascii=False, indent=2) + "\n"
    if "--dry-run" in sys.argv[1:]:
        print(text)
        return

    tmp = OUT.with_suffix(".json.tmp")
    tmp.write_text(text, encoding="utf-8", newline="\n")
    tmp.replace(OUT)
    print(f"wrote {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
