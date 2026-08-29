# UtenFieldMessage（字段长提示与错误披露）

> 源码：[`lib/components/inputs/uten_field_message.dart`](../../lib/components/inputs/uten_field_message.dart)
>
> 本组件统一表单辅助说明、校验错误和可点击通知的长文案披露。业务代码不得自行拼接
> “省略号 + Tooltip”，也不得继续使用原生 `helperText` / `errorText`。

## 一、交互规则

1. 默认只占一行；使用真实文字样式、字号缩放和可用宽度测量，**仅实际溢出**时显示省略号与
   `help_outline_rounded`。短文案不显示多余问号。
2. 完整内容锚定在问号位置显示；桌面鼠标 hover、触摸/鼠标点击、键盘 focus 均可打开，
   不能把 hover 作为唯一入口。
3. 问号视觉图标为 18dp，交互区域至少 44×44dp；窄屏和大字号下仍保留完整可操作区域。
4. 错误使用主题 error 色，并以 `Semantics(liveRegion: true)` 播报完整内容；辅助说明使用
   `onSurfaceVariant`，颜色不是唯一错误信号。
5. Tooltip 展示完整原文并允许换行；点击问号不得触发其外层卡片、通知或行的业务动作。

## 二、API

```dart
InputDecoration(
  helper: utenFieldHelper(helperMessage),
  error: utenFieldError(errorMessage),
);

TextFormField(
  errorBuilder: utenTextFieldErrorBuilder,
  validator: validateAmount,
);

// 已封装字段使用 message 参数，不再透传原生 text 参数。
UtenInput(
  helperMessage: '请输入账户原币金额',
  errorMessage: serverError,
);
UtenDropdownField(errorMessage: selectionError, ...);
UtenDateField(errorMessage: dateError, ...);
```

- `UtenFieldMessage.helper/error`：字段辅助说明或错误。
- `utenFieldHelper/utenFieldError`：接受 nullable 字符串的紧凑适配器。
- `utenTextFieldErrorBuilder`：所有直接 `TextFormField` 的统一 validator 错误构建器。
- `UtenOverflowMessage`：非字段场景的底层溢出披露；当前可点击顶部通知复用该能力。

## 三、强制约束

- `lib/` 下禁止 `helperText:`、`errorText:`；改用 `InputDecoration.helper/error` 和本组件。
- 每个直接 `TextFormField(` 都必须声明
  `errorBuilder: utenTextFieldErrorBuilder`，即使当前没有 validator，防止后续补校验时退回原生截断。
- 公共字段参数统一命名为 `helperMessage` / `errorMessage`，由组件内部转成 Widget。
- 确有无法迁移的框架兼容场景，必须在对应调用旁写明原因：
  `// uten-field-message-exception: raw-message - <reason>` 或
  `// uten-field-message-exception: TextFormField - <reason>`。
  例外不是长期豁免，后续应移除。

源码门禁位于
[`test/components/inputs/uten_field_message_source_contract_test.dart`](../../test/components/inputs/uten_field_message_source_contract_test.dart)，
会递归扫描 `lib/`，阻止新增裸提示或遗漏统一 errorBuilder。

## 四、验证要求

- 宽布局短文案：不出现问号。
- 窄布局或大字号长文案：一行省略，问号出现且命中区不少于 44dp。
- hover、tap、focus 均能看到相同完整原文。
- 错误具有完整 live-region 语义。
- 问号嵌在可点击通知/卡片内时，不得执行外层动作。
- 亮色、暗色、375dp 窄屏和系统大字号均不得产生布局溢出。
