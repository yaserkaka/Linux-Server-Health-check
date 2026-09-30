import smtplib
from email.message import EmailMessage

from .base import Channel


class EmailChannel(Channel):
    name = "email"
    required_env = ("SMTP_HOST", "ALERT_EMAIL_FROM", "ALERT_EMAIL_TO")

    def build_message(self, alert):
        msg = EmailMessage()
        msg["Subject"] = alert.title()
        msg["From"] = self.env["ALERT_EMAIL_FROM"]
        msg["To"] = self.env["ALERT_EMAIL_TO"]
        msg.set_content(alert.text())
        return msg

    def send(self, alert):
        host = self.env["SMTP_HOST"]
        port = int(self.env.get("SMTP_PORT", "587"))
        user = self.env.get("SMTP_USER")
        password = self.env.get("SMTP_PASSWORD")

        with smtplib.SMTP(host, port, timeout=15) as smtp:
            if self.env.get("SMTP_STARTTLS", "1") != "0":
                smtp.starttls()
            if user and password:
                smtp.login(user, password)
            smtp.send_message(self.build_message(alert))
