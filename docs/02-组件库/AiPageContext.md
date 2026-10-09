# AiPageContext (AI 助手读页面与确认卡)

> 源码: [ai_page_context.dart](../../lib/shared/ai/page_context/ai_page_context.dart)、
> [ai_page_snapshot.dart](../../lib/shared/ai/page_context/ai_page_snapshot.dart)、
> [ai_chat_action_card.dart](../../lib/shared/ai/chat/ai_chat_action_card.dart)、
> [uten_color_name.dart](../../lib/components/data_display/uten_color_name.dart)。
> 决策: [ADR-150](../99-决策记录-ADR/ADR-150-AI助手页面上下文有据作答与确认后执行.md)、[ADR-158](../99-决策记录-ADR/ADR-158-AI文件理解一次作答与按权限给出去处.md)(文件回答与确认文件卡); 前后端契约: [AI 平台接入指南第八章](../05-架构/AI平台接入指南.md)。

右下角 AI 助手回答「这个页面上各颜色是什么意思」「有什么值要检查」, 以及提出「把第3行数量改成100」这类操作时, 读的是**当前顶层页面上你看得见的东西**。
共享组件挂载时自动登记「取值回调」, 只有在你发送问题(或确认一张卡片)时才计算一次有界快照; 平时不做任何计算, 不影响滚动、重建和转场。

## 一、谁会自动登记

| 组件 | 登记内容 | 何时读取 |
| --- | --- | --- |
| `MasterDataTableView` | 可见列(列名 + 列头 ⓘ)、显示行数/勾选数、前 30 行显示文本、**状态图例**(按单元格最终底色聚合: 列/值/颜色中文名/色调/含义/行数)、整行标红(`rowColor` 反查为红的行记 `FLAGGED`); 通用动作 筛选/勾选行/打开行 | 发送时 |
| `UtenEditableGrid` | 同上 + 整行标红、红框必填空、黄框待核对及原因(列定义 `reviewReasonOf` 与格内 `UtenFieldMessage.autofill`/错误/`RequiredCellFrame`) | 发送时 |
| `UtenInput` / `UtenDropdownField` / `UtenDateField` | 标签、显示值、状态(正常/必填空/黄框预填/错误)、提示原因、ⓘ 说明; 通用动作「填写字段」 | 发送时 |
| `UtenMasterPickerField`(客户/供应商选择) / `UtenEmployeePicker` / `UtenEmployeeMultiPicker` / `UtenFilterPickerField`(工具栏层级筛选) | 标签、所选名称(多选用「、」连接; 筛选未生效时为占位「全部」)、必填空; **只读**, 选人选客户仍由用户自己点 | 发送时 |
| `UtenSearchBar` | 通用动作「搜索」 | 发送时 |
| `UtenStatusBadge` / `UtenDocStatusPill` / `UtenSegmentBadgeLabel` | 文字、色调、颜色名、计数(同名同色合并) | 发送时 |
| `UtenInlineNotice` / `UtenTopBannerCard`(有 semanticLabel) / `UtenDialog.show` 纯文字正文 / `AiGuidedFileBanner`(文件识别进度横幅) | 提示标题与正文 | 发送时 |
| `UtenAppBar(title:)` | 页面标题 | 发送时 |

**不登记**: 密码框(`isPassword` / `obscureText`)一律不登记; 标签像密码/口令/验证码/密钥/令牌/api key 的字段整条不发; 没有标签的输入框不登记; 只读信息行 `UtenInfoRow` 不登记; Offstage/IndexedStack 里看不见的分页、被新页面或弹窗盖住的页面都不进快照。

**整页不读**: 工资、人事、员工档案、个人资料、改密码页面(`aiContentWithheldRoutes`: `/payroll`、`/hr`、`/employee`、`/profile`、`/change-password` 及子路径)不采集快照, 输入区上方写「这个页面含工资或个人信息, 不读取页面内容, 只发送问题」; 服务端同一张清单再丢一次。

**受保护页面(ADR-153)**: 系统管理与安全页面(`aiProtectedRoutes`: `/admin`(系统设置、AI 服务设置、权限管理、审计日志、服务器状态)、`/page-permissions`、`/security`、`/settings/device-receipts` 及子路径)既不采集快照也不提供页面动作, 输入区上方写「系统管理页面…不读取页面内容, AI 也不能在这里代办操作, 只发送问题」; 落在这些页面上的确认卡一律不执行(`aiChatCardProtectedPage`)。服务端 `AiChatPageSnapshot.PROTECTED_ROUTES` 同一张清单丢弃快照, 提案服务拒绝这些路由上的页面动作。两端都按规范化路由判断(`aiCanonicalRoute` / `canonicalRoute`: 小写、合并重复斜杠、去掉末尾斜杠), `/ADMIN/system-settings`、`/admin/ai-settings/` 与 `/admin/system-settings` 同等对待; 含空段的路由(`//admin/...`)服务端直接拒绝(ADR-153 第七节)。

**敏感数值**: 列定义 `aiSensitive: true`、`UtenInput(aiSensitive: true)` 或标签命中平台敏感词(`aiSensitiveLabel`: 成本/毛利/利润、工资/薪/奖金/提成/社保/公积金/应发/实发/扣减/扣款/个税/加班费/津贴/补贴/绩效、信用额度/授信、身份证/证件号/银行卡/银行账号/卡号/手机/电话/邮箱/住址 等, 含英文)时, 只发标签与状态: 值、提示文字(`message`)、ⓘ 说明、待核对原因都不发, 标签写进 `withheld`; 行识别文字(`rowLabel`)跳过这些列。服务端再按同一张词表兜一次。标签按人读到的样子匹配: 全角字母折成半角、去掉空白与不可见字符后再比对(「成 本」「Ｃｏｓｔ」「毛 利」同样算), 词表含进价/进货价(ADR-153 第七节)。
词表管不到的通用标签(成本报表里的「单价」「金额」)必须由页面标 `aiSensitive: true`; 已标: 工资审核/工资条列表的应发/扣减/实发, 车间内料报表的单价/金额/结算时金额/材料金额/单件材料成本, 库存洞察的库存金额, 货品成本测算的单价/金额/费用。

**徽章**: 标签按服务端同口径处理(≤40 字截断, 空标签/编号/网址整条不发), 只认 10 个共享色调名, 颜色名 ≤8 字; 一个异常徽章不会让整页快照被拒。

## 二、只取顶层当前路由

`AiPageContextController`(挂在 `PlatformTablesHost`, 与表格投影控制器同级)按 owner 登记 `Element` 与回调。计算时:

1. 跳过已卸载、`TickerMode` 关闭(被不透明新页面盖住的路由、IndexedStack/Visibility 非当前页)、尚未布局、祖先里有 `Offstage(offstage: true)` 的条目;
2. 在剩下的条目里取**导航器嵌套最深**的一层(外壳导航栏的徽章不会混进页面);
3. 同一导航器里再按 overlay 绘制顺序取**最上面那条路由**(弹窗、侧滑面板这类半透明路由盖在页面上时只读弹窗), 按屏幕位置排序。

整个过程**不建立任何依赖**(不调用 `ModalRoute.of` / `isCurrentOf`): 发问一次之后, 表格和输入框不会因为之后的进页/返回多重建一次(测试锁定)。

## 三、快照上限(前端先截, 服务端再验)

表 ≤4 × 行 ≤30 × 列 ≤12, 单值 ≤80 字(单行), 字段 ≤60, 图例 ≤40, 待核对 ≤80, 徽章 ≤30, 提示 ≤10, 动作 ≤16; 整体按 JSON 字节 ≤22KB(服务端上限 24KB)。
超出时依次减少样本行、待核对、图例、字段、提示, 并标 `truncated`。标签里带编号(UUID)/网址的整条丢弃, 值里的编号/网址替换成「[编号]」「[链接]」, 控制字符清掉。

## 四、给列加「含义」: `legendOf`

图例的颜色和值来自单元格最终底色(`cellColor` 或状态列自动色调); 含义只能来自页面:

```dart
MasterColumnDef<Task>(
  key: 'status',
  label: '状态',
  value: (t) => t.stageLabel,
  cellColor: (context, t) => productionReadinessCellColor(t.tone),
  legendOf: (t) => readinessMeaning(t.tone), // 走 l10n, 没有可靠含义就返回 null
)
```

没有 `legendOf` 时不编含义, 服务端回答会说明「页面没有写明含义」。车间任务页「状态」列已接入 8 种就绪度含义。

颜色名表(`utenColorName` / `UtenStatusBadgeType.colorName`, 给 AI 的固定中文词): 灰、蓝、绿、黄(亮底警示)、琥珀(实底警示)、红、橙、青、品红、紫、青绿(品牌青绿)。先按 `UtenColors` 令牌精确反查(实底、浅底、深字、暗色半透明叠加都认), 查不到按色相归档。**状态列与状态胶囊必须走共享色调**(见准则 09), 否则颜色名只能按色相猜。

## 五、待核对原因: `reviewReasonOf`

```dart
EditableGridColumn<SalesGridRow>(
  key: 'goods',
  label: '货品名称',
  reviewReasonOf: (r) => r.aiReview, // 识别结果的待核对原因(含标价/单位/金额对不上/重复货品 warnings)
  ...
)
```

非空时快照 `flaggedCells` 多一条 `REVIEW`(行号、行识别文字、列、当前值、原因)。格内已用 `UtenFieldMessage.autofill(reason)` 显示黄框的格子会自动上报, 不必重复写; `reviewReasonOf` 用于「原因在行数据里」的场景, 两者同一格同一状态只记一条。

## 六、页面动作(闭合动作集)

AI 只能从当前页面登记的动作里提议; 卡片正文由服务端按参数标题渲染。页面用 `AiPageSlot` 或 `AiPageRegistrar` 登记:

```dart
final _aiPage = AiPageSlot();

@override
void didChangeDependencies() {
  super.didChangeDependencies();
  _aiPage.attach(context, AiPageInfoSource(actions: _aiActions));
}

List<AiPageAction> _aiActions(AiCaptureContext ctx) => [
  AiPageAction(
    name: 'setLineField',               // [a-z][A-Za-z0-9_]{1,47}, 页面内唯一
    title: ctx.l10n.salesAiActionSetLine,
    kind: AiActionKind.form,            // VIEW/FORM/SAVE/SUBMIT, 服务端按它定风险下限
    rowTable: _grid,                    // 行参数数的是哪张表(UtenEditableGrid: 它的 controller)
    params: [
      AiActionParam('row', type: AiParamType.integer, title: ctx.l10n.aiActionParamRow,
          minimum: 1, maximum: rows.length, rowRef: true),
      AiActionParam('field', type: AiParamType.string, title: ctx.l10n.aiActionParamField, options: ['数量', '折扣']),
      AiActionParam('value', type: AiParamType.string, title: ctx.l10n.aiActionParamValue),
    ],
    handler: (call) async {             // 与页面按钮同一代码路径; 失败抛 AiActionFailure(给人看的原因)
      final row = call.row('row')! as SalesGridRow;   // 提问时那一行的记录, 不按下标取
      row.applyAiValue('qty', call.args['value']! as String);
      return null;
    },
  ),
];

@override
void dispose() { _aiPage.detach(); super.dispose(); }
```

- 参数只允许 string/integer/number/boolean, 最多 6 个, 声明顺序就是卡片行顺序; 参数名 `row`/`rowNo` 为整数时卡片自动附上该行识别文字(只取 `rowTable` 那张表)。行号是**屏幕上的第几行**(表头筛选后可见行, 从 1 起), 与快照 `rows[].no` 一致, 两种表格同口径。
- **行绑定**: 行参数写 `rowRef: true`(整数 = 一行, 字符串 = 「1,3,5-8」, 0/空 = 不选), 动作写 `rowTable`。发问时控制器记下那张表每一行的记录身份(MasterDataTableView 按 `idOf`, 编辑表按行对象); 确认后只有那几行仍是同一条记录才执行, handler 用 `call.row/rows` 拿到记录。行被删除/插入/排序/筛选过就拒绝(「第N行已经不是提问时那一行了」), 行号超出提问时的行数回「没有第N行」。
- **页面实例绑定**: 卡片只在提问时那个页面实例上执行(导航器 overlay 条目 + 页面级 `AiPageInfoSource` 登记); 保存后又开了一张同类新单、或换了一页, 回「页面已经换成另一张单据或重新打开过」。
- FORM 动作只改本页输入并标黄「AI 填入, 请核对」, 用户再改那一格黄框即消失; SAVE/SUBMIT 调页面自己的保存/提交方法, 服务端校验照旧。
- 通用动作由共享组件自带: 表格 `filterTable`/`selectRows`/`openRow`(同页多张表时名字带序号)、输入组件 `setField`、搜索框 `searchPage`。页面动作同名时页面优先。
- 第一批页面动作: 销售订货/报价编辑页 `setLineField`(数量/单价(报价)/折扣/备注/文件型号/文件品名)、`confirmReviewLine`(与核对面板「确认」同口径: 只清「货品没对准」提醒并记为人工确认, 保存时学习客户料号; 单位/金额/重复/定价提醒保留, 只有这类提醒的行不能确认)、`saveDraft`(按保存按钮保存)。

## 七、确认卡

对话框把服务端返回的 `CONFIRM_ACTION` 卡渲染为 `AiChatActionCard`: 标题、逐行摘要、风险提示(MEDIUM/HIGH)、再认证提示、到期倒计时、取消/确认(防重复点击)、执行中、成功/失败回执; 结果不明(网络)时只给「查看结果」, **不会自动再确认**。

执行顺序(CLIENT 动作): 本地检查当前顶层路由 == 卡片 `route`、未过期、页面仍登记了该 handler → `POST .../confirm` 拿权威参数 → `AiPageContextController.run`(同一页面实例、按页面**当前**声明再校验参数、行参数核对提问时绑定的记录) → 运行 handler → `POST .../receipt`(成功/失败 + 一句原因)。
`OPEN_GUIDED_FORM`(文件识别)确认后才打开对应新建页并按识别结果填入: 先跳转, 下一帧核对栈顶路由确实是这张表单, 才收起对话框并回执成功; 没打开(无路由、被路由守卫转到无权限页等)回执失败并说明原因, 对话框保持打开、原因写在卡上。`PERMISSION_GRANT` 走原授权端点, 由网络层弹出密码再认证, 关掉密码框视为没确认。身份(账号/模拟/权限/服务器)变化时整段对话与卡片清空。

文件回答(2026-10-05, ADR-158): 任何能用对话的员工都能上传文件让 AI 识别; 一个文件的回答最多一张确认卡, 且只能是 `OPEN_GUIDED_FORM`(服务端读取时只保留绑定了本账号可用用途的卡; 页面动作卡、授权卡等其它类型一律不收)。用途不明时不出卡, 回答下方按服务端给的可选用途出选项, 只列本账号能填的; 点一个选项即把同一个文件连同原话和所选用途再发一次(用户侧显示「选择：…」), 新回答最多一张卡, 原回答的选项随即全部失效。服务端给的可去页面以按钮显示, 先过与路由守卫同一份权限判断(`locationAllowedFor`), 点后跳转并收起对话框; 本账号做不了的事项以灰字列出原因(服务端已写成中文权限名, 不出现权限码)。用途由 AI 兜底判断时(typeSource=AI)加一行说明只看了表头和格式。界面细节见 [AiChatOverlay 第七节](AiChatOverlay.md)。

输入区上方显示「将附带当前页面: 表格N行/字段M个/待核对K项」(打开对话框、换页、聚焦输入框时在下一帧计算); 在「对话设置」里关闭「读取当前页面」(ADR-152, 原对话框里的开关已移入设置)后既不发路由也不发快照, 之前消息存的快照与绑定也丢掉(重试只发问题); 服务端按账号设置再兜底丢弃页面上下文。

## 八、测试

- `test/shared/ai/ai_page_context_test.dart`: 颜色名反查、值清理与上限、表格快照与图例计数(含含义、敏感列)、通用表格动作、编辑表待核对/标红/必填空/格内黄框、输入登记与密码不登记、AI 填入标黄与用户改动清除、整行标红与筛选字段/行内提示、只取顶层路由(不透明页面与同导航器弹窗)、Offstage 不读、发问后进页/返回不多重建、超大页面字节预算、销售订货识别原因进入 flaggedCells; 敏感列在最前且整行标红时行文字不带敏感值、敏感字段的提示/说明不发、凭证字段整条不发、徽章边界、卡片只在原页面实例与原行上执行、整页不读清单与词表。
- `test/shared/ai/ai_chat_test.dart`: 快照随消息发送与附带提示、页面感知关闭不发(含关掉后重试)、工资页只发问题、确认卡执行/双击只一次/取消/过期/错页/同路由换页面实例不执行/handler 失败回执/身份变化作废/网络不明只查不重放、授权卡、文件识别不自动跳转; 文件回答: 用途不明零卡+按权限列选项、点选项同文件带用途重发且只出一张卡、选项一次有效、页面按钮按路由守卫显隐并跳转、做不了的事项灰字、最多一张卡且只收文件表单卡、表单没成为栈顶时回执失败且对话框不收; 真实外壳: 从工作台/设置 push 的页面可见、返回回原 Tab、点 Tab 离开, 工作台上确认文件卡后表单在上层。
- `test/shared/ai/ai_document_destinations_contract_test.dart`: 服务端文件回答页面目录(`AiDocumentDestinations.java` 一行一个 `new Destination(...)`)要求的权限覆盖客户端路由守卫(全部码都在、任一码至少一个、持有这些码能过 `locationAllowedFor`), 路由是安全的固定路径, 无权说明不出现权限码。
- `test/features/payroll/payroll_review_page_test.dart`: 真实工资审核页快照里没有金额。`test/features/sales/pages/sales_doc_edit_intake_test.dart`: 真实销售编辑页的行绑定与确认待核对行口径。
