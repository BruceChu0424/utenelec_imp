#!/usr/bin/env python3
"""Retired automatic updater entry point. Never reads a schedule or contacts OSS.

Kept for installations whose old timer still invokes this file during upgrade.
The manual operations installer disables that timer. Authorization and explicit
user action now enter host_operations.py; this compatibility entry cannot update.
"""
import json


def main():
    print(json.dumps({'manualOnly': True, 'automaticUpdatesRetired': True,
                      'message': 'Use the authorized Check and update action in System Settings.'}))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
