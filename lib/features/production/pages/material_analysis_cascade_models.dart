part of 'production_material_analysis_page.dart';

/// 父件 + 下层一起下单（ADR-081，2026-09-14 修订为**弹窗前置**）：在分桶页
/// 点「创建生产计划 / 下达委外」时，若被下达件的 BOM 还有没下单的下层，**先**
/// 弹这张与物料分析准备页同款的层级表——树顶是被下达件本身，下面是子层 /
/// 孙层，数量按本批数量自动算好（可改），点「一键下单」才按序提交：
/// 先父件（车间走 issue-plans 原子建锚点 + 出计划 / 委外走 notify），
/// 再按最新快照重建下层行并继承已填数量，最后按各自路线分流——
/// 采购行走下达采购、无子层委外行走下达委外、自制与有子层委外行回到
/// 下达车间。基础需求已下过单的下层行按申请进度分流：申请未分解的把追加量
/// **并入原申请**（明细数量改大，V477 口径），已分解的问过用户后按**追加**
/// 另立申请（notify 超量通道）。
///
///不是一个事务：各段各有自己的校验、幂等键与 CAS（ADR-080「明确不做」里
/// 拒绝把它们压进一个事务的理由依然成立）。这里做的是**有序编排 + 逐段如实
/// 回报**：任一段失败即停下、不静默继续，已成功的段保留（幂等键可重放），
/// 弹窗按最新快照重算后留在原地供重试。

/// 树顶那一行（= 本次要下达的件）走哪条通道。
///
/// 2026-09-15 起显式声明，不再靠 `actionGroupKey != null` 猜入口：三条通道的
/// 数量约束、要不要车间/负责人、提交后该落在哪个桶，都各不相同。
enum _CascadeParentChannel {
  /// 下达车间：issue-plans（顶层产品 / 已建锚点子件 / 自制候选）。
  /// 数量可超量（V577，超出部分记公共备货产出），必须有车间 + 负责人。
  workshop,

  /// 下达委外，且要我方先自制目标件再发外（有生产性自制子层），但当前账号
  /// **没有生成生产计划权限**，只能走 notify 整量接管：服务端要求 `requested`
  /// 逐字等于剩余需求、不接受公共超量，所以数量不可改；前置自制任务建好后
  /// 留在「下达车间 / 未下达」等有权限的人排产。
  ///
  /// 有生成生产计划权限时这类行改走 [workshop] 通道 (issue-plans 的 ARRANGE
  /// 段，2026-09-16)：数量可改、超量按 V589 跟到台账与行动、同事务建台账 +
  /// 锚点 + 计划——正是用户要的「有子层级的委外自动添加到下达车间然后自动
  /// 下达车间」，也不再需要单独一段「前置自制任务下达车间」。
  subcontractMakeFirst,

  /// 下达委外，直接外发（无子层，或 V581「只有一个叶子子件」的我方供料件）。
  /// notify 一步到位形成委外申请，可分批、可按权限超量，不需要车间。
  subcontractDirect,
}

/// 一次下达里的一行，既是下层展开的起点，也是**父件段完整的提交意图**。
///
/// 2026-09-15 扩容（原来只有「ID + 本批数量」）：车间 / 负责人是**用户输入**，
/// 不随服务端快照失效，却被挡在页面外——级联页因此只能把树顶那两格封死成
/// 一句「车间在上一页已经填过」，而这句话对「下达委外」入口根本不成立
/// （委外桶没有车间列）。真正需要车间的是委外下达后建出来的前置自制任务。
class _ChildCascadeSeed {
  _ChildCascadeSeed({
    required this.label,
    required this.batchQty,
    required this.channel,
    this.maxQty,
    this.analysisLineId,
    this.materialLineId,
    this.actionGroupKey,
    this.unitName,
    this.departmentId,
    this.departmentName,
    this.workerId,
    this.workerName,
    this.workshopAutofilled = false,
    this.workerAutofilled = false,
    this.groupKey,
    this.overQtyConfirmed = false,
    this.quantityExplicit = false,
    this.outputUnitRate = 1,
  });

  /// 本行走哪条通道（决定数量约束与要不要车间/负责人）。
  final _CascadeParentChannel channel;

  /// 本行在分桶页对应的操作组键 (`_MaterialGroup.key`)。委外 notify 请求按它
  /// 定位行；被祖先吸收的种子要从父件请求里剔除时也按它找。
  final String? groupKey;

  /// 分桶页已经对「本批数量超出需求」问过一次确认 (车间桶在 `_validatePlanRows`
  /// 里问)。委外桶改走 issue-plans 的行没问过，级联页提交前要补问。
  final bool overQtyConfirmed;

  /// Only an explicitly edited bucket quantity can override ancestor demand.
  final bool quantityExplicit;
  final double outputUnitRate;

  /// 被另一颗种子 (它在 BOM 上的祖先) 的展开吸收 (2026-09-16)。
  ///
  /// 用户口径「我选择很多，包括顶层的，它们都是顶层的子层级；我改顶层数量，
  /// 其他的就不会跟着变」——原来每个勾选行各成一棵树、互不驱动。现在：勾选行
  /// 若是另一勾选行的 BOM 后代，就并进祖先那棵树当普通下层行 (数量按祖先本批
  /// 数量驱动、车间/负责人沿用分桶页填的)，不再单独成树，也不进父件段；它由
  /// 级联页的车间段按算好的数量提交。null = 本种子是树顶。
  _ChildCascadeSeed? absorbedBy;

  /// 树顶 (未被吸收) 才进父件段、才算「本次将下达」。
  bool get isTop => absorbedBy == null;

  /// 本次可下达上限（车间入口 = 产品剩余需求 / 候选剩余量；委外入口 =
  /// 服务端剩余需求）。null = 拿不到上限（旧载荷），此时只校验「> 0」。
  /// 超过它不是错误，但必须像分桶页一样过一次超量二次确认。
  final double? maxQty;

  /// 生产车间 / 负责人。**可变**：树顶那一行现在可以直接改
  /// （用户口径「父件也要有车间和负责人选项」），改完回写到这里，
  /// 父件段与「前置自制下达车间」段都读它。
  String? departmentId;
  String? departmentName;
  String? workerId;
  String? workerName;

  /// 车间 / 负责人是**系统带出来的默认值**(上一页的学习默认或车间主管),
  /// 不是用户亲手选的。
  ///
  /// 2026-09-15 用户口径:「顶层物料的生产车间、负责人同样是默认值,它们边框
  /// 没有标黄也没有提示 icon」。根因是这两个标记原来止步于分桶页——种子只带
  /// 值不带来历,级联页看到「已有值」就不再补默认(`departmentId.value != null`
  /// 那道门),树顶那两格于是永远是「用户已确认」的素底。带上来历,树顶与下层
  /// 才是同一套「默认值要标黄提醒核对」的口径。
  bool workshopAutofilled;
  bool workerAutofilled;

  /// 本通道的数量能不能改。有自制子层的委外件不可改——服务端要求整量接管。
  bool get quantityEditable =>
      channel != _CascadeParentChannel.subcontractMakeFirst;

  /// 本通道要不要填车间 / 负责人：走 issue-plans 的行要 (父件段直接建计划)；
  /// notify 整量接管的行也要 (随后那一段要拿它去排前置自制锚点)；只有直接
  /// 外发的委外件不需要——它整件发给委外商，我方不排产。
  bool get needsWorkshop => channel != _CascadeParentChannel.subcontractDirect;

  /// 委外种子的提交单元键：父件段走 notify（按 actionGroupKey 传数量），
  /// 用户在本页改了树顶数量时要能改写回那张请求（[_patchRequestWithSeedQtys]）。
  /// 车间种子按 analysisLineId / materialLineId 定位，不需要它。
  final String? actionGroupKey;

  /// 被下达件的显示名（页面标题与逐行「来自」列用）。
  final String label;

  /// 本批数量（含超出需求的公共备货产出部分）——下层展开的驱动量。
  /// **可变**：页面树顶那行允许直接改（2026-09-14 用户口径「父类也能改数量，
  /// 一改其他的一起变动」），改完既驱动下层重算，也作为父件段的提交数量。
  double batchQty;

  /// 产品行（顶层产品或已建锚点子件）。
  final String? analysisLineId;

  /// 候选物料行（自制候选 / 有子层委外候选）。
  final String? materialLineId;

  final String? unitName;
}

/// 下层行按有效路线分流到的下达通道。
enum _CascadeKind {
  /// 采购 → 下达采购（notify BUY）。
  buy,

  /// 直接外发的委外件 → 下达委外（notify SUBCONTRACT，直接形成委外申请）。
  /// 包含两类：无子层的纯外协，以及 V581「只有一个叶子子件」的我方供料件
  /// （仓库发那个子件，委外商交回目标件）。枚举名沿用历史，不再等于「BOM 叶子」。
  subcontractLeaf,

  /// 自制 / **需要先自制目标件**的委外件 → 下达车间
  /// （issue-plans：建锚点 + 出计划，同一事务）。
  workshop,
}

extension _CascadeKindX on _CascadeKind {
  String get label => switch (this) {
    _CascadeKind.buy => '采购',
    _CascadeKind.subcontractLeaf => '委外',
    _CascadeKind.workshop => '车间',
  };

  /// 未下达时的第一步（全站统一流程词表，见 生产物料分析页 §3.7）。
  String get pendingStage => switch (this) {
    _CascadeKind.buy => '等待下发采购',
    _CascadeKind.subcontractLeaf => '等待下发委外',
    _CascadeKind.workshop => '等待下达车间',
  };
}

/// 展开阶段的中间结果：一条 BOM 路径 + 它在本批下的毛需求。
typedef _CascadeNode = ({
  /// 快照里的物料行。树顶行在「顶层产品且快照没有 ROOT_SUPPLY 行」时为 null，
  /// 身份改由 [product] 提供——那时也没有任何下层可挂，但树顶那一行必须在，
  /// 否则「最上面是被下达的那个件」直接不成立（用户诉求 1）。
  ProductionMaterialAnalysisMaterial? material,
  ProductionMaterialAnalysisProduct? product,
  int depth,

  /// 第几棵树（一次勾多行下达 = 多棵树平铺在同一张表）。只有同树的行才
  /// 互为兄弟——否则连线会从上一棵树一路画到下一棵树。
  int treeIndex,
  String seedLabel,

  /// 驱动本节点的上层行（null = 直接由种子驱动）。
  String? parentMaterialLineId,

  /// 驱动方的单位耗用（种子 = 种子除数），用于「改上层数量 → 下层重算」。
  double parentPerProduct,

  /// 本批毛需求：按直属 BOM 边计量并向上保留四位基本量。
  double grossNeed,

  /// 毛需求是否真按本批数量放大过（false = 缺单位耗用的历史行，退回快照需求）。
  bool scaled,

  /// 刚下达的那个件本身：树顶行（用户口径「最上面就是点击下达车间的」），
  /// 不参与提交单元合并、不可勾选；数量可直接改（2026-09-14）。
  bool isSeed,

  /// 树顶行挂回它的种子（改父件数量 → 回写 batchQty + 驱动下层重算）。
  _ChildCascadeSeed? seed,

  /// 本节点吸收了哪颗勾选行的种子 (2026-09-16)：该行在分桶页也被勾选了，但它
  /// 是本树祖先的 BOM 后代，所以作为普通下层行留在这里 (数量随祖先重算)，
  /// 分桶页填的车间/负责人经它带进来。null = 普通节点。
  _ChildCascadeSeed? absorbedSeed,
});

/// 下层办齐弹窗里的一行（与下达车间桶同一张 UtenEditableGrid）。
class _ChildCascadeRow extends EditableGridRow {
  _ChildCascadeRow({
    required this.material,
    required this.product,
    required this.groupKey,
    required this.submitKey,
    required this.depth,
    required this.treeIndex,
    required this.seedLabel,
    required this.route,
    required this.kind,
    required this.parentMaterialLineId,
    required this.parentPerProduct,
    required this.grossNeed,
    required this.pathGrossNeed,
    required this.snapshotNeed,
    required this.residual,
    required this.overspill,
    required this.minQty,
    required this.suggested,
    required this.scaled,
    required this.ownsInput,
    required this.mergedPathCount,
    required this.blockedReason,
    required this.overCapped,
    this.isSeed = false,
    this.seed,
    this.anchorAnalysisLineId,
  }) {
    if (ownsInput && suggested > 0) qty.text = _bucketQtyText(suggested);
  }

  /// 树顶那行 = 本次要下达的件本身（下层数量都由它的本批数量驱动；
  /// 2026-09-14 起数量可直接改，改完回写种子并驱动下层重算）。
  final bool isSeed;

  /// 树顶行挂回它的种子；非树顶行为 null。
  final _ChildCascadeSeed? seed;

  /// 本行物料已经建过自制子件任务 / 委外前置自制任务时，那条锚点产品行
  /// (MAKE_COMPONENT / SUBCONTRACT_MAKE) 的 id (2026-09-16)。
  ///
  /// 原来这类行一律「本页不重复下达，请到下达车间对那个任务排产」——可用户
  /// 多选时恰恰会把父件和这些已建任务的子件一起勾上，改父件数量却没人跟着变。
  /// 现在：锚点还有剩余可排量 (`canSchedule` 且 remainingQty > 0) 就直接按
  /// 锚点产品行 (`analysisLineId`) 下达车间，追加到同一个任务上；剩余为 0 的
  /// 才阻断 (canSchedule 资格闸早于数量校验，V577 没有也不该放开它)。
  /// 车间段据此分流：有锚点走 planDrafts，没锚点走 candidateInputs。
  final String? anchorAnalysisLineId;

  /// 快照里的物料行；「顶层产品且无 ROOT_SUPPLY 行」的树顶行为 null。
  final ProductionMaterialAnalysisMaterial? material;

  /// [material] 为 null 的树顶行的身份来源。
  final ProductionMaterialAnalysisProduct? product;

  /// 第几棵树（同一张表里可能平铺多棵）。只有同树同深度的行才互为兄弟。
  final int treeIndex;

  /// 本行在当前快照里的 `_MaterialGroup.key`（路线确认 / 下达按它定位）。
  final String groupKey;

  /// 提交单元身份 = actionGroupKey ?? materialLineId。同一提交单元在树里
  /// 出现多次时只有第一处可填数量，其余行只作层级上下文。
  final String submitKey;

  /// 相对被下达件的层级（1 = 直接子件）。
  final int depth;
  final String seedLabel;
  final MaterialSupplyRoute route;
  final _CascadeKind kind;

  final String? parentMaterialLineId;
  final double parentPerProduct;

  /// 本批毛需求。持有输入框的行上是**该提交单元所有 BOM 路径之和**，
  /// 其余行是本路径自己的那份。
  double grossNeed;

  /// 本行这一条 BOM 路径自己的毛需求（合并前）。整表重算按它自顶向下推，
  /// 再汇总成 [grossNeed]。
  double pathGrossNeed;

  /// 提交单元级的库存/供给口径，与物料分析准备页主表逐列同义：
  /// - available：代表行的仓库可用现货（同货多路径看的是**同一个仓库池**，
  ///   求和会把一份库存重复计量成 N 份，所以取代表行不求和）。
  /// - shortage / additionalRecommended：按路径求和（它们是逐需求节点的量）。
  /// - inbound / sharedFuturePending：各路径一致才显示，不一致给 null（"—"），
  ///   避免拿一条路径的数字冒充整组。
  ({
    double? available,
    double? shortage,
    double? inbound,
    double? sharedFuturePending,
    double? additionalRecommended,
    String? expectedReadyDate,
  })
  stats = (
    available: null,
    shortage: null,
    inbound: null,
    sharedFuturePending: null,
    additionalRecommended: null,
    expectedReadyDate: null,
  );

  /// 服务端快照里这些路径的本批需求合计。
  final double snapshotNeed;

  /// 服务端口径的可下达余量（本批缺口 − 已在途）。
  final double residual;

  /// 超产造成的额外量 = max(0, 毛需求 − 快照需求)。
  double overspill;

  /// 本批毛需求扣除服务端已覆盖量后的净需，不重复采购现货或在途。
  /// 公共超量仍受路线与权限边界约束；采购起订量不属于硬下限。
  double minQty;

  /// 预填的建议下单量 = [minQty]，采购行再按货品的最小起订量 / 订货倍数
  /// 向上抬一次（软约束：抬出来的富余归公共备货，用户可以改回 [minQty]）。
  double suggested;

  /// 额外量因缺少超量下达权限被砍掉。
  bool overCapped;

  /// 本行毛需求是否真按本批数量放大过。false = 缺单位耗用（perProductQty）
  /// 的历史行，只能退回快照需求——必须在状态列如实标明，否则用户会以为
  /// 这行也跟着本批数量算好了。
  final bool scaled;

  final bool ownsInput;
  final int mergedPathCount;

  /// 非空 = 本行不能在这里下达（原因如实显示，不勾选）。
  final String? blockedReason;

  final TextEditingController qty = TextEditingController();
  final ValueNotifier<String?> departmentId = ValueNotifier<String?>(null);
  String? departmentName;
  bool workshopAutofilled = false;
  final ValueNotifier<String?> workerId = ValueNotifier<String?>(null);
  String? workerName;
  bool workerAutofilled = false;

  /// 用户手工改过本行数量：上层数量再变时不覆盖它。
  bool qtyTouched = false;

  /// 用户手工填进来的超产驱动量（只在 [qtyTouched] 时有意义）。
  ///
  /// 单独存一份，是因为重算必须**一趟自顶向下**：读输入框拿到的是本轮还没
  /// 写入的旧文本，父层数量往小改时孙层会继续按旧值算（2026-09-15 修正）。
  double manualDriverQty = 0;

  /// 基础需求已下过单的行：下游采购/委外申请联动（null = 未下过单或未加载，
  /// 走普通下达；加载失败不阻断，按无联动展示）。
  MaterialAnalysisSupplyLink? supplyLink;

  /// 基础需求已覆盖（还可下达=0）而本批超产又多出来的量：需要走「并入申请」
  /// 或「追加」通道，而不是普通下单。
  bool get supplementMode =>
      residual <= 0.0001 &&
      overspill > 0.0001 &&
      supplyLink != null &&
      (kind == _CascadeKind.buy || kind == _CascadeKind.subcontractLeaf);

  /// 并入已有申请：申请未分解出订货单，追加量直接把明细数量改大。
  ///
  /// 还要求**当前账号确实能调那个端点**：`PUT /purchase/requests/{id}/items/{itemId}/qty`
  /// 要 `purchase_request:view` + `purchase_order:decompose`，而计划员通常两个
  /// 都没有。不先判一下的话，界面会把行勾上、弹窗承诺「并入原申请」，一提交
  /// 就 403，并把整条一键下单卡在这一段（父件那时已经落库）。
  bool canAdjustPurchaseRequest = false;
  bool get adjustIntoRequest =>
      supplementMode && supplyLink!.adjustable && canAdjustPurchaseRequest;

  /// 可并入但本人没有采购侧权限：如实说明该找谁，不硬勾。
  bool get adjustNeedsPurchasePermission =>
      supplementMode && supplyLink!.adjustable && !canAdjustPurchaseRequest;

  /// 已分解出订货单 / 委外申请：问过用户后按追加另立申请（需超量权限）。
  bool get appendToOrdered => supplementMode && !supplyLink!.adjustable;

  /// 行身份：物料行用它的 materialLineId；无物料行的树顶用产品行 id 加前缀，
  /// 保证与任何 materialLineId 都不会撞（折叠状态、勾选集都按它索引）。
  String get id =>
      material?.materialLineId ?? 'PRODUCT|${product?.analysisLineId ?? ''}';
  String? get goodsId => material?.goodsId ?? product?.goodsId;
  String? get goodsName => material?.goodsName ?? product?.goodsName;
  String? get goodsCode => material?.goodsCode ?? product?.goodsCode;
  String? get colorName => material?.colorName ?? product?.colorName;
  String? get spec => material?.spec ?? product?.spec;

  /// 所属仓库 (V587) 的快照值: 货品平时归哪个仓管的主档归属, 既不是单据落点仓,
  /// 也不是物料分析的分析范围仓。归属是货品级事实, 物料行与产品行各自下发一份,
  /// 这里按 [goodsId] 同款优先级取。显示值还要过宿主的本会话覆盖表, 别直接用。
  String? get owningWarehouseNameSnapshot =>
      material?.owningWarehouseName ?? product?.owningWarehouseName;
  String? get owningWarehouseIdSnapshot =>
      material?.owningWarehouseId ?? product?.owningWarehouseId;

  /// 单位：树顶行的数量是**来源单位**（需求 10 箱就是 10），挂的根供给行
  /// 记的却是基本单位（200 件）——树顶一律显示产品的来源单位，不然会出现
  /// 「刚下达 10 件」这种错标（2026-09-14）。
  String? get unitName => isSeed
      ? (product?.unitName ?? seedUnitName ?? material?.unitName)
      : material?.unitName;

  /// 种子带过来的来源单位名（分桶页那一行显示的单位）。
  String? seedUnitName;

  MaterialSupplyRoute? get confirmedRoute => material?.confirmedRoute;
  String? get actionGroupKey => material?.actionGroupKey;

  /// 显示名（提示、校验点名、二次确认弹窗统一走它）。
  String get displayName => goodsName ?? goodsCode ?? id;

  /// 可勾选可下达：有输入框、无阻断原因，且（有建议量 或 可并入已有申请——
  /// 并入走采购侧 sanctioned 入口，权限由该端点自裁，不吃分析侧超量闸）。
  ///
  /// 2026-09-14 追加一条：**已分解出订货单**的行不在本页勾选。这类行本批需求
  /// 已全部转成下游单据，分析侧的提交单元已不可执行（`_isExecutableSupplyGroup`
  /// 的 `_hasSupplySubmitQty` 为假），勾了必然在采购段被整段挡住、把一键下单
  /// 卡死；正确去处是到采购/委外模块对那张单追加。
  bool get selectable =>
      !isSeed &&
      ownsInput &&
      blockedReason == null &&
      !appendToOrdered &&
      !workshopFullyConverted &&
      (suggested > 0.0001 || adjustIntoRequest);

  /// 车间去向、本批需求已全部转成计划（还可下达 = 0），只剩超产多出来的量。
  ///
  /// 这种行**不能**在本页下达：服务端的排产资格闸（`canSchedule` / 已下达
  /// 自制归属）早于数量校验，必拒 400/409，一拒就把整条一键下单卡在车间段。
  /// V577 放开的是「本批数量可以高于剩余需求」，不是「需求已清零还能再下一张」。
  bool get workshopFullyConverted =>
      !isSeed &&
      kind == _CascadeKind.workshop &&
      residual <= 0.0001 &&
      overspill > 0.0001;

  /// 本行要不要指定生产车间与负责人。
  ///
  /// 2026-09-15：树顶（父件）行也算——用户口径「父件也要有车间还有负责人选项，
  /// 限制也要有」。此前这里硬写 `!isSeed`，配合 `_canAssignWorkshop` 里的
  /// `ownsInput`（树顶恒为 false）把整格钉死成一句「车间在上一页已经填过」，
  /// 而这句话对「下达委外」入口根本不成立：委外桶没有车间列，真正需要车间的
  /// 是委外下达后建出来的前置自制任务。要不要车间改由种子的通道决定。
  bool get needsWorkshop => isSeed
      ? (seed?.needsWorkshop ?? false)
      : (ownsInput && kind == _CascadeKind.workshop);

  double get enteredQty => double.tryParse(qty.text.trim()) ?? 0;

  /// 按父层数量算出来的**本行下限**：低于它，父件就备不齐这批料。
  ///
  /// = 扣除已覆盖量后的本批净需([minQty])，按权限限制公共超量。用户口径
  /// 「根据父层算出来需要 5 个，可以填大于 5，不能填小于 5」。
  ///
  /// **不含**采购起订量抬出来的那部分：那是软约束（`_defaultSubmitQty` 的契约
  /// 写明「计划员可以改小，服务端不硬拦」），拿它当硬下限会把「需求 430、
  /// 起订量 500」的行卡死在红框里（2026-09-15 修正）。
  /// 「并入已有采购申请」的行不吃这条：它的量是往原申请上追加，下限由采购侧自裁。
  double get minRequiredQty => adjustIntoRequest ? 0 : minQty;

  /// 当前填写是否低于下限（实时判定，数量框每次变更都会重算）。
  bool get belowMinimum =>
      !isSeed &&
      ownsInput &&
      blockedReason == null &&
      minRequiredQty > 0.0001 &&
      enteredQty < minRequiredQty - 0.0001;

  /// 低于下限时给人看的完整解释（悬停提示 + 提交拦截共用同一句）。
  ///
  /// 「已被覆盖」只能从毛需求里扣，且不允许出现负数——2026-09-15 之前它是
  /// `毛需求 − 下限` 反推的，下限含起订量抬量时会打印出「已覆盖 −70」这种数字。
  String shortfallHint(String Function(double? value) qtyText) {
    final covered = grossNeed - minQty;
    return '本行至少要下 ${qtyText(minRequiredQty)}：'
        '按父件本批数量算，这批要用 ${qtyText(grossNeed)}'
        '${covered > 0.0001 ? '，现有可用与在途已覆盖 ${qtyText(covered)}' : ''}，'
        '缺口 ${qtyText(minRequiredQty)} 必须本次下齐。'
        '现在填的是 ${qtyText(enteredQty)}，还差 '
        '${qtyText(minRequiredQty - enteredQty)}，这样父件会缺料。'
        '可以填得比下限多（多出来的进公共备货），但不能少。';
  }

  @override
  void dispose() {
    qty.dispose();
    departmentId.dispose();
    workerId.dispose();
    super.dispose();
  }
}

/// 一键下单的逐段结果（成功段与失败点都如实回报，不合并成一句「已完成」）。
typedef _CascadeStepResult = ({String label, int count, bool ok, String? note});
