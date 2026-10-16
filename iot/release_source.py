#!/usr/bin/env python3
"""Authorize an immutable application artifact before any SSH or staging write."""
import json
import os
import re


def validate(metadata, repository, sha, run_id):
    if not re.fullmatch(r"[a-f0-9]{40}", sha) or not re.fullmatch(r"[1-9][0-9]*", str(run_id)):
        raise ValueError("Full commit SHA and positive workflow run ID required")
    expected = {
        "id": int(run_id), "head_sha": sha, "head_branch": "main", "event": "push",
        "status": "completed", "conclusion": "success", "path": ".github/workflows/ci-baitly-iot.yml",
    }
    if any(metadata.get(key) != value for key, value in expected.items()):
        raise ValueError("Release must come from a successful complete main IoT CI run, including the audit")
    if metadata.get("head_repository", {}).get("full_name") != repository:
        raise ValueError("Artifacts from forks or another repository are forbidden")


if __name__ == "__main__":
    with open("app-run.json") as source:
        validate(json.load(source), os.environ["APP_REPOSITORY"], os.environ["APP_SHA"], os.environ["APP_RUN_ID"])
    print("Approved main artifact source; no deployment performed by this check")
