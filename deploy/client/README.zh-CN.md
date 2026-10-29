# Windows 软件包的公司服务器存储

Windows 首次下载提供可双击安装的 `Setup.exe`，安装后继续由软件自动处理 ZIP 更新包。
安装程序与后续更新包共用现有发布目录、权限校验和认证下载接口。
`packageKind=installer`、`installMode=windows_setup` 表示 Windows 安装程序，原始文件名必须以 `.exe` 结尾；
`windows_archive` 表示后续自动替换的 ZIP 更新包。历史 `windows_bundle` 完整 ZIP 仍可备份恢复，
新软件下载入口只提供 Setup.exe。当前可分发版本的元数据、安装包和更新 ZIP 必须完整对应；
旧包清理后保留审计元数据，不能把已清理的旧记录当作仍可下载的软件包。

## 多端同步与 Windows 运行时边界

每次功能修改先判断前端呈现、后端业务或共享契约，并按[统一实现与公共能力](../../docs/00-项目准则/16-统一实现与公共能力.md)
核对 Web、现有 Flutter 桌面和 Win7 C# WPF 的全部相关调用及业务链。同一业务以后不能只修一版；
保留完整迁移清单、平台必要差异、未迁移项和实际验证证据。UI 默认使用 `frontend-design` 及同源 Uten 设计资源。

Windows 产物按 `platform + runtimeFamily + architecture` 标识，包类型再区分安装程序与更新包：

| 目标 OS | `runtimeFamily` | 包合同及当前边界 |
|---|---|---|
| Windows 10/11 | `flutter` | 现有 `windows_setup` / `windows_archive`，沿用现有客户端与 SDK；只列实际受支持架构 |
| Windows 7 SP1 / Windows 8.1 | `wpf_legacy` | 独立 C# WPF / .NET Framework 4.8 候选，x86/x64；对应 `windows_wpf_setup` / `windows_wpf_archive` 合同，须逐组完成正式验收后才能分发 |

当前 WPF 尚未完成完整 ERP 迁移、Win7 真机 UAT 或正式发布，不能把源码、局部读取、本机编译或候选安装模板
写成可正式下载的完整客户端。Win7 无 SP1、Win8.0及未支持架构不得被映射到其他运行时的包。
Win7 迁移在独立分支推进，不降级、不替换原 Win10 程序及公共 Flutter SDK。

软件下载须明确 OS、运行时及架构；更新检查必须保持同一组合。普通请求与历史缺少 `runtimeFamily` 的记录
默认且仅归 `flutter`；WPF 显式选择 `wpf_legacy`，不按最高构建号或相同 `windows+x64` 互相推荐。
catalog 校验、保留清理、回滚及配套备份/恢复都遵守同一运行时边界。上线前验证实际服务器、管理员发布界面及
客户端均已支持该合同；新增源码或本文规则不代表现网已经部署。

## 首次安装与后续更新

### 现有 Flutter Windows 运行库不得依赖开发电脑

`windows/CMakeLists.txt` 在 Profile/Release 安装阶段从当前 MSVC 工具链的正式 CRT
redistributable 目录复制完整的应用本地 DLL 集合，与 `uten_imp.exe` 放在同一目录。
Windows 10+ 自带的 OS/UCRT/API-set 不从其他软件目录复制；Debug CRT 不得发布。

`package_windows.py` 是安装包与更新 ZIP 的唯一完整性及依赖检查入口：要求根目录的核心 VC
运行库，读取全部 EXE/DLL 的普通和延迟导入，检查 PE 架构及依赖闭合。开发机 System32
存在某 DLL 不能替代安装包内的文件；缺库、错误架构、Debug 依赖及不可解析依赖均阻止出包。
打包后还会独立重读 ZIP 验证，双包构建继续共享同一份已校验 payload。

历史转接依赖可能生成未使用的 `dartjni.dll`；只有源代码、AOT、NativeAssets 和 PE 引用
共同证明不使用 JNI 时，打包器才可从输出省略并记录证据，不修改原构建目录。
确实使用 JNI 的构建缺少 JVM 时必须失败，不能靠忽略依赖通过检查。

本节及下方 `build_windows_installer.py` 命令属于 `flutter` 运行时，不能直接用于 WPF EXE/DLL。
WPF 的独立构建、私有依赖、PE/CLR 架构、安装器、更新清单及恢复合同须单独验证；当前
`clients/windows_legacy/tools/build_windows_wpf.ps1` 默认只输出计划，显式构建也不等于生成或发布正式双包。

### 内网 TLS 与下载信誉

原生客户端在启动时加载、核验固定摘要的公开公司 CA，只用于批准的公司内网 HTTPS 来源。
探针、普通请求、刷新及下载使用同一原生传输入口；Web 继续使用浏览器证书验证。
员工无需额外导入证书，不修改 Windows 系统信任库，不关闭证书、主机名或账号验证。
证书错误不会伪装成网络断开后把密码转交外网。CA 轮换须审核新证书及摘要后随客户端发布。

这些检查不等于 Authenticode：当前环境没有已配置的公司代码签名证书/私钥或托管签名凭据。
Ed25519 发布摘要和 SHA-256 文件校验不能代替 Windows 发行者签名，也不能承诺消除 SmartScreen
新文件信誉提示。可信发行者签名和浏览器对内网证书的信任仍需各自完成正式配置。

`windows_installer.iss` 使用 Inno Setup 6.5+：首次安装显示目录选择页，默认当前用户目录
`{localappdata}\Programs\Uten\UIMP`，已有正式安装沿用原目录，创建桌面/开始菜单快捷方式，
包含固定更新器。安装器、快捷方式及软件外部展示名称为“UTEN”，外部图标使用既有动漫 IP；
登录页和软件内部品牌继续使用原来的平台品牌与 Logo。以后软件内的“立即更新”下载 ZIP，
在当前安装目录备份、替换并重启，不重新调用 Setup.exe 或让员工重选路径。

## 每次正式发布：Windows 安装包和更新 ZIP 一起交付

### 软件下载识别与发布中心（独立兼容分支增量）

软件下载页读取设备系统、系统版本及系统架构，再选择对应目标；Web 的浏览器提示不足以区分 Windows 10/11、SP1 或位数时，显示未确认并允许手选。目标、按钮和保存文件名包含系统范围、架构、产品版本及构建号。Windows 的 Flutter 与 WPF 家族、X86/X64/ARM64 严格隔离；非 Windows 仅在已有合同允许时提供通用包或官方商店入口，没有合法已发布版本就不提供下载。

工作台下载页的“发布与管理”和设置中的发布入口统一打开 `/settings/software-publish` 完整页面，不再打开上传弹窗。可单选或多选添加文件，逐行核对系统、客户端类型、架构、包用途、版本和构建号。Windows 首装使用 Setup.exe，更新使用 ZIP；文件名不作为版本或架构的权威证据，后端仍校验包内容。持有 `client_release:publish` 的当前身份才能进入，发布和撤回沿用再认证。

新版后端创建的 Windows 记录带 `deliveryContract=paired_v1`，只有同家族、架构、版本及构建号的安装包和更新包都通过并发布后，该组才进入软件下载、更新推荐和二进制下载。历史缺省记录保持旧行为，不读时补写或反向修改现役记录。Android 新 APK 的 `audited_v1` 使用包内版本及 ABI 校验；Apple 平台仍使用既有官方商店合同。新页面需要配套后端，不把旧后端返回当成完整配对已支持。

首次使用新交付合同前，须同步审核服务器与备份/恢复工具；已有新合同记录的 catalog 不能交给不认识 `deliveryContract` 的旧 JAR 服务。仅支持运行时隔离的旧版本仍可能忽略配对门，暴露未完整的新组；因此回滚也必须保留新合同读取/推荐/下载/清理能力，不能靠删除字段伪装历史记录。

队列保留每项原发布编号与结果。部分失败只处理未完成项；网络中断结果不明时先核对原记录，禁止换编号重复发布。发布草稿只保存原账号下的元数据与阶段，不保存文件内容、本地路径或认证材料；恢复需要时重选同一摘要文件。本分支源码与本机 fixture 证据不代表已部署、已上传正式包或 Win7 真机验收，详情见 [本轮实施记录](../../docs/99-项目治理/Win7兼容版/12-软件下载识别与独立批量发布.md)。

已有 Windows 可分发版本后，每次正式发版都要从同一份已审核源码生成 Windows `Release`，
同时交付 Setup.exe 和更新 ZIP。两份使用相同显示版本、真实构建号和精确架构；构建号必须高于
该平台、架构已发布过的构建号。不能只更新服务器/Web 或只上传其中一份就宣布完整多端交付。

正式 Windows 构建必须显式配置批准的公司与可信云端两个 HTTPS API；本地测试的 Debug/Profile、
localhost、`--local-test` 包不得混入正式输出或服务器分发目录。实际正式发行签名、安装和升级仍须
按[多端发布与签名](../../docs/99-项目治理/多端发布与签名.md)验证，不能用本地测试包的验收代替。

以下占位符须替换为本次批准的版本、构建号、端点和已验证编译器路径。`<版本号>` 不含 tag 的 `v`，
且与本次 tag、`pubspec.yaml` 一致；输出目录独立于 Flutter bundle：

```powershell
flutter build windows --release `
  --build-name='<版本号>' --build-number='<真实构建号>' `
  --dart-define='APP_VERSION=<版本号>' `
  --dart-define='API_BASE_URL=https://<公司域名>/api' `
  --dart-define='CLOUD_API_BASE_URL=https://<可信云端域名>/api'

python deploy/client/build_windows_installer.py `
  --bundle build/windows/x64/runner/Release `
  --output '<独立输出目录/UTEN-Windows-x64-Setup.exe>' `
  --update-output '<独立输出目录/UTEN-Windows-x64-update.zip>' `
  --version '<版本号>' --build-number '<真实构建号>' --architecture x64 `
  --iscc '<已验证的ISCC.exe路径>' --compile
```

无需分别构建两次应用。`--update-output` 从同一个完整 payload 快照准备两份产物，显示版本和真实
构建号都与 `uten_imp.exe` 核对。构建器仍默认为 dry-run，显式 `--compile` 才生成实际产物；
只检查计划时将 `--compile` 换为 `--dry-run`。
两份都验证完成后才替换输出，第二份落盘失败会尝试恢复旧输出；这不是跨文件或断电事务保证。

发布操作清单：

1. 列出每个已支持的平台/运行时/精确架构组合，冻结同一审核提交、产品版本、构建号和正式 HTTPS 配置；Windows 每组从同一完整应用输出构建并验证两份产物，保留摘要和构建回执。候选或未支持组合明确排除，不得冒充已交付。
2. 持有 `client_release:publish` 的人员使用已具备运行时隔离能力的发布界面分别上传安装程序和更新 ZIP，同组版本、运行时、架构、说明共用，
   发布时完成再认证。自动化调用也必须走现有授权创建、上传、发布 API，不直接向 catalog 根目录复制文件或自造元数据。
3. 核对两份均已发布，版本/构建号/运行时/架构一致；软件下载入口按 OS/运行时/架构认证下载 Setup.exe，软件更新检查只能取得同组 ZIP，并有跨运行时拒绝证据。
   每份有独立状态和重试编号，任一上传、校验或发布失败都保留上一完整组，不把部分成功当全部成功。
4. 最新完整组成功后，由客户端发布服务在 catalog 锁内按下节规则清理旧二进制；保留当前组和旧版审计元数据。
   核对最新两份下载及清理结果后才结束该平台交付。

两份实际保存在 `UTEN_CLIENT_RELEASES_DIR` 指定的私有 catalog：Setup.exe 用于首次安装，ZIP 由运行中的
客户端检查并按需下载。既有 API 会生成 `<UUID>/release.json` 和 `package.bin`，不直接从管理员电脑推送到员工设备。

现有 `.github/workflows/simple-release.yml` 主流程只自动构建和发布服务器/Web，尚未接入 Windows runner 和
Windows 双包授权上传。当前完整发布必须另外完成上述 Windows 构建与发布清单；该 workflow 成功本身只代表
服务器/Web 发布，不能记为 Windows 已发布或全部平台完成。

构建器共用完整包清单验证，只向 ISCC 提供一份经过校验的 payload；不会把完整 ZIP 再附加到 EXE。
它校验输出 PE 和版本资源、整包摘要，不能据此声称已校验 Authenticode 发行签名或实际向导安装。

本地测试包连接本地测试后端；服务器分发包固定公司及可信远程入口，两者分开命名和存放。
不能将本地 localhost 包上传为正式版本，正式包完成对应验收后再分发。应用内更新包仍由
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
旧包清理仍保留审计记录，因此这些记录继续计入 200 条上限；达到记录上限时须受控归档，不能靠删除发布历史解除构建号约束。
这些是容量保护，不是独立文件系统配额；软件包与业务原件仍可能共用一个卷。
容量不足时先扩容或受控归档，不能减少业务原件、历史单据，或在新组完整发布前抢先删除上一组客户端包来腾空间。
现有 `server.env` 的值优先于单位默认值，升级时需要核对并合并这两个配置项；不能覆盖现有密钥和其他并行配置。

普通存储清理把整个当前上传根当作受保护数据，不允许选择删除 `client-releases`。
服务端代码版本清理仍只处理自己的代码版本和暂存区，不扫描该目录。

## 分发包保留：Windows 每个运行时与精确架构只保留最新完整组

Windows 同一运行时、同一精确架构的 Setup.exe 与更新 ZIP 均已完整验证并成功发布，且版本、构建号一致后，
客户端发布服务才在 `.catalog.lock` 内清理该平台、该运行时、该精确架构的低构建号旧二进制，包含旧安装包和更新 ZIP。
新组只成功一份、存在校验错误或发布失败时不清理旧组；合同支持的 `x86`、`x64`、`arm64` 等精确架构分开处理，
不以架构兼容关系跨组删除。`flutter` 与 `wpf_legacy` 即使架构相同也完全分组；绝不因一组构建号更高而删除另一运行时。
其他运行时、平台和架构、正在上传的草稿、业务附件、数据库备份及服务端回滚版本均不受影响。

“只保留最新”指在线分发二进制：旧记录以 `WITHDRAWN` 保留，已清理记录的 `sha256=null`、`sizeBytes=0`，
原发布编号、构建号、发布时间等审计信息继续保留，旧记录不再提供下载。不能递归删除整个 catalog、
删除锁文件、把保留策略变成全盘搜索，或通过删掉历史构建号记录允许旧版本重新发布。
备份仍按原备份政策保留，客户端包清理不会删除已有备份中的历史字节。
撤回当前版本不会自动恢复已清理的旧二进制；需要重新分发时，按递增构建号发布完整修复版本。
客户端更新失败的恢复只使用同运行时/架构的安装快照；不得以另一运行时的较低版本替代原安装或其本机状态。

该规则替代 2026-10-26 初版文档中“发布撤回不删除历史二进制”的保留规则；
代码和本地回归不代表已有服务器已升级，现场仍须部署相应服务版本并核对发布、清理与下载结果。

## 配套备份、恢复与旧部署

保持原位置无需迁移。配套备份默认读取 `media_root/client-releases`，与上述显式路径相同；
启用历史 local 存储时也会覆盖 `local_media_root/client-releases`。原有配置中的 `client_releases_root=null`
可以继续使用，不能仅因为模板显式写出同一默认路径就忽略备份默认范围。

Windows Setup.exe、历史完整 ZIP 和更新包的混合目录通过现有 POSIX record lock，与 Java `FileChannel.lock()` 互斥地导出。
备份保存 `release.json`、仍保留的包字节及清单，核对 UUID、`runtimeFamily`、精确架构、类型/模式、大小、SHA-256 和父备份集绑定；
已清理的 `WITHDRAWN` 审计记录按 `sha256=null`、`sizeBytes=0` 导出和恢复，不要求重新生成已删除的二进制。
完整恢复只写入新的空目录，重建空锁，保留已上传草稿、已发布及已撤回记录。旧更新元数据继续兼容。
历史缺省运行时只恢复为 `flutter`，不得将其包或记录重新归为 WPF；配套备份和恢复校验须认识
`wpf_legacy` 及其两种包模式，未知运行时/模式明确失败，不能静默跳过。上线前验证混合 catalog 中两运行时的
字节、元数据、恢复下载与保留清理均互不覆盖；原有历史备份与验证记录保留其原始范围。
详细步骤见[配套备份手册](../postgres/backup/PAIRED_INTERNAL_BACKUP.zh-CN.md#客户端发布目录配套备份v2528)。
隔离恢复使用尚未创建 catalog 的新媒体目录；不要先用准备器放入锁文件再要求恢复工具覆盖它。
恢复完成后可运行准备器核对已有空锁和权限，不修改已恢复的元数据或包。

如已有部署显式使用另一 catalog 路径，先核对其实际元数据和包，再保留该路径或安排受控迁移。
同时调整应用 `UTEN_CLIENT_RELEASES_DIR`、备份 `client_releases_root`、实际服务沙箱写权限和备份只读权限；
不能直接套用示例路径启动一个空目录。旧包和原备份在新路径完整恢复及下载验证前保留。

## 上线组件顺序与验证记录

以下组件顺序来自 2026-10-26 的存储准备和隔离验证记录。该记录未在服务器执行，也未生成或上传正式客户端包；
后续本地测试安装包的生成不改变这项正式部署验收结论。每次正式上线仍须执行并记录对应的部署与验收。

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
