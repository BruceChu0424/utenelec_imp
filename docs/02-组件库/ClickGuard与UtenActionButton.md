# ClickGuard & UtenActionButton（防连点 / 等待回执）

> **本项目自建组件**。这一对组合的目的只有一个：
> **任何按钮只要触发了"点击 → 等待后端回执"流程，在回执到达之前，禁止再点、禁止重入、视觉上有 loading 反馈。**
> 用于彻底防住"快速点击 → 多次提交 / 多次扣费 / 多次发送"这类线上必踩坑。

---

## 一、为什么需要这一对

### 痛点
任何写得轻率的代码：

```dart
FilledButton(
  onPressed: () async {
    await api.submit();  // 网络请求
  },
  child: Text('提交'),
)
```

都允许用户在异步回执到达前**反复点击**，造成：
- 后端收到多条相同请求（创建了 5 个相同员工 / 5 个相同报销单）
- 前端 state 错乱（5 个并发 setState）
- 用户体感"按钮没反应，于是再点几次"——雪上加霜

### 解决思路

核心模式 **"点击 → 置忙 → 等回执 → 解锁"**：

```text
Time →
用户点击              回执到达
  ↓                      ↓
[busy=true]    UI 禁用 + spinner    [busy=false]  UI 恢复可点
  ↑───────────── 重复点击被忽略 ─────────────┘
```

`ClickGuard` 是状态机，`UtenActionButton` 是它的可视外壳。

---

## 二、ClickGuard（核心工具）

### 2.1 API

```dart
class ClickGuard {
  bool get isBusy;                       // 当前是否置忙（用于 build 时 disable 子组件）

  Future<void>? run(Future<void> Function() action);
  // - 同步判定：若已 busy 直接返回 null，业务侧**不会**触达 action。
  // - 异步判定：返回 Future<void>?，被拦截时返回 null。
  // - Future resolve 时（无论成功还是抛错）自动解锁。

  void release();                        // 强制释放（仅用于旁路，正常用 run）
}
```

### 2.2 用法（自定义控件）

Switch / Slider / SegmentedButton 等非按钮型控件也容易踩坑，
用 `ClickGuard` + build 里读 `isBusy` 来 disable：

```dart
final _guard = ClickGuard();

SwitchListTile(
  value: device.power,
  onChanged: _guard.isBusy
      ? null
      : (v) => _guard.run(() async {
          await api.update(power: v);
        }),
)
```

如果你的页面里多个控件需要同步等待某个动作完成（如 HVAC 控制页的开关 / 温度 / 模式 / 风速都对应同一次 PUT），把同一个 `ClickGuard` 给多个控件共享。

> **重要**：guard 是按 State 实例追踪，每个 State 一个，**不要**跨 widget 共享。

---

## 三、UtenActionButton（带 loading 视觉的按钮）

### 3.1 API

```dart
UtenActionButton({
  required Future<void> Function() onAction,  // 必须：等待回执的异步动作
  required Widget label,                       // 必须：按钮文字
  Widget? loadingLabel,                        // 可选：loading 时显示的简写（如"提交中…"）
  Widget? icon,                                // 可选：左侧图标
  UtenActionButtonType type = primary,         // 主/次/幽灵/危险
  UtenActionButtonSize size = medium,          // small/medium/large
  bool isExpanded = false,                     // 撑满父宽（用于 BottomActionBar）
})
```

### 3.2 用法

```dart
UtenActionButton(
  type: UtenActionButtonType.primary,
  isExpanded: true,
  icon: Icons.check_rounded,
  label: Text(l10n.submit),
  loadingLabel: Text(l10n.submitting),
  onAction: () async {
    await api.submit();
    if (context.mounted) context.appSuccess(l10n.submitSuccess);
  },
)
```

按下后：
1. 立刻进入 busy（**不可被重复点击**）。
2. 图标位替换为 `CircularProgressIndicator(strokeWidth: 2)`。
3. 文字位换成 `loadingLabel`（如有），否则保持 `label`。
4. `onAction()` Future 完成（成功或抛错）后恢复。

---

## 四、和 `UtenButton` 的关系

| 组件 | 适用场景 | 何时用 |
|---|---|---|
| `UtenButton(isLoading: ..., onPressed: ...)` | 业务侧自己管 `_submitting`/`_acting` flag；动作复杂（多阶段）；状态要在多处复用 | 页面级状态 + 多个按钮共享同一个 loading 状态；动作里要做其他 setState |
| **`UtenActionButton(onAction: ...)`** | 按钮点一下单次动作；loading 状态是按钮自己的事 | **多数场景首选**——dev 写不出 bug |
| `ClickGuard.run(...)` | Switch/Slider/SegmentedButton 等非按钮控件；同一组控件共享一个 guard | 联动控件（一个动作影响多个 UI） |

原则：**业务侧拿不准时，无脑 `UtenActionButton`**。

### 3.3 老代码迁移路径

| 老代码 | 推荐改法 |
|---|---|
| `bool _acting = false;` + `UtenButton(isLoading: _acting, ...)` | 删除 `_acting`，改用 `UtenActionButton(onAction: () async {...})` |
| `TextButton(onPressed: () async { await api.x(); }, ...)` 裸 async | 改用 `UtenActionButton` 拦住 |
| 多步动作（A → B → C），各自有 loading 状态 | 每一步一个独立 `UtenActionButton`；或外层一个 guard + 多个内层按钮 |
| Switch/Slider 直接 `onChanged: (v) { await api.update(v); }` | 用 `ClickGuard.run()` 守，再加上 `isBusy ? null : onChanged` |

---

## 五、何时用 / 何时不用

### 用

- ✅ 任何触发网络请求的按钮（提交、保存、删除、审批、转交）
- ✅ 任何 Switch / Slider 改变会触发后端 PUT
- ✅ 任何 SegmentedButton 触发后端操作
- ✅ 任何确认/删除对话框里的"确定"按钮
- ✅ Mock 阶段为了 UX 一致性，模拟 600ms 延时也要套 guard

### 不用（用更合适的方式）

- ❌ 纯本地导航：`Navigator.push` / `context.go`，**无需**等待回执
- ❌ 纯 UI 状态切换（如展开/折叠 Drawer）：`UtenButton` 不带 onAction 也行
- ❌ 长时间任务（几秒以上）：建议用全局 `PageLoader` 或进度条，**不要**让用户靠按钮等

---

## 六、响应式 / 性能档

- **响应式**：按钮内部按 `widget.isExpanded` 撑满宽度，三档断点下表现同 `UtenButton`。
- **性能档**：
  - `lite` 档：仍出 spinner（必要反馈），无 blur、无 fancy 动画。
  - `standard/rich` 档：与 UtenButton 表现一致。

## 七、国际化适配

- `label` 和 `loadingLabel` 接受任意 Widget，文案自己走 `AppLocalizations.of(context).xxx`。
- 不在组件内硬编码中文 / 英文。

---

## 八、防连点实现细节（避坑）

1. **不要在 `onAction` 同步抛错**——会让 caller 以为是 success。
   ```dart
   // 不推荐
   onAction: () {
     doSync();                    // 同步抛出会绕过 run 的 whenComplete
     throw 'oops';
   }
   // 推荐
   onAction: () async {
     try {
       await api.submit();
     } catch (e) {
       // 把错误转给 context.appApiError(e)
     }
   }
   ```

2. **不要在 `onAction` 里 await **无关**的 Future**——会延长锁定时间。
   ```dart
   // 不推荐
   onAction: () async {
     await Future.delayed(Duration(seconds: 3));  // 测试/演示用是可以的
     await api.submit();
   }
   ```

3. **同一页面多个 `UtenActionButton` 各自独立**——按用户预期分别 disable，不需要互锁。
   互锁场景才用 `ClickGuard` 共享实例。

4. **回调里用 `context` 必须 `context.mounted` 守卫**——guard 在异步回执后才解锁，
   那时原页面可能已 pop。

   另外：**在 State 子类的方法**里，`context` 是 State 的，**用 `mounted` 守卫**就够
   （`context.mounted` 会被 lint 标"不相关的 mounted 检查"）。
   ```dart
   // 在 _MyPageState 的方法里：
   await api.submit();
   if (!mounted) return;       // ✅ 用 State.mounted
   context.appSuccess(...);    // 现在用 context 安全
   
   // 在 UtenActionButton.onAction 里（onAction 闭包有自己捕获的 BuildContext）：
   await api.submit();
   if (!context.mounted) return;  // ✅ 用 context.mounted
   context.appSuccess(...);
   ```

---

## 九、示例代码

### 9.1 提交报销

```dart
UtenActionButton(
  type: UtenActionButtonType.primary,
  isExpanded: true,
  icon: Icons.send_rounded,
  label: Text(l10n.submit),
  loadingLabel: Text(l10n.submitting),
  onAction: () async {
    await ref.read(expenseRepositoryProvider).submit(claim.id);
    if (context.mounted) {
      context.appSuccess(l10n.submitSuccess);
      context.go(RouteName.expense);
    }
  },
)
```

### 9.2 通知发布页（校验 → 二次确认 → 动作 → 跳转）

这是 [通知发布页](../../03-页面/通知发布页.md) 的真实例子——
onAction 里既有客户端校验、又有 showDialog 等待、又有后续跳转。
`UtenActionButton` 把这一整段统一管起来，禁止用户在等待期间再次点击。

```dart
// ❌ 之前的写法（手动 _publishing state + UtenButton.isLoading）
bool _publishing = false;

Future<void> _publish() async {
  if (_title.text.trim().isEmpty) {
    _toastError(l10n.noticePublishValidateTitle);
    return;
  }
  final ok = await showDialog<bool>(/*...*/);
  if (ok != true) return;
  setState(() => _publishing = true);
  try {
    await Future.delayed(Duration(milliseconds: 600));
    context.appSuccess(l10n.noticePublishPublished);
    context.go('/notice');
  } finally {
    if (mounted) setState(() => _publishing = false);
  }
}
// 还要写一个配套的 `UtenButton(isLoading: _publishing, onPressed: _publish, ...)`
// 还有一个 `_toastError()` 私有方法...
// 业务代码 ~30 行 + 重复样板

// ✅ 迁移到 UtenActionButton（业务代码精简一半）
Future<void> _onPublish() async {
  final l10n = AppLocalizations.of(context);
  // 1) 校验（在按钮上：提示用户错得早，release 按钮）
  if (_title.text.trim().isEmpty) {
    if (context.mounted) context.appError(l10n.noticePublishValidateTitle);
    return;
  }
  if (_content.text.trim().isEmpty) {
    if (context.mounted) context.appError(l10n.noticePublishValidateContent);
    return;
  }
  // 2) 二次确认
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l10n.noticePublishConfirmTitle),
      content: Text(/*...*/),
      actions: [/* 取消 / 发布 */],
    ),
  );
  if (ok != true) return;

  // 3) 实际动作 + 跳转
  await Future<void>.delayed(const Duration(milliseconds: 600));
  if (!mounted) return;          // 注意：State 子类方法用 mounted，不是 context.mounted
  context.appSuccess(l10n.noticePublishPublished);
  context.go('/notice');
}

// 调用：一个 UtenActionButton 全包
Expanded(
  child: UtenActionButton(
    type: UtenActionButtonType.primary,
    isExpanded: true,
    icon: Icons.send_rounded,
    label: Text(l10n.noticePublishPublishButton),
    loadingLabel: const Text('发布中…'),
    onAction: _onPublish,
  ),
)
```

要点：
- **校验失败 → 直接 return**，按钮根本没进入"置忙"环节，红色 banner 一闪而过。
- **取消确认 → 直接 return**，按钮短暂置忙后立刻解锁，符合"点开了但没干"的体感。
- **真正发布 → 跳列表页**，跳的时机在 `await` 之后、按钮解锁之前。
- **状态机自带**：删了 `_publishing`、`_toastError()`、setState 等样板。

### 9.3 HVAC 联动控件

```dart
final _guard = ClickGuard();

Switch(
  value: device.power,
  onChanged: _guard.isBusy
      ? null
      : (v) {
          final f = _guard.run(() async {
            await api.update(device.copyWith(power: v));
          });
          if (f != null) setState(() {});  // 重建以禁用其他控件
        },
)

Slider(
  onChanged: !_device.power || _guard.isBusy
      ? null
      : (v) => setState(() => _device = _device.copyWith(targetTemp: v)),
  onChangeEnd: _guard.isBusy
      ? null
      : (v) => _guard.run(() => api.update(_device.copyWith(targetTemp: v))),
)
```

### 9.3 错误回执透传到顶部通知

```dart
UtenActionButton(
  label: Text(l10n.delete),
  loadingLabel: Text(l10n.deleting),
  type: UtenActionButtonType.danger,
  onAction: () async {
    try {
      await api.delete(id);
      if (context.mounted) context.appSuccess(l10n.deleted);
    } on ApiException catch (e) {
      if (context.mounted) context.appApiError(e);
    }
  },
)
```

---

## 十、自检清单（每次写按钮过一遍）

- [ ] 只要按钮会触发网络请求 / 异步操作 → 包 `UtenActionButton` 或 `UtenButton(isLoading: ...)`
- [ ] 异步回调里使用 `context` 前做了 `context.mounted` 守卫
- [ ] 不在 `onAction` 里抛同步异常（统一用 try/catch + appError）
- [ ] 联动控件（Switch/Slider/SegmentedButton）共享 `ClickGuard` 实例
- [ ] `loadingLabel` 用了 l10n key（如 "提交中…"/"Submitting…"）
- [ ] 没有把 `Future.delayed(...)` 当 sleep 用在生产代码

---

**最后更新**：2026-07-23 · **位置**：`lib/components/buttons/click_guard.dart`
