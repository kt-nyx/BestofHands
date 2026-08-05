# SPDX-License-Identifier: Unlicense

import argparse
import json
import os
import urllib.request


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--subject", required=True)
    parser.add_argument("--text", required=True)
    parser.add_argument("--idempotency-key", required=True)
    args = parser.parse_args()
    key = os.environ["RESEND_API_KEY"]
    sender = os.environ["NOTIFICATION_EMAIL_FROM"]
    recipient = os.environ["NOTIFICATION_EMAIL_TO"]
    payload = json.dumps({
        "from": sender, "to": [recipient], "subject": args.subject, "text": args.text,
    }).encode("utf-8")
    request = urllib.request.Request(
        "https://api.resend.com/emails", data=payload, method="POST",
        headers={
            "Authorization": "Bearer " + key,
            "Content-Type": "application/json",
            "Idempotency-Key": args.idempotency_key,
            "User-Agent": "best-of-hands-github-actions/1",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        if response.status not in {200, 201}:
            raise RuntimeError(f"email provider returned HTTP {response.status}")
    print("Notification accepted by email provider.")
