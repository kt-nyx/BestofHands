# SPDX-License-Identifier: Unlicense

from __future__ import annotations

import argparse
import json
import os
import subprocess
from datetime import datetime, timezone

from automation_support import BUILD_ID, decide_build_change, initial_state_build


STATE_TITLE = "[Automation state] BG3 Steam public build"
STATE_LABEL = "automation-state:bg3-build"
UPDATE_LABEL = "bg3-update-detected"


def gh(*arguments: str, input_text: str | None = None) -> str:
    result = subprocess.run(
        ["gh", *arguments], input=input_text, text=True,
        check=True, capture_output=True,
    )
    return result.stdout.strip()


def output(name: str, value: str) -> None:
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as stream:
        stream.write(f"{name}={value}\n")


def list_issues(label: str) -> list[dict]:
    return json.loads(gh(
        "issue", "list", "--state", "all", "--label", label,
        "--limit", "100", "--json", "number,title,body,url,state",
    ))


def prepare(args: argparse.Namespace) -> None:
    if not BUILD_ID.fullmatch(args.detected):
        raise ValueError("detected build ID is invalid")
    labels = {item["name"] for item in json.loads(gh(
        "label", "list", "--limit", "100", "--json", "name",
    ))}
    if STATE_LABEL not in labels:
        gh("label", "create", STATE_LABEL, "--color", "6f42c1",
           "--description", "Durable automation state; do not delete")
    if UPDATE_LABEL not in labels:
        gh("label", "create", UPDATE_LABEL, "--color", "d93f0b",
           "--description", "A new Baldur's Gate 3 Steam build was detected")
    states = [issue for issue in list_issues(STATE_LABEL) if issue["title"] == STATE_TITLE]
    if len(states) > 1:
        raise RuntimeError("multiple BG3 automation state issues exist")
    state = states[0] if states else None
    decision, previous = decide_build_change(
        args.detected, state["body"] if state else None, args.baseline or None,
    )
    now = datetime.now(timezone.utc).isoformat()
    if state is None:
        state_build = initial_state_build(decision, previous, args.detected)
        body = (
            "Durable state for the scheduled BG3 build watcher.\n\n"
            "Do not edit or delete the marker below.\n\n"
            f"<!-- bg3-build-state:v1 build={state_build} -->\n"
            f"Last successful observation: {now}\n"
        )
        url = gh("issue", "create", "--title", STATE_TITLE, "--label", STATE_LABEL,
                 "--body", body)
        state = {"number": url.rsplit("/", 1)[-1], "url": url}
    output("state_issue", str(state["number"]))
    output("old_build", previous)
    output("new_build", args.detected)
    output("decision", decision)
    if decision != "changed":
        output("issue_number", "")
        output("issue_url", "")
        return

    title = f"[BG3 update] Steam public build {args.detected}"
    marker = f"<!-- bg3-build-detection:v1 build={args.detected} -->"
    existing = [issue for issue in list_issues(UPDATE_LABEL)
                if issue["title"] == title and marker in issue["body"]]
    if len(existing) > 1:
        raise RuntimeError("duplicate build detection issues already exist")
    body = (
        f"{marker}\n"
        "## Baldur's Gate 3 update detected\n\n"
        f"- Previous Steam build ID: `{previous}`\n"
        f"- New Steam build ID: `{args.detected}`\n"
        f"- Detected (UTC): `{now}`\n"
        f"- Watcher run: {args.run_url}\n"
        "- Steam: https://store.steampowered.com/app/1086940/\n"
        "- SteamDB: https://steamdb.info/app/1086940/patchnotes/\n\n"
        "## Next steps\n\n"
        "1. Generate sanitized local compatibility evidence on Windows.\n"
        "2. Review the evidence and this issue.\n"
        "3. Manually run the Codex compatibility-draft workflow.\n"
        "4. Review and gameplay-test the resulting draft pull request.\n"
    )
    if existing:
        issue = existing[0]
        gh("issue", "edit", str(issue["number"]), "--body", body)
    else:
        url = gh("issue", "create", "--title", title, "--label", UPDATE_LABEL,
                 "--body", body)
        issue = {"number": url.rsplit("/", 1)[-1], "url": url}
    output("issue_number", str(issue["number"]))
    output("issue_url", issue["url"])


def commit(args: argparse.Namespace) -> None:
    if not BUILD_ID.fullmatch(args.detected):
        raise ValueError("detected build ID is invalid")
    now = datetime.now(timezone.utc).isoformat()
    body = (
        "Durable state for the scheduled BG3 build watcher.\n\n"
        "Do not edit or delete the marker below.\n\n"
        f"<!-- bg3-build-state:v1 build={args.detected} -->\n"
        f"Last successfully notified observation: {now}\n"
    )
    gh("issue", "edit", args.state_issue, "--body", body)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    prepare_parser = subparsers.add_parser("prepare")
    prepare_parser.add_argument("--detected", required=True)
    prepare_parser.add_argument("--baseline")
    prepare_parser.add_argument("--run-url", required=True)
    commit_parser = subparsers.add_parser("commit")
    commit_parser.add_argument("--detected", required=True)
    commit_parser.add_argument("--state-issue", required=True)
    arguments = parser.parse_args()
    prepare(arguments) if arguments.command == "prepare" else commit(arguments)
