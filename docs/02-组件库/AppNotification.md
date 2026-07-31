# AppNotification（顶部通知服务）

> **本项目自建组件**。
> 不是 Material 的 SnackBar，也不是 `lib/components/feedback/uten_toast.dart` 的 UtenToast。
> 顶部渲染（status bar 下方滑入），按 `success/error/warning/info` 四级配色，
> 队列上限 3 条 + 600ms 同 message 合并去重，专治"先成功再失败"的双 SnackBar 抖动。

> ⚠️ **调用入口已收敛**：新代码请走统一门面 **[UtenNotify](UtenNotify.md)**
> （`UtenNotify.banner/success/error/...`，顶部弹条 + 居中弹窗双通道）。
> 本文档描述底层服务行为；`context.appSuccess/Error/...` 扩展保持兼容可用。

---

## 一、用途

- 统一替代全平台所有 `ScaffoldMessenger.showSnackBar(...)` 调用。
- 解决底部 SnackBar 不显眼、跨页面 pop 后消息丢失、连续触发时队列叠加等问题。
- API 错误自动展示后端 `fieldErrors`，比裸 message 信息密度更高。

## 二、何时用 / 何时不用

| 场景 | 用什么 |
|---|---|
| 表单/操作反馈（成功、失败、警告） | **`context.appSuccess/Error/Warning/Info`**（推荐） |
| API 抛 `ApiException` 后的错误提示 | `context.appApiError(e)` |
| 普通 toast 式提示 | `context.appInfo(...)` |
| 阻塞性错误 | 用 `UtenDialog` 确认对话框，**不要**用通知 |
| 重要/紧急强提醒（必须被看见） | 用 `UtenNotify.alert(...)` 居中弹窗（见 [UtenNotify.md](UtenNotify.md)），**不要**用顶部弹条 |
| 进度提示（非瞬时反馈） | 使用按钮 loading、`UtenSkeleton` 或主题化进度指示器，**不要**用通知 |

> 旧代码里 `ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(...)))`
> 在 **Phase 1.0+ 已全面迁移** 为 `AppNotification`。新功能禁止再使用底部 SnackBar。

## 三、API

### 3.1 入口扩展（业务最常用）

挂在 `BuildContext` 上，业务侧一行调用：

```dart
context.appSuccess('员工入职成功');          // 顶部绿色
context.appError('工号已存在');            // 顶部红色
context.appWarning('即将离开');            // 顶部橙
context.appInfo('正在准备工资条 PDF');       // 顶部中性

// 自动从 ApiException 提取 message + fieldErrors
context.appApiError(e, fallback: '提交失败');
```

| 方法 | 签名 |
|---|---|
| `context.appSuccess(message, {title?, force?})` | 显示一条成功通知，3.2s 自动消失 |
| `context.appError(message, {title?, fieldErrors?, force?})` | 显示一条错误通知，5s 自动消失 |
| `context.appWarning(message, {title?, force?})` | 显示一条警告通知，3.2s 自动消失 |
| `context.appInfo(message, {title?, force?})` | 显示一条信息通知，3.2s 自动消失 |
| `context.appApiError(error, {fallback?})` | 自动从 `ApiException` 提信息 |

> `force: true` 用于必须让用户看到的关键提示（如禁用按钮的点击反馈），跳过 600ms 去重。`showSuccess/showError/showWarning/showInfo/showMessage` 同样支持 `force`。

### 3.2 Provider（不常用）

```dart
final notifier = ref.read(appNotificationProvider.notifier);
notifier.showError('xxx', title: '失败');
notifier.dismiss(notificationId); // 立刻关掉某条
notifier.clear();                   // 清空所有
```

### 3.3 数据结构

```dart
class AppNotification {
  final String id;                       // 服务内生成的唯一 ID
  final AppNotificationKind kind;        // success / error / warning / info
  final String? title;                   // 可选标题
  final String message;                  // 必填正文
  final int durationMs;                  // 自动消失毫秒数
  final List<ApiFieldError>? fieldErrors; // API 错误专用的字段级错误
}
```

## 四、视觉规范

| kind | 背景 | 文字 | 图标 |
|---|---|---|---|
| success | `colorScheme.primary` | `onPrimary` | `check_circle_outline_rounded` |
| error | `colorScheme.error` | `onError` | `error_outline_rounded` |
| warning | `colorScheme.tertiary` | `onTertiary` | `warning_amber_rounded` |
| info | `surfaceContainerHighest` | `onSurface` | `info_outline_rounded` |

- **位置**：status bar 下方 8dp 居中靠左，全宽左右各留 16dp。
- **动画**：滑入（easeOutCubic，220ms）+ 长按或左/右滑可关闭。
- **队列上限 3 条**：超出自动 FIFO 出队最早的。
- **去重**：600ms 内同 `kind + message` 合并显示一次（防止“先 success 再 fail”双显）。`force: true` 时绕过去重，保证关键提示（如禁用态点击反馈）不被前一条同文案吞掉。

## 五、响应式 / 性能档

- **响应式**：宽度跟随父 `Stack`（在 MaterialApp.builder 中注入），三档断点下表现相同。
- **性能档**：
  - `lite` 档：仍正常显示，不开模糊/长动画。
  - `standard/rich` 档：220ms 滑入 + 自动计时消失。

## 六、国际化适配

- 所有文案走 `AppLocalizations.of(context).xxx`，不在通知组件里硬编码。
- 例外：`'操作失败，请稍后重试'`（`appApiError` 的 fallback 默认值）

## 七、示例代码

### 7.1 简单成功提示

```dart
ScaffoldMessenger 已废除。改用：
context.appSuccess(AppLocalizations.of(context).employeeOnboardSuccess);
context.pop();
```

### 7.2 API 错误自动展开

```dart
try {
  await ref.read(employeeRepositoryProvider).create(input);
} on ApiException catch (e) {
  // 自动渲染 e.message + e.fieldErrors
  context.appApiError(e);
}
```

### 7.3 关闭所有通知

```dart
ref.read(appNotificationProvider.notifier).clear();
```

## 八、实现要点

- **不依赖具体页面**：`AppNotificationHost` 通过 `MaterialApp.builder` 挂到全局 `Stack` 顶层。
  路由 push / pop 不会丢失提示。`ScaffoldMessenger` 不行——它跟最近一个 Scaffold 绑。
- **自管生命**：通知进入队列后由 host 渲染 `_AppNotificationBanner`，220ms 滑入 + `Future.delayed` 计时退出。
- **去重策略**：比 `DateTime.now().millisecondsSinceEpoch` 简单判断；同 message 在 600ms 内合并；`force: true` 跳过此判定。
- **可手动关闭**：IconButton + Dismissible（左滑 / 右滑），保证无障碍可达性。

---

**最后更新**：2026-08-01（加 `force` 参数） · **位置**：`lib/core/ui/app_notification.dart`
