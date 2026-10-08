part of 'production_material_analysis_page.dart';

/// Material rows retain their source identities and existing quantity inputs.
/// Aggregate totals own the intent; server allocations synchronize source inputs.
final class _MaterialAggregateTableController {
  _MaterialAggregateTableController(this.owner);
  final _MaterialAnalysisMaterialTableState owner;
  late final submission = _MaterialAggregateSubmission(this);
  final editors = <String, TextEditingController>{};
  final rateEditors = <String, TextEditingController>{};
  final _draftByLine = <String, String>{};
  final drafts = <String, _MaterialAggregateDraft>{};
  Timer? _debounce;
  CancelToken? _cancelToken;
  Future<void>? _flight;
  String? _flightSignature;
  int _previewGeneration = 0;
  int _revision = 0;
  bool saving = false, uncertain = false;
  String? error;
  MaterialAggregateOrderRequest? _previewRequest, _submittedRequest;
  MaterialAggregateOrderPreview? _preview;
  String? _submittedFingerprint;
  String? _previewSignature;
  MaterialAggregateOrderResult? lastStageResult;
  bool get hasDrafts => drafts.isNotEmpty;
  bool ownsLine(String lineId) => _draftByLine.containsKey(lineId);
  bool isProductFlow(String lineId) =>
      drafts[_draftByLine[lineId]]?.productFlow == true;

  void analysisChanged() {
    if (drafts.isEmpty) return;
    _revision++;
    _preview = null;
    _previewRequest = null;
    for (final draft in drafts.values) {
      draft.previewGroups = const [];
      // 新快照里各来源的「还需安排」可能变了：手输总量的草稿按新的需要
      // 重新平分，两视图的数字才不会一边旧一边新。
      _applyLocalSplit(draft);
    }
    if (!saving && !uncertain) schedulePreview();
  }

  Widget lockedText(String value) =>
      Tooltip(message: '本次数量已保留，可继续下单核对结果；需要改数时先撤销未提交草稿。', child: Text(value));

  Widget actionCell(_MaterialAggregate aggregate) {
    final actionIds = <String>{
      for (final path in aggregate.paths)
        for (final target in path.notifiedTargets)
          if (target.actionId != null &&
              target.status != 'CANCELLED' &&
              owner._supplyOperationType(target.actionId) == 'AGGREGATE_SUPPLY')
            target.actionId!,
    };
    // 来源车间 / 负责人 / 比例不同时，这一行下单会自动分成几张工单
    // (ADR-120 §8)：在办理列直接写明，悬浮逐张列出参数和数量。
    final split = splitNote(aggregate);
    final note = split == null
        ? null
        : Tooltip(
            message: split.detail,
            child: Text(
              split.headline,
              key: ValueKey('material-aggregate-split-${aggregate.key}'),
            ),
          );
    if (actionIds.isEmpty) {
      // 单一来源的量会并入既有车间计划 / 订货单而不另开汇总批次
      // (AggregateMaterialOrderWriteService.issueExistingSingleSource)：这类行
      // 名下没有可整批撤回的批次，但数量格已锁、确实下过单——如实标注去向，
      // 不再误显「勾选后下单」让人以为这行没下成。
      if (orderedQty(aggregate) > 0.000000001) {
        final merged = Tooltip(
          message:
              '本行的量已并入来源既有的车间计划或订货单，未另开汇总批次。'
              '撤回请在「按产品办理」视图的供给任务与撤回，或直接处理那张单据。',
          child: Text(
            '已并入既有单据',
            key: ValueKey('material-aggregate-merged-${aggregate.key}'),
          ),
        );
        return note == null
            ? merged
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [merged, note],
              );
      }
      return note ?? const Text('勾选后下单');
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final id in actionIds)
          TextButton(
            key: ValueKey('material-aggregate-cancel-$id'),
            onPressed: owner._busy || !owner._canCancelSpecificAction(id)
                ? null
                : () => unawaited(cancelAction(id)),
            child: Text('整批撤回 ${owner._supplyActionOf(id)?.documentNo ?? ''}'),
          ),
        ?note,
      ],
    );
  }

  Future<bool> cancelAction(String actionId) async {
    final analysis = owner._analysis;
    if (analysis == null ||
        owner._busy ||
        !owner._canCancelSpecificAction(actionId)) {
      return false;
    }
    final affected = <ProductionMaterialAnalysisMaterial, double>{};
    for (final material in analysis.materials) {
      for (final target in material.notifiedTargets) {
        if (target.actionId == actionId && target.status != 'CANCELLED') {
          final allocated = target.allocatedQty;
          if (allocated == null) {
            owner.context.appWarning('此批次缺少完整来源份额，请刷新核对后再整批撤回');
            return false;
          }
          affected.update(
            material,
            (value) => value + allocated,
            ifAbsent: () => allocated,
          );
        }
      }
    }
    if (affected.keys.any((material) => ownsLine(material.materialLineId))) {
      owner.context.appWarning('此批次来源仍有汇总草稿，请先下达或撤销草稿再整批撤回');
      return false;
    }
    final action = owner._supplyActionOf(actionId)!;
    final allocated = affected.values.fold<double>(
      0,
      (sum, value) => sum + value,
    );
    if ((allocated - action.requestedQty).abs() > 0.00005) {
      owner.context.appWarning('此批次来源资料不完整，请刷新核对后再整批撤回');
      return false;
    }
    final public = action.publicSurplusQty;
    final total = allocated + public;
    var reason = '';
    final confirmed = await UtenDialog.show(
      owner.context,
      title: '整批撤回供给任务？',
      confirmLabel: '确认整批撤回',
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '将撤回本批全部来源，总量 ${owner._qty(total)}，其中公共备货 ${owner._qty(public)}。',
              ),
              for (final entry in affected.entries)
                Text(
                  '${sourceLabel(entry.key)}：${owner._qty(entry.value)} ${entry.key.unitName ?? ''}',
                ),
              const Text('已实际领用、报工或有后续单据的批次会由系统核对后阻止撤回。'),
              TextField(
                key: const Key('material-aggregate-cancel-reason'),
                onChanged: (value) => reason = value,
                maxLength: 1000,
                decoration: const InputDecoration(labelText: '撤回原因（选填）'),
              ),
            ],
          ),
        ),
      ),
    );
    reason = reason.trim();
    if (confirmed != true || !owner.mounted) return false;
    final key = businessIdempotencyKey(
      'material-aggregate-cancel',
      '$actionId|${analysis.analysisId}|${analysis.version}|${analysis.fingerprint}|$reason',
    );
    owner._mutateAggregateTable(() => owner._cancellingAction = true);
    try {
      final current = await owner.ref
          .read(productionPlanRepositoryProvider)
          .cancelAggregateMaterialOrder(
            analysis: analysis,
            actionId: actionId,
            idempotencyKey: key,
            reason: reason,
          );
      if (!owner.mounted) return false;
      owner._mutateAggregateTable(() => owner._applyAnalysis(current));
      owner.context.appSuccess('整批任务已撤回，来源需求已按最新事实更新');
      return true;
    } catch (failure) {
      if (owner.mounted) {
        owner.context.appWarning(
          productionErrorMessage(failure, fallback: '整批撤回失败，请核对后重试'),
        );
      }
      return false;
    } finally {
      if (owner.mounted) {
        owner._mutateAggregateTable(() => owner._cancellingAction = false);
      }
    }
  }

  Widget? toolbarAction() => drafts.isEmpty
      ? null
      : TextButton.icon(
          key: const Key('material-aggregate-cancel-drafts'),
          onPressed: saving ? null : () => unawaited(cancelAll()),
          icon: const Icon(Icons.undo_rounded),
          label: Text('撤销汇总草稿(${drafts.length})'),
        );

  Widget quantityCell(
    ThemeData theme,
    _MaterialAggregate aggregate, {
    required bool append,
  }) {
    final ordered = orderedQty(aggregate) > 0.000000001;
    final displayedOrder = issuedText(aggregate) ?? '无法确认';
    final breakdown = issuedBreakdown(aggregate);
    final cellKey = ValueKey(
      'material-aggregate-${append ? 'append' : 'order'}-${aggregate.key}',
    );
    if (append != ordered) {
      if (append) {
        return Text('0', key: cellKey);
      }
      // 已下达：与按产品视图的下单数量格同一锁定样式(锁图标 + 累计已下单)，
      // 裸文本会被读成「没锁住、还能改」(2026-09-25 用户实机误读)。
      return Tooltip(
        message:
            '累计已下单 $displayedOrder。'
            '${breakdown == null ? '' : '$breakdown。公共备货没有分配给某个产品，也不表示已合格入库。'}'
            '下达之后这一格不可改，要再下请填「追加下单」。',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.lock_outline_rounded,
              size: 13,
              color: Theme.of(owner.context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: UtenSpacing.s4),
            Flexible(
              child: Text(
                displayedOrder,
                key: cellKey,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  owner.context,
                ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            if (breakdown != null)
              const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Icon(Icons.info_outline_rounded, size: 14),
              ),
          ],
        ),
      );
    }
    final controller = editor(aggregate);
    final editableGroups = groupsOf(
      aggregate,
    ).where((group) => !inactiveSourceContext(group)).toList();
    final canEdit =
        editableGroups.isNotEmpty &&
        editableGroups.every(
          (group) =>
              group.representative.confirmedRoute != null &&
              !owner._dirtyRouteGroups.contains(group.key),
        );
    // 2026-09-25 用户口径「下单数量下面不要显示任何的」：原先挂在输入框下面的
    // 六段小字(待核对来源分配 / 其中公共备货 / 共享父批次新增用料 / 本次保留
    // N 个来源 / 预览 blockedReason / 预览错误)全部退役。被服务端拒绝的原因在
    // 点「下单」时由汇总提交流程统一说明，不在格子里常驻。
    // 2026-09-27 用户口径「输入的值不能低于还缺数量，边输入边判断，不对就
    // 红」：下单格加与按产品视图同一规则的实时下限(见 [orderFloor])；追加格
    // 没有下限。悬浮里讲清下限与平分去向，红框含义不再靠猜。
    final floor = append ? '0' : orderFloor(aggregate);
    final field = owner._materialTableQtyField(
      theme,
      key: 'material-aggregate-qty-${aggregate.key}',
      controller: controller,
      enabled:
          !owner._busy &&
          !uncertain &&
          canEdit &&
          (owner._canNotify || owner._canGenerate),
      hintText: owner._qty(pendingQty(aggregate)),
      onTyped: (value) => changed(aggregate, value),
      onFinished: append ? owner._finishPreparationQuantityEditing : null,
      invalid: () {
        final text = controller.text;
        if (!validText(text)) return true;
        if (append) return false;
        if (floor == 'NaN') return true;
        return materialQuantityUnits(text) < materialQuantityUnits(floor);
      },
    );
    return SizedBox(
      height: 40 * MediaQuery.textScalerOf(owner.context).scale(1),
      child: append
          ? field
          : Tooltip(
              message: floor == 'NaN'
                  ? '来源缺少可核对的精确数量，请刷新后重试。'
                  : materialQuantityUnits(floor) > BigInt.zero
                  ? '本次合计不能低于各来源「还需安排」的合计 $floor，'
                        '边输入边核对，低于它这格会标红并拦下下达。'
                        '超出需求的部分单独作为公共备货，实际归属以提交前预览为准。'
                  : '填多少下多少。超出需求的部分单独作为公共备货，'
                        '实际归属以提交前预览为准。',
              child: field,
            ),
    );
  }

  void dispose() {
    _debounce?.cancel();
    _cancelToken?.cancel('aggregate editor disposed');
    _revision++;
    _preview = null;
    _previewRequest = null;
    _submittedRequest = null;
    _submittedFingerprint = null;
    uncertain = false;
    drafts.clear();
    _draftByLine.clear();
    for (final controller in editors.values) {
      controller.dispose();
    }
    editors.clear();
    for (final controller in rateEditors.values) {
      controller.dispose();
    }
    rateEditors.clear();
  }

  TextEditingController editor(_MaterialAggregate aggregate) {
    final draft = drafts[aggregate.key];
    final value = draft?.totalText ?? owner._qty(pendingQty(aggregate));
    final controller = editors.putIfAbsent(
      aggregate.key,
      () => TextEditingController(text: value),
    );
    if (draft == null && controller.text != value) {
      final analysis = owner._analysis;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (owner.mounted &&
            identical(owner._analysis, analysis) &&
            identical(editors[aggregate.key], controller) &&
            !drafts.containsKey(aggregate.key)) {
          controller.text = value;
        }
      });
    }
    return controller;
  }

  _MaterialAggregateDraft begin(
    _MaterialAggregate aggregate, {
    List<_MaterialGroup>? scope,
  }) {
    final groups =
        scope ?? groupsOf(aggregate).where(selectableForOrder).toList();
    final existing = drafts[aggregate.key];
    if (existing != null) {
      var changed = false;
      for (final group in groups) {
        final line = group.representative.materialLineId;
        if (existing.paths.containsKey(line)) continue;
        existing.paths[line] = _snapshot(group);
        existing.sourceRequestedQtyByMaterialLineId?[line] = owner
            ._tableSubmitQtyTextOf(group);
        _draftByLine[line] = aggregate.key;
        changed = true;
      }
      if (changed) {
        if (existing.sourceRequestedQtyByMaterialLineId case final requested?) {
          existing.totalText = sumQuantityTexts(requested.values);
        }
        _revision++;
        existing.previewGroups = const [];
        _preview = null;
        _previewRequest = null;
        schedulePreview();
      }
      return existing;
    }
    return drafts.putIfAbsent(aggregate.key, () {
      final snapshots = <String, _MaterialAggregatePathSnapshot>{};
      for (final group in groups) {
        snapshots[group.representative.materialLineId] = _snapshot(group);
        _draftByLine[group.representative.materialLineId] = aggregate.key;
      }
      return _MaterialAggregateDraft(
          aggregate.key,
          aggregate.goodsName ?? aggregate.goodsCode ?? '物料',
          snapshots,
          sumQuantityTexts(groups.map(owner._tableSubmitQtyTextOf)),
        )
        ..appendFlow = orderedQty(aggregate) > 0.000000001
        ..sourceRequestedQtyByMaterialLineId = {
          for (final group in groups)
            group.representative.materialLineId: owner._tableSubmitQtyTextOf(
              group,
            ),
        }
        ..userEntered = snapshots.values.any((state) => state.hasExplicitQty);
    });
  }

  _MaterialAggregatePathSnapshot _snapshot(_MaterialGroup group) {
    final rate = owner._overproductionPercentController(
      materialLineId: group.representative.materialLineId,
    );
    return _MaterialAggregatePathSnapshot(
      groupKey: group.key,
      orderText: owner._tableOrderQtyController(group).text,
      appendText: owner._tableAppendQtyController(group).text,
      orderSeed: owner._tableSeededQtyTexts['ORDER|${group.key}'],
      appendSeed: owner._tableSeededQtyTexts['APPEND|${group.key}'],
      typedQty: owner._tableUserTypedQty[group.representative.materialLineId],
      selected: owner._selectedMaterialGroupKeys.contains(group.key),
      autoSelected: owner._tableAutoSelectedKeys.contains(group.key),
      deselected: owner._tableUserDeselectedKeys.contains(group.key),
      workshop: owner._tableWorkshopDraft[group.key],
      worker: owner._tableWorkerDraft[group.key],
      rate: rate.text,
      rateExplicit: owner._prefilledOverproductionRates.isExplicit(rate),
    );
  }

  void changed(_MaterialAggregate aggregate, String value) {
    if (saving || uncertain) return;
    owner._mutateAggregateTable(() {
      final draft = begin(aggregate);
      draft.totalText = value;
      draft.userEntered = true;
      draft.sourceRequestedQtyByMaterialLineId = null;
      draft.previewGroups = const [];
      _revision++;
      _preview = null;
      _previewRequest = null;
      error = null;
      for (final snapshot in draft.paths.values) {
        owner._selectedMaterialGroupKeys.add(snapshot.groupKey);
        owner._tableUserDeselectedKeys.remove(snapshot.groupKey);
      }
      // 敲键当场把总量平分回各来源行(2026-09-27 用户口径「汇总输入的值和
      // 按产品看要连通」)：不等 300ms 防抖 + 服务端预览往返——那 1~7 秒里
      // 切回按产品视图，看到的必须就是平分后的数。
      _applyLocalSplit(draft);
    });
    schedulePreview();
  }

  bool validText(String value) =>
      RegExp(r'^\d+(?:\.\d{0,4})?$').hasMatch(value.trim()) &&
      (double.tryParse(value)?.isFinite ?? false) &&
      (double.tryParse(value) ?? -1) >= 0;

  String sumQuantityTexts(Iterable<String> values) {
    var total = BigInt.zero;
    for (final value in values) {
      // An unfinished source input stays invalid until edited; never invent 0.
      if (!validText(value)) return 'NaN';
      total += materialQuantityUnits(value);
    }
    return materialQuantityText(total);
  }

  /// Business validation uses the exact source demand. Display rounding must
  /// neither turn 0.5 + 0.5 + 0.5 into 2 nor discard a real 0.0002 remainder.
  String _residualFloor(Iterable<_MaterialGroup> groups) {
    // 2026-10-06 用户口径「优先整数」：下限取最粗守恒整分总量（83.3334×3 的
    // 定点分摊尾巴按 1000 校验，不再逼人输 1000.0002）；真实分数需求
    //（0.5×3=1.5）噪声预算外，下限保持精确（2026-10-07 用户口径）。
    // 任一来源不可解析（含 build 期调用）fail closed 成 NaN → 红框拦下。
    try {
      return coalescedAggregateTotalText([
            for (final group in groups) owner._tableGroupResidualText(group),
          ]) ??
          'NaN';
    } on FormatException {
      return 'NaN';
    }
  }

  /// 汇总「下单数量」格的下限：参与来源(可选下单的组)的「还需安排」
  /// (毛口径 residual)合计——与按产品视图单行红框是同一条规则的总数版
  /// (2026-09-22 用户口径「输入小于需要就冒红」)：总量低于它，平分回去
  /// 必然有来源行低于自己的还需安排。已下达的汇总行走「追加下单」格，
  /// 追加是额外量、填多少都行，没有下限。
  String orderFloor(_MaterialAggregate aggregate) {
    if (orderedQty(aggregate) > 0.000000001) return '0';
    return _residualFloor([
      for (final group in groupsOf(aggregate))
        if (selectableForOrder(group)) group,
    ]);
  }

  /// 手输总量 → 各来源行的本地平分（2026-09-27 用户口径「按物料汇总输入的值
  /// 和按产品看要连通；三个产品同料合一起，需要 3000 填 6000，没下单切回按
  /// 产品看，每行下单数量变成 2000」）。
  ///
  /// 平分是**两视图之间的编辑态同步**，不是下单分配：真实下达仍由服务端按
  /// 「各来源需要量 + 公共备货」落账（上例下成来源 3000 + 公共 3000）。规则：
  /// - 先盖住每条来源自己的「还需安排」(毛口径 residual)，富余在**有需求的
  ///   来源**之间平均分；0 需求的兄弟行保持原样，不打扰它们「没有要下单的量」
  ///   的只读形态；全都无需求(纯公共备货)才全体均分；
  /// - 总量低于需要合计(红框态)时按需求占比缩放——行间仍是公平的；
  /// - 已下达的来源写「追加下单」格，未下达的写「下单数量」格，与提交读数、
  ///   服务端预览回写同一口径；
  /// - 清成空/0 = 交还系统：恢复草稿拍下的汇总前数值(撤销单行版)。
  /// 平分只服务手输总量的草稿；按产品「全选下单」并进来的草稿
  /// (productFlow，带逐行请求数)各行本来就是用户自己的数，不动。
  void _applyLocalSplit(_MaterialAggregateDraft draft) {
    if (!draft.userEntered ||
        draft.productFlow ||
        draft.sourceRequestedQtyByMaterialLineId != null) {
      return;
    }
    final groups = draftGroups(draft);
    if (groups.isEmpty) return;
    if (!validText(draft.totalText)) return;
    // 平分粒度跟着用户敲的小数位走(2026-10-06 用户口径「优先整数」)：整数
    // 总量落整数份额，83.3334 这类服务端分摊尾巴不再层层上屏。
    final List<String> shares;
    try {
      shares = splitTypedTotalText(draft.totalText, [
        for (final group in groups) owner._tableGroupResidualText(group),
      ]);
    } on FormatException {
      error = '来源缺少可核对的精确数量，请刷新后重试';
      return;
    }
    for (var i = 0; i < groups.length; i++) {
      final group = groups[i];
      final line = group.representative.materialLineId;
      final snapshot = draft.paths[line];
      if (materialQuantityUnits(shares[i]) == BigInt.zero) {
        // 平分不再给这一行分量(0 需求来源 / 需求已变化 / 总量清空)：
        // 恢复草稿拍下的原值，不把上一次平分的结果留在这行。
        _restoreSnapshotQty(group, snapshot);
        continue;
      }
      final append = owner._tableGroupIssued(group);
      final controller = append
          ? owner._tableAppendQtyController(group)
          : owner._tableOrderQtyController(group);
      final text = shares[i];
      if (controller.text != text) controller.text = text;
      // This numeric cache is for local availability estimates only. The
      // controller and wire retain the exact decimal text above.
      owner._tableUserTypedQty[line] = double.parse(text);
      owner._tableSeededQtyTexts.remove(
        '${append ? 'APPEND' : 'ORDER'}|${group.key}',
      );
    }
  }

  /// 恢复一条来源行在汇总草稿建立时的数量格状态(数量 / 预填快照 / 手填记号)。
  void _restoreSnapshotQty(
    _MaterialGroup group,
    _MaterialAggregatePathSnapshot? snapshot,
  ) {
    if (snapshot == null) return;
    final line = group.representative.materialLineId;
    final order = owner._tableOrderQtyController(group);
    final append = owner._tableAppendQtyController(group);
    if (order.text != snapshot.orderText) order.text = snapshot.orderText;
    if (append.text != snapshot.appendText) append.text = snapshot.appendText;
    void restoreSeed(String side, String? seed) {
      final key = '$side|${group.key}';
      if (seed == null) {
        owner._tableSeededQtyTexts.remove(key);
      } else {
        owner._tableSeededQtyTexts[key] = seed;
      }
    }

    restoreSeed('ORDER', snapshot.orderSeed);
    restoreSeed('APPEND', snapshot.appendSeed);
    if (snapshot.typedQty == null) {
      owner._tableUserTypedQty.remove(line);
    } else {
      owner._tableUserTypedQty[line] = snapshot.typedQty!;
    }
  }

  void schedulePreview() {
    if (saving ||
        uncertain ||
        drafts.isEmpty ||
        owner._preparationSubmissionActive) {
      return;
    }
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 300),
      () => unawaited(refreshPreview()),
    );
  }

  List<_MaterialGroup> draftGroups(
    _MaterialAggregateDraft draft, {
    bool requireComplete = false,
  }) => [
    for (final source in draftSources(draft, requireComplete: requireComplete))
      source.group,
  ];

  /// 草稿的来源行(草稿里的行 id 与它当前的办理组，按草稿顺序)。
  List<({String line, _MaterialGroup group})> draftSources(
    _MaterialAggregateDraft draft, {
    bool requireComplete = false,
  }) {
    final analysis = owner._analysis;
    if (analysis == null) return const [];
    final byLine = owner._analysisIndexes(analysis).groupsByLine;
    final sources = [
      for (final line in draft.lineIds)
        if (byLine[line] case final group?) (line: line, group: group),
    ];
    if (requireComplete && sources.length != draft.lineIds.length) {
      throw const FormatException('汇总来源已变化，请核对后撤销此草稿重新填写');
    }
    return sources;
  }

  /// 这批来源走不走车间通道：只有自制(ADR-143 起委外汇总永远是外部批次)。服务端对
  /// 自制(manufacture)一律要求车间 / 负责人 / 超产比例，权限也只看「下达车间」——
  /// 与 [workshopGroups] 同一口径。
  bool viaWorkshop(List<_MaterialGroup> groups) =>
      groups.isNotEmpty && owner._tableIssueTarget(groups.first).viaWorkshop;

  /// 超产比例按数值比较：'10' 与 '10.0' 是同一个比例、同一张工单。
  static double? _rateValue(String text) =>
      parseProductionOverproductionPercent(text);

  /// 一条来源此刻「怎么做」的参数：生产车间、负责人、超产比例。
  _MaterialAggregateMakeParams makeParams(_MaterialGroup group) {
    final workshop = owner._tableWorkshopFor(group);
    final worker = owner._tableWorkerFor(group);
    final rate = owner._overproductionPercentController(
      materialLineId: group.representative.materialLineId,
    );
    return _MaterialAggregateMakeParams(
      workshop: (id: workshop.id, name: workshop.name),
      worker: (id: worker.id, name: worker.name),
      rateText: rate.text,
      rateExplicit: owner._prefilledOverproductionRates.isExplicit(rate),
    );
  }

  /// ADR-120 §8「该分开的分开」：车间通道的来源按「生产车间 + 负责人 + 超产
  /// 比例(按数值)」分成几张工单——参数相同的来源并成一张，不同就各开一张，
  /// 不再报错要求先统一。本页不选班组，服务端合并键里的班组恒为空，不参与拆分；
  /// 父件也不参与，下层做好后送给哪个上层工单在报工时再分(见 ADR-127)。
  /// 采购 / 委外整组一张。只拆出一张时提交键就是草稿键；拆成多张时是
  /// 「草稿键|part-指纹」，指纹只由这张工单的参数决定，参数不变键就不变。
  /// 顺序稳定：按来源在 [sources] 里第一次出现的先后。
  List<_MaterialAggregatePart> partsOf(
    String draftKey,
    List<({String line, _MaterialGroup group})> sources, {
    required bool workshop,
  }) {
    final byKey = <String, _MaterialAggregatePart>{};
    for (final source in sources) {
      final params = workshop ? makeParams(source.group) : null;
      final part = byKey.putIfAbsent(
        params?.key ?? '',
        () => _MaterialAggregatePart(params),
      );
      // 同一张工单里只要有一条来源的比例是人定的，整张按人定的提交
      // (拆单键相同，车间 / 负责人 / 比例数值一致，只是显式标记不同)。
      if (params != null &&
          params.rateExplicit &&
          part.params != null &&
          !part.params!.rateExplicit) {
        part.params = params;
      }
      part
        ..lineIds.add(source.line)
        ..groups.add(source.group);
    }
    final parts = byKey.values.toList(growable: false);
    for (final part in parts) {
      part.clientGroupKey = parts.length == 1
          ? draftKey
          : '$draftKey|${businessIdempotencyKey('part', part.params!.key)}';
    }
    return parts;
  }

  static final _partKeySuffix = RegExp(r'\|part-[0-9a-f]{16}$');

  /// 提交 / 预览回包里的组键 → 草稿键(汇总行键)。见 [partsOf]。
  String draftKeyOf(String clientGroupKey) =>
      clientGroupKey.replaceFirst(_partKeySuffix, '');

  /// 草稿此刻会拆成的工单；来源供应方式不一致时不拆(提交时会被拦下)。
  List<_MaterialAggregatePart> draftParts(_MaterialAggregateDraft draft) {
    final sources = draftSources(draft);
    final groups = [for (final source in sources) source.group];
    final workshop =
        groups.map(owner._draftRoute).toSet().length == 1 &&
        viaWorkshop(groups);
    return partsOf(draft.key, sources, workshop: workshop);
  }

  /// 各张工单本次的数量(与 [parts] 同序)，合计恰为草稿总量。
  /// - 逐行带数的草稿(按产品全选下单、汇总前各行已有数)：每张工单 = 它那几行
  ///   自己的数，逐行数量原样随这张工单提交；
  /// - 手输总量的草稿：先按平分规则([splitTypedTotal])把总量落到
  ///   各来源行，再按工单相加。
  /// 按万分之一 BigInt 精确累加，各张合计必须等于原始总量。
  List<({String qty, Map<String, String>? sourceRequested})> partQuantities(
    _MaterialAggregateDraft draft,
    List<_MaterialAggregatePart> parts,
  ) {
    if (parts.length == 1) {
      return [
        (
          qty: draft.totalText,
          sourceRequested: draft.sourceRequestedQtyByMaterialLineId,
        ),
      ];
    }
    final requested = draft.sourceRequestedQtyByMaterialLineId;
    if (requested != null) {
      return [
        for (final part in parts)
          _requestedPart({
            for (final line in part.lineIds) line: ?requested[line],
          }),
      ];
    }
    final sources = draftSources(draft);
    final shares = splitTypedTotalText(draft.totalText, [
      for (final source in sources)
        owner._tableGroupResidualText(source.group, authoritative: true),
    ]);
    final shareByLine = {
      for (var i = 0; i < sources.length; i++) sources[i].line: shares[i],
    };
    final partUnits = [
      for (final part in parts)
        part.lineIds.fold<BigInt>(
          BigInt.zero,
          (sum, line) => sum + materialQuantityUnits(shareByLine[line]!),
        ),
    ];
    if (partUnits.fold(BigInt.zero, (sum, value) => sum + value) !=
        materialQuantityUnits(draft.totalText)) {
      throw FormatException('「${draft.label}」本次总量无法分到各张工单，请重新填写总量');
    }
    return [
      for (final value in partUnits)
        (qty: materialQuantityText(value), sourceRequested: null),
    ];
  }

  static ({String qty, Map<String, String>? sourceRequested}) _requestedPart(
    Map<String, String> subset,
  ) => (
    qty: materialQuantityText(
      subset.values.fold<BigInt>(
        BigInt.zero,
        (sum, qty) => sum + materialQuantityUnits(qty),
      ),
    ),
    sourceRequested: subset,
  );

  /// 分成多张工单的草稿里，每张工单在确认框 / 提示里的名字，按提交键取：
  /// 「(第 1 张，共 2 张：装配一车间 / 张三 / 超产 10%)」。没分开的草稿不加。
  Map<String, String> partLabels(Iterable<String> draftKeys) {
    final labels = <String, String>{};
    for (final key in draftKeys) {
      final draft = drafts[key];
      if (draft == null) continue;
      final parts = draftParts(draft);
      if (parts.length < 2) continue;
      for (var i = 0; i < parts.length; i++) {
        labels[parts[i].clientGroupKey] =
            '(第 ${i + 1} 张，共 ${parts.length} 张：${parts[i].label})';
      }
    }
    return labels;
  }

  /// 本次提交里这个草稿占几组(分成几张工单就是几组)，供分窗口计数。
  int requestGroupCount(_MaterialAggregateDraft draft) {
    final count = draftParts(draft).length;
    return count < 1 ? 1 : count;
  }

  /// 汇总行上把「会分成几张工单」讲明白(ADR-120 §8)：同一物料的来源车间、
  /// 负责人或超产比例不同，下单时自动各开一张，这一行只是合起来看。
  /// [headline] 挂在办理列，[detail] 逐张列出参数和本次数量。没有分开时为 null。
  ({String headline, String detail})? splitNote(_MaterialAggregate aggregate) {
    final draft = drafts[aggregate.key];
    final List<_MaterialAggregatePart> parts;
    List<String?> quantities;
    if (draft != null) {
      parts = draftParts(draft);
      if (parts.length < 2) return null;
      try {
        quantities = [
          for (final value in partQuantities(draft, parts)) value.qty,
        ];
      } on FormatException {
        quantities = List.filled(parts.length, null);
      }
    } else {
      final sources = [
        for (final group in groupsOf(aggregate).where(selectableForOrder))
          (line: group.representative.materialLineId, group: group),
      ];
      final groups = [for (final source in sources) source.group];
      if (groups.map(owner._draftRoute).toSet().length != 1 ||
          !viaWorkshop(groups)) {
        return null;
      }
      parts = partsOf(aggregate.key, sources, workshop: true);
      if (parts.length < 2) return null;
      quantities = [];
      for (final part in parts) {
        final total = part.groups.fold<double>(
          0,
          (sum, group) => sum + owner._tableSubmitQtyOf(group),
        );
        quantities.add(total.isFinite ? owner._qty(total) : null);
      }
    }
    final dimensions = [
      if (parts.map((part) => part.params!.workshop.id).toSet().length > 1)
        '车间',
      if (parts.map((part) => part.params!.worker.id).toSet().length > 1) '负责人',
      if (parts.map((part) => part.params!.rate).toSet().length > 1) '比例',
    ];
    final unit = aggregate.unitName ?? '';
    return (
      headline: '按${dimensions.join('/')}分成 ${parts.length} 张工单',
      detail: [
        '这些来源的${dimensions.join('、')}不同，下单时自动分成 ${parts.length} 张工单：',
        for (var i = 0; i < parts.length; i++)
          '第 ${i + 1} 张  ${parts[i].label}：${quantities[i] ?? '—'} $unit'
              .trimRight(),
        '要合成一张，就在这一行把车间、负责人和比例改成一样的。',
      ].join('\n'),
    );
  }

  MaterialAggregateOrderRequest requestFor(
    List<_MaterialAggregateDraft> selected, {
    bool skipAutoClaim = false,
  }) {
    final analysis = owner._analysis!;
    final inputs = <MaterialAggregateOrderGroupInput>[];
    final safetyDimensions = <String>{};
    for (final draft in selected) {
      if (!validText(draft.totalText)) {
        throw FormatException('「${draft.label}」请输入非负数量，最多四位小数');
      }
      final sources = draftSources(draft, requireComplete: true);
      final groups = [for (final source in sources) source.group];
      // 2026-09-27 用户口径「输入的值不能低于还缺数量」：手输总量的下单流草稿
      // 在红框之外由提交通道再拦一道。按产品「全选下单」并进来的草稿
      // (sourceRequested 逐行带着用户自己填的数，分批少下合法)与追加流(额外量)
      // 都不套这条下限。下限与红框([orderFloor])同为权威四位定点数，
      // 展示取整不得抬高真实小数需求，也不得吞掉小于一单位的真实缺口。
      if (draft.userEntered &&
          draft.sourceRequestedQtyByMaterialLineId == null &&
          !draft.appendFlow) {
        final floor = _residualFloor(groups);
        if (floor == 'NaN') {
          throw const FormatException('来源缺少可核对的精确数量，请刷新后重试');
        }
        if (materialQuantityUnits(draft.totalText) <
            materialQuantityUnits(floor)) {
          throw FormatException(
            '「${draft.label}」本次总量 ${draft.totalText} 不能低于各来源'
            '「还需安排」的合计 $floor；要分批少下请切到按产品逐行办理',
          );
        }
      }
      if (groups.any(
        (group) =>
            group.representative.isRootSupply ||
            group.representative.level <= 0,
      )) {
        throw const FormatException('顶层产品请切换按产品办理，不能作为组件汇总下达');
      }
      if (groups.any(
        (group) =>
            group.representative.confirmedRoute == null ||
            owner._dirtyRouteGroups.contains(group.key),
      )) {
        throw FormatException('「${draft.label}」还有来源未确认供应方式，请先确认');
      }
      final routes = groups.map(owner._draftRoute).toSet();
      if (routes.length != 1) {
        throw FormatException('「${draft.label}」各来源供应方式不同，请先统一设置');
      }
      // 上方已拒绝「confirmedRoute 为空」的来源，这里必有已确认路线。
      final route = routes.single!;
      final workshop = viaWorkshop(groups);
      if (workshop && !owner._canGenerate || !workshop && !owner._canNotify) {
        throw FormatException('没有下达「${draft.label}」的权限');
      }
      // 来源的车间 / 负责人 / 超产比例不同就自动分成几张工单(ADR-120 §8)，
      // 汇总行只是把它们合起来看。比例没人改过的来源按货品默认：提交时送
      // 空值由服务端填写且不记住(ADR-129 §2.10)；只有人改过且解析不出数值
      // 的才算「允许超产比例无效」。
      final parts = partsOf(draft.key, sources, workshop: workshop);
      if (workshop &&
          parts.any((part) => part.params!.rate == null && part.rateExplicit)) {
        throw FormatException('「${draft.label}」允许超产比例填写有误，请填不小于 0 的百分比');
      }
      final quantities = partQuantities(draft, parts);
      for (var i = 0; i < parts.length; i++) {
        final part = parts[i];
        inputs.add(
          MaterialAggregateOrderGroupInput(
            clientGroupKey: part.clientGroupKey,
            materialLineIds: [...part.lineIds]..sort(),
            route: route,
            qty: quantities[i].qty,
            sourceRequestedQtyByMaterialLineId: quantities[i].sourceRequested,
            allowPublicExtra: workshop || owner._canOverSupply,
            departmentId: part.params?.workshop.id,
            workerId: part.params?.worker.id,
            allowedOverproductionRate: part.rateExplicit
                ? part.params?.rate
                : null,
            // 公共安全补库只走采购；采购不按车间拆，一个物料至多一组。
            safetyQty:
                route == MaterialSupplyRoute.buy &&
                    safetyDimensions.add(draft.key)
                ? owner._groupSafetyReplenishmentGapText(groups.first)
                : '0',
          ),
        );
      }
    }
    final warehouse = owner._warehouseId;
    if (warehouse == null) throw const FormatException('请先选择分析仓库');
    final key = businessIdempotencyKey(
      'material-aggregate-orders',
      jsonEncode([
        analysis.analysisId,
        analysis.version,
        analysis.fingerprint,
        warehouse,
        owner._dateText(owner._billDate),
        owner._dateText(owner._deliveryDate),
        owner._preparationApproveNow,
        if (skipAutoClaim) 'skipAutoClaim',
        for (final input in inputs) input.toJson(),
      ]),
    );
    return MaterialAggregateOrderRequest(
      analysisId: analysis.analysisId,
      version: analysis.version,
      fingerprint: analysis.fingerprint,
      idempotencyKey: key,
      warehouseId: warehouse,
      billDate: owner._dateText(owner._billDate)!,
      deliveryDate: owner._dateText(owner._deliveryDate),
      approveNow: owner._preparationApproveNow,
      groups: inputs,
      skipAutoClaim: skipAutoClaim,
    );
  }

  Future<void> refreshPreview({
    Set<String>? keys,
    bool forSubmission = false,
    bool? skipAutoClaim,
  }) async {
    // 编辑预览重试应重读工具栏当前选择；提交显式指定的选择则必须贯穿整轮。
    final skipAutoClaimOverride = skipAutoClaim;
    skipAutoClaim ??= owner._preparationUseAvailableQty == false;
    _debounce?.cancel();
    if (saving || uncertain || drafts.isEmpty) return;
    if (!forSubmission && owner._preparationSubmissionActive) return;
    if (!owner.mounted || saving || uncertain || drafts.isEmpty) return;
    final requestRevision = _revision;
    final Set<String> effectiveKeys;
    try {
      effectiveKeys = keys ?? submission.previewRoots();
    } on FormatException catch (failure) {
      owner._mutateAggregateTable(() => error = failure.message);
      return;
    }
    if (effectiveKeys.isEmpty) return;
    final scope = effectiveKeys.toList()..sort();
    // 「足额下单(不扣可用数量)」要换一份带 skipAutoClaim 的提交请求：签名带上
    // 该标记，让编辑期不带标记的在途预览在提交时被取代而不是被复用。
    final signature =
        '$requestRevision|${scope.join('|')}|${owner._analysis?.version}|${owner._analysis?.fingerprint}|'
        '${owner._warehouseId}|${owner._dateText(owner._billDate)}|${owner._dateText(owner._deliveryDate)}|'
        '${owner._preparationApproveNow}'
        '${skipAutoClaim ? '|skipAutoClaim' : ''}';
    final flight = _flight;
    if (flight != null) {
      if (forSubmission && _flightSignature != signature) {
        // Only superseded reads are cancelled. A matching editor preview is
        // the mandatory preview too, so reuse it rather than duplicate work.
        _previewGeneration++;
        _cancelToken?.cancel('submission superseded aggregate preview');
        _cancelToken = null;
        _flight = null;
        _flightSignature = null;
      } else {
        await flight;
        if (!owner.mounted ||
            (!forSubmission && owner._preparationSubmissionActive)) {
          return;
        }
        return refreshPreview(
          keys: keys,
          forSubmission: forSubmission,
          skipAutoClaim: skipAutoClaimOverride,
        );
      }
    }
    if (_preview != null &&
        _previewSignature == signature &&
        _preview!.groups.every((group) => group.blockedReason == null)) {
      return;
    }
    late final Future<void> work;
    final generation = ++_previewGeneration;
    work =
        _performPreview(
          requestRevision,
          effectiveKeys,
          signature,
          generation,
          skipAutoClaim: skipAutoClaim,
        ).whenComplete(() {
          if (identical(_flight, work)) {
            _flight = null;
            _flightSignature = null;
          }
        });
    _flight = work;
    _flightSignature = signature;
    await work;
    if (_revision != requestRevision &&
        owner.mounted &&
        !saving &&
        !uncertain &&
        (forSubmission || !owner._preparationSubmissionActive)) {
      await refreshPreview(
        keys: keys,
        forSubmission: forSubmission,
        skipAutoClaim: skipAutoClaimOverride,
      );
    }
  }

  Future<void> _performPreview(
    int revision,
    Set<String>? keys,
    String signature,
    int generation, {
    bool skipAutoClaim = false,
  }) async {
    try {
      final selected = drafts.values
          .where((draft) => keys == null || keys.contains(draft.key))
          .toList();
      if (selected.isEmpty) return;
      final request = requestFor(selected, skipAutoClaim: skipAutoClaim);
      final token = CancelToken();
      _cancelToken = token;
      final preview = await owner.ref
          .read(productionPlanRepositoryProvider)
          .previewAggregateOrders(request, cancelToken: token);
      if (!owner.mounted ||
          revision != _revision ||
          generation != _previewGeneration) {
        return;
      }
      if (preview.analysisId != request.analysisId ||
          preview.analysis.analysisId != request.analysisId) {
        throw const FormatException('预览属于其他分析，未套用此结果');
      }
      final grouped = <String, List<MaterialAggregateOrderGroupPreview>>{};
      final materials = {
        for (final material in preview.analysis.materials)
          material.materialLineId: material,
      };
      final ownerIds = preview.analysis.products
          .map((product) => product.analysisLineId)
          .toSet();
      final sourceOrigins = <MaterialAggregateSourceAllocation, List<String>>{};
      final coveredByGroup = <String, Set<String>>{};
      for (final group in preview.groups) {
        final input = request.groups
            .where((input) => input.clientGroupKey == group.clientGroupKey)
            .firstOrNull;
        if (input == null) {
          throw const FormatException('预览返回了不属于本次汇总的来源，未套用此结果');
        }
        final requestedIds = input.materialLineIds.toSet();
        final covered = coveredByGroup.putIfAbsent(
          group.clientGroupKey,
          () => {},
        );
        for (final source in group.sources) {
          final effective = materials[source.materialLineId];
          if (effective == null ||
              !ownerIds.contains(effective.analysisLineId)) {
            throw const FormatException('预览结果不属于这份分析，本次没有套用，请刷新后重试');
          }
          final exactOrigins = [
            for (final id in input.materialLineIds)
              if (materials[id] != null &&
                  (source.materialLineId == id ||
                      (materials[id]!
                              .aggregatePreparation
                              ?.targetMaterialLineIds
                              .contains(source.materialLineId) ??
                          false)))
                id,
          ];
          // Older responses already carry the exact graph in analysis. Use
          // that proof only; never infer membership from SKU or row order.
          final originals = source.hasOriginalMaterialLineIds
              ? source.originalMaterialLineIds
              : exactOrigins;
          if (originals.isEmpty ||
              originals.any((id) => !requestedIds.contains(id))) {
            throw const FormatException('预览返回了不属于本次汇总的来源，未套用此结果');
          }
          if (originals.toSet().length != originals.length ||
              originals.length != exactOrigins.length ||
              !exactOrigins.toSet().containsAll(originals)) {
            throw const FormatException('预览来源证明与精确对应关系冲突，未套用此结果');
          }
          for (final originalId in originals) {
            final original = materials[originalId];
            if (source.materialLineId != originalId &&
                !(original?.aggregatePreparation?.targetMaterialLineIds
                        .contains(source.materialLineId) ??
                    false)) {
              throw const FormatException('预览结果对不上原来的来源行，本次没有套用，请刷新后重试');
            }
          }
          covered.addAll(originals);
          sourceOrigins[source] = originals;
        }
        // 分成几张工单的草稿(ADR-120 §8)回到同一个汇总行：各张的来源与
        // 数量都归这个草稿，逐张核对仍按上面的提交键各自做。
        grouped
            .putIfAbsent(draftKeyOf(group.clientGroupKey), () => [])
            .add(group);
      }
      for (final input in request.groups) {
        final covered =
            coveredByGroup[input.clientGroupKey] ?? const <String>{};
        if (!covered.containsAll(input.materialLineIds)) {
          throw const FormatException('预览没有完整核对本次所选来源，未套用此结果');
        }
      }
      for (final draft in selected) {
        final groups = grouped[draft.key] ?? const [];
        if (groups.isEmpty) throw const FormatException('汇总预览缺少所选物料，请重新核对');
        final allocated = groups.fold(
          0.0,
          (sum, group) =>
              sum +
              group.publicExtraQty +
              group.sources.fold(
                0.0,
                (sum, source) => sum + source.allocatedQty,
              ),
        );
        final exact = _exactPreviewContribution(groups);
        if (exact == null &&
            (double.parse(draft.totalText).abs() >= 10000000000 ||
                groups.any(
                  (group) =>
                      group.publicExtraQty.abs() >= 10000000000 ||
                      group.sources.any(
                        (source) => source.allocatedQty.abs() >= 10000000000,
                      ),
                ) ||
                materialQuantityUnits(
                      owner._qty(double.parse(draft.totalText)),
                    ) !=
                    materialQuantityUnits(draft.totalText))) {
          throw const FormatException('服务器未返回精确数量，请更新服务器后再核对大数量');
        }
        final differs = exact == null
            ? (allocated - double.parse(draft.totalText)).abs() > 0.00005
            : exact != materialQuantityUnits(draft.totalText);
        if (differs && groups.every((group) => group.blockedReason == null)) {
          throw const FormatException('汇总预览的来源份额与公共份合计不等于本次总量，未应用此结果');
        }
      }
      owner._mutateAggregateTable(() {
        _previewRequest = request;
        _preview = preview;
        _previewSignature = signature;
        error = null;
        for (final draft in selected) {
          draft.previewGroups = grouped[draft.key]!;
          final contribution = draft.previewGroups.fold<double>(
            0,
            (sum, group) =>
                sum +
                group.publicExtraQty +
                group.sources.fold<double>(
                  0,
                  (sum, source) => sum + source.allocatedQty,
                ),
          );
          final exact = _exactPreviewContribution(draft.previewGroups);
          if (exact == null
              ? (contribution - double.parse(draft.totalText)).abs() > 0.00005
              : exact != materialQuantityUnits(draft.totalText)) {
            continue;
          }
          final allocation = <String, BigInt>{};
          for (final group in draft.previewGroups) {
            for (final source in group.sources) {
              // Canonical allocation may cover several original rows. Its
              // total is a ledger fact, not a per-source amount to duplicate.
              final originals = sourceOrigins[source]!;
              if (originals.length != 1) continue;
              final originalId = originals.single;
              final units = materialQuantityUnits(
                materialQuantityFact(
                  source.allocatedQtyExact,
                  source.allocatedQty,
                ),
              );
              allocation.update(
                originalId,
                (value) => value + units,
                ifAbsent: () => units,
              );
            }
          }
          for (final group in draftGroups(draft)) {
            final line = group.representative.materialLineId;
            final sourceRequested =
                draft.sourceRequestedQtyByMaterialLineId?[line];
            if (sourceRequested == null) {
              // 2026-09-27 用户口径「汇总输入的值和按产品看是连通的」：手输总量
              // 在敲键时就已按「需要 + 平分富余」落到各来源行(_applyLocalSplit)。
              // 服务端预览的来源分配只在真实下达时生效，不回写格子——否则填
              // 6000(需要 3000)切回按产品看会显示每行 1000(服务端把富余 3000 记
              // 公共备货)，与汇总总量对不上。
              if (draft.userEntered) continue;
              if (!allocation.containsKey(line)) continue;
            }
            final text =
                sourceRequested ??
                materialQuantityText(allocation[line] ?? BigInt.zero);
            final quantity = double.parse(text);
            final append = owner._tableGroupIssued(group);
            final controller = append
                ? owner._tableAppendQtyController(group)
                : owner._tableOrderQtyController(group);
            controller.text = text;
            owner._tableUserTypedQty[line] = quantity;
            owner._tableSeededQtyTexts.remove(
              '${append ? 'APPEND' : 'ORDER'}|${group.key}',
            );
          }
        }
        owner._tableCascadePreview = preview.analysis;
        owner._tableCascadePreviewTyped = Map.unmodifiable(
          owner._tableUserTypedQty,
        );
        owner._tableEstimatedQty.clear();
        owner._tableEstimateTick.value++;
        owner._reseedMaterialTableQtyInputs();
      });
    } catch (failure) {
      if (!owner.mounted ||
          revision != _revision ||
          generation != _previewGeneration) {
        return;
      }
      owner._mutateAggregateTable(() {
        _preview = null;
        _previewRequest = null;
        error = failure is FormatException
            ? failure.message
            : productionErrorMessage(failure, fallback: '汇总预览失败，输入已保留');
      });
    }
  }

  BigInt? _exactPreviewContribution(
    List<MaterialAggregateOrderGroupPreview> groups,
  ) {
    var total = BigInt.zero;
    for (final group in groups) {
      final extra = group.publicExtraQtyExact;
      if (extra == null) return null;
      total += materialQuantityUnits(extra);
      for (final source in group.sources) {
        final allocated = source.allocatedQtyExact;
        if (allocated == null) return null;
        total += materialQuantityUnits(allocated);
      }
    }
    return total;
  }

  /// 调用方(产品视图主确认框或汇总视图开跑前的一次性确认，见
  /// [_MaterialAggregateSubmission._submit])都已确认过整单，这里起各依赖轮次
  /// 只做核对与提交，不再弹确认框——ADR-120 §2.4「只确认一次」。
  Future<bool> submit(
    List<_MaterialGroup> selectedGroups, {
    bool confirmed = false,
    bool? skipAutoClaim,
  }) => submission.submit(
    selectedGroups,
    confirmed: confirmed,
    skipAutoClaim: skipAutoClaim,
  );

  Future<bool> submitStage(
    List<_MaterialGroup> selectedGroups, {
    bool skipAutoClaim = false,
  }) async {
    if (saving || selectedGroups.isEmpty) return false;
    if (!uncertain) {
      await owner._ensureTableMandatoryAssignments(selectedGroups);
    }
    if (!owner.mounted) return false;
    final keys = selectedGroups
        .map((group) => owner._aggregateKeyOf(group.representative))
        .toSet();
    if (!uncertain) {
      owner._mutateAggregateTable(() {
        for (final key in keys) {
          final groups = selectedGroups
              .where(
                (group) => owner._aggregateKeyOf(group.representative) == key,
              )
              .toList();
          begin(
            _MaterialAggregate(
              key: key,
              paths: [for (final group in groups) ...group.paths],
            ),
            scope: groups,
          );
        }
      });
      // 2026-09-25 用户口径「按物料汇总点击下单没有加载弹窗」：核对与提交两段
      // 纯网络等待挂全页遮罩(与产品视图 notify 同一通道 bucketActionBusyMessage)；
      // 确认弹窗之前必须撤掉，否则会把弹窗盖在背后转圈。
      owner.bucketActionBusyMessage.value = '正在核对汇总下达内容';
      try {
        await refreshPreview(
          keys: keys,
          forSubmission: true,
          skipAutoClaim: skipAutoClaim,
        );
      } finally {
        owner.bucketActionBusyMessage.value = null;
      }
      if (!owner.mounted) return false;
      if (_preview == null || _previewRequest == null) {
        owner.context.appWarning(error ?? '请先核对汇总预览');
        return false;
      }
      final blocked = _preview!.groups
          .where((group) => group.blockedReason?.isNotEmpty == true)
          .toList();
      final labels = partLabels(keys);
      String nameOf(MaterialAggregateOrderGroupPreview group) =>
          '${group.goodsName}${labels[group.clientGroupKey] ?? ''}';
      if (blocked.isNotEmpty) {
        // A dependency round is complete only when every admitted group was
        // committed. Dropping a blocked parent would falsely unlock its
        // descendants and lose its original quantity. Keep the entire round
        // for review/retry, and preserve the caller's single confirmation.
        owner.context.appWarning(
          '本轮尚未下达：${blocked.take(3).map((group) => '${nameOf(group)}：${group.blockedReason}').join('；')}。'
          '输入和选择已保留，请修正后继续。',
        );
        _preview = null;
        _previewRequest = null;
        _previewSignature = null;
        return false;
      }
      // 预览捕获与 _submittedRequest 钉死之间不得插入任何 await：插入后预览可能
      // 在等待期被替换，提交会带着过时指纹出去(旧逐轮确认框时代的竞态面)。
      _submittedRequest = _previewRequest!;
      _submittedFingerprint = _preview!.previewFingerprint;
    }
    final request = _submittedRequest!;
    final makesPlans = request.groups.any(
      (group) => group.departmentId != null,
    );
    owner._mutateAggregateTable(() {
      saving = true;
      error = null;
      owner._tableSubmitting = true;
      owner._planSubmissionApproveNow = makesPlans && request.approveNow;
    });
    try {
      // 确认弹窗已收口，这里起是纯网络段：挂遮罩(见上，同一次用户口径)。
      owner.bucketActionBusyMessage.value = makesPlans
          ? request.approveNow
                ? '正在生成并审核下达'
                : '正在生成生产计划'
          : '正在下达物料';
      final result = await owner.ref
          .read(productionPlanRepositoryProvider)
          .submitAggregateOrders(
            request,
            previewFingerprint: _submittedFingerprint!,
          );
      if (!owner.mounted) return false;
      lastStageResult = result;
      for (final batch in result.batches) {
        final plan = batch.generatedPlan;
        if (plan != null && plan.planId.isNotEmpty) {
          owner._preparationPlanResults[plan.planId] = plan;
        }
      }

      owner._mutateAggregateTable(() {
        for (final input in request.groups) {
          // 分成几张工单的草稿随第一张一起清掉，其余几张在这里取到 null。
          final draft = drafts.remove(draftKeyOf(input.clientGroupKey));
          if (draft == null) continue;
          for (final entry in draft.paths.entries) {
            _draftByLine.remove(entry.key);
            final key = entry.value.groupKey;
            owner._tableUserTypedQty.remove(entry.key);
            owner._selectedMaterialGroupKeys.remove(key);
            owner._tableAutoSelectedKeys.remove(key);
            owner._tableUserDeselectedKeys.remove(key);
            owner._tableAppendQtyControllers[key]?.text = '0';
            owner._tableSeededQtyTexts['APPEND|$key'] = '0';
            final order = owner._tableOrderQtyControllers[key];
            if (order != null) {
              owner._tableSeededQtyTexts['ORDER|$key'] = order.text;
            }
          }
        }
        uncertain = false;
        _preview = null;
        _previewRequest = null;
        _revision++;
        owner._applyAnalysis(result.analysis);
      });
      if (result.batches.any((batch) => batch.planId?.isNotEmpty == true)) {
        refreshAfterProductionPlanGenerated(owner.ref);
      }
      refreshBadges(owner.ref);
      owner.context.appSuccess(
        result.batches.isEmpty
            ? result.analysis.materials.any(
                    (material) =>
                        material.preparationAdoptedQty > 0 &&
                        request.groups.any(
                          (group) => group.materialLineIds.contains(
                            material.materialLineId,
                          ),
                        ),
                  )
                  ? '已采用现有供给，数量和进度已更新'
                  : '办理完成，数量和进度已更新'
            : '已下达 ${result.batches.length} 笔：${result.batches.map((batch) => batch.documentNo).where((value) => value.isNotEmpty).join('、')}',
      );
      return true;
    } catch (failure) {
      if (!owner.mounted) return false;
      final rejected =
          failure is ApiException &&
          failure.httpStatus != null &&
          failure.httpStatus! >= 400 &&
          failure.httpStatus! < 500;
      owner._mutateAggregateTable(() {
        uncertain = !rejected;
        error = rejected
            ? failure.message
            : '${productionErrorMessage(failure, fallback: '服务器没有返回确定的结果')}；'
                  '提交结果尚未确认，请保留本次总量并使用相同内容重试核对';
        if (rejected) {
          _revision++;
          _preview = null;
          _previewRequest = null;
        }
      });
      if (failure is ApiException && failure.httpStatus == 409) {
        try {
          final current = await owner._readMaterialAnalysisDetail(
            request.analysisId,
          );
          if (owner.mounted) {
            owner._mutateAggregateTable(() => owner._applyAnalysis(current));
          }
        } catch (_) {
          /* Keep the exact draft when the refresh is unavailable. */
        }
      }
      if (owner.mounted) owner.context.appWarning(error!);
      return false;
    } finally {
      // 遮罩随本段收口(2026-09-14 教训：忙标志/遮罩漏一条 return 分支没清，
      // 整页就被 Positioned.fill 遮罩吃掉所有点击)。
      owner.bucketActionBusyMessage.value = null;
      if (owner.mounted) {
        owner._mutateAggregateTable(() {
          saving = false;
          owner._tableSubmitting = false;
          owner._planSubmissionApproveNow = false;
        });
      }
    }
  }

  Future<void> cancelAll() async {
    if (saving || drafts.isEmpty) return;
    if (uncertain) {
      owner.context.appWarning('提交回执尚未确认，请先重试核对结果');
      return;
    }
    final confirmed = await UtenDialog.show(
      owner.context,
      title: '撤销未提交的汇总草稿？',
      content: Text('撤销 ${drafts.length} 种物料的汇总输入，恢复汇总前的来源数量和选择；已实际下达的单据不受影响。'),
      confirmLabel: '撤销草稿',
    );
    if (confirmed != true || !owner.mounted) return;
    owner._mutateAggregateTable(() {
      _revision++;
      _debounce?.cancel();
      _cancelToken?.cancel('aggregate draft cancelled');
      for (final draft in drafts.values) {
        for (final entry in draft.paths.entries) {
          final state = entry.value, key = state.groupKey;
          owner._tableOrderQtyControllers[key]?.text = state.orderText;
          owner._tableAppendQtyControllers[key]?.text = state.appendText;
          if (state.orderSeed == null) {
            owner._tableSeededQtyTexts.remove('ORDER|$key');
          } else {
            owner._tableSeededQtyTexts['ORDER|$key'] = state.orderSeed!;
          }
          if (state.appendSeed == null) {
            owner._tableSeededQtyTexts.remove('APPEND|$key');
          } else {
            owner._tableSeededQtyTexts['APPEND|$key'] = state.appendSeed!;
          }
          if (state.typedQty == null) {
            owner._tableUserTypedQty.remove(entry.key);
          } else {
            owner._tableUserTypedQty[entry.key] = state.typedQty!;
          }
          void restore(Set<String> target, bool included) {
            if (included) {
              target.add(key);
            } else {
              target.remove(key);
            }
          }

          restore(owner._selectedMaterialGroupKeys, state.selected);
          restore(owner._tableAutoSelectedKeys, state.autoSelected);
          restore(owner._tableUserDeselectedKeys, state.deselected);
          if (state.workshop == null) {
            owner._tableWorkshopDraft.remove(key);
          } else {
            owner._tableWorkshopDraft[key] = state.workshop!;
          }
          if (state.worker == null) {
            owner._tableWorkerDraft.remove(key);
          } else {
            owner._tableWorkerDraft[key] = state.worker!;
          }
          // 快照时仍是系统预填的比例回到当前预填值(草稿期间可能已按新默认刷新)，
          // 不把旧默认当成人填的放回去。
          owner._prefilledOverproductionRates.restore(
            owner._overproductionPercentController(materialLineId: entry.key),
            state.rate,
            explicit: state.rateExplicit,
          );
        }
      }
      drafts.clear();
      _draftByLine.clear();
      _preview = null;
      _previewRequest = null;
      error = null;
      owner._invalidateMaterialTableCascadePreview();
    });
  }

  List<_MaterialGroup> groupsOf(_MaterialAggregate aggregate) {
    final analysis = owner._analysis;
    if (analysis == null) return const [];
    final indexes = owner._analysisIndexes(analysis);
    final result = <String, _MaterialGroup>{};
    for (final path in aggregate.paths) {
      final group = indexes.groupsByLine[path.materialLineId];
      if (group != null) result[group.key] = group;
    }
    return result.values.toList(growable: false);
  }

  /// 走车间通道的来源组(只有自制)：服务端 aggregate-orders 对自制(manufacture)
  /// 一律要求生产车间+负责人。判定与主表 [_tableIssueTarget].viaWorkshop 同源。
  List<_MaterialGroup> workshopGroups(_MaterialAggregate aggregate) => groupsOf(
    aggregate,
  ).where((group) => owner._tableIssueTarget(group).viaWorkshop).toList();

  String workshopText(_MaterialAggregate aggregate) {
    if (drafts[aggregate.key]?.mixedWorkshop == true) return '多个车间';
    final groups = workshopGroups(aggregate);
    if (groups.isEmpty) return '—';
    final values = groups.map(owner._tableWorkshopFor).toList();
    if (values.map((value) => value.id).toSet().length > 1) return '多个车间';
    return values.first.name ?? '待指派';
  }

  String workerText(_MaterialAggregate aggregate) {
    if (drafts[aggregate.key]?.mixedWorker == true) return '多位负责人';
    final groups = workshopGroups(aggregate);
    if (groups.isEmpty) return '—';
    final values = groups.map(owner._tableWorkerFor).toList();
    if (values.map((value) => value.id).toSet().length > 1) return '多位负责人';
    return values.first.name ?? '待指派';
  }

  Widget assignmentCell(
    ThemeData theme,
    _MaterialAggregate aggregate, {
    required bool worker,
  }) {
    if (workshopGroups(aggregate).isEmpty) return const Text('—');
    final value = worker ? workerText(aggregate) : workshopText(aggregate);
    return owner._materialTableAssignmentCell(
      theme,
      key:
          'material-aggregate-${worker ? 'worker' : 'workshop'}-${aggregate.key}',
      text: value,
      autofilled: false,
      empty: value == '待指派',
      semanticsLabel: '${worker ? '负责人' : '生产车间'} $value',
      onTap: owner._canGenerate && !owner._busy && !uncertain
          ? () => unawaited(
              worker ? pickWorker(aggregate) : pickWorkshop(aggregate),
            )
          : null,
    );
  }

  void invalidateDraft(_MaterialAggregateDraft draft) {
    draft.previewGroups = const [];
    _revision++;
    _preview = null;
    _previewRequest = null;
    error = null;
    for (final snapshot in draft.paths.values) {
      owner._selectedMaterialGroupKeys.add(snapshot.groupKey);
      owner._tableUserDeselectedKeys.remove(snapshot.groupKey);
    }
    schedulePreview();
  }

  Future<void> pickWorkshop(_MaterialAggregate aggregate) async {
    final groups = workshopGroups(aggregate);
    if (groups.isEmpty) return;
    final tree = owner._tableWorkshopTree.isNotEmpty
        ? owner._tableWorkshopTree
        : await owner._tableWorkshopTreeOrEmpty();
    if (!owner.mounted) return;
    final selectable = tree.map((node) => node.id).toSet();
    final picked = await showUtenDepartmentPickerPanel(
      owner.context,
      tree: tree,
      selectablePredicate: (node) => selectable.contains(node.id),
    );
    if (!owner.mounted || picked == null || picked.isEmpty) return;
    owner._mutateAggregateTable(() {
      final draft = begin(aggregate);
      draft.mixedWorkshop = false;
      draft.mixedWorker = false;
      for (final group in groups) {
        owner._tableWorkshopDraft[group.key] = (
          id: picked.first.id,
          name: picked.first.name,
        );
        owner._tableWorkerDraft.remove(group.key);
      }
      invalidateDraft(draft);
    });
  }

  Future<void> pickWorker(_MaterialAggregate aggregate) async {
    final groups = workshopGroups(aggregate);
    if (groups.isEmpty) return;
    final revision = _revision;
    final workshops = groups.map(owner._tableWorkshopFor).toList();
    if (workshops.map((item) => item.id).toSet().length != 1 ||
        workshops.first.id == null) {
      owner.context.appWarning('请先统一生产车间，再选择负责人');
      return;
    }
    final workshop = workshops.first;
    final picked = await showUtenEmployeePickerPanel(
      owner.context,
      title: '选择生产负责人',
      departmentName: workshop.name,
      loader: (keyword) async {
        final result = await owner.ref
            .read(employeeRepositoryProvider)
            .listPickerCandidates(
              size: 30,
              search: keyword,
              departmentId: keyword?.trim().isEmpty != false
                  ? workshop.id
                  : null,
              includeSubtree: true,
            );
        return [
          for (final employee in result)
            UtenEmployeePickerItem(
              id: employee.id,
              name: employee.fullName,
              employeeCode: employee.code,
              departmentId: employee.departmentId,
              departmentName: employee.departmentName,
            ),
        ];
      },
    );
    if (!owner.mounted || picked == null || revision != _revision) return;
    final currentGroups = workshopGroups(aggregate);
    if (currentGroups.length != groups.length ||
        currentGroups.any(
          (group) =>
              !groups.any((original) => original.key == group.key) ||
              owner._tableWorkshopFor(group).id != workshop.id,
        )) {
      return;
    }
    owner._mutateAggregateTable(() {
      final draft = begin(aggregate);
      draft.mixedWorker = false;
      for (final group in groups) {
        owner._tableWorkerDraft[group.key] = (id: picked.id, name: picked.name);
      }
      invalidateDraft(draft);
    });
  }

  /// 各来源行的本次比例输入格(与主表同一批控制器)。
  List<TextEditingController> rateControllers(
    Iterable<_MaterialGroup> groups,
  ) => [
    for (final group in groups)
      owner._overproductionPercentController(
        materialLineId: group.representative.materialLineId,
        issued: owner._tableGroupIssued(group),
      ),
  ];

  /// 各来源的本次比例按数值比较('10' 与 '10.0' 是同一个比例)。一致时返回代表
  /// 文本——有人改过的格子优先，照抄它不会把人定的比例降回系统默认；不一致或
  /// 含无效输入时返回 null(各格文本完全相同时照原样返回)。
  String? uniformRateText(Iterable<_MaterialGroup> groups) {
    final controllers = rateControllers(groups);
    if (controllers.isEmpty) return null;
    final texts = {for (final controller in controllers) controller.text};
    if (texts.length == 1) return texts.single;
    final rates = texts.map(parseProductionOverproductionPercent).toSet();
    if (rates.length != 1 || rates.single == null) return null;
    return (controllers
                .where(owner._prefilledOverproductionRates.isExplicit)
                .firstOrNull ??
            controllers.first)
        .text;
  }

  String rateText(_MaterialAggregate aggregate) {
    if (drafts[aggregate.key]?.mixedRate == true) return '多个比例';
    final groups = workshopGroups(aggregate);
    if (groups.isEmpty) return '—';
    final uniform = uniformRateText(groups);
    return uniform == null ? '多个比例' : '$uniform%';
  }

  Widget rateCell(_MaterialAggregate aggregate) {
    final groups = workshopGroups(aggregate);
    if (groups.isEmpty) return const Text('—');
    final uniform = uniformRateText(groups);
    if (groups.any(owner._tableGroupIssued)) {
      return Tooltip(
        message: '这一行已有下达记录，允许超产比例随工单锁定；要改已下达工单的比例须计划部审批。未下达来源可切换按产品分别设置。',
        child: Text(
          uniform == null ? '多个比例（已锁定）' : '$uniform%',
          key: ValueKey('material-aggregate-rate-${aggregate.key}'),
        ),
      );
    }
    final initial = drafts[aggregate.key]?.mixedRate == true
        ? ''
        : uniform ?? '';
    final controller = rateEditors.putIfAbsent(
      aggregate.key,
      () => TextEditingController(text: initial),
    );
    // 各来源仍是系统预填的默认比例时汇总格跟着来源走：新快照会刷新来源的预填值，
    // 提交也按来源送空值，汇总格若停在旧默认，看到的就不是服务端要填的比例。
    // 有人改过(汇总格的输入会写进每个来源)就不再动它。
    final sourcesPrefilled = !rateControllers(
      groups,
    ).any(owner._prefilledOverproductionRates.isExplicit);
    if ((!drafts.containsKey(aggregate.key) || sourcesPrefilled) &&
        controller.text != initial) {
      controller.text = initial;
    }
    return Tooltip(
      message: uniform != null ? '本次汇总生产统一使用此比例' : '各来源比例不同，请明确填写本次汇总比例',
      child: ProductionOverproductionRateField(
        key: ValueKey('material-aggregate-rate-${aggregate.key}'),
        controller: controller,
        enabled: owner._canGenerate && !owner._busy && !uncertain,
        onChanged: (value) => owner._mutateAggregateTable(() {
          if (workshopGroups(aggregate).any(owner._tableGroupIssued)) return;
          final draft = begin(aggregate);
          draft.mixedRate = false;
          for (final group in groups) {
            owner
                    ._overproductionPercentController(
                      materialLineId: group.representative.materialLineId,
                    )
                    .text =
                value;
          }
          invalidateDraft(draft);
        }),
      ),
    );
  }

  String sourceLabel(ProductionMaterialAnalysisMaterial material) {
    final draft = drafts[_draftByLine[material.materialLineId]];
    for (final group
        in draft?.previewGroups ??
            const <MaterialAggregateOrderGroupPreview>[]) {
      for (final source in group.sources) {
        if (source.materialLineId == material.materialLineId &&
            source.sourceLabel.isNotEmpty) {
          return source.sourceLabel;
        }
      }
    }
    final analysis = owner._analysis;
    if (analysis == null) return owner._pathLabel(material);
    final rootId = owner
        ._bomPresentation(analysis)
        .rootIdsByMaterial[material.materialLineId];
    final product = owner._analysisIndexes(analysis).productsById[rootId];
    return '${product?.goodsName ?? product?.goodsCode ?? '来源'} · ${owner._pathLabel(material)}';
  }

  List<_MaterialGroup> selectionScope(_MaterialTableRow row) {
    final analysis = owner._analysis;
    if (analysis == null || row.contextOnly || row.isAggregateSource) {
      return const [];
    }
    if (row.aggregate case final aggregate?) return groupsOf(aggregate);
    if (row.product case final product?) {
      // 按物料汇总视图：顶层产品行是独立可下单行，勾选只带根行自己——
      // 组件在各自的聚合行上另勾另核，不随顶层整树联动（2026-10-07）。
      if (owner._bomAggregateByMaterial) {
        return owner._materialRowAllGroups(row);
      }
      final indexes = owner._analysisIndexes(analysis);
      final nodes =
          owner
              ._bomPresentation(analysis)
              .nodesByProduct[product.analysisLineId] ??
          const [];
      final result = {
        for (final group in owner._materialRowAllGroups(row)) group.key: group,
      };
      for (final node in nodes) {
        final group = indexes.groupsByLine[node.materialLineId];
        if (group != null) result[group.key] = group;
      }
      return result.values.toList(growable: false);
    }
    return owner._materialRowAllGroups(row);
  }

  bool selectableForOrder(_MaterialGroup group) {
    if (inactiveSourceContext(group)) return false;
    final reason = owner._tableIssueBlockedReason(group, forAggregate: true);
    return reason == null ||
        reason ==
            _MaterialAnalysisMaterialTableState._tableMissingWorkshopReason ||
        reason == _MaterialAnalysisMaterialTableState._tableMissingWorkerReason;
  }

  bool inactiveSourceContext(_MaterialGroup group) {
    final material = group.representative;
    if (material.hasPriorityMakeSupplement) return false;
    final anchor = owner._tableMakeAnchorOf(group);
    if (anchor?.canSchedule == true && (anchor?.remainingQty ?? 0) > 0.0001) {
      return false;
    }
    if (material.aggregatePreparation case final preparation?) {
      return !preparation.actionable;
    }
    return material.requiredQty <= 0 &&
        const {
          MaterialRequirementState.delegatedToMakeChild,
          MaterialRequirementState.inactiveParentCovered,
          MaterialRequirementState.inactiveParentRoute,
          MaterialRequirementState.inactiveReference,
        }.contains(material.effectiveRequirementState);
  }

  List<_MaterialGroup> selectableGroups(_MaterialTableRow row) =>
      selectionScope(row)
          .where(
            (group) =>
                (row.aggregate != null ||
                    !ownsLine(group.representative.materialLineId) ||
                    isProductFlow(group.representative.materialLineId)) &&
                // 2026-09-25 确认路线退役：复选框只服务「下单」，不再有
                // 「选行去确认路线」语义(服务端建分析时自动确认 + 直改即存接管)。
                selectableForOrder(group),
          )
          .toList(growable: false);

  bool? selectionState(_MaterialTableRow row) {
    final groups = selectableGroups(row);
    if (groups.isEmpty) return false;
    final selected = groups
        .where((group) => owner._selectedMaterialGroupKeys.contains(group.key))
        .length;
    return selected == 0
        ? false
        : selected == groups.length
        ? true
        : null;
  }

  /// 左上角表头全选的完整范围：**当前投影可见层**里所有可勾的操作组键，
  /// 不经过行投影——折叠分支里、屏外的子行与展开的行一视同仁(2026-09-27
  /// 用户口径「即使层级收起，点左上角也是全选，包括收起的」)。
  ///
  /// 取 `owner._bomFilterProjection` 的可见层(视图 chip × 关键词，不含折叠、
  /// 不含表头列筛选)而不是整份分析：搜索/只看缺料收窄后全选只在命中的子树里
  /// 生效；这与产品行勾选自带整棵子树、忽略更细筛选的既有口径一致。被汇总
  /// 草稿接管的来源行不直接勾(它们随汇总行整体办理)，与 [selectableGroups]
  /// 同一口径。
  Set<String> allSelectableGroupKeys() {
    final analysis = owner._analysis;
    if (analysis == null) return const {};
    final indexes = owner._analysisIndexes(analysis);
    final result = <String>{};
    for (final nodes
        in owner._bomFilterProjection(analysis).nodesByProduct.values) {
      for (final node in nodes) {
        final group = indexes.groupsByLine[node.materialLineId];
        if (group == null || !selectableForOrder(group)) continue;
        final lineId = group.representative.materialLineId;
        if (ownsLine(lineId) && !isProductFlow(lineId)) continue;
        result.add(group.key);
      }
    }
    return result;
  }

  /// Actual issue facts only. Shared plan anchors and public action slices are
  /// counted once even when multiple displayed paths point at the same source.
  MaterialIssuedQuantitySummary? issuedSummary(_MaterialAggregate aggregate) {
    final analysis = owner._analysis;
    if (analysis == null) return null;
    final byLine = {
      for (final material in analysis.materials)
        material.materialLineId: material,
    };
    final queue = aggregate.paths.toList();
    final visited = <String>{};
    final actions = <MaterialAnalysisSupplyAction>[];
    for (var i = 0; i < queue.length; i++) {
      final material = queue[i];
      if (!visited.add(material.materialLineId)) continue;
      for (final reference in material.notifiedTargets) {
        if (reference.status == 'CANCELLED' || reference.isRootOutput) continue;
        final action = owner._supplyActionOf(reference.actionId);
        if (action != null) actions.add(action);
      }
      for (final target
          in material.aggregatePreparation?.targetMaterialLineIds ??
              const <String>[]) {
        if (byLine[target] case final material?) queue.add(material);
      }
    }
    // A legacy plan alongside a newer aggregate action needs its own explicit
    // breakdown; do not relabel the action subset as the whole history.
    if (groupsOf(aggregate).any(
      (group) =>
          owner._tableLegacyAnchorWithSharedSupply(
                group,
                authoritative: true,
              ) !=
              null ||
          (owner._tableUsesMakeAnchor(group) &&
              (owner
                          ._tableMakeAnchorOf(group, authoritative: true)
                          ?.issuedPlanQty ??
                      0) >
                  0),
    )) {
      return null;
    }
    final result = MaterialIssuedQuantitySummary(actions);
    return actions.isEmpty ? null : result;
  }

  String? issuedText(_MaterialAggregate aggregate) {
    final summary = issuedSummary(aggregate);
    if (summary != null) return summary.total;
    final groups = groupsOf(aggregate);
    if (groups.isNotEmpty && groups.every(owner._tableUsesMakeAnchor)) {
      final anchors = <String, String?>{};
      for (final group in groups) {
        final anchor = owner._tableMakeAnchorOf(group, authoritative: true);
        if (anchor == null) return null;
        final qty = materialPresentationFact(
          anchor.quantityFactsExact,
          'issuedPlanQty',
          anchor.issuedPlanQty,
        );
        final rate = owner._tableIsRootSupply(group.representative)
            ? materialPresentationFact(
                anchor.quantityFactsExact,
                'unitRate',
                anchor.unitRate ?? 1,
                scale: 6,
              )
            : '1';
        final units = financeExactProductUnits(qty, rate);
        anchors[anchor.analysisLineId] = units == null
            ? null
            : financeExactTrimmed(financeExactDecimalFromUnits(units));
      }
      return materialPresentationSum(anchors.values);
    }
    return materialPresentationFact(const {}, 'ordered', orderedQty(aggregate));
  }

  String? issuedBreakdown(_MaterialAggregate aggregate) {
    final summary = issuedSummary(aggregate);
    if (summary == null || !summary.known || summary.total == '0') return null;
    return '已下单 ${summary.total} = 需求份 ${summary.demand} + 公共备货 ${summary.public}'
        '${summary.safety == '0' ? '' : ' + 安全补库 ${summary.safety}'}';
  }

  double orderedQty(_MaterialAggregate aggregate) {
    var total = 0.0;
    final anchors = <String>{};
    final references = <String>{};
    final allocatedByAction = <String, double>{};
    final sourceGroups = groupsOf(aggregate);
    final effectiveGroups = {
      for (final group in sourceGroups) group.key: group,
    };
    final indexes = owner._analysis == null
        ? null
        : owner._analysisIndexes(owner._analysis!);
    for (final group in sourceGroups) {
      final preparation = group.representative.aggregatePreparation;
      if (preparation == null ||
          preparation.orderedQtyExact ||
          preparation.targetMaterialLineIds.isEmpty) {
        continue;
      }
      // 历史记录没有逐行发出量时，从精确目标的单据引用去重汇总，不能把每个
      // 来源都可见的整单总量相加，也不能把转交需求当成已下单。
      effectiveGroups.remove(group.key);
      for (final id in preparation.targetMaterialLineIds) {
        final target = indexes?.groupsByLine[id];
        if (target != null) effectiveGroups[target.key] = target;
      }
    }
    for (final group in effectiveGroups.values) {
      final preparation = group.representative.aggregatePreparation;
      if (preparation?.orderedQtyExact == true) {
        total += preparation!.orderedQty;
        continue;
      }
      final route = owner._draftRoute(group);
      if (owner._tableUsesMakeAnchor(group)) {
        final anchor = owner._tableMakeAnchorOf(group, authoritative: true);
        if (anchor != null && anchors.add(anchor.analysisLineId)) {
          total +=
              anchor.issuedPlanQty * owner._tableAnchorUnitRate(group, anchor);
        }
        continue;
      }
      final legacy = owner._tableLegacyAnchorWithSharedSupply(
        group,
        authoritative: true,
      );
      if (legacy != null && anchors.add(legacy.analysisLineId)) {
        total +=
            legacy.issuedPlanQty * owner._tableAnchorUnitRate(group, legacy);
      }
      for (final path in group.paths) {
        for (final target in path.notifiedTargets) {
          if (target.target != route ||
              target.isRootOutput ||
              target.status == 'CANCELLED' ||
              const {
                'FUTURE_TRANSFER',
                'SHARED_FUTURE_CLAIM',
              }.contains(owner._supplyOperationType(target.actionId)) ||
              !references.add('${path.materialLineId}|${target.actionId}')) {
            continue;
          }
          if (legacy != null &&
              owner._supplyOperationType(target.actionId) !=
                  'AGGREGATE_SUPPLY') {
            continue;
          }
          final allocated = target.allocatedQty ?? 0;
          total += allocated;
          final actionId = target.actionId;
          if (actionId != null) {
            allocatedByAction.update(
              actionId,
              (value) => value + allocated,
              ifAbsent: () => allocated,
            );
          }
        }
      }
    }
    for (final entry in allocatedByAction.entries) {
      final action = owner._supplyActionOf(entry.key);
      if (action == null || action.publicSurplusQty <= 0) continue;
      final share = owner._supplyOperationType(entry.key) == 'AGGREGATE_SUPPLY'
          ? 1.0
          : action.requestedQty > 0.000000001
          ? (entry.value / action.requestedQty).clamp(0.0, 1.0)
          : 1.0;
      total += action.publicSurplusQty * share;
    }
    return total;
  }

  double pendingQty(_MaterialAggregate aggregate) => groupsOf(
    aggregate,
  ).fold(0.0, (sum, group) => sum + owner._tableSubmitQtyOf(group));

  String orderText(_MaterialAggregate aggregate) {
    final ordered = orderedQty(aggregate);
    return ordered > 0.000000001
        ? (issuedText(aggregate) ?? '无法确认')
        : drafts[aggregate.key]?.totalText ?? owner._qty(pendingQty(aggregate));
  }

  String quantityRaw(_MaterialAggregate aggregate, {required bool append}) {
    final ordered = orderedQty(aggregate);
    if (append && ordered <= 0.000000001) return '0';
    if (!append && ordered > 0.000000001) return issuedText(aggregate) ?? '—';
    return drafts[aggregate.key]?.totalText ?? pendingQty(aggregate).toString();
  }

  String appendText(_MaterialAggregate aggregate) =>
      orderedQty(aggregate) > 0.000000001
      ? drafts[aggregate.key]?.totalText ?? owner._qty(pendingQty(aggregate))
      : '0';

  /// 已选/待办组里不在当前渲染行集中的数量：折叠分支、表头筛掉的子行等。
  /// 2026-09-27 主表去分页后不再有「其他分页」这一类，只剩折叠与筛选。
  int includedOutsideCurrentRows(Iterable<_MaterialGroup> pending) {
    final analysis = owner._analysis;
    if (analysis == null) return 0;
    final rows = owner._materialTableRows(analysis);
    final visible = <String>{};
    for (final row in rows) {
      if (row.contextOnly) continue;
      for (final group in owner._materialRowAllGroups(row)) {
        visible.add(group.key);
      }
    }
    return pending.where((group) => !visible.contains(group.key)).length;
  }
}

final class _MaterialAggregateDraft {
  _MaterialAggregateDraft(this.key, this.label, this.paths, this.totalText);
  final String key, label;
  final Map<String, _MaterialAggregatePathSnapshot> paths;
  String totalText;
  bool userEntered = false;
  bool productFlow = false;

  /// 汇总行已下达过（总量写在「追加下单」格）：追加是额外量，没有下限，
  /// 平分落在各来源行的追加格（见 [_MaterialAggregateTableController.changed]）。
  bool appendFlow = false;
  Map<String, String>? sourceRequestedQtyByMaterialLineId;
  bool mixedWorkshop = false, mixedWorker = false, mixedRate = false;
  List<MaterialAggregateOrderGroupPreview> previewGroups = const [];
  Iterable<String> get lineIds => paths.keys;
  double get publicQty =>
      previewGroups.fold(0.0, (sum, group) => sum + group.publicExtraQty);
}

final class _MaterialAggregatePathSnapshot {
  const _MaterialAggregatePathSnapshot({
    required this.groupKey,
    required this.orderText,
    required this.appendText,
    required this.orderSeed,
    required this.appendSeed,
    required this.typedQty,
    required this.selected,
    required this.autoSelected,
    required this.deselected,
    required this.workshop,
    required this.worker,
    required this.rate,
    required this.rateExplicit,
  });
  final String groupKey, orderText, appendText, rate;

  /// 快照时比例是人定的(不再是系统预填值)。
  final bool rateExplicit;
  final String? orderSeed, appendSeed;
  final double? typedQty;
  final bool selected, autoSelected, deselected;
  final ({String? id, String? name})? workshop, worker;
  bool get hasExplicitQty =>
      typedQty != null || orderText != orderSeed || appendText != appendSeed;
}

/// 一条来源「怎么做」的参数(ADR-120 §8)：参数相同的来源并成一张工单。
final class _MaterialAggregateMakeParams {
  const _MaterialAggregateMakeParams({
    required this.workshop,
    required this.worker,
    required this.rateText,
    required this.rateExplicit,
  });
  final ({String? id, String? name}) workshop, worker;
  final String rateText;

  /// 这格比例是人定的吗：没人改过的系统预填值提交时送空值(ADR-129 §2.10)。
  final bool rateExplicit;

  /// 按数值解析的超产比例；填得不合法时为 null。
  double? get rate => _MaterialAggregateTableController._rateValue(rateText);

  /// 拆单键：车间 + 负责人 + 比例(数值，六位小数与服务端比例精度一致)。
  String get key =>
      '${workshop.id ?? ''}|${worker.id ?? ''}|${rate?.toStringAsFixed(6) ?? ''}';

  String get label {
    final value = rate;
    final percent = value == null
        ? rateText
        : productionOverproductionPercentText(value);
    return '${workshop.name ?? '待指派车间'} / ${worker.name ?? '待指派负责人'}'
        ' / 超产 $percent%';
  }
}

/// 一个汇总草稿拆出的一张工单：一组「怎么做」参数相同的来源。
/// 非车间通道(采购 / 委外)不拆，[params] 为 null。
final class _MaterialAggregatePart {
  _MaterialAggregatePart(this.params);
  _MaterialAggregateMakeParams? params;
  final lineIds = <String>[];
  final groups = <_MaterialGroup>[];

  /// 这张工单的超产比例是人定的吗(任一来源改过即算，见 [partsOf])。
  bool get rateExplicit => params?.rateExplicit ?? false;

  /// 本张工单的提交键，由 [_MaterialAggregateTableController.partsOf] 填。
  String clientGroupKey = '';
  String get label => params?.label ?? '';
}
