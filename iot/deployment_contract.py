"""Pure input validation shared by the runner and the privileged VM installer."""
import re
from render_firewall import render


def validate_settings(settings):
    expected = {"pms_ip", "pms_database_ip", "pms_machine_id", "ssh_port", "service_token", "store_password"}
    if set(settings) != expected:
        raise ValueError("Unexpected deployment settings")
    for key in ("service_token", "store_password"):
        if not isinstance(settings[key], str) or not re.fullmatch(r"[A-Za-z0-9_-]{32,128}", settings[key]):
            raise ValueError("Invalid deployment secret format")
    if not re.fullmatch(r"[a-f0-9]{32}", settings["pms_machine_id"]):
        raise ValueError("Expected PMS machine identity is required")
    render(settings["pms_ip"], settings["pms_database_ip"], 1001, 1002, 1003, settings["ssh_port"])


def require_approval(environment):
    if environment.get("IOT_DEPLOY_APPROVED") != "staging":
        raise ValueError("Deployment is on hold; explicit staging approval is required")
