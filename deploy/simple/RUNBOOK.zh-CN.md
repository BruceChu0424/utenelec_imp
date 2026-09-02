# Uten IMP 简化发布链 Runbook（ADR-060）

> 唯一维护者操作手册。旧 `deploy/` 重链已退役为参考，与本文冲突时以本文为准。
> **2026-09-02 首装实测勘误**：updater OSS 签名改 Authorization 头（版本控制桶不支持 URL 签名）、
> releases 属主/nginx 组权限、uten-imp.service ReadWritePaths、CSP style-src、内网必须 HTTPS
> （内部 CA + `erp-trust-init.bat`）。详见
> [首装执行记录与勘误](../../docs/99-项目治理/2026-09-02-首装执行记录与勘误.md)。
> **手把手版（含阿里云/GitHub 控制台逐步截图位与验收清单）见
> [新库上线与首装操作指引](../../docs/99-项目治理/2026-09-01-新库上线与首装操作指引.md)。**
> 日常发版 = 打 tag 推 GitHub，其余全自动；只有含数据库迁移的版本需要一次 SSH。

## 架构一览

```
你（任意地点）──git tag & push──▶ GitHub（Quality Gate + simple-release）
                                      │ 构建+签名+上传
                                      ▼
                              阿里云 OSS releases/<v>/** + LATEST.txt
                                      │ 每 5 分钟拉取验签
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
   - **Variables**（2 个）：`OSS_BUCKET`、`OSS_ENDPOINT`
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

1. 建桶（私有读写都关，仅授权访问），**开启版本控制**；
2. RAM 建两个子账号，都只授权这一个桶：
   - **发布账号**（给 GitHub）：`PutObject/GetObject` 限 `releases/*` 与 `LATEST.txt`；
   - **服务器账号**（给 updater）：仅 `GetObject` 同前缀，无任何写删权限；
   - 密钥分别填进 GitHub Secrets 和 `/etc/uten-imp-updater.env`。

## 三、服务器首装（现场半天，只做这一次）

前提：Ubuntu 24.04、内网、出站可访问 OSS。

```bash
# 1. 系统包与账号
apt update && apt install -y openjdk-21-jre-headless postgresql-16 nginx curl python3
useradd --system --home /opt/uten-imp --shell /usr/sbin/nologin uten-imp

# 2. 目录布局
mkdir -p /opt/uten-imp/releases /etc/uten-imp /etc/uten-imp-updater /var/backups/uten-imp
chown root:root /opt/uten-imp /opt/uten-imp/releases

# 3. 数据库（空库；schema 由首版 migrator 建到最新）
sudo -u postgres createuser uten-app
sudo -u postgres psql -c "ALTER USER uten-app PASSWORD '应用密码';"   # 写进 server.env
sudo -u postgres createdb -O uten-app uten_imp

# 4. 配置文件（从本仓库 deploy/ 拷贝后改 REPLACE）
#    /etc/uten-imp/server.env        ← 参考 deploy/setup/server.env.internal-test.example
#    /etc/uten-imp/migrator.env      ← 同源，用同一个数据库账号
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

# 7. 发首个版本：本机打 tag vYYYY.MM.DD-1 push → GitHub 出制品进 OSS
/usr/local/sbin/uten-imp-updater check          # 下载暂存（会提示首装需人工激活）
/usr/local/sbin/uten-imp-updater activate vYYYY.MM.DD-1   # 备份→建库→切换→健康检查

# 8. 通过后开机自启 + 定时更新
systemctl enable --now uten-imp.service uten-imp-updater.timer
```

验证：浏览器开内网域名登录；`uten-imp-updater status` 全绿。

## 四、日常发版（全自动）

```bash
git tag v2026.09.01-1 && git push origin v2026.09.01-1
```

- 5 分钟内服务器自动拉取；**没动数据库**的版本直接自动激活（失败自动回滚上一版）；
- **动了数据库**（`server/src/main/resources/db/migration/` 有增改）的版本：等 CI 完成
  → `uten-imp-updater check` 暂存 → 在维护窗口 SSH：

  ```bash
  /usr/local/sbin/uten-imp-updater status
  /usr/local/sbin/uten-imp-updater activate v2026.09.01-2
  # 自动：pg_dump 全量备份 → migrator → 原子切换 → 健康检查
  # 失败：代码回滚、应用停止、备份文件路径会打印出来，按路径人工恢复
  ```

## 五、数据刷新：把本地/外部数据库灌到服务器

> 适用：测试期把本地开发库刷上去重测；正式数据切换同流程但必须先对账演练。
> 日常经营数据由员工操作直接写入服务器库，**永远不需要手动传输**（需要真实数据做测试时
> 方向反过来：从服务器 `pg_dump` 拉副本下来）。

### 0. 前提

- Tailscale 通：`ssh utenelec@100.109.196.17` 免密可登
- 本地库容器在跑：`docker ps --filter name=uten-imp-postgres`
- 若本地库 Flyway 版本**高于**服务器发布版本：先确认新迁移对现行后端透明（纯新增表/索引），
  否则先走第四节发版再灌数据

### 1. 本地打包

```bash
# 记下版本号（写进文件名）
docker exec uten-imp-postgres psql -U uten -d uten_imp -Atc \
  "SELECT version FROM flyway_schema_history ORDER BY installed_rank DESC LIMIT 1"
docker exec uten-imp-postgres pg_dump -U uten -Fc uten_imp > ~/uten_imp-dev-V<版本>-<日期>.dump
```

### 2. 传输并校验（两端 md5 一致才继续）

```bash
scp ~/uten_imp-dev-V*.dump utenelec@100.109.196.17:/tmp/
md5sum ~/uten_imp-dev-V*.dump
ssh utenelec@100.109.196.17 'md5sum /tmp/uten_imp-dev-V*.dump'
```

### 3. 服务器执行（整段贴入，逐步有输出）

```bash
ssh utenelec@100.109.196.17 'bash -s' <<'REMOTE'
set -e
echo "== 1. 备份现有库（保后悔药）"
sudo -u postgres pg_dump -Fc uten_imp > ~/db-before-refresh-$(date +%Y%m%d-%H%M).dump
ls -lh ~/db-before-refresh-*.dump | tail -1
echo "== 2. 停应用（数据库保持运行）"
sudo systemctl stop uten-imp
echo "== 3. 清空重建"
sudo -u postgres psql -c "DROP DATABASE uten_imp WITH (FORCE);"
sudo -u postgres psql -c "CREATE DATABASE uten_imp OWNER uten;"
echo "== 4. 恢复（postgis 类报错无害，见坑②）"
DBPASS=$(sudo grep -E "^UTEN_DB_PASSWORD=" /etc/uten-imp/server.env | cut -d= -f2-)
PGPASSWORD="$DBPASS" pg_restore -h 127.0.0.1 -U uten --no-owner --no-privileges \
  -d uten_imp /tmp/uten_imp-dev-V*.dump || echo "(已忽略 postgis 类报错)"
echo "== 5. 核对（版本号与员工数应与预期一致）"
PGPASSWORD="$DBPASS" psql -h 127.0.0.1 -U uten -d uten_imp -Atc \
  "SELECT installed_rank||' / '||version FROM flyway_schema_history ORDER BY installed_rank DESC LIMIT 1"
PGPASSWORD="$DBPASS" psql -h 127.0.0.1 -U uten -d uten_imp -Atc "SELECT count(*) FROM employees"
echo "== 6. 启动 + 健康检查"
sudo systemctl start uten-imp
for i in $(seq 1 30); do sleep 3
  curl -fsS --max-time 4 http://127.0.0.1:8080/actuator/health 2>/dev/null | grep -q '"status":"UP"' \
    && { echo "健康 UP"; exit 0; }
done
echo "未就绪——优先查坑①（引导账号撞库）"; sudo journalctl -u uten-imp -n 40 --no-pager | tail -15; exit 1
REMOTE
```

### 4. 验收

浏览器登录（账号 = 灌入库里的账号）抽查数据是否符合预期。

### 已知坑（2026-09-03 实战记录）

1. **引导账号撞库（会崩溃循环）**：应用启动时确保 `BOOTSTRAP_ADMIN_LOGIN`
   （`/etc/uten-imp/server.env`）在库中存在，不存在就新建并可能撞 employees 唯一约束。
   **灌库后该值必须是库中已有账号**（当前=17665410007）。修复：

   ```bash
   ssh utenelec@100.109.196.17
   sudo sed -i 's/^BOOTSTRAP_ADMIN_LOGIN=.*/BOOTSTRAP_ADMIN_LOGIN=<库中已有账号>/' /etc/uten-imp/server.env
   sudo systemctl reset-failed uten-imp && sudo systemctl start uten-imp   # StartLimit 卡死必须先 reset
   ```

2. **postgis 噪音（约 14 条报错，无害）**：本地 postgis 镜像自动装的地理扩展混进 dump，
   服务器没有也不需要，业务零影响。根治（下次 dump 前在本地库执行一次即可）：

   ```sql
   DROP EXTENSION postgis_tiger_geocoder CASCADE;
   DROP EXTENSION postgis_topology CASCADE;
   DROP EXTENSION postgis CASCADE;   -- ERP 无几何字段，安全
   ```

3. **版本不匹配**：库**可以**高于后端（新迁移纯新增时透明）；库**低于**发布版本时恢复后必须补跑
   `java -jar /opt/uten-imp/current/server/uten-imp-migrator.jar`（加载 `/etc/uten-imp/migrator.env`）。

### 正式数据切换（老系统 → 服务器，未来做）

同一流程，但顺序必须是：**源头先在本地演练并逐项对账**（客户/供应商/库存数量/关键金额）
→ 打包传输 → 恢复 →（版本低时）跑 migrator → 员工岗位 UAT 抽查 → **冻结源头机器**。
对账不过关不得让员工开始使用。

## 六、故障速查

| 症状 | 命令 |
|---|---|
| 看更新器在干什么 | `journalctl -u uten-imp-updater.service -n 100` |
| 看后端日志 | `journalctl -u uten-imp.service -n 200` |
| 手动回滚到旧版 | `ln -sfn releases/<旧版> /opt/uten-imp/current.new && mv -T /opt/uten-imp/current.new /opt/uten-imp/current && systemctl restart uten-imp && echo <旧版> > /opt/uten-imp/active-version.txt` |
| 迁移失败恢复库 | 用 `/var/backups/uten-imp/*.dump`：`pg_restore -U postgres -d uten_imp --clean --if-exists <dump>` |
| 误激活坏版本 | 纯代码版早已自动回滚；含迁移版按上一条恢复备份 |
| 应用反复崩溃（duplicate key users_employee_id_key） | 坑①：BOOTSTRAP_ADMIN_LOGIN 不是库中账号；改 env 后 reset-failed 再 start（见第五节） |

## 七、纪律红线

- 永远不要手工改 `/opt/uten-imp/current` 指向未验签目录、或往 releases 目录手工拷 JAR；
- 私钥（`RELEASE_SIGNING_KEY`）只存在 GitHub secret + 你的冷备份两处，不出现在任何服务器；
- 服务器/数据库/SSH 不暴露公网；远程管理走 VPN；
- 打 tag 前确认对应提交 Quality Gate 全绿（自动触发，看到红叉别发）。
