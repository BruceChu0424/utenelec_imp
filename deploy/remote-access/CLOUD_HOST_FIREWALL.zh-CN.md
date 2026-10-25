# 云代理主机入站防火墙

本方案只适用于现有云代理，独立维护 `inet uten_cloud_host`；保留现有 `inet uten_remote`、iptables及其他团队规则。
`uten_remote` 继续负责隧道隔离和代理进程出站范围。它的input默认accept不等于整机default-deny。
不修改公司服务器，不使用全局清空命令，不停止现有隧道防火墙或放宽其业务权限。

## SSH来源由哪一层管理

| 模式 | 主机22端口 | 管理员IP变化时 | 使用前提 |
|---|---|---|---|
| `security-group`（建议） | 允许指定网卡的IPv4 SSH；来源限制交给云安全组 | 在已验证的云控制台维护精确来源，无需OS控制台密码 | 已能独立登录云控制台并管理实际绑定的安全组；准确读回全部SG规则 |
| `host-allowlist` | 仅显式批准的公网IPv4 `/32` | 旧地址仍可用时先增后删；已失去旧地址须有可用OS救援shell | 实际完成独立VNC/受控救援shell登录；只看到console login提示不算通过 |

`security-group` 模式必须使用空 `admin_ipv4_cidrs`，避免旧profile中的地址看起来有效却不再属于当前维护人。
它不能单独证明SSH已限制：若云安全组仍允许22来自任何IPv4，则SSH来源仍公开。
应在云控制台把22收紧为实际管理出口的精确来源，并用新的SSH TCP连接复验；不要同时盲改两层规则。
还需检查同安全组内网默认互通、其他绑定安全组/网卡、来源优先级及Workbench来源，不能只看一条规则。
不为使用本工具强迫启用Session Manager、新增长期权限或设置新的OS密码。

两种模式均保留loopback和已有连接，公网业务仅IPv4 TCP443、UDP51820；其余新入站及转发默认drop。
允许必要IPv4错误/限速ping、IPv6路径MTU与邻居发现；不因IPv6监听而自动开放新的IPv6 SSH/HTTPS。
DHCPv4回复是否放行必须根据真实网卡配置显式决定，不能猜机器使用静态地址。
WireGuard可以对显式公司公网`/32`开放；公司出口动态时可仅UDP51820允许公网，仍由WireGuard密钥认证。

## 安装前只读核对

记录当前 `SSH_CONNECTION` 四元组、`ip -j address`、路由、真实入站网卡、DHCP/静态配置、`ss -lntup`，
以及 `nft -j list ruleset`、防火墙unit状态与全部绑定安全组规则。不得把旧profile当成当前网络授权。
只读取必要字段；不输出.env、SSH私钥、WireGuard私钥或完整云凭据。

选择`security-group`时，先确保用户可从独立浏览器登录实际ECS所属云账号并维护该实例的安全组。
安全组变更先新增精确来源、保持已有连接，再移除22的泛来源，随后在禁用SSH复用的全新连接中验证。
该步骤由拥有云控制台的维护人执行，源码生成、占位配置或旧截图都不能代替实际读回。
VNC到达登录提示只证明控制台链路可达；Session Manager按钮可见也不证明它已启用。

## 候选配置与安装

复制 `cloud-host-firewall.example.json` 到受控私有目录后填写真实 `public_interface` 和布尔 `dhcpv4`。
保留 `role=cloud`，明确选择上述模式。示例中的REPLACE占位值会被拒绝。
`host-allowlist`模式的`admin_ipv4_cidrs`必须包含当前 `SSH_CONNECTION` 的公网来源；拒绝泛CIDR。

先运行仅生成候选的命令，输出文件必须不存在：

```bash
python3 cloud_host_firewall.py render \
  --policy /root/reviewed-cloud-host/policy.json \
  --output /root/reviewed-cloud-host/candidate.nft
```

生成不安装、不修改网络。按受审源码/签名包核对hash后，原子安装以下文件：

| 源 | 目标 | 权限 |
|---|---|---|
| `cloud_host_firewall.py` | `/usr/local/lib/uten-remote/cloud_host_firewall.py` | root:root 0755 |
| `templates/cloud-host-firewall.nft.tmpl` | `/usr/local/lib/uten-remote/templates/cloud-host-firewall.nft.tmpl` | root:root 0644 |
| `units/uten-cloud-host-firewall.service` | `/etc/systemd/system/uten-cloud-host-firewall.service` | root:root 0644 |
| 已审实际policy | `/root/reviewed-cloud-host/policy.json` | root:root 0600 |

状态目录 `/var/lib/uten-remote/cloud-host-firewall` 必须是root:root 0700。安装前确认没有pending事务，
不要在回退timer依赖旧helper时更换它。用同目录`.next`文件加原子rename，避免把正在被回退服务读取的源码写到一半。
helper或模板升级也应在维护窗口重新trial/确认，不得把“已有active策略”当成新模板已验收；确认会拒绝试用中改变的helper/模板。
安装后执行 `systemctl daemon-reload` 和针对该unit的 `systemd-analyze verify`，确认本机发行版无依赖/路径错误。
**此时不要enable/start主机防火墙unit**；首次trial仍须保持原网络状态与可回退性。

## 内存试用、独立连接确认和持久化

在当前已验证SSH连接中运行，`SSH_CONNECTION`必须保留；不要把旧四元组写死为启动参数。
建议的SG来源管理模式使用：

```bash
python3 /usr/local/lib/uten-remote/cloud_host_firewall.py trial \
  --policy /root/reviewed-cloud-host/policy.json \
  --security-group-console-verified --rollback-seconds 180
```

该flag表示实际确认了云控制台的SG管理通路，不表示已取得VNC OS shell。
`host-allowlist`改用`--recovery-access-verified`，仅在真实救援shell已验收后使用。
工具核对服务器端真实已建立SSH四元组；先写root私有回退收据，独立启动systemd timer并确认active，
然后`nft --check`，再在一个事务中仅替换`uten_cloud_host`。首次试用不写active策略、不enable开机unit。
检查失败保留pending及回退授权，不允许直接开启下一次试用掩盖失败。

保留原SSH窗口，立即从另一窗口建立**新的TCP连接**，例如：

```text
ssh -o ControlMaster=no -o ControlPath=none -o StrictHostKeyChecking=yes -o BatchMode=yes -o IdentitiesOnly=yes -i <原有已核验私钥> root@<已核验EIP>
```

工具拒绝原连接、ControlMaster复用及试用前已有的第二连接。新连接中核对HTTPS、WireGuard握手/业务入口、
真实监听端口的外部可达性及其他防火墙表保留情况，再用trial返回的token确认：

```bash
python3 /usr/local/lib/uten-remote/cloud_host_firewall.py confirm --token <trial返回的token>
```

只有确认成功才保存active策略、enable开机unit并撤销回退timer。未确认则到期只恢复本表及先前active/unit状态。
确认后可独立执行 `systemctl start uten-cloud-host-firewall.service` 验证真实unit入口，再做一次新SSH/HTTPS验证。
enabled、真实unit启动成功、实际重启后验收是三种不同证据；不得仅凭unit文件声称开机自启已验收。
停止unit不会删除防火墙规则，避免服务异常导致意外开放。

手动放弃未确认试用：

```bash
python3 /usr/local/lib/uten-remote/cloud_host_firewall.py rollback --token <对应token>
```

不要手改pending收据、清空其他表或停用现有`uten_remote`来恢复连接。SG模式的动态IP变更优先在独立云控制台
更新精确来源；host-allowlist模式先同时批准旧/新`/32`并验证新连接，再移除旧来源，每次都重新试用/确认。

## 本地回归与证据边界

```bash
python3 -S -m unittest discover -s deploy/remote-access -p test_cloud_host_firewall.py -v
sudo python3 -S deploy/remote-access/tests/cloud_host_firewall_linux.py --nft /usr/sbin/nft
```

第二条自行进入全新network namespace；里面没有对外网卡/默认公网路由，只创建隔离veth、合成TCP/UDP服务和
受控nft表。覆盖既有连接、新SSH来源控制、SG委托模式、HTTPS/WG、其他端口/转发、loopback、IPv6邻居发现、
DHCP、后续base-chain drop、失败事务保留旧表及独立定时进程执行真实回退。systemd管理命令在该测试中stub，
不能代替云主机实际timer与unit验收；合成22端口监听也不是sshd认证测试。

依据：[nft链与最终drop行为](https://wiki.nftables.org/wiki-nftables/index.php/Configuring_chains)、
[原子规则替换](https://wiki.nftables.org/wiki-nftables/index.php/Atomic_rule_replacement)、
[systemd独立timer服务](https://www.freedesktop.org/software/systemd/man/latest/systemd-run.html)、
[阿里云安全组](https://www.alibabacloud.com/help/en/ecs/user-guide/start-using-security-groups)、
[VNC与其他连接方式](https://help.aliyun.com/en/ecs/user-guide/connect-to-instance)。
