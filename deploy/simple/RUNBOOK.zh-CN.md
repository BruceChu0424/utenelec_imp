# Uten IMP 简化发布链 Runbook（ADR-060）

> 唯一维护者操作手册。旧 `deploy/` 重链已退役为参考，与本文冲突时以本文为准。
> **2026-09-02 首装实测勘误**：updater OSS 签名改 Authorization 头（版本控制桶不支持 URL 签名）、
> releases 属主/nginx 组权限、uten-imp.service ReadWritePaths、CSP style-src、内网必须 HTTPS
> （内部 CA + `erp-trust-init.bat`）。详见
> [首装执行记录与勘误](../../docs/99-项目治理/2026-09-02-首装执行记录与勘误.md)。
> **手把手版（含阿里云/GitHub 控制台逐步截图位与验收清单）见
> [新库上线与首装操作指引](../../docs/99-项目治理/2026-09-01-新库上线与首装操作指引.md)。**
> 日常发版 = 打 tag 推 GitHub，其余全自动；只有含数据库迁移的版本需要一次 SSH。
> **占位符约定**：文中 `<服务器IP>` 等尖括号占位符代表真实环境值（不入库防泄露），
> 操作时替换为本机 Tailscale IP / 真实账号等。

## 架构一览

```
你（任意地点）──git tag & push──▶ GitHub（Quality Gate + simple-release）
                                      │ 构建+签名+上传
                                      ▼
                              阿里云 OSS releases/<v>/** + LATEST.txt
                                      │ 每天 05:00（北京时间）拉取验签
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

# 2. 目录布局
mkdir -p /opt/uten-imp/releases /etc/uten-imp /etc/uten-imp-updater /var/backups/uten-imp
chown root:root /opt/uten-imp /opt/uten-imp/releases

# 3. 数据库先按下文的独立安装/现有主机协议准备。
#    不在这里创建应用账号拥有的数据库，不将密码放进 shell 命令。
#    应用使用 uten，迁移使用 uten_migrator；schema 由正式 migrator 建立。

# 4. 配置文件（从本仓库 deploy/ 拷贝后改 REPLACE）
#    /etc/uten-imp/server.env        ← 参考 deploy/setup/server.env.internal-test.example
#    /etc/uten-imp/migrator.env      ← 独立迁移角色 uten_migrator，不能复制应用账号配置
#    /etc/uten-imp-updater.env       ← 参考 deploy/simple/updater.env.example
#    /etc/uten-imp-updater/allowed_signers ← 发布公钥（见上）
chmod 600 /etc/uten-imp/server.env /etc/uten-imp/migrator.env /etc/uten-imp-updater.env

# 5. 安装更新器与 systemd 单元
cp deploy/simple/uten-imp-updater.sh /usr/local/sbin/uten-imp-updater && chmod 755 $_
cp deploy/simple/units/uten-imp.service deploy/simple/units/uten-imp-updater.{service,timer} \
   /etc/systemd/system/
systemctl daemon-reload

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

附件办公文档预览（装了 1b 才需要，覆盖 doc/docx/rtf/odt、xls/xlsx/ods、ppt/pptx/odp、svg 共 11 种；图片/PDF/文本/CSV/zip 由客户端自己渲染，不经服务器）：`server.env` 加 `UTEN_ATTACHMENT_PREVIEW_ENABLED=true`（可选 `UTEN_ATTACHMENT_PREVIEW_SOFFICE_PATH=/usr/bin/soffice`、`UTEN_ATTACHMENT_PREVIEW_TIMEOUT_SECONDS=60`、`UTEN_ATTACHMENT_PREVIEW_MAX_CONCURRENT=2`、`UTEN_ATTACHMENT_PREVIEW_CACHE_MAX_BYTES=1073741824`）。转换缓存与 LibreOffice 用户配置目录都落在附件根目录 `/data/uten-imp/attachments/{preview,scratch}` 下，`uten-imp.service` 的 `ReadWritePaths=/data/uten-imp/attachments` 已覆盖，无需再放开其它目录（`PrivateTmp=true` 保持）。验收：上传一个 docx 和一个 pptx，点「预览」都应弹出 PDF；`journalctl -u uten-imp | grep -i preview` 无 "soffice is not executable" 告警。没装 `libreoffice-draw` 时 svg 预览会失败并回落为下载，其余类型不受影响。

当前独立 migrator 固定连接同机 `127.0.0.1:5432/uten_imp`、使用 `uten_migrator`，从 `UTEN_MIGRATOR_DB_PASSWORD` 读取专用密码（20–512 位字母数字）。激活前只检查变量存在、格式和该角色真实连接/DDL权限，不打印密码。应用角色与迁移角色分离，数据库名、主机或端口不符合这一部署协议时先修正部署方案，不能等到停服后才发现凭据缺失。

**因为连接串写死, 不要在服务器上拿它对副本库"演练"**(改 `UTEN_DB_URL` 无效, 会直接迁正式库; 2026-09-24 v2.0.0 发版踩过)。迁移演练在开发机克隆库上做: pg_dump 服务器库 → 本机恢复 → 用待发布 JAR 起实例指向克隆库。

## 数据与附件备份

日常备份统一使用[配套备份](../postgres/backup/PAIRED_INTERNAL_BACKUP.zh-CN.md)，以同一数据库快照和原件校验生成可恢复集合。旧 `uten-backup-daily` 入口只委托该程序，不再先导出数据库、后 `rsync --delete` 或自动覆盖上一份附件副本。安装入口前必须配齐 `/usr/local/lib/uten-imp/paired_internal_backup.py`、系统依赖和 `/etc/uten-imp/paired-internal-backup.json`；配置保持 root:root、0600，备份集合保持私有权限。

每台服务器仅启用一条日常备份定时器。已经使用 `uten-paired-internal-backup.timer` 的主机继续沿用它，不重复启用旧 `uten-backup.timer`。修改前查实际 unit、最后成功时间与恢复结果，不能从脚本存在推断已生效。历史备份只在核对实际路径、保留需求和可恢复性后处理。

## 四、日常发版（全自动）

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

- 服务器每天 **05:00（北京时间）** 自动拉取（要立即上线可 SSH 执行
  `sudo /usr/local/sbin/uten-imp-updater check`）；**没动数据库**的版本直接自动激活（失败自动回滚上一版）；
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

迁移前备份由更新器以`0700`目录和`0600`文件保存，文件名带随机后缀，重复激活不会覆盖同秒的旧备份。空备份、目录权限设置失败或`pg_dump`失败都会停止激活。权限在备份创建处单独设置，发行目录和JAR继续保留应用/Nginx需要的读取权限。

升级旧更新器时，另行只读列出实际`UTEN_BACKUP_DIR`及其已有dump的所有者/权限，确认后按明确路径收紧旧备份为`0600`、目录为`0700`；新代码不会自动重写历史文件。恢复时由root读取私有dump并流入postgres的`pg_restore`，不需要把备份临时开放给普通用户。相关回归为`deploy/updater/test_simple_release_backup.py`，文件权限验证必须在Linux执行。

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

版本目录的列出与保留由更新器`release_versions`统一处理，只接受语义化`vMAJOR.MINOR.PATCH`目录（2026-09-18 起从日期号 `vYYYY.MM.DD-N` 切换；切换前留在服务器上的旧日期号目录不再被识别，属「未识别目录」，不会被自动删除，确认无需回退后可人工清理）。2026-09-12修复了旧`ls .../ | sed`把带尾斜杠的整个路径删空的问题：它会使`status`显示空版本且旧版本保留策略失效。新实现按版本排序，只清理保留数量之外的已识别目录，始终保护正在运行的版本；未识别目录不自动删除。保留数量不在1至9999、版本记录与实际current链接不一致或链接不可核对时，停止清理并保留全部文件，不把已健康激活的版本误报为发布失败。对应5项回归为`deploy/updater/test_simple_release_retention.py`。更新脚本源码与安装到`/usr/local/sbin/uten-imp-updater`是两个步骤，目标安装必须另外核验摘要。

| 症状 | 命令 |
|---|---|
| 看更新器在干什么 | `journalctl -u uten-imp-updater.service -n 100` |
| 看后端日志 | `journalctl -u uten-imp.service -n 200` |
| 回退应用 | 先确认数据库结构兼容，并使用已验签的保留版本；含迁移时按第五节恢复匹配的数据库与应用组合 |
| 迁移失败恢复库 | 保持停写；核对失败迁移及备份摘要，先向独立库恢复并验证，再切换匹配组合，见第五节 |
| 误激活坏版本 | 纯代码版早已自动回滚；含迁移版按上一条恢复备份 |
| 应用反复崩溃（duplicate key users_employee_id_key） | 核对引导账号与已有员工/用户映射及环境配置；修复已确认的冲突后再启动，不能新建重复身份 |
| 更新器报「启动或健康检查失败」，但日志里明明有 `Started …Application` | 不是新版本起不来，是判活拿不到 UP。`curl -sS $UTEN_HEALTH_URL` 看 readiness，再逐个查它的四个探针 `readinessState,db,diskSpace,attachmentSafety`——2026-09-22 就是发行版自动升级（clamav 1.5.3→1.5.4）后 `clamav-daemon.socket` 重复绑定 3310 起不来，附件探针 UNAVAILABLE 把整组拖成 DOWN，发布被误判失败并回滚 |
| `clamav-daemon.socket` 报 `Address already in use` 但 3310 上没有进程 | 是自己绑了自己：clamav 1.5.4 起包里自带 socket 生成器，按 `clamd.conf` 生成了两条 `ListenStream`，我们 `/etc` 里的 drop-in 再追加一条就重复了。drop-in 必须先 `ListenStream=` 清空再写回环两条，见 `deploy/systemd/clamav-uten-imp-loopback.socket.conf.example` |

## 七、纪律红线

- 永远不要手工改 `/opt/uten-imp/current` 指向未验签目录、或往 releases 目录手工拷 JAR；
- 私钥（`RELEASE_SIGNING_KEY`）只存在 GitHub secret + 你的冷备份两处，不出现在任何服务器；
- 服务器/数据库/SSH 不暴露公网；远程管理走 VPN；
- 打 tag 前确认对应提交 Quality Gate 全绿（自动触发，看到红叉别发）。

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
