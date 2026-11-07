part of 'production_material_analysis_page.dart';

const _materialAllocationPrecisionKey =
    'production.material.aggregate-allocation';

class _MaterialPrecisionDraftHost extends ConsumerStatefulWidget {
  const _MaterialPrecisionDraftHost({
    super.key,
    required this.controller,
    required this.analysisId,
    required this.sessionScope,
    required this.child,
  });
  final _MaterialAggregateTableController controller;
  final String analysisId, sessionScope;
  final Widget child;
  @override
  ConsumerState<_MaterialPrecisionDraftHost> createState() =>
      _MaterialPrecisionDraftState();
}

class _MaterialPrecisionDraftState
    extends ConsumerState<_MaterialPrecisionDraftHost>
    with FormDraftMixin<_MaterialPrecisionDraftHost> {
  final initialized = Completer<void>();
  Map<String, dynamic> _lastSnapshot = {};
  bool _initializing = false;
  bool get current =>
      mounted &&
      formDraftIdentityIsCurrent &&
      widget.controller.owner.mounted &&
      widget.controller.owner._analysis?.analysisId == widget.analysisId &&
      widget.controller.owner._sessionScopeKey() == widget.sessionScope;
  @override
  bool get formDraftUseCurrentRoute => false;
  @override
  bool get formDraftBusy => widget.controller.saving;
  @override
  bool get formDraftCanReplaySubmission =>
      widget.controller._submittedRequest != null;
  @override
  String? get formDraftResumeId =>
      widget.controller.owner.widget.preparationDraftId;
  @override
  FormDraftSpec get formDraftSpec => FormDraftCatalog.materialPreparation.spec(
    routeParameters: {
      'analysisId': widget.analysisId,
      if (widget.controller.owner.widget.planCreateEntry)
        'planCreateEntry': 'true',
    },
  );
  @override
  Iterable<Listenable> get formDraftListenables => [
    widget.controller.draftPulse,
  ];
  @override
  Map<String, dynamic> captureFormDraft() {
    if (current) {
      _lastSnapshot = widget.controller.capturePrecisionDraft(
        widget.analysisId,
      );
    }
    return _lastSnapshot;
  }

  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    if (!current || data['analysisId'] != widget.analysisId) {
      throw const FormatException('草稿对应另一份分析，原输入已保留');
    }
    await widget.controller.restorePrecisionDraft(data, () => current);
    _lastSnapshot = data;
  }

  @override
  void initState() {
    super.initState();
    widget.controller.draftHost = this;
    widget.controller.owner._materialProjectionPending.addListener(
      _tryInitialize,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryInitialize());
  }

  void _tryInitialize() {
    if (!mounted ||
        _initializing ||
        initialized.isCompleted ||
        !current ||
        widget.controller.owner._materialPresentedScope !=
            widget.sessionScope) {
      return;
    }
    _initializing = true;
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await initializeFormDraft();
    } finally {
      if (!initialized.isCompleted) initialized.complete();
    }
    if (current && !formDraftRestorationBlocked) {
      if (widget.controller.precisionDraft != null) {
        await widget.controller.chooseAllocationPrecision();
      }
      widget.controller.schedulePreview();
    }
  }

  @override
  void didUpdateWidget(covariant _MaterialPrecisionDraftHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    markFormDraftChanged();
  }

  Future<T> preview<T>(Future<T> Function() send) async {
    await initialized.future;
    if (!current || formDraftRestorationBlocked) {
      throw StateError('原草稿或身份尚未核对，请保留输入');
    }
    return runFormDraftPrecisionRead(send);
  }

  Future<T> mutate<T>(Future<T> Function() send) async {
    await initialized.future;
    if (!current || formDraftRestorationBlocked) {
      throw StateError('原草稿或身份尚未核对，请保留输入');
    }
    return runFormDraftSubmission(send);
  }

  @override
  Widget build(BuildContext context) {
    if (!initialized.isCompleted) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _tryInitialize());
    }
    return withFormDraft(widget.child);
  }

  @override
  void dispose() {
    widget.controller.owner._materialProjectionPending.removeListener(
      _tryInitialize,
    );
    if (!initialized.isCompleted) initialized.complete();
    if (identical(widget.controller.draftHost, this)) {
      widget.controller.draftHost = null;
    }
    super.dispose();
  }
}

extension _MaterialPrecisionDraftOwner on _MaterialAggregateTableController {
  Widget draftBoundary(Widget child) {
    final analysis = owner._analysis;
    if (analysis == null) return child;
    final scope = owner._sessionScopeKey();
    precisionOwnerScope ??= scope;
    if (precisionOwnerScope != scope) {
      if (drafts.isNotEmpty ||
          _submittedRequest != null ||
          owner._tableUserTypedQty.isNotEmpty ||
          owner._preparationOrderMethodByGroup.isNotEmpty) {
        return const Material(
          child: Center(child: Text('登录身份或权限已变化，请重新打开分析。原输入和原请求保留在原账号下。')),
        );
      }
      precisionOwnerScope = scope;
    }
    // Keep a stable wrapper while the table publishes a new projection. Mounting
    // and unmounting it from projection readiness would restart large grids.
    return _MaterialPrecisionDraftHost(
      key: ValueKey(
        'material-precision-${analysis.analysisId}-${owner.ref.read(exportContextEpochProvider)}',
      ),
      controller: this,
      analysisId: analysis.analysisId,
      sessionScope: scope,
      child: child,
    );
  }

  Future<T> withDraftPrecisionRead<T>(Future<T> Function() send) async {
    final host = draftHost;
    if (host == null) throw StateError('备料草稿保护正在准备，请保留输入并稍后核对');
    return host.preview(send);
  }

  Future<T> withDraftMutation<T>(Future<T> Function() send) async {
    final host = draftHost;
    if (host == null) throw StateError('备料草稿保护正在准备，本次未提交');
    return host.mutate(send);
  }

  List<String> splitWithCurrentPrecision(
    _MaterialAggregateDraft draft,
    List<String> needs,
  ) {
    final policy = draftHost?.formDraftPrecisionChoice(
      _materialAllocationPrecisionKey,
    );
    try {
      return splitTypedTotalText(
        draft.totalText,
        needs,
        precisionScale: policy?.scale,
        precisionRounding: policy?.rounding,
      );
    } on MaterialQuantityPrecisionRequired catch (required) {
      precisionDraft = draft;
      precisionReason = required.reason;
      final fingerprint =
          '${owner._analysis?.analysisId}:${draft.key}:${draft.totalText}:$_revision:${policy?.scale}:${policy?.rounding}';
      if (!precisionBusy && precisionAsked.add(fingerprint)) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => unawaited(chooseAllocationPrecision()),
        );
      }
      rethrow;
    }
  }

  Future<void> chooseAllocationPrecision() async {
    final draft = precisionDraft, host = draftHost, reason = precisionReason;
    if (precisionBusy ||
        saving ||
        uncertain ||
        draft == null ||
        host == null ||
        reason == null) {
      return;
    }
    precisionBusy = true;
    final revision = _revision,
        scope = owner._sessionScopeKey(),
        text = draft.totalText;
    try {
      await host.initialized.future;
      final policy = await host.chooseFormDraftPrecision(
        BusinessPrecisionRequirement(
          key: _materialAllocationPrecisionKey,
          groupKey: _materialAllocationPrecisionKey,
          label: '本次汇总输入在各来源/工单的分配；最后来源承接精确余量',
          maxScale: 24,
          reason: reason,
        ),
        isCurrent: () =>
            host.current &&
            _revision == revision &&
            drafts[draft.key] == draft &&
            draft.totalText == text &&
            owner._sessionScopeKey() == scope &&
            !saving &&
            !uncertain,
      );
      if (policy == null ||
          !host.current ||
          revision != _revision ||
          text != draft.totalText) {
        return;
      }
      precisionDraft = null;
      precisionReason = null;
      owner._mutateAggregateTable(() {
        error = null;
        _applyLocalSplit(draft);
        _revision++;
      });
      schedulePreview();
    } on MaterialQuantityPrecisionRequired catch (required) {
      if (owner.mounted) {
        owner._mutateAggregateTable(
          () => error = required.exceedsTotal
              ? '所选位数会使建议份额超过原总量，请增加位数或选择直接截取；原输入未改'
              : required.message,
        );
      }
    } finally {
      precisionBusy = false;
    }
  }

  Set<String> get precisionInputKeys => {
    for (final draft in drafts.values)
      for (final path in draft.paths.values) path.groupKey,
  };
  Set<String> get precisionInputLines => {
    for (final draft in drafts.values) ...draft.paths.keys,
  };
  Map<String, dynamic> capturePrecisionDraft(String analysisId) => {
    'schema': 1,
    'analysisId': analysisId,
    'warehouseId': owner._warehouseId,
    'billDate': owner._dateText(owner._billDate),
    'deliveryDate': owner._dateText(owner._deliveryDate),
    'orderMethodByGroup': {
      for (final entry in owner._preparationOrderMethodByGroup.entries)
        entry.key: entry.value.wireName,
    },
    'approveNow': owner._preparationApproveNow,
    'groups': [
      for (final draft in drafts.values)
        {
          'key': draft.key,
          'label': draft.label,
          'totalText': draft.totalText,
          'userEntered': draft.userEntered,
          'productFlow': draft.productFlow,
          'appendFlow': draft.appendFlow,
          'receiptAllocationMode': ?draft.receiptAllocationMode?.wireName,
          'sourceRequested': draft.sourceRequestedQtyByMaterialLineId,
          'mixedWorkshop': draft.mixedWorkshop,
          'mixedWorker': draft.mixedWorker,
          'mixedRate': draft.mixedRate,
          'paths': {
            for (final entry in draft.paths.entries)
              entry.key: {
                'groupKey': entry.value.groupKey,
                'orderText': entry.value.orderText,
                'appendText': entry.value.appendText,
                'orderSeed': entry.value.orderSeed,
                'appendSeed': entry.value.appendSeed,
                'typedQty': entry.value.typedQty?.toString(),
                'selected': entry.value.selected,
                'autoSelected': entry.value.autoSelected,
                'deselected': entry.value.deselected,
                'workshop': _prepAssignment(entry.value.workshop),
                'worker': _prepAssignment(entry.value.worker),
                'rate': entry.value.rate,
                'rateExplicit': entry.value.rateExplicit,
              },
          },
        },
    ],
    'uncertain': uncertain,
    if (uncertain) formDraftUnknownSubmissionKey: true,
    if (_submittedRequest != null) ...{
      'submittedAnalysisId': _submittedRequest!.analysisId,
      'submittedPreviewFingerprint': _submittedFingerprint,
      'submittedBodyJson': jsonEncode(
        _submittedRequest!.toJson(previewFingerprint: _submittedFingerprint),
      ),
    },
    'selected': {
      for (final key in precisionInputKeys)
        key: owner._selectedMaterialGroupKeys.contains(key),
    },
    'autoSelected': {
      for (final key in precisionInputKeys)
        key: owner._tableAutoSelectedKeys.contains(key),
    },
    'deselected': {
      for (final key in precisionInputKeys)
        key: owner._tableUserDeselectedKeys.contains(key),
    },
    'workshops': {
      for (final key in precisionInputKeys)
        if (owner._tableWorkshopDraft.containsKey(key))
          key: _prepAssignment(owner._tableWorkshopDraft[key]),
    },
    'workers': {
      for (final key in precisionInputKeys)
        if (owner._tableWorkerDraft.containsKey(key))
          key: _prepAssignment(owner._tableWorkerDraft[key]),
    },
    'typed': {
      for (final line in precisionInputLines)
        if (owner._tableUserTypedQty.containsKey(line))
          line: owner._tableUserTypedQty[line].toString(),
    },
    'currentOrder': {
      for (final e in owner._tableOrderQtyControllers.entries)
        if (precisionInputKeys.contains(e.key)) e.key: e.value.text,
    },
    'currentAppend': {
      for (final e in owner._tableAppendQtyControllers.entries)
        if (precisionInputKeys.contains(e.key)) e.key: e.value.text,
    },
  };
  Future<void> restorePrecisionDraft(
    Map<String, dynamic> data,
    bool Function() current,
  ) async {
    if (data['schema'] != 1 ||
        data['analysisId'] != owner._analysis?.analysisId ||
        data['groups'] is! List) {
      throw const FormatException('备料草稿来源或版本无法核对，原输入已保留');
    }
    final restored = <String, _MaterialAggregateDraft>{},
        byLine = <String, String>{};
    final work = UiWorkBudget();
    for (final raw in data['groups'] as List) {
      if (!current()) throw StateError('原草稿身份已变化');
      final group = Map<String, dynamic>.from(raw as Map),
          paths = <String, _MaterialAggregatePathSnapshot>{};
      for (final entry in (group['paths'] as Map).entries) {
        final row = Map<String, dynamic>.from(entry.value as Map);
        final line = entry.key.toString();
        if (byLine.containsKey(line)) {
          throw const FormatException('原备料来源重复，原草稿已保留');
        }
        byLine[line] = group['key'] as String;
        paths[line] = _MaterialAggregatePathSnapshot(
          groupKey: row['groupKey'] as String,
          orderText: row['orderText'] as String,
          appendText: row['appendText'] as String,
          orderSeed: row['orderSeed'] as String?,
          appendSeed: row['appendSeed'] as String?,
          typedQty: double.tryParse(row['typedQty']?.toString() ?? ''),
          selected: row['selected'] == true,
          autoSelected: row['autoSelected'] == true,
          deselected: row['deselected'] == true,
          workshop: _prepAssignmentRead(row['workshop']),
          worker: _prepAssignmentRead(row['worker']),
          rate: row['rate'] as String,
          rateExplicit: row['rateExplicit'] == true,
        );
        await work.checkpoint();
      }
      final receiptMode = MaterialReceiptAllocationMode.fromWire(
        group['receiptAllocationMode'],
      );
      if (group['receiptAllocationMode'] != null && receiptMode == null) {
        throw const FormatException('原备料草稿的到货归属无法核对，请保留原草稿');
      }
      final draft =
          _MaterialAggregateDraft(
              group['key'] as String,
              group['label'] as String,
              paths,
              group['totalText'] as String,
            )
            ..userEntered = group['userEntered'] == true
            ..productFlow = group['productFlow'] == true
            ..appendFlow = group['appendFlow'] == true
            ..receiptAllocationMode = receiptMode
            ..sourceRequestedQtyByMaterialLineId =
                group['sourceRequested'] is Map
                ? Map<String, String>.from(group['sourceRequested'] as Map)
                : null
            ..mixedWorkshop = group['mixedWorkshop'] == true
            ..mixedWorker = group['mixedWorker'] == true
            ..mixedRate = group['mixedRate'] == true;
      restored[draft.key] = draft;
    }
    MaterialAggregateOrderRequest? frozen;
    String? fingerprint;
    if (data['submittedBodyJson'] case final String body) {
      final json = Map<String, dynamic>.from(jsonDecode(body) as Map);
      frozen = MaterialAggregateOrderRequest.fromExactJson(
        data['submittedAnalysisId'] as String,
        json,
      );
      fingerprint = data['submittedPreviewFingerprint'] as String;
      if (jsonEncode(frozen.toJson(previewFingerprint: fingerprint)) != body) {
        throw const FormatException('原提交内容不能原样恢复，请保留草稿并只读核对');
      }
    }
    if (data['uncertain'] == true && frozen == null) {
      throw const FormatException('原未知请求缺失，不能创建替代请求');
    }
    if (!current()) throw StateError('原草稿身份已变化');
    final liveIndexes = owner._analysisIndexes(owner._analysis!);
    for (final draft in restored.values) {
      for (final line in draft.paths.keys) {
        if (!liveIndexes.groupsByLine.containsKey(line)) {
          throw const FormatException('原来源已经变化，不能局部恢复备料草稿；原输入已保留');
        }
      }
    }
    final restoredChoices = <String, MaterialPreparationOrderMethod>{};
    final rowChoices = data['orderMethodByGroup'];
    if (rowChoices != null && rowChoices is! Map) {
      throw const FormatException('原备料草稿的下单方式无法核对，请保留草稿并重新读取');
    }
    if (rowChoices is Map) {
      for (final entry in rowChoices.entries) {
        final method = MaterialPreparationOrderMethod.fromWire(entry.value);
        if (method == null) {
          throw const FormatException('原备料草稿的下单方式无法核对，请保留草稿并重新读取');
        }
        final key = entry.key.toString();
        if (liveIndexes.groupsByKey.containsKey(key)) {
          restoredChoices[key] = method;
        }
      }
    } else if (data['useAvailableQty'] case final bool legacyChoice) {
      // Older drafts used one choice for the whole batch.
      for (final key in liveIndexes.groupsByKey.keys) {
        restoredChoices[key] = legacyChoice
            ? MaterialPreparationOrderMethod.availableThenOrder
            : MaterialPreparationOrderMethod.orderAll;
      }
    }
    owner._mutateAggregateTable(() {
      drafts
        ..clear()
        ..addAll(restored);
      _draftByLine
        ..clear()
        ..addAll(byLine);
      _submittedRequest = frozen;
      _submittedFingerprint = fingerprint;
      _submittedSessionScope = frozen == null ? null : owner._sessionScopeKey();
      uncertain = data['uncertain'] == true;
      owner._warehouseId = data['warehouseId'] as String?;
      owner._billDate = DateTime.parse(data['billDate'] as String);
      owner._deliveryDate = data['deliveryDate'] == null
          ? null
          : DateTime.parse(data['deliveryDate'] as String);
      owner._preparationOrderMethodByGroup
        ..clear()
        ..addAll(restoredChoices);
      owner._preparationApproveChoice = data['approveNow'] == true;
      final indexes = owner._analysisIndexes(owner._analysis!);
      for (final draft in drafts.values) {
        for (final entry in draft.paths.entries) {
          final group = indexes.groupsByLine[entry.key];
          if (group != null) _restoreSnapshotQty(group, entry.value);
        }
        editors.putIfAbsent(draft.key, () => TextEditingController()).text =
            draft.totalText;
      }
      void restoreSet(String key, Set<String> target) {
        for (final entry in (data[key] as Map? ?? {}).entries) {
          if (entry.value == true) {
            target.add(entry.key.toString());
          } else {
            target.remove(entry.key.toString());
          }
        }
      }

      restoreSet('selected', owner._selectedMaterialGroupKeys);
      restoreSet('autoSelected', owner._tableAutoSelectedKeys);
      restoreSet('deselected', owner._tableUserDeselectedKeys);
      for (final entry in (data['workshops'] as Map? ?? {}).entries) {
        final value = _prepAssignmentRead(entry.value);
        if (value != null) {
          owner._tableWorkshopDraft[entry.key.toString()] = value;
        }
      }
      for (final entry in (data['workers'] as Map? ?? {}).entries) {
        final value = _prepAssignmentRead(entry.value);
        if (value != null) {
          owner._tableWorkerDraft[entry.key.toString()] = value;
        }
      }
      for (final entry in (data['typed'] as Map? ?? {}).entries) {
        final value = double.tryParse(entry.value.toString());
        if (value != null) {
          owner._tableUserTypedQty[entry.key.toString()] = value;
        }
      }
      for (final e in (data['currentOrder'] as Map? ?? {}).entries) {
        owner._tableOrderQtyControllers[e.key]?.text = e.value.toString();
      }
      for (final e in (data['currentAppend'] as Map? ?? {}).entries) {
        owner._tableAppendQtyControllers[e.key]?.text = e.value.toString();
      }
      if (!uncertain) {
        for (final draft in drafts.values) {
          _applyLocalSplit(draft);
        }
      }
      _revision++;
      _preview = null;
      _previewRequest = null;
    });
  }
}

Map<String, String?>? _prepAssignment(({String? id, String? name})? value) =>
    value == null ? null : {'id': value.id, 'name': value.name};
({String? id, String? name})? _prepAssignmentRead(Object? value) => value is Map
    ? (id: value['id'] as String?, name: value['name'] as String?)
    : null;
