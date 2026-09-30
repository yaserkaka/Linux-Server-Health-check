from alerting.cooldown import Cooldown


def test_first_alert_is_sent(tmp_path):
    cd = Cooldown(str(tmp_path / "s.json"), 600)
    assert cd.should_send("web01:nginx:CRITICAL", now=1000)


def test_repeat_inside_window_is_suppressed(tmp_path):
    cd = Cooldown(str(tmp_path / "s.json"), 600)
    cd.mark_sent("k", now=1000)
    assert not cd.should_send("k", now=1300)
    assert cd.should_send("k", now=1600)


def test_state_survives_reload(tmp_path):
    path = str(tmp_path / "s.json")
    Cooldown(path, 600).mark_sent("k", now=1000)
    assert not Cooldown(path, 600).should_send("k", now=1100)


def test_corrupt_state_file_is_ignored(tmp_path):
    path = tmp_path / "s.json"
    path.write_text("{not json")
    assert Cooldown(str(path), 600).should_send("k", now=10_000)


def test_zero_disables_cooldown(tmp_path):
    cd = Cooldown(str(tmp_path / "s.json"), 0)
    cd.mark_sent("k", now=1000)
    assert cd.should_send("k", now=1001)
