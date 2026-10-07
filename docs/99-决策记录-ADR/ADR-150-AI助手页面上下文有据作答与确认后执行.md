# ADR-150 AI 助手: 页面上下文、有据作答与确认后执行

- 日期: 2026-10-04。
- 状态: 已实现。服务端(A1a)与前端(A1b: 页面快照登记、通用确认卡、文件识别改确认卡)均已完成, 在克隆库 + 真实智谱 GLM 上端到端验证。迁移在本分支临时编号 V805, 集成时由编排者改号。
- 取代: [ADR-140](ADR-140-权限内对话助手与页面示例指导.md) 中「页面上下文只传规范路由与可选字段键」「模型自由文本不成为答案」两条;
  [ADR-141](ADR-141-AI业务查询与可见表单辅助填写.md) §1「模型只选择查询」、§3「识别后自动打开实际表单并填写」、§7「默认短句、列表最多 5 项」。
  ADR-140/141 的身份、部门、功能权限、对象范围、历史复核与只读工具边界继续有效。
- 依赖: ADR-133 公共 AI 平台、ADR-110 再认证、ADR-109 授权策略、ADR-017 跨 feature 只经 application.port。
- 后续修订(2026-10-05): [ADR-153](ADR-153-AI助手范围闸门与平台知识检索.md) 增加模型前的确定性范围闸门、回答出口的内部内容守卫与平台设计文档知识检索; 事实守卫对规则解释放宽为「可由用户给的数和规则来源里的数推算」, 页面与工具数据仍按本 ADR 严格; 「整页不读」中的权限管理与审计日志页并入 ADR-153 的受保护页面(系统管理与安全页面不读、不登记动作、不接受动作提案)。
- 后续修订(2026-10-05, AI 文件理解第一阶段): [ADR-158](ADR-158-AI文件理解一次作答与按权限给出去处.md) 把 §3「选用途时每个用途一张」改为**一个文件最多一张确认卡**: 用途明确且本人能填时出一张 `OPEN_GUIDED_FORM`; 用途不明时不出卡, 给可选用途的选项, 点选后同一个文件带参数 `workflow` 重新识别, 新回答再出一张。§5 文件卡的执行改为先跳转、下一帧核对表单确实在最上层才收起对话框并回执成功, 没打开就回执失败并在卡上说明原因(根因是外壳按 push 后不跟随的 `matchedLocation` 判断主 Tab, 已改按栈顶叶子路由)。另: 识别文件只要求能用对话; 结果增加识别依据、用户意图、可去页面与做不了的事项(按读者当前权限每次重算); 本地规则认不出时只把表格结构交给模型猜类型, 模型只回枚举、不选卡片页面权限。其余决定不变。
- 修订(2026-10-04): 「回答长短只看用户原话」与「多轮只带上一轮回答且只在同一页面」两条由 [ADR-152](ADR-152-AI对话设置与连续对话.md) 取代(账号设置定默认详略、本句覆盖; 对话 id 关联最近 N 轮且跨页面, 历史只作记忆不作页面事实)。其余决定不变。

## 背景

2026-10-04 用户在测试服务器反映三件事(服务器 ai_jobs 只读证据见调查报告):

1. 在「我的车间任务」问「状态的颜色有什么含义」, AI 只回了一句流程, 没说哪种颜色是什么状态。
2. 在新建销售订货单识别客户文件后, 有 11 行被标成黄框待核对(多数原因「标价为0, 要先做报价单交给财务定价」), 问「这个订单哪个产品需要再确认」回「这项暂时还不能帮你处理」。
3. 希望 AI 能「做事」, 但必须先在对话框里出一张确认卡, 用户点确认才执行, 而且执行仍走本人权限与服务端校验。整体感觉回答太短、太空。

根因是结构性的: (1) 模型只路由、从不组织回答, 回复全部来自 14 个页面约 40 条一句话说明的静态目录, 问题落不进目录就只能挑最近的一条罐头文案; (2) 页面上下文只传一个路由, 服务端看不到屏幕上的表格、状态颜色、黄框待核对、红框必填和弹窗文字, 全平台也没有机器可读的「状态 → 颜色 → 含义」图例; (3) 「简短」被写成规范(overview 只取 3 个字段、SUMMARY 删例子、工具最多 5 行), 而且 mode 由模型自选; (4) 没有通用的「提出动作 → 确认 → 执行」机制, 唯一的授权确认卡是 HMAC 令牌、10 分钟内可重放, 文件识别后又会自动跳页填表, 恰好违反了用户的新要求。

## 同行做法(调研出处)

- Microsoft Copilot(Dynamics 365 / Power Apps 的 copilot): 回答以当前表单/视图数据为上下文; 改记录类动作先给出预览, 用户点「确认」后由应用以用户身份执行([Copilot Studio Security FAQs](https://learn.microsoft.com/en-us/microsoft-copilot-studio/security-faq))。
- SAP Joule: 区分信息查找、导航与事务任务; 事务任务在执行前展示待确认的变更并要求用户确认([SAP Joule Capabilities](https://help.sap.com/docs/joule/capabilities-guide/about-this-document))。
- Salesforce Agentforce: 动作由管理员登记为封闭集合, 沿用登录用户的对象、字段与共享权限, 敏感动作要求确认([Agentforce 安全与共同责任](https://help.salesforce.com/s/articleView?id=005315874&language=en_US&type=1))。
- OWASP AI Agent Security / Prompt Injection: 页面与文件内容一律当不可信数据; 高影响动作要人参与确认、参数完整性校验、一次性核销与审计; 提示词或正则不能代替确定性的权限边界([AI Agent Security](https://cheatsheetseries.owasp.org/cheatsheets/AI_Agent_Security_Cheat_Sheet.html)、[LLM Prompt Injection Prevention](https://cheatsheetseries.owasp.org/cheatsheets/LLM_Prompt_Injection_Prevention_Cheat_Sheet.html))。

共识: 有据作答(grounded) + 来源可见; 动作来自闭合登记集; human-in-the-loop 确认后以用户身份经原路径执行; 一次性、可审计。本 ADR 按此设计。

## 决定

### 1. 页面上下文快照(通用机制, 不针对单页)

- 前端 `AiPageContextController` 挂在 PlatformTablesHost, 与 TableColumnProjectionController 同级, 按 owner + ModalRoute 登记取值回调, 只取顶层当前路由, **发送时才计算**。
- 共享组件自动登记: MasterDataTableView / UtenEditableGrid(可见列与列说明、总行数/可见/勾选数、前 30 行显示文本、按最终单元格底色 + 状态组件聚合的图例「列/值/颜色中文名/含义/计数」、标红行、红框必填空、黄框待核对及原因); 状态组件(UtenStatusBadge/UtenDocStatusPill/分段徽章); 输入组件(标签、显示值、必填空、黄框预填与原因、错误、ⓘ 说明, 密码与 obscure 不登记); UtenInlineNotice/UtenTopBannerCard/对话框正文; 页面登记的动作。
- 快照有界: 表 ≤4 × 行 ≤30 × 列 ≤12, 单值 ≤80 字, 字段 ≤60, 总 ≤24KB; 服务端 `AiChatPageSnapshot.sanitized()` 再校验一次, 超限 422(不截断), 标签禁止 UUID/网址/控制字符, 值里的 UUID/网址替换, 格式控制字符删除。
- 敏感数值默认不发送(详见 §6): 成本/毛利、工资类(应发/实发/扣减/个税/加班费/津贴/绩效…)、信用额度、证件号/银行账号/手机电话/邮箱/住址等个人信息只发标签与状态, 值、提示与说明都不发; 密码/验证码/密钥/令牌类字段整条不发。前端列/字段 `aiSensitive` 标记 + 同一张词表, 服务端按同一张词表再兜一次; 工资、人事与个人资料页面整页不读。
- 快照只在 `ai_jobs.input_bytes` 里, 任务结束即清空; 结果、审计摘要不保存快照。任务输入上限由 32KB 调到 64KB。
- 销售新建订货单识别后的 REVIEW 行与 warnings 原因必须进入快照(flaggedCells)。

### 2. 有据作答

- 页面类问题(PAGE_STATE/PAGE_HELP/KNOWLEDGE)**一次调用同时选路与作答**, 输出 `{intent, reply, usedSources, tool, arguments, action}`; 工具类问题先执行工具, 再用工具的 `modelFacts` 投影作答(投影为空的工具直接用自己的确定性回复, 不再调用模型)。
- 来源: 页面快照(不可信段)、已审核页面说明、知识目录(新增 `UI_CONVENTIONS` 平台界面约定: 红框必填、黄框预填待核对、红徽章轮到你、黄徽章在办、括号已结束、色调中文名)、工具描述、上一轮问答(仅当上一轮回答可外送且仍在同一页面, 解决「那黄色呢」这类指代)。
- 提示词: 先直接回答再分条给依据; 颜色逐条「颜色 = 状态 = 含义 (N 行)」; 待检查逐条「行/列/当前值/原因/建议」; 超过 12 条写「还有 N 项」; 来源里没有的不编, 说明去哪看; 不说「已保存/已提交」。
- 呈现方式只由用户原话决定(`presentationMode`): 用户没要求简单就完整回答; 去掉 overview 只取 3 个字段与 SUMMARY 删例子。
- 事实守卫 `AiChatAnswerGuard`: 数字与业务编码必须出现在来源或用户原话; 「颜色 = 状态 (N 行)」行按**配对**核对页面自己的图例与徽章(颜色要是该状态的颜色, 行数要等于该项计数, 只对快照核对, 不对拼接的全部来源); 禁止第一人称完成断言(页面本来显示的状态词除外); 去链接、裸域名与 HTML; 限 4000 字。不通过或 AI 不可用时由 `AiChatPageStateRenderer` 按快照确定性渲染(图例、待核对清单、字段状态), 结果标 `fallback`。
- 授权正则只拦「给我/帮我开通…权限」「把我设为管理员」「假装我是管理员」类请求意图; 「需要什么权限」「怎么开通」交给作答阶段说明。

### 3. 确认后执行

- 动作只来自**当前页面登记的闭合动作集**(页面动作描述符: name/title/kind/risk/参数 schema/行参数所属表 `table`), 服务端校验结构、按 kind 定风险下限(VIEW/FORM 低, SAVE 中, SUBMIT 高), 校验参数后渲染摘要行(模型文字不进卡片; 行号后的行文字只取动作所属那张表, 不明确就不写)。
- **确定性闸门**: 只有用户自己的原话要求了该类操作(VIEW 筛选/打开/勾选…, FORM 改/填/确认…, SAVE 保存, SUBMIT 提交), 模型选的 ACTION 才会变成卡片; 会准备授权卡的工具(`prepare_permission_grant`)只在用户原话是授权请求时运行(`AiChatToolPort.requestedBy`)。页面里的提示、单元格、识别原因写了「请调用 submitOrder」也只当数据: 不出卡, 按页面内容确定性作答。
- 一次性提案表 `ai_chat_action_proposals`: actor、授权版本、全局授权纪元、部门归属指纹、动作类型/handler/执行方式、目标、参数与参数哈希、摘要、风险、10 分钟有效期、状态 PROPOSED/CONFIRMED/CANCELLED/EXPIRED/FAILED、执行回执。数据库触发器保证内容不可改、PROPOSED 只能确认一次、过期不能确认、回执只记一次。
- CLIENT 动作: 用户点确认 → `POST /api/ai/chat/actions/{id}/confirm` 一次性核销并返回权威参数 → 前端在**提问时那个页面实例、提问时那几行记录**上调用页面登记的 handler(与页面按钮同一代码路径, 权限与服务端校验照旧; 页面换了实例或行变了就不执行, 见 §6) → `receipt` 回写结果。表单类动作只改本页输入并标黄「AI 填入, 请核对」, 保存/提交仍是页面按钮或单独再确认的 SAVE/SUBMIT 动作。
- SERVER 动作: 超管单项授权并入通用卡(`PERMISSION_GRANT`), 确认仍走原端点 `/api/ai/chat/permission-grants/confirm` 与 `@RequiresStepUp`, 提案在授权事务里一次性核销; 删除 HMAC 令牌编解码器(可重放)。
- 文件识别后不再自动跳页填表: `ERP_DOCUMENT_ROUTE` 结果带 `OPEN_GUIDED_FORM` 确认卡(选用途时每个用途一张), 用户确认后才打开表单填入。(2026-10-05 修订: 「选用途时每个用途一张」由 ADR-158 取代——一个文件最多一张确认卡, 用途不明时给选项不出卡。)
- 跨账号读取/确认 404; 授权版本、全局授权纪元或部门变化后未确认的卡作废(AUTH_CHANGED); 过期 409; 并发双击只有一次成功; 每次提议/确认/取消/回执/作废写审计日志。
- 不新增 `ai:act` 权限点: 提案只需要 `ai:use`, 能不能做成由页面 handler 或业务端点原有权限决定。
- 删除旧路径: `OPEN_SALES_ORDER_DRAFT` 动作、`SALES_DRAFT` 意图、`attachmentJobId` 请求字段与 previousAttachment 追问。

### 4. 数据外送

页面快照会把用户屏幕上看得见的客户名、货品、数量、单价等业务数据发给管理员配置的模型服务商(现为境内智谱 GLM)。这推翻了 ADR-140「不外送真实表单值」的口径, 由用户在 SPEC A1 中拍板。不外送的范围按 §6 实际执行: 敏感数值与个人信息只发标签、凭证整条不发、工资/人事/个人资料等页面整页不读、页面路由里的记录编号换成 `:id`。外送字段类别登记在[中国大陆部署与兼容性](../99-项目治理/中国大陆部署与兼容性.md) 2.3.1, 界面隐私说明(zh/en/ko `aiChatPageHint`)同步写明这几条。

### 5. 前端实现(A1b)

- **登记表**: `AiPageContextController`(`lib/shared/ai/page_context/`)挂在 `PlatformTablesHost`(按登录身份重建)。组件在 `didChangeDependencies` 里用 `AiPageSlot.attach` 登记「取值回调」(一次 map 写入, 无通知、无计算), `dispose` 注销。计算只发生在: 用户发送问题、确认卡执行前(重新取当前动作集)、对话框打开/换页/聚焦输入框时生成「将附带当前页面: 表格N行/字段M个/待核对K项」提示(下一帧, 仅对话框打开时)。
- **顶层路由**: 跳过已卸载、`TickerMode` 关闭(被不透明页面盖住、非当前分页)、未布局、祖先 `Offstage` 的条目; 取导航器嵌套最深的一层(外壳导航栏的徽章不混入页面), 同一导航器里按 overlay 绘制顺序只取最上面的路由(同导航器的弹窗/侧滑面板盖住页面时只读弹窗); 按屏幕位置排序。**全程不建立依赖**(不用 `ModalRoute.isCurrentOf`), 否则发问一次后每次进页/返回都会让表格与输入框多重建一次, 测试锁定。
- **表格**: MasterDataTableView / UtenEditableGrid 的快照逻辑放在各自的 part 文件(`*_ai.dart`), 主文件只加列参数(`legendOf` 值 -> 含义、`aiSensitive`、编辑表另有 `reviewReasonOf`)和登记/注销。图例按单元格**最终底色**(`cellColor` 或状态列自动色调)聚合, `utenNamedColor` 先按 `UtenColors` 令牌反查(实底/浅底/深字/暗色半透明叠加), 再按色相归档; `UtenStatusBadgeType.colorName` 给共享色调中文名。编辑表的黄框原因/错误/必填空由格内 `UtenTableCellHints`(新增可选 `aiCell` 身份)与 `RequiredCellFrame` 在挂载时登记探针, 发问时读取; 行号 = 屏幕上的第几行(表头筛选后可见行里从 1 起, 与 MasterDataTableView 同口径)。
- **输入**: UtenInput / UtenDropdownField / UtenDateField 登记标签、显示值、状态与原因; 密码与 obscure 不登记; 通用动作 `setField` 按标签设值并标黄「AI 填入, 请核对」(用户再改即清除)。选择器(UtenMasterPickerField 即客户/供应商字段、UtenEmployeePicker、UtenEmployeeMultiPicker)与工具栏 UtenFilterPickerField 只读登记所选名称, 不给设值动作。UtenSearchBar 提供 `searchPage`。状态组件(UtenStatusBadge / UtenDocStatusPill / UtenSegmentBadgeLabel)、UtenInlineNotice、有朗读标签的 UtenTopBannerCard、文件识别进度横幅 AiGuidedFileBanner、UtenDialog.show 纯文字正文、UtenAppBar 标题均自动登记。MasterDataTableView 整行底色反查为红的行记 `FLAGGED`。
- **前端先截**: 与服务端同一组上限, 另留 2KB 字节余量(≤22KB), 超出依次减行/待核对/图例/字段/提示并标 `truncated`; 标签含 UUID/网址整条丢弃, 值里替换, 控制与格式字符清掉; 敏感列/字段只发标签并写 `withheld`。
- **页面动作第一批**: MasterDataTableView 通用 `filterTable`/`selectRows`/`openRow`; 输入组件通用 `setField`; 搜索框 `searchPage`; 销售订货/报价编辑页 `setLineField`(数量/单价(报价)/折扣/备注/文件型号/文件品名, 值按页面同一规则校验; AI 改值不清除识别黄标, 不算人工核对)、`confirmReviewLine`(与核对面板的「确认」同口径: 只去掉「货品没对准」那段提醒并记为人工确认, 保存时学习客户料号, 卡片标题写明; 单位换算、金额对不上、重复货品、定价提醒照样保留, 只有这类提醒的行不能「确认」, 要核对后直接改)、`saveDraft`(调用页面保存按钮的 `_save`, 以服务端保存成功计数判断成败)。销售识别的待核对原因(含标价/单位/金额对不上/重复货品 warnings; 后两种原先只在核对面板显示, 导入后行上没有黄标, 现与面板「需要核对」同源)经 `reviewReasonOf` 进入 `flaggedCells`。
- **确认卡**: `AiChatActionCard` 显示服务端摘要行、风险提示、再认证提示、到期倒计时(仅卡片可确认时每秒刷新)、取消/确认(`UtenActionButton` 防连点; 同一时间只有一张卡在执行)、执行中、成功/失败回执、身份变化作废; 网络结果不明只给「查看结果」(`GET`), 不重放确认。CLIENT 执行顺序: 当前顶层路由 == 卡片 `route` 且页面仍登记该 handler → `confirm` 取权威参数 → `AiPageContextController.run`: 同一页面实例(导航器 overlay 条目 + 页面级登记)、`checkedArgs` 按页面当前声明再校验、行参数按提问时绑定的记录核对仍在原屏幕行上 → handler 收到那几条记录 → `receipt`。`OPEN_GUIDED_FORM` 确认后才校验来源文件与识别任务并打开新建页; `PERMISSION_GRANT` 调原授权端点, 网络层弹密码再认证, 关掉密码框卡片仍可确认。删除旧 `OPEN_SALES_ORDER_DRAFT` 分支、授权专用弹窗、识别后自动跳页。
- **对话框其它**: 回答下方显示「依据: …」, 依据含页面内容或为确定性整理(`fallback`)时加「以页面为准」/「AI 暂时没回上来, 以下按页面内容整理」; 隐私说明(zh/en/ko)改为如实说明会读取当前页面可见的表格和字段并发给管理员配置的 AI 服务(敏感金额默认不发); 使用审计面板给 PAGE_STATE/ACTION 加中文用途名。
- **共享组件影响**: 不改既有行为与外观; 唯一可见差异是 AI 填入后的黄框(只在用户确认卡片之后出现)。

### 6. 审查后加固(2026-10-04, 同日)

审查(A1a 服务端 + A1b 前端)指出的问题全部从根上改, 不留兼容分支:

- **颜色配对**: 生产环境的来源里总带着平台界面约定(列出所有颜色和通用状态词), 逐词核对会放过对调的配对。守卫改为把每条颜色行当作「颜色, 状态, 行数」三元组, 只对快照自己的图例与徽章核对; 对不上就走确定性渲染。
- **只有用户要求才做事**: 页面内容(提示、弹窗、单元格、客户文件识别原因)现在会到模型那里, 所以 ACTION 与准备授权卡的工具都加了**确定性闸门**(看用户原话, 不看模型选择、不看页面文字), 见 §3。
- **路由不外送记录编号**: 发给模型的只是页面形状, 含数字或长十六进制的段换成 `:id`(`/expense/:id/edit`)。
- **敏感兜底的覆盖面**: 词表扩到工资类、个人证件/账号/联系方式; 凭证类(密码、口令、验证码、密钥、令牌)整条不发; 敏感列/字段的 `message`、`info`、待核对原因一并不发; 待核对的行文字服务端按样本行(敏感格已清空)重算, 样本外的行只有在表里没有敏感列时才保留前端给的行文字; 前端两个表格的行文字也跳过敏感列(用户可以把成本列拖到最前)。工资、人事、员工档案、个人资料、改密码、权限管理、审计日志页面(`/payroll`、`/hr`、`/employee`、`/profile`、`/change-password`、`/admin/permissions`、`/admin/audit-logs`)前后端同一张清单, 整页不读, 只回答问题本身。现有真实页面补了列标记: 工资审核/工资条列表的应发/扣减/实发, 车间内料报表的单价/金额/结算时金额/材料金额/单件材料成本, 库存洞察的库存金额, 货品成本测算的单价/金额/费用。
- **卡片绑定页面实例与行**: 每次发问时登记一次「绑定」: 页面实例(导航器 overlay 条目 + 页面级登记)与行参数所属表的记录身份(MasterDataTableView 按 `idOf`, 编辑表按行对象)。确认后只在同一页面实例上执行, 行参数必须仍指向提问时那条记录, handler 直接收到记录(`AiActionCall.row/rows`), 不再按执行时的下标取行。删除/插入/排序/筛选后、保存后又开了一张同类新单、或从没有绑定的消息来的卡, 一律不执行并说明原因。行参数的取值范围按提问时的行数核对, 不按执行时。
- **编辑表行号**: `no` 改为屏幕上的第几行(筛选后可见行), 与 MasterDataTableView 一致; 动作描述符带 `table`(快照里第几张表), 卡片行文字只从这张表取。
- **徽章**: 标签按服务端同口径截断/丢弃(空、编号、网址), 未知色调丢掉, 一个超长徽章不再让整页快照 422。
- **确认待核对行**: 见 §5 页面动作。货品对应提醒在识别补丁里单独记下(`goodsMatchReason`, 草稿保存也带), 确认只清它。
- **重试**: 关掉页面感知后, 之前消息里存的快照、路由与绑定一并丢掉; 重试只发问题。
- **其它**: 清理结果幂等(withheld 输出也封顶 30, 任务服务二次校验不再 422); 在页面上作答的回答不论引用了什么都记下页面, 只在同一页面带入下一轮; 外送事实合约测试改为扫描全部 `AiChatToolPort` 实现; `server/logs-*.out` 进 `.gitignore`。

## 后果

- 正面: 颜色、待核对、字段、弹窗类问题从结构上可答; 回答完整且有来源; AI 能提出操作, 但每一步都要本人确认、一次性核销、留审计; 授权卡不再可重放; 文件识别符合「先确认再做」。
- 负面与风险: 输入 token 明显增加(实测页面类问题输入约 4k token, 单次约 6-18 秒); 事实守卫降低但不能杜绝幻觉(界面注明以页面为准); 共享组件登记面大, 必须发送时才计算, 不影响滚动与重建性能; 页面动作的执行正确性取决于前端登记的 handler(与页面按钮共用代码路径以降低风险)。
- 迁移: V805(临时号) `ai_chat_action_proposals`, 业务清空归 CLEAR, 审计分类 NONE(各状态变化写显式审计事件)。

## 验证(前端)

- `test/shared/ai/ai_page_context_test.dart`(15): 颜色名反查、值清理与上限、表格快照与图例计数(含含义、敏感列不发值)、通用表格动作(筛选/打开)、编辑表 REVIEW/FLAGGED/REQUIRED_EMPTY/格内黄框、输入登记且密码不登记、AI 填入标黄与用户改动清除、整行标红与筛选字段/行内提示、只取顶层路由(push/pop、同导航器弹窗)、Offstage 不读、发问后进页/返回不多重建(去掉 isCurrentOf 依赖, 换回旧实现时该用例失败)、超大页面字节预算与截断、销售订货识别原因进入 flaggedCells 与 AI 改数量标黄; 审查后加固: 敏感列移到最前与整行标红时行文字不带敏感值、敏感字段的提示与说明不发、凭证字段整条不发、徽章超长/空标签/未知色调按服务端同口径处理、卡片只在原页面实例与原行上执行(排序后行变、另开同类页面、无绑定都拒绝)、工资/人事页面清单与词表。
- `test/features/sales/intake/sales_intake_apply_test.dart`: 金额对不上/重复货品提醒进入导入行的待核对原因; 货品对应提醒单独记下, 确认只清它, 单位/金额提醒保留, 草稿往返不丢。
- `test/features/sales/pages/sales_doc_edit_intake_test.dart`: 真实销售编辑页经控制器执行 `setLineField`/`confirmReviewLine`(单位提醒行确认被拒且原因保留), 删掉上面一行后旧卡片按「第N行已经不是提问时那一行」拒绝, 重新提问后按新行执行。
- `test/features/payroll/payroll_review_page_test.dart`: 真实工资审核页的快照里没有任何金额(应发/扣减/实发只发标签)。
- `test/shared/ai/ai_chat_test.dart`(58): 卡片解析拒绝未知类型/编号/路由、仓库发送路由 + 快照与 UUID 端点、附带提示与页面感知关闭不发、依据与兜底提示、页面动作确认后执行并回执、双击只确认一次、取消、过期、错页本地拒绝、handler 失败回执原因、AUTH_CHANGED 作废、网络不明只查不重放、超管授权卡、身份变化清卡、未知/旧动作不渲染、文件识别不自动跳转(确认后才打开, 含权限撤销时失败回执), 关掉页面感知后重试只发问题, 工资页只附带问题, 同一路由换了页面实例时卡片不执行, 以及原有投递/重试/布局/身份边界用例。
- 真实链路记录见[治理验证记录](../99-项目治理/AI助手验收合集.md#ai-20261004-frontend)。

## 验证(服务端)

- 单元: `AiChatPageSnapshotTest`(超限、控制字符、UUID/网址标签、注入文本只当数据、敏感数值不发送、工资/个人信息/凭证词表与提示/原因/行文字兜底、清理幂等、工资人事路由整页不读、动作所属表校验、动作描述符闭合)、`AiChatAnswerGuardTest`(含全部来源里带平台界面约定时颜色对调仍被拦、行数不符、裸域名剥离)、`AiChatDialogueSupportTest`(操作请求闸门)、`AiPermissionGrantToolTest`(授权意图闸门)、`AiChatOutboundFactsContractTest`(类路径扫描全部 AiChatToolPort 实现)、`AiChatPageStateRendererTest`(车间任务 8 种颜色、销售 12 条待核对 + 还有 N 项)、`AiChatJobHandlerTest`/`AiChatAdversarialSecurityTest`(模型自带动作/链接/完成断言不会变成卡片或答案, 未登记动作不出卡; 页面文字要求提交或授权时只读问题不出卡、不跑授权工具; 记录 UUID 不进模型请求; 在页面上作答的回答不带到别的页面; 多表时卡片行文字只取所属表)、`AiDocumentRouteHandlerTest`(识别结果只给确认卡)、授权卡三件套测试。
- PostgreSQL: `AiChatActionProposalPostgresTest`(并发双击只成功一次、回执一次、取消、过期、身份变化作废、触发器拒绝改内容与过期确认、快照 422、授权卡要再认证且只能用一次)、`AiDocumentRoutePostgresTest`、`AiChatProviderRoutingPostgresTest`、`AiChatPostgresTest`。
- 真实链路(8086 + 克隆库 + 智谱 GLM): 车间任务页问颜色列出 8 种「颜色 = 状态 = 含义 (N 行)」; 销售订货页问待检查列出 4 行 REVIEW 与原因及客户红框、币种黄框; 「把第3行数量改成100」出卡片, 确认/重复确认 409/回执; 非超管账号跨账号确认 404、取消后确认 409、受保护页面 403、授权请求本地拒绝; 超管授权卡 SERVER + 再认证。
