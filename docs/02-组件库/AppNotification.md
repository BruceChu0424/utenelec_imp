# AppNotification（顶部通知服务）

> **本项目自建组件**。
> 不是 Material 的 SnackBar，也不是 `lib/components/feedback/uten_toast.dart` 的 UtenToast。
> 顶部渲染（status bar 下方滑入），按 `success/error/warning/info` 四级配色，
> 同时完整展示上限 3 条 + 600ms 同 message 合并去重；
> 2026-09-02 起**每条通知从到达时刻独立计时、快进快出**——未挂载的到点自行消失，
> 最早的先走，专治"先成功再失败"的双 SnackBar 抖动与叠堆久留。

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
| 通知中心到达的 important / urgent 事件 | 仍走顶部叠放，分别使用 warning / error 视觉和更长停留时间 |
| 当前操作必须立即确认、且不是通知到达事件 | 可显式使用 `UtenNotify.alert(...)`；不得由通知到达链默认弹出 |
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
| `context.appSuccess(message, {title?, force?})` | 显示一条成功通知，默认 1.5s 自动消失 |
| `context.appError(message, {title?, fieldErrors?, force?})` | 显示一条错误通知，默认 2.5s 自动消失 |
| `context.appWarning(message, {title?, force?})` | 显示一条警告通知，默认 2s 自动消失 |
| `context.appInfo(message, {title?, force?})` | 显示一条信息通知，默认 1.5s 自动消失 |
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

视觉外壳与「连接恢复横幅」共用 [`UtenTopBannerCard`](../../lib/core/ui/uten_top_banner_card.dart)（居中 / 最大宽 720 / 圆角 14 / elevation 4）。配色取柔和容器色：

| kind | 背景 | 文字 | 图标 |
|---|---|---|---|
| success | `colorScheme.primaryContainer` | `onPrimaryContainer` | `check_circle_outline_rounded` |
| error | `colorScheme.errorContainer` | `onErrorContainer` | `error_outline_rounded` |
| warning | `colorScheme.tertiaryContainer` | `onTertiaryContainer` | `warning_amber_rounded` |
| info | `UtenColors.infoContainer`（浅蓝，深色模式 `infoContainerDark`） | `onInfoContainer` / `onInfoContainerDark` | `info_outline_rounded` |

> 本主题 `primary/secondary/tertiaryContainer` 同为 teal，故 **success 与 warning 同底色，靠语义图标区分**（✓ / ⚠）；error 浅红、info 浅蓝各自独立。info 不再用中性灰 `surfaceContainerHighest`——灰底叠 hover InkWell 罩会把整条刷成一片灰长条（用户误以为「灰色面板」），故改用语义浅蓝/深蓝容器色。

- **位置**：屏幕顶部居中，最大宽 720dp；`SafeArea` 与水平居中由宿主统一承担，卡片两侧空白不拦截页面点击。
- **动画**：滑入（easeOutCubic，220ms）+ 左/右滑可关闭；系统 `disableAnimations` 时立即进入/退出。
- **iPhone 式叠放**：最新通知在最上层；默认只挂载最新真实卡片，更早通知以卡片下缘露出的 **6px 细边条**表示层数（最多 2 条）。细边画在卡片足迹之外、不垫在卡片背后——历史上用整块灰色圆角矩形垫背，滑动 / 淡出移开卡片时整块灰板暴露，就成了「突然全屏宽的灰色横条」。
- **展开控制 = 紧凑计数胶囊**：叠放层下方居中悬挂一枚 stadium 小胶囊（方向箭头 + 队列总数，`surfaceContainerHigh` 底），替代历史上的整行「展开 X 条通知」文字按钮；完整说明在 tooltip 与 Semantics 标签，命中区域 ≥48dp。
- **正文溢出也按内容收缩**：带 `onTap` 的正文走 `UtenOverflowMessage` 溢出分支，文字触发省略号时该分支用 `Flexible`（loose）按最长渲染行收缩。历史 bug：曾是 `Expanded`（tight），溢出即顶满 720 可用宽，移开上层通知露出的就是一块全屏宽淡色横条（叠上灰色轮廓层更像「灰条」）。
- **独立计时（2026-09-02）**：每条通知从**到达时刻**起算自己的停留时长。挂载中的卡片由 banner 倒计时（支持悬停 / 后台暂停，重挂载按剩余时间而非重置）；未挂载的（细边 / 排队超出上限）由宿主统一到期——**最早的先消失**，批量叠堆在各自时限内从后往前清空，不再串行拖延。到期同样触发一次 `onDismissed`（含排队中未完整展示的项；`clear` 与宿主销毁仍不触发）。
- **默认停留时长**：success/info 1.5s、warning 2s、error 2.5s；文案每超 20 字 +0.3s（封顶 +1.8s）；字段错误 +1s。显式传 `Duration` 走调用方口径。
- **队列不丢弃**：3 条只是同时完整展示上限。超过 3 条继续保留在 `AppNotificationService`，但每条都在按自己的到达时刻独立倒计时（见上「独立计时」）；`onDismissed` 恰好触发一次。
- **去重**：600ms 内同 `kind + message` 合并显示一次（防止“先 success 再 fail”双显）。`force: true` 时绕过去重，保证关键提示（如禁用态点击反馈）不被前一条同文案吞掉。

## 五、响应式 / 性能档

- **响应式**：卡片最大宽 720dp；展开控制是恒定的紧凑计数胶囊（箭头 + 数字），无需按屏宽/字号在文字与图标按钮间切换，窄屏大字号下也只是胶囊内数字变大。
- **可访问性**：展开/收起有明确 Semantics 标签；关闭和展开触控目标至少 48dp；叠放时只有最新通知进入 live region，展开旧通知不会重复打断读屏。
- **性能档**：
  - `lite` 档：仍正常显示，不开模糊/长动画。
  - `standard/rich` 档：220ms 滑入/展开淡变 + 自动计时消失；悬停暂停计时。

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
- **自管生命**：通知进入队列后由 host 交给 `UtenNotificationStack`；挂载中的卡片由 banner 自己倒计时（悬停 / 后台暂停、重挂载按剩余时间），未挂载的由宿主按「到达时刻 + 停留时长」统一到期，最早的先走。
- **去重策略**：比 `DateTime.now().millisecondsSinceEpoch` 简单判断；同 message 在 600ms 内合并；`force: true` 跳过此判定。
- **可手动关闭**：IconButton + Dismissible（左滑 / 右滑），保证无障碍可达性。
- **共享外壳**：`_AppNotificationBanner` 的视觉外壳（maxWidth 720 / Material / 圆角 14）由 [`lib/core/ui/uten_top_banner_card.dart`](../../lib/core/ui/uten_top_banner_card.dart) 的 `UtenTopBannerCard` 提供，与 `ConnectionRecoveryBanner` 同款；`AppNotificationHost` 统一处理 `SafeArea`、居中与叠放。

---

**最后更新**：2026-09-02（②独立计时口径：每条从到达起算、未挂载项宿主统一到期最早先走、默认时长缩至 1.5-2.5s；②叠放深度提示改卡片下缘细边条，修复滑动移开时露出整块灰板的「全屏宽灰条」；③展开控制改紧凑计数胶囊；④溢出正文 Expanded→Flexible） · **位置**：`lib/core/ui/app_notification.dart` · **叠放层**：`lib/core/ui/app_notification_stack.dart` · **外壳**：`lib/core/ui/uten_top_banner_card.dart`
