# Windows 软件包的公司服务器存储

Windows 首次下载提供可双击安装的 `Setup.exe`，安装后继续由软件自动处理 ZIP 更新包。
安装程序与后续更新包共用现有发布目录、权限校验和认证下载接口。
`packageKind=installer`、`installMode=windows_setup` 表示 Windows 安装程序，原始文件名必须以 `.exe` 结尾；
`windows_archive` 表示后续自动替换的 ZIP 更新包。历史 `windows_bundle` 完整 ZIP 仍可备份恢复，
新软件下载入口只提供 Setup.exe。各类元数据和实际包必须一起保留。

## 首次安装与后续更新

`windows_installer.iss` 使用 Inno Setup 6.5+：当前用户权限安装到
`{localappdata}\Programs\Uten\UIMP`，沿用已有安装目录，创建桌面/开始菜单快捷方式，
包含固定更新器。中文安装语言显示“优腾综合管理平台(UIMP)”，其他提供的安装语言显示
“Uten Integrated Management Platform (UIMP)”。以后软件内的“立即更新”下载 ZIP，
在当前安装目录备份、替换并重启，不重新调用 Setup.exe 或让员工重选路径。

正式生成须等待用户明确下令。本次仅提交源码、dry-run 和合成 fixture 测试；本机尚未发现 ISCC，
没有安装工具或生成实际 ERP 包。后续选择并验证当前环境的完整 Flutter Release 输出后，可使用：

```powershell
python deploy/client/build_windows_installer.py --bundle <当前环境的Release目录> --output <独立输出目录/UIMP-Setup.exe> --version <显示版本> --build-number <真实构建号> --architecture x64 --dry-run
```

通常发布一版需要 Setup.exe 与更新 ZIP 两种用途，但无需分别构建应用。增加
`--update-output <独立输出目录/UIMP-update.zip>`，构建器从同一个完整 payload 快照准备两份产物，
显示版本和真实构建号都与 `uten_imp.exe` 核对。仍默认为 dry-run，明确 `--compile` 后才保存正式产物。
两份都验证完成后才替换输出，第二份落盘失败会尝试恢复旧输出；这不是跨文件或断电事务保证。

发布界面为安装程序和更新 ZIP 分别提供上传发布区，版本、架构、说明只填写一次。
两份都保存在上文私有 catalog：Setup.exe 用于软件下载首次安装，ZIP 由运行中的客户端检查并按需下载，
不直接从管理员电脑向员工设备推送。每份有自己的发布状态与重试编号，不能把部分成功当成全部发布成功。

只有明确要求生成时才增加 `--compile`，并通过 `--iscc` 指定批准的已有编译器（或由已安装路径发现）。
构建器共用完整包清单验证，只向 ISCC 提供一份经过校验的 payload；不会把完整 ZIP 再附加到 EXE。
它校验输出 PE 和版本资源、整包摘要，不能据此声称已校验 Authenticode 发行签名或实际向导安装。

本地测试包连接本地测试后端；服务器分发包固定公司及可信远程入口，两者分开命名和存放。
不能将本地 localhost 包上传为正式版本，用户实测确认前不上传。应用内更新包仍由
`package_windows.py` 默认 update 模式产生；其 ZIP 不能作为首次安装程序提供下载。

技术依据：[Inno Setup 目录](https://jrsoftware.org/ishelp/topic_setup_defaultdirname.htm)、
[当前用户安装权限](https://jrsoftware.org/ishelp/topic_setup_privilegesrequired.htm)、
[沿用安装目录](https://jrsoftware.org/ishelp/topic_setup_usepreviousappdir.htm)、
[官方版本资源写入实现](https://github.com/jrsoftware/issrc/blob/main/Projects/Src/Compiler.ExeUpdateFunc.pas#L621-L629)。

## 持久目录与写入边界

| 部署 | `UTEN_CLIENT_RELEASES_DIR` | 既有 systemd 写边界 |
|---|---|---|
| Simple、正式内部存储、正式服务模板 | `/var/lib/uten-imp-media/attachments/client-releases` | `/var/lib/uten-imp-media/attachments` |
| 封闭 internal-test | `/data/uten-imp/attachments/client-releases` | `/data/uten-imp/attachments` |

`client-releases` 是私有媒体卷中的独立命名空间，与 `final`、`staging`、`preview` 等业务文件目录分开。
它位于应用的 `current`、`releases/<version>` 和静态 `web` 根之外，应用发版和旧代码版本清理不会替换它。
没有新增媒体卷之外的写权限。云端远程通道只转发认证请求，不建立第二份软件包目录。
`deploy/cloud/uten-imp-cloud.service.example` 已明确退役，不能为软件下载重新启用该历史业务实例。

程序以 `uten-imp` 账号在首次访问目录时创建 catalog 和 `.catalog.lock`，服从现有私有 umask。
可在已批准的媒体卷挂载完成后，用经过审核的本地准备器提前建立 0700 目录和 0600 空锁文件：

```bash
sudo python3 -I /reviewed/deploy/client/prepare_client_release_storage.py --profile internal
```

internal-test 使用 `--profile internal-test`。脚本要求 Linux root、既有媒体父目录、正确挂载和至少 10 GiB
可用空间，将新目录及锁交给既有 `uten-imp` 账号；不创建账号、不移动包、不发布、不连接网络。
重复执行不修改历史目录内容；遇到链接、其他账号拥有的目录、额外写权限或繁忙锁会拒绝，禁止用递归 `chown`
或删除目录来“修好”它。目录准备后仍须在应用运行账号、实际沙箱和认证下载链路验证读写。

## 空间保护

部署模板显式设置 `UTEN_CLIENT_UPDATE_MIN_FREE_BYTES=10737418240`，即上传后至少保留 10 GiB，
与私有原件卷默认保留空间一致。应用已有单包 512 MiB、目录 200 条记录以及流式上传过程的磁盘余量检查。
这些是容量保护，不是独立文件系统配额；软件包与业务原件仍可能共用一个卷。
不要把低余量错误通过减少业务原件、历史单据或自动删除已发布包来掩盖。容量不足时先扩容或受控归档。
现有 `server.env` 的值优先于单位默认值，升级时需要核对并合并这两个配置项；不能覆盖现有密钥和其他并行配置。

普通存储清理把整个当前上传根当作受保护数据，不允许选择删除 `client-releases`。
发版清理只作用于自己的代码版本和暂存区，不扫描该目录。发布撤回改变可分发状态，不删除历史二进制。

## 配套备份、恢复与旧部署

保持原位置无需迁移。配套备份默认读取 `media_root/client-releases`，与上述显式路径相同；
启用历史 local 存储时也会覆盖 `local_media_root/client-releases`。原有配置中的 `client_releases_root=null`
可以继续使用，不能仅因为模板显式写出同一默认路径就忽略备份默认范围。

Windows Setup.exe、历史完整 ZIP 和更新包的混合目录通过现有 POSIX record lock，与 Java `FileChannel.lock()` 互斥地导出。
备份同时保存 `release.json`、包字节及清单，核对 UUID、类型/模式、大小、SHA-256 和父备份集绑定；
完整恢复只写入新的空目录，重建空锁，保留已上传草稿、已发布及已撤回记录。旧更新元数据继续兼容。
详细步骤见[配套备份手册](../postgres/backup/PAIRED_INTERNAL_BACKUP.zh-CN.md#客户端发布目录配套备份v2528)。
隔离恢复使用尚未创建 catalog 的新媒体目录；不要先用准备器放入锁文件再要求恢复工具覆盖它。
恢复完成后可运行准备器核对已有空锁和权限，不修改已恢复的元数据或包。

如已有部署显式使用另一 catalog 路径，先核对其实际元数据和包，再保留该路径或安排受控迁移。
同时调整应用 `UTEN_CLIENT_RELEASES_DIR`、备份 `client_releases_root`、实际服务沙箱写权限和备份只读权限；
不能直接套用示例路径启动一个空目录。旧包和原备份在新路径完整恢复及下载验证前保留。

## 上线组件顺序与验证记录

这组步骤属于后续受控部署，本次没有在服务器执行，也没有生成或上传正式客户端包。

1. 冻结同一份已审核源码，保留当前成功备份及已安装组件摘要。暂停新发布写入，等正在执行的配套备份和更新作业完成。
2. 在上线 `windows_setup` 发布能力前，同步安装 `paired_internal_backup.py`、`market_state_backup.py`、
   `client_release_state_backup.py` 三件套。旧客户端备份 helper 不识别新模式，会拒绝备份，不能把这种失败当作“本次没有包”。
3. 现役 Simple 安装可使用下列已有受控安装器；它持有更新、运维及配套备份锁，先写依赖模块再切换入口，
   同时更新运维助手，因此整套源目录与安装效果都要纳入该次审核。不要只把一个 helper 原位覆盖到正在运行的作业下面。

   ```bash
   sudo bash /reviewed/deploy/simple/install-server-operations.sh /reviewed/deploy/simple
   ```

4. 核对实际 `server.env` 和单位的 catalog 路径、10 GiB 余量、运行账号及父目录写边界。
   internal-test 的封闭环境校验器需与本次单位/env 模板同步安装；签名安装和开机校验沿用其现有冻结摘要及受控安装流程，
   不能沿用旧 hash 证明新组件已部署。
5. 在隔离 Linux fixture 环境运行混合目录导出/恢复回归，确认旧更新元数据、历史完整 ZIP、Setup.exe、已撤回记录及原始字节都能核验。
   正式 helper 安装后，按配套备份手册手动产生一次新成功集合，记录其中 `client_release_state` 的目录、包数量、字节数及清单摘要。
6. 核验该成功集合并恢复到隔离的空媒体目录，比较元数据和包摘要，再确认员工认证下载可用。
   记录源代码提交、安装组件摘要、配置路径、备份集 ID、恢复和下载结果。没有这些回执前，状态保持“待部署/待实际验收”。

本地验证记录见 `build/software-downloads-20261026/storage-evidence.json`。
本次使用断网 Linux 容器检查目录权限、防链接、磁盘余量、跨进程 record lock、混合 catalog 冷恢复、普通清理保护和五套真实 Nginx。
缓存容器中缺少 Linux JDK，既有 Java 源文件互锁测试保留跳过；Python 跨进程互锁通过，不能把它写成 Java 实测通过。

## 下载与代理

Setup.exe 安装程序继续通过 `/api/client-updates/{id}/download` 认证流式下载，上传继续使用
`/api/admin/client-releases/{id}/package`，无需新增任意文件下载路径或静态目录映射。
五套现有 Nginx 模板已有该上传路径的 512 MiB 限额及下载不缓存配置；普通请求体额度维持原值。
验证脚本 `nginx_client_updates_integration.py` 只在隔离容器里运行真实 Nginx 和 fixture 后端，
不连接 OSS、不上传真实客户端包、不等同生产部署验收。
