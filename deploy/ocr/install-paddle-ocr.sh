#!/usr/bin/env bash
# 发票识别侧车安装/升级 (只能由 root 直接执行, 服务使用独立无登录账号)。
# 用法：sudo bash install-paddle-ocr.sh [--prepare-models] [--verify]
# 设计：/opt/uten-ocr（venv + 模型缓存 + 本脚本同目录的服务文件），
# systemd 常驻 127.0.0.1:8501；安装后设为开机自启 (2026-10-06, ADR-157), 不在安装时启动。
# 零外部 API：PaddleOCR 为 Apache-2.0 开源，纯 CPU 推理（ADR-094）。
set -euo pipefail
# 安装过程里任何 python 都不往 /opt/uten-ocr 写 __pycache__ (2026-09-20 曾留下运维账号所有的缓存)。
export PYTHONDONTWRITEBYTECODE=1
# Python package metadata must be readable by the separate service account.
# The installer handles public program files only; secret/runtime directories
# use explicit restrictive modes below and in the systemd unit.
umask 022

DEST=/opt/uten-ocr
PY=python3
prepare_models=false
verify_service=false
for argument in "$@"; do
  case "$argument" in
    --prepare-models) prepare_models=true ;;
    --verify) verify_service=true ;;
    *) printf 'Unknown option: %s\n' "$argument" >&2; exit 2 ;;
  esac
done

log() { printf '[install-paddle-ocr] %s\n' "$*"; }

need_root_hint() {
  if [[ "$(id -u)" != 0 ]]; then
    log "请使用 sudo 以 root 安装；运行服务不使用管理员账号"; exit 1
  fi
}

# 代码目录 (模型缓存除外) 只能归 root: 清掉别的账号留下的字节码缓存, 其余非 root 文件直接拒绝。
require_root_owned_tree() {
  local stray
  rm -rf -- "$DEST/__pycache__"
  stray=$(find "$DEST" -path "$DEST/models" -prune -o \( ! -user root -o ! -group root \) -print -quit)
  [[ -z "$stray" ]] || { log "拒绝继续: $stray 不归 root (只能由 root 安装或升级)"; exit 1; }
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
install -d -m 0750 -o root -g uten-ocr "$DEST/models"
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

if [[ "$prepare_models" == true ]]; then
  PADDLE_PDX_CACHE_HOME="$DEST/models" "$DEST/venv/bin/python" "$DEST/prepare_models.py"
fi
for model in PP-OCRv5_mobile_det PP-OCRv5_mobile_rec PP-LCNet_x1_0_textline_ori; do
  [[ -d "$DEST/models/official_models/$model" ]] \
    || { log '固定模型尚未准备；显式使用 --prepare-models 完成下载后再安装/启用'; exit 1; }
done
[[ -z "$(find "$DEST/models" -xdev -type l -print -quit)" ]] \
  || { log '模型目录不能含符号链接'; exit 1; }
chown -R --no-dereference root:uten-ocr "$DEST/models"
find "$DEST/models" -xdev -type d -exec chmod 0750 {} +
find "$DEST/models" -xdev -type f -exec chmod 0640 {} +
sudo -u uten-ocr /usr/bin/test ! -w "$DEST/models" \
  || { log '运行账号仍能写模型目录，拒绝启用'; exit 1; }

require_root_owned_tree
install -m 0644 uten-paddle-ocr.service /etc/systemd/system/uten-paddle-ocr.service
systemctl daemon-reload
# 开机自启 (只 enable 不 start): 服务器重启后发票识别不再静默缺席。
systemctl enable uten-paddle-ocr

if [[ "$verify_service" == true ]]; then
  was_active=false
  systemctl is-active --quiet uten-paddle-ocr && was_active=true
  log "启动并自检 …"
  # 已在运行的实例用 restart 加载新代码; 原来没运行的, 自检后恢复为停止。
  systemctl restart uten-paddle-ocr
  for i in $(seq 1 60); do
    if curl -sf http://127.0.0.1:8501/health >/dev/null 2>&1; then break; fi
    sleep 2
  done
  curl -sf http://127.0.0.1:8501/health && echo
  if [[ "$was_active" == true ]]; then
    log "自检通过；原来在运行, 保持运行"
  else
    log "自检通过；原来没运行, 自检后停止 (开机自启已设置)"
    systemctl stop uten-paddle-ocr
  fi
fi

log "完成。已设开机自启; 现在就启动: systemctl start uten-paddle-ocr (后端 provider=paddle 时才会调用)"
df -h /opt | tail -1
