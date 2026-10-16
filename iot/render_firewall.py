#!/usr/bin/env python3
"""Render a dedicated-VM firewall. IoT UIDs cannot initiate any off-host connection."""
import argparse
import ipaddress


def render(pms, database, runtime_uid, mqtt_uid, edge_uid, ssh_port=22):
    pms = ipaddress.IPv4Address(pms)
    database = ipaddress.IPv4Address(database)
    if any(ip.is_loopback or ip.is_unspecified or ip.is_multicast or ip.is_link_local
           or ip == ipaddress.IPv4Address("255.255.255.255") for ip in (pms, database)):
        raise ValueError("PMS addresses must be outside the dedicated IoT host")
    if type(ssh_port) is not int or not 1 <= ssh_port <= 65535 or ssh_port in (443, 8883, 8444):
        raise ValueError("Invalid SSH port")
    uids = (runtime_uid, mqtt_uid, edge_uid)
    if len(set(uids)) != 3 or any(type(uid) is not int or not 1 <= uid < 2**32 - 1 for uid in uids):
        raise ValueError("Workloads must use non-root UIDs")
    protected = ", ".join(sorted({str(pms), str(database)}))
    return f"""table inet baitly_iot {{
 chain input {{
  type filter hook input priority 0; policy drop;
  ct state invalid drop
  ct state established,related accept
  iifname "lo" accept
  tcp dport {{ {ssh_port}, 443, 8883 }} accept
  ip saddr {pms} tcp dport 8444 accept
  meta l4proto {{ icmp, ipv6-icmp }} accept
 }}
 chain output {{
  type filter hook output priority 0; policy accept;
  ct state invalid drop
  ct state established,related accept
  oifname "lo" accept
  ip daddr {{ {protected} }} counter reject with icmpx type admin-prohibited
  meta skuid {{ {runtime_uid}, {mqtt_uid}, {edge_uid} }} counter reject with icmpx type admin-prohibited
 }}
 chain forward {{ type filter hook forward priority 0; policy drop; }}
}}
"""


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    for name in ("pms", "database"):
        p.add_argument("--" + name, required=True)
    for name in ("runtime-uid", "mqtt-uid", "edge-uid", "ssh-port"):
        p.add_argument("--" + name, type=int, required=name != "ssh-port", default=22)
    a = p.parse_args()
    print(render(a.pms, a.database, a.runtime_uid, a.mqtt_uid, a.edge_uid, a.ssh_port))
