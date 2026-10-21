# Build from the repository root. This is a deployment example, not an automatic release.
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1
WORKDIR /app
COPY services/material_forecast/requirements.txt /app/requirements.txt
RUN python -m pip install --no-cache-dir --require-hashes --only-binary=:all: -r /app/requirements.txt \
    && python -m pip check \
    && useradd --system --uid 10001 forecast \
    && mkdir -p /data && chown 10001:10001 /data
COPY services/material_forecast /app/services/material_forecast
COPY server/src/main/resources/pricing/material-benchmarks.json /app/server/src/main/resources/pricing/material-benchmarks.json
USER 10001:10001
STOPSIGNAL SIGTERM
CMD ["python", "services/material_forecast/worker.py", "--auto", "--output-directory", "/data"]
