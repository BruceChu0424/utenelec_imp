# Uten IMP 简化发布链 Runbook（ADR-060）

> 唯一维护者操作手册。旧 `deploy/` 重链已退役为参考，与本文冲突时以本文为准。
> **2026-09-02 首装实测勘误**：updater OSS 签名改 Authorization 头（版本控制桶不支持 URL 签名）、
> releases 属主/nginx 组权限、uten-imp.service ReadWritePaths、CSP style-src、内网必须 HTTPS
> （内部 CA + `erp-trust-init.bat`）。详见
> [首装执行记录与勘误](../../docs/99-项目治理/2026-09-02-首装执行记录与勘误.md)。
> **手把手版（含阿里云/GitHub 控制台逐步截图位与验收清单）见
> [新库上线与首装操作指引](../../docs/99-项目治理/2026-09-01-新库上线与首装操作指引.md)。**
> 日常发版 = 打 tag 推 GitHub 后按需手动拉取；自动检查间隔在系统设置中配置（默认每周日），含数据库迁移的版本需手动激活。
> **占位符约定**：文中 `<服务器IP>` 等尖括号占位符代表真实环境值（不入库防泄露），
> 操作时替换为本机 Tailscale IP / 真实账号等。
> **2026-10-06 服务器安全基线** (ADR-157)：目录与保留规范、密钥纪律、离线托管件、删除流程、告警、
> 恢复演练和维护窗口顺序见第九节；所有备份只保留 3 天；systemd 单元与主机配置的唯一来源是
> `deploy/simple/units/` 与 `deploy/simple/host/`。执行记录见
> [2026-10-06 服务器安全整改](../../docs/99-项目治理/2026-10-06-服务器安全整改.md)。

## 架构一览

```
你（任意地点）──git tag & push──▶ GitHub（Quality Gate + simple-release）
                                      │ 构建+签名+上传
                                      ▼
                              阿里云 OSS releases/<v>/** + LATEST.txt
                                      │ 按系统设置到期拉取（默认每周日当地 05:00）
                                      ▼
公司服务器 updater ──▶ /opt/uten-imp/releases/<v>
      ├─ 纯代码：自动激活（切 current + 重启 + 健康检查，失败自动回滚）
      └─ 含迁移：暂存后等你 SSH：uten-imp-updater activate <v>
                  （自动 pg_dump 备份 → migrator → 切换 → 健康检查）
Nginx：web 静态 + /api 反代 127.0.0.1:8080（deploy/nginx/uten-imp-http-lan.conf）
```

## 一、GitHub 侧（一次性，5 分钟）

1. 新库 Settings → Secrets and variables → Actions：
   - **Secrets**（3 个）：
     - `OSS_ACCESS_KEY_ID` / `OSS_ACCESS_KEY_SECRET` —— 发布用 RAM 子账号（见下）
     - `RELEASE_SIGNING_KEY` —— 下面第 2 步生成的**私钥**全文
   - **Variables**（2 个必填）：`OSS_BUCKET`、`OSS_ENDPOINT`
   - **Variables**（可选）：`OSS_UPLOAD_ENDPOINT` —— 只作用于上传。GitHub 托管跑批机在境外，
     传境内桶是整条发布链唯一的慢点（2026-09-21 同样的产物传了 1h23m，隔天同样的产物 4 分钟）。
     桶上开了传输加速后把它填成 `oss-accelerate.aliyuncs.com`：发布前会先打一个探针对象试水，
     加速不可用就原样回落 `OSS_ENDPOINT`，不会因为一个加速开关发不出去。下载与清理仍走 `OSS_ENDPOINT`。
2. 生成发布签名密钥（在本机或任意可信机器，私钥另存一份冷备份）：

   ```bash
   umask 077
   ssh-keygen -t ed25519 -a 100 -C uten-imp-release -f ./uten-imp-release-ed25519
   ```

   `uten-imp-release-ed25519`（私钥）→ 填进 secret；`.pub`（公钥）→ 装到服务器
   `/etc/uten-imp-updater/allowed_signers`，内容一行：

   ```text
   uten-imp-release ssh-ed25519 AAAA……公钥内容……
   ```

## 二、阿里云 OSS 侧（一次性，10 分钟）

1. 建桶（私有读写都关，仅授权访问），**开启版本控制**；跨境发布建议同时**开启传输加速**
   （控制台 → 该桶 → 传输加速），再把 GitHub 变量 `OSS_UPLOAD_ENDPOINT` 填成
   `oss-accelerate.aliyuncs.com`；加速按流量另计费，只用于上传；
2. RAM 建两个子账号，都只授权这一个桶：
   - **发布账号**（给 GitHub）：`PutObject/GetObject` 限 `releases/*` 与 `LATEST.txt`；
   - **服务器账号**（给 updater）：仅 `GetObject` 同前缀，无任何写删权限；
   - 密钥分别填进 GitHub Secrets 和 `/etc/uten-imp-updater.env`。

## 三、服务器首装（现场半天，只做这一次）

前提：Ubuntu 24.04、内网、出站可访问 OSS。

```bash
# 1. 系统包与账号
apt update && apt install -y openjdk-21-jre-headless nginx curl python3
# 1b. 附件办公文档在线预览（可选）：LibreOffice 无头转换 + 中日韩字体，缺失时预览接口回落为下载原件
#     writer=doc/docx/rtf/odt，calc=xls/xlsx/ods，impress=ppt/pptx/odp，draw=svg（2026-09-11 起需要）
apt install -y --no-install-recommends libreoffice-core libreoffice-writer libreoffice-calc \
  libreoffice-impress libreoffice-draw fonts-noto-cjk
useradd --system --home /opt/uten-imp --shell /usr/sbin/nologin uten-imp
# nginx 只加入 uten-web 组 (只能读发行目录里的 web/), 不加入 uten-imp 组 (2026-10-06)
groupadd --system uten-web && usermod -aG uten-web www-data

# 2. 目录布局 (完整规范见第九节「目录与保留规范」; /srv/uten-backup 是独立的本机备份卷, 先建卷挂载)
mkdir -p /opt/uten-imp/releases /etc/uten-imp /etc/uten-imp-updater
chown root:root /opt/uten-imp /opt/uten-imp/releases
install -d -o root -g root -m 0700 /srv/uten-backup/pre-activation
# 附件卷 (NVMe 独立 LV, 按 UUID 挂到 /var/lib/uten-imp-media, nodev,nosuid,noexec,errors=remount-ro) 挂好后再建;
# uten-imp.service 把下面两个目录写成必须存在的 ReadWritePaths, 缺任何一个, 第 7 步激活时
# systemctl start uten-imp 会报 226/NAMESPACE 并走失败分支
findmnt /var/lib/uten-imp-media >/dev/null || echo '附件卷还没挂载: 先挂载, 再执行下面两行'
install -d -o uten-imp -g uten-imp -m 0700 /var/lib/uten-imp-media/attachments
install -d -o uten-imp -g uten-imp -m 0700 /var/log/uten-imp

# 3. 数据库先按下文的独立安装/现有主机协议准备。
#    不在这里创建应用账号拥有的数据库，不将密码放进 shell 命令。
#    应用使用 uten，迁移使用 uten_migrator；schema 由正式 migrator 建立。

# 4. 配置文件（从本仓库 deploy/ 拷贝后改 REPLACE）
#    /etc/uten-imp/server.env        ← 参考完整 deploy/setup/server.env.internal-storage.example
#    /etc/uten-imp/migrator.env      ← 独立迁移角色 uten_migrator，不能复制应用账号配置
#    /etc/uten-imp-updater.env       ← 参考 deploy/simple/updater.env.example
#    /etc/uten-imp-updater/allowed_signers ← 发布公钥（见上）
#    当前prod/internal例子含DB/JWT/PGP/HMAC/AI独立密钥和bootstrap基础字段；逐个生成并替换占位。
#    internal-test例子只属于退役closed-local参考链，不能用于本Simple单元首装。
#    首次激活前先准备ClamAV Unix socket（uten-imp组0660、父目录0755）；确认媒体卷、
#    真干净文件/EICAR和成套备份恢复，再开放附件上传。旧引用存在时先只读盘点再显式开旧读取开关，不能删旧目录。
chown root:uten-imp /etc/uten-imp/server.env
chmod 640 /etc/uten-imp/server.env
chmod 600 /etc/uten-imp/migrator.env /etc/uten-imp-updater.env

# 5. 安装更新器与 systemd 单元
cp deploy/simple/uten-imp-updater.sh /usr/local/sbin/uten-imp-updater && chmod 755 $_
install -d -o root -g root -m 0755 /usr/local/lib/uten-imp
install -o root -g root -m 0644 deploy/simple/update_schedule.py /usr/local/lib/uten-imp/update_schedule.py
install -o root -g root -m 0755 deploy/simple/host/start-server.py /usr/local/lib/uten-imp/start-server.py
cp deploy/simple/units/uten-imp.service deploy/simple/units/uten-imp-updater.{service,timer} \
   /etc/systemd/system/
systemctl daemon-reload
# 备份单元 (uten-pgbackup、uten-paired-internal-backup) 在 pgBackRest 与备份卷就绪后按「数据与附件备份」一节安装

# 6. Nginx 站点
cp deploy/nginx/uten-imp-http-lan.conf /etc/nginx/sites-available/uten-imp
# 编辑：__INTERNAL_DOMAIN__ → 内网域名；__EXACT_OFFICE_CIDR__ → 办公网段
ln -s /etc/nginx/sites-available/uten-imp /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default   # 按需保留
nginx -t && systemctl enable --now nginx

# 7. 发首个版本：本机打 tag v1.0.0 push → GitHub 出制品进 OSS
/usr/local/sbin/uten-imp-updater check          # 下载暂存（会提示首装需人工激活）
/usr/local/sbin/uten-imp-updater activate v1.0.0   # 备份→建库→切换→健康检查

# 8. 通过后开机自启 + 定时更新
systemctl enable --now uten-imp.service uten-imp-updater.timer
```

数据库必须先区分全新主机与已有 PostgreSQL 的主机。全新专用主机使用[数据库初始化脚本](../setup/phase2-postgres.sh)及对应前置检查；它负责安装 PostgreSQL 和分离应用、迁移、所有者身份，拒绝任何已有集群。已有数据库不得执行该脚本，也不能删掉集群来通过检查；按[现有角色加固协议](../setup/harden-existing-postgres-roles.sh)先核对当前权限和恢复路径，再实施适合该主机的改动。公司已有库的小版本更新仅执行正式前向迁移，不重新初始化角色、数据库或密钥。

验证：浏览器开内网域名登录；`uten-imp-updater status` 全绿。

附件办公文档预览(装了 1b 才需要，覆盖 doc/docx/rtf/odt、xls/xlsx/ods、ppt/pptx/odp、svg 共 11 种；图片/PDF/文本/CSV/zip 由客户端自己渲染，不经服务器)：`server.env` 加 `UTEN_ATTACHMENT_PREVIEW_ENABLED=true`(可选 `UTEN_ATTACHMENT_PREVIEW_SOFFICE_PATH=/usr/bin/soffice`、`UTEN_ATTACHMENT_PREVIEW_TIMEOUT_SECONDS=60`、`UTEN_ATTACHMENT_PREVIEW_MAX_CONCURRENT=2`、`UTEN_ATTACHMENT_PREVIEW_CACHE_MAX_BYTES=1073741824`)。转换缓存与 LibreOffice 用户配置目录都落在附件卷 `/var/lib/uten-imp-media/attachments/{preview,scratch}` 下 (2026-10-06 起；旧 `/data/uten-imp/attachments` 不再可写)，`uten-imp.service` 的 `ReadWritePaths=/var/lib/uten-imp-media/attachments /var/log/uten-imp` 已覆盖，无需再放开其它目录 (`PrivateTmp=true` 保持)。应用 `UMask=0077`，缓存与日志都只归 uten-imp 自己读写。验收：上传一个 docx 和一个 pptx，点「预览」都应弹出 PDF；`journalctl -u uten-imp | grep -i preview` 无 "soffice is not executable" 告警。没装 `libreoffice-draw` 时 svg 预览会失败并回落为下载，其余类型不受影响。

当前独立 migrator 固定连接同机 `127.0.0.1:5432/uten_imp`、使用 `uten_migrator`，从 `UTEN_MIGRATOR_DB_PASSWORD` 读取专用密码（20–512 位字母数字）。激活前只检查变量存在、格式和该角色真实连接/DDL权限，不打印密码。应用角色与迁移角色分离，数据库名、主机或端口不符合这一部署协议时先修正部署方案，不能等到停服后才发现凭据缺失。

**因为连接串写死, 不要在服务器上拿它对副本库"演练"**(改 `UTEN_DB_URL` 无效, 会直接迁正式库; 2026-09-24 v2.0.0 发版踩过)。迁移演练在开发机克隆库上做: pg_dump 服务器库 → 本机恢复 → 用待发布 JAR 起实例指向克隆库。

## 数据与附件备份

日常备份统一使用[配套备份](../postgres/backup/PAIRED_INTERNAL_BACKUP.zh-CN.md)，以同一数据库快照和原件校验生成可恢复集合；数据库另有 pgBackRest 全量 + WAL。旧 `uten-backup-daily` 入口及 `uten-backup.{service,timer}` 已于 2026-10-06 从仓库删除，服务器上按整改计划同步删除。安装配套备份前必须配齐 `/usr/local/lib/uten-imp/paired_internal_backup.py`、系统依赖和 `/etc/uten-imp/paired-internal-backup.json`；配置保持 root:root、0600，备份集合保持私有权限。现役单元只来自 `deploy/simple/units/` (`uten-pgbackup.{service,timer}` 与 `uten-paired-internal-backup.{service,timer}`，整文件安装到 `/etc/systemd/system/` 后 `daemon-reload`、`enable --now` 两个 timer；用 `deploy/setup/phase2-postgres.sh` 新装的专用主机沿用它自己的备份单元，不混装)。修改前查实际 unit、最后成功时间与恢复结果，不能从脚本存在推断已生效。

### 备份布局与保留 (2026-10-06 起, 所有备份只保留 3 天)

每份备份都和它保护的数据放在不同的物理盘上。三类备份各自保留，互不代管：

| 备份 | 位置 (所在盘) | 频率 | 保留 | 谁来删 |
|---|---|---|---|---|
| pgBackRest repo1 全量 + WAL | `/data/backups/pgbackrest` (md0 机械盘阵列, 与库同盘) | 每天 02:17 (`uten-pgbackup.timer`) | `repo1-retention-full=3` | backup 结束时 pgBackRest 自动 expire |
| pgBackRest repo2 全量 + WAL, aes-256-cbc | `/srv/uten-backup/pgbackrest` (本机 NVMe 独立卷) | 同一单元紧接 repo1 | `repo2-retention-full=3` | 同上 |
| 配套备份 (库 + 附件原件) | `/data/uten-imp-backups/paired` (md0) | 每天 03:40 与 13:10 (`uten-paired-internal-backup.timer`) | 最近 3 个日历日 (含当天)，且至少保留最新 3 份；`retention_days` 可调 1..365 | 每次成功后由配套备份程序自己清理，结果计数写进 `last-attempt.json`，清理跳过/失败时服务器状态页报红；规则见[配套备份手册](../postgres/backup/PAIRED_INTERNAL_BACKUP.zh-CN.md)「自动保留」 |
| 升级前 dump | `/srv/uten-backup/pre-activation` (NVMe) | 仅含迁移的激活 | 最近 `UTEN_BACKUP_KEEP_DAYS` 个日历日 (默认 3)，最新一份永远保留 | 更新器激活且健康检查通过后清理，见第四节 |
| 异地仓 repo3 | 独立 OSS bucket + WORM (待建, 治理记录 D6/C2) | - | 至少 3 天 | - |

**repo 编号**：repo1 = `/data` 机械盘阵列 (现有)；repo2 = 本机 NVMe 加密仓 (`deploy/simple/host/pgbackrest-20-uten-imp-repo2.conf.example`)；repo3 = 异地 OSS (待建)。已退役的 `deploy/postgres/backup/README.zh-CN.md` 里 "repo2=OSS" 的编号作废，以本表为准。WAL 归档保持同步 (不开 archive-async)，archive-push 同时推 repo1 与 repo2。

repo1 保留期改为 3 之前，先验收仓库化的[本地双仓只读健康入口](../postgres/backup/LOCAL_BACKUP_HEALTH.zh-CN.md)：
`deploy/postgres/backup/local_backup_health.py` 与 `deploy/simple/units/uten-pgbackup-health.{service,timer}`。
新入口共用 3 个恢复点门槛，仍输出 `/var/lib/uten-imp-backup-health/health.json` 给状态页。
实际服务器若还指向 `/usr/local/libexec/uten-imp-monitoring/local_backup_health.py`，说明仍是旧的未版本化脚本，
按交接手册先备份旧单元/脚本，再完整安装、只读验收新入口；不能仅凭仓库已有文件推断现场已切换。
确认新健康入口与两仓恢复点通过后，才调整 repo1 的 `repo1-retention-full=3`；下一次 02:17 备份结束自动 expire。
旧受控双仓链的门禁 (`pgbackrest_repo2`、`backup_commissioner`、`backup_acceptance`、`release_updater`) 同样保持 3 个恢复点。

repo2 口令只在服务器上由管道生成并直接写进正式文件，不进命令行参数、不落临时文件 (下面整段经 SSH 标准输入执行)，写完立即重做离线托管件 (第九节)：

```bash
sudo install -d -o root -g postgres -m 0750 /etc/pgbackrest /etc/pgbackrest/conf.d
sudo sh -c 'umask 027; f=/etc/pgbackrest/conf.d/20-uten-imp-repo2.conf;
  { printf "[global]\nrepo2-path=/srv/uten-backup/pgbackrest\nrepo2-retention-full-type=count\nrepo2-retention-full=3\nrepo2-bundle=y\nrepo2-cipher-type=aes-256-cbc\nrepo2-cipher-pass=";
    openssl rand -base64 48 | tr -d "\n"; printf "\n"; } > "$f.new" && chown root:postgres "$f.new" && mv "$f.new" "$f"'
sudo -u postgres pgbackrest info | grep -q 'repo2' || echo 'repo2 未被读取: 把上面几行并入 /etc/pgbackrest.conf 的 [global]'
sudo -u postgres pgbackrest --stanza=uten-imp stanza-create && sudo -u postgres pgbackrest --stanza=uten-imp check
```

`uten-pgbackup.service` 整文件替换服务器上 2026-08-11 的两行简版：两个仓各跑一次全量，任一仓失败不影响另一个仓，但单元记为失败；不再单独跑 expire；不加 PrivateTmp (锁目录 `/tmp/pgbackrest` 与 archive-push 共用)。单元只硬依赖 repo1 所在的 `/data` (`RequiresMountsFor=/data/backups/pgbackrest`)；备份卷只 `Wants`/`After`，repo2 路径在 `ReadWritePaths` 里带 `-`，所以备份卷坏了或没挂上时 repo1 照常备份，repo2 那条命令报错、单元记失败并走告警。

**备份卷 (repo2) 掉了先处理 WAL 归档**：WAL 归档是同步推两个仓的，repo2 不可写时每次 archive-push 都返回失败，PostgreSQL 会一直重试同一个 WAL 段，两个仓的归档都停住，`/data` 上的 `pg_wal` 持续变大 (巡检的 wal-archive 告警会报)。卷当天修不好时 (按 `du -sh /data/postgresql/16/main/pg_wal` 的增长速度和 `/data` 剩余空间估算)，先临时停用 repo2，让归档只推 repo1：

```bash
# 只改名不删 (文件里有 repo2 口令); pgBackRest 只读 conf.d 下的 *.conf。
# 若当初 repo2 几行是并进 /etc/pgbackrest.conf [global] 的, 改用 sudoedit 临时注释掉那几行 repo2-*。
sudo mv /etc/pgbackrest/conf.d/20-uten-imp-repo2.conf /etc/pgbackrest/conf.d/20-uten-imp-repo2.conf.disabled
# 几分钟内 last_archived_time 应追到当前, last_failed_time 不再更新
sudo -u postgres psql -XAtc "select last_archived_wal, last_archived_time, last_failed_time from pg_stat_archiver"
```

停用期间每天的 `uten-pgbackup` 仍会因 `--repo=2` 报错而告警，用来提醒还没恢复。卷修好、重新挂上后改回原名，`sudo -u postgres pgbackrest --stanza=uten-imp check` 通过后只给 repo2 补一份全量 `sudo -u postgres pgbackrest --stanza=uten-imp --repo=2 --type=full backup` (不重跑整个单元，免得 repo1 多出一份全量、按份数挤掉一天)；停用期间 repo2 缺的那段 WAL 补不回来，repo2 的时间点恢复从这份新全量起算。

服务器上 2026-10-05 之前装的配套备份脚本 (v1，2026-09-09) 没有任何自动删除，装新版本前按配套备份手册「安装前核对」第 6、7 条处理。其它历史目录 (人工 dump、旧版本快照等) 不在任何自动规则内，按第九节「删除流程」核对后直接删除。

## 四、日常发版（按需手动拉取，可配置自动检查间隔）

公司运行 `prod` 且强制HTTPS时，更新器的 `UTEN_HEALTH_URL` 也必须指向Nginx提供的HTTPS
readiness地址，使用证书中包含的内部域名或IP，并安装内部CA；不能仍用会302跳转的后端HTTP地址，
也不能用 `-k` 绕过证书检查。局域网白名单从实际网卡的CIDR核对，不能默认公司一定使用 `/24`。

2026-09-09 用户明确允许本次先发布、CI继续运行：手动 `workflow_dispatch` 可显式勾选
`allow_running_checks`（默认关闭）。仍检查同一提交、最新运行与尝试，已失败/取消的工作流或任务、
缺失及不完整证据继续阻断；只允许尚在排队/运行且没有已失败任务的检查继续并行。
构建前和签名前各核对一次，发布记录标注“CI未完成”，不冒充检查全绿。普通tag触发不能开启此选项。
版本包依然由原发布密钥签名并上传阿里云OSS，业务附件和数据库使用内部服务器。

Simple Release现在在构建前强制核验实际检出提交SHA对应的三个既有工作流：
`quality.yml`（Quality Gate）、`codeql.yml`（CodeQL）、`osv-scanner.yml`
（Dependency Vulnerability Scan）。每个工作流以文件路径和GitHub数值ID识别，取该SHA的
最新运行，并重新读取其当前重跑次数；三者都必须为 `completed/success`。
旧提交的绿灯、同名其他工作流、旧成功记录之后的失败或进行中重跑都不能放行。

构建完成后、签名和OSS凭证注入前再次检查，防止构建期间启动的重跑被旧成功状态掩盖。
检查只使用当前作业的 `GITHUB_TOKEN`（步骤内名为 `GH_TOKEN`），权限限于
`contents: read`、`actions: read`，不需要增加发布私钥或云端账号权限。
没有运行、运行中、失败/取消、SHA/工作流不符或API错误都会停止发布；不自动等待或重试。
先完成/修复同一SHA的质量工作流，再从GitHub界面手动重新运行失败的Simple Release。
`.github/scripts/test_release_gate.py`提供离线回归并在发布作业的门禁前执行。

```bash
git tag v1.4.1 && git push origin v1.4.1
```

- 服务器默认每周日 **05:00（服务器当地时间）** 自动拉取（要立即上线可 SSH 执行
  `sudo /usr/local/sbin/uten-imp-updater check`）；**没动数据库**的版本直接自动激活（失败自动回滚上一版）；
- 系统设置的 `updater_check_interval_days` 接受 `0..365`：`0` 仅手动，`7` 为每周日；
  其他 `N` 从设置修改的服务器当地日期加 `N` 天开始，此后每隔 `N` 天当地 05:00 执行。
  `7` 的首次执行是严格晚于设置修改时刻的首个周日 05:00。服务器时区可通过
  `timedatectl show -p Timezone --value` 核实，本次不改变原有时区或 05:00 时刻。
- systemd 每分钟运行 `update_schedule.py`，**只读本机 PostgreSQL**。未到期、仅手动、
  配置缺失/非法或数据库不可读时不访问 OSS。设置保存后约一分钟内被读取，无需重启；
  不补昨天及更早的计划，同一当地日期最多自动尝试一次（含失败与中断），失败后可手动重试。
  没有开机专用触发或定时器补跑；同一到期日 05:00 后恢复服务会执行当日尚未尝试的计划。
- 系统设置页读取 root 生成的 `/var/lib/uten-imp/updater-schedule/status.json`，显示实际已读取的
  间隔、下次执行和最后尝试；保存值不等于服务器已应用。缺失、过期、与数据库设置不一致或
  执行失败必须显示未同步/异常。该状态查询与保存设置都不产生 OSS GET。
  `uten-imp-updater status` 仍会访问 OSS 读取最新版本，只用于主动检查，不接入周期状态探测。
- **OSS 只保留最新一版**：发布流水线在发布成功后自动删除 `releases/` 下旧版本
  （含版本控制桶的历史版本与删除标记）。若发布 RAM 子账号缺 `DeleteObject` 权限，
  发布作业的 Purge 步骤会告警（发布本身不受影响）——去 RAM 控制台给发布账号策略
  追加 `DeleteObject`（资源限 `releases/*` 与 `LATEST.txt`）即可；
- **动了数据库**（`server/src/main/resources/db/migration/` 有增改）的版本：等 CI 完成
  → `uten-imp-updater check` 暂存 → 在维护窗口 SSH：

  ```bash
  /usr/local/sbin/uten-imp-updater status
  /usr/local/sbin/uten-imp-updater activate v1.5.0
  # 自动：pg_dump 全量备份 → migrator → 原子切换 → 健康检查
  # 失败：代码回滚、应用停止、备份文件路径会打印出来，按路径人工恢复
  ```

迁移前备份由更新器以`0700`目录和`0600`文件保存，文件名带随机后缀，重复激活不会覆盖同秒的旧备份。`pg_dump`先写`<正式名>.partial`，成功且非空后才以硬链接发布为正式名 (不覆盖已有文件)；失败、为空时立即删掉`.partial`，所以目录里不会出现像正式备份的半截文件。空备份、目录权限设置失败或`pg_dump`失败都会停止激活。权限在备份创建处单独设置，发行目录和JAR继续保留应用/Nginx需要的读取权限。

迁移前备份默认放 `/srv/uten-backup/pre-activation` (本机 NVMe 备份卷，与库所在的 `/data` 阵列不同盘；2026-10-06 起，旧默认 `/var/backups/uten-imp`)。含迁移的激活在**停应用之前**先确认该目录可建可写，备份盘没挂载时直接报错退出，应用照常运行、数据库不动。

迁移前备份的保留 (2026-10-05 起)：每次激活**健康检查通过后** (紧跟旧版本目录清理 `prune_old`) 执行 `prune_database_backups`，只处理 `UTEN_BACKUP_DIR` 下一层、名称严格为更新器自己生成格式 `<库名>-vX.Y.Z-YYYYMMDD-HHMMSS.<6位随机>.dump` 的普通文件 (符号链接、子目录、人工 dump 如 `uten_imp-pre-rollback-*.dump`、`ocr-before-*` 目录一律不碰)。年龄取文件名里的服务器本地日期 (不看 mtime)，保留最近 `UTEN_BACKUP_KEEP_DAYS` 个日历日 (默认 3，含当天；只接受 1..365，非法值记日志并整轮跳过)，时间戳最新的一份**已完成的非空** dump (含同秒并列) 无论多旧都保留；`.partial` (更新器被强杀时留下) 和空文件不参与「最新一份」的判定，只按日期清理，目录里一份完成的 dump 都没有时整轮不删。每删一个都在更新器日志记文件名和释放字节数；激活失败、回滚或迁移失败时不清理。备份目录本身是符号链接或不存在时也跳过。对应回归在 `deploy/updater/test_simple_release_backup.py` 与 `test_simple_release_activation.py`。

升级旧更新器时，另行只读列出实际`UTEN_BACKUP_DIR`及其已有dump的所有者/权限，确认后按明确路径收紧旧备份为`0600`、目录为`0700`；新代码不会自动重写历史文件。恢复时由root读取私有dump并流入postgres的`pg_restore`，不需要把备份临时开放给普通用户。相关回归为`deploy/updater/test_simple_release_backup.py`，文件权限验证必须在Linux执行。

### 已有服务器应用可配置计划

仅发布应用包不会替换已经安装的 systemd 单元。先核对 `systemctl cat uten-imp-updater.service
uten-imp-updater.timer` 及 `systemctl list-timers --all uten-imp-updater.timer`；若有 drop-in
覆盖命令或定时规则，先按实际内容合并，避免旧直接拉取任务与新调度器并行。
确认没有正在执行的更新，完成包含设置登记的数据库前向迁移后，在服务器部署目录执行：

```bash
schedule_backup=$(sudo mktemp -d /var/backups/uten-imp-schedule.XXXXXX)
sudo cp -a /etc/systemd/system/uten-imp-updater.service \
  /etc/systemd/system/uten-imp-updater.timer "$schedule_backup/"
sudo systemctl stop uten-imp-updater.timer
sudo install -d -o root -g root -m 0755 /usr/local/lib/uten-imp
sudo install -o root -g root -m 0644 deploy/simple/update_schedule.py \
  /usr/local/lib/uten-imp/update_schedule.py
sudo install -o root -g root -m 0644 deploy/simple/units/uten-imp-updater.service \
  deploy/simple/units/uten-imp-updater.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now uten-imp-updater.timer
systemctl cat uten-imp-updater.service uten-imp-updater.timer
systemctl list-timers --all uten-imp-updater.timer
# 下一分钟后核验本地回执；它不访问 OSS
sudo cat /var/lib/uten-imp/updater-schedule/status.json
```

调度器使用 root 私有目录 `/var/lib/uten-imp-update-schedule` 的持久化尝试记录和锁去重；
应用仅能读取回执（目录 root:uten-imp 0750、文件 0640），不能改 root 的排程执行记录。
回执上级 `/var/lib/uten-imp` 必须由 root 管理且不可被应用写入；不符合时先核对用途并修正部署，
调度器拒绝使用不安全目录。

回退时先停定时器，从 `$schedule_backup` 恢复两个旧单元后 `daemon-reload`；恢复前的旧计划
可能每日拉取，确认需要该频率后才重新启用，也可保持停用并手动 `check`。验证通过后
`sudo rm -rf "$schedule_backup"`，服务器上不留旧单元副本。
本节不改变数据库与附件备份计划。运行测试：
`python3 -m unittest discover -s deploy/updater -p test_simple_update_schedule.py -v`。

2026-10-06 起 `uten-imp-updater.service` 带沙箱 (`ProtectSystem=strict` 等，ADR-157)：定时触发的检查与
纯代码激活只能写单元注释里列出的几个目录 (`/opt/uten-imp`、`/run/lock`、两个排程状态目录、
升级前 dump 目录)。更新器锁随之从 `/run/uten-imp-updater.lock` 改为 `/run/lock/uten-imp-updater.lock`，
换装前先停定时器、确认没有正在进行的激活。改 `UTEN_BACKUP_DIR` 到别处时同步给该单元加
`ReadWritePaths=` drop-in。维护窗口里人工 `sudo uten-imp-updater activate` 不经过该单元，不受沙箱影响。
`deploy/updater/test_simple_units_contract.py` 校验脚本写到的每个路径都在单元的可写清单里。

### 发行目录权限 (2026-10-06 起)

nginx (`www-data`) 不再加入 `uten-imp` 组，只加入专用组 `uten-web`。更新器暂存和激活时都会执行
`publish_release_permissions`：`releases/<v>` 为 root:uten-imp 0751 (别的账号只能穿过、不能列目录)，
`server/` 为 root:uten-imp 0750 (nginx 读不到 JAR)，`web/` 为 root:uten-web 0750、文件 0640。
`uten-web` 组不存在、或 `www-data` 不在该组时，更新器在下载或停应用之前直接报错退出，提示先执行
`groupadd --system uten-web && usermod -aG uten-web www-data` 并重启 nginx (worker 重新加载组成员)。
现有服务器的切换顺序 (先让 nginx 进 `uten-web`、再换装新更新器)。`sudo -u www-data test` 按 `/etc/group`
的当前内容判断，www-data 还在 `uten-imp` 组时它一定通过，证明不了退组以后还读得到；所以预检用 `setpriv`
直接模拟「退组以后」的身份 (只带 www-data、uten-web 两个组)，退组并重启 nginx 后再经 nginx 本身正向复查：

```bash
sudo groupadd --system uten-web && sudo usermod -aG uten-web www-data
sudo sh -c 'for r in /opt/uten-imp/releases/v*/; do chgrp -R uten-web "$r/web" && chmod -R g+rX,o-rwx "$r/web" && chmod 0751 "$r"; done'
# web-extra 只放公开的根 CA 证书 (80 端口 /ca/ 下载), 同样交给 uten-web 组读
sudo sh -c 'chgrp -R uten-web /opt/uten-imp/web-extra && chmod -R g+rX,o-rwx /opt/uten-imp/web-extra'
sudo systemctl restart nginx                     # worker 重新加载组成员
# 预检 (退组前): 模拟退组以后的身份, 两行都打印 OK 才往下走
as_web() { sudo setpriv --reuid=www-data --regid=www-data --groups=www-data,uten-web -- "$@"; }
as_web test -r /opt/uten-imp/current/web/index.html && echo WEB_OK
as_web test -r /opt/uten-imp/web-extra/uten-imp-root-ca.crt && echo CA_OK
# 任一不 OK: 看哪一级目录穿不过 (每级都要对 www-data 或 uten-web 有 x), 修好后重跑预检
sudo namei -l /opt/uten-imp/current/web/index.html /opt/uten-imp/web-extra/uten-imp-root-ca.crt
# 退组, 然后经 nginx 正向复查 (这时才是退组以后的真实结果)
sudo gpasswd -d www-data uten-imp && sudo systemctl restart nginx
curl -sk -o /dev/null -w 'site %{http_code}\n' https://127.0.0.1/                          # 期望 site 200
curl -s -o /dev/null -w 'ca %{http_code}\n' http://127.0.0.1/ca/uten-imp-root-ca.crt     # 期望 ca 200
sudo -u www-data test -r /opt/uten-imp/current/server/uten-imp-server.jar && echo BAD || echo JAR_DENIED_OK
sudo -u www-data test -r /var/log/uten-imp/server.log && echo BAD || echo LOG_DENIED_OK
# 复查任一不是 200: 先回退恢复访问, 再按 namei -l 查原因
#   sudo usermod -aG uten-imp www-data && sudo systemctl restart nginx
```

OSS 请求签名 (2026-10-06 起)：AccessKey Secret 只经环境变量交给 python 计算 HMAC，不再出现在
`openssl -hmac` 的命令行参数里 (`/proc/<pid>/cmdline` 本机任何账号都能读)。回归
`deploy/updater/test_simple_release_signing.py` 用替身进程记录所有命令行，断言其中没有 Secret。

## 五、数据库替换与旧系统首次导入

日常小版本更新只走第四节的前向迁移，不替换公司数据库。开发副本刷新、旧系统首次导入和公司已有库升级是三个不同入口，不能共用“先删库、再恢复”的操作清单。

- **已有公司库升级**：签名候选先在可丢弃的公司备份副本上演练，核对 Flyway 校验和、行数、数量、金额与审计证据，再在维护窗口由更新器执行前向迁移。
- **旧系统首次导入**：使用[旧数据导入入口](../../server/legacy_migration/README.md)的当前候选校验、来源清单和显式目标库证明。只能导入独立空业务库，通过全模块对账后才具备切换资格；不能对已经经营的公司库执行 bootstrap。
- **确需替换公司数据库**：先按下列步骤准备独立恢复库，保留现行库及其原版本，维护窗口仅切换已经验收的应用与数据库组合。

### 替换前必须具备的证据

1. 固定源端导出时点与业务停止写入边界；在允许业务写入后重新导出的旧快照不能作为最终切换依据。生成数据库与附件配套备份，使用 SHA-256 验证传输和存储摘要，并实际恢复验证。
2. 只向显式命名的独立恢复库导入，使用 `pg_restore --exit-on-error`；任何非零退出都停止。遇到扩展、所有者或授权不兼容，先在副本查明依赖并修复导出/恢复方案，不能忽略错误或直接删除源库扩展。
3. 使用与待发布 JAR 一致的正式 migrator 前向升级，保留完整 Flyway 身份与校验和。较新的数据库也不能未经兼容验证直接搭配较旧的后端。
4. 核对应用角色、迁移角色、对象所有者和最小权限；保留公司的加密、签名及数据库配置。不能套用宽泛的全表/全函数授权，也不能用本机环境文件覆盖公司配置。
5. 对账主档、库存数量、预留与消耗、应收应付与关键金额、审计、附件原件和可用账号；在隔离环境走岗位业务流程。核对现有管理员映射，不能靠修改引导账号或反复启动来绕过身份冲突。
6. 记录旧应用、旧库、附件集合、新组合及回退路径；停写后做最终增量核对，切换后验证 HTTPS readiness、Flyway、登录与权限、业务读取及错误日志。验收通过再恢复员工写入。

失败时保留停写状态，先确定迁移与新业务写入是否发生。恢复数据库和附件必须使用同一已验证集合；先恢复到独立库、完成校验，再切回匹配的应用和数据库配置。不能直接在唯一现行库上执行 `--clean`，不能把旧 JAR 指向已经不兼容的新结构。旧库与备份保留到明确的恢复保留期结束。

详细备份与恢复协议见[配套备份手册](../postgres/backup/PAIRED_INTERNAL_BACKUP.zh-CN.md)；当前候选和服务器的实际证据见[当前版本验证](../../docs/99-项目治理/当前版本验证.md)。历史事故记录仅供诊断，不替代本节步骤。

## 六、故障速查

版本目录的列出与保留由更新器`release_versions`统一处理，只接受语义化`vMAJOR.MINOR.PATCH`目录(2026-09-18 起从日期号 `vYYYY.MM.DD-N` 切换；切换前留在服务器上的旧日期号目录不再被识别，属「未识别目录」，不会被自动删除，确认无需回退后可人工清理；2026-10-06 整改计划把它们删除)。2026-10-06 起每次清理都会在更新器日志里逐个点名未识别的条目 (`report_unrecognized_releases`)，不让它们悄悄堆满磁盘。2026-09-12修复了旧`ls .../ | sed`把带尾斜杠的整个路径删空的问题：它会使`status`显示空版本且旧版本保留策略失效。新实现按版本排序，只清理保留数量之外的已识别目录，始终保护正在运行的版本；未识别目录不自动删除。保留数量不在1至9999、版本记录与实际current链接不一致或链接不可核对时，停止清理并保留全部文件，不把已健康激活的版本误报为发布失败。对应5项回归为`deploy/updater/test_simple_release_retention.py`。更新脚本源码与安装到`/usr/local/sbin/uten-imp-updater`是两个步骤，目标安装必须另外核验摘要。

| 症状 | 命令 |
|---|---|
| 看更新器在干什么 | `journalctl -u uten-imp-updater.service -n 100` |
| 看后端日志 | `journalctl -u uten-imp.service -n 200` |
| 回退应用 | 先确认数据库结构兼容，并使用已验签的保留版本；含迁移时按第五节恢复匹配的数据库与应用组合 |
| 迁移失败恢复库 | 保持停写；核对失败迁移及备份摘要，先向独立库恢复并验证，再切换匹配组合，见第五节 |
| 误激活坏版本 | 纯代码版早已自动回滚；含迁移版按上一条恢复备份 |
| 应用反复崩溃（duplicate key users_employee_id_key） | 核对引导账号与已有员工/用户映射及环境配置；修复已确认的冲突后再启动，不能新建重复身份 |
| 更新器报「启动或健康检查失败」，但日志里明明有 `Started …Application` | 不是新版本起不来，是判活拿不到 UP。`curl -sS $UTEN_HEALTH_URL` 看 readiness，再逐个查它的四个探针 `readinessState,db,diskSpace,attachmentSafety`——2026-09-22 就是发行版自动升级（clamav 1.5.3→1.5.4）后 `clamav-daemon.socket` 重复绑定 3310 起不来，附件探针 UNAVAILABLE 把整组拖成 DOWN，发布被误判失败并回滚 |
| `clamav-daemon.socket` 报 `Address already in use` 但 3310 上没有进程 | 是自己绑了自己：clamav 1.5.4 起包里自带 socket 生成器，按 `clamd.conf` 生成了两条 `ListenStream`，我们 `/etc` 里的 drop-in 再追加一条就重复了。drop-in 必须先 `ListenStream=` 清空；新版应用已支持 Unix socket，当前模板只保留 `/run/clamav/clamd.ctl`，见 `deploy/systemd/clamav-uten-imp-unix.socket.conf.example` |

## 七、纪律红线

- 永远不要手工改 `/opt/uten-imp/current` 指向未验签目录、或往 releases 目录手工拷 JAR；
- 私钥（`RELEASE_SIGNING_KEY`）只存在 GitHub secret + 你的冷备份两处，不出现在任何服务器；
- 服务器/数据库/SSH 不暴露公网；远程管理走 VPN；
- 打 tag 前确认对应提交 Quality Gate 全绿（自动触发，看到红叉别发）。
- 任何秘密 (数据库口令、OSS Secret、备份仓口令、webhook 地址) 都不出现在命令行参数里；
  服务器上不留临时脚本、导出文件或配置副本，运维命令经 SSH 标准输入执行 (第九节「密钥纪律」)。

## 八、发票识别侧车（PaddleOCR，可选，ADR-094）

报销图片识别使用本地开源PaddleOCR，固定 `PP-OCRv5_mobile_det/mobile_rec` 与文本行方向模型、CPU推理，服务只监听回环8501。
Apache-2.0 许可不等于零运行成本；票据不发往外部 AI 服务。部署文件、步骤、验证及回滚见
[OCR 部署说明](../ocr/README.md)，法规及人工核验边界见[报销凭证清单](../../docs/07-业务链路/员工报销合规依据与凭证清单.md)。

- 后端默认 `UTEN_EXPENSE_OCR_PROVIDER=disabled`。完成样本验证并按发布流程批准后再设置 `paddle`；
  endpoint 默认 `http://127.0.0.1:8501`，应用限制为同机回环 HTTP，不允许外部票据服务地址。
- 图片仅 JPEG/PNG/WebP，最大8MB、4000万像素、单边30000像素；拒绝动画图与格式不符内容。
  后端和侧车均限制并发。PDF/OFD/XML 作为原件附件保存，不能直接发送给图片识别端点。
- `/health` 仅证明 HTTP 存活，`engine_loaded` 仅说明是否加载过引擎；部署还须使用脱敏样本实际推理，
  检查字段建议、耗时、内存、并发拒绝、错误路径及断网重启。不能用健康接口200代替识别验收。
- Nginx对 `/api/expense-claims/invoices/recognize` 精确路径使用9MB请求体/130秒代理等待，
  原通用2MB/45秒不能直接用于照片识别；Dart该请求140秒，Java默认60秒且可配置不超过120秒。
  9MB仅容纳multipart封装，实际图片仍限制8MB，其他接口不随此放宽。
- 侧车只回传文字行，Java `InvoiceTextParser` 生成待人工确认的建议；不得在日志记录票据文字或完整原图。
  模型缓存位于 `/opt/uten-ocr/models`，运维通过 `prepare_models.py` 显式预置并核验；
  侧车只读取现成v5缓存，缺失即失败，不在员工提交图片时下载模型。
- PaddleX固定3.7.2，OpenCV使用上游指定 `opencv-contrib-python==4.10.0.84`；本轮真实模型准备
  确认headless替代会被上游依赖检查拒绝。Linux补 `libgomp1/libgl1` 及对应glib运行库，无需桌面；
  具体清理冲突wheel和安装步骤以[部署说明](../ocr/README.md)及安装脚本为准。
- 停用时把 provider 改为 `disabled` 并按发布流程重启后端，再 `systemctl disable --now uten-paddle-ocr`。
  仅停侧车但保留 `paddle` 会返回识别失败，而不是“未配置”；两者都应允许员工改为手工录入。

2026-09-19的[历史验收](../../docs/99-项目治理/2026-09-19-员工报销全链路验收.md)仅记录当时的未启用状态。当前 PP-OCRv5 的实机推理、隔离权限、断网重启及后端配置状态，以[当前版本验证](../../docs/99-项目治理/当前版本验证.md)中的同次证据为准；不能用旧实现的耗时或健康接口替代。

## 九、服务器安全基线 (2026-10-06, ADR-157)

本节是服务器整改后的目标状态与日常纪律。逐项执行顺序、现状和待用户决定的事项见
[2026-10-06 服务器安全整改](../../docs/99-项目治理/2026-10-06-服务器安全整改.md)。
systemd 单元只来自 `deploy/simple/units/`，其它主机配置只来自 `deploy/simple/host/`
(清单与安装方式见 [host/README](host/README.zh-CN.md))。

### 9.1 目录与保留规范

原则：每份备份都和它保护的数据放在不同的物理盘上；秘密只放在 root 可读的地方，另有一份离线托管件。
**服务器上所有备份只保留 3 天。**

| 用途 | 路径 | 所在盘 | 属主/权限 | 保留 |
|---|---|---|---|---|
| 在线附件 | `/var/lib/uten-imp-media/attachments/{staging,final,scratch,preview}/<类别>/<YYYYMM>/...` (文件名由服务端随机生成) | NVMe 独立卷, `nodev,nosuid,noexec,errors=remount-ro` | 目录 uten-imp 0700, 文件 0600 | 业务决定 |
| 数据库 PGDATA | `/data/postgresql/16/main` | md0 RAID1 机械盘 | postgres 0700 | 迁 NVMe 见治理记录 C11 |
| pgBackRest repo1 | `/data/backups/pgbackrest` | md0 | postgres 0750 | 3 份全量 + WAL |
| pgBackRest repo2 (加密) | `/srv/uten-backup/pgbackrest` | NVMe 独立卷 `uten-backup` | postgres 0750, aes-256-cbc | 3 份全量 + WAL |
| 配套备份 (库 + 附件) | `/data/uten-imp-backups/paired/<UTC时间>Z-<12hex>/` | md0 | root 0700 / 文件 0600 | 3 天且至少 3 份, 每天 2 次 |
| 升级前 dump | `/srv/uten-backup/pre-activation/` | NVMe `uten-backup` | root 0700 / 文件 0600 | 3 天 (最新一份永远保留, 更新器自动清理) |
| 临时导出 / 恢复演练 | `/srv/uten-backup/adhoc`, `/srv/uten-backup/drill` | NVMe `uten-backup` | root 0700 / postgres 0700 | 用完即删, 不过夜 |
| 异地仓 repo3 (待建) | 独立 OSS bucket, 开 WORM | 云 | 专用 RAM 子账号, 无删除权限 | 至少 3 天 |
| 配置与密钥 | `/etc/uten-imp/*.env`, `/etc/uten-imp-updater.env`, `/etc/pgbackrest.conf`, `/etc/pgbackrest/conf.d/*.conf` | NVMe 根 | root 0600 / root:postgres 0640 | 另有离线托管件 |
| 程序 | `/opt/uten-imp/releases/vX.Y.Z` (`current` 为 symlink) | NVMe 根 | root:uten-imp 0751, `web/` root:uten-web 0750 | 更新器保留 5 版 |
| 告警状态 | `/var/lib/uten-alert` | NVMe 根 | root 0700 | - |

`/srv/uten-backup` 挂载点本身 `chattr +i`：卷没挂上时任何程序都写不进去，备份不会悄悄落到系统盘；
fstab 带 `nofail`，阵列或备份卷出问题时系统照样启动、SSH 不丢。

### 9.2 密钥纪律

- 秘密一律不出现在命令行参数里：`sudo` 会把整条命令记进 journal，`/proc/<pid>/cmdline` 本机任何账号可读。
  只用 `sudoedit`、`psql \password`、root 0600 文件或管道/标准输入传递。
- 服务器上不留任何临时脚本、导出文件或配置副本。运维命令写在管理机本地文件里，经
  `ssh <运维账号>@<服务器IP> 'sudo bash -s' < 本机脚本` 执行；要装的文件经
  `ssh ... 'sudo install -m <权限> /dev/stdin <目标>' < 本机文件` 传入，装完比对 sha256。
- 部署文件一律从 `main` 的 git blob 取原始字节 (`git show main:<路径> > 文件`)，不用 PowerShell 重定向
  (会转码)，不直接拷工作区文件 (可能是 CRLF)。
- PostgreSQL 慢日志与错误日志不记绑定参数 (`log_parameter_max_length = 0`、
  `log_parameter_max_length_on_error = 0`)：应用把 PII 主钥作为绑定参数传给 `pgp_sym_encrypt/decrypt`。
- `postgres` 超级用户没有口令，只能本机 peer 登录；除 `postgres`、`uten`、`uten_migrator`、`uten_repl`
  外不允许任何可登录角色 (`harden-existing-postgres-roles.sh` 前后都检查)。
- 进程不产生 core dump (`uten-imp.service` 的 `LimitCORE=0`、`fs.suid_dumpable=0`、停用 apport)：
  JVM 内存里有数据库口令和主钥。
- SSH 只认密钥 (`PasswordAuthentication no`、`KbdInteractiveAuthentication no`、`AuthenticationMethods publickey`)，
  cloud-init 钉死 `ssh_pwauth: false`。sudo 免密本次保留 (自动化依赖 `sudo -n`)，白名单列为长期项。

### 9.3 离线托管件

两位管理员各自 `age-keygen`，私钥只在自己手里；服务器上只用两把公钥加密，托管件不在服务器上落盘。

- **托管内容**：`/etc/uten-imp/server.env`、`migrator.env`、`paired-internal-backup.json`、
  `/etc/uten-imp-updater.env`、`/etc/uten-imp-updater/allowed_signers`、`/etc/pgbackrest.conf`、
  `/etc/pgbackrest/conf.d/`、`/etc/ssl/private/uten-imp-lan.key` 与证书；历史密钥 (旧 PGP 主钥可能还用于
  解密历史导出) 单独一份；根 CA 私钥单独一份，托管后从服务器删除。
- **何时重做**：轮换任何密钥、修改任何 env、生成或修改备份仓口令之后，当天重做。
- **存两处**：密码管理器附件 + 保险柜里的加密 U 盘。
- **每月演练**：用私钥解开一次 (`age -d -i <私钥> <托管件> | tar -tvf -`)，确认能打开；解出的明文看完即删。

生成方式：在管理机上执行，托管件经 SSH 管道直接落到管理机，服务器上不落任何文件
(服务器需装 `age`；`R` 为两把 age 公钥，形如 `-r age1... -r age1...`)：

```bash
ssh <运维账号>@<服务器IP> "sudo sh -c 'cd / && tar -cf - etc/uten-imp/server.env etc/uten-imp/migrator.env \
  etc/uten-imp/paired-internal-backup.json etc/uten-imp-updater.env etc/uten-imp-updater/allowed_signers \
  etc/pgbackrest.conf etc/pgbackrest/conf.d etc/ssl/private/uten-imp-lan.key etc/ssl/certs/uten-imp-lan.crt \
  | age $R'" > uten-keys-current-$(date +%Y%m%d).tar.age
age -d -i <私钥> uten-keys-current-$(date +%Y%m%d).tar.age | tar -tvf -   # 只列清单核对, 不落明文
```

### 9.4 删除流程

确认无用就直接删除，不设隔离期 (2026-10-06 用户口径)：

1. **核对**：只读确认它不在任何运行路径里 (`systemctl cat`、`readlink -f /opt/uten-imp/current`、
   `active-version.txt`、配置里的路径)，备份类确认更新的一份已经 `--verify` 或 `pgbackrest info` 通过。
2. **点名删除**：只按明确的完整路径删除，不用会扩大范围的通配；目录先 `ls -la` 看清再删。
   程序自己命名的备份集合只交给程序自己的保留规则清理，人工补删时只删 `<UTC时间>Z-<12hex>` 与
   `.incomplete-*` 这两种名字。
3. **含秘密的文件** (`*.env*`、口令文件、托管件、dump) 用 `shred -u` 删除；NVMe 上 shred 只是尽力而为，
   真正起作用的是轮换密钥。日志里出现过现行密钥的，删日志的同时轮换该密钥。
4. **记录**：删了什么、为什么、核对依据，写进当次治理记录。

### 9.5 平台内服务器告警

各单元已带 `OnFailure=uten-alert@%n.service`；每 10 分钟的只读巡检 `uten-host-check` 检查磁盘、
RAID、关键服务、WAL 归档和备份新鲜度 (pgBackRest 26 小时、配套备份 16 小时)；SMART 与 mdadm
各有钩子。`uten-alert` 调用固定 Python 记录器, 在 root 控制的本机文件中保留有界事件。
安装清单、权限和保留边界见 [主机配置](host/README.zh-CN.md)。群机器人配置已删除。
应用单元读取 `UTEN_SERVER_STATUS_HOST_ALERT_FILE=/var/lib/uten-alert/events.json`, 后台按持久事件 UUID
去重, 只发给当前有告警接收权和通知阅读权的活跃账号。警告与危急告警进入中央弹窗, 逐条确认;
切换账号会立即关闭旧账号弹窗, 恢复通知仍用普通顶部提示。告警不依赖额外 webhook 或外网。

接入验证: `sudo systemctl start uten-alert@test.service`, 确认本机事件文件成功写入, 再由授权员工
登录平台看到测试弹窗; 重启后台后同一事件不重复发布。记录器损坏文件/队列满会失败并保留证据。
ERP 完全停机时不能即时显示平台弹窗, 事件最多保留 7 天等待恢复, 不宣称替代外部宕机通知。
含数据库迁移的升级由更新器在停应用前校验 `uten-imp` 可读取 migrator, 随后备份并以该账号执行
迁移 JAR; 迁移配置只在独立子进程导出, 日志写 `/var/log/uten-imp/migrator.log`。安装前确认该目录
归应用账号可写, 不给迁移进程主机 root 权限。数据库迁移仍使用专用数据库迁移角色。

### 9.6 恢复演练 (每月一次, 不碰生产库)

repo1 与 repo2 轮流：本月从 repo2 恢复 (顺带验证加密仓)，下月从 repo1。全程在
`/srv/uten-backup/drill` 下起一个只监听本地 socket、端口 5433 的临时实例，演练完整个目录删掉。

```bash
sudo -u postgres pgbackrest --stanza=uten-imp verify
sudo install -d -o postgres -g postgres -m 0700 /srv/uten-backup/drill/pg /srv/uten-backup/drill/sock
sudo -u postgres pgbackrest --stanza=uten-imp --repo=2 --pg1-path=/srv/uten-backup/drill/pg \
  --type=time --target='<昨天某个时刻 +08>' --target-action=promote --archive-mode=off restore
# 必须带 --archive-mode=off, 否则演练库会往生产仓推 WAL
# 写最小 postgresql.conf (port=5433, listen_addresses='', unix_socket_directories 指向 drill/sock,
# archive_mode=off, ssl=off) 后用 pg_ctl 启动, 查 flyway 头版本、users 行数、audit_log 最新时间,
# 关键表 (货品、销售单、库存流水、应收) 行数与生产同一时点对比; 再把最新配套备份 --verify 后
# pg_restore 进同一实例的 paired_check 库核对。
sudo -u postgres /usr/lib/postgresql/16/bin/pg_ctl -D /srv/uten-backup/drill/pg -m fast stop
sudo rm -rf /srv/uten-backup/drill/pg /srv/uten-backup/drill/sock
```

结果 (目标时间、恢复耗时 RTO、数据丢失窗口 RPO、头版本、是否通过) 记入当月治理记录，服务器上不留结果文件。
加密字段能否解密在正式演练脚本 `deploy/setup/drill-restore.sh` 里验证，手工演练不在命令行输入密钥。
每月定时化见治理记录 C9。

### 9.7 维护窗口顺序 (需要停机的整改)

窗口避开 02:17 pgBackRest、03:40 与 13:10 配套备份、周日 05:00 更新器；重启时必须有人在机房或有带外控制台。
全程保持两条 SSH 会话 (Tailscale 与局域网各一条)，改 sshd 前先挂 "10 分钟后自动回退" 的定时器。

1. **开窗 (不停服)**：停 `uten-imp-updater.timer` 与巡检定时器；手动跑一次 `uten-pgbackup` 与配套备份并核验。
2. **停机段一 (约 3-5 分钟)**：停 `uten-imp`；用 `psql \password` 轮换 `uten` 与 `uten_migrator` 口令，
   `sudoedit` 改两个 env (清空 `BOOTSTRAP_ADMIN_PASSWORD`、`UTEN_BOOTSTRAP_ADMIN_RETIRED=true`)，
   跑 `validate-server-env.sh` / `validate-migrator-env.sh`；整文件换装 `deploy/simple/units/uten-imp.service`
   并删除并入的 `uten-v538-mounts.conf` drop-in；先在当前版本上启动验证 (readiness、登录切账号、
   上传附件过 ClamAV、导出打印、AI 识别、服务器状态页)。
3. **停机段二 (约 3-10 分钟)**：`uten-imp-updater activate <新版本>`，升级前 dump 应落在
   `/srv/uten-backup/pre-activation/`。健康检查失败先看 `journalctl -u uten-imp` 有没有 Started。
4. **更新器换新 + web 分组 (ERP 不停, nginx 两次秒级重启)**：按第四节「发行目录权限」切换 `uten-web`，
   换装新的 `uten-imp-updater` 与 `uten-imp-updater.service`，`uten-imp-updater status && check` 必须成功
   (新的签名计算访问 OSS)。
5. **OCR 与 ClamAV (局部短暂中断)**：先显式准备固定 OCR 模型并收紧为 root:uten-ocr、目录0750/文件0640，
   再换装模型只读的 `uten-paddle-ocr.service`，验证真实样本；临时缓存由 PrivateTmp 隔离。
   ClamAV 使用 `deploy/systemd/clamav-uten-imp-unix.socket.conf.example` 安装到
   `/etc/systemd/system/clamav-daemon.socket.d/uten-unix.conf`，删除旧重复监听 drop-in；
   `/run/clamav` 必须为0755可遍历，socket 为uten-imp组0660，clamd.conf 的 LocalSocket/LocalSocketGroup/LocalSocketMode 同步，
   并移除 TCPAddr/TCPSocket。应用保持原来的 `Group=uten-imp`，与
   `UTEN_CLAMAV_UNIX_SOCKET=/run/clamav/clamd.ctl` 同时生效；启动前由实际服务身份检查 socket 读写权限。
   维护窗口完成后必须以应用身份验证 PING、干净文件、EICAR 拒绝和不可用失败关闭，并确认3310不再监听。
6. **配套备份**：装带自动清理的 `paired_internal_backup.py`，换装两份单元 (每天 2 次)，再手动跑一次并 `--verify`。
7. **停机段三 (约 5-10 分钟)**：系统更新并重启，开机后核对挂载、阵列、sshd、各服务与 WAL 归档。
8. **收尾**：恢复定时器，重做离线托管件 (口令已换)，通知恢复；次日确认 02:17、03:40、13:10 的备份都成功。

每一步的回滚：换装前用 `systemctl cat` / `sha256sum` 记下原文件摘要，原文件内容放管理机 (不在服务器上留副本)，
出问题时经 SSH 标准输入装回原文件并 `daemon-reload`。
