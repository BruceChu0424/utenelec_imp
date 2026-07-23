# ADR-002 - 状态管理选 Riverpod

- **状态**：已接受
- **日期**：2026-07-21

---

## 上下文

Flutter 状态管理方案众多，团队需要选定一个统一方案。候选：

1. **Riverpod 2.x**
2. **Provider**（Flutter 官方旧推荐）
3. **Bloc / Cubit**
4. **GetX**

## 决策

**选定 Riverpod 2.x**。

## 理由

| 维度 | Riverpod | Provider | Bloc | GetX |
|---|---|---|---|---|
| 类型安全 | ✅ 强 | ❌ 弱 | ✅ | ⚠️ |
| 不依赖 BuildContext | ✅ | ❌ | ✅ | ✅ |
| 测试友好 | ✅ | ⚠️ | ✅ | ❌ |
| AsyncNotifier 一站式 | ✅ | ❌ | ⚠️ 需 Stream | ❌ |
| 学习曲线 | 中等 | 低 | 高 | 低 |
| 社区活跃度 | ✅ 高 | 中（已过时） | ✅ | ⚠️ 争议 |
| 反模式风险 | 低 | 中 | 低 | **高** |

关键决策点：
- **Provider 已被官方建议用 Riverpod 替代**（作者同一人）
- **Bloc 样板代码多**，对中等复杂度项目过重
- **GetX 架构混乱**，把路由/状态/i18n 都混在一起，企业项目禁用
- Riverpod 的 `AsyncNotifier` 完美契合"加载列表 → 处理错误 → 缓存"这种企业后台典型场景

## 后果

### 正面
- 全局状态（主题/语言/字号/性能档）用 Provider 统一管理
- 业务状态用 AsyncNotifier，加载/错误/数据三态清晰
- 测试时不需要 MaterialApp 包裹，单测简单
- 代码生成（riverpod_generator）减少样板代码

### 负面
- 团队需要学习 Riverpod 语法（`ref.watch` / `ref.read` / `Notifier` / `AsyncNotifier`）
- Provider 作用域概念需要理解

## 使用约定

- 全局偏好：`Notifier` + `shared_preferences` 持久化
- 业务数据：`AsyncNotifier` + Repository
- 不要在 Widget 顶层散落 `ProviderScope`，只在 `main.dart` 包一层
- Provider 命名：`xxxProvider`（小写）+ `XxxNotifier`（大写类名）

## 相关

- [../00-项目准则/05-国际化与多语言.md](../00-项目准则/05-国际化与多语言.md)（LocaleProvider 用 Riverpod）
- [../05-架构/状态管理.md](../05-架构/状态管理.md) ⏳

---

**最后更新**：2026-07-21
