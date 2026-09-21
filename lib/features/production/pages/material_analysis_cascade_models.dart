part of 'production_material_analysis_page.dart';

/// 父件 + 下层一起下单（ADR-081；2026-09-21 ADR-099 改为**服务端算量**）：
/// 在分桶页点「创建生产计划 / 下达委外」时，若被下达件的 BOM 还有没下单的
/// 下层，先进这张与准备页同款的层级表——树顶是被下达件本身，下面是子层 /
/// 孙层。下层的需求、还需安排量全部来自服务端：车间通道先按同一套代码跑一遍
/// 「下达预览」（服务端真实执行 issue-plans 再整体回滚，库里不留痕迹）拿到
/// 「下达之后」的快照；直接外发的委外通道用当前快照即可（它的子件需求本来
/// 就不依赖通知量）。浏览器不再按单耗自行相乘、不再猜「超产多需」。
///
/// 一键下单仍是**有序编排 + 逐段如实回报**（不是一个事务）：先父件（车间走
/// issue-plans / 委外走 notify），成功后按最新真实快照重建下层行并继承已填
/// 数量，再按路线分流——采购行走下达采购、直接外发委外行走下达委外、自制与
/// 需先自制的委外行回到下达车间。任一段失败即停下、不静默继续，已成功的段
/// 保留（幂等键可重放），页面按最新快照重算后留在原地供重试。

/// 树顶那一行（= 本次要下达的件）走哪条通道。
enum _CascadeParentChannel {
  /// 下达车间：issue-plans（顶层产品 / 已建锚点子件 / 自制候选 / 需先自制
  /// 目标件的有子层委外件）。数量可超量（V577，超出部分记公共备货产出），
  /// 必须有车间 + 负责人；下层数字由服务端预览给出。
  workshop,

  /// 下达委外，直接外发（无子层，或 V581「只有一个叶子子件」的我方供料件）。
  /// notify 一步到位形成委外申请，可分批、可按权限超量，不需要车间。
  subcontractDirect,
}

/// 一次下达里的一行，既是下层展开的起点，也是**父件段完整的提交意图**
/// （ID + 本批数量 + 上限 + 车间 + 负责人；车间 / 负责人是用户输入，不随
/// 服务端快照失效）。
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
    this.publicSurplusOnly = false,
  });

  /// 本行走哪条通道（决定数量约束与要不要车间/负责人）。
  final _CascadeParentChannel channel;

  /// ADR-099：树顶是「需求已全部转入计划」的产品行，本批全部是追加的公共备货
  /// 产出——预览与真实下达都要显式声明，服务端才放行（不声明照旧 409）。
  final bool publicSurplusOnly;

  /// 本行在分桶页对应的操作组键 (`_MaterialGroup.key`)。委外 notify 请求按它
  /// 定位行。
  final String? groupKey;

  /// 分桶页已经对「本批数量超出需求」问过一次确认。没问过的（委外桶改走
  /// issue-plans 的行）级联页提交前要补问。
  final bool overQtyConfirmed;

  /// 本次可下达上限（车间入口 = 产品剩余需求 / 候选剩余量；委外入口 =
  /// 服务端剩余需求）。null = 拿不到上限，此时只校验「> 0」。
  /// 超过它不是错误，但必须像分桶页一样过一次超量二次确认。
  final double? maxQty;

  /// 生产车间 / 负责人。**可变**：树顶那一行可以直接改，改完回写到这里，
  /// 父件段读它。
  String? departmentId;
  String? departmentName;
  String? workerId;
  String? workerName;

  /// 车间 / 负责人是系统带出来的默认值（学习默认或车间主管），不是用户亲手
  /// 选的——级联页同样要标黄提醒核对。
  bool workshopAutofilled;
  bool workerAutofilled;

  /// 走 issue-plans 的行要填车间 / 负责人；直接外发的委外件整件发给委外商，
  /// 我方不排产，不需要。
  bool get needsWorkshop => channel == _CascadeParentChannel.workshop;

  /// 委外种子的提交单元键：父件段走 notify（按 actionGroupKey 传数量），
  /// 用户在本页改了树顶数量时要能改写回那张请求。
  final String? actionGroupKey;

  /// 被下达件的显示名（页面标题与逐行「来自」列用）。
  final String label;

  /// 本批数量（含超出需求的公共备货产出部分）。**可变**：树顶那行允许直接改，
  /// 改完重新向服务端要一份预览，下层随之重算；它也是父件段的提交数量。
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
  /// 包含两类：无子层的纯外协，以及 V581「只有一个叶子子件」的我方供料件。
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

/// 展开阶段的中间结果：一条 BOM 路径。数量不在这里——全部读服务端快照。
typedef _CascadeNode = ({
  /// 快照里的物料行。树顶行在「顶层产品且快照没有 ROOT_SUPPLY 行」时为 null，
  /// 身份改由 [product] 提供。
  ProductionMaterialAnalysisMaterial? material,
  ProductionMaterialAnalysisProduct? product,
  int depth,

  /// 第几棵树（一次勾多行下达 = 多棵树平铺在同一张表）。
  int treeIndex,
  String seedLabel,

  /// 树顶行（本次要下达的件本身）。
  bool isSeed,
  _ChildCascadeSeed? seed,
});

/// 下层办齐页里的一行（与下达车间桶同一张 UtenEditableGrid）。
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
    required this.requiredQty,
    required this.residual,
    required this.claimableQty,
    required this.suggested,
    required this.ownsInput,
    required this.mergedPathCount,
    required this.blockedReason,
    this.allowsExtra = false,
    this.orderedQty = 0,
    this.growableLineQty,
    this.orderedDocumentNo,
    this.isSeed = false,
    this.seed,
    this.anchorAnalysisLineId,
    this.preparationAnchorAnalysisLineId,
  }) {
    if (ownsInput && suggested > 0) {
      qty.text = _bucketQtyText(suggested);
    } else if (ownsInput && allowsExtra) {
      // 已下达行的「追加量」默认就写 0（用户口径 2026-09-21）：勾着不动 = 这一行
      // 本次不下，要追加才改成正数。0 是合法值，不再当成「没填」。
      qty.text = '0';
    }
  }

  /// 还需安排为 0 时还能不能填「追加量」（用户口径 2026-09-21：即使采购 /
  /// 委外已下达甚至已处理，父层级这里还是可以追加，多下的属公共备货）。
  /// 采购 / 直接外发委外恒可；已建自制任务的行看锚点 canIssueSurplus；没建
  /// 过任务的自制候选不可（服务端对已被覆盖的候选拒绝建锚）。
  final bool allowsExtra;

  /// 本提交单元此前已下达的量（未撤销下游行动分摊之和）；0 = 从没下过。
  final double orderedQty;

  /// 最近一条**仍未被采购 / 委外部门处理**的申请明细当前数量（服务端
  /// growableLineQty）：追加会直接改到那张申请上。null = 没有这样的明细
  /// （没下过，或已在处理 / 已订货——追加会另立新申请）。
  final double? growableLineQty;

  /// 最近一条下游单据的单号（状态列点名用）。
  final String? orderedDocumentNo;

  /// 填的数量超出还需安排量的部分 = 主动追加，属公共备货。
  double get extraQty {
    final extra = enteredQty - residual;
    return extra > 0.0001 ? extra : 0;
  }

  /// 本行没有「还需安排」的下限，格里那个数纯粹是追加量（0 = 本次不下它）。
  bool get isAppendOnly => !isSeed && ownsInput && minRequiredQty <= 0.0001;

  /// 本次真的要为这一行下单吗（填 0 的追加行不进提交集合）。
  bool get willSubmit => !isAppendOnly || enteredQty > 0.0001;

  /// 树顶那行 = 本次要下达的件本身（数量可直接改，改完重新预览）。
  final bool isSeed;

  /// 树顶行挂回它的种子；非树顶行为 null。
  final _ChildCascadeSeed? seed;

  /// 本行物料已经建过自制子件任务时那条锚点产品行的 id：车间段按锚点追加下达
  /// （planDrafts）。需先自制的委外件不走锚点——按候选行提交，服务端的
  /// ARRANGE 段自己给既有台账增量。
  final String? anchorAnalysisLineId;

  /// 有自制子层的委外件已经建过「前置自制任务」时那条锚点产品行的 id。
  ///
  /// **只用于两件事**：① 判定这一行还能不能再追加（锚点的 canSchedule /
  /// canIssueSurplus）；② 提交时声明 `publicSurplusOnly`。它**不**改变提交通道
  /// ——追加仍按候选行走 issue-plans 的 ARRANGE 段，委外台账才会跟着量走
  /// （V589）；改走 planDrafts 会绕开台账。
  final String? preparationAnchorAnalysisLineId;

  /// 快照里的物料行；「顶层产品且无 ROOT_SUPPLY 行」的树顶行为 null。
  final ProductionMaterialAnalysisMaterial? material;

  /// [material] 为 null 的树顶行的身份来源。
  final ProductionMaterialAnalysisProduct? product;

  /// 第几棵树（同一张表里可能平铺多棵）。
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

  /// 服务端快照里这行的本批需求（持有输入框的行 = 该提交单元全部路径之和）。
  /// 父件按超过需求的数量下达时，这里已经是按计划产出量放大过的值。
  final double requiredQty;

  /// 服务端口径的还需安排量：采购 / 直接外发委外 = 本批缺口 − 已在途；
  /// 已建自制任务的行 = 锚点剩余可排量；其余自制 / 需先自制的委外 = 本批
  /// 缺口 − 已在途（含既有前置自制台账未通知量）。
  final double residual;

  /// 此刻可自动认领的同主仓公共在途（只对采购 / 直接外发委外有意义）。
  /// 下达时服务端先认领它，只为余下部分新下单。
  final double claimableQty;

  /// 预填的下单量 = [residual]，采购行再按货品的最小起订量 / 订货倍数向上
  /// 抬一次（软约束：抬出来的富余归公共备货，用户可以改回 [residual]）。
  final double suggested;

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

  /// 用户手工改过本行数量：重新预览重建行集时保留它。
  bool qtyTouched = false;

  /// 行身份：物料行用它的 materialLineId；无物料行的树顶用产品行 id 加前缀。
  String get id =>
      material?.materialLineId ?? 'PRODUCT|${product?.analysisLineId ?? ''}';
  String? get goodsId => material?.goodsId ?? product?.goodsId;
  String? get goodsName => material?.goodsName ?? product?.goodsName;
  String? get goodsCode => material?.goodsCode ?? product?.goodsCode;
  String? get colorName => material?.colorName ?? product?.colorName;
  String? get spec => material?.spec ?? product?.spec;

  /// 所属仓库 (V587) 的快照值。显示值还要过宿主的本会话覆盖表。
  String? get owningWarehouseNameSnapshot =>
      material?.owningWarehouseName ?? product?.owningWarehouseName;
  String? get owningWarehouseIdSnapshot =>
      material?.owningWarehouseId ?? product?.owningWarehouseId;

  /// 单位：树顶行的数量是**来源单位**（需求 10 箱就是 10），挂的根供给行
  /// 记的却是基本单位——树顶一律显示产品的来源单位。
  String? get unitName => isSeed
      ? (product?.unitName ?? seedUnitName ?? material?.unitName)
      : material?.unitName;

  /// 种子带过来的来源单位名（分桶页那一行显示的单位）。
  String? seedUnitName;

  MaterialSupplyRoute? get confirmedRoute => material?.confirmedRoute;
  String? get actionGroupKey => material?.actionGroupKey;

  /// 显示名（提示、校验点名、二次确认弹窗统一走它）。
  String get displayName => goodsName ?? goodsCode ?? id;

  /// 可勾选可下达：有输入框、无阻断原因，且服务端还有可下达量**或**本行允许
  /// 追加（还需安排 0 也能填追加量）。默认只勾还有缺口的行。
  bool get selectable =>
      !isSeed &&
      ownsInput &&
      blockedReason == null &&
      (suggested > 0.0001 || allowsExtra);

  /// 本行要不要指定生产车间与负责人：树顶看种子通道；下层行看去向。
  bool get needsWorkshop => isSeed
      ? (seed?.needsWorkshop ?? false)
      : (ownsInput && kind == _CascadeKind.workshop);

  double get enteredQty => double.tryParse(qty.text.trim()) ?? 0;

  /// 本行下限 = 服务端算出的还需安排量：低于它，父件就备不齐这批料
  /// （用户口径「根据父层算出来需要 5 个，可以填大于 5，不能填小于 5」）。
  /// 采购起订量抬出来的部分是软约束，不进下限。
  double get minRequiredQty => residual;

  bool get belowMinimum =>
      !isSeed &&
      ownsInput &&
      blockedReason == null &&
      minRequiredQty > 0.0001 &&
      enteredQty < minRequiredQty - 0.0001;

  String shortfallHint(String Function(double? value) qtyText) {
    final covered = requiredQty - residual;
    return '本行至少要下 ${qtyText(minRequiredQty)}：'
        '按父件本批数量算，这批要用 ${qtyText(requiredQty)}'
        '${covered > 0.0001 ? '，现有可用与在途已覆盖 ${qtyText(covered)}' : ''}，'
        '还需安排 ${qtyText(minRequiredQty)} 必须本次下齐。'
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

/// 进页判定的结果：下层行、进不进页的原因、行集来自哪份快照（车间通道 =
/// 服务端下达预览；直接外发委外 = 当前快照）。
typedef _CascadePending = ({
  List<_ChildCascadeRow> rows,
  String? note,
  ProductionMaterialAnalysisView? view,
});
