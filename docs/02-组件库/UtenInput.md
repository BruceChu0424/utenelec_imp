# UtenInput (通用输入框)

> 源码：[uten_input.dart](../../lib/components/inputs/uten_input.dart)。文本、密码、数字等通用输入，带客户端校验与全站框内提示约定。

## 参数速查

| 参数 | 说明 |
| --- | --- |
| `label` | 框外上方标签；`required: true` 时附红 `*` |
| `hint` | 框内占位文字，输入后消失 |
| `info` | 字段静态说明，收进框内信息图标，悬停、点击或键盘聚焦查看 |
| `errorMessage` | 外部字段错误，显示框内错误图标和红框，完整内容保留 live-region 语义 |
| `autofilled` / `warningMessage` | 历史或默认带出值使用黄框、浅黄底和框内警告图标；可传入具体来源说明 |
| `required` | 必填标签红 `*`；空值红框，填好恢复 |
| `validator` | 原生表单校验，与外部错误共用框内提示，不改变 `FormState.validate/reset` 行为 |
| `isPassword` / `obscureText` | 密码输入；`isPassword` 提供可见切换按钮，与提示图标共存 |
| `inputFormatters` | 字段级输入约束；中文自然语言字段通常不应设置 |
| 其余 | `controller` / `keyboardType` / `maxLines` / `enabled` / `focusNode` 等常规项 |

## 字段提示

| 内容 | 通道 | 视觉 |
| --- | --- | --- |
| 静态说明 | `info:` | 框内信息图标 |
| 校验错误 | `errorMessage:` / `validator` | 框内错误图标和红框 |
| 预填提醒 | `autofilled/warningMessage`；裸装饰使用 `applyAutofillHint` | 框内警告图标、黄框和浅黄底 |

同一字段的多类消息合并到一个图标，完整内容按错误、预填、说明排序；字段下方不显示提示，也不保留消息槽高度。业务调用方在人工编辑或明确确认后清除 `autofilled`；已有单据回显不冒充学习值。空值不标黄，校验错误和必填空仍优先标红。

父组件更换文本控制器时会立即切换显示、监听和必填状态，组件只释放自己创建的控制器，避免同一页面切换记录后继续编辑上一条记录。

图标支持悬停、点击和键盘聚焦，不影响原有输入、清空或密码按钮。详见 [UtenFieldMessage](UtenFieldMessage.md)。

## 使用约束

- 优先复用本组件，不在框下额外拼接说明或错误文字。
- 直接 `TextFormField` 必须使用 `UtenInputDecoration`，并配置 `errorBuilder: utenTextFieldErrorBuilder`。
- 页面禁止原生 `helperText:` / `errorText:`；需要裸字段时使用 `info` 或 `UtenFieldMessage` 并接入装饰适配器。
- 全站 AST 源码契约检查实际字段调用，适配器内部原参数转发是唯一精确兼容例外。
