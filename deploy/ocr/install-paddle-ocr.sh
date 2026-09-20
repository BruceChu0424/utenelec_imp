#!/usr/bin/env bash
# 发票识别侧车安装/升级 (以 root 运行，服务使用独立无登录账号)。
# 用法：bash install-paddle-ocr.sh [--verify]
# 设计：/opt/uten-ocr（venv + 模型缓存 + 本脚本同目录的服务文件），
# systemd 常驻 127.0.0.1:8501；安装后默认【停止】状态，启用见 RUNBOOK。
# 零外部 API：PaddleOCR 为 Apache-2.0 开源，纯 CPU 推理（ADR-094）。
set -euo pipefail
# Python package metadata must be readable by the separate service account.
# The installer handles public program files only; secret/runtime directories
# use explicit restrictive modes below and in the systemd unit.
umask 022

DEST=/opt/uten-ocr
PY=python3

log() { printf '[install-paddle-ocr] %s\n' "$*"; }

need_root_hint() {
  if [[ "$(id -u)" != 0 ]]; then
    log "请使用 sudo 以 root 安装；运行服务不使用管理员账号"; exit 1
  fi
}
need_root_hint
[[ "$(realpath -e "$DEST")" = "$DEST" && ! -L "$DEST" ]] \
  || { log "拒绝非真实安装目录"; exit 1; }
chown root:root "$DEST"
chmod 0755 "$DEST"

log "磁盘现状（安装前后对照，防撑爆）："; df -h /opt | tail -1

if ! id uten-ocr >/dev/null 2>&1; then
  useradd --system --user-group --home-dir "$DEST" --no-create-home \
    --shell /usr/sbin/nologin uten-ocr
fi
install -d -m 0750 -o uten-ocr -g uten-ocr "$DEST/models"
chown -R --no-dereference uten-ocr:uten-ocr "$DEST/models"
cd "$DEST"
for f in ocr_server.py uten-paddle-ocr.service requirements.txt prepare_models.py; do
  [[ -f "$f" ]] || { log "缺少 $f (先将对应 deploy/ocr 文件安装到 /opt/uten-ocr/)"; exit 1; }
done

if [[ ! -d venv ]]; then
  log "创建 venv …"
  "$PY" -m venv venv
fi
# OpenCV 的动态库依赖不要求桌面或显示器；PaddleX 按包名检查 contrib wheel。
GLIB_PACKAGE=libglib2.0-0
if apt-cache show libglib2.0-0t64 >/dev/null 2>&1; then GLIB_PACKAGE=libglib2.0-0t64; fi
apt-get install -y -q --no-install-recommends libgomp1 libgl1 "$GLIB_PACKAGE"
./venv/bin/pip install --upgrade pip >/dev/null
log "安装依赖（paddlepaddle CPU 版约 500MB，paddleocr 会另拉模型到 models/）…"
# 清理共享 cv2 命名空间的其它 wheel 后完整重装受支持的 contrib wheel。
./venv/bin/pip uninstall -y -q opencv-python opencv-python-headless opencv-contrib-python-headless >/dev/null 2>&1 || true
./venv/bin/pip install --quiet -r requirements.txt
./venv/bin/pip install --quiet --force-reinstall --no-deps 'opencv-contrib-python==4.10.0.84'
./venv/bin/python -c 'import cv2; print("OpenCV import verified")'
./venv/bin/pip freeze > installed-requirements.txt
# The HTTP service must not be able to replace its own Python code or packages.
chown -R root:root "$DEST/venv"
find "$DEST/venv" -type d -exec chmod 0755 {} +
find "$DEST/venv" -type f -exec chmod a+r,go-w {} +
chown root:root ocr_server.py prepare_models.py requirements.txt uten-paddle-ocr.service
chmod 0644 ocr_server.py prepare_models.py requirements.txt uten-paddle-ocr.service
sudo -u uten-ocr "$DEST/venv/bin/python" -c \
  'import cv2, importlib.metadata as m; assert m.version("opencv-contrib-python") == "4.10.0.84"; assert cv2.__version__.startswith("4.10."); print("Service identity OpenCV import and metadata verified")'
log "pip 依赖完成"; du -sh "$DEST" || true

install -m 0644 uten-paddle-ocr.service /etc/systemd/system/uten-paddle-ocr.service
systemctl daemon-reload

if [[ "${1:-}" == "--verify" ]]; then
  log "启动并自检 …"
  systemctl start uten-paddle-ocr
  for i in $(seq 1 60); do
    if curl -sf http://127.0.0.1:8501/health >/dev/null 2>&1; then break; fi
    sleep 2
  done
  curl -sf http://127.0.0.1:8501/health && echo
  log "自检通过；按本轮口径验证完即停，不常驻"
  systemctl stop uten-paddle-ocr
fi

log "完成。启用（发版配 provider=paddle 时）：systemctl enable --now uten-paddle-ocr"
df -h /opt | tail -1
