from dataclasses import dataclass, field
from datetime import datetime


@dataclass
class Alert:
    host: str
    check: str
    status: str
    message: str
    action: str = "-"
    timestamp: str = field(
        default_factory=lambda: datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    )

    @property
    def key(self):
        # used for de-duplication, message text is left out on purpose
        # because it usually contains changing numbers
        return f"{self.host}:{self.check}:{self.status}"

    def title(self):
        return f"[{self.status}] {self.host} - {self.check}"

    def text(self):
        lines = [
            self.title(),
            f"time:    {self.timestamp}",
            f"message: {self.message}",
        ]
        if self.action and self.action != "-":
            lines.append(f"action:  {self.action}")
        return "\n".join(lines)
