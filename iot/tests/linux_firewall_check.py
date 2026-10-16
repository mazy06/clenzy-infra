#!/usr/bin/env python3
"""Executed ONLY inside unshare --net in CI; no changes to the runner's host network."""
import os
from pathlib import Path
import select
import socket
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from render_firewall import render
from verify_network import counters


def run(*args):
    subprocess.run(args, check=True, capture_output=True)


def serve():
    print(os.getpid(), flush=True)
    sys.stdin.readline()
    servers = []
    for port in (443, 5432):
        server = socket.socket()
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("198.18.0.2", port)); server.listen(16); servers.append(server)
    print("ready", flush=True)
    while True:
        for server in select.select(servers, [], [], 5)[0]:
            peer, _ = server.accept(); peer.close()


def main():
    if os.geteuid() != 0:
        raise RuntimeError("Disposable network namespace check requires root")
    # Fail rather than ever applying these rules to the runner's initial namespace.
    if os.readlink("/proc/self/ns/net") == os.readlink("/proc/1/ns/net"):
        raise RuntimeError("Refusing the host network namespace")
    child = subprocess.Popen(["unshare", "--net", sys.executable, __file__, "--serve"],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    control = socket.socket()
    try:
        pid = int(child.stdout.readline())
        run("ip", "link", "set", "lo", "up")
        run("ip", "link", "add", "test0", "type", "veth", "peer", "name", "test1")
        run("ip", "link", "set", "test1", "netns", str(pid))
        run("ip", "addr", "add", "198.18.0.1/30", "dev", "test0")
        run("ip", "link", "set", "test0", "up")
        for command in (("ip", "addr", "add", "198.18.0.2/30", "dev", "test1"),
                        ("ip", "link", "set", "test1", "up"), ("ip", "link", "set", "lo", "up")):
            run("nsenter", "-t", str(pid), "-n", *command)
        run("ip", "route", "add", "169.254.169.254/32", "via", "198.18.0.2", "dev", "test0")
        child.stdin.write("go\n"); child.stdin.flush()
        if child.stdout.readline().strip() != "ready":
            raise RuntimeError("External positive-control servers did not start")
        for port in (443, 5432):
            with socket.create_connection(("198.18.0.2", port), timeout=2):
                pass
        control.bind(("127.0.0.1", 8096)); control.listen(16)
        policy = render("198.18.0.2", "198.18.0.2", 11001, 11002, 11003)
        with tempfile.NamedTemporaryFile(mode="w") as file:
            file.write("add table inet baitly_iot\ndelete table inet baitly_iot\n" + policy); file.flush()
            run("nft", "-c", "-f", file.name)
            run("nft", "-f", file.name)
            run("nft", "-f", file.name)  # repeated installation stays atomic and valid
        code = "import socket,sys; s=socket.create_connection((sys.argv[1],int(sys.argv[2])),timeout=2); s.close()"
        for uid in (11001, 11002, 11003):
            def change_user():
                os.setgroups([]); os.setgid(uid); os.setuid(uid)
            positive = subprocess.run([sys.executable, "-c", code, "127.0.0.1", "8096"], preexec_fn=change_user, capture_output=True)
            if positive.returncode != 0:
                raise RuntimeError("Loopback control unexpectedly blocked")
            for host, port in (("198.18.0.2", 443), ("198.18.0.2", 5432), ("169.254.169.254", 80)):
                before = counters()
                result = subprocess.run([sys.executable, "-c", code, host, str(port)], preexec_fn=change_user, capture_output=True)
                if result.returncode == 0 or counters() <= before:
                    raise RuntimeError("Firewall did not prove the forbidden connection was rejected")
        print("Nine forbidden connections rejected by nftables; three loopback controls passed")
    finally:
        control.close()
        child.terminate(); child.wait(timeout=5)


if __name__ == "__main__":
    serve() if "--serve" in sys.argv else main()
