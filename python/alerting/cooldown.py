import json
import os
import time


class Cooldown:
    """Remembers when each alert key was last sent.

    The health check runs every 5 minutes, without this a broken disk
    would send a message every 5 minutes until someone fixes it.
    """

    def __init__(self, path, seconds):
        self.path = path
        self.seconds = seconds
        self._data = self._load()

    def _load(self):
        if not self.path or not os.path.exists(self.path):
            return {}
        try:
            with open(self.path) as f:
                data = json.load(f)
            return data if isinstance(data, dict) else {}
        except (OSError, ValueError):
            # corrupt state file shouldn't block alerts
            return {}

    def should_send(self, key, now=None):
        if self.seconds <= 0:
            return True
        now = now if now is not None else time.time()
        last = self._data.get(key, 0)
        return now - last >= self.seconds

    def mark_sent(self, key, now=None):
        self._data[key] = now if now is not None else time.time()
        self._save()

    def clear(self, key):
        if self._data.pop(key, None) is not None:
            self._save()

    def _save(self):
        if not self.path:
            return
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self._data, f, indent=2)
        os.replace(tmp, self.path)
