#!/usr/bin/python3
"""Bounded, in-memory ClamAV Unix-socket acceptance probe. Writes no object files."""
import argparse
import json
from pathlib import PurePosixPath
import socket
import struct
import sys
import time


def scan(endpoint, content, timeout=5):
    if not PurePosixPath(endpoint).is_absolute():
        raise ValueError("Scanner socket must be an absolute path")
    if not content or len(content) > 8192:
        raise ValueError("Probe input must be between 1 and 8192 bytes")
    if not 0 < timeout <= 30:
        raise ValueError("Probe timeout must be positive and at most 30 seconds")
    deadline = time.monotonic() + timeout

    def remaining():
        value = deadline - time.monotonic()
        if value <= 0:
            raise TimeoutError("Scanner exchange deadline exceeded")
        return value

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(remaining())
        client.connect(endpoint)
        client.settimeout(remaining())
        client.sendall(b"zINSTREAM\x00" + struct.pack("!I", len(content)) + content + b"\x00\x00\x00\x00")
        reply = bytearray()
        while not reply.endswith(b"\x00"):
            client.settimeout(remaining())
            chunk = client.recv(1025 - len(reply))
            if not chunk or len(reply) + len(chunk) > 1024:
                raise ValueError("Incomplete or oversized scanner response")
            reply.extend(chunk)
        response = bytes(reply[:-1])
        if response == b"stream: OK":
            return "CLEAN"
        if response.startswith(b"stream: ") and response.endswith(b" FOUND"):
            return "INFECTED"
        raise ValueError("Scanner did not return a definite verdict")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", default="/run/clamav/clamd.ctl")
    parser.add_argument("--expect-unavailable", action="store_true")
    arguments = parser.parse_args()
    try:
        clean = scan(arguments.socket, b"Uten company document clean acceptance probe\n")
        if arguments.expect_unavailable:
            raise ValueError("The unavailable probe unexpectedly connected")
        # Build the standard safe antivirus test string only in memory. No EICAR
        # object is placed in /tmp, the media store, or the application database.
        eicar = (b"X5O!P%@AP[4\\PZX54(P^)7CC)7}$" + b"EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*")
        infected = scan(arguments.socket, eicar)
        if clean != "CLEAN" or infected != "INFECTED":
            raise ValueError("Clean/EICAR classification did not match")
        report = {"status": "PASS", "clean": clean, "eicar": infected}
    except (OSError, ValueError) as error:
        if arguments.expect_unavailable and isinstance(error, OSError):
            report = {"status": "PASS", "unavailable": True}
        else:
            print(json.dumps({"status": "FAIL", "reason": str(error)}), file=sys.stderr)
            return 1
    print(json.dumps(report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
