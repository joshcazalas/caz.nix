#!/usr/bin/env python3
"""Queue deployment events locally and submit them to the local Alertmanager."""

import argparse
from datetime import datetime, timedelta, timezone
import fcntl
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time
import urllib.request
import uuid


EVENTS = {
    "available": ("info", "New release available for verification"),
    "deployed": ("info", "Release deployed and healthy"),
    "failed": ("warning", "Release verification or deployment failed"),
    "rolled-back": (
        "warning",
        "Deployment failed; previous generation restored and healthy",
    ),
    "rollback-failed": (
        "critical",
        "Deployment failed; rollback did not restore a healthy server",
    ),
}


def utcnow():
    return datetime.now(timezone.utc)


def timestamp(value):
    return value.isoformat().replace("+00:00", "Z")


def enqueue(
    queue, event, repository, release, phase, reboot_required, rollback_status, instance
):
    # Discovery/verification may fail before the release tag is trustworthy.
    # Never include command output, credentials, or arbitrary remote text.
    if not re.fullmatch(r"caz\.nix-\d{4}\.\d{2}\.\d{2}-g[0-9a-f]{12}", release):
        release = "unknown"
    severity, summary = EVENTS[event]
    event_id = uuid.uuid4().hex
    occurred = timestamp(utcnow())
    description = f"Release: {release}. Stage: {phase}. Recorded: {occurred}."
    if event == "deployed":
        description += (
            " A kernel/initrd change requires an ordinary reboot; no automatic reboot was requested."
            if reboot_required
            else " No kernel/initrd reboot is required."
        )
    if event in ("rolled-back", "rollback-failed"):
        description += f" Rollback result: {rollback_status}."
    if event in ("failed", "rolled-back", "rollback-failed"):
        description += " Inspect journalctl -u caz-release-updater.service and caz-deploy-server-release --status."

    record = {
        "recordedAt": occurred,
        "alert": {
            "labels": {
                "alertname": "ReleaseDeploymentEvent",
                "component": "deployment-event",
                "instance": instance,
                "event_id": event_id,
                "event": event,
                "severity": severity,
            },
            "annotations": {"summary": summary, "description": description},
            "generatorURL": f"https://github.com/{repository}/releases"
            + (f"/tag/{release}" if release != "unknown" else ""),
        },
    }
    queue.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".event-", dir=queue)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(record, stream)
            stream.flush()
            os.fsync(stream.fileno())
        Path(temporary).replace(queue / f"{time.time_ns():020d}-{event_id}.json")
    finally:
        Path(temporary).unlink(missing_ok=True)


def drain(queue, endpoint):
    if not queue.exists():
        return
    # Producers write atomically and never wait for this delivery lock.
    with (queue / ".delivery.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        # This endpoint is generated from the loopback-only Alertmanager config.
        # Ignore proxy variables so local event data cannot go through a proxy.
        client = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        for path in sorted(queue.glob("*.json"))[:20]:
            record = json.loads(path.read_text())
            now = utcnow()
            if now - datetime.fromisoformat(record["recordedAt"]) > timedelta(days=14):
                print(
                    f"Discarding deployment event older than 14 days: {path.name}",
                    file=sys.stderr,
                )
                path.unlink()
                continue
            alert = record["alert"]
            # Start the delivery window now, including after a long outage.
            # Retried requests keep the same event_id for Alertmanager deduplication.
            alert["startsAt"] = record["recordedAt"]
            alert["endsAt"] = timestamp(now + timedelta(minutes=10))
            request = urllib.request.Request(
                endpoint,
                data=json.dumps([alert]).encode(),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with client.open(request, timeout=3) as response:
                if not 200 <= response.status < 300:
                    raise RuntimeError(
                        "Alertmanager did not accept the deployment event"
                    )
            # Acceptance by Alertmanager is the hand-off, not proof that either
            # external channel delivered. Their retries belong to Alertmanager.
            path.unlink()


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--queue", type=Path, required=True)
    commands = parser.add_subparsers(dest="command", required=True)
    add = commands.add_parser("enqueue")
    add.add_argument("event", choices=EVENTS)
    add.add_argument("--repository", required=True)
    add.add_argument("--release", default="unknown")
    add.add_argument(
        "--phase",
        choices=(
            "discovery",
            "verification",
            "build",
            "preflight",
            "backup",
            "activation",
            "health",
            "recording",
        ),
        required=True,
    )
    add.add_argument("--reboot-required", choices=("true", "false"), default="false")
    add.add_argument(
        "--rollback-status",
        choices=(
            "not-needed",
            "in-progress",
            "failed",
            "profile-restore-failed",
            "activation-failed",
            "store-path-mismatch",
            "health-check-failed",
            "succeeded",
        ),
        default="not-needed",
    )
    add.add_argument("--instance", required=True)
    send = commands.add_parser("drain")
    send.add_argument("--endpoint", required=True)
    args = parser.parse_args()
    try:
        if args.command == "enqueue":
            if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
                parser.error("invalid repository")
            enqueue(
                args.queue,
                args.event,
                args.repository,
                args.release,
                args.phase,
                args.reboot_required == "true",
                args.rollback_status,
                args.instance,
            )
        else:
            drain(args.queue, args.endpoint)
    except (OSError, ValueError, KeyError, RuntimeError) as error:
        # Do not include server response bodies or configuration in the journal.
        print(
            f"Deployment notification failed ({type(error).__name__}); queued events will retry.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
