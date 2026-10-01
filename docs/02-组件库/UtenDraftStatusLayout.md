# UtenDraftStatusLayout

实现：`lib/components/layout/uten_draft_status_layout.dart`。统一由 `FormDraftMixin.withFormDraft` 接入；业务页不用增加底部 padding。

状态条是表单布局的一部分，不覆盖业务按钮。`status` 为空时不保留状态条高度；非空时先分配状态条和安全区，再给编辑内容剩余高度。内容子树位置保持稳定，状态变化不重建输入控件。

| 参数 | 合同 |
| --- | --- |
| `status` | 已有草稿状态文本，长错误可独立滚动阅读 |
| `isError` | 使用主题 error 颜色及无障碍 live region |
| `onRetry` | 可选的本机保存重试，调用者提供；不能在此转成业务提交重放 |
| `child` | 页面或弹层内容，同时支持有界高度和滚动容器内的收缩布局 |

底部结构复用 `UtenBottomActionBar`。状态条只消耗一次键盘 inset；已由 footer 消耗的胶囊导航遮挡，在编辑内容子树中归零，避免双重垫高。状态消失后恢复内容原本的键盘和胶囊布局规则。

文本使用主题 `bodySmall` 和颜色 token，保留系统文字缩放。极长错误不挤走重试按钮，文本区域有界并可滚动；重试复用 `UtenActionButton` 的焦点、44dp 最小高度和防连点。标签优先读现有 `commonRetry`，轻量测试或未提供语言委托的独立宿主保留中文兜底。

Mixin 仅在本机保存失败且当前不忙、未完成、恢复和提交未被保护锁定时提供重试。重试调用现有 `saveFormDraftNow`，继续使用既有身份和 CAS 合同。

验证及隔离集成记录见 [2026-09-30-公共草稿状态条布局](../99-项目治理/2026-09-30-公共草稿状态条布局.md)。这项修复不改变草稿字段编码、行身份、未知提交恢复或后端写入协议。
