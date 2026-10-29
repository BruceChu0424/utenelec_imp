# client_update：业务页面来源

候选/静态线索必须人工核对；完整JSON证据保留在business-inventory.json。

## W7-BIZ-039 · lib/features/client_update/client_update_page.dart

模块 `client_update`；537 行；SHA256 `4c92bd51e4b3d3d22e0f6c4a76f6e6297e35e9e5ebcc314fa11cc8ead73e25b4`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | ClientUpdatePage @34 (page-class)<br>_ClientUpdatePageState @41 (state-class)<br>_UpdateMark @389 (supporting-class)<br>_UpdateMarkState @406 (state-class)<br>_UpdateRing @507 (supporting-class) |
| 真实路由绑定 | 未静态确认；不能当作不存在 |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | 未静态确认；不能当作不存在 |
| 动作处理 | openClientUpdatePage @12 [method-declaration-candidate] 提示 ['update']；Future<void> openClientUpdatePage(<br>ClientUpdatePage @19 [action-like-invocation] 提示 ['update']；builder: (_) => ClientUpdatePage(controller: controller),<br>removeRoute @22 [action-like-invocation] 提示 ['remove']；if (route.isActive) navigator.removeRoute(route);<br>removeOwnerDisposedListener @29 [action-like-invocation] 提示 ['remove']；controller.removeOwnerDisposedListener(ownerChanged);<br>ClientUpdatePage @35 [action-like-invocation] 提示 ['update']；const ClientUpdatePage({super.key, required this.controller});<br>_ClientUpdatePageState @38 [action-like-invocation] 提示 ['update']；State<ClientUpdatePage> createState() => _ClientUpdatePageState();<br>addPostFrameCallback @60 [action-like-invocation] 提示 ['post']；WidgetsBinding.instance.addPostFrameCallback((_) async {<br>_UpdateMark @197 [action-like-invocation] 提示 ['update']；builder: (context, duration) => _UpdateMark(<br>copyWith @222 [action-like-invocation] 提示 ['copy']；?.copyWith(fontWeight: FontWeight.w800),<br>copyWith @233 [action-like-invocation] 提示 ['copy']；?.copyWith(fontWeight: FontWeight.w700),<br>copyWith @240 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodyMedium?.copyWith(<br>copyWith @248 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.titleLarge?.copyWith(<br>copyWith @269 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodyMedium?.copyWith(<br>copyWith @338 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>copyWith @359 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.titleMedium?.copyWith(<br>copyWith @368 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodyMedium?.copyWith(<br>_UpdateMark @390 [action-like-invocation] 提示 ['update']；const _UpdateMark({<br>_UpdateMarkState @403 [action-like-invocation] 提示 ['update']；State<_UpdateMark> createState() => _UpdateMarkState();<br>stop @426 [action-like-invocation] 提示 ['stop']；_rotation.stop();<br>_UpdateRing @458 [action-like-invocation] 提示 ['update']；painter: _UpdateRing(<br>_UpdateRing @508 [action-like-invocation] 提示 ['update']；const _UpdateRing({ |
| 控制器候选（人工核实） | 未静态确认；不能当作不存在 |
| 审计限制 | 未找到直接路由builder构造；可能由动态factory、共享页面或内部导航进入，需核实。<br>存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/buttons/uten_back_button.dart` (sharedComponents)；`lib/components/buttons/uten_button.dart` (sharedComponents)；`lib/components/feedback/uten_motion.dart` (sharedComponents)；`lib/core/constants/app_info.dart` (core)；`lib/core/l10n/gen/app_localizations.dart` (core)；`lib/core/theme/uten_anim.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/features/client_update/client_update_controller.dart` (other)。

## W7-BIZ-040 · lib/features/client_update/software_downloads_page.dart

模块 `client_update`；873 行；SHA256 `891b223e3f7a433974556cf0300147895315d6355eeb1ada208affb280258e60`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | SoftwareDownloadsPage @22 (page-class)<br>_DownloadsState @29 (state-class)<br>_CurrentUnavailablePlatform @227 (supporting-class)<br>_WindowsPanel @274 (supporting-class)<br>_DownloadStatus @547 (supporting-class)<br>_DesktopArtwork @636 (supporting-class)<br>_InstallationGuide @707 (supporting-class)<br>_OtherPlatforms @789 (supporting-class) |
| 真实路由绑定 | /software-downloads；router @556；builder ['SoftwareDownloadsPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | 未静态确认；不能当作不存在 |
| 动作处理 | _download @40 [method-declaration-candidate] 提示 ['download']；Future<void> _download(<br>download @48 [action-like-invocation] 提示 ['download']；await controller.download(release);<br>_download @95 [action-like-invocation] 提示 ['download']；await _download(controller, release);<br>addPostFrameCallback @103 [action-like-invocation] 提示 ['post']；WidgetsBinding.instance.addPostFrameCallback((_) {<br>addPostFrameCallback @131 [action-like-invocation] 提示 ['post']；WidgetsBinding.instance.addPostFrameCallback((_) {<br>windowsDownloadArchitectures @186 [action-like-invocation] 提示 ['download']；if (!windowsDownloadArchitectures(<br>_download @193 [action-like-invocation] 提示 ['download']；unawaited(_download(controller, release)),<br>copyWith @255 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>copyWith @325 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>copyWith @335 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.headlineLarge?.copyWith(<br>copyWith @344 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodyLarge?.copyWith(<br>windowsDownloadArchitectures @407 [action-like-invocation] 提示 ['download']；for (final target in windowsDownloadArchitectures(<br>onDownload @456 [action-like-invocation] 提示 ['download']；onPressed: downloading ? null : () => onDownload(release!),<br>_DownloadStatus @495 [action-like-invocation] 提示 ['download']；_DownloadStatus(controller: controller),<br>copyWith @507 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>copyWith @517 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodyMedium?.copyWith(height: 1.7),<br>_DownloadStatus @548 [action-like-invocation] 提示 ['download']；const _DownloadStatus({required this.controller});<br>copyWith @589 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodyMedium?.copyWith(<br>copyWith @602 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodyMedium?.copyWith(<br>copyWith @675 [action-like-invocation] 提示 ['copy']；?.copyWith(<br>copyWith @683 [action-like-invocation] 提示 ['copy']；style: Theme.of(context).textTheme.bodyMedium?.copyWith(<br>copyWith @763 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith( |
| 控制器候选（人工核实） | 未静态确认；不能当作不存在 |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/buttons/uten_button.dart` (sharedComponents)；`lib/components/inputs/uten_dropdown_scroll_scope.dart` (sharedComponents)；`lib/components/feedback/uten_motion.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/theme/uten_anim.dart` (core)；`lib/core/ui/uten_notify.dart` (core)；`lib/core/ui/opportunistic_dialog_coordinator.dart` (core)；`lib/features/client_update/client_release.dart` (other)；`lib/features/client_update/client_release_access.dart` (other)；`lib/features/client_update/client_release_publish_dialog.dart` (other)；`lib/features/client_update/software_downloads_controller.dart` (other)；`lib/features/client_update/software_downloads_presentation.dart` (other)。
