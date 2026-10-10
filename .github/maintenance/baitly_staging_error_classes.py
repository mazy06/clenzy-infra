"""Diagnostic Baitly : classes/codes uniquement, aucun message ni log brut."""
import json
import re
import subprocess


def summarize(raw):
    classes = re.findall(r"\b(?:[a-zA-Z_$][\w$]*\.)+[A-Z][\w$]*(?:Exception|Error)\b", raw)
    frames = re.findall(r"\bat (com\.clenzy\.[\w.$]+)\((?:[\w$]+\.java:\d+|Unknown Source|Native Method)\)", raw)
    states = re.findall(r"\bSQLState:\s*([A-Z0-9]{5})\b", raw)
    return {"exceptionClasses": list(dict.fromkeys(classes))[-30:],
            "applicationFrames": list(dict.fromkeys(frames))[-30:],
            "sqlStates": sorted(set(states))}


if __name__ == "__main__":
    result = subprocess.run(["docker", "compose", "-f", "docker-compose.prod.yml",
                             "--env-file", ".env", "logs", "--since", "30m",
                             "--tail", "5000", "--no-color", "pms-server"],
                            capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise SystemExit("Lecture du diagnostic staging impossible ; aucun log publié")
    print(json.dumps(summarize(result.stdout), sort_keys=True))
