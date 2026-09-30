from .base import Channel, post_json


class SlackChannel(Channel):
    name = "slack"
    required_env = ("SLACK_WEBHOOK_URL",)

    def send(self, alert):
        post_json(self.env["SLACK_WEBHOOK_URL"], {"text": alert.text()})
