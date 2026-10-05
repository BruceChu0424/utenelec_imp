# AiChatOverlay (AI 对话框、对话设置与连续对话)

- 代码: [`ai_chat_overlay.dart`](../../lib/shared/ai/chat/ai_chat_overlay.dart)、[`ai_chat_settings_panel.dart`](../../lib/shared/ai/chat/ai_chat_settings_panel.dart)、
  [`ai_chat_models.dart`](../../lib/shared/ai/chat/ai_chat_models.dart)、[`ai_chat_repository.dart`](../../lib/shared/ai/chat/ai_chat_repository.dart)。
- 决策: [ADR-150](../99-决策记录-ADR/ADR-150-AI助手页面上下文有据作答与确认后执行.md)(页面快照、有据作答、确认卡)、[ADR-152](../99-决策记录-ADR/ADR-152-AI对话设置与连续对话.md)(对话设置、连续对话)。
- 读页面与确认卡见 [AiPageContext](AiPageContext.md); 接口契约见《AI平台接入指南》第八章。

## 一、挂载与生命周期

`MainShellPage` 用 `AiChatOverlay(currentRoute: ..., child: shell)` 包住整个壳, 右下角是可上下拖动的启动按钮, 打开后是一个最宽 440、最高 660 的浮层面板。
身份边界(用户、代办人、只读、权限集、服务器、授权纪元)任何一项变化, 整个会话状态(消息、文件、确认卡、对话 id、设置面板)都销毁重建。

## 二、标题栏按钮

| 按钮 | key | 作用 |
|---|---|---|
| 对话设置(`Icons.tune`) | `ai-chat-settings` | 在面板内切到设置页; 标题变「对话设置」, 左侧返回箭头 `ai-settings-back` 回到对话 |
| 说明 | `ai-chat-info` | 隐私、权限边界与读页面说明 |
| 新对话 | `ai-chat-new` | 有内容时先确认, 然后清空本窗口并生成新的对话 id(旧记录仍在服务端, 可在设置里清空) |
| 关闭 | — | 收起面板, 对话保留 |

## 三、对话设置(`AiChatSettingsPanel`)

设置随账号保存在服务端(`capabilities.settings`), 换设备同步; 改一项立即 `PATCH /ai/chat/settings`: 乐观更新、该行标题旁转圈、其它行等待; 失败回滚原选择, 面板顶部 `ai-settings-error` 与顶部通知提示「设置没保存成功」。

| 行 key | 控件 | 取值 |
|---|---|---|
| `ai-settings-detail` | 分段 | 全面 / 标准 / 精简 |
| `ai-settings-reasoning` | 分段 | 快速 / 标准 / 深入; 服务不支持时锁住并显示 `ai-settings-reasoning-unsupported`「当前 AI 服务不支持调整思考程度」 |
| `ai-settings-memoryTurns` | 分段 | 关闭 / 3 轮 / 6 轮 / 10 轮 |
| `ai-settings-replyLanguage` | 分段 | 跟随界面 / 中文 / English / 한국어 |
| `ai-settings-explanationStyle` | 分段 | 通俗易懂 / 专业简洁 |
| `ai-settings-sendKey` | 分段 | Enter 发送 / Ctrl+Enter 发送(说明随选择切换) |
| `ai-settings-pageAware` | 开关 | 读取当前页面(原对话框里的页面感知开关) |
| `ai-settings-showSources` | 开关 | 显示回答依据 |
| `ai-settings-showSuggestions` | 开关 | 显示推荐问题 |
| `ai-settings-confirm-always` | 只读 | 操作前确认: 始终开启 |
| `ai-settings-clear` | 危险按钮 | 清空对话记录(二次确认后 `DELETE /ai/chat/conversations`, 成功后开新对话并提示) |

设置面板是普通列(非懒加载), 每一行都能被键盘、读屏和滚动到达。

## 四、连续对话

- `_conversationId`: 进入时生成; **第一次打开对话框时**(能力已加载)才调用 `GET /ai/chat/conversations/current` 恢复最近一次对话(对话框常驻, 页面加载本身不请求; 用户已经开始新消息则不覆盖), 恢复的消息上方显示「以下是你最近的对话」; 服务端因权限变化隐藏的轮数显示为「有 N 条较早的对话因账号权限变化不再显示」; 引用数据已变化的轮次(`dataChanged`)显示问题和「这条回答引用的业务数据已经变化, 不再显示旧内容; 需要的话请重新问一次」, 不算权限变化。
- 恢复出来的确认卡(`_rememberCards(detached: true)`): 在页面上执行的卡(`execution` 不是 `SERVER`: 页面动作、带文件打开表单)标记 `AiChatCardUi.detached`, 卡上只显示「页面刷新过, 这张卡已不能执行, 请重新提问」并只给取消; 服务端执行的卡(超管授权)照常可确认。另外 `_executePageCard` 在核销前检查绑定, 没有页面绑定(`AiCaptureBinding.none`)的页面卡直接提示、不调用确认接口, 一次性提案不会被白白用掉。
- 每次提问带 `conversationId` 与界面语言 `locale`(zh/en/ko); 重试沿用原消息的对话 id。客户端不发送历史, 历史由服务端读取与截断(ADR-152)。
- 换页面不换对话: A 页问完到 B 页追问, 服务端带上之前几轮(只作记忆, 当前页面以本次快照为准)。

## 五、发送键

输入框外包一层 `Focus(onKeyEvent)`: 「Enter 发送」时 Enter 发送、Shift+Enter 换行; 「Ctrl+Enter 发送」时 Enter 换行、Ctrl/Cmd+Enter 发送。输入法组字(composing)中的 Enter 不发送; 等待回复时按键不重复发送。

## 六、回答下方

- 「依据: …」行只在「显示回答依据」打开时显示(关掉不影响服务端事实守卫); 确定性兜底说明始终显示。
- 「显示推荐问题」关闭时, 欢迎页与页面推荐的可点问题都不显示。

## 七、测试

`test/shared/ai/ai_chat_test.dart` 的「ADR-152 chat settings and conversation」组: 设置面板即改即存与忙碌态、失败回滚、不支持思考程度、Enter / Ctrl+Enter、恢复历史与新对话、只在打开对话框时恢复、数据已变化的轮次只显示问题、恢复出来的页面卡只能取消、清空、依据与推荐问题开关; 其余用例覆盖页面快照、确认卡与身份边界。辅助函数 `_togglePageAware` 经设置面板切换读页面。
