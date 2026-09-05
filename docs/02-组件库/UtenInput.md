# UtenInput（通用输入框）

> 源码：[`lib/components/inputs/uten_input.dart`](../../lib/components/inputs/uten_input.dart)
>
> 文本/密码/数字等通用输入，带客户端校验与全站字段外观约定。

## 一、参数速查

| 参数 | 说明 |
|---|---|
| `label` | 标签（框外上方；`required: true` 时附红 `*`） |
| `hint` | 框内占位提示（灰字，输入后消失） |
| `info` | **字段静态说明**：收进标签旁 ⓘ 悬停提示，不常驻框下（2026-09-04 全站约定，见 [UtenFieldMessage](UtenFieldMessage.md)） |
| `errorMessage` | 框下红字（实时校验错误，`UtenFieldMessage.error`） |
| `required` | 必填：标签红 `*` + 空值红框（`applyRequiredEmpty`），填好恢复 |
| `validator` | 与 `errorMessage` 共用统一长提示外观（`errorBuilder`） |
| `isPassword` / `obscureText` | 密码框（自带可见切换按钮） |
| `inputFormatters` | 字段级输入约束；中文自然语言字段（姓名/单位/地址）不应设置 |
| 其余 | `controller` / `keyboardType` / `maxLines` / `enabled` / `focusNode` 等常规项 |

## 二、三条消息通道（全站约定）

| 内容 | 通道 | 视觉 |
|---|---|---|
| 静态说明（怎么填、口径） | `info:` | 标签旁 ⓘ，悬停/长按弹提示 |
| 校验错误 | `errorMessage:` / `validator` | 框下红字 + 红框，live-region |
| 预填提醒 | 见 `UtenDropdownField.autofilled`（文本框暂无预填通道） | 黄框 + 框下黄字 |

## 三、约束

- 禁止绕过本组件手写 `helperText:`/`errorText:`（源码契约测试扫描 `lib/`）。
- 直接 `TextFormField` 必须接 `errorBuilder: utenTextFieldErrorBuilder`；例外须注释登记。
