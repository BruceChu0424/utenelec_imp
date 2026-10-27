# 公司内网 HTTPS 与自动续期

内网固定 IP 使用公司的内部 CA。浏览器必须同时验证有效期、访问地址、签发链和本机信任；只重新签发服务器证书不能补齐员工电脑的根信任。公共 CA 不签保留内网 IP，依据 [CA/Browser Forum 要求](https://cabforum.org/working-groups/server/baseline-requirements/requirements/)。Windows 根信任见 [Microsoft 证书存储说明](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/trusted-root-certification-authorities-certificate-store)。不要关闭 TLS 校验或让员工长期跳过浏览器警告。

## 员工电脑

由管理员通过可信渠道交付 `erp-trust-init.bat`、`erp-trust-init.ps1` 和公开的 `uten-imp-root-ca.crt`，三者放在同一目录，也可打成 ZIP。解压后运行 BAT；安装到当前 Windows 用户的受信任根，Windows 安全确认由用户亲自接受。无需管理员和 hosts 修改。每位 Windows 用户首次安装一次；相同根签发的服务器证书自动续期后无需重复安装。完成后完全退出并重开 Edge/Chrome，访问公司的内网地址。

脚本在任何证书存储写入前验证 **X.509 DER 的 SHA-256**，同时验证有效期、CA 标志、公开根身份和体积；拒绝错误根、多个 PEM 和重定向。优先使用 ZIP 中的公开根，缺失时仅从固定 HTTP 精确路径下载公开证书。脚本及预期指纹不能从同一未验证下载动态获取。不能从 HTTP 下载并自动运行代码。已经信任根的电脑可从 HTTPS `/ca/uten-imp-trust.zip` 下载管理员提供的包；未信任的电脑应从可信管理渠道取得完整包。

## 服务端唯一续期入口

- 源码：`host/uten-lan-tls-renew.py`；安装为 root:root 0755 `/usr/local/sbin/uten-lan-tls-renew`。
- 单元：`units/uten-lan-tls-renew.service`、`.timer`，安装到 `/etc/systemd/system/`。
- 签发者：root-only `/etc/uten-lan-tls/issuer.key`，公开证书 `issuer.crt`。必须由现有公司根签发，critical CA TRUE/pathlen:0，critical nameConstraints 精确包含脚本中审核的三个 DNS。签发者初始有效期五年；自动任务不读取根私钥。
- 服务器证书：`/etc/ssl/certs/uten-imp-lan.crt` 为叶子和签发者完整链；继续使用原 `/etc/ssl/private/uten-imp-lan.key`，不轮换共享私钥。
- 每日服务器当地时间 03:45 后随机 0–30 分钟检查，断电错过会补跑；剩余 30 天内自动签发 365 天证书。根或签发者剩余不足 400 天时停止签发并告警，管理员须受控更新签发者；不自动更换员工信任根。
- 先验证根指纹、受限签发者、SAN、链和密钥，再原子安装、`nginx -t`、平滑 reload、真实回环 TLS 验证；失败恢复原证书。检查发现磁盘与已加载证书不一致时，普通模式重新校验和加载，`--check-only` 不修改 Nginx。
- **Windows 桌面兼容性**：已发布桌面版使用的 Dart/BoringSSL 不支持 `iPAddress` nameConstraints，实际握手会报 `unsupported name constraint type`。因此签发者只保留 DNS 名称约束，禁止添加 IP 名称约束；叶子仍必须含审核后的精确 IP SAN，并由固定签发器与验证器双重强制执行。IP 签发范围是受控代码规则，不声称由 CA 名称约束在密码学层面限制。不得把 Windows 原生链或 OpenSSL 通过当作桌面版通过；更新签发策略须同时验证真实 Dart/公司 Dio adapter 的 IP 和主域握手。证据见 [BoringSSL 官方实现](https://raw.githubusercontent.com/google/boringssl/main/crypto/x509/v3_ncons.cc) 和 [Dart 官方兼容性记录](https://raw.githubusercontent.com/dart-lang/tools/main/pkgs/boring/test/conformance/x509_limbo_expected_failures.txt)。
- `/var/lib/uten-lan-tls/status.json` 保留检查、最近成功和续签时间；`previous-fullchain.crt` 保存最近一次替换前公开证书。进程锁防止并发。失败经 `OnFailure=uten-alert@%n.service` 进入现有站内运维告警；未据此声称邮件/短信已送达。

正式安装时仅将脚本中的 `__LAN_IP_ADDRESS__` 渲染为审核后的内网 IPv4，保留源码及渲染后 SHA-256，按 RUNBOOK 的原始字节传输纪律安装并核对服务端摘要。未渲染的脚本拒绝运行。`systemctl daemon-reload` 后先在相同正式 service 沙箱内执行一次强制续期，验证签发、日志权限、Nginx 校验和真实 HTTPS，再删除临时 ExecStart 覆盖，启用定时器：

```bash
sudo systemctl enable --now uten-lan-tls-renew.timer
sudo systemctl start uten-lan-tls-renew.service
sudo systemctl show uten-lan-tls-renew.service -p Result -p ExecMainStatus
sudo systemctl list-timers uten-lan-tls-renew.timer
sudo cat /var/lib/uten-lan-tls/status.json
sudo /usr/local/sbin/uten-lan-tls-renew --check-only
```

服务通过 `InaccessiblePaths` 隔离根私钥和业务秘密，限制写入范围、网络仅回环，禁用 core dump。`CAP_DAC_OVERRIDE` 用于现有 Nginx 日志 `www-data:adm 0640` 下执行完整 `nginx -t`；`CAP_NET_BIND_SERVICE` 用于其检查低端口监听。不能误删所需权限后把健康跳过当成完整续签验收。

初始化签发者只在受控维护中调用根签发权；根私钥继续按 RUNBOOK 9.3 单独离线托管，自动化服务不依赖根私钥在线。本次不以删除根私钥代替已验证的托管，未验证托管前不得删除。灾备材料须包含签发者、叶子和必要密钥，沿用现有秘密保护与管理员恢复控制。

## 回归与回滚

Linux 以 root 在隔离临时目录运行 `python3 host/test_uten_lan_tls_renew.py`，使用临时测试 CA 和真实 OpenSSL，不访问生产路径。覆盖真实签发、健康跳过、30 天门限、私钥保留、错误根/约束/SAN/即将过期签发者拒绝、校验及 TLS 失败回滚、中止后恢复、只读检查与状态历史。员工脚本可 dot-source，仅加载验证函数，不下载或打开证书存储。

回滚先停用定时器，恢复 `/var/lib/uten-lan-tls/previous-fullchain.crt` 对应的审核证书，校验后 reload；不改业务、数据库、员工根信任。Nginx HTTP 只公开精确的公有根下载路径，其余业务继续跳转 HTTPS；新增 HTTPS 根/ZIP 精确路径应保留原网段 ACL，不能开放目录索引或私钥文件。
