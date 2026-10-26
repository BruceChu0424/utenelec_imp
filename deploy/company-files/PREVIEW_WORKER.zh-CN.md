# 独立文档预览 worker

状态：2026-10-26 本地候选；没有安装到公司服务器、开启转换或完成真实 systemd 隔离验收。现场 Office 转换关闭，旧 `/usr/local/libexec/uten-preview-soffice` 仅清理环境，不能视作本方案。

## 边界与统一入口

公司资料库与其他业务附件继续使用 `AttachmentPreviewService`，先校验当前附件/owner/目录 ACL、密码和会话，再验证原件、展开量和活动资源；转换结束读取响应前再核验当前授权。Java 的固定转换命令调用 `/usr/local/libexec/uten-preview-soffice-isolated`，该客户端只把当前原件字节、允许的后缀、摘要和固定限额传给 `/run/uten-imp-preview.sock`，不发送文件名、主机路径、数据库参数或环境变量。

`Accept=yes` 为每个连接启动一个 `DynamicUser` 服务。worker 只执行固定 `/usr/bin/soffice`，不接受命令、文件路径或任意导出类型。每请求有私有目录和全新 profile；Java 与 worker 共用仓库唯一的 `attachment-preview-safe-profile.xcu`。客户端和 worker 都校验 SHA-256、长度及 PDF 签名；只有完整成功结果才写入 Java 当前工作目录的 `source.pdf`。失败、缺失 socket、断连或超时不回退同身份转换。

每连接单独限制：原件 25 MiB、PDF 64 MiB、转换 60 秒、连接读写各 15 秒、服务总运行 90 秒、工作 tmpfs 384 MiB、内存 768 MiB（禁 swap）、CPU 100%、64 个任务。socket 同时最多 2 个连接，最坏内存预算约 1.5 GiB；应与 ERP、数据库、扫描和备份一起规划宿主容量。Java 本身还有并发闸门、ZIP 展开量/条目和输出限制；调大 Java 配置不会放宽 worker 协议上限。

服务使用独立网络、私有 `/run` 和设备、只读系统、不可见的其他身份进程、空 capability、禁止新增权限，并隐藏业务配置、原件、应用、旧数据及备份目录。进程组清理处理超时与断线，`KillMode=control-group` 和总运行时限进一步清理逃离进程组的后代。私有 tmpfs 不占附件原件目录；资源或转换失败不修改原件。

## 成套安装候选

以下仅供受控发布；本次未执行。`$reviewed` 必须是散列核对、LF 行尾的冻结候选，不能指向多人同时修改的工作树。先保存现役文件、unit 和环境中相关字段的 root 私有 preimage，保留关闭转换的回退方案。

1. 保持 `UTEN_ATTACHMENT_PREVIEW_ENABLED=false`，确认 Ubuntu/systemd 支持本 unit 的全部保护项，安装匹配的 LibreOffice Writer/Calc/Impress/Draw 和中文字体，并保持系统安全补丁维护。
2. root:root 0755 创建 `/usr/lib/uten-imp-preview`，安装下表文件；unit/profile 不能由应用或其他用户写入。新客户端使用独立名称，防止与现场旧环境清理包装器混淆。

| 仓库输入 | 安装目标 | 属主与模式 |
| --- | --- | --- |
| `deploy/company-files/preview_worker.py` | `/usr/lib/uten-imp-preview/preview_worker.py` | root:root 0755 |
| `server/src/main/resources/attachment-preview-safe-profile.xcu` | `/usr/lib/uten-imp-preview/attachment-preview-safe-profile.xcu` | root:root 0644 |
| `deploy/simple/host/uten-preview-soffice.py` | `/usr/local/libexec/uten-preview-soffice-isolated` | root:root 0755 |
| `deploy/company-files/uten-imp-preview.socket` | `/etc/systemd/system/uten-imp-preview.socket` | root:root 0644 |
| `deploy/company-files/uten-imp-preview@.service` | `/etc/systemd/system/uten-imp-preview@.service` | root:root 0644 |

3. 对上述候选执行 `systemd-analyze verify`；不存在的 app 路径可由 unit 的 `-` 前缀容忍，不能删除实际存在的秘密/原件目录的屏蔽。核对 unit 来源、没有意外 drop-in，再 `daemon-reload`、启动 socket。socket 必须为 root:uten-imp 0660，worker 不加入 uten-imp 组。
4. 在隔离验收环境验证真实运行进程：独立且不同于 ERP 的 UID、不同网络命名空间、`/run` 不含宿主服务 socket、不能读 ERP 配置/原件/备份和 ERP 的 `/proc/*/environ`、不能访问外网/内网/宿主服务、不能在允许范围外写入。验证父进程退出/setsid 后代、超时、断线及内存/磁盘限额后整个实例 cgroup 归零。静态 unit 检查和 Docker 不能替代这一步。
5. 使用脱敏中文 Word/Excel/PPT/SVG 经客户端和真实 worker 转换；核对 PDF 版式、页数、中文字体、表格/公式显示，原件下载 SHA-256 不变。覆盖 SVG 外部资源、Office 自动外链/宏、重复请求、并发上限、非法长度/摘要、坏 PDF、转换失败和已撤权对象；数据/API 授权仍走 Java，不能直接用 socket 测试冒充授权验收。
6. 上述通过后，才在现役环境设置 `UTEN_ATTACHMENT_PREVIEW_SOFFICE_PATH=/usr/local/libexec/uten-preview-soffice-isolated`，随匹配应用版本受控重启并开启转换；以真实员工账号验证权限/密码/直链与回退。不能仅发新版 Java 或只打开 enabled：现场旧 wrapper 不会自动获得隔离。

回退时先关闭转换入口并排空在途请求，再按 preimage 恢复匹配配置；原件、数据库、密码与密钥不变。缺失 worker 时保持下载原件，不能通过将路径改回 `/usr/bin/soffice` 绕过隔离。

## 本地验证与限制

`deploy/updater/test_preview_soffice_launcher.py` 使用真实 Unix socket 验证客户端协议、原件字节、失败拒绝和无部分发布。`deploy/company-files/test_preview_worker.py` 使用真实 POSIX socket/父子进程及假转换器验证工作区、profile、摘要、限额、超时与断连清理。假转换器测试不能证明 LibreOffice 排版正确；一次性真实 LibreOffice 容器的结果另见[检查记录](../../docs/99-项目治理/2026-10-26-公司资料库安全稳定性检查.md)。

参考：[systemd.socket](https://www.freedesktop.org/software/systemd/man/latest/systemd.socket.html)、[systemd.exec](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html)、[OWASP 文件上传](https://cheatsheetseries.owasp.org/cheatsheets/File_Upload_Cheat_Sheet.html)。保护项必须以目标 systemd 实际运行行为验收。
