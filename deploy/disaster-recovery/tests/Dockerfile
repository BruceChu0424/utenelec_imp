# Disposable test fixture only. Never deploy this image to a business host.
FROM ubuntu:24.04
RUN printf '%s\n' \
      'path-include=/usr/share/man' \
      'path-include=/usr/share/man/man1' \
      'path-include=/usr/share/man/man1/node.1.gz' \
      'path-include=/usr/share/man/man1/nodejs.1.gz' \
      > /etc/dpkg/dpkg.cfg.d/uten-dr-node-manual \
    && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    python3 python3-venv nodejs openssh-client gnupg ca-certificates util-linux \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --user-group --no-create-home --shell /usr/sbin/nologin uten-dr-control
RUN test -s /usr/share/man/man1/node.1.gz \
    && test -e /usr/share/man/man1/nodejs.1.gz \
    && test -e /etc/alternatives/js.1.gz
COPY requirements-linux-cp312.lock /tmp/requirements.lock
RUN python3 -m venv /opt/dr-tests \
    && /opt/dr-tests/bin/python -m pip install --disable-pip-version-check --require-hashes --only-binary=:all: -r /tmp/requirements.lock \
    && /opt/dr-tests/bin/python -m pip check
ENV PATH="/opt/dr-tests/bin:$PATH" PYTHONDONTWRITEBYTECODE=1
WORKDIR /workspace
CMD ["python", "deploy/disaster-recovery/tests/run_contracts.py"]
