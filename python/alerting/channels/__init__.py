from .base import Channel, ChannelNotConfigured
from .discord import DiscordChannel
from .email import EmailChannel
from .slack import SlackChannel

# add new channels here (teams, telegram, pagerduty...)
CHANNELS = {
    "slack": SlackChannel,
    "discord": DiscordChannel,
    "email": EmailChannel,
}

__all__ = ["CHANNELS", "Channel", "ChannelNotConfigured"]
