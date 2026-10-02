# SPDX-License-Identifier: Unlicense
"""Preserve the current Nexus file description and verify the published version."""

from __future__ import annotations

import argparse
from decimal import Decimal
import hashlib
import json
import os
from pathlib import Path
import re
import time
from urllib.error import HTTPError
from urllib.request import Request, urlopen
import uuid


API_ROOT = "https://api.nexusmods.com"
GAME = "baldursgate3"
MOD_ID = "23881"
BBCODE = re.compile(r"\[/?(?:b|i|u|s|color|size|font|url|img|quote|code|list|center|left|right|spoiler)(?:[=\s][^\]]*)?\]", re.IGNORECASE)
LINE_BREAK = re.compile(r"(?:<br\s*/?>|&lt;br\s*/?&gt;)", re.IGNORECASE)


def description_bbcode(description: str) -> str:
    # API v1 returns legacy breaks as <br />, but a v3 upload's breaks as
    # &lt;br /&gt;. Both render identically on Nexus. Send actual newlines
    # to avoid accumulating HTML escapes, leaving every BBCode tag intact.
    return LINE_BREAK.sub("\n", description.replace("\r\n", "\n")).strip()


def identifier(value: object) -> str:
    text = str(value)
    if not text.isdecimal() or int(text) <= 0:
        raise ValueError("Invalid Nexus file identifier")
    return text


def read_api(path: str) -> dict:
    key = os.environ.get("NEXUSMODS_API_KEY", "")
    if not key:
        raise ValueError("NEXUSMODS_API_KEY is required")
    request = Request(API_ROOT + path, headers={
        "apikey": key, "User-Agent": "BestofHands-release",
        "Accept": "application/json", "Cache-Control": "no-cache",
    })
    try:
        with urlopen(request, timeout=30) as response:
            return json.load(response)
    except HTTPError as error:
        # Do not print authenticated request headers or arbitrary response text.
        raise ValueError(f"Nexus metadata request failed: HTTP {error.code}") from None


def file_details(game_scoped_id: object, read=read_api) -> dict:
    return read(f"/v1/games/{GAME}/mods/{MOD_ID}/files/{identifier(game_scoped_id)}.json")


def prepare(file_id: str, next_version: str, read=read_api) -> dict:
    file_id = identifier(file_id)
    versions = read(f"/v3/mod-files/{file_id}/versions")["data"]["versions"]
    if any(version["version"] == next_version for version in versions):
        raise ValueError("This version already exists on Nexus; do not upload it again")
    active = [version for version in versions if version["category"] == "main"]
    if not active:
        raise ValueError("No current main-file version to copy the description from")
    latest = max(active, key=lambda version: Decimal(version["position"]))
    if identifier(latest["file"]["id"]) != file_id:
        raise ValueError("Description source belongs to another Nexus file")
    details = file_details(latest["game_scoped_id"], read)
    if identifier(details["file_id"]) != identifier(latest["game_scoped_id"]):
        raise ValueError("Nexus file-description identity does not match")
    description = details.get("description")
    if not isinstance(description, str) or not description.strip():
        raise ValueError("Current file description is empty; refusing to lose install instructions")
    # The official action trims input whitespace. Preserve its actual input.
    description = description_bbcode(description)
    if not BBCODE.search(description):
        raise ValueError("Current description has no raw BBCode; refusing to copy rendered or plain text")
    return {
        "file_id": file_id, "previous_version_id": identifier(latest["id"]),
        "previous_game_scoped_id": identifier(latest["game_scoped_id"]),
        "previous_version": latest["version"], "next_version": next_version,
        "description": description,
        "description_sha256": hashlib.sha256(description.encode("utf-8")).hexdigest(),
    }


def write_output(path: Path, name: str, value: str) -> None:
    delimiter = "nexus_" + uuid.uuid4().hex
    while delimiter in value:
        delimiter = "nexus_" + uuid.uuid4().hex
    with path.open("a", encoding="utf-8", newline="\n") as output:
        output.write(f"{name}<<{delimiter}\n{value}\n{delimiter}\n")


def verify(snapshot: dict, version_id: str, read=read_api) -> dict:
    published = read(f"/v3/mod-file-versions/{identifier(version_id)}")["data"]
    previous = read(f"/v3/mod-file-versions/{identifier(snapshot['previous_version_id'])}")["data"]
    if identifier(published["file"]["id"]) != snapshot["file_id"]:
        raise ValueError("Published version belongs to another Nexus file")
    if published["version"] != snapshot["next_version"] or published["category"] != "main":
        raise ValueError("Published version is not the expected main file")
    if previous["category"] != "old_version":
        raise ValueError("Previous version has not become a visible old version")
    details = file_details(published["game_scoped_id"], read)
    if identifier(details["file_id"]) != identifier(published["game_scoped_id"]):
        raise ValueError("Published description identity does not match")
    if description_bbcode(details.get("description") or "") != description_bbcode(snapshot["description"]):
        raise ValueError("Published description does not match the previous file")
    if (details.get("changelog_html") or "").strip():
        raise ValueError("Published file changelog is not blank")
    return {
        "version_id": identifier(version_id), "version": published["version"],
        "game_scoped_id": identifier(published["game_scoped_id"]),
        "previous_version": snapshot["previous_version"],
        "previous_category": previous["category"],
        "description_sha256": snapshot["description_sha256"],
        "bbcode_preserved": True, "changelog_blank": True,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("prepare", "verify"))
    parser.add_argument("--snapshot", required=True, type=Path)
    args = parser.parse_args()
    if args.operation == "prepare":
        snapshot = prepare(os.environ["NEXUSMODS_FILE_ID"], os.environ["RELEASE_VERSION"])
        args.snapshot.write_text(json.dumps(snapshot, ensure_ascii=False), encoding="utf-8")
        write_output(Path(os.environ["GITHUB_OUTPUT"]), "description", snapshot["description"])
        print(f"Copying raw BBCode description from Nexus {snapshot['previous_version']} "
              f"({len(snapshot['description'])} characters)")
    else:
        snapshot = json.loads(args.snapshot.read_text(encoding="utf-8"))
        for attempt in range(6):
            try:
                result = verify(snapshot, os.environ["NEXUS_VERSION_ID"])
                print(json.dumps(result))
                summary = os.environ.get("GITHUB_STEP_SUMMARY")
                if summary:
                    with Path(summary).open("a", encoding="utf-8") as output:
                        output.write(f"Nexus {result['version']} published. "
                                     f"Previous {result['previous_version']} is an old version. "
                                     "File description preserved; changelog blank.\n")
                return
            except ValueError:
                if attempt == 5:
                    raise
                time.sleep(10)


if __name__ == "__main__":
    main()
