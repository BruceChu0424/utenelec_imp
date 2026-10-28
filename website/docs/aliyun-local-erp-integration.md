# 阿里云官网与公司本地 IMP 联动操作手册

核对日期：2026-10-26。适用方案：**官网放阿里云云服务器，公司 IMP 继续运行在公司本地服务器**。官网只展示公司、产品与资料，并接收销售咨询；不提供购物车、支付或在线下单。

本文包括准备、配置、人员操作、验收与恢复流程。当前代码已具备 PostgreSQL 运行候选、持久询盘投递、IMP 授权进入 CMS、内容版本与资料权限。**现有 `website/deploy` 签名发布、启停保护和 paired-state 恢复链仍以 SQLite 为合同；它们不能直接用于 PostgreSQL 正式部署。** 下文列出的生产门禁完成且用户确认部署后，才执行云端安装、迁移、DNS 切换或公司服务重启。本文本身不代表已经上线。

底层 API 的唯一协议说明见 [服务桥接契约](../../server/docs/website-management-bridge.md)；本文负责实际部署顺序与岗位操作，不另外定义一套协议。

## 一、连通方式

```mermaid
flowchart LR
    Visitor[客户浏览器] -->|HTTPS 443| Cloud[阿里云 Nginx + 官网 Next.js]
    Cloud --> WebDB[(官网 PostgreSQL)]
    Cloud --> Files[耐久图片与私有 PDF]
    ERP[公司本地 IMP 服务] -->|主动 HTTPS 拉取待投递询盘| Cloud
    ERP --> ERPDB[(公司 ERP 数据库)]
    ERP -->|入库提交后精确 ACK| Cloud
    ERP -->|注册短期授权及续期 / 撤权| Cloud
    Staff[员工浏览器 / IMP 客户端] --> ERP
    Staff -->|一次性 PKCE 授权进入 CMS| Cloud
```

公司网络无需为了此功能做 ERP 公网端口映射。官网服务器不会主动连接公司 ERP；由公司 ERP 服务进程出站访问官网 HTTPS。员工电脑能打开官网，不代表公司服务器、其服务账号、DNS 或 Java 证书信任库也能访问。两条链都必须验证。

客户提交后，官网先提交询盘正文、产品来源快照和 PENDING 投递记录。ERP 拉取后在自己数据库事务中幂等保存，再返回精确 ACK；销售通知与待办由已提交事实生成。网络中断时官网继续收件，恢复连接后继续投递。同一来源 ID 不应产生第二条 ERP 询盘。

页面上的“需求已受理”表示官网已保存；“已送达 IMP”表示 ERP 已持久化并确认。两者均不等于销售已经阅读、认领、回复或成交。

## 二、上线前必须明确的记录

在维护工单中填好以下信息，密钥值另存密钥管理或服务器私密配置，不放工单正文。

| 项目 | 本方案要求 |
|---|---|
| 官网主 origin | 例如 `https://www.ch-uten.com`；最终值先确认，不含路径、查询参数、fragment |
| 站点身份 | 两端同一稳定 siteId，例如 `uten`；后续恢复不能随意改名 |
| 网站服务身份 | 两端同一独立密码学随机 token，43–512 字符，只允许 `A–Z a–z 0–9 + / = _ -` |
| 官网数据库 | 独立 PostgreSQL；不连接公司 ERP 库，不共用公司数据库密码 |
| 官网运行用户 | 独立 Linux 用户 `uten-website`，不使用 root 或 ERP 账号 |
| 官网监听 | Next.js 仅回环 `127.0.0.1:3000`，公网由 Nginx 443 提供 |
| 公司 ERP | 保持现有安全 profile、数据库、附件和业务状态；只增加官网桥接配置 |
| 域名与证书 | 域名控制权、解析、完整证书链、续期负责人；中国内地机房所需备案按当时官方要求办理 |
| 销售接收人 | 实际在职账号，已完成首登改密，获得询盘与通知权限 |
| 发布人 | 分开授予内容编辑、产品编辑、素材、发布及版本恢复权限 |
| 备份与恢复 | 官网 PG、图片、私有 PDF 和来源/版本/回执保持配套，明确 RPO/RTO 并做恢复演练 |

生成 token 的示例命令如下，仅在获批的私密终端执行；不要把生成结果粘贴进聊天、Git、截图或公共日志。两端配置同一个生成值，不要各生成一个。

```bash
umask 077
openssl rand -base64 48 > website-bridge-token.secret
chmod 0600 website-bridge-token.secret
```

`AUTH_SECRET` 是官网 cookie 签名密钥，必须单独生成；不等于 bridge token、数据库密码、ERP JWT/PGP/HMAC 密钥。不要因为接官网而轮换公司 ERP 现有加密密钥。

## 三、阿里云资源、DNS 和 HTTPS 准备

1. 在已批准的地域与 VPC 创建或确认官网专用 ECS、耐久数据盘与备份位置。PostgreSQL 如果在同一 ECS，只监听回环；如果在独立数据库实例，通过私网访问。数据库端口不向公网开放。
2. 网站公网业务仅开放 TCP 80/443；运维 SSH 限定管理员可信来源。公司 ERP 不新增公网入站规则。安全组只是云网络的一层，还要检查主机防火墙和 Nginx 实际监听。阿里云关于网站、管理和数据库隔离的当前规则见 [安全组场景指引](https://www.alibabacloud.com/help/en/ecs/user-guide/security-groups-for-different-use-cases)。
3. 在 DNS 服务商为最终主机名配置到已批准网站公网地址的 A 记录；IPv6 只有在实际服务、路由及证书都验证后才配置 AAAA。改动前导出现有记录、TTL 和旧地址，避免覆盖邮件等其他记录。阿里云 DNS 的记录类型与操作见 [添加解析记录](https://www.alibabacloud.com/help/en/dns/pubz-add-parsing-record)。
4. 在证书服务中取得覆盖实际主机名的证书，按 Nginx 格式部署完整证书链和对应私钥；证书与私钥放受限目录。检查配置再 reload，完成 HTTP 到固定 HTTPS 主机名的跳转。证书下载、域名匹配、安装与续期核对 [阿里云 Nginx/Tengine 证书说明](https://help.aliyun.com/zh/ssl-certificate/install-ssl-certificates-on-nginx-servers-or-tengine-servers)。

以下为**只读网络检查**，在员工电脑与公司 ERP 所在服务器分别执行。将主机名替换为最终批准值。

```bash
WEBSITE_HOST=www.ch-uten.com
getent ahosts "$WEBSITE_HOST"
curl --fail --silent --show-error --max-time 10 "https://$WEBSITE_HOST/api/health"
openssl s_client -connect "$WEBSITE_HOST:443" -servername "$WEBSITE_HOST" \
  -verify_return_error </dev/null
```

Windows 检查示例：

```powershell
Resolve-DnsName www.ch-uten.com
Test-NetConnection www.ch-uten.com -Port 443
Invoke-RestMethod -Uri 'https://www.ch-uten.com/api/health' -TimeoutSec 10
```

不能用 `curl -k`、关闭 Java 证书验证或开放公司数据库端口来“修通”。公司服务器若通过企业代理出站，应给 ERP 服务配置经过批准的代理/信任链；浏览器自身代理设置不会自动传给 Java 服务。

## 四、官网服务器配置

### 4.1 稳定目录与访问权

路径必须脱离每次发布的代码目录。当前源码的生产路径合同为：

| 路径 | 用途及访问边界 |
|---|---|
| `/var/lib/uten-website/runtime/uploads` | 不可变图片；Nginx 仅只读公开该目录 |
| `/var/lib/uten-website/runtime/upload-staging` | 图片写入暂存；不对外提供 |
| `/var/lib/uten-website/runtime/documents` | 私有 PDF；只有应用/备份账号可访问，禁止 Nginx alias 或静态发布 |
| `/etc/uten-website/website.env` | 网站服务器私密配置，root 管理、网站进程只读 |
| `/var/cache/uten-website` | 可重建缓存，不作为业务备份 |
| `/var/backups/uten-website` | 受限备份目录，并另存离机副本 |

目录准备示例只供批准后的运维执行；用户和组先确认存在，已有目录不得用错误挂载覆盖：

```bash
sudo install -d -m 0750 -o uten-website -g uten-website \
  /var/lib/uten-website/runtime/documents \
  /var/lib/uten-website/runtime/upload-staging
sudo install -d -m 2750 -o uten-website -g uten-website-media \
  /var/lib/uten-website/runtime/uploads
```

图片共享组只给 Nginx 读取图片的权限；**不要**把 Nginx 加入能读配置、数据库或私有 PDF 的网站主组。静态资源 URL 保留 `/uploads/...`，更换主机不改文件名和数据库引用。

### 4.2 网站私密配置

在服务器上由运维直接填写真实值。以下是字段模板，`__...__` 都是占位符，不能原样启动。文件权限建议 root 所有、仅网站服务组可读（0640）；不要将其打进发布包。

```dotenv
NODE_ENV=production
HOSTNAME=127.0.0.1
PORT=3000
SITE_URL=https://www.ch-uten.com
DATABASE_URL=postgresql://__WEBSITE_DB_USER__:__URI_ENCODED_PASSWORD__@127.0.0.1:5432/uten_website
AUTH_SECRET=__INDEPENDENT_RANDOM_AUTH_SECRET__
UPLOADS_DIR=/var/lib/uten-website/runtime/uploads
DOCUMENTS_DIR=/var/lib/uten-website/runtime/documents
WEB_SITE_ID=uten
UTEN_WEBSITE_BRIDGE_TOKEN=__SAME_RANDOM_BRIDGE_TOKEN_AS_COMPANY_ERP__
INQUIRY_TRUSTED_CLIENT_IP_HEADER=x-real-ip
ADMIN_TRUSTED_CLIENT_IP_HEADER=x-real-ip
ALLOW_DESTRUCTIVE_SEED=false
```

数据库 URL 内的用户名、密码必须按 URI 规则编码。网站的 `WEB_SITE_ID` 对应 ERP 的 `UTEN_WEBSITE_BRIDGE_SITE_ID`；两端 token 必须逐字相同且不能带尾部换行。旧 `IMP_INGEST_URL` / `IMP_INGEST_TOKEN` 不再是新站的投递配置。

只有在 Nginx 确实覆盖客户端提交的转发头、Next 源站不可公网直连时，才能信任 `x-real-ip`。启用 CDN/WAF/SLB 后必须重新核对可信代理链；不能直接相信任意客户端的 X-Forwarded-For。

### 4.3 PostgreSQL 数据与发布门禁

网站运行时依据 `DATABASE_URL` 选择 SQLite 或生成的 PostgreSQL 客户端。候选构建需生成两套 Prisma 客户端；PostgreSQL 使用 `prisma/postgresql/schema.prisma`。已有网站数据不能只换数据库 URL。

在独立候选环境的命令如下；**不是让运维现在在正式云主机执行**：

```bash
cd website
npm ci
npm run db:generate
# DATABASE_URL 已由候选环境的私密配置注入，且指向独立目标
npm run db:migrate:postgresql
```

已有 SQLite 内容迁移到 PG 时，先停写并生成一致的离线备份，目标必须为空。使用 `scripts/migrate-sqlite-to-postgresql.mjs` dry-run 核对所有模型、记录数与摘要，再在批准的维护操作中显式 apply；非回环目标还须单独部署许可与 `--allow-remote-target`。不得把现有生产目标当可反复执行的“合并导入”，也不得运行破坏性 seed。

当前上线前仍要补齐并验收：

- PostgreSQL 客户端及其引擎、schema、迁移和精确构建清单进入正式发布包。
- PG 环境校验、迁移计划、服务启停/就绪门禁及安全的版本切换。
- PG 与图片、私有 PDF 的一致备份、清单、摘要、恢复和中断恢复流程。
- 上线验证当前 `/api/health` 的 schema/迁移、图片与私有资料目录权限和存在性，以及 `WebsiteDocumentAsset` / `ResourceDocument` 两表检查。健康检查已覆盖这些就绪条件；一个 200 不等于每份文件的完整性校验或配套备份恢复已经通过。
- 多实例或无服务器部署需要共享限流与共享耐久文件，当前进程内限流不能当跨实例全局限流。初次应以已验收的单实例边界运行。

现有 `validate-runtime.sh`、`uten-website-activate.sh`、`uten-website-boot-guard.sh`、`website_release.py`、`paired_state.py` 的 SQLite 合同不能靠改几个 env 值绕过。它们当前 paired-state 也不包含私有 `documents`。保留旧 SQLite 回归；另行实现 PG 路径后才能解除这项生产门禁。

### 4.4 反向代理核对

使用仓库 Nginx 站点模板作为审核起点，替换固定域名和证书路径，保留安全头、固定 Host、转发头覆盖、无公开源站及版本门禁。正式配置审核后运行：

```bash
sudo nginx -t
# 只有配置审核与维护许可通过后才执行
sudo systemctl reload nginx
```

上传封套必须与当前应用匹配：图片上限 8 MiB、PDF 上限 20 MiB，Next Server Actions 请求上限 22mb。管理路径的 Nginx `client_max_body_size` 应允许对应 22m 封套；如果仍沿用 10m 模板，10–20 MiB 的合法 PDF 会被代理提前 413。只扩大受保护的管理路径，不扩大公开询盘表单的限制。

`/api/imp/bridge/*` 必须透传 Authorization 与站点头，不得缓存、注入浏览器挑战或重定向到其他域。`/admin/*` 和 `/api/resources/*/download` 不得静态缓存私人状态。资料下载由应用检查已发布状态、产品范围、哈希和文件大小，私有 PDF 不提供直接磁盘 URL。

## 五、公司本地 ERP 配置

### 5.1 只增加桥接配置

公司 ERP 保持现有受支持的部署 profile 与发布管理，不改成 dev，不替换现有 JWT/PGP/HMAC、数据库、业务数据集身份或附件设置。云端专用 `cloud` profile 不运行出站询盘 worker，不能把公司 ERP 切换到该角色来连接官网。

在公司 ERP **实际服务读取的环境文件**中增加以下项，保持其已有所有者和受限权限。不能只在管理员临时 shell 中 export 后认为 systemd 服务已拿到。

```dotenv
UTEN_WEBSITE_BRIDGE_ALLOWED_ORIGINS=https://www.ch-uten.com
UTEN_WEBSITE_BRIDGE_TOKEN=__SAME_RANDOM_BRIDGE_TOKEN_AS_WEBSITE__
UTEN_WEBSITE_BRIDGE_SITE_ID=uten
UTEN_WEBSITE_BRIDGE_ALLOW_LOOPBACK_HTTP=false
UTEN_WEBSITE_BRIDGE_POLL_DELAY_MS=30000
UTEN_WEBSITE_BRIDGE_INITIAL_DELAY_MS=30000
```

这些变量在 `server/src/main/resources/application.yml` 显式映射到桥接属性，不依赖对带连字符属性的环境名称猜测。多个预置 origin 用逗号分隔；通常只保留一个最终 HTTPS origin。不要填 `/admin`、旧 PHP 页面、带参数的 URL 或任意内网 URL。

Linux 服务确认示例，服务名以公司当前安装为准，不为此功能新建第二个 ERP 进程：

```bash
systemctl list-unit-files '*uten*'
ERP_SERVICE=__ACTUAL_COMPANY_ERP_SERVICE__.service
systemctl show "$ERP_SERVICE" --property=EnvironmentFiles --value
# 由运维在返回的现有私密文件中添加上述字段；不要 cat 密钥进共享日志
# 配置、备份和维护审批完成后才重启
sudo systemctl restart "$ERP_SERVICE"
systemctl is-active "$ERP_SERVICE"
```

重启后从服务账号和 Java 实际运行环境检查官网 DNS、HTTPS 和证书信任。`/api/health` 是无密钥就绪检查；服务器间服务身份的验证使用下一步 IMP“检查连接”，避免把 Bearer token 拼进终端命令或浏览器地址栏。

### 5.2 超级管理员启用

1. 以公司 IMP 超级管理员正常登录，进入工作台的官网运营/官网管理。
2. 打开连接设置，从预置列表选择最终 `https://...` 地址，填写显示名称。若无预置地址或“服务身份未配置”，先由运维核对实际进程配置，前端无法补填服务器 secret。
3. 启用连接并保存；按系统统一再认证输入本人当前密码。该动作同时要求超级管理员、`website:view`、`authorization:manage`，不是给普通编辑人授 `authorization:manage` 就能操作。
4. 点击检查连接，核对“可达/就绪”、站点 ID、待投递数量、最近投递/同步时间。配置版本变化时重新检查；不要将旧检查结果当新地址已经就绪。
5. 打开官网管理，页面先确认进入人员身份，完成后进入 CMS。不得复制授权网址给别人；60 秒单次授权超时后回 IMP 重新打开。

公开官网不依赖这名管理员一直在线。出站 worker 由服务运行，默认约每 30 秒轮询；一次最多拉 20 条。后台任务需要服务进程在运行且连接处于启用状态。

## 六、销售与内容人员使用

### 6.1 首次人员准备

使用公司既有员工与账号流程，不用网站账户代替 ERP 员工。新员工由人事/有权人员正式开通账号，获得一次性初始密码，首次登录自行改密。启用官网不应批量修改现有员工密码。

销售接收人至少实际授出 `notice:read`、`webinquiry:view`、`webinquiry:claim`；需要关闭或转客户时按岗位再授 `webinquiry:close`、`webinquiry:convert_client`。通过 IMP 当前权限/账号信息核验，不仅看部门名称。当前通知按实际授权筛人，超级管理员操作豁免不会自动把超管当销售接收人。

内容岗位分别使用：

- `website:view`：查看管理状态、按本人权限进入后台。
- `website:content_edit`：编辑公司、首页、新闻、案例、岗位等内容草稿。
- `website:product_edit`：编辑官网展示产品与系列，不修改 ERP 物料、价格或库存。
- `website:media_manage`：管理经核实可公开的图片与 PDF。
- `website:publish` / `website:rollback`：审核发布或恢复指定版本。

权限应通过现有 IMP 授权入口维护，不直接改数据库。后台只显示及执行本人可用操作，不能把“看得到入口”当作发布权已授予。

### 6.2 销售日常处理

1. 新咨询保存并送达后，销售收到“新的官网咨询”通知与官网询盘角标；点击进入实际详情。
2. 核对联系人、公司、需求、原页面、关联系列/型号和来源快照，再认领。
3. 在本人负责的记录追加跟进，保存后刷新确认时间线保留；其他人不能抢占负责人或替本人覆盖跟进。
4. 后续按真实业务关闭或转客户。重复点击与重试不能制造第二个客户。

不要在官网 CMS 再维护一套“已经处理/销售已读”开关。联系方式属于受权限保护的客户数据，故障截图和日志不应包含完整表单正文。

### 6.3 内容日常发布

编辑内容/产品/系列/场景/新闻/案例/岗位/资料 → 保存草稿 → 预览固定版本和差异 → 有权人员发布 → 刷新公开页核对。保存草稿不会立即改公开页。

上传 PDF 后还要填写标题、说明、语言、版本、适用市场及可选系列/型号范围，再保存资料草稿并发布。文件未发布、范围已下架或完整性校验失败时，不应继续提供公开下载。带脚本、自动动作、嵌入附件或加密的 PDF 会被拒绝。

恢复功能生成新的版本与审计，不删除历史、不倒拨行版本。若公开内容或关联关系已有后续修改，系统可能拒绝覆盖；应重新审阅当前版本，而不是直接修改数据库强制回退。

### 6.4 撤权和退出

CMS 授权绑定打开它的原 IMP `authSessionId`。ERP 每轮重新核验原会话及当前账号/员工权限并续期；登出、停用或撤去官网权限后不再续期。正常连接时在下一轮收敛，连接中断时最多等现有 5 分钟租约到期；绝对 8 小时后须重新从 IMP 进入。

这不是即时全网推送撤销。紧急事件可在批准的运维处置中暂时关闭官网管理入口并撤销相关身份，公开官网与收件能力保持独立。不能通过延长租约来掩盖 ERP 离线或撤权失败。

## 七、正式验收清单

使用明确标注的合成测试联系人和测试销售账号，不向真实客户发送测试消息。每步记录时间、候选版本和不含隐私的回执 ID。

| 步骤 | 操作 | 通过依据 |
|---|---|---|
| 公开访问 | 员工、外网手机、公司服务器分别访问官网 | HTTPS 正常；首页、目录、详情、新闻、资料、联系页面可用 |
| 双环境可达 | 公司 ERP 服务环境检查 DNS/TLS，再用 IMP 检查连接 | 浏览器与服务端两条链均通过；siteId 相同，检查非旧缓存 |
| 离线收件 | 在测试窗口暂时禁用 ERP 官网连接，提交一条合成咨询 | 官网返回稳定受理编号，数据库 PENDING 存在；不能声称销售已读 |
| 恢复投递 | 重新启用连接并等待 worker | ERP 唯一询盘保留 sourceId/来源，网站精确 ACK 同一 erpInquiryId |
| 幂等 | 再轮询或对同一次提交重试 | 不增加第二条询盘、不覆盖原始快照、不重复通知 |
| 销售办理 | 实际销售登录、看通知、认领、追加跟进并刷新 | 本人负责、跟进保存、历史追加、待办正确撤销 |
| 公开与草稿隔离 | 修改首页和一个产品，保存草稿 | 预览可见新版本；公开页面仍为原版本 |
| 发布与恢复 | 有权人员发布、回读公开页、恢复再回读 | 公开变化、恢复结果、版本审计及稳定 ID 一致 |
| 文件 | 上传普通小 PDF、10–20 MiB 合法 PDF；发布、下载、下架 | 代理与应用限制匹配；下载哈希/大小正确；未发布/下架不可下载 |
| 越权 | 用无发布权账号发布，撤权后继续旧 CMS 页面 | 操作被服务端拒绝，未写公开内容；租约按上限失效 |
| 重启 | 重启测试网站/ERP 进程后读取未确认任务 | 询盘、回执、内容版本、图片与 PDF 仍在，未生成新来源 ID |
| 恢复演练 | 从配套备份恢复到隔离目标，验证公开页与待投递任务 | PG/文件摘要与引用一致，不重复建客户、不误认为所有待投递已送达 |

只读回读与截图留证据即可，不记录姓名、电话、邮箱、密码、cookie、授权 fragment 或 Bearer token。截图中受理/回执 ID 可保留，但不能把一个 HTTP 200 代替整段业务验收。

## 八、故障排查

| 现象 | 检查与处理 |
|---|---|
| 浏览器可访问，IMP 检查不可达 | 查公司服务器服务账号的 DNS、出口防火墙、代理、Java 信任链；公网浏览器结果不能替代服务进程结果 |
| 连接地址不允许 / 要求预置 HTTPS origin | 核对实际环境文件的 allowed-origins 与前端选择值，不能填路径或重定向别名；HTTPS 证书必须覆盖该主机名 |
| 503 `BRIDGE_NOT_CONFIGURED` | 云端桥接 token 为空或不符合长度/字符合同；公开页面可能仍正常 |
| 401 `UNAUTHORIZED` | 服务 token 缺失或两端不同；由运维在私密环境核对，禁止把 token 发群里比对 |
| 403 `SITE_MISMATCH` | 网站 WEB_SITE_ID 与 ERP SITE_ID 不同；先查配置，不能通过换业务来源 ID 消除错误 |
| 503 `SERVICE_UNAVAILABLE` / `/api/health` 不就绪 | 查应用、PG 连接、迁移是否完整、耐久挂载和目录权限；不向客户返回数据库异常或密钥 |
| 待投递数量增长 | ERP 服务、连接启用状态、worker 日志、合法数据及事务失败；已保存任务不能删除后重新造 ID |
| ERP 有询盘但网站还 PENDING | 入库提交与 ACK 之间可能断网；允许下轮按相同 sourceId 重投并精确确认，不能据此再建客户 |
| ERP 已 ACK，销售没通知 | 核对实际 notice/read/view/claim 权限、账号与员工有效状态、Outbox/通知任务、本人通知设置；ACK 不是已读 |
| 认领/跟进冲突 | 先刷新负责人及状态；不得重试抢占他人记录，未知提交先回读 |
| CMS 401 `ENTRY_EXPIRED` / 已消费 | 60 秒授权过期、verifier不匹配或已使用；回 IMP 重新进入，不复制旧 URL |
| CMS 403 或租约过期 | 查原 IMP 会话、当前权限、启停/登出和续期网络；按真实授权恢复，不延长旧会话绕过撤权 |
| 同源错误 | SITE_URL 与实际浏览器 origin 不一致、代理 Host/Proto 错误；不用关闭同源保护解决 |
| PDF 413 | 检查 Nginx 管理路径封套是否仍10m、Next22mb及文件20MiB；公开表单限制保持较小 |
| PDF 下载404或完整性失败 | 查发布状态与产品范围、documents挂载、hash/size，不将私有目录改成静态公开 |
| 证书续期后 Java仍失败 | 检查域名、完整中间链、系统时间及服务实际信任库；不忽略证书校验 |

阿里云侧按 [安全组规则](https://www.alibabacloud.com/help/en/ecs/user-guide/security-group-rules) 与 [Nginx证书排查](https://help.aliyun.com/zh/ssl-certificate/install-ssl-certificates-on-nginx-servers-or-tengine-servers) 定位；控制台名称、配额和入口可能调整，操作时核对最新官方页面。

## 九、备份、恢复与回滚

### 9.1 必须配套的内容

官网 PG 包含目录、内容、稳定来源、询盘、投递回执、CMS版本与素材账本；图片和 PDF 另外在文件系统。仅有 ECS 磁盘快照、仅有数据库 dump、或仅有发布包，均不能证明网站可以完整恢复。ECS 默认不会替用户完成业务备份，快照的一致性类型也需核验，参见 [ECS快照说明](https://www.alibabacloud.com/help/en/ecs/user-guide/snapshot-overview/) 和 [应用一致性快照](https://www.alibabacloud.com/help/en/ecs/user-guide/create-application-consistent-snapshots-in-the-ecs-console/)。

PG 的基础逻辑备份/隔离恢复命令示例：数据库连接通过备份账号的受限 `.pg_service.conf` / `.pgpass` 提供，不把密码放 argv；账号须有被批准的备份/恢复权。

```bash
# 只在已核验的备份环境执行；产物必须加密离机保存
umask 077
BACKUP_DIR=/var/backups/uten-website/__APPROVED_BACKUP_ID__
mkdir -m 0700 "$BACKUP_DIR"
pg_dump --dbname=service=uten_website_backup --format=custom \
  --file="$BACKUP_DIR/website.pgdump"
pg_restore --list "$BACKUP_DIR/website.pgdump" > "$BACKUP_DIR/contents.txt"
# 仅恢复到事先创建的隔离空目标，禁止指向正在运行的生产数据库
pg_restore --dbname=service=uten_website_restore_test --exit-on-error \
  --no-owner --no-privileges "$BACKUP_DIR/website.pgdump"
```

这些命令只涵盖 PG 逻辑归档，并不构成完整生产恢复工具。命令选项及版本边界参见 [PostgreSQL 16 pg_dump](https://www.postgresql.org/docs/16/app-pgdump.html) 和 [pg_restore](https://www.postgresql.org/docs/16/app-pgrestore.html)。

正式流程还必须在同一冻结窗口或已证明一致的协议下，备份 uploads 与 documents、生成每个文件的相对路径/大小/SHA256清单，并绑定 DB、迁移版本、siteId、发布版本和时间。暂停所有内容/询盘写入及桥接 ACK 后取一致点；文件复制完成和恢复回读前不能宣布备份完成。RPO、RTO、保留周期、加密密钥和离机副本由公司确认。

### 9.2 恢复与回滚规则

1. 先关闭受影响的管理与写入入口，记录故障和最后成功版本；保留原盘、原库和日志，不直接覆盖唯一副本。
2. 在隔离目标恢复配套 PG、图片与私有 PDF，核对 schema迁移、数量、摘要、文件引用、询盘sourceId/ACK和CMS版本；用原稳定身份恢复，不重新seed或随机换siteId。
3. 若恢复点早于某些已接收询盘，先对照 ERP 的持久来源回执与云端备份恢复差异，处理可解释的重投和缺口；不能将所有PENDING标成ACK，不能删除公司已经建成的询盘或客户。
4. 数据库 schema 变化后不能简单切旧二进制或倒拨 Flyway/Prisma 记录。回滚先判断兼容性；不兼容时按经过演练的配套恢复/前向修复执行。
5. 恢复后先验证受限服务、公开页、资料、bridge与权限，再受控开放写入和ERP同步。重新执行离线/恢复投递与销售处理验收。
6. 密钥泄露按独立安全事件处置。正常内容恢复不轮换公司ERP PGP/HMAC；网站bridge token轮换应计划两端维护窗口，暂停同步期间继续云端持久收件，换后核对无遗漏与重复。

## 十、移交回执

正式移交至少填写：候选提交/发布摘要、云主机与域名、HTTPS到期日、两个稳定siteId值一致的核验、配置文件位置及所有者（不含值）、数据/文件挂载、备份及隔离恢复回执、销售及发布岗位权限、离线收件→唯一入库→ACK→销售认领跟进的证据、CMS发布恢复及撤权证据、监控接收人和仍未完成项。

本轮本地实现与测试结果由当前验收报告填写。PG正式发布/备份恢复门禁未解除、生产配置未核验、用户未确认之前，**不得把本手册或开发构建当作可以直接上线的批准**。
