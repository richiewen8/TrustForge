"""Minimal raw DNS client so preflight can ask the same resolver the pipeline asks.

Usage: python dnsprobe.py RESOLVER PORT NAME TYPE [EXPECTED_TXT]
Prints "rcode=<name> answers=<count> matched=<count>" and exits 0 when the resolver
answered, 1 on timeout or a malformed reply.
"""
import random
import socket
import struct
import sys

QTYPE = {"SOA": 6, "TXT": 16, "A": 1}
RCODE = {0: "NOERROR", 1: "FORMERR", 2: "SERVFAIL", 3: "NXDOMAIN", 5: "REFUSED"}


def build_query(name, qtype, query_id):
    parts = [struct.pack("!HHHHHH", query_id, 0x0100, 1, 0, 0, 0)]
    for label in name.rstrip(".").encode("ascii").decode("ascii").split("."):
        raw = label.encode("ascii")
        if not 1 <= len(raw) <= 63:
            raise ValueError("DNS label length out of range")
        parts.append(bytes([len(raw)]) + raw)
    parts.append(b"\x00" + struct.pack("!HH", qtype, 1))
    return b"".join(parts)


def skip_name(message, offset):
    while offset < len(message):
        length = message[offset]
        offset += 1
        if length == 0:
            return offset
        if length & 0xC0 == 0xC0:
            return offset + 1
        offset += length
    raise ValueError("truncated name in DNS reply")


def txt_value(rdata):
    value = ""
    cursor = 0
    while cursor < len(rdata):
        segment = rdata[cursor + 1:cursor + 1 + rdata[cursor]]
        value += segment.decode("utf-8", "replace")
        cursor += 1 + len(segment)
    return value


def ask(resolver, port, packet, query_id):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(5)
        sock.sendto(packet, (resolver, port))
        data, _ = sock.recvfrom(4096)
    if len(data) < 12 or struct.unpack("!H", data[:2])[0] != query_id:
        raise ValueError("reply id mismatch")
    flags = struct.unpack("!H", data[2:4])[0]
    answers = struct.unpack("!H", data[6:8])[0]
    offset = skip_name(data, 12) + 4
    collected = []
    for _ in range(answers):
        offset = skip_name(data, offset)
        rtype, _, _, rdlength = struct.unpack("!HHIH", data[offset:offset + 10])
        offset += 10
        collected.append((rtype, data[offset:offset + rdlength]))
        offset += rdlength
    return RCODE.get(flags & 0x000F, str(flags & 0x000F)), collected


def main():
    resolver, port, name, type_name = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4].upper()
    expected = sys.argv[5] if len(sys.argv) > 5 else None
    query_id = random.randrange(1 << 16)
    packet = build_query(name, QTYPE[type_name], query_id)
    for attempt in range(2):
        try:
            rcode, records = ask(resolver, port, packet, query_id)
            break
        except (OSError, ValueError) as error:
            if attempt == 1:
                print(f"rcode=TIMEOUT answers=0 matched=0 ({error})")
                return 1
    matched = sum(1 for rtype, rdata in records
                  if rtype == QTYPE[type_name] and expected is not None and txt_value(rdata) == expected)
    print(f"rcode={rcode} answers={len(records)} matched={matched}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
