# Win10 以下客户端兼容适配：独立验证阶段

> 2026-10-28 后续决定：用户明确选择原生 C# + WPF。现役实现与持续迁移状态见 [Win7 WPF 客户端](../../../clients/windows_legacy/README.zh-CN.md)。本文件保留前期审查证据；下文的 Web 外壳候选已被排除，相应实验安装/规划代码已清理，不属于当前交付路线。所有成果仍留在独立分支，不合并 `main`。

用户目标是同一安装入口自动判断系统：Win7/Win8/Win8.1 使用兼容运行层，Win10 及以上继续使用现有原生版本。UI、业务流程、权限、数量计算、提交与恢复规则沿用现有公共实现；不降级 Flutter、Dart、依赖、Java 或数据库来迁就旧系统。

**当前只有自动选择策略、独立验证安装模板和输入检查工具，没有已经验收的 Win7 客户端。** Web 外壳是可行性候选，源码审查已发现平台差异，尚未满足原生功能等价。不能把安装时的条件判断、摘要检查或单元测试当作兼容完成。

## 隔离范围

- 分支：`uimp/legacy-windows-auto-detect-20261028`。
- 基线：`46d4afb68e599148a8dc254417eff32e383ed550`，应用版本 `2.5.34+2534`。这是独立分支的已提交基线；原主工作区还有 `2.5.35+2535` 等并行未提交改动，未复制、覆盖或回退那些改动。此基线不是新的发布版本。
- 本阶段只新增本目录文件，不修改 `lib/`、`server/`、`windows/`、`pubspec.yaml`、`pubspec.lock`、CI、既有安装器或更新器。
- 没有在公司服务端、数据库或员工电脑执行安装、迁移、业务请求、发布或旧包清理；没有生成分发用 Setup.exe/更新 ZIP。
- 验证安装器使用独立 AppId、安装目录、快捷方式和浏览器 profile，不注册默认浏览器、不导入系统根证书、不关闭 TLS 或沙箱。
- **检测到 Win10 x64 时，当前验证安装器在 `InitializeSetup` 阶段直接停止，不安装或启动第二份原生客户端。** Flutter 默认凭据、偏好和应用支持目录可能按产品身份共享；只换安装目录与 AppId 不足以隔离。最终统一安装入口对现有原生安装器的委派须另行验证，不能提前打开此路径。

## 当前前后端到底能否在 Win7 运行

### 原生 Flutter：现有二进制不能直接运行

`pubspec.yaml` 要求 Dart `^3.12.2`；本机 SDK 是 Flutter **3.44.2** / Dart **3.12.2**，引擎 revision 为 `77e2e94772b6eb43759e34ed1ad7da4674e19cab`。未更换或降级该 SDK。

| 实际拥有入口 | 已核事实 | 影响 |
|---|---|---|
| SDK `windows-x64-release/flutter_windows.dll` | 只读导入表中有 `GetCurrentThreadStackLimits`，微软最低要求 Win8 | Win7 会在引擎加载阶段遇到缺失 API，Dart 内部的 `if` 尚未执行 |
| `windows/runner/win32_window.cpp` | 直接调用 `GetDpiForWindow`，微软最低要求 Win10 1607 | Win7、Win8、Win8.1 都不能原样使用当前 runner |
| `windows/CMakeLists.txt` | 依赖 Win10 自带 UCRT/API-set，不附带 UCRT | 当前 MSVC DLL 集合不是 Win7 干净系统可运行的证明 |
| `windows/runner/client_updater.ps1` | 使用 PowerShell 5.1/.NET 对应能力 | Win7 原装 PowerShell 不能原样执行现有更新器 |
| `pdfrx 1.3.5` 的 Windows CMake | 目前实现强制 `CPU_NAME=x64` | 当前依赖不能作为原生 x86 PDF 支持依据 |
| `deploy/client/windows_installer.iss` | `MinVersion=10.0` | 降低安装限制无法修复上述二进制依赖，保留既有规则 |

参考：[Flutter 支持矩阵](https://docs.flutter.dev/reference/supported-platforms)、[GetCurrentThreadStackLimits](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getcurrentthreadstacklimits)、[GetDpiForWindow](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getdpiforwindow)。

保留当前 Dart/UI 代码的原生路线，需要与 **当前 Flutter/Dart 版本精确匹配** 的旧 Windows 引擎、runner、插件和更新器。RustDesk 的旧 Windows 引擎使用 3.24 系列，不能把旧 DLL 直接替换进 3.44 构建。此项尚未实现或编译，不能称为已选定的交付底层。

### Web 运行层：可以研究复用，已有明确差异

候选为有 Win7/8.x x86/x64 支持声明的 [Supermium](https://github.com/win32ss/supermium)，用私有 runtime 和 `--app=<公司 HTTPS Web 入口>` 打开现有 Flutter Web。不会改变 `kIsWeb`，也不会自动获得原生 MethodChannel。浏览器模式不是业务逻辑的一套新实现；若无法保全必要桌面能力，不能按“效果一致”验收。

| 链路 | 源码证据及必须处理的差异 |
|---|---|
| 登录、窗口与布局 | `lib/core/platform/desktop_window.dart` 在 Web 禁用窗口通道；`login_page.dart` 的 `DesktopLoginLayout` 只用于原生。独立浏览器窗口不会自动选择同样的登录布局 |
| 服务器选择与证书 | `api_base_url.dart` 强制 Web Release 同源 `/api`；`server_selection.dart` 停用原生 LAN/cloud 探测。`company_tls.dart` 的 Web 路径不会加载应用内置公司 CA，必须在正常浏览器信任链下验证 HTTPS |
| 登录会话与安全存储 | 原生是 Windows Credential Manager/本机偏好；Web 使用 WebCrypto、localStorage/sessionStorage，窗口关闭、多窗口和 refresh 竞争语义需要测试。不能共享员工日常浏览器 profile |
| 文件选择、拖放 | 已有 Web 实现，但无原生文件系统路径；`file_picker` Web 可把内容读取进内存，需测低内存 x86、多附件、中文文件名、取消和切换账号 |
| 导出与大文件 | `file_saver_web.dart` 使用 Blob/下载请求，流式保存还需 HTTPS、OPFS、quota 与 writable stream。`uten_export_button.dart` 在没有流式保存能力时拒绝超过 32 MiB，不能靠外壳消除限制 |
| PDF 与打印 | Web 使用 PDFium WASM/Blob worker、iframe print，涉及 CSP、同源资源、字体、打印机与取消行为；调用 print 不等于纸张实际打印成功 |
| 自动更新 | `client_update_tile.dart` 隐藏 Web 更新，controller/host 跳过原生更新，下载 stub 拒绝原生安装。兼容运行时本体尚无已接通的更新链 |
| 审计与扫码 | Web 审计记录 `platform=web`，部分系统字段为空；`security_scan_page.dart` Web 只有手工输入，没有原生摄像头扫码 |
| 渲染与响应性 | 当前 JS Web 构建仍通过 CanvasKit 使用 WASM/WebGL，另有 JSON/data codec/PDF worker。老显卡能否稳定运行须实测；不默认关闭沙箱或开启 unsafe SwiftShader |

`desktop_drop`、device info、secure storage、file picker、path provider、shared preferences、URL launcher、printing、pdfrx、JNI 等 Windows 插件及 Dart FFI 边界均已静态核对。现有依赖和业务接口没有为本阶段改写。

### 后端继续运行在公司服务器

员工 Win7 电脑只运行客户端，不需要在电脑上安装 Java、PostgreSQL 或 Docker。现有 `server/pom.xml` 是 Spring Boot 4.1.1/Java 21，正式部署为 Ubuntu 24.04/OpenJDK 21/PG16；这些继续留在服务器。

若要求 Win7 **本机** 同时运行完整后端，现有受支持部署不成立：PostgreSQL 16 要求 Win10+，当前 JDK21 认证平台和 Docker Desktop 要求也不含 Win7。本适配不通过降级这些组件改变业务运行环境。

已核对登录、刷新、Bearer 认证和设备审计入口，没有发现业务接口按客户端 Win7 版本拒绝访问的规则。客户端仍须保持原有授权、精度、幂等、提交结果未知时的处理、证书校验与恢复语义。

参考：[PostgreSQL 16 发布说明](https://www.postgresql.org/docs/16/release-16.html)、[JDK21 认证平台](https://www.oracle.com/java/technologies/javase/products-doc-jdk21certconfig.html)、[Docker Desktop 要求](https://docs.docker.com/desktop/setup/install/windows-install/)。

## 新增代码及状态

| 文件 | 职责与边界 |
|---|---|
| `runtime_policy.py` | 唯一系统/架构决策表，同时供 Python 检查和生成 Pascal 使用，避免两份规则漂移 |
| `windows_auto_installer.iss` | 独立验证模板，安装前缓存系统探测结果，只安装选中的 legacy runtime，Win10 分支无安装和启动副作用 |
| `prepare_auto_installer.py` | 检查已审核运行时目录的完整摘要、架构、版本、许可清单和正式 HTTPS 入口；复用现有原生依赖校验，只生成 source plan/ISS 输入，不调用编译器或发布接口 |
| `test_runtime_policy.py`、`test_prepare_auto_installer.py` | 系统/架构互斥、输入校验、错包、篡改、缺运行库、私有资料混入、源计划输出和 Win10 不启动第二原生客户端的不变式 |

系统规则：

| 检测结果 | 策略 | 当前验证程序行为 |
|---|---|---|
| Win7 SP1 x86/x64 | `legacy-x86` / `legacy-x64` | 待真实兼容 runtime 和机器验收 |
| Win7 未装 SP1 | 前置条件未满足 | 显示 SP1 要求并停止。SP1 是本项目当前验证基线，不是 Supermium 官方硬性要求；未覆盖此配置，不能声称“所有 Win7”已支持 |
| Win8/8.1 x86/x64 | `legacy-x86` / `legacy-x64` | 待真实机器验收 |
| Win10+ x64 | `native-x64` | 当前 pilot 退出，继续使用现有客户端；最终原生安装委派待实现 |
| Win10 x86、ARM64、Vista/XP、未知版本 | 不自动猜测 | 明确停止，避免投放不能运行的包 |

### 输入检查工具

只对本地已审查的干净运行时目录计算摘要；不下载或运行 EXE。`inventory` 的输出不构成人工审核批准。

```powershell
python deploy/client/legacy_windows/prepare_auto_installer.py inventory '<运行时目录>'
python deploy/client/legacy_windows/prepare_auto_installer.py plan `
  --review '<已审核的review.json>' `
  --company-web-url 'https://<批准的公司Web域名>/' `
  --source-output '<新的独立源计划目录>'
```

review 格式为 `schemaVersion=1`、`applicationVersion`、`applicationBuild`、40 位 `sourceCommit` 和 `runtimes`。`runtimes` 精确包含 `legacy-x86`、`legacy-x64`、`native-x64` 三个独立目录，各项提供 `directory` 及相对路径到 SHA-256 的 `files`。legacy 还需 `vendor=Supermium`、准确 `runtimeVersion`、`sourceUrl` 和 `licenseFiles`。native 仅作为现有版本的静态核对参考，不嵌入或运行。

检查结果永远标记 `releaseReady=false`。生成的 ISS **引用原始目录，不是冻结快照**；未来目录可能变化。不能直接用该 source plan 宣称审核字节与出包字节相同。正式构建须复用既有私有快照、编译前重验、版本/源码绑定及完整产物校验，再执行经过授权的双包交付。

现有客户端 catalog 只区分 platform/architecture/build，并强制原生 Flutter 文件集；另一份 `windows+x64` 兼容包会与现有包发生推荐及旧包清理冲突。当前代码没有接入这个通道；后续须先完善 runtime/OS 区分和配套备份恢复，不能直接发布。

## 验证与剩余工作

2026-10-28 已执行：

- 新增策略及输入校验：24 项测试通过，全部使用临时合成 PE fixture，不构成 Win7 runtime 验收。
- 既有 Win10 安装器回归：31 项通过、1 项实际 ISCC 编译测试按既有条件跳过；未调用真实安装编译器。
- 在独立工作树用当前 SDK、固定 `pubspec.lock` 执行离线依赖解析；命令级改用锁文件的 `https://pub.dev` 源后成功，没有更改锁文件或全局环境。没有降低 SDK 或依赖版本。
- 当前 Flutter 3.44.2/Dart 3.12.2 的 JS Web Release 编译成功，输出仅在独立工作树 `build/legacy-windows-web-compile`，未部署。执行命令为 `flutter build web --release --no-pub --no-web-resources-cdn --output build/legacy-windows-web-compile`，耗时约 224 秒。
- 同一次构建的 Wasm dry run 指出现有 `flutter_secure_storage_web 1.2.1` 使用 `dart:html`/`dart:js_util`，不兼容纯 Dart Wasm 目标；当前实际 JS 构建成功。未通过关闭存储/认证、降级依赖或掩盖警告来通过构建。CanvasKit/PDF 自身的 WASM 资源与纯 Dart Wasm 目标是不同层次。
- 新模板尚未经过真实 Inno 编译或向导安装，Win7/Win8.x 真机运行也没有验收。Web 编译成功只证明该源码能生成 Web 产物，不证明目标电脑的显卡、浏览器、证书或业务链路运行成功。

后续先确定满足原生行为合同的运行层，再验证：正常 HTTPS→登录/MFA→采购、委外、生产、仓库、财务测试业务链→附件→XLSX/PDF/ZIP 导出→打印→退出重启→更新。覆盖 Win7 x86/x64、Win8/8.1、中文输入、100/125/150% DPI、老显卡/低内存、断网与权限撤销，保存真实版本和证据。Win10 原生安装、凭据、快捷方式和更新通道须独立对照回归。

回归命令：

```powershell
python -B -m unittest discover -s deploy/client/legacy_windows -p 'test_*.py' -v
python -B -m unittest discover -s deploy/client -p test_build_windows_installer.py -v
```

UI 与交互适配继续使用 `frontend-design`，复用项目 Uten 组件和主题；本阶段未迁移 UI 调用方、未删除业务实现，也不宣称业务全链路已通过旧系统验收。
