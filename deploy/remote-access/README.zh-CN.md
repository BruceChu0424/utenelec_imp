# 少量员工远程入口：部署、验证与故障处理

适用范围：最多 5 人日常远程使用、偶尔在海外；本地单套 Spring 与 PostgreSQL 继续承办全部业务。本文及本目录是当前新方案的部署合同，`deploy/cloud/` 旧云应用/云数据库方案继续保持退役。仓库验证不等于公司服务器、阿里云或公网已经上线。

## 1. 固定的数据与信任边界

```text
员工设备 ── 员工 HTTPS（域名校验，密钥只在公司）──────────────────────────┐
          阿里云 ECS stream:443（只读 SNI，员工正文始终为密文）        │
            ├─ 员工域名 ── 127.0.0.1:15443                         │
            └─ 外层 mTLS（云机器证书）+ WireGuard ── 公司 WG:8443       │
                 公司 stream 验证云证书，拆外层 ── 127.0.0.1:9443 ◀───┘
                 公司 HTTP Nginx 解员工 TLS，静态 Web 与 /api 同源
                    └─ 127.0.0.1:8082（专用远程 connector）
                         └─ 现有 Spring ── 本地 PostgreSQL
内网员工 ── 现有 LAN Nginx ── 127.0.0.1:8080（保持既有内网链）
管理员 ── 独立管理域名:443 ── SNI ── 云 127.0.0.1:19443 独立 TLS
            └─ 云 127.0.0.1:9087 灾备控制面（不依赖公司业务链）
```

云上没有 Spring、PostgreSQL、业务副本、附件原件、备份密钥、JWT 密钥、员工域名证书私钥、DNS 管理权限或公司 SSH 密钥。数据库 SQL 不经过 WAN；远程 API 请求和响应经过 WAN。云入口不能缓存明文静态页面、WAF 检查业务内容或注入 HTTP 头，因为这些内容在内层 TLS 内。

可选 `dr_public_domain` 启用独立管理入口；管理证书及私钥只用于该管理名，不包含员工域名。443 分发器拒绝未知 SNI；两个内部监听仅绑定 loopback，不开放公网 8443。管理入口共享最多 4 个正在处理的连接，总请求 10 次/秒、burst 20；认证及注册共同限为 1 次/秒、burst 2，超限 429。后端继续执行账号锁定、Bearer、CSRF 和新鲜 MFA。网关不采信公网来源头，日志不含 URL、查询、请求体或认证头；Nginx 原生 runtime error log 无法删除 URI/query，故这两个专用代理将它写到 `/dev/null`，保留脱敏 access 状态/耗时及 systemd 启动诊断。`/v1/broker`、`/v1/agent` 及编码/矩阵变体拒绝进入。管理页面可用只代表救援控制面可用，不能据此认定业务恢复或数据库提升成功。

WireGuard 只路由两个主机 `/32` 地址，不路由公司 LAN，不 NAT，不启用转发；公司防火墙对 `wg-uten` 仅放行认证云 peer 到公司 WG 地址 TCP 8443，其余输入与全部转发拒绝。专用 `uten-remote` 进程身份出站只能到 loopback 9443/8082，并且看不到应用、数据库、附件和备份秘密目录。外层机器证书只允许进入应用入口，员工仍须满足系统远程总开关、个人授权、MFA、会话有效性和原业务权限。

这限制云失陷后的横向通路与凭证窃取；不能承诺软件永无漏洞。攻击者仍能中断/延迟入口、发起合法协议格式的攻击流量；应用补丁、账号保护与容量隔离仍是独立防线。公司主机/员工终端或 DNS 管理账号自身失陷不属于“仅云 ECS 失陷”的假设。

## 2. 安装前输入与停止条件

先按 [采购与扩容](PURCHASE-AND-SCALE.zh-CN.md) 建好资源清单与报价。准备一份只保存在受控运维机器的 `profile.local.json`：从 `profile.example.json` 复制，填写受控员工域名、公司传输证书 SAN、EIP、两个不与 LAN/VPC 冲突的 WireGuard 主机地址、双方公钥、管理员公网 `/32`、公司 ACME 账号 URI。私钥不能填入这份 JSON。

以下任意项不满足时保持远程总开关 OFF：本地服务和备份恢复证据不清楚；没有正常的公司 LAN 管理入口；5 名试点用户未绑定 MFA；数据库池名义容量检查不通过或实测内网明显受远程拖累；公司上行/区域 RTT 未测；域名备案与正式证书未完成；公网 5432/8080/8082 或 WG 的 LAN 转发仍可达。

```bash
python3 deploy/remote-access/remote_access.py validate --config /secure/remote/profile.local.json
python3 deploy/remote-access/remote_access.py render --config /secure/remote/profile.local.json --output /secure/remote/review-01
```

生成器只写新目录，不连接云端、不安装、不启用远程权限，不读取或输出秘密。`review-01/cloud/` 只交付云侧配置，`company/` 只交付公司配置。不要将整个公司配置/证书目录复制到云上。生成失败会拒绝未知字段、宽泛路由、注入字符、示例 IP、相同双方公钥、泛 SSH 来源或错误 connector 端口。

若正式员工域名尚未确定，可以先从网络 profile 中去掉 `public_domain`、`acme_account_uri`、`remote_backend_port`，使用 `render-private-test` 准备机器链路验收。该模式固定使用保留名 `remote-commissioning.invalid` 与专用8082，必须配私有测试CA并校验证书；输出显著的 `COMMISSIONING-ONLY.txt`，不生成DNS/CAA记录，不允许夹带正式域名或虚构ACME账号。此阶段保持应用远程政策OFF，不给员工授权。正式启用前必须另行以完整profile重新生成配置、在公司安装正式域名证书，并完成DNS/CAA与现场验收；私有链路通过不代表员工公共HTTPS已上线。

## 3. 先建立证书与 DNS 权限隔离

员工域名证书默认选 **Let's Encrypt 正式证书 + DNS-01 自动续期**。域名 A 指向 EIP；仅公司证书任务或专用运维机器能修改 `_acme-challenge` TXT，优先把挑战委派到独立验证域并仅授权该域，避免给业务服务完整域名管理权限。ACME 账号私钥不交付 ECS，也不交付 `uten-remote` 进程。

必须审查并发布生成的 CAA：只允许 `letsencrypt.org`、`validationmethods=dns-01`、公司特定 `accounturi`，并用 `issuewild ";"` 禁止通配符签发；清除同名/继承链中不必要的其他签发授权。云上不开放 HTTP 80，也不执行 HTTP-01/TLS-ALPN-01。**仅把现有证书留公司是不够的**：若不约束签发方式，失陷的域名入口可能再次证明 IP 控制权获取另一张证书。CAA 的账号与验证方式约束见 [Let's Encrypt 官方说明](https://letsencrypt.org/zh-cn/docs/caa/)。DNS 账号启用 MFA，ECS 不附带可改 DNS 的 RAM 角色。

另由公司控制的离线/受控 CA 分别签发：

| 证书 | 私钥在哪 | 证书用途与部署位置 |
|---|---|---|
| 员工域名正式证书 | 仅公司 | `employee-fullchain.crt` / `employee.key`；内层 9443；SAN 是员工域名 |
| 传输服务器证书 | 仅公司 | `transport-server.crt` / `.key`；外层 8443；SAN 是 profile 的传输名，EKU serverAuth |
| 云机器客户端证书 | 仅对应 ECS | `cloud-client.crt` / `.key`；EKU clientAuth；专用签发 CA 只签这类云入口身份 |
| 两个传输 CA 根私钥 | 离线或专用签发机器 | 不在 ECS，不在代理服务目录；两种角色不共用叶子密钥 |

云只持有 `transport-server-ca.crt` 公共信任根；公司只持有 `cloud-client-ca.crt` 公共信任根。叶子证书到期前 30/14/7 天告警；续期后先 `nginx -t`，再 reload 专用服务。正式 TLS 私钥文件 `root:uten-remote 0640`，目录 `root:uten-remote 0750`；WireGuard 私钥目录和文件分别 `root:root 0700/0600`。不要用 `chmod -R 777`，不要输出私钥。

云被怀疑失陷时先公司断开入口，再撤销其 WireGuard 公钥、轮换专用云客户端 CA/证书并重建 ECS；只给同一 CA 换一张新叶子证书不会自动使旧叶子失效。若引入多云节点，需要为每节点独立证书及可验证撤销机制，再扩展当前单 peer 模板。

### 当前固定域名的 DNS-01 与续期任务

`dns01_hook.py`、`remote_tls.py`、`cert_receiver.py` 是已审查的 `justplayit.cn` 员工入口和 `admin.justplayit.cn` 管理入口专用工具，拒绝任意域名或路径。公司 root 独立 Certbot venv 位于 `/opt/uten-remote-acme/venv`；版本、安装来源与下载哈希保存在公司 root-only 安装日志。不要复用旧网站的 ACME 账户或 TLS 私钥。

公司 `/etc/uten-remote-ca/dns01.json` 必须是 root 单链接 regular 文件、0600，且 JSON 恰有 `access_key_id`、`access_key_secret` 两个字段。RAM 仅允许该域名的 `DescribeDomainRecords`、`AddDomainRecord`、`DeleteDomainRecord`。hook 固定官方 AliDNS API，限定两个挑战 TXT；删除时重新核对记录 ID、RR、类型和值。CAA 改动先保存 root-only 原记录快照，先增加公司账户与 DNS-01 限制，再删除冲突的 issue/issuewild，保留其他记录并核对 A 记录未变。TXT 传播直接核对权威 DNS，不能为排障放开 DNS 权限或修改系统解析器。

公司持有 `/etc/uten-remote-ca/letsencrypt` 的账户、`archive/uten-erp-employee` 物理私钥和 `renewal/uten-erp-employee.conf`，`live/uten-erp-employee` 为 Certbot 管理的受控相对链接。员工私钥只复制到公司专用 TLS 目录。管理私钥在云生成；公司通过独立 `uten-cert-receiver` forced-command 身份取得只包含管理 SAN 的 CSR，签发后仅发公开证书链。接收器只允许 `get-csr`、`publish-cert`、`publish-status`，不能取得 shell、转发连接或指定路径；收到的证书必须匹配云端原私钥、单一管理 SAN、有效公共链且至少还有 7 天有效期。公司 publisher 私钥与 DNS 凭据绝不交付云。

`uten-remote-acme-renew.timer` 每天运行受限 root oneshot；员工证书走 Certbot lineage 续期，管理证书在剩余 30 天时按新 CSR 重新签发。每次先校验 CAA，安装前校验证书身份、公共链和匹配私钥，再通过专用服务以真实用户执行 `ExecReload` 验证并 HUP；不重启 LAN Nginx、应用或数据库。失败进入 `OnFailure=uten-alert@%n.service` 本机告警。这里没有配置外部邮件或短信通知；运维须实际接入外部通知渠道后才能声称有人收到提醒。

续期结果原子保存在公司 `/var/lib/uten-remote-acme/tls-status.json`；只发布白名单公开元数据至云 `/var/lib/uten-remote-status/tls.json`（root 文件、0644、父目录0755），供独立控制面显示证书到期、最近签发成功或续期失败时间。每日任务另检查公司保存的两张机器叶证书，在 30/14/7 天内写入 `/var/lib/uten-remote-acme/transport-status.json` 并触发本机失败告警；机器身份轮换仍由公司受控 CA 操作，不能为了自动化把 CA 私钥或签发权放到云上。备份必须覆盖 ACME 物理账户/归档私钥及受控链接映射，不能只保存 `live` 链接。

## 4. 主机安装顺序

下列是目标主机安装合同；具体现场运行状态以对应日期的受控验收记录为准，生成配置本身不会部署。公司现有 LAN Nginx、PostgreSQL 和发行安装器不由本目录覆盖。

1. 先核对两端实际发行版、Nginx 构建参数和 stream 模块路径。Ubuntu 24.04 LTS 使用官方包 `python3 nginx libnginx-mod-stream wireguard-tools nftables`，模块为 `/usr/lib/nginx/modules/ngx_stream_module.so`；Alibaba Cloud Linux 4 使用其发行仓库的 `nginx-mod-stream`，通常位于 `/usr/lib64/nginx/modules/ngx_stream_module.so`，必须与 Nginx 二进制版本匹配。profile 可分别填写 `cloud_nginx_stream_module` / `company_nginx_stream_module`，仅接受这两个标准路径或已通过 `nginx -V` 和配置检查确认的 `builtin`；省略时兼容原 Ubuntu 路径。不从任意地址下载来历不明的模块。云上若新装 Nginx 自动启动默认站点，先停用其默认 `nginx.service`；公司保留原 `nginx.service`，新服务使用独立配置/PID/端口。

   若发行仓库确实没有 `wireguard-tools`，已有内核 WireGuard 模块且 `gpg/gcc/make` 已按发行版安装，可由 root 运行本目录 `install_wireguard_tools.py`。它只下载固定上游 `1.0.20260223` 源包，校验上游发布者固定指纹与解压后的 tar 签名，隔离构建后安装 `wg`、`wg-quick` 与 unit；拒绝覆盖已有安装，不启动服务、不改防火墙。签名/构建日志留在 `/usr/local/src/uten-wireguard-tools/1.0.20260223`，版号、源哈希、文件哈希和签名回执在 `/usr/local/lib/uten-remote/wireguard-tools-install.json`；重复运行先核对回执与实际文件，不能用未验签二进制替代。
2. 建立无登录、只有自身主组的系统用户 `uten-remote`；禁止加入 `uten-imp`、`postgres`、备份、Docker 或管理员组。公司专用 Nginx unit 仅通过 `SupplementaryGroups=uten-web` 取得既有发行器授予的静态 Web 读取权，云 unit 不附加该组；先确认该组只读 `web/`，不能用应用组代替。建立 `/etc/uten-remote`（root:uten-remote 0750）、`tls`（同）、`wireguard`（root:root 0700）以及 root-only `/usr/local/lib/uten-remote`。禁止复用 ERP `server.env` 或应用进程账户。
3. 两端分别执行 `wg genkey`，将标准输出直接写入本机 0600 私钥文件；使用 `wg pubkey` 从文件派生**公钥**并填入 profile。不要把私钥作为 CLI 参数、环境变量、聊天内容或 JSON 字段。生成配置的 `PostUp` 只把本机文件路径交给 `wg set`，不会打印私钥；禁止 `wg showconf`/`wg show all dump` 输出到共享日志。
4. 把对应角色 `nginx.conf` 与 `firewall.nft` 安装到 `/etc/uten-remote/`（root:uten-remote 0640）；`wg-uten.conf` 安装到 `/etc/wireguard/`（root:root 0600）。把 `apply_firewall.py` / `tunnel_watchdog.py` 安装到 `/usr/local/lib/uten-remote/`（root:root 0755），四个 unit 安装到 `/etc/systemd/system/`（root:root 0644），`logrotate.conf` 安装到 `/etc/logrotate.d/uten-remote`。按照上节放置各角色需要的证书，禁止整包复制秘密。
5. 云安全组：公网 TCP 443；UDP 51820 对公司固定公网 `/32`，没有固定出口时仅这个 WireGuard UDP 端口可对公网开放；SSH 22 只给管理员 `/32`。不开放 80、8443、9443、8080、8082、5432，不发布 AAAA。公司路由器不做公网入站/NAT 映射。保留现有公司防火墙；如现有 UFW 默认拒绝，还需在其自身添加精确规则，例如示例地址对应 `ufw allow in on wg-uten from 10.77.0.1 to 10.77.0.2 port 8443 proto tcp`。**nft 较早 base chain 的 accept 不会跳过后续 UFW 的 drop**；云侧若也启用 UFW，还须与安全组对应放行 443、51820 和管理员 `/32` 的 SSH，保留既有 established 返回流量。每条命令替换为已批准真实地址，不得关闭 UFW 或开放整段 LAN 排障。
6. 先 `systemctl daemon-reload`，再 `systemctl enable --now uten-remote-firewall.service`。该服务先 `nft --check` 再在一个事务中替换唯一 `inet uten_remote` 表，不 flush 全局规则。检查已有安全策略不会在后续 reload 时清除此表。**不先打开隧道再补防火墙**。
7. 再 `systemctl enable --now wg-quick@wg-uten.service`。公司端主动联系 EIP 并 `PersistentKeepalive=25`，只交换一个对端 `/32`。检查握手时间，确认无 LAN 路由、无 forward；不修改主机全局 IP_FORWARD，以免影响既有服务。最后启用 watchdog timer；它仅恢复隧道，不重放任何业务。
8. 公司以现役受审发行链部署支持 remote connector 的 JAR。把生成的 `backend.env` 两项合并进受控服务环境：`UTEN_REMOTE_INGRESS_ENABLED=true`、`UTEN_REMOTE_INGRESS_PORT=8082`；仍保留全局远程政策 OFF。主 8080 与远程 8082 均只监听 loopback。不要启动云 Spring 或旧 `application-cloud`。
9. 先以与专用 unit 相同的身份和 capability 检查配置。公司 root 可用 `runuser -u uten-remote -g uten-remote -G uten-web -- nginx -t -q -c /etc/uten-remote/nginx.conf`；云端 443 的 `nginx -t` 同样可能绑定端口，须用 `systemd-run --wait --pipe` 临时 unit 设置 `User=uten-remote`、`Group=uten-remote` 和唯一 `CAP_NET_BIND_SERVICE`。不能用无 capability 的普通 `runuser` 失败结果判断配置无效，也不要用 root `nginx -t` 造成 cache 所有权变化。正式 reload 由现有专用 unit 的两个 `ExecReload` 执行。检查公司 `/opt/uten-imp/current/web` 可读，而 `current/server`、应用环境、PG/附件/备份路径不可读。必要时仅对发行父目录给予该用户 traverse、对 **web 子树**给予读取 ACL，不可加入 appSecrets/应用/数据库组，不可递归放开整个 `/opt/uten-imp`。先 `realpath` 核对 web 物理路径；若历史环境把 web 链到 `/data`，本服务的 `/data` 隔离会阻止读取，须评审单独 web 只读发布目录，不能删除秘密目录隔离来“修好”。启用 `uten-remote-nginx.service`，不要替换 LAN Nginx 配置。
10. Web 发行必须使用 `--no-web-resources-cdn`，静态资源与 API 来自公司同一 `current` 发行；只有文件名带内容 hash 的资源 immutable。`index.html`、`flutter_bootstrap.js`、`version.json` 与未带 hash 的资源均须回源校验。云端不单独上传另一个版本 Web。

示例安装命令中的源路径需由变更单确定，不在未核对路径时执行递归复制。所有证书/环境变更先保留 root-only 备份和回滚清单。Nginx 只对外提供最小 health/readiness/liveness；不公开 metrics、管理 actuator、访客与系统测试端点。现有官网机器集成 `/api/website-inquiries/ingest` 在这个员工入口精确返回404，即使携带官网机器token也不能通过；官网原有独立集成入口保持原合同，不借员工远程总开关取得发布资格。登录/MFA 限流与账号锁由应用执行，不依赖被云报告的源 IP。

## 5. 开放前验证与性能基线

程序自测（普通工作机，无服务器修改）：

```bash
python3 -m unittest discover -s deploy/remote-access -p 'test_*.py' -v
docker build -t uten-remote-contract:20261017 -f deploy/remote-access/tests/Dockerfile deploy/remote-access
docker run --rm --network none --cap-add NET_ADMIN --mount type=bind,source=/absolute/repo/deploy/remote-access,target=/src,readonly uten-remote-contract:20261017 python3 tests/integration_linux.py --firewall
docker run --rm --network none --cap-add NET_ADMIN --cap-add SYS_ADMIN --sysctl net.ipv4.ip_forward=1 --mount type=bind,source=/absolute/repo/deploy/remote-access,target=/src,readonly uten-remote-contract:20261017 python3 tests/network_isolation_linux.py
```

容器测试不映射端口，不连接公网或公司。第一个测试验证真实嵌套 TLS、错误域名/缺机器证书拒绝、恶意转发头清理、提交后丢响应不重试、静态缓存/上传上限与代理身份无法连接 5432。第二个测试在容器内部创建 cloud/LAN 两个子 network namespace，使用真实 WireGuard 和 veth 模拟公网，先证明无规则时 22/5432/8080/9443 与 LAN 转发确实可达，再证明加规则后只剩 8443；即使模拟攻击者扩大云侧 AllowedIPs 和路由，仍不能转入公司 LAN。另叠加模拟 UFW 后续 default-deny chain，验证必须精确双层放行。`SYS_ADMIN` 仅用于这个无网络、无宿主权限挂载的临时测试容器，生产代理服务没有此能力。2026-10-17 已在 Ubuntu 24.04 / Nginx 1.24.0 容器验证通过；这不是生产验收。

真实上线前记录：三网/公司宽带/手机热点与实际海外所在地；冷启动和热缓存；5 人正常并发、10 并发过载；公司同时进行正常内网操作；只授权 5 人，未授权、已撤权、过期会话、未完成 MFA、访客、伪造来源头和编码后的 API 路径都不能绕过边界。先在总开关OFF验证关闭行为；成功登录、业务性能及撤权对照须在明确的受控验收窗口、已绑定验证器的试点账号下临时ON，验证后再OFF。不能在始终OFF的状态宣称业务验收通过。公网和 WG 端扫描确认公司 SSH、8080/8082、5432、LAN 主机均不可达。必须验证没有云 DNS/证书签发权限。

同时核对公司服务器、云主机的时间同步状态与员工验证器设备的自动时间。TOTP按30秒时间步和有限容差工作，时钟异常先修复同步，不扩大验证码容差或取消MFA。将域名/ECS/EIP余额与到期、证书续期失败、隧道断连、服务器时间失步列入现有运维告警；日志不得包含验证码或注册密钥。公司网络断开后，内网证书校验、DNS和本地时钟须能继续工作。

固定5人优先使用签名原生客户端，资源随安装包、端点来自批准的构建配置。浏览器必须另验首次/版本升级下载、5人并发冷启动和热缓存；10Mbps入口总量理论仅约1.25MB/s，不能把小API的P95当作Flutter Web首次启动承诺。云仍不能解密或L7缓存正文；带宽不足应按采购文档扩容，不能把域名私钥移到云端。

只读压力工具默认只探测健康接口（它不测数据库业务吞吐）；业务验收另用已批准的**低敏感 GET**列表，例如将真实只读聚合接口逐条登记到本地 JSON 数组。不能用任意报表/导出/附件下载代替，不假定所有 GET 都无副作用。

```bash
python3 deploy/remote-access/performance_probe.py --base-url https://erp.company.example --acknowledge-live-read-load
# 业务 GET：在安全终端把短期最小权限 token 放到 UTEN_PROBE_TOKEN，或用安全管道配合 --token-stdin；不要放参数。
python3 deploy/remote-access/performance_probe.py --base-url https://erp.company.example --approved-get-paths /secure/probe/approved-paths.json --token-stdin --requests-per-stage 30 --acknowledge-live-read-load
```

每次依次发 5、10 并发，固定 GET，不跳转，不输出 token/URL 参数/正文；每响应最多读取 2 MiB。报告包含 P50/P95/P99、成功请求 P95、429 与其他错误、字节量。每请求使用新 TLS 连接，能暴露握手开销，**不等于浏览器 HTTP/2 长连接的实际体验**；还要补浏览器真实业务验收。用正式 TLS 或指定受控 CA，不允许跳过证书验证。

本地业务远程预算默认 `UTEN_REMOTE_MAX_CONCURRENT_REQUESTS=8`，公开health/readiness/liveness另有独立2并发预算；启动条件为 **业务预算 + 2 ≤ Hikari最大连接数 − 4**，默认8+2≤20−4。该检查针对名义请求容量；嵌套事务可使一个请求占用多个连接，不能据此宣称已物理预留4个连接。remote connector 24个线程、64个连接、16个等待连接。业务短突发可等待最多100ms，不能无限排队；健康探针不等待，预算满返回429及独有结构化码`REMOTE_CAPACITY_REJECTED`。仅该准入拒绝可以确认本次未进入业务；普通429、网关错误页或其他业务错误不能这样推断，此前已有未知提交也不能被这次拒绝消除。应用 `uten.remote.request.duration` 的5分钟P50/P95/P99与 `uten.remote.request.rejected` 应通过受控本地监测读取，不能开放公网actuator。提高远程并发前先复测LAN P95与数据库池等待，不能把连接池调大当作吞吐提升。

专用 Nginx 固定 2 个 worker；公司进程 CPUQuota=100%（一个 CPU 核的时间额度）、云进程150%，MemoryHigh=256MiB、MemoryMax=512MiB。它们是保护其他工作的初始资源预算，双层TLS的真实吞吐仍需测量；不要因为公司有很多核就自动启动同等数量远程worker。`2×8KiB` 是前端 header buffer 总预算，单个 header 上限仍8KiB；后端总header上限16KiB。Nginx不自行压缩API，但保留员工Accept-Encoding，后端专用connector可对≥4KiB JSON响应压缩；静态资源由Nginx低压缩等级处理。

### 员工如何开通和日常使用

1. 员工先在公司内网以本人账号登录；临时密码先完成改密。在“设置 → 远程身份验证”开始绑定，按系统要求再认证。
2. 用可信验证器扫描页面二维码或手工录入密钥，输入当前6位动态验证码确认。注册有效期10分钟；二维码只在本机显示，不调用外部二维码服务，也不要把截图/密钥发给其他人。
3. 内网超管在原有账号权限管理授予远程资格，再到“系统设置/平台设置 → 外网访问与连接”核对名单、验证器状态和5人容量。完成全部现场验收后，最后开启总开关。
4. 外出使用批准的正式客户端/业务域名，以账号、密码和验证码登录；现有单设备规则继续适用，同账号新登录会替换原会话。已经消费的验证码不要在同一时间步重复使用。验证码连续错误5次锁定15分钟，先核对自动时间，不靠连续尝试解决。
5. 远程会话的MFA证明最长8小时，可能随会话失效提前结束，系统可能要求再次验证。验证成功后原业务请求不自动重放；核对最新业务状态，再本人点击。此前已经发出但超时的提交仍须查结果，不能仅因重新验证成功就再次创建。
6. 更换/丢失手机时，经公司内网超管核实身份、填写原因并再认证后重置；旧会话立即失效，员工回内网重新绑定。管理页的重置按钮只展示在“已授权且已绑定”的名单行；已经撤权的账号不在此名单，须由受控运维核对账号ID，走同样受内网、超管、再认证与理由约束的`POST /api/auth/mfa/users/{userId}/reset`，不能临时给多余远程资格来绕过容量。本期没有邮件链接或远程管理员免MFA恢复入口。

## 6. 故障、恢复与紧急关闭

| 情况 | 预期行为 | 操作 |
|---|---|---|
| 云 ECS/公司公网/隧道故障 | 远程 TLS/请求失败；内网继续 | 查网络与隧道；不提升数据库、不创建离线写队列 |
| 短暂断线后恢复 | WG 自动重新握手，watchdog 可恢复缺失/过期接口 | 客户端重新获取业务状态，再决定是否重试 |
| 写请求超时/响应丢失 | 结果可能已经提交 | 通过业务单号/操作幂等键查询；代理不自动重试 POST/PUT/PATCH/DELETE |
| 429且统一错误码为REMOTE_CAPACITY_REJECTED | 本次未取得远程请求预算，未进入业务 | 降低远程负载；检查批量请求与慢 SQL；保留此前未知提交，核对后由本人决定再试 |
| 其他429或无结构化错误码 | 可能为账号/业务限流或代理拒绝 | 按具体错误处理，不能据状态码认定未执行或自动重放写 |
| 公司应用/数据库/断电故障 | 内外网都可能不可用 | 走既有本地恢复/备份流程；云只转发，不能代替数据库 |
| 域名证书续期失败 | 到期后客户端拒绝连接 | 公司 DNS-01 续期、验证后 reload；绝不关闭证书校验 |
| MFA连续校验失败 | 当前远程办理被拒绝，可能触发锁定 | 先核对设备及服务器自动时间、是否重复使用同一时间步；因子丢失走内网超管受控重置，不放宽验证窗口 |
| 云疑似失陷 | 先切断云到公司能力 | LAN 超管关远程总开关，禁用远程 nginx/watchdog，关闭 WG；轮换密钥并重建云 |
| 发布或回滚 | 内外网使用同一公司发行 | 保持现役签名发布/迁移流程；回滚前确认数据库兼容，不切到旧云 JAR |

紧急关闭只影响新远程入口：从公司 LAN 把远程总政策设 OFF；再在公司执行 `systemctl disable --now uten-remote-tunnel-watchdog.timer uten-remote-nginx.service`，随后 `systemctl stop wg-quick@wg-uten.service`。保留专用 firewall 表，防止后续误启动隧道暴露其他端口；不要 stop 现有 `nginx.service`、Spring 或 PostgreSQL。已开始执行的业务必须按提交事实核对，不能因为关闭入口就认定回滚。

回滚部署：保持全局 OFF，停用这些专用服务，移除/关闭两个 remote connector 环境项后按现役应用流程重启；恢复前一份专用配置即可，不动 LAN 入口和数据库。若恢复试点，先重新跑权限和网络负向验证，最后由 LAN 超管开启政策并单独授权人员。

从备份恢复之前就按上面的紧急关闭顺序停用远程代理、watchdog和WG，恢复及LAN核查期间持续保持隔离，不能先让恢复出的旧会话面对公网。按受控恢复流程撤销恢复出来的会话、刷新凭据及MFA证明，远程总开关保持OFF，重新复核近期授权/撤权记录后才安排受控接入验收。保留已绑定因子不代表保留旧登录证明。

首次 5 人阶段不建立云数据库或离线业务双写。公司宽带断开后仍要远程办公，优先增加公司独立运营商/4G 或 5G 备线和 UPS；公司机房灾备按[独立灾备控制面合同](../disaster-recovery/README.zh-CN.md)验证 RPO/RTO、恢复与单写隔离，不能用本目录的“隧道重连”或管理页面可用替代。
