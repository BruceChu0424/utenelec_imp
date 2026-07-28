# UtenPagePrefsNotifier（页面偏好基类）

> 路径：`lib/shared/providers/uten_page_prefs_notifier.dart` · Riverpod `Notifier` 抽象基类
> 后端依赖：`user_preferences`（V27）键值接口 `GET/PUT /api/user/preferences[/{key}]`，无额外权限点
> 已实现范例：工作台布局（`workbench.layout`）· 即时库存「含不良品仓」开关（`stock.instantInventory`）

## 一、解决什么

报表页/列表页的筛选项、开关、列显隐、布局等「上次选择」，要**换设备/重登自动带上**。
在这个基类之前，每处各写一套缓存+同步+防抖（工作台布局一处、即时库存一处），逻辑重复且容易漏掉
离线兜底、换号同步这些边角。基类把三层策略下沉，子类只声明 **prefKey + 序列化** 两件事。

## 二、三层策略（继承即得，无需重写）

1. **冷启动**：先读 shared_preferences 本地缓存 → 页面即时渲染，不闪烁；无缓存用 `defaultValue`。
2. **服务端同步**：会话就绪（登录/换号）后拉 `GET /user/preferences` 的 `prefKey` 覆盖本地；
   服务端没存过该 key → 保留本地缓存/默认值，不打断页面。
3. **写路径**：乐观更新 `state` + 立即写缓存 + 防抖 800ms `PUT /user/preferences/{prefKey}`；
   **离线兜底**：PUT 失败静默（本地已生效），下次登录同步自然收敛，不做重试队列。

## 三、最小子类（照抄即可）

```dart
class MyPagePrefsNotifier extends UtenPagePrefsNotifier<bool> {
  @override
  String get prefKey => 'myPage.showClosed'; // 服务端偏好 key（全账号唯一，点分层命名）

  @override
  bool get defaultValue => true;

  @override
  bool? decode(Object? raw) => raw is bool ? raw : null; // 不识别返回 null=保留现状

  @override
  Object? encode(bool state) => state;
}

final myPagePrefsProvider =
    NotifierProvider<MyPagePrefsNotifier, bool>(MyPagePrefsNotifier.new);
```

页面使用：

```dart
final v = ref.watch(myPagePrefsProvider);                    // 读
ref.read(myPagePrefsProvider.notifier).update(v2);           // 整体替换 + 持久化
// 或子类自行改 state 后调 persist()（如 workbench 的 toggleCollapsed/reorder）
ref.listen(myPagePrefsProvider, (prev, next) { /* 偏好变了 → 重查 */ });
```

## 四、契约与注意

| 成员 | 说明 |
|---|---|
| `prefKey` | 服务端偏好 key。命名约定 `<页面/模块>.<含义>` 点分层（`stock.instantInventory`、`workbench.layout`）。后端校验 ≤100 字符 |
| `defaultValue` | 本地缓存/服务端都没有时的默认值 |
| `decode(raw)` | **必须兼容两种来源**：缓存 `jsonDecode` 结果 与 服务端原始 value（服务端 value 可能是 String 形态，需自行再 `jsonDecode`）。返回 null = 不覆盖本地 |
| `encode(state)` | 可 JSON 序列化值；写缓存 `jsonEncode` 与 PUT body 共用。后端限制 value ≤16KB |
| `cacheKey` | 本地缓存 key，默认派生 `page_prefs_cache_$prefKey`；**迁移期可覆盖**兼容旧缓存（两个范例都覆盖了） |
| `saveDebounce` | 推送防抖，默认 800ms，可覆盖 |
| `update(v)` / `persist()` | 写入口：简单偏好用 `update`；多字段状态自行改 `state` 后调 `persist()` |

- **未登录不推服务端**（基类内部守卫）；访客模式 service 层会拒绝，静默失败即可。
- **不要在 decode 里做网络请求**；合并逻辑（如丢弃已删除 key）放 decode 内同步完成。
- 偏好值只放「界面状态」；业务数据、敏感信息禁止进偏好。

## 五、迁移既有偏好到基类（范例实证）

1. 子类化，把原 `_loadFromCache/_syncFromServer/_persist/_pushToServer` 全删掉；
2. 原合并/解析逻辑搬进 `decode`；原写入结构搬进 `encode`；
3. **覆盖 `cacheKey` 为旧值**，避免老用户本地缓存丢失（旧缓存值若是裸字符串 `"true"`，
   本身是合法 JSON，`jsonDecode` 后 decode 照常识别）；
4. 原 `_persist()` 调用点改 `persist()`。

两个已回迁实现：`lib/features/dashboard/providers/workbench_layout_provider.dart`、
`lib/features/stock/providers/instant_inventory_prefs_provider.dart`——照它们抄即可。
