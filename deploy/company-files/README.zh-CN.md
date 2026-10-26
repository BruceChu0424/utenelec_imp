# 公司资料库的内部存储

公司资料库复用统一附件原件服务，不建立第二套对象目录、公开静态 URL 或无扫描上传入口。资料库中的目录是数据库对象；磁盘对象使用服务端随机键，与可修改的文件名、目录名分离。新文件沿用 `presign -> raw PUT -> confirm` 协议，确认后才进入正式文件列表。

## 2026-10-25 只读核验

通过既有 `uten-imp-server` SSH 别名、专用密钥和 `StrictHostKeyChecking=yes` 读取；未安装脚本、修改配置、重启、部署或写入测试文件。时间点事实如下，正式启用前重跑核验：

| 位置 | 实际来源 | 可用字节 | 用途 |
| --- | --- | ---: | --- |
| `/` | `/dev/mapper/ubuntu--vg-ubuntu--lv` | 75,008,053,248 | 系统与应用运行 |
| `/var/lib/uten-imp-media` | `/dev/mapper/ubuntu--vg-uten--media` | 199,324,176,384 | 独立 NVMe 附件卷，约 185.6 GiB |
| `/data` | `/dev/md0` | 1,780,384,874,496 | 既有机械阵列，不能因空闲大就选为新原件目录 |
| `/srv/uten-backup` | `/dev/mapper/ubuntu--vg-uten--backup` | 48,950,849,536 | 独立本机备份卷 |

进一步 `lvs`/`lsblk` 只读确认：系统 LV 100 GiB、媒体 LV 200 GiB、备份 LV 60 GiB 均位于同一块 `nvme0n1p3`；机械盘为 `sda/sdb`。这里的“独立卷”是容量隔离，媒体文件不会吃掉系统文件系统的剩余空间，不代表独立物理磁盘或故障域。I/O 仍共享同一 NVMe，故保留并发 2 和预览/备份预算；同盘备份仍需异机恢复点。

实际附件根为 `/var/lib/uten-imp-media/attachments`，合计约 155.6 MiB；根和 `staging/final/scratch/preview` 均为 `uten-imp:uten-imp 0700`。该卷为 ext4，已设置 `rw,nodev,nosuid,noexec`。现役 `internal`、上传开关、ClamAV 均已启用，ClamAV service 为 active。单文件 25 MiB、I/O 并发 2、余量保留 10 GiB。以上证明当前配置与容量，不能代替新资料库 API 的上线验收。

**现场差异**：实际 Java 进程沿用 `UTEN_CLAMAV_HOST=127.0.0.1`、`UTEN_CLAMAV_PORT=3310` 的 TCP 扫描，未设置 Unix socket，实际 TCP listener 仅在 loopback。现役 TCP 扫描不能因此被判为不可用。虽然 socket 存在，它的权限为 `clamav:clamav 0660`，`uten-imp` 无访问权，尚未达到仓库当前 Unix socket 模板。将本门禁源码在内存中以实际 `uten-imp` 身份只读运行，挂载/UUID/目录/容量均通过，最终因 socket 不可访问明确拒绝。不能把本 drop-in 直接装进现役服务造成启动失败，不能仅因 socket 文件存在就称扫描验收完成。本次未更改任何现场配置。

旧文档中的 `/data/uten-imp/attachments` 和 NVMe commissioning 中间状态不能作为本功能的新写入路径。现役 unit 仍有旧路径的可写兼容项，仓库现役模板仅放行媒体卷与日志；后续按旧原件引用盘点单独处理，资料库不得借用兼容路径写入。

## 防止占用系统盘

### 2026-10-26 只读复核补充

本轮从活进程环境中仅提取无秘密的存储/扫描/预览配置：仍为 `internal`、媒体卷根 `/var/lib/uten-imp-media/attachments`、10 GiB 余量及上传开启；ClamAV 为 active，活进程已经配置 `/run/clamav/clamd.ctl`。这更新了上节 2026-10-25 的 TCP 配置时间点，不能据此推定本轮重新执行过真实 EICAR、挂载门禁或备份恢复。

Office 转换明确为 `UTEN_ATTACHMENT_PREVIEW_ENABLED=false`，`/usr/bin/soffice` 不存在。已安装的 root:root 0755 `/usr/local/libexec/uten-preview-soffice` 与本轮修改前的环境清理包装器一致，只清除继承环境，不提供独立文件/网络隔离。因此当前 Word/Excel/PPT 等转换预览尚未启用，保持原件下载。本轮已提供[独立 worker 候选](PREVIEW_WORKER.zh-CN.md)，新客户端另用 `/usr/local/libexec/uten-preview-soffice-isolated`，避免误调用现场旧 wrapper；开启前须完成成套部署和真实 systemd/员工模板验收。本轮没有安装、修改服务器配置、部署或重启。完整检查与本地验证见[本轮记录](../../docs/99-项目治理/2026-10-26-公司资料库安全稳定性检查.md)。

`RequiresMountsFor` 负责启动依赖，但还需要验证实际挂载对象，避免 fstab 被误改或挂载消失后落到根文件系统。提供只读启动门禁：

- `validate_storage.py`：核对独立文件系统、精确挂载来源和文件系统 UUID、ext4 保护选项、无符号链接、同卷命名空间、0700 属主、10 GiB 最低保留及可访问的 ClamAV Unix socket。已存在的 preview 缓存目录同样核验。失败时返回非零，不创建目录、不回退路径、不读取密钥文件、不触碰对象。
- `storage-policy.example.json`：部署时填入当次 `findmnt -T /var/lib/uten-imp-media/attachments -no SOURCE,UUID` 的受审来源和 UUID；示例占位符必定被拒绝。通过 root 控制的 `/run/udev/data/b<major>:<minor>` 确认实际挂载 UUID，可在 `PrivateDevices` 下运行；udev 证据不可读也拒绝启动。策略归 root 且不可由组或其他用户写入。
- `30-company-files-storage.conf`：附加到现役 `uten-imp.service` 的可选 drop-in，增加 mountpoint 断言和 Java 前置门禁，不增加可写目录。

部署事务中安装 Python 到 `/usr/local/lib/uten-imp/validate-company-files-storage.py` (root:root 0755)，策略到 `/etc/uten-imp/company-files-storage.json` (root:root 0644)，先带现役已加载环境以 `uten-imp` 身份执行预检，再安装 drop-in。不能把全部 `server.env` 打印到终端或 source 到不受控 shell。安装和重启属于后续受控发布，本次只提供文件与测试。

门禁不替代运行中防护：`InternalStorageService` 每次操作检查真实目录、流式大小及可用空间，有界 I/O 槽位；对象先暂存、扫描、校验摘要和大小，再原子发布。Nginx 原件上传 location 继续使用无落盘的流式反代，不能新增 multipart 处理或系统 `/tmp` 文件副本。现场只读确认现役 `/api/attachments/raw/[A-Za-z0-9._-]+` location 已设 `client_max_body_size 25m`、`proxy_request_buffering off`，上传不先缓冲为系统盘请求体临时文件。Office 转换缓存与 scratch 同在媒体卷，缓存容量上限沿用现有配置；未安装安全转换器时下载原件。

## 后续维护窗口的 socket 切换步骤

以下命令是后续受控发布方案，本轮没有执行。`$reviewed` 指已签名、校验散列且解包为 LF 的本次发布源码根，不能直接指向多人修改中的工作树。先留存现役 `server.env`、ClamAV service/socket 配置和 drop-in 的 root 私有 preimage，核对实际 socket-activation 配置；保持当前 TCP 方案可回退。先临时停止接收新上传并排空在途确认，在维护窗口停止应用，再切换扫描监听，避免在业务请求中途撤去原监听。

```sh
# 核对当次物理设备和UUID，写入root控制的policy；不打印server.env
findmnt -T /var/lib/uten-imp-media/attachments -no TARGET,SOURCE,UUID,OPTIONS
sudo install -d -o root -g root -m 0755 /etc/systemd/system/clamav-daemon.socket.d
sudo install -o root -g root -m 0644 \
  "$reviewed/deploy/systemd/clamav-uten-imp-unix.socket.conf.example" \
  /etc/systemd/system/clamav-daemon.socket.d/uten-unix.conf
# 在受控preimage事务里移走已退役uten-loopback.conf；不要保留互相叠加的TCP/socket监听
sudoedit /etc/clamav/clamd.conf
# clamd.conf必须与socket activation一致，去掉旧TCPSocket/TCPAddr，确认LocalSocket和父目录0755
sudoedit /etc/uten-imp/server.env
# 仅合并：UTEN_CLAMAV_UNIX_SOCKET=/run/clamav/clamd.ctl；保留其它凭据和配置
sudo systemctl daemon-reload
sudo systemctl stop clamav-daemon.service clamav-daemon.socket
sudo systemctl start clamav-daemon.socket clamav-daemon.service
sudo stat -c '%a %U %G %n' /run/clamav /run/clamav/clamd.ctl
# 预期父目录0755，socket clamav:uten-imp 0660；不能用chmod777或加app进clamav组代替
sudo install -o root -g root -m 0755 "$reviewed/deploy/company-files/probe_scanner.py" /usr/local/lib/uten-imp/probe-company-files-scanner.py
sudo -u uten-imp /usr/bin/python3 -I /usr/local/lib/uten-imp/probe-company-files-scanner.py
sudo -u uten-imp /usr/bin/python3 -I /usr/local/lib/uten-imp/probe-company-files-scanner.py \
  --socket /run/clamav/intentionally-absent-uten-acceptance.sock --expect-unavailable
```

探针只在内存构造干净文本与标准 EICAR 测试串，经同一个 Unix INSTREAM 协议检查两个明确判定，连接/读写期限五秒，单次响应不超过 1 KiB，不把病毒测试文件写入系统盘或公司资料库。`--expect-unavailable` 验证连接失败会被明确分类；真实扫描超时/残缺响应的客户端拒绝还需运行 `ClamAvMalwareScanner` 回归，不能把不存在socket测试称为真实超时演练。

干净/EICAR/不可用检查全部达到预期后，才安装本目录 storage gate、填写并安装 policy，再安装 drop-in。以 `uten-imp` 加载受控环境执行完整 storage gate，通过后启动应用；核验活进程明确使用 Unix socket、旧 TCP listener 已消失、readiness、真实授权上传/下载字节一致后恢复接收。任一步失败先恢复本次 preimage 中的 scanner/app 成套配置，再启动原服务；不改数据库、原件或既有密钥。新 gate 不应先于 socket 验收安装。

## 容量、保留与恢复

资料库复用既有待上传配额：每用户最多 10 个/100 MiB，每业务对象最多 20 个/250 MiB；上传失败和超时由统一到期清理处理，不能将 pending 当正式文件。回收站是可恢复的逻辑删除，保留原件和来源历史，不提供无备份永久清空。长期容量包括活动文件、回收站、未确认暂存和预览缓存；告警与余量均按整个媒体卷计算，不能只看当前目录文件大小。

备份复用已覆盖媒体根的配套备份：数据库和被引用的精确原件版本同时保存并实际恢复。新功能上线前确认备份配置实际覆盖 `company_file` owner 的附件，不只根据文件夹名称推测覆盖。单机 NVMe 副本不能作为异机灾备证明。

**容量不能只看媒体卷**：媒体 LV 为 200 GiB，而本机备份 LV 只有 60 GiB，当前空闲约 45.6 GiB，且两者同属一块 NVMe。媒体卷有约 185.6 GiB 空闲，不代表这些字节已经具备备份接收能力。资料库增长前按配套备份真实目标、保留天数、完整份数、数据库/WAL 和原件实际压缩率重新预算；媒体、备份两侧均需容量告警，并验证最新配对恢复点可还原。不能通过减少最低完整恢复份数或清理未到期原件来“腾出”容量；预算不足应暂停扩大接收并规划受审备份扩容/异机目标，本次不临时新增业务库配额。

## 执行验证

本地只读门禁单元测试：

```powershell
python -m unittest discover -s deploy/company-files -p 'test_*.py' -v
```

上线矩阵包括：真实 Word/Excel/PDF/中文文件名上传下载 SHA-256 一致；错误扩展名/魔数、超限、截断、EICAR、扫描不可用/超时、磁盘余量不足、有界并发；目录撤权、密码到期/更改、跨账号/跨会话及通用附件直链；未挂载/错误卷/只读卷/目录 symlink 启动拒绝；回收站还原与同名冲突；成套备份还原后数据库对象和原件一致。

安全设计参考：[OWASP 文件上传指南](https://cheatsheetseries.owasp.org/cheatsheets/File_Upload_Cheat_Sheet.html) 对扩展名、真实内容、授权、大小、杀毒和站点目录外保存的分层要求；[systemd.unit](https://www.freedesktop.org/software/systemd/man/systemd.unit.html) 的挂载依赖与 mountpoint 断言，以及 [systemd.exec](https://www.freedesktop.org/software/systemd/man/systemd.exec.html) 的可写路径隔离。实现仍以项目 ADR-074 与当前 Simple 部署约束为准。
