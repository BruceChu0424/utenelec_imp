# ADR-134：销售客户文件 AI 识别导入、主档学习与报价财务核价

- 日期：2026-09-27
- 状态：已接受；本地实现，未部署(迁移号 V742 为临时号，落地时顺延)；2026-09-27 九个实现包合并后按最终代码复核(全局对照计数口径、学习回调顺序、徽章入口名与接口一览)；2026-09-28 集成补记(用户改正优先、购买历史只算已审核订货、无买方线索时的篮子比较、未预选客户时复用客户专属版式、英文名去规格尾行、接口一览补报价列表/订单财务审核/任务错误码)；同日评审修复(全局版式按不同客户计数、别的客户的版式只作规则之后的兜底、提示词抬头区号码从严、报价币种只能本位币、旧流程已审报价不在财务读范围也不能直接转订货、订货服务端拦截无标价或高于标价的文件单价行、折扣区间按取位后判断)
- 范围：新建报价单/订货单的客户文件识别导入；客户货品对照、货品英文名、客户外文名与版式学习；报价单财务核价流程与转订货；新增权限码 `sales_quote_finance:view`、`sales_quote_finance:confirm`、`ai:use`、`goods:name_en:edit`，退役 `sales_quote:approve`
- 依赖：ADR-133(公共 AI 平台)、ADR-017(跨模块只经 application.port)、ADR-027(财务审核组)、ADR-074(附件绑定已保存单据)、ADR-112(金额只在服务端精确派生)、ADR-121(新建表单草稿)

## 背景

业务员手里的客户文件(报价单、形式发票 PI、商业发票)每个客户格式都不一样：列顺序、表头文字(中英混排、换行)、合并单元格、合计/订金/银行信息行、图片列都不同，货品描述多为英文(也有其他语言)，客户写的「型号」大多是我们的型号(可能带系列前缀或零件后缀)，颜色常写英文或写在描述括号里。用户要求：

1. 新建报价单/订货单时上传客户文件，自动填好客户与货品明细；货品必须大概率对准。
2. 价格不允许改(销售无改价权限)，按客户写的单价反推折扣。
3. 用户确认保存后学习：货品英文名进货品资料(可在货品资料修改，保持最新)，客户资料自动补全，客户的叫法越用越准；只学基础信息，不学价格。
4. 业务员只能看到自己的客户。
5. 报价单不是最终的：财务会反复修改，确认后才转订货单；订货单才是最终的，并按我们自己的表格显示。

同行做法(调研出处见文末)：SAP 的「客户物料信息记录」(KNMT/CMIR)与 AI 抽取后人工复核的销售订单请求、Dynamics 365 BC 的 Item Reference 与 Sales Order Agent(先建报价、三层匹配、价格从不取自文件)、金蝶「客户物料对应表」、用友 YonGPT 智能生单、Odoo customerinfo 与「连续 3 次无修改才信任」。共识是：**一张按客户维度的对照表 + 先草稿后人工确认 + 分级置信度 + 从确认中学习 + 价格不取自文件**。

## 决定

### 一、识别以规则为主、AI 为辅(混合)

- 服务端解析文件(Excel 取缓存计算值、合并单元格、隐藏行列跳过；PDF 取文字层；扫描件/图片只在管理员启用「支持图片识别」的模型时交给 AI)，只挑表头得分最高的一张工作表，其他像明细的工作表提示用户选择(结果 `file.otherSheets[{name, index, lineCount}]`; 核对面板点「另有工作表 X 也像明细表 (N 行)」即用同一个文件加参数 `sheet`=index 重新识别, 新结果整个替换面板)，绝不自动拼接(防止装箱单重复计数)。
- 列角色先查**已学习版式**(表头指纹)，再按中英关键词字典打分，规则置信度低时才请 AI 判断列角色；表头信息(买方、联系人、邮箱、电话、单号、日期、贸易术语、付款条件)规则优先，AI 只补规则没抽到的，且只看表格上方文字。
- **发送前最小化**：银行/账号/SWIFT/收款人行与我方卖方信息整行剔除；邮箱、电话、税号换成占位符，服务端再映射回来；抽表头时从不发送单价金额。认列(表格片段)与 PDF 文字两种提示词里，抬头区(第一行货品/表头之前，买方与联系人一带)按表头同口径从严：7 位以上数字串都当电话，7 位以上的整数数字格也换成占位符；左边一格只是「Tel:」「VAT No.」这类标签时，右边的号码一律换成占位符；电话标签认 tel/telephone/ph/phone/mobile/cell/fax/whatsapp/wechat/viber/contact、带「.」或「:」的单字母 T 及中文电话/手机/传真/联系(英文词前后不紧挨字母, 「Total」「Photo」不算)，货品区只换带标签或明显电话格式的号码，数量单价照常发送。文件内容一律按「不可信数据」加分隔标记，提示词明确禁止执行其中指令。
- 识别以后台作业运行(ADR-133 公共作业，kind `SALES_DOCUMENT_INTAKE`，参数 `docType`=quote|order、可选 `clientId`/`docId`/`sheet`，文件 <= 15 MiB、图片 <= 8 MiB)，前端显示分步进度弹窗，可取消；每人同时最多 2 个、每日有上限。服务端阶段(2026-09-27 按代码核对)：`READING`(10) → `LAYOUT`(25) → `EXTRACTING`(40) → `MATCHING_GOODS`(60) → `MATCHING_CLIENT`(75) → `PRICING`(90) → `DONE`(100)；先把文件完整解析完再调用 AI，解析阶段(READING/LAYOUT)租约过期按坏文件结束不重试。结果 JSON `schemaVersion` 2，行键 `S<表序号>R<行号>`(PDF `P1R<n>`、图片 `I1R<n>`)，保存时作为 `intakeLineKey` 回传。

### 二、货品匹配：可加性证据 + 只在证据充分时自动对应

- 候选来源：客户对照(本客户，精确上下文/任意上下文)、全局对照(至少 2 个不同客户确认过、同一叫法不指向多个货品，见 §五)、型号精确与前缀变体(剥 `Q120-`/`F-`/`V6`/`G-`，罚 4 分，从不剥 `-0N` 零件后缀)、本系列内一字之差的型号(只能进入「需核对」)、货品编号、中文品名(去客户/国别前缀与系列号后精确或去括号限定语后相等)、中文字二元组相似度、**本客户历史买过的货品池**、英文名称。
- 打分可叠加：系列一致 +10、不一致 -20；主色一致 +8、不一致 -25；面框色(规格里「…面框」)不一致 -10；型号与名称互相印证 +10；本客户买过 +6(3 次以上再 +3)；本客户/国别前缀 +4、他人前缀 -10；文件单价折算后与标价一致 +4(只作平局参考)。
- 「买过」一律只算**已审核**的订货单(`sales_orders.status = 1`，未删除；草稿、待审核与作废都不算)：本客户历史货品池(近 24 个月)、「本客户买过」加分、下文 §三 的购物篮重合用同一口径(`MasterIntakeLookupAdapter`)，还没审核的单据不会把货品推成「常买」。
- **自动对应(不需核对)必须同时满足**：得分 ≥ 90 且领先第二名 ≥ 8、证据含型号/对照/唯一名称的精确命中、无系列/颜色冲突、候选中没有同名族兄弟、不是「A+B+C」组合行、对照键不指向多个货品、不是多行对到同一货品；没有系列列而同型号同色跨多个系列时，只在该客户近 24 个月只买过其中一个时才自动对应。否则进入「需核对」或「没找到」。
- 用户确认过的精确上下文对照是**权威**的(明确选过 >= 1 次或确认 >= 2 次：99 分，其他候选最多 89)；新学的对照在第二张单据确认前最多 92 分。改正立即生效(用户改正优先于自动学习)：匹配时同一客户、同一型号叫法、同一上下文下只有一个货品被人明确选过(`explicit_count >= 1`)时，它就是答案(99 分)，系统以前自动学到的其它对应不再加分(那些货品仍可凭型号等其它证据进候选，最多 89 分)；保存时用户明确选了某货品，同一客户、同一叫法(型号与品名两种)、同一上下文下指向其它货品且 `explicit_count = 0`(只是系统自动对上后保存学到的)的旧对应直接作废(`ClientGoodsAliasLedger.supersedeAutoLearned`，受影响的全局对照随即按客户证据重算)。只有两个货品都被人明确选过(同一叫法确有两种货品)时才判为有歧义、进入「需核对」，错的一条可在客户资料「货品对照」删除。
- 中文品名召回用内存索引 `GoodsNameCatalog`，不用 pg_trgm：中文品名在 pg_trgm 里是一整个「词」，正确名称的相似度只有 0.1 左右，且名称夹着空格、全角括号与客户/国别前缀。索引把「使用中、未删除、非占位」货品名称按识别同一口径(NFKC、小写、去全部空白)规范化放在内存，按「名称结尾一致 → 字二元组 Dice 最高 → 名称包含」召回，只返回货品 id，可见范围与状态由调用方回表过滤(索引过期也不会越权)；按货品表轻量签名(行数、版本和、最后修改时间)失效重建，另有 10 分钟兜底过期。英文名称召回用 `idx_goods_name_en_trgm`，型号用 `idx_goods_model_norm`。
- AI 只处理「需核对/没找到」的行，只能在给定候选里选；AI 选了规则第一名以外的货品时仍需人工核对，从不据 AI 单方面自动对应。
- 精度门槛(回归测试固定)：用旧库真实订单为标准答案，SUNAS 商业发票与 UJ23 形式发票两类文件自动对应的准确率 100%，正确货品进入前 8 候选 ≥ 93%。

### 三、客户匹配与新建

只在上传人可见的客户里匹配(沿用 ClientAccessPolicy)：邮箱/邮箱域名(排除公共邮箱)、外文名称、英文特征词(去掉 ELECTRIC/TRADING/CO/LTD 等通用词)、电话后 8 位、名称相似度，以及「这些货品该客户是否都买过」(购物篮重合，只算已审核订货，只作建议不自动确定)。购物篮比较的范围：文件上有买方线索(名称、邮箱、电话、国家等)时，只在线索找到的候选客户之间比较，不让别的老客户仅凭买过同样的货品把强线索客户压成待核对；文件上一条买方线索都没有、且用户没有预选客户时，才在上传人看得到的全部启用客户里比较(端口 `historyContains` 的客户集合为空即表示「全部可见启用客户」，库里按买过的候选货品数排序只取前 50 个，候选货品最多取 4000 个)；只靠购物篮的客户最多预选为「需核对」(REVIEW)，从不自动确定；用户已选好客户时不做这次全量比较。文件里的买方与已选客户明显不一致时提醒。没有匹配时可「用文件信息新建客户」：先跨全部客户查重(邮箱、电话后 8 位、外文名/全称)，命中别人名下的客户只提示「可能已由其他业务员负责」，不泄露名称。

### 四、价格与折扣(销售永不改价)

- 导入后的单据币种一律为本位币(货品标价的币种)；文件币种与文件单价只作参考保存(`client_file_currency`、`client_price`)。汇率只取财务维护的币种汇率，销售不填。报价按货品标价计价，手工新建的报价币种也只能是本位币或不填：选客户时不按客户上次订货的币种预填，币种下拉只列本位币，服务端保存/提交核价时拒绝外币(「报价按货品标价(本位币)计价, 币种只能选本位币或不填」)，不再等财务确认后转订货单才报错。
- 折扣 = 文件单价 × 汇率 ÷ 标价，在 `MoneyPolicy.discountFromUnitPrice` 里四位四舍五入(全平台唯一取位处)；分别按汇率 1 与财务汇率各算一次，恰好一个落在 (0.3, 1] 才采用，否则需核对(可能对错货品或币种不对)。「落在 (0.3, 1]」判的是取 4 位后的折扣(`SalesPriceAuthority.plausibleDiscount`)，识别定价、看不到价格的人保存时的反推、前端换货预览是同一个判断，同一行不会因为谁在看而得到不同折扣。高于标价(取 4 位后大于 1)从不截成 1。
- 标价为 0 或未维护、文件单价高于标价：报价单上留空折扣、标「待财务定价」，由财务在核价时给出成交单价(`price_source = FINANCE`)；订货单上这些行不可导入，引导「改为新建报价单」(复用同一次识别，不必重传，原文件一并带到报价的附件里)；服务端订货保存同样拦下带文件单价、而货品标价为 0 或文件单价高于标价的行(报价转来、财务核定单价的行除外)，直接调接口或在导入行上手工换货品也一样(409「请先做报价单交给财务定价」)。
- 无售价查看权限的业务员：识别结果不含标价与折扣(`summary.priceMasked = true`)；前端提交 `discount: null`，保存时服务端按文件单价用同一规则(`SalesPriceAuthority.deriveDiscountFromClientPrice`，合理区间 (0.3, 1])派生折扣，推不出时按原价(折扣 1)并在行备注写「文件单价换算不出合理折扣, 暂按原价, 请有价格权限的同事核对」；已保存行(按明细 id 对上)的折扣保持不变、请求没带文件单价时也保留原文件单价(修复原先无权限保存把折扣重置为 1 的问题)。候选上的订货单拦截标记 `orderBlocked`(没有标价或客户价高于标价)不是价格字段，看不到价格的读者也保留，订货页据此不勾选并引导改做报价单；它会让这类读者知道「该货品不能直接下订货单」，但不透露任何价格。

### 五、学习(保存后，只学基础信息)

- 保存报价/订货单时在保存事务内只做校验(勾选的客户资料字段不合法返回 422，整单回滚)；学习在提交成功后另起短事务执行(`SalesMasterLearningPort.learnAfterCommit`，回调排在最后)，失败只记日志(日志不含客户文件内容)、不影响单据保存(避免与保存时对货品行的共享锁互相等待)。学习的权限按当前登录人重新判定；请求声明的保存人与登录人不一致时不学。
- 客户对照：从**服务端保存的识别记录**(`AiJobUsagePort.resultFor`，按 `intakeLineKey` 对行)里取客户原文(不信任请求体里改写过的文字)，只学用户明确选过/改过的行(`userConfirmed`)，或识别「已自动对应」且用户没改货品的行；型号(PART_NO)与品名(DESCRIPTION)各学一条，上下文取识别行的「系列|主色」。同一张单据里同一叫法(同上下文)对到不止一个货品时这次不学；对客户没有写范围(只读共享)不学客户对照。确认次数按保存的单据累计，同一张单据重复保存不重复计数；同一张单据再次保存时某叫法改对到别的货品，撤回本单据上次学到的旧对应(只确认过一次的删除，多次的扣一次)；用户明确选了某货品时，同一叫法同一上下文下从没被人明确选过的其它对应一并作废(改正优先)。用户可在客户资料「货品对照」里删除错误对照(写审计)。
- 全局对照(`client_id` 为空)：只从与识别原文一致的文字学习(手打的原文只学客户对照、不学全局与英文名)。全局行的 `confirm_count` **不是保存次数**，而是「有多少个不同客户的客户对照把同一叫法(不分上下文)对到同一货品」，`explicit_count` 是其中明确选过的客户数；每次学习或撤回后按客户证据重算，撤回后已没有任何客户证据的全局对照删除。这样同一个人反复保存同一批单据不会把它推过门槛；识别时全局对照要至少 2 个客户确认、且同一叫法不指向多个货品才用(90 分)。按 (种类, 叫法, 货品) 查各客户证据走 V742 的部分索引 `idx_client_goods_aliases_global_evidence`(只含客户对照行)；两个计数列的注释写明了客户行与全局行两种口径。
- 货品英文名：识别面板每行「设为货品英文名」(货品英文名为空且文字有区分度时默认勾选)，保存后写入 `goods.name_en`(来源 LEARNED，有意勾选即覆盖旧值)；只学识别结果里的英文描述(识别行的 `nameEnText`)，要求至少两个英文单词、不含汉字；描述后面附带的规格行整段去掉、只留品名本身(空白压成一个空格后，从空格加 current / voltage / power / rated / rating / size / dimension / material / colour / color / packing / weight 加半角或全角冒号处起删到结尾，例如 `WALL SWITCH Current: 10A` 只学 `WALL SWITCH`；去掉后为空则不学，`SalesIntakePipeline.nameEnText`)；同一张单据里同一段英文对到多个货品、或同一货品出现两段不同英文时都不学；另一个货品已用同一英文名称(不分大小写)时不学。货品资料里手工修改为 MANUAL(`PUT /api/master/goods/{id}/name-en`)；需要 `goods:name_en:edit` 或 `goods:edit` 且对货品有写范围。手工选货品时「文件品名」为空则带出货品英文名称(不查客户对照; 与 SPEC §7.3「先带客户叫法」的偏差: 手工选货品的场景没有客户文件原文, 客户对照在客户资料「货品对照」里可查, 下单页不再为每次选货多一次查询)；带出后没改过的英文名称只保存显示、不当客户叫法学习(不回传 `userConfirmed`)，改成客户自己的叫法才学。
- 客户资料：面板里一句话一个勾选「保存时补进客户资料」，空字段默认补、有值且不同默认不改；只接受 nameEn、fullName、linkman、email、phone、mobile、address、taxId、website 九个键；需要 `client:edit` 与客户写范围。邮箱/电话/手机/网址记进多联系方式表(同类已有同值不记，该类第一条记为主联系方式，由服务端同步回客户表平铺列)，其余写客户表。审计事件 `client.learn_from_document`(「从客户文件补全」)只列字段名，作为旁路事件记录，不吞掉本次保存自己的操作审计(报价/订货的新增或修改)。
- 版式：保存后按识别记录学习表头指纹与列角色(`sales_intake_layouts`)。版式来自规则或 AI 时写本客户一行(列角色没变确认次数 +1，变了从 1 重新数)，再按各客户的证据重算全局一行(列角色 = 最多客户确认过的那种，确认次数 = 确认过它的**不同客户数**，与全局对照同口径；同一客户保存再多次也只算 1)；保存时用的就是学习到的版式则只刷新使用时间、不加次数(自己确认自己不算新证据)；没有客户的保存不写。使用顺序：① 先于规则：已选客户自己的版式(一次即用)、至少 2 个不同客户确认过的全局版式；② 规则；③ 规则认不出时的兜底(仍在 AI 之前)：同一表头指纹学到的版式(全局的与别的客户的)只有一种列角色才用，互相矛盾就交给 AI。别的客户的专属版式从不先于规则或可信的全局版式，一个客户的一次保存(可能是 AI 认错列后手工改了表格)不会影响其他人。没有预选客户时也查各客户的专属版式，但只用于第 ③ 步；识别时只取列角色与表头行数，不读表头原文列 `header_texts`，来源客户不当客户线索也不写进识别结果(`SalesIntakeStore.layouts`、`SalesIntakePipeline.trusted/fallbackLearnedLayout`)。
- 重复单据：同一客户同一单号、同一文件或明细基本相同的报价/订货单，面板顶部黄色提醒(只提醒不拦截)。

### 六、报价单财务核价

状态：0 草稿(含「财务退回」)→ 2 待财务核价 → 1 已核价 →(转订货单)；-1 作废。

- 销售：提交财务核价、撤回、已核价未转时重新修改、转订货单、作废。
- 财务(`sales_quote_finance:confirm`，按 ADR-027 财务审核组 + 任务认领，所有动作带版本号)：可改每行折扣或成交单价(二者互推)，标价为 0/空或文件单价高于标价时给出财务成交价；可改有效期、结算方式、财务备注；可对勾选行批量设折扣；可退回(带常用原因)或确认；未转订货前可「撤销确认再修改」。每次动作写只追加的修订记录，重新提交时标出销售改动了哪些财务确认过的折扣。
- 转订货单：带入财务确认的单价与折扣，订货单上这些行的折扣锁定(改动返回「该行折扣已由财务在报价核定」)；数量与新增行仍可改。订货单的财务确认(V294，信用/条款/放行计划)仍保留，列表和审核页显示「报价已核价 · 一致」。
- 徽章：财务「报价待核价」(`financeQuoteReview`，事实 `salesQuoteFinance.pending`)、销售「报价被退回」(`salesQuoteFinanceRejected`，事实 `financeRejected.salesQuote`)「报价已核价待转订货」(`salesQuoteAwaitingConversion`，事实 `salesQuote.awaitingConversion`)均为红色(轮到我)，服务端 `WorkbenchBadgeCatalog` 与前端 `badge_registry.dart` 逐字一致；销售任务中心报价大类另有黄数 = 待财务核价(在财务手上)。草稿数不含被退回的报价(不双计)。报价列表分段(查询参数 `bucket`)：草稿 / 财务退回 / 待财务核价 / 已核价 / 作废 + 历史记录；另有只作筛选的 `AWAITING_CONVERSION`(已核价、没有未删除订货单引用它，与徽章同口径，订货单「从报价引入」用)。
- 通知：提交后发给全部合格核价人(财务部门成员且持 `sales_quote_finance:view` + `sales_quote_finance:confirm`，审核待办卡，撤回/退回/确认时撤卡)，退回、确认、财务撤销确认通知报价负责人；深链财务 `/finance/quote-review/{id}`、销售 `/sales/quotes/{id}`。

### 七、接口一览(2026-09-27 按最终代码核对；2026-09-28 集成补记报价列表、订单财务审核与任务错误码)

| 接口 | 权限 | 说明 |
|---|---|---|
| `POST /api/ai/jobs?kind=SALES_DOCUMENT_INTAKE&docType=quote\|order[&clientId][&docId][&sheet]` | 员工账号 + 处理器校验 `sales_quote:create\|edit` 或 `sales_order:create\|edit` | 原始字节流上传, 见 ADR-133 §4; 查询 `GET /api/ai/jobs/{id}`、取消 `POST /api/ai/jobs/{id}/cancel` 只给提交人。结果的货品候选带 `orderBlocked`(订货单不能直接导入: 没有标价或文件单价高于标价; 不是价格字段, 看不到价格的读者也保留, 见 §四)。失败时任务的 `errorCode`(`ai_jobs.error_code`)取处理器 `ApiException` 的 `fieldErrors` 里 `field = "errorCode"` 给出的业务码: `UNSUPPORTED_FILE` / `NO_TABLE` / `NO_LINES` / `AI_REQUIRED` / `AI_VISION_UNAVAILABLE` / `AI_FAILED`(前端据此给下一步), 约定见 ADR-133 §4 与 [AI 平台接入指南](../05-架构/AI平台接入指南.md) §三.5 |
| `GET /api/sales/quotes?bucket=...`、`/facets?bucket=...` | `sales_quote:view` | 报价列表(`QuoteListItem`)。列表项带 `currencyId`、`deliverDate`(与订货单列表同名; 列表的币种列按 `currencyId` 解析名称)、`statusBucket`、`allowedActions`、`priceMasked` 等; `bucket` = `DRAFT` / `FINANCE_REJECTED` / `PENDING_FINANCE` / `APPROVED` / `REVERSED`(与分段计数同口径), 另有只作筛选的 `AWAITING_CONVERSION`(状态 1、财务确认过、没有未删除的订货单引用它, 与徽章「报价已核价待转订货」同口径, 订货单「从报价引入」用); 其他值 422 「报价分段无效」 |
| `POST /api/sales/quotes/{id}/submit\|withdraw\|reopen` | `sales_quote:edit` | body `{expectedRevision}`(submit 可省), 返回报价详情 |
| `POST /api/sales/quotes/{id}/convert` | `sales_quote:convert` + `sales_order:create` | 只对财务确认过(有财务确认时间)、未转单的报价; 旧流程销售自审的已审报价先「重新修改」再提交核价 |
| `GET /api/sales/quotes/counts` | `sales_quote:view` | 「报价已核价待转订货」数(本人负责范围) |
| `GET /api/sales/quotes/finance-review?state=pending\|confirmed\|returned`、`/finance-review/count`、`/{id}/finance-review` | `sales_quote_finance:view` | 核价队列、计数与核价详情(不脱敏); 核价详情明细行带 `unitId`(数量合计按单位分组, 不同单位不相加; `unitName` 只作显示) |
| `GET /api/sales/orders/finance-confirmation/pending`、`GET /api/sales/orders/{id}/finance-confirmation/review` | `sales_order_finance:view` | 订单财务确认列表与审核详情(V294/V300 既有接口, 本 ADR 加字段): 列表行与详情都带来源报价 `sourceQuote{id, billNo, financeConfirmedByName, financeConfirmedAt, allLinesMatch}` 与顶层 `matchesQuote`(报价转入的订单: 每行单价与折扣都与报价核定一致为 true、有不一致为 false; **不是报价转入为 null**, 两处同一配对规则); 审核明细行带 `quotePrice`、`quoteDiscount`、`matchesQuote`(报价外新增的行为 false)与客户文件的 `clientPrice`、`clientGoodsName`、`clientModel`, 表头 `clientFileCurrency` |
| `PUT /api/sales/quotes/{id}/finance`、`POST /{id}/finance-return\|finance-confirm\|finance-reopen` | `sales_quote_finance:view` + `sales_quote_finance:confirm` | 带 `expectedRevision`(改价/退回/确认另带 `expectedClaimId`), 认领类型 `SALES_QUOTE_FINANCE_REVIEW` |
| `GET /api/master/clients/{id}/goods-aliases?page&size&keyword`、`DELETE .../goods-aliases/{aliasId}` | `client:view` + 读范围 / `client:edit` + 写范围 | 客户资料「货品对照」, 删除写审计 |
| `POST /api/master/clients/from-document` | `client:create` | 用文件信息新建客户; 跨全部客户查重, 本人看得到的重复回 409 并在 `fieldErrors` 带 `existingClientId`, 看不到的只提示「可能已由其他业务员负责」 |
| `PUT /api/master/goods/{id}/name-en` | `goods:name_en:edit` 或 `goods:edit` + 写范围 | body `{nameEn, version}`, 来源记 MANUAL, 版本冲突 409 |

旧的 `POST /api/sales/quotes/{id}/approve` 与权限码 `sales_quote:approve` 已删除。

## 代价与边界

- 上线前提：客户资料必须分配负责人(当前开发库全部为空，业务员将看不到任何客户，识别会提示「你名下还没有客户资料」)。
- 标价币种是隐含的(多数为人民币，个别外贸专用货品疑似按美元标价)；本 ADR 用双汇率合理区间判断兜底，是否给货品增加售价币种留作后续决定。
- 匹配阈值依据两类真实文件调出，已固定为回归测试；上线后按「自动对应被改动率」持续调整。
- PDF/图片识别依赖所选模型的能力，整份文件会发给 AI 服务(界面先提示)。
- 学习写货品英文名与客户资料属于「无主档编辑权限的受控回写」，限定字段、限定来源、限定权限码并审计；其余主档字段仍只能在基础资料维护。

## 参考

- SAP CMIR / KNMT：https://www.sap-tables.org/table/knmt/sap-table-KNMT-erd.pdf ；AI 辅助抽取建销售订单：https://help.sap.com/docs/SAP_S4HANA_CLOUD/a376cd9ea00d476b96f18dea1247e6a5/565f8b8bd23944f1b04836a1b424c647.html ；参考架构：https://architecture.learning.sap.com/docs/ref-arch/b2b40e
- Dynamics 365 BC Item Reference：https://learn.microsoft.com/en-us/dynamics365/business-central/inventory-how-use-item-cross-refs ；Sales Order Agent：https://learn.microsoft.com/en-us/dynamics365/business-central/sales-order-agent ；按文件建议销售行：https://learn.microsoft.com/en-us/dynamics365/business-central/faq-sales-suggest-sales-lines-with-copilot
- Odoo 客户货品编码(OCA)：https://apps.odoo.com/apps/modules/18.0/product_customerinfo_sale ；发票数字化信任升级：https://www.odoo.com/documentation/19.0/applications/finance/accounting/vendor_bills/invoice_digitization.html
- 金蝶客户物料对应表：https://help.open.kingdee.com/dokuwiki_std/doku.php?id=%E5%AE%A2%E6%88%B7%E7%89%A9%E6%96%99%E5%AF%B9%E5%BA%94%E8%A1%A8
- 用友 YonGPT 智能生单：https://blog.csdn.net/YonBIP/article/details/132056481
- 表格与候选选择的研究：https://arxiv.org/abs/2407.09025 ；https://aclanthology.org/2025.coling-main.8.pdf ；提示注入缓解：https://genai.owasp.org/llmrisk/llm01-prompt-injection/
