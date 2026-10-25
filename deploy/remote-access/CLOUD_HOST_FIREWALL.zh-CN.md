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
SSH 还承载公司备份上传和受限救援代理。收紧前须根据真实认证记录核对这些固定作业的出口及身份，
为其保留独立、精确的来源规则；不能只放行管理员出口而阻断公司 `ingest` / `broker` 新连接。
动态公司出口变更也须由独立云控制台维护；不要为省维护直接扩大成整个运营商网段。
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
管理员新连接与公司备份/代理各自的新连接都必须通过；已有长连接仍在线不能证明新规则允许其重连。
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
helper或模板升级也应在维护窗口重新trial/确认，不得把“已有active策略”当成新模板已验收。
`active.json`是版本化确认收据，原子绑定policy、已确认rendered字节/摘要及helper/template身份；禁止直接编辑。
正常boot先校验这些绑定，只加载原已确认字节。试用中或确认后发生的实现/模板漂移都会拒绝加载，保留当前表与active原字节。
旧版仅policy的active文件不算已绑定验收，只能在显式新trial中作为原状回退证据；新TCP确认后才升级为绑定收据。
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
应用成功后再次采集server:22非LISTEN的TCP四元组（包括半开/关闭中的可见socket），合并初始集合并原子保存后，
才标记确认就绪。timer启动、检查或应用期间建立的第二连接不能充当“新规则允许新SSH”的证据。
后采样或收据写入失败会保留未就绪pending及回退授权；即使之后出现新连接也不能确认或持久化。
不得直接开启下一次试用掩盖失败。

保留原SSH窗口，看到成功的TRIAL回执后再从另一窗口建立**新的TCP连接**，例如：

```text
ssh -o ControlMaster=no -o ControlPath=none -o StrictHostKeyChecking=yes -o BatchMode=yes -o IdentitiesOnly=yes -i <原有已核验私钥> root@<已核验EIP>
```

工具拒绝原连接、ControlMaster复用及应用后截止采样中已有的第二连接。新连接中核对HTTPS、WireGuard握手/业务入口、
真实监听端口的外部可达性及其他防火墙表保留情况，再用trial返回的token确认：

```bash
python3 /usr/local/lib/uten-remote/cloud_host_firewall.py confirm --token <trial返回的token>
```

只有确认成功才保存绑定active收据、enable开机unit并撤销回退timer。
同一启动周期内未确认则由仍存活的timer到期只恢复本表及先前active/unit状态。
确认后可独立执行 `systemctl start uten-cloud-host-firewall.service` 验证真实unit入口，再做一次新SSH/HTTPS验证。
enabled、真实unit启动成功、实际重启后验收是三种不同证据；不得仅凭unit文件声称开机自启已验收。
停止unit不会删除防火墙规则，避免服务异常导致意外开放。

**未确认试用遇到主机重启：**内存nft规则和transient timer会丢失。若unit尚未enabled或active条件未满足，
systemd不会调用boot入口；首次trial的正常状态正是disabled且没有active。因此pending可能留在磁盘，
不会自动收尾。管理员必须先只读核对当前nft表、SG、SSH通路及pending记录，再使用对应token显式rollback清理，
不能手删pending或把直接调用`boot()`的测试当成真实开机恢复。
已有确认收据且unit已enabled时，boot入口才有真实调度条件；它可恢复后续未确认trial记录的原状，再按绑定收据加载。
boot拒绝漂移只代表拒绝加载该候选；`Before=`不等价于网络必须等待它成功，不能据此声称整机已fail-closed。
启动后仍须读回本表、验证新SSH/HTTPS和云SG限制。

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
另验证预应用第二连接拒绝、后采样失败不准确认、绑定收据阻止确认后模板漂移。
不能代替云主机实际timer与unit验收；合成22端口监听也不是sshd认证测试。

依据：[nft链与最终drop行为](https://wiki.nftables.org/wiki-nftables/index.php/Configuring_chains)、
[原子规则替换](https://wiki.nftables.org/wiki-nftables/index.php/Atomic_rule_replacement)、
[systemd独立timer服务](https://www.freedesktop.org/software/systemd/man/latest/systemd-run.html)、
[阿里云安全组](https://www.alibabacloud.com/help/en/ecs/user-guide/start-using-security-groups)、
[VNC与其他连接方式](https://help.aliyun.com/en/ecs/user-guide/connect-to-instance)。
