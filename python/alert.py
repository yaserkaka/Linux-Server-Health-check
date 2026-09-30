#!/usr/bin/env python3
"""Send a server-health alert to one or more channels.

Called by health-check.sh, but works on its own too:

    SLACK_WEBHOOK_URL=https://hooks.slack.com/... \\
    ./alert.py --host web01 --check nginx --status CRITICAL \\
               --message "nginx stopped" --channels slack

Webhook URLs and SMTP credentials are only read from the environment.
"""

import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from alerting.channels import CHANNELS, ChannelNotConfigured  # noqa: E402
from alerting.cooldown import Cooldown  # noqa: E402
from alerting.models import Alert  # noqa: E402

STATUSES = ("OK", "WARNING", "CRITICAL", "RECOVERED")


def parse_channels(value):
    names = [c for c in re.split(r"[,\s]+", value or "") if c]
    return [] if names == ["none"] else names


def parse_args(argv):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--host", required=True)
    p.add_argument("--check", required=True)
    p.add_argument("--status", required=True, choices=STATUSES)
    p.add_argument("--message", required=True)
    p.add_argument("--action", default="-")
    p.add_argument("--channels", default="",
                   help="comma or space separated, e.g. 'slack,email'")
    p.add_argument("--cooldown", type=int, default=0,
                   help="seconds before the same host/check/status is sent again")
    p.add_argument("--state-file", default="",
                   help="where cooldown timestamps are kept")
    return p.parse_args(argv)


def dispatch(alert, channel_names, env=None, cooldown=None):
    """Returns the number of channels that failed."""
    if cooldown and not cooldown.should_send(alert.key):
        print(f"suppressed (cooldown): {alert.key}", file=sys.stderr)
        return 0

    failures = 0
    sent = 0
    for name in channel_names:
        cls = CHANNELS.get(name)
        if cls is None:
            print(f"unknown channel '{name}'", file=sys.stderr)
            failures += 1
            continue
        try:
            cls(env).send(alert)
            sent += 1
        except ChannelNotConfigured as e:
            print(str(e), file=sys.stderr)
            failures += 1
        except Exception as e:  # network errors, smtp errors, http 4xx/5xx
            print(f"{name}: send failed: {e}", file=sys.stderr)
            failures += 1

    if sent and cooldown:
        cooldown.mark_sent(alert.key)
        if alert.status == "RECOVERED":
            # new incident after a recovery should page again right away
            cooldown.clear(f"{alert.host}:{alert.check}:CRITICAL")
    return failures


def main(argv=None):
    args = parse_args(argv)
    alert = Alert(
        host=args.host,
        check=args.check,
        status=args.status,
        message=args.message,
        action=args.action,
    )
    print(alert.text())

    cooldown = Cooldown(args.state_file, args.cooldown) if args.state_file else None
    failures = dispatch(alert, parse_channels(args.channels), cooldown=cooldown)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
