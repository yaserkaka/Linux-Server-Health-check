from unittest import mock

import pytest

from alerting.channels import CHANNELS, ChannelNotConfigured
from alerting.channels.discord import DiscordChannel
from alerting.channels.email import EmailChannel
from alerting.channels.slack import SlackChannel
from alerting.models import Alert

ALERT = Alert(host="web01", check="nginx", status="CRITICAL",
              message="nginx is inactive", timestamp="2026-09-30 12:30:05")


def test_registry_has_expected_channels():
    assert set(CHANNELS) == {"slack", "discord", "email"}


def test_slack_requires_webhook_env():
    with pytest.raises(ChannelNotConfigured):
        SlackChannel(env={})


def test_slack_posts_text_payload():
    env = {"SLACK_WEBHOOK_URL": "https://hooks.example/abc"}
    with mock.patch("alerting.channels.slack.post_json") as post:
        SlackChannel(env=env).send(ALERT)
    url, payload = post.call_args[0]
    assert url == "https://hooks.example/abc"
    assert "nginx is inactive" in payload["text"]


def test_discord_uses_content_field_and_limit():
    env = {"DISCORD_WEBHOOK_URL": "https://discord.example/x"}
    long_alert = Alert(host="h", check="c", status="WARNING", message="x" * 5000)
    with mock.patch("alerting.channels.discord.post_json") as post:
        DiscordChannel(env=env).send(long_alert)
    payload = post.call_args[0][1]
    assert len(payload["content"]) <= 2000


def test_email_message_headers():
    env = {"SMTP_HOST": "smtp.example", "ALERT_EMAIL_FROM": "mon@example.com",
           "ALERT_EMAIL_TO": "ops@example.com"}
    msg = EmailChannel(env=env).build_message(ALERT)
    assert msg["Subject"] == "[CRITICAL] web01 - nginx"
    assert msg["To"] == "ops@example.com"


def test_email_sends_with_login_and_starttls():
    env = {"SMTP_HOST": "smtp.example", "SMTP_PORT": "2525",
           "SMTP_USER": "u", "SMTP_PASSWORD": "p",
           "ALERT_EMAIL_FROM": "a@x", "ALERT_EMAIL_TO": "b@x"}
    with mock.patch("alerting.channels.email.smtplib.SMTP") as smtp_cls:
        EmailChannel(env=env).send(ALERT)
    smtp_cls.assert_called_once_with("smtp.example", 2525, timeout=15)
    smtp = smtp_cls.return_value.__enter__.return_value
    smtp.starttls.assert_called_once()
    smtp.login.assert_called_once_with("u", "p")
    smtp.send_message.assert_called_once()
