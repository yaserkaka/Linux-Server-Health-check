import json
import os
import urllib.request


class ChannelNotConfigured(Exception):
    pass


class Channel:
    """Base class. A channel reads its settings from environment
    variables and implements send()."""

    name = "base"
    required_env = ()

    def __init__(self, env=None):
        self.env = env if env is not None else os.environ
        missing = [k for k in self.required_env if not self.env.get(k)]
        if missing:
            raise ChannelNotConfigured(
                f"{self.name}: missing env var(s): {', '.join(missing)}"
            )

    def send(self, alert):
        raise NotImplementedError


def post_json(url, payload, timeout=10):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Content-Type": "application/json",
            "User-Agent": "server-health-alert/1.0",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status
