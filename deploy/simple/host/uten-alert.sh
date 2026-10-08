#!/bin/sh
# Root-owned local recorder. The application delivers these events inside ERP.
set -eu
exec /usr/bin/python3 -I /usr/local/libexec/uten-host-alert.py "$@"
