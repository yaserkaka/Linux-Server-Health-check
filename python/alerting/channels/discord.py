from .base import Channel, post_json


class DiscordChannel(Channel):
    name = "discord"
    required_env = ("DISCORD_WEBHOOK_URL",)

    def send(self, alert):
        # discord renders ``` blocks nicely and has a 2000 char limit
        body = "```\n" + alert.text()[:1900] + "\n```"
        post_json(self.env["DISCORD_WEBHOOK_URL"], {"content": body})
