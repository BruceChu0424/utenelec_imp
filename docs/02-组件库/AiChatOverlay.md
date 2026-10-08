# AiChatOverlay (AI 对话框、对话设置与连续对话)

- 代码: [`ai_chat_overlay.dart`](../../lib/shared/ai/chat/ai_chat_overlay.dart)、[`ai_chat_settings_panel.dart`](../../lib/shared/ai/chat/ai_chat_settings_panel.dart)、
  [`ai_chat_models.dart`](../../lib/shared/ai/chat/ai_chat_models.dart)、[`ai_chat_repository.dart`](../../lib/shared/ai/chat/ai_chat_repository.dart)。
- 决策: [ADR-150](../99-决策记录-ADR/ADR-150-AI助手页面上下文有据作答与确认后执行.md)(页面快照、有据作答、确认卡)、[ADR-152](../99-决策记录-ADR/ADR-152-AI对话设置与连续对话.md)(对话设置、连续对话)、[ADR-158](../99-决策记录-ADR/ADR-158-AI文件理解一次作答与按权限给出去处.md)(上传文件的回答、选项与去处)。
- 读页面与确认卡见 [AiPageContext](AiPageContext.md); 接口契约见《AI平台接入指南》第八章。

## 一、挂载与生命周期

`MainShellPage` 用 `AiChatOverlay(currentRoute: ..., child: shell)` 包住整个壳(`currentRoute` 是栈顶叶子路由 `uri.path`, 与外壳判断主 Tab 用的是同一个值, 见 [App 外壳](../03-页面/App外壳.md)), 右下角是可上下拖动的启动按钮, 打开后是一个最宽 440、最高 660 的浮层面板。
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

输入框、附件按钮和发送/停止按钮共享输入行高度，最小 48；多行输入或文字缩放增高时，两侧按钮同步增高并保持图标居中。颜色与间距沿用现有主题。

输入框外包一层 `Focus(onKeyEvent)`: 「Enter 发送」时 Enter 发送、Shift+Enter 换行; 「Ctrl+Enter 发送」时 Enter 换行、Ctrl/Cmd+Enter 发送。输入法组字(composing)中的 Enter 不发送; 等待回复时按键不重复发送。

## 六、回答下方

- 「依据: …」行只在「显示回答依据」打开时显示(关掉不影响服务端事实守卫); 确定性兜底说明始终显示。
- 「显示推荐问题」关闭时, 欢迎页与页面推荐的可点问题都不显示。

## 七、上传文件与文件回答(ADR-158)

- **能不能上传**: 服务端 `capabilities.canUploadDocument` 为 true(任何能用对话的员工)且不是只读会话时, 输入区显示附件按钮(`ai-chat-attach`), 输入框提示随之切换; 上传不再要求本人有可填的单据。
- **回答**: 气泡正文是服务端的 `summary`(是什么文件、凭什么看出来、你想做什么、能做和做不到什么、去哪里)。下面依次是:
  - 用途由 AI 推测时(`typeSource=AI`)一行灰字「文件用途是 AI 只看表头和格式判断的(具体内容没有发给 AI), 请核对」;
  - **用途选项**(`ChoiceChip`, key `ai-doc-choice-<任务 id>-<用途>`): 只在服务端要求选择(`needsChoice`)时出现, 只列本账号能填的单据(能力里的用途 + 本地权限集 + 非只读)。点一个: 用户一侧加一条「选择：<单据>」, 把**同一个文件**连同原话、原页面和所选用途重新识别一次; 这个回答下的选项随即全部变灰, 每个回答只能选一次;
  - **页面按钮**(`ActionChip`「打开<页面>」, key `ai-doc-page-<任务 id>-<页面>`): 服务端已按权限过滤, 前端显示前和点击时再过一次 `safeAiChatPath` 与路由守卫同一份判断 `locationAllowedFor`; 点后 `go` 到该页并收起对话框。只是跳转, 不填表、不写数据;
  - **做不了的事项**(key `ai-doc-blocked-<任务 id>-<序号>`): 锁形图标 + 灰字「事项：原因」, 原因是服务端写好的中文(缺什么权限或系统做不到), 只显示;
  - 确认卡: 文件回答只收 `OPEN_GUIDED_FORM`, 最多 1 张; 别的卡型不显示。
- **确认文件卡**: 核销后 `push` 对应新建页(不等待返回), 等一帧看栈顶路由: 是该表单才收起对话框、回执成功; 被转到无权限页时卡上写「当前账号没有打开这个填写页面的权限, 这张卡已作废, 请联系管理员开通后重新上传文件」, 其它没打开的情况写「填写页面没有打开, 这张卡已作废, 请重新上传文件再试」, 都回执失败、对话框不收。
- 文件回答和选项只在本次会话里; 刷新页面或身份变化后不恢复(ADR-152: 文件识别不进对话记忆)。
- 文件回答提供「继续用此文件」入口：把同一份本地文件放回可移除的附件区，保留已经输入的文字，让用户补充要求或纠正用途后重新发送。忙碌时不可用，已选了新附件时不覆盖；普通聊天不会自动绑定旧文件。新对话和身份变化照常清空文件。

## 八、测试

`test/shared/ai/ai_chat_test.dart` 的「ADR-152 chat settings and conversation」组: 设置面板即改即存与忙碌态、失败回滚、不支持思考程度、Enter / Ctrl+Enter、恢复历史与新对话、只在打开对话框时恢复、数据已变化的轮次只显示问题、恢复出来的页面卡只能取消、清空、依据与推荐问题开关; 其余用例覆盖页面快照、确认卡与身份边界。文件回答(ADR-158): 用途不明零卡且按权限出选项、点选项同一文件带用途重发且只出一张卡、选项一次有效、填不了的用途不出选项、只管人事的账号也能上传、页面按钮按路由守卫显示并跳转、做不了的事项灰字、最多一张表单卡; 真实外壳下从工作台/设置 push 的页面可见, 工作台上确认文件卡后表单在最上层才回执成功, 表单没打开(无权限页、无路由)时回执失败且对话框不收。辅助函数 `_togglePageAware` 经设置面板切换读页面。
