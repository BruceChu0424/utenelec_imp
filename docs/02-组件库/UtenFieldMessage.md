# UtenFieldMessage（字段长提示与错误披露）

> 源码：[`lib/components/inputs/uten_field_message.dart`](../../lib/components/inputs/uten_field_message.dart)
>
> 本组件统一**实时状态类**字段消息（校验错误、预填提醒）与可点击通知的长文案披露。
> **静态字段说明**（解释这个字段是什么/怎么填）自 2026-09-04 起不落在本组件，
> 统一收进标签旁的 ⓘ 悬停提示（`fieldLabel`，见
> [`required_field_decoration.dart`](../../lib/components/inputs/required_field_decoration.dart)），
> 与 `UtenEditableGrid.headerInfo`（表头列说明）同一视觉约定。
> 业务代码不得自行拼接「省略号 + Tooltip」，也不得使用原生 `helperText` / `errorText`。

## 一、两条通道，各管一类

| 内容性质 | 通道 | 视觉 |
| --- | --- | --- |
| 静态说明（怎么填、口径、审计去向） | `fieldLabel(label, theme, info: '…')`；封装组件传 `info:` | 标签旁 ⓘ（`info_outline` 14dp），悬停/长按弹完整提示 |
| 校验错误（提交/服务端返回） | `UtenFieldMessage.error` / `errorBuilder: utenTextFieldErrorBuilder` | 框下红字 + 红框，live-region 播报 |
| 预填提醒（系统学习/主档带入默认值） | `UtenFieldMessage.autofill`（组件 `autofilled: true` 自动挂） | 框下黄字 + 字段黄框，表达「请核对」 |

判断标准：**换一个用户、换一天，这句话还成立吗？** 成立＝静态说明（ⓘ）；
依赖当前输入或流程状态＝实时消息（框下文字，不得藏进悬停）。

## 二、UtenFieldMessage 交互规则

1. 默认只占一行；使用真实文字样式、字号缩放和可用宽度测量，**仅实际溢出**时显示省略号与
   `help_outline_rounded`。短文案不显示多余问号。
2. 完整内容锚定在问号位置显示；桌面鼠标 hover、触摸/鼠标点击、键盘 focus 均可打开，
   不能把 hover 作为唯一入口。
3. 问号视觉图标为 18dp，交互区域至少 44×44dp；窄屏和大字号下仍保留完整可操作区域。
4. 错误使用主题 error 色，并以 `Semantics(liveRegion: true)` 播报完整内容；预填提醒使用
   语义 warning 文字色（`UtenColors.warningText`），与字段黄框
   （`required_field_decoration.dart` 的 `applyAutofillHint`）成对出现；非错误、不播报。
5. Tooltip 展示完整原文并允许换行；点击问号不得触发其外层卡片、通知或行的业务动作。

## 三、API

```dart
// 静态说明：ⓘ 悬停（fieldLabel 也适用于裸 TextField 的 label:）
TextField(
  decoration: InputDecoration(
    label: fieldLabel('当前批次实际汇率', theme, required: true,
        info: '最多 6 位小数；同一收款批次的全部 AR 分配共用该汇率'),
    error: utenFieldError(errorMessage),
  ),
);

// 实时校验错误
TextFormField(
  errorBuilder: utenTextFieldErrorBuilder,
  validator: validateAmount,
);

// 封装组件：info=ⓘ 说明；errorMessage=框下红字；autofilled=黄框+黄字
UtenInput(label: '金额', info: '请输入账户原币金额', errorMessage: serverError);
UtenDropdownField(info: '财务批准后冻结为快照', autofilled: true, ...);
UtenDateField(info: '…', ...);
```

- `fieldLabel`（required_field_decoration.dart）：标签 + 必填红 `*` + 可选 ⓘ 说明，
  三个输入组件与裸 `label:` 共用。
- `UtenFieldMessage.error / .autofill`：框下实时状态消息（helper 构造已随全站 ⓘ 化移除）。
- `utenFieldError`：接受 nullable 字符串的紧凑适配器。
- `utenTextFieldErrorBuilder`：所有直接 `TextFormField` 的统一 validator 错误构建器。
- `UtenOverflowMessage`：非字段场景的底层溢出披露；当前可点击顶部通知复用该能力。

## 四、强制约束

- `lib/` 下禁止 `helperText:`、`errorText:`；改用 `fieldLabel(info:)` 与
  `InputDecoration.error` + 本组件。
- 字段静态说明禁止以常驻文字出现在输入框下方（含裸 `helper:` 文字）——一律 ⓘ。
- 每个直接 `TextFormField(` 都必须声明
  `errorBuilder: utenTextFieldErrorBuilder`，即使当前没有 validator，防止后续补校验时退回原生截断。
- 封装字段组件的说明参数统一命名为 `info` / `errorMessage` / `autofilled`。
- 确有无法迁移的框架兼容场景，必须在对应调用旁写明原因：
  `// uten-field-message-exception: raw-message - <reason>` 或
  `// uten-field-message-exception: TextFormField - <reason>`。
  例外不是长期豁免，后续应移除。

源码门禁位于
[`test/components/inputs/uten_field_message_source_contract_test.dart`](../../test/components/inputs/uten_field_message_source_contract_test.dart)，
会递归扫描 `lib/`，阻止新增裸提示或遗漏统一 errorBuilder。

## 五、验证要求

- 宽布局短文案：不出现问号。
- 窄布局或大字号长文案：一行省略，问号出现且命中区不少于 44dp。
- ⓘ 说明：悬停/长按出现完整提示；标签+ⓘ 在窄字段（140px 起）不溢出。
- hover、tap、focus 均能看到相同完整原文（状态消息）。
- 错误具有完整 live-region 语义。
- 问号嵌在可点击通知/卡片内时，不得执行外层动作。
- 亮色、暗色、375dp 窄屏和系统大字号均不得产生布局溢出。
