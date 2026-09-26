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

  void analysisChanged() {
    if (drafts.isEmpty) return;
    _revision++;
    _preview = null;
    _previewRequest = null;
    for (final draft in drafts.values) {
      draft.previewGroups = const [];
    }
    if (!saving && !uncertain) schedulePreview();
  }

  Widget lockedText(String value) =>
      Tooltip(message: '此来源已有未提交的汇总总量，请到「按物料汇总」修改、下达或撤销草稿', child: Text(value));

  Widget actionCell(_MaterialAggregate aggregate) {
    final actionIds = <String>{
      for (final path in aggregate.paths)
        for (final target in path.notifiedTargets)
          if (target.actionId != null &&
              target.status != 'CANCELLED' &&
              owner._supplyOperationType(target.actionId) == 'AGGREGATE_SUPPLY')
            target.actionId!,
    };
    if (actionIds.isEmpty) return const Text('勾选后下单');
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
            '累计已下单 ${owner._qty(orderedQty(aggregate))}。'
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
            Text(
              owner._qty(orderedQty(aggregate)),
              key: cellKey,
              style: Theme.of(
                owner.context,
              ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700),
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
    return SizedBox(
      height: 40 * MediaQuery.textScalerOf(owner.context).scale(1),
      child: owner._materialTableQtyField(
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
        invalid: () => !validText(controller.text),
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
        _draftByLine[line] = aggregate.key;
        changed = true;
      }
      if (changed) {
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
          owner._qty(
            groups.fold<double>(
              0.0,
              (sum, group) => sum + owner._tableSubmitQtyOf(group),
            ),
          ),
        )
        ..userEntered = snapshots.values.any(
          (state) =>
              state.typedQty != null ||
              state.orderText != state.orderSeed ||
              state.appendText != state.appendSeed,
        );
    });
  }

  _MaterialAggregatePathSnapshot _snapshot(_MaterialGroup group) =>
      _MaterialAggregatePathSnapshot(
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
        rate: owner
            ._overproductionPercentController(
              materialLineId: group.representative.materialLineId,
            )
            .text,
      );

  void changed(_MaterialAggregate aggregate, String value) {
    if (saving || uncertain) return;
    owner._mutateAggregateTable(() {
      final draft = begin(aggregate);
      draft.totalText = value;
      draft.userEntered = true;
      draft.previewGroups = const [];
      _revision++;
      _preview = null;
      _previewRequest = null;
      error = null;
      for (final snapshot in draft.paths.values) {
        owner._selectedMaterialGroupKeys.add(snapshot.groupKey);
        owner._tableUserDeselectedKeys.remove(snapshot.groupKey);
      }
    });
    schedulePreview();
  }

  bool validText(String value) =>
      RegExp(r'^\d+(?:\.\d{0,4})?$').hasMatch(value.trim()) &&
      (double.tryParse(value)?.isFinite ?? false) &&
      (double.tryParse(value) ?? -1) >= 0;

  void schedulePreview() {
    if (saving || uncertain || drafts.isEmpty) return;
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 300),
      () => unawaited(refreshPreview()),
    );
  }

  List<_MaterialGroup> draftGroups(
    _MaterialAggregateDraft draft, {
    bool requireComplete = false,
  }) {
    final analysis = owner._analysis;
    if (analysis == null) return const [];
    final byLine = owner._analysisIndexes(analysis).groupsByLine;
    final groups = [for (final line in draft.lineIds) ?byLine[line]];
    if (requireComplete && groups.length != draft.lineIds.length) {
      throw const FormatException('汇总来源已变化，请核对后撤销此草稿重新填写');
    }
    return groups;
  }

  String? uniformId(Iterable<String?> ids, String label) {
    final values = ids.toSet();
    if (values.length > 1) throw FormatException('各来源$label不同，请先在汇总行统一设置');
    return values.isEmpty ? null : values.single;
  }

  MaterialAggregateOrderRequest requestFor(
    List<_MaterialAggregateDraft> selected,
  ) {
    final analysis = owner._analysis!;
    final inputs = <MaterialAggregateOrderGroupInput>[];
    for (final draft in selected) {
      if (!validText(draft.totalText)) {
        throw FormatException('「${draft.label}」请输入非负数量，最多四位小数');
      }
      final groups = draftGroups(draft, requireComplete: true);
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
      // 服务端对 manufacture 组(MAKE + 要先自制目标件的委外)一律要求车间 /
      // 负责人 / 超产比例，权限也只看「下达车间」——与 [workshopGroups] 同一
      // 口径，别让前置自制委外漏带车间再次被拒(2026-09-25 对齐修正)。
      final workshop =
          route == MaterialSupplyRoute.make ||
          owner._tableIssueTarget(groups.first).viaWorkshop;
      if (workshop && !owner._canGenerate || !workshop && !owner._canNotify) {
        throw FormatException('没有下达「${draft.label}」的权限');
      }
      if (workshop &&
          (draft.mixedWorkshop || draft.mixedWorker || draft.mixedRate)) {
        throw FormatException('「${draft.label}」原来源生产参数不同，请明确统一本次车间、负责人和比例');
      }
      final rateTexts = workshop
          ? groups
                .map(
                  (group) => owner
                      ._overproductionPercentController(
                        materialLineId: group.representative.materialLineId,
                      )
                      .text,
                )
                .toSet()
          : <String>{};
      if (rateTexts.length > 1) {
        throw FormatException('「${draft.label}」各来源超产比例不同，请先统一设置');
      }
      final rate = rateTexts.isEmpty
          ? null
          : parseProductionOverproductionPercent(rateTexts.single);
      if (workshop && rate == null) {
        throw FormatException('「${draft.label}」允许超产比例无效');
      }
      inputs.add(
        MaterialAggregateOrderGroupInput(
          clientGroupKey: draft.key,
          materialLineIds: draft.lineIds.toList()..sort(),
          route: route,
          qty: draft.totalText,
          allowPublicExtra: workshop || owner._canOverSupply,
          departmentId: workshop
              ? uniformId(
                  groups.map((group) => owner._tableWorkshopFor(group).id),
                  '生产车间',
                )
              : null,
          workerId: workshop
              ? uniformId(
                  groups.map((group) => owner._tableWorkerFor(group).id),
                  '负责人',
                )
              : null,
          allowedOverproductionRate: rate,
        ),
      );
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
        owner._permissions.contains(Perm.productionPlanApprove),
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
      approveNow: owner._permissions.contains(Perm.productionPlanApprove),
      groups: inputs,
    );
  }

  Future<void> refreshPreview({Set<String>? keys}) async {
    _debounce?.cancel();
    if (saving || uncertain || drafts.isEmpty) return;
    while (_flight != null) {
      await _flight!;
    }
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
    final signature =
        '$requestRevision|${scope.join('|')}|${owner._analysis?.version}|${owner._analysis?.fingerprint}|'
        '${owner._warehouseId}|${owner._dateText(owner._billDate)}|${owner._dateText(owner._deliveryDate)}|'
        '${owner._permissions.contains(Perm.productionPlanApprove)}';
    if (_preview != null && _previewSignature == signature) return;
    late final Future<void> work;
    work = _performPreview(requestRevision, effectiveKeys, signature)
        .whenComplete(() {
          if (identical(_flight, work)) _flight = null;
        });
    _flight = work;
    await work;
    if (_revision != requestRevision &&
        owner.mounted &&
        !saving &&
        !uncertain) {
      await refreshPreview(keys: keys);
    }
  }

  Future<void> _performPreview(
    int revision,
    Set<String>? keys,
    String signature,
  ) async {
    try {
      final selected = drafts.values
          .where((draft) => keys == null || keys.contains(draft.key))
          .toList();
      if (selected.isEmpty) return;
      final request = requestFor(selected);
      final token = CancelToken();
      _cancelToken = token;
      final preview = await owner.ref
          .read(productionPlanRepositoryProvider)
          .previewAggregateOrders(request, cancelToken: token);
      if (!owner.mounted || revision != _revision) return;
      final grouped = <String, List<MaterialAggregateOrderGroupPreview>>{};
      for (final group in preview.groups) {
        final input = request.groups
            .where((input) => input.clientGroupKey == group.clientGroupKey)
            .firstOrNull;
        if (input == null ||
            group.sources.any(
              (source) =>
                  !input.materialLineIds.contains(source.materialLineId),
            )) {
          throw const FormatException('预览返回了不属于本次汇总的来源，未套用此结果');
        }
        grouped.putIfAbsent(group.clientGroupKey, () => []).add(group);
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
        if ((allocated - double.parse(draft.totalText)).abs() > 0.00005 &&
            groups.every((group) => group.blockedReason == null)) {
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
          if ((contribution - double.parse(draft.totalText)).abs() > 0.00005) {
            continue;
          }
          final allocation = <String, double>{};
          for (final group in draft.previewGroups) {
            for (final source in group.sources) {
              allocation.update(
                source.materialLineId,
                (value) => value + source.allocatedQty,
                ifAbsent: () => source.allocatedQty,
              );
            }
          }
          for (final group in draftGroups(draft)) {
            final line = group.representative.materialLineId;
            final quantity = allocation[line] ?? 0;
            final append = owner._tableGroupIssued(group);
            final controller = append
                ? owner._tableAppendQtyController(group)
                : owner._tableOrderQtyController(group);
            controller.text = owner._qty(quantity);
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
      if (!owner.mounted || revision != _revision) return;
      owner._mutateAggregateTable(() {
        _preview = null;
        _previewRequest = null;
        error = failure is FormatException
            ? failure.message
            : productionErrorMessage(failure, fallback: '汇总预览失败，输入已保留');
      });
    }
  }

  /// [confirmed] = 调用方已经确认过一次(产品视图全选下单的主确认框说了
  /// 「合并成共享批次一次下达」)，各轮不再逐轮弹确认——用户口径 2026-09-25
  /// 「直接弹一次是否确认，确认后全部下达」。汇总视图直接下单仍逐轮核对。
  Future<bool> submit(
    List<_MaterialGroup> selectedGroups, {
    bool confirmed = false,
  }) => submission.submit(selectedGroups, confirmed: confirmed);

  Future<bool> submitStage(
    List<_MaterialGroup> selectedGroups, {
    bool confirmed = false,
  }) async {
    if (saving || selectedGroups.isEmpty) return false;
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
        await refreshPreview(keys: keys);
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
      if (blocked.isNotEmpty) {
        final blockedKeys = blocked
            .map((group) => group.clientGroupKey)
            .toSet();
        if (keys.difference(blockedKeys).isEmpty) {
          owner.context.appWarning(blocked.first.blockedReason!);
          return false;
        }
        // 一个组被服务端拒绝不再拖停整批(对齐产品视图「blocked 列出、其余照下」
        // 的口径)：释放被拒的草稿、把原因说一次，剩下的按原流程继续核对下达。
        // 2026-09-25 用户实机：全选下单时一种物料缺车间被拒，整批全部停在第一
        // 步，看起来就是「很多物料不能成功下单」。
        owner._mutateAggregateTable(() {
          for (final key in blockedKeys) {
            submission._releaseZero(key);
          }
        });
        owner.context.appInfo(
          '已跳过 ${blockedKeys.length} 种暂不能下达的物料'
          '（${blocked.first.blockedReason}），其余继续核对',
        );
        return submitStage(
          selectedGroups
              .where(
                (group) => !blockedKeys.contains(
                  owner._aggregateKeyOf(group.representative),
                ),
              )
              .toList(),
        );
      }
      final request = _previewRequest!, preview = _preview!;
      final userConfirmed =
          confirmed ||
          (await UtenDialog.show(
                owner.context,
                title: '确认下达 ${keys.length} 种物料？',
                content: SingleChildScrollView(
                  child: Text(
                    [
                      for (final group in preview.groups) ...[
                        '${group.goodsName}：本次 ${owner._qty(group.requestedQty)} ${group.unitName}',
                        if (group.existingBatchId != null)
                          '追加原批次，原产出 ${owner._qty(group.priorOutputQty)}；下层只办理本次净增量。',
                        '来源分配 ${owner._qty(group.sources.fold<double>(0.0, (sum, source) => sum + source.allocatedQty))}，公共备货 ${owner._qty(group.publicExtraQty)}',
                        for (final source in group.sources.take(6))
                          '${source.sourceLabel}：${owner._qty(source.allocatedQty)}',
                        if (group.sources.length > 6)
                          '另有 ${group.sources.length - 6} 个来源，详见汇总展开明细',
                        for (final child in group.sharedBomChildren.take(8))
                          '下层本批需 ${child.goodsName} ${owner._qty(child.requiredQty)} ${child.unitName}',
                        '',
                      ],
                      '按以上总量和来源分配一次下达；库存与生产开工条件仍按真实业务状态核对。',
                    ].join('\n'),
                  ),
                ),
                confirmLabel: '下达',
              )) ==
              true;
      if (!userConfirmed || !owner.mounted) return false;
      if (!identical(request, _previewRequest) ||
          !identical(preview, _preview)) {
        owner.context.appWarning('汇总内容已变化，请核对新的预览后再下达');
        return false;
      }
      _submittedRequest = request;
      _submittedFingerprint = preview.previewFingerprint;
    }
    final request = _submittedRequest!;
    owner._mutateAggregateTable(() {
      saving = true;
      error = null;
      owner._tableSubmitting = true;
    });
    try {
      // 确认弹窗已收口，这里起是纯网络段：挂遮罩(见上，同一次用户口径)。
      owner.bucketActionBusyMessage.value = '正在下达汇总物料';
      final result = await owner.ref
          .read(productionPlanRepositoryProvider)
          .submitAggregateOrders(
            request,
            previewFingerprint: _submittedFingerprint!,
          );
      if (!owner.mounted) return false;
      lastStageResult = result;
      owner._mutateAggregateTable(() {
        for (final input in request.groups) {
          final draft = drafts.remove(input.clientGroupKey);
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
      owner.context.appSuccess(
        '已下达 ${result.batches.length} 个批次${result.batches.isEmpty ? '' : '：${result.batches.map((batch) => batch.documentNo).where((value) => value.isNotEmpty).join('、')}'}',
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
        error = rejected ? failure.message : '提交回执尚未确认，请保留本次总量并使用相同内容重试核对';
        if (rejected) {
          _revision++;
          _preview = null;
          _previewRequest = null;
        }
      });
      if (failure is ApiException && failure.httpStatus == 409) {
        try {
          final current = await owner.ref
              .read(productionPlanRepositoryProvider)
              .materialAnalysisDetail(request.analysisId);
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
          owner
                  ._overproductionPercentController(materialLineId: entry.key)
                  .text =
              state.rate;
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

  /// 走车间通道的来源组：自制，以及**要先自制目标件的委外**。
  ///
  /// 2026-09-25 对齐修正：服务端 aggregate-orders 对这两类(manufacture)一律要求
  /// 生产车间+负责人，原来这里只认自制，导致「前置自制委外」的聚合行车间/负责人
  /// 两列显示「—」没处填、预览永远被拒——用户实机「按物料汇总很多物料下不了单」
  /// 的死结。判定与主表 [_tableIssueTarget].viaWorkshop 同源。
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
            .list(
              size: 30,
              search: keyword,
              departmentId: keyword?.trim().isEmpty != false
                  ? workshop.id
                  : null,
              includeSubtree: true,
            );
        return [
          for (final employee in result.items)
            UtenEmployeePickerItem(
              id: employee.id,
              name: employee.fullName,
              employeeCode: employee.code,
              departmentName: employee.departmentName,
            ),
        ];
      },
    );
    if (!owner.mounted || picked == null) return;
    owner._mutateAggregateTable(() {
      final draft = begin(aggregate);
      draft.mixedWorker = false;
      for (final group in groups) {
        owner._tableWorkerDraft[group.key] = (id: picked.id, name: picked.name);
      }
      invalidateDraft(draft);
    });
  }

  String rateText(_MaterialAggregate aggregate) {
    if (drafts[aggregate.key]?.mixedRate == true) return '多个比例';
    final groups = workshopGroups(aggregate);
    if (groups.isEmpty) return '—';
    final rates = groups
        .map(
          (group) => owner
              ._overproductionPercentController(
                materialLineId: group.representative.materialLineId,
              )
              .text,
        )
        .toSet();
    return rates.length == 1 ? '${rates.single}%' : '多个比例';
  }

  Widget rateCell(_MaterialAggregate aggregate) {
    final groups = workshopGroups(aggregate);
    if (groups.isEmpty) return const Text('—');
    final rates = groups
        .map(
          (group) => owner
              ._overproductionPercentController(
                materialLineId: group.representative.materialLineId,
              )
              .text,
        )
        .toSet();
    final initial = drafts[aggregate.key]?.mixedRate == true
        ? ''
        : rates.length == 1
        ? rates.single
        : '';
    final controller = rateEditors.putIfAbsent(
      aggregate.key,
      () => TextEditingController(text: initial),
    );
    if (!drafts.containsKey(aggregate.key) && controller.text != initial) {
      controller.text = initial;
    }
    return Tooltip(
      message: rates.length == 1 ? '本次汇总生产统一使用此比例' : '各来源比例不同，请明确填写本次汇总比例',
      child: ProductionOverproductionRateField(
        key: ValueKey('material-aggregate-rate-${aggregate.key}'),
        controller: controller,
        enabled: owner._canGenerate && !owner._busy && !uncertain,
        onChanged: (value) => owner._mutateAggregateTable(() {
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
    return material.requiredQty <= 0 &&
        const {
          MaterialRequirementState.delegatedToMakeChild,
          MaterialRequirementState.delegatedToSubcontractPreparation,
          MaterialRequirementState.inactiveParentCovered,
          MaterialRequirementState.inactiveParentRoute,
          MaterialRequirementState.inactiveReference,
        }.contains(material.effectiveRequirementState);
  }

  List<_MaterialTableRow> sharedProductionRows(
    ProductionMaterialAnalysisView analysis,
    _BomFilterProjection projection,
  ) {
    final result = <_MaterialTableRow>[];
    final indexes = owner._analysisIndexes(analysis);
    final parents = projection.presentation.parentIdsByMaterial.values.toSet();
    for (final product in analysis.products.where(
      (product) => product.sourceType == 'AGGREGATE_MAKE',
    )) {
      if (!projection.visibleProductIds.contains(product.analysisLineId)) {
        continue;
      }
      final nodes =
          projection.nodesByProduct[product.analysisLineId] ??
          const <ProductionMaterialAnalysisMaterial>[];
      result.add(
        _MaterialTableRow(
          kind: _MaterialTableRowKind.product,
          key: 'AGGREGATE_PRODUCTION|${product.analysisLineId}',
          sequence: 'S${result.length + 1}',
          depth: 0,
          product: product,
          hasChildren: nodes.isNotEmpty,
          rootAnalysisLineId: product.analysisLineId,
          contextOnly: projection.contextOnlyProductIds.contains(
            product.analysisLineId,
          ),
        ),
      );
      if (owner._collapsedBomProducts.contains(product.analysisLineId)) {
        continue;
      }
      for (final material in owner._orderedBomNodes(
        nodes,
        parentIds: projection.presentation.parentIdsByMaterial,
      )) {
        final group = indexes.groupsByLine[material.materialLineId];
        if (group == null) continue;
        result.add(
          _MaterialTableRow(
            kind: _MaterialTableRowKind.material,
            key: 'MATERIAL|${material.materialLineId}',
            sequence: 'S',
            depth:
                projection.presentation.depthByMaterial[material
                    .materialLineId] ??
                1,
            material: material,
            group: group,
            rootAnalysisLineId: product.analysisLineId,
            parentMaterialLineId: projection
                .presentation
                .parentIdsByMaterial[material.materialLineId],
            hasChildren: parents.contains(material.materialLineId),
            contextOnly: projection.contextOnlyMaterialIds.contains(
              material.materialLineId,
            ),
          ),
        );
      }
    }
    return result;
  }

  List<_MaterialGroup> selectableGroups(_MaterialTableRow row) =>
      selectionScope(row)
          .where(
            (group) =>
                (row.aggregate != null ||
                    !ownsLine(group.representative.materialLineId)) &&
                // 2026-09-25 确认路线退役：复选框只服务「下单」，不再有
                // 「选行去确认路线」语义（进页自动确认 + 直改即存接管）。
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

  /// Actual issue facts only. Shared plan anchors and public action slices are
  /// counted once even when multiple displayed paths point at the same source.
  double orderedQty(_MaterialAggregate aggregate) {
    var total = 0.0;
    final anchors = <String>{};
    final references = <String>{};
    final allocatedByAction = <String, double>{};
    for (final group in groupsOf(aggregate)) {
      final route = owner._draftRoute(group);
      if (owner._tableUsesMakeAnchor(group)) {
        final anchor = owner._tableMakeAnchorOf(group, authoritative: true);
        if (anchor != null) {
          if (anchors.add(anchor.analysisLineId)) {
            total +=
                anchor.issuedPlanQty *
                owner._tableAnchorUnitRate(group, anchor);
          }
          continue;
        }
        if (route == MaterialSupplyRoute.make) continue;
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
                'AGGREGATE_CONTINUATION',
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
        ? owner._qty(ordered)
        : drafts[aggregate.key]?.totalText ?? owner._qty(pendingQty(aggregate));
  }

  String appendText(_MaterialAggregate aggregate) =>
      orderedQty(aggregate) > 0.000000001
      ? drafts[aggregate.key]?.totalText ?? owner._qty(pendingQty(aggregate))
      : '0';

  int includedOutsideCurrentRows(Iterable<_MaterialGroup> pending) {
    final analysis = owner._analysis;
    if (analysis == null) return 0;
    final rows = owner._materialTableRows(analysis);
    const pageSize = _MaterialAnalysisMaterialTableState._materialTablePageSize;
    final pages = (rows.length / pageSize).ceil().clamp(1, 1000000);
    final page = owner._bomTablePageNo.clamp(1, pages);
    final visible = <String>{};
    for (final row in rows.skip((page - 1) * pageSize).take(pageSize)) {
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
  });
  final String groupKey, orderText, appendText, rate;
  final String? orderSeed, appendSeed;
  final double? typedQty;
  final bool selected, autoSelected, deselected;
  final ({String? id, String? name})? workshop, worker;
}
