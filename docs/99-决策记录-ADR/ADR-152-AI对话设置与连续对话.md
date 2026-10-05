# ADR-152 AI 对话设置与连续对话

- 日期: 2026-10-04。
- 状态: 已实现(服务端 + 前端 + 迁移 + 测试), 在克隆库 uten_imp_wai + 后端 8086 + 真实智谱 GLM 上端到端验证。迁移在 AI 轨道临时编号 V799, 集成时由编排者改号。
- 修订: [ADR-150](ADR-150-AI助手页面上下文有据作答与确认后执行.md) 中「回答长短只看用户原话(presentationMode)」与「多轮只带上一轮回答, 且只在同一页面」两条, 由本 ADR 的「设置默认 + 本句覆盖」与「对话(conversation)记忆」取代; ADR-150 的页面快照、有据作答、事实守卫、确认卡与执行边界全部继续有效。
- 扩展: [ADR-133](ADR-133-公共AI平台与服务商可配置.md) 的服务商能力开关「关闭深度思考方式」扩展为「思考参数写法」, 公共平台请求增加与服务商无关的思考程度。
- 依赖: ADR-017 跨 feature 只经 application.port、ADR-108 偏好随会话快照带回、ADR-110 身份戳。
- 后续修订(2026-10-05): [ADR-153](ADR-153-AI助手范围闸门与平台知识检索.md) 规定被范围闸门拒绝的轮次不带入对话记忆; 回答语言设置同样决定拒绝文案与诚实兜底的语言。
- 后续修订(2026-10-05, ADR-153 第七节): 思考程度的账号默认值由「标准」改为「快速」(标准档每题 20-50 秒, 快速档 5-12 秒); 用户这句话要求详细分析时这一问至少按「标准」; 被模型或服务商内容审核拒绝的轮次同样不进记忆。

## 背景

用户原话(2026-10-04): 「在 AI 对话框这里弄一个设置的按钮, 里面可以设置回答是全面的、标准的、精简的(有些人想问详细一点), 还有思考的程度之类的, 其他的你想想有什么可以设置的, 让用户更个性化一点。然后一个对话框的上下文最好可以关联起来, 问一个问题, 下一个问题和上一个问题能够关联下来, 不会只局限于一个问题。」

ADR-150 之前的实现: 回答长短只由这一句话里的「简单点/举例/步骤」决定; 多轮只带「上一轮」且仅在同一页面, 换页面就断; 没有任何按人保存的偏好; 公共 AI 平台对所有用途都发「关掉思考」(或不发), 用户无法要「想深一点」。

## 同行做法

- ChatGPT「自定义指令 / 个性化」与 Claude「风格(Styles)/ 偏好」: 回答长度与语气是账号级偏好, 单条消息里明说的要求优先于偏好; 记忆可关闭、可清空。
- Microsoft Copilot(M365): 同一会话内多轮关联, 「新对话」开新会话; 会话历史按用户隔离、可删除; 跨应用(页面)延续上下文, 但当前文档/页面内容只取当前的。
- 各服务商的思考控制: OpenAI `reasoning_effort`(none/minimal/low/medium/high); DeepSeek `thinking.type` + `reasoning_effort`(low/high/max, 关思考时不能带 reasoning_effort); 智谱 GLM `thinking.type` + `reasoning_effort`(GLM-5.3 只认 low/high/max 且不能关思考; Anthropic 兼容端点按 `output_config.effort` 定档、忽略 `budget_tokens`); 通义 `enable_thinking` + `thinking_budget`(百炼错误码: 非流式调用 `enable_thinking` 必须为 false, 开思考时不支持 JSON 模式); Claude Opus 4.5 / Sonnet 4.6 及以上 `output_config.effort`(新模型拒绝 `budget_tokens`; Haiku 4.5、Sonnet 4.5 及更早拒绝 effort); OpenAI GPT-5 系列只在 `reasoning_effort=none` 时接受 `temperature`。出处: [智谱 深度思考](https://docs.bigmodel.cn/cn/guide/capabilities/thinking)、[智谱 核心参数](https://docs.bigmodel.cn/cn/guide/start/concept-param)、[DeepSeek Thinking Mode](https://api-docs.deepseek.com/guides/thinking_mode/)、[阿里云百炼 深度思考](https://help.aliyun.com/zh/model-studio/deep-thinking)、Anthropic Messages API 文档(effort 与 adaptive thinking)。

共识: 偏好按账号保存、本句要求优先; 对话按会话关联、可开新会话、可清空; 思考深度用与服务商无关的档位表达, 各家参数在适配层映射, 不支持的就不发。

## 决定

### 1. 对话设置(按账号保存, 换设备同步)

存放: `user_preferences` 键 `ai.chat.settings`(功能自管键)。读写只经 `GET /api/ai/chat/capabilities`(随能力一起带回 `settings` 与 `reasoningEffortSupported`)和 `PATCH /api/ai/chat/settings`(一个或几个字段, 白名单 + 枚举校验, 422 拒绝未知字段/取值/类型)。通用偏好接口 `PUT /api/user/preferences/{key}` 拒绝 `ai.` 开头的键, 防止绕过校验。存量值逐字段宽松读取(坏值退回默认), 新账号用默认值。设置变化属于个人偏好, 不写业务审计(`@AuditAutomaticWrite`)。

| 设置 | 取值(默认加粗) | 服务端怎么用 |
|---|---|---|
| 回答详略 `detail` | 全面 / **标准** / 精简 | 提示词长度说明: 全面=每项给依据、需要时给举例(标「举例(假设)」)和下一步, 最多 30 项; 标准=先结论再分条, 最多 12 项; 精简=一两句结论, 需要列举时每项一行不解释, 最多 6 项。用户这句话里说「简单点/详细点/展开说/不要展开」时只对这一句改用对应档(`AiChatPresentation`)。全面档事实守卫长度上限放宽到 6000 字。工具的「详细回复」只在全面档用。 |
| 思考程度 `reasoning` | **快速** / 标准 / 深入 | 映射为与服务商无关的 `AiReasoningEffort`: 快速=OFF、标准=MEDIUM、深入=HIGH(见第 3 节)。快速档回答输出上限 4096。默认快速(ADR-153 第七节, 原默认标准); 用户这句话写明「详细分析/一步一步」等时这一问至少按标准。 |
| 读取当前页面 `pageAware` | **开** / 关 | 替代对话框里原来的页面感知开关, 语义不变。关时服务端也丢掉请求里的页面上下文(前端漏发也不读)。 |
| 显示回答依据 `showSources` | **开** / 关 | 只隐藏回答下方的「依据」行; 服务端照样做事实守卫。兜底说明(「这是按页面整理的」)照常显示。 |
| 连续对话记忆 `memoryTurns` | 关闭 / 3 / **6** / 10 | 服务端带入的最近轮数(第 2 节); 客户端不能传更大的值。 |
| 回答语言 `replyLanguage` | **跟随界面** / 中文 / English / 한국어 | 提示词写明回答语言; 跟随界面时用每次提问附带的界面语言 `locale`(zh/en/ko)。编码、名称、页面标签与状态词保持原文。 |
| 发送方式 `sendKey` | **Enter 发送**(Shift+Enter 换行) / Ctrl+Enter 发送(Enter 换行) | 纯前端; 输入法组字中的 Enter 不发送。 |
| 表达方式 `explanationStyle`(新增) | **通俗易懂** / 专业简洁 | 通俗=顺带解释业务用词(新同事); 专业=直接用术语(熟手)。 |
| 显示推荐问题 `showSuggestions`(新增) | **开** / 关 | 对话框里可点的推荐问题(欢迎页与页面推荐)是否显示。 |
| 操作前确认 | 始终开启(只读展示) | AI 做任何操作都先给确认卡(ADR-150), 不是设置项, 不能关。 |
| 清空对话记录 | 按钮(二次确认) | 第 2 节。 |

新增两项的理由: 「表达方式」直接对应用户说的「有些人想要详细」之外的另一种差异 —— 新同事需要术语解释、熟手嫌啰嗦; 「显示推荐问题」让熟手收起不需要的按钮。两项都只改措辞或界面, 不影响读取范围、权限或执行。没有加任何能打开敏感字段、扩大数据范围、跳过确认或改变服务商的开关。

### 2. 连续对话(conversation)

- 前端维护当前对话 id(UUID): 打开/关闭对话框不变; 「新对话」生成新 id; 刷新页面后**第一次打开对话框时**调用 `GET /api/ai/chat/conversations/current` 恢复最近一次对话并显示历史消息(对话框常驻, 不随每次页面加载请求)。每次提问带 `conversationId`(不带时服务端新开一个, 并在结果里返回)。旧的 `previousJobId` 删除。
- 存储复用 `ai_jobs`: 聊天结果里记 `conversationId`、`pageTitle` 与内部 `_route`(不回给读者)。不新建表 —— 保留期、本人隔离、使用审计与清理全部沿用 AI 任务(结果 48 小时后随任务归档)。
- 服务端组装上下文(`AiChatConversation`): 取同一账号、同一对话 id、成功且未归档的最近 N 轮(N = 设置), 每轮都按「读历史」同样重新校验(身份戳 auth_version/epoch/部门指纹不变、域可见、工具/页面/知识仍可用), 不通过的计数为 hidden, 不带入、不显示。按时间顺序给模型: 每轮「页面标题 + 路由形状(记录 id 换成 :id) + 用到的工具名 + 问 + 答」。总量 ≤ 8KB(UTF-8, 按实际发出的文本计, 含每轮 `Turn k ` 前缀与换行): 最新一轮回答最多 3000 字节、更早的每轮 1200 字节, 超出从最早的整轮开始丢并写「(更早的对话已省略)」。
- 「数据变了」和「权限变了」分开: 工具回答在读历史时还要由工具复核它引用的业务数据(`authorizeResultRead`, 会重查业务)。数据有任何变动(正常的出入库、报工、待办变化)都会让复核不通过, 这**不是**权限变化: 这一轮照常带入问题、工具名和查询条件, 回答换成「(这条回答引用的业务数据已变化，未带入；需要时请重新查询)」——「那够做 100 个吗」仍能接上上一问, 「详细点」仍按原条件重查最新数据, 旧数值永远不回来; 恢复显示时这一轮只显示问题和一句说明。只有身份戳、域、工具、页面、知识不通过才算 hidden(「因账号权限变化不再显示」)。单条任务读取(`GET /api/ai/jobs/{id}`)仍按原规则直接拒绝。
- 复核按请求记忆: 一次恢复或一次组装记忆里, 同一身份戳、域、工具、页面、知识条目、工具证据各只查一次, 确认卡按一个身份戳一次查回; 组装记忆时只有 8KB 预算还有空间才复核下一轮。
- 跨页面关联: 在 A 页问完到 B 页追问「那这个呢」, 模型能看到前几轮。但只有当前页面快照是「页面事实」, 历史只是对话记忆:
  - 提示词: 历史放在单独的 `CONVERSATION HISTORY` 段, 说明它可能来自其它页面、是当时的情况, 不得当作当前页面内容; 哪一行用到历史就在那一行(或列表的引导行)里说「刚才说的/之前查到的/上一页的」; 没带入的回答不得猜, 需要时重新查。
  - 事实守卫: 回答里的数字或编码只出现在历史里(不在当前页面、资料或用户这句话里)时, **所在那一行**(列表项看它的引导行)必须带记忆标记(「刚才说的/之前查到的/前面列出的/上一页的/上一轮/earlier/as mentioned…」), 否则判 `MEMORY_AS_FACT` 退回确定性回答。「发货之前」「在此之前」「before」这类时间说法不算标记, 别的行里提到过去对话也不算; 历史从不为新数字背书。
- 安全:
  - 只带「可外送」的回答(`replyShareable`): 工具结果没有可外送事实投影(成本、信用、人事、授权等)的回答只带问题, 写「(该回答含敏感数据，未带入)」; 确认卡只带卡片标题。
  - 只读本人的: 查询条件始终是 `submitted_by_user = 当前账号`, 别人的对话 id 在自己名下查不到任何东西。
  - 身份变化后旧对话不再带入、也不再显示(只给出「有 N 条较早的对话因账号权限变化不再显示」)。
  - 记忆关闭(0 轮)时不读历史。
- 「新对话」只是开新 id, 不删任何东西。「清空对话记录」(`DELETE /api/ai/chat/conversations`)把本账号全部聊天任务归档(`archive_reason = AI_CHAT_CLEARED_BY_USER`): 不再恢复、不再带入; 管理员的 AI 使用审计行仍在(审计不按归档过滤), 平台的永久生命周期规则不变。
- 文件识别(`ERP_DOCUMENT_ROUTE`)仍是独立任务, 不进入对话记忆。

### 3. 公共 AI 平台: 与服务商无关的思考程度

- `AiCompletionPort.AiCompletionRequest` 增加 `reasoningEffort`(`DEFAULT/OFF/LOW/MEDIUM/HIGH`), 旧构造器默认 `DEFAULT`; `AiAvailability` 增加 `supportsReasoningEffort`; 任务上下文转发请求时保留该字段(`withJobId`)。
- `ai_providers.thinking_control` 从「关闭深度思考的写法」改为「思考参数写法」, 新增 `ZHIPU`、`ANTHROPIC_EFFORT`(V799 放宽 CHECK, 已有的智谱配置由 NONE 改为 ZHIPU)。预设默认: 智谱=ZHIPU, Claude=ANTHROPIC_EFFORT。
- 「能否调整」只有一个判定 `AiReasoningParams.supported(runtime)`: 写法 + 生效协议 + 模型三者都接受才算; 不能调整时一律按 DEFAULT 写请求体、不加额度、不改超时, 所以账号里存的任何档位(包括换服务商之前存的「快速」)都不会改变请求, 也不会让请求被拒。
- 唯一映射表 `AiReasoningParams`(协议客户端写请求体、网关放宽/收紧上限与超时、调用日志都用它):

| 写法(协议) | DEFAULT(识别等用途, 行为不变) | OFF(快速) | LOW | MEDIUM(标准) | HIGH(深入) |
|---|---|---|---|---|---|
| DEEPSEEK(OpenAI 兼容) | thinking disabled | thinking disabled | enabled + reasoning_effort low | enabled + high | enabled + max |
| ZHIPU(OpenAI 兼容) | 不发 | enabled + low(5.3 关不掉思考) | enabled + low | enabled + high | enabled + max |
| ZHIPU(Anthropic 兼容端点) | 不发 | output_config.effort low | low | high | max |
| DASHSCOPE(不可调整) | enable_thinking false | false | false | false | false |
| OPENAI_REASONING | reasoning_effort none | none | low | medium | high |
| ANTHROPIC_EFFORT(Opus 4.5 / Sonnet 4.6 及以上) | 不发 | output_config.effort low | low | medium | high |
| ANTHROPIC_EFFORT + 不认 effort 的模型(Claude 3、Haiku 4.x、Sonnet 4/4.5、Opus 4/4.1) | 不发 | 不发 | 不发 | 不发 | 不发 |
| NONE / 写法与协议不匹配 | 不发 | 不发 | 不发 | 不发 | 不发 |

- 通义: 百炼文档的错误码写明「非流式调用 enable_thinking 必须为 false」「开思考时不支持 JSON 模式」, 本平台所有调用都是非流式 JSON, 所以通义写法只用来关思考, 报告为不支持调整。
- OpenAI: GPT-5 系列只在 `reasoning_effort=none` 时接受 `temperature`, 所以带了 low/medium/high 时不发 temperature(管理员的「固定输出」开关照旧只管 none 档); DeepSeek 开思考时 temperature 不生效, 也不发。
- Claude: Haiku 4.5、Sonnet 4.5 及更早的模型带 `output_config.effort` 直接 400, 按模型名(含云厂商前缀)自动不发; 名单外的新模型按支持处理, 由「测试连接」的「思考程度」一步实测兜底。

- 不发 `budget_tokens`(GLM 忽略, 新 Claude 模型 400)。支持调整时: 回答上限之外另给思考额度(LOW +2048、MEDIUM +4096、HIGH +16384), 但单次输出**不超过管理员配置的「最大输出长度」**(单次输出含思考的硬上限, 也是模型上限与成本上限; 想给「深入」更多空间由管理员调大); 超时 OFF 收紧到 ≤60 秒, HIGH 放宽到配置的 1.5 倍(≤240 秒, 任务租约在调用中自动续)。不支持时一律不改。调用方只按回答需要给上限(对话固定 8192, 长短由详略决定, 不随思考档缩放)。
- 「测试连接」: 能调整时多一步「思考程度」, 按对话默认档「标准」用同一套写法实测一次; 服务商拒绝(400/404) = 模型不认思考参数, 判失败并提示改为「不发送」或换模型; 超时、限流只提示。
- 网关在明确要求了思考程度时写一行调用日志 `AI call reasoning: purpose, provider, effort, params=[...], maxOutputTokens, timeoutSeconds`(只有参数名与档位)。
- 服务端能力 `reasoningEffortSupported` 告诉前端; 不支持时设置面板锁住该项并显示「当前 AI 服务不支持调整思考程度」。

### 4. 前端

- 对话框标题栏新增「对话设置」图标按钮(三语 tooltip), 设置在对话框内以面板形式展开(返回箭头回到对话), 不另开浮层(对话框本身已是右下角浮层, 叠第二层抽屉会遮挡并增加身份切换时的清理面)。每项即改即存: 乐观更新、该行转圈、其它行等待; 失败回滚原选择并在面板内与顶部通知提示。
- 原「读取当前页面」开关从对话框移入设置; 对话框保留一行当前页面标题(关闭时显示「未读取当前页面(可在对话设置里打开)」)。
- 「新对话」按钮生成新对话 id(有内容时先确认, 文案说明旧记录仍保留、可在设置里清空); 刷新后第一次打开对话框时恢复最近对话并标注「以下是你最近的对话」; 数据已变化的轮次显示问题和「这条回答引用的业务数据已经变化, 不再显示旧内容」。
- 恢复出来的确认卡: 在页面上执行的卡(页面动作、带文件打开表单)绑定的页面实例已不在, 只显示「页面刷新过, 这张卡已不能执行」并只给取消, 不会点确认时先用掉一次性提案再失败; 服务端执行的卡(超管授权)照常可确认。

## 影响

- 接口: `POST /api/ai/chat/messages` 删 `previousJobId`, 增 `conversationId`(可省略)与 `locale`; 结果增 `conversationId/pageTitle/detail`; 新增 `PATCH /api/ai/chat/settings`、`GET /api/ai/chat/conversations/current`、`DELETE /api/ai/chat/conversations`; capabilities 增 `settings`、`reasoningEffortSupported`。
- 数据外送(见《中国大陆部署与兼容性》): 新增「同一对话最近 N 轮的问题与可外送回答(≤8KB)」与「回答语言/详略/表达方式等提示」; 敏感工具回答、页面快照原文不进入历史。
- 成本: 记忆使每次提问输入多约 0-2k token; 深入档输出与耗时增加(实测 GLM: 快速 3.1 秒/172 输出 token, 深入 12.2 秒/889 输出 token)。

## 审查修复(2026-10-04)

A2 只读审查的 10 条发现与处理(详见治理验证记录):

1. 通义默认「标准」档发 `enable_thinking=true` + 非流式 + JSON 模式 → 400: 通义写法改为只关思考、不可调整(见上表)。
2. OpenAI 预设 `temperature:0` + `reasoning_effort` 非 none → 400: 带 effort 时不发 temperature。
3. Claude 预设下选 Haiku 4.5 → 每问 400: 按模型名自动不发 effort; 连接测试新增「思考程度」实测一步。
4. 工具回答在数据变动后被当成「权限变化」隐藏、追问接不上: 改为只丢旧回答, 保留问题与查询条件(见第 2 节)。
5. 恢复/记忆每轮单独复核(N+1): 改为按请求记忆复核、记忆只在预算有空间时复核、恢复改为第一次打开对话框时才请求。
6. 思考额度叠加在管理员「最大输出长度」之上: 改为不超过该配置。
7. 记忆标记按整段回答判定(「发货之前」也算): 改为按行(列表看引导行), 排除时间说法。
8. 恢复出来的页面确认卡点确认会先用掉一次性提案: 改为只读并只给取消, 没有页面绑定时核销前就拦下。
9. 8KB 预算没算 `Turn k ` 前缀: 改为按实际发出的文本计。
10. 不支持思考程度的服务商上, 存着的「快速」仍把输出上限压到 4096: 对话不再按思考档缩放输出上限, 不能调整时什么都不改。

## 验证

- 后端: `AiChatSettingsTest`、`AiChatPresentationTest`、`AiChatConversationTest`(含前缀计入预算、数据变化只带问题)、`AiReasoningParamsTest`(含通义不开思考、OpenAI 不带温度、不认 effort 的 Claude 模型、输出上限不超配置)、`AiConnectionTesterTest`(思考程度一步)、`AiChatAnswerGuardTest`(记忆标记按行、时间说法不算、单行多对颜色)、`AiChatJobHandlerTest`(详略/语言/思考程度/跨页面记忆/敏感回答/身份变化/记忆关闭/页面读取关闭)、`AiChatConversationPostgresTest`(设置白名单与通用偏好拒写、跨页面三问、恢复、他人隔离、清空、身份变化、思考参数到达服务商)。
- 前端: `test/shared/ai/ai_chat_test.dart` 新增 ADR-152 组(设置面板即改即存/忙碌/失败回滚、不支持思考程度提示、Enter 与 Ctrl+Enter、恢复历史与新对话、清空、依据与推荐问题开关)。
- 真实链路记录: [2026-10-04 AI 对话设置与连续对话验证](../99-项目治理/2026-10-04-AI对话设置与连续对话验证.md)。
