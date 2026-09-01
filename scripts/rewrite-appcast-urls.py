#!/usr/bin/env python3
"""Point every appcast enclosure at the GitHub release that carries the file.

generate_appcast writes whatever URL prefix it was given (or a bare filename)
for every enclosure, including the deltas. Pointing those at a raw.github URL
on the default branch is how they came to 404: release artifacts are gitignored
and never reach the branch, so the only durable home for them is the release
they belong to.

Each item's files live on the release tagged for that item's version, so the
prefix is derived per item rather than applied to the whole feed.

Only the url= attributes are touched. sparkle:edSignature covers the file
contents, not the URL, so rewriting a URL does not invalidate a signature --
but rewriting anything else in the enclosure would, and this stays away from it.
"""

import re
import sys
import urllib.parse
from pathlib import Path

# generate_appcast names a delta after the app: "Vibe Notch10-9.delta". GitHub
# rewrites spaces in a release asset name to dots, so deltas are uploaded
# space-free and the URL has to match the uploaded name, not the local one.
DELTA_APP_PREFIX = "Vibe Notch"
ASSET_PREFIX = "VibeNotch-"


def asset_name(url: str) -> str:
    base = urllib.parse.unquote(url.rsplit("/", 1)[-1])
    if base.startswith(DELTA_APP_PREFIX):
        return ASSET_PREFIX + base[len(DELTA_APP_PREFIX):]
    return base


def rewrite(text: str, repo: str) -> tuple[str, int]:
    count = 0

    def fix_item(match: re.Match) -> str:
        nonlocal count
        item = match.group(0)
        version = re.search(r"<sparkle:shortVersionString>([^<]+)<", item)
        if not version:
            return item
        prefix = f"https://github.com/{repo}/releases/download/v{version.group(1)}/"

        def fix_url(url_match: re.Match) -> str:
            nonlocal count
            old = url_match.group(1)
            new = prefix + asset_name(old)
            if old != new:
                count += 1
                print(f"  {old}\n    -> {new}")
            return f'url="{new}"'

        return re.sub(r'url="([^"]+)"', fix_url, item)

    return re.sub(r"<item>.*?</item>", fix_item, text, flags=re.S), count


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: rewrite-appcast-urls.py <appcast.xml> <owner/repo>", file=sys.stderr)
        return 2

    path, repo = Path(sys.argv[1]), sys.argv[2]
    original = path.read_text()
    updated, count = rewrite(original, repo)

    # A feed that still points somewhere other than a release asset would ship
    # 404s to every installed client, so refuse rather than write one.
    stale = [u for u in re.findall(r'url="([^"]+)"', updated)
             if not u.startswith(f"https://github.com/{repo}/releases/download/")]
    if stale:
        print("ERROR: enclosure URLs are not release assets:", file=sys.stderr)
        for u in stale:
            print(f"  {u}", file=sys.stderr)
        return 1

    if updated != original:
        path.write_text(updated)
    print(f"{count} URL(s) rewritten; all enclosures point at release assets.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
