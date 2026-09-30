from alerting.models import Alert


def make(**kw):
    base = dict(host="web01", check="nginx", status="CRITICAL",
                message="nginx is inactive", timestamp="2026-09-30 12:30:05")
    base.update(kw)
    return Alert(**base)


def test_key_ignores_message():
    assert make(message="a").key == make(message="b").key


def test_key_differs_by_status():
    assert make(status="CRITICAL").key != make(status="RECOVERED").key


def test_text_contains_fields():
    text = make(action="systemctl restart nginx").text()
    assert "[CRITICAL] web01 - nginx" in text
    assert "nginx is inactive" in text
    assert "systemctl restart nginx" in text


def test_text_hides_empty_action():
    assert "action" not in make(action="-").text()
