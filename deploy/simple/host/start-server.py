#!/usr/bin/python3
"""Bind the application status version to the physical release being started."""
import os
from pathlib import Path
import re
import sys

VERSION = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")
VERSION_OPTION = "-Duten.server-status.application-version="


def server_command(release: Path, arguments: list[str], releases: Path = Path("/opt/uten-imp/releases")) -> list[str]:
    physical = release.resolve(strict=True)
    if (release != physical or physical.parent != releases.resolve(strict=True)
            or not physical.is_dir() or not VERSION.fullmatch(physical.name)):
        raise ValueError("Application working directory is not a physical versioned release")
    jar = physical / "server" / "uten-imp-server.jar"
    if jar.resolve(strict=True) != jar or not jar.is_file():
        raise ValueError("Application jar must be a real file in this release")
    if len(arguments) < 2 or arguments[-2:] != ["-jar", "server/uten-imp-server.jar"]:
        raise ValueError("Application launcher requires the release-local server jar")
    options = [argument for argument in arguments[:-2] if not argument.startswith(VERSION_OPTION)]
    return ["/usr/bin/java", *options, VERSION_OPTION + physical.name, "-jar", str(jar)]


def main() -> int:
    try:
        command = server_command(Path.cwd(), sys.argv[1:])
    except (OSError, ValueError):
        print("Uten application release identity validation failed; refusing to start", file=sys.stderr)
        return 1
    os.execv(command[0], command)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
