from unittest import mock

import pytest

import alert
from alerting.cooldown import Cooldown
from alerting.models import Alert

ALERT = Alert(host="web01", check="disk:/", status="CRITICAL", message="96% full")


def test_parse_channels():
    assert alert.parse_channels("slack,discord") == ["slack", "discord"]
    assert alert.parse_channels("slack discord") == ["slack", "discord"]
    assert alert.parse_channels("none") == []
    assert alert.parse_channels("") == []


def test_unknown_channel_counts_as_failure():
    assert alert.dispatch(ALERT, ["pigeon"], env={}) == 1


def test_unconfigured_channel_counts_as_failure():
    assert alert.dispatch(ALERT, ["slack"], env={}) == 1


def test_success_marks_cooldown(tmp_path):
    cd = Cooldown(str(tmp_path / "s.json"), 600)
    env = {"SLACK_WEBHOOK_URL": "https://hooks.example/abc"}
    with mock.patch("alerting.channels.slack.post_json"):
        assert alert.dispatch(ALERT, ["slack"], env=env, cooldown=cd) == 0
    assert not cd.should_send(ALERT.key)


def test_cooldown_suppresses_second_send(tmp_path):
    cd = Cooldown(str(tmp_path / "s.json"), 600)
    cd.mark_sent(ALERT.key)
    env = {"SLACK_WEBHOOK_URL": "https://hooks.example/abc"}
    with mock.patch("alerting.channels.slack.post_json") as post:
        assert alert.dispatch(ALERT, ["slack"], env=env, cooldown=cd) == 0
    post.assert_not_called()


def test_network_error_is_reported_not_raised():
    env = {"SLACK_WEBHOOK_URL": "https://hooks.example/abc"}
    with mock.patch("alerting.channels.slack.post_json", side_effect=OSError("timeout")):
        assert alert.dispatch(ALERT, ["slack"], env=env) == 1


def test_main_rejects_bad_status():
    with pytest.raises(SystemExit) as e:
        alert.main(["--host", "h", "--check", "c", "--status", "BROKEN", "--message", "m"])
    assert e.value.code == 2


def test_recovery_resets_critical_cooldown(tmp_path):
    cd = Cooldown(str(tmp_path / "s.json"), 600)
    crit = Alert(host="web01", check="nginx", status="CRITICAL", message="down")
    rec = Alert(host="web01", check="nginx", status="RECOVERED", message="restarted")
    env = {"SLACK_WEBHOOK_URL": "https://hooks.example/abc"}
    with mock.patch("alerting.channels.slack.post_json"):
        alert.dispatch(crit, ["slack"], env=env, cooldown=cd)
        assert not cd.should_send(crit.key)
        alert.dispatch(rec, ["slack"], env=env, cooldown=cd)
    assert cd.should_send(crit.key)
