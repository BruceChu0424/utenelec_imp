# UtenFieldMessage (全站框内字段提示)

> 2026-09-05 起，文本框、输入框、下拉框、日期和人员等选择器统一将字段说明、预填提醒与校验错误收进框内图标。鼠标悬停、点击或键盘聚焦图标可查看完整内容。
>
> 适配器：[UtenInputDecoration](../../lib/components/inputs/uten_input_decoration.dart)；交互：[UtenFieldHintIcon](../../lib/components/inputs/uten_field_hint_icon.dart)；消息：[UtenFieldMessage](../../lib/components/inputs/uten_field_message.dart)。

## 展示与交互

| 内容 | 业务接口 | 框内表现 |
| --- | --- | --- |
| 静态说明，如填写方法或金额口径 | `info:`，或 `fieldLabel(..., info:)` | 信息图标，弹出完整说明 |
| 校验错误，如必填、格式或服务端字段错误 | `errorMessage:`、`validator`、`UtenFieldMessage.error` | 错误图标和红框，完整错误具有 live-region 语义 |
| 预填提醒，如系统带入历史选项后提示核对 | `autofilled`、`warningMessage`、`UtenFieldMessage.autofill` | 警告图标和黄框，弹出核对提示 |

一个字段同时存在多类消息时使用一个图标，按错误、预填提醒、静态说明顺序展示完整内容；相同消息去重。图标采用主题及语义颜色，视觉优先级为错误、警告、说明。空消息不占图标位置。

2026-09-07 起，`applyAutofillHint` 统一负责黄色描边、浅黄底和框内警告图标，直接使用它的采购/委外供应商、币种、汇率、税率、结算方式、销售收货地址/电话、车间和负责人不再遗漏图标。调用方已有具体预填说明时保留原说明，其余采用中英韩通用核对文案。错误仍优先使用红框。**表格列（2026-09-10）**：列级通用说明一律上移列头 ⓘ（`EditableGridColumn.headerInfo`，共用 `UtenColumnHeaderInfo`），格内只保留错误/预填状态图标；含状态图标的列必须把 44px 图标计入 `chromeWidth`（`UtenEditableGridCellSpec.hintIconWidth`）并给足默认宽（币种 150 / 汇率·税率 140 / 结账 180 / 供应商 170），否则新单默认预填态下值会被裁成省略号。

`UtenFieldLabel` 独立存放标签元数据，`required_field_decoration.dart` 保留导出；装饰与标签不互相循环依赖。`UtenInputDecoration.copyWith/applyDefaults` 保留预填状态，不重复嵌套图标。

禁用字段仍允许查看提示。带帮助或错误的原生 TextField/TextFormField 使用 `ignorePointers: false` 放行提示交互，并保留原 `enabled` 条件；适配器会隔离原有前后缀业务按钮。自定义 `onTap` 仍须检查 enabled，不能借此恢复编辑或业务动作。

字段下方不显示这些消息，也不预留 helper/error 的高度。`hint` 仍是输入前显示、输入后消失的框内占位文字；字段标签和必填 `*` 保持原用途。

图标视觉大小为 18dp，点击区域为 44×44dp；支持鼠标悬停、点击和键盘聚焦，触屏通过点击查看。弹层允许完整原文换行。图标位于框内后缀区域，与原有清空、搜索、密码可见切换、下拉和日期按钮共存，点击提示不应触发字段外层选择或导航动作。

## 使用方式

优先使用共享输入组件，它们负责适配器接入：

```dart
UtenInput(
  label: l10n.amount,
  info: amountHelp,
  errorMessage: serverError,
  validator: validateAmount,
);

UtenDropdownField(
  label: l10n.currency,
  info: currencyHelp,
  value: selectedCurrency,
  items: currencyItems,
  autofilled: currencyAutofilled,
  onChanged: onCurrencyChanged,
);
```

直接使用 Material 字段时，装饰必须使用 `UtenInputDecoration`。每个 `TextFormField` 都配置统一错误构建器，即使当前没有 validator：

```dart
TextFormField(
  controller: amountController,
  validator: validateAmount,
  errorBuilder: utenTextFieldErrorBuilder,
  decoration: UtenInputDecoration(
    InputDecoration(
      label: fieldLabel(
        l10n.amount,
        theme,
        required: true,
        info: amountHelp,
      ),
      error: utenFieldError(serverError),
      suffixIcon: originalSuffixButton,
    ),
  ),
);
```

`TextField`、`InputDecorator`、`DropdownButtonFormField` 等使用 `InputDecoration` 的字段同样适用；预填消息仍由原来的业务状态控制：

```dart
UtenInputDecoration(
  applyAutofillHint(
    InputDecoration(
      labelText: l10n.currency,
      helper: autofilled ? UtenFieldMessage.autofill(autofillHelp) : null,
      error: utenFieldError(errorMessage),
    ),
    theme,
    autofilled: autofilled,
  ),
  info: currencyHelp,
);
```

## 组件责任

- `UtenInputDecoration` 保留原始装饰，转发属性、`copyWith` 和 `applyDefaults`。原生表单后来注入的 validator 错误也会进入框内；`FormState.validate`、错误状态、控制器和 `reset` 继续由原生表单管理。
- `UtenFieldHintIcon` 负责悬停、点击、键盘和无障碍消息，合并三类文本。错误持续保留语义通知，视觉显示不影响校验结果。
- `fieldLabel` 返回带说明元数据的 `UtenFieldLabel`。用于输入装饰时，适配器将说明移入框内，仅将标签和必填星号交给浮动标签。
- `UtenFieldMessage.error/.autofill` 是字段消息载体；`utenFieldError` 接受可空字符串，`utenTextFieldErrorBuilder` 统一生成 validator 消息。
- `UtenOverflowMessage` 保留非字段内容的长文案披露能力，例如顶部通知；不使用输入框适配器，不改变通知布局。

## 源码门禁

[`uten_field_message_source_contract_test.dart`](../../test/components/inputs/uten_field_message_source_contract_test.dart) 使用 Dart AST 扫描整个 `lib/`，逐个检查实际调用，注释和字符串中的代码示例不会影响结果：

1. 每个直接 `TextFormField` 必须有外层 `UtenInputDecoration` 和 `errorBuilder: utenTextFieldErrorBuilder`。
2. 含 `helper`、`error` 或 `fieldLabel` 的 `InputDecoration` 必须置于 `UtenInputDecoration` 内。
3. 页面禁止原生 `helperText:`、`errorText:`。唯一兼容例外是适配器 `copyWith` 对原参数的精确转发；不接受页面注释豁免。
4. `part` 文件遵循同一展示门禁，依赖由主库导入，不在 `part` 中另加 import。

封装字段的说明参数统一使用 `info` / `errorMessage` / `autofilled`。新增或修改字段时，不得在框下另放重复说明。

## 验证要求

- 短消息与长消息均使用框内图标，框下无提示文字、无 helper/error 占位。
- 静态说明、预填和错误能同时查看；错误优先显示，并完整保留无障碍语义。
- 通过 hover、tap 和键盘 focus 获取相同原文，提示点击不触发选择器或外层业务动作。
- 原有清空、搜索、密码可见切换、下拉和日期操作仍有效。
- `validate()` 失败、错误恢复、`reset()`、外部错误更新和 controller 编辑保持真实表单行为。
- 亮色、暗色、窄屏及大字号不溢出；通知等非字段消息保留原有布局和交互。

## 2026-09-07 虚拟表格中的学习状态

仓库单笔/批量到货登记复用 `WarehouseAutofillTextField`，底层仍为
`applyAutofillHint + UtenInputDecoration`，不再复制黄色边框和图标实现。
`UtenAutofillTextController` 将待核对状态绑定到行数据生命周期：仅实际文本变化清除状态，
selection/focus/composing 不清除；新自动建议必须显式调用 `setAutomaticText`。
历史快照以 `autofilled:false` 创建。单笔/批量成品登记保留原来源枚举，文字变更监听同样只比较文本。
校验和确认动作仍由页面及服务端负责；黄色来源提示本身不批准、不提交、不改变业务事实。
