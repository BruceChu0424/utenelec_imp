part of 'production_material_increment_pages.dart';

class ProductionMaterialIncrementCreatePage extends ConsumerStatefulWidget {
  const ProductionMaterialIncrementCreatePage({
    super.key,
    required this.segmentId,
  });
  final String segmentId;
  @override
  ConsumerState<ProductionMaterialIncrementCreatePage> createState() =>
      _IncrementCreateState();
}

class _IncrementCreateState
    extends ConsumerState<ProductionMaterialIncrementCreatePage>
    with FormDraftMixin<ProductionMaterialIncrementCreatePage> {
  ProductionMaterialIncrementContext? _data;
  List<Map<String, dynamic>> _materials = const [];
  Map<String, Map<String, dynamic>> _demandById = const {};
  final _quantities = <String, TextEditingController>{};
  final _selectedIds = <String>{};
  final _reason = TextEditingController();
  List<Map<String, dynamic>>? _frozenRequests;
  String? _error;
  bool _busy = false,
      _loading = false,
      _uncertain = false,
      _submissionPending = false;
  bool _draftInitialized = false;
  bool _sourceChanged = false;
  int _loadGeneration = 0;

  @override
  bool get formDraftBusy => _busy || _loading || _uncertain;
  @override
  bool get formDraftCanReplaySubmission => _frozenRequests?.isNotEmpty == true;
  @override
  bool get formDraftHasUnknownSubmission => _uncertain || _submissionPending;
  @override
  FormDraftSpec get formDraftSpec => FormDraftSpec(
    title: '申请追加用料',
    module: BadgeModule.workshop,
    route: RoutePath.productionMaterialIncrementForSegment(widget.segmentId),
    permission: productionMaterialIncrementPermission,
  );
  @override
  Iterable<Listenable> get formDraftListenables => [
    _reason,
    ..._quantities.values,
  ];
  @override
  Map<String, dynamic> captureFormDraft() => {
    'reason': _reason.text,
    'quantities': {
      for (final entry in _quantities.entries) entry.key: entry.value.text,
    },
    'selectedIds': _selectedIds.toList()..sort(),
    'frozenRequests': _frozenRequests,
    'uncertain': _uncertain || _submissionPending,
    'sourceChanged': _sourceChanged,
    'sources': [
      for (final id in _selectedIds)
        if (_demandById[id] case final row?)
          {
            'originalDemandId': id,
            'lockVersion': row['lockVersion'],
            'requestGeneration': row['requestGeneration'],
            'approvedIncrementQty': row['approvedIncrementQty'],
          },
    ],
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    _sourceChanged = data['sourceChanged'] == true;
    _reason.text = draftText(data, 'reason');
    final quantities = data['quantities'];
    if (quantities is Map) {
      for (final entry in quantities.entries) {
        _controller(entry.key.toString()).text = entry.value?.toString() ?? '';
      }
      _selectedIds.addAll(
        (data['selectedIds'] as List? ?? const []).whereType<String>(),
      );
    } else if (data['demandId'] is String) {
      // Preserve drafts created by the former single-material editor.
      final id = data['demandId'] as String;
      _controller(id).text = draftText(data, 'quantity');
      _selectedIds.add(id);
    }
    _uncertain = data['uncertain'] == true;
    final frozen = data['frozenRequests'];
    if (frozen is List && frozen.isNotEmpty) {
      _frozenRequests = frozen
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
      if (_frozenRequests!.any(
        (row) =>
            row['targetSegmentId'] != widget.segmentId ||
            row['originalDemandId'] is! String ||
            row['idempotencyKey'] is! String,
      )) {
        throw const FormatException('原追加申请的任务或回执标识不完整，请保留草稿核对');
      }
    }
    if (_uncertain && _frozenRequests == null) {
      throw const FormatException('原申请结果未知且缺少原始提交记录，请先核对申请结果');
    }
    if (!_uncertain && _selectedIds.any((id) => !_demandById.containsKey(id))) {
      _sourceChanged = true;
      _error = '原材料来源已变化；草稿填写保留，请重新核对材料来源';
    }
    final sources = data['sources'];
    if (!_uncertain) {
      if (sources is! List) {
        _sourceChanged = true;
      } else {
        final restoredSources = <Object?>{};
        for (final saved in sources.whereType<Map<Object?, Object?>>()) {
          final id = saved['originalDemandId'];
          if (!_selectedIds.contains(id)) continue;
          restoredSources.add(id);
          final current = _demandById[id];
          if (current == null ||
              saved['lockVersion'] != current['lockVersion'] ||
              saved['requestGeneration'] != current['requestGeneration'] ||
              productionExactQuantityUnits(saved['approvedIncrementQty']) !=
                  productionExactQuantityUnits(
                    current['approvedIncrementQty'],
                  )) {
            _sourceChanged = true;
          }
        }
        if (!_selectedIds.every(restoredSources.contains)) {
          _sourceChanged = true;
        }
      }
      if (_sourceChanged) {
        _error = '材料来源或审批版本需重新核对；原输入保留，请重新核对来源后提交';
      }
    }
    if (mounted) setState(() {});
  }

  List<Map<String, dynamic>> get _demands => _materials;
  bool get _editable =>
      !_busy && !_loading && !_uncertain && formDraftIdentityIsCurrent;
  TextEditingController _controller(String id) =>
      _quantities.putIfAbsent(id, TextEditingController.new);
  bool _eligible(Map<String, dynamic> row) => row['pendingRequestId'] == null;

  @override
  void initState() {
    super.initState();
    startFormDraftIdentityGuard();
    Future.microtask(_load);
  }

  @override
  void dispose() {
    _loadGeneration++;
    _reason.dispose();
    for (final controller in _quantities.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load({bool userTriggered = false}) async {
    if (_loading || _busy || _uncertain || !formDraftIdentityIsCurrent) return;
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repository = ref.read(
        productionMaterialIncrementRepositoryProvider,
      );
      final data = userTriggered
          ? await UtenBusyOverlay.run(
              context,
              title: '正在核对工单材料',
              action: () => repository.context(widget.segmentId),
            )
          : await repository.context(widget.segmentId);
      if (!formDraftIdentityIsCurrent || generation != _loadGeneration) return;
      setState(() {
        _data = data;
        if (userTriggered) _sourceChanged = false;
        _materials = data.demands;
        _demandById = {
          for (final row in _materials) row['originalDemandId'] as String: row,
        };
        for (final row in _materials) {
          _controller(row['originalDemandId'] as String);
        }
        if (!_draftInitialized &&
            _materials.length == 1 &&
            _eligible(_materials.single)) {
          _selectedIds.add(_materials.single['originalDemandId'] as String);
        }
      });
      if (!_draftInitialized) {
        _draftInitialized = true;
        await initializeFormDraft();
      }
    } on ApiException catch (error) {
      if (formDraftIdentityIsCurrent && generation == _loadGeneration) {
        setState(() => _error = error.message);
      }
    } catch (_) {
      if (formDraftIdentityIsCurrent && generation == _loadGeneration) {
        setState(() => _error = '材料来源读取失败，请重试；原输入仍保留');
      }
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  List<Map<String, dynamic>> _prepare() {
    if (_selectedIds.isEmpty || _selectedIds.length > 100) {
      throw const FormatException('请选择1至100项工单材料');
    }
    final reason = _reason.text.trim();
    if (reason.length < 2 || reason.length > 500) {
      throw const FormatException('请填写2至500字的申请原因');
    }
    final repository = ref.read(productionMaterialIncrementRepositoryProvider);
    final result = <Map<String, dynamic>>[];
    for (final id in _selectedIds.toList()..sort()) {
      final row = _demandById[id];
      if (row == null || !_eligible(row)) {
        throw const FormatException('选中材料来源已变化或已有待审批申请，请核对来源');
      }
      final text = _controller(id).text.trim();
      if (positiveMaterialCommandQuantityText(text) == null) {
        throw FormatException(
          '${row['goodsName']}：追加数量须大于0、最多4位小数且小于100000000000000',
        );
      }
      result.add(
        repository.submissionBody(
          context: _data!,
          demand: row,
          deltaQty: text,
          reason: reason,
        ),
      );
    }
    return result;
  }

  bool _definitelyRejected(ApiException error) =>
      error.hasResponseCode &&
      error.httpStatus != null &&
      error.httpStatus! >= 400 &&
      error.httpStatus! < 500;

  Future<void> _submit() async {
    if (_busy ||
        _loading ||
        !formDraftIdentityIsCurrent ||
        (_sourceChanged && !_uncertain) ||
        (_data?.canSubmit != true && !_uncertain)) {
      return;
    }
    final wasUncertain = _uncertain;
    try {
      if (!_uncertain) _frozenRequests = _prepare();
    } on FormatException catch (error) {
      setState(() => _error = error.message);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repository = ref.read(
        productionMaterialIncrementRepositoryProvider,
      );
      final scope = await captureFormDraftRequestScope();
      if (!mounted || !formDraftIdentityIsCurrent) return;
      final requests = await UtenBusyOverlay.run(
        context,
        title: '正在提交追加用料申请',
        action: () => scope.run(() async {
          _submissionPending = true;
          return runFormDraftSubmission(
            () => repository.submitBatch(_frozenRequests!),
            isDefiniteRejection: (error) =>
                !wasUncertain && _definitelyRejected(error),
          );
        }),
      );
      if (!formDraftIdentityIsCurrent) return;
      _submissionPending = false;
      _uncertain = false;
      await completeFormDraft();
      if (!mounted || !formDraftIdentityIsCurrent) return;
      bumpListRefresh(ref, productionMaterialIncrementRefreshKey);
      context.appSuccess('已提交 ${requests.length} 项追加用料申请');
      if (requests.length == 1) {
        context.pushReplacement(
          RoutePath.productionMaterialIncrementRequest(requests.single.id),
        );
      } else {
        popOrBackTo(context, defaultPath: RouteName.productionWorkshopTasks);
      }
    } on ApiException catch (error) {
      if (formDraftIdentityIsCurrent) {
        setState(() {
          _uncertain = wasUncertain || !_definitelyRejected(error);
          _error = _uncertain
              ? '${error.message}；提交结果尚未确认，请保留原内容重试，同一申请不会重复创建'
              : error.message;
          if (!_uncertain) _frozenRequests = null;
        });
      }
    } catch (_) {
      if (formDraftIdentityIsCurrent) {
        setState(() {
          _uncertain = true;
          _error = '提交结果尚未确认，请保留原内容重试；同一申请不会重复创建';
        });
      }
    } finally {
      _submissionPending = false;
      if (mounted) setState(() => _busy = false);
      if (formDraftIdentityIsCurrent) await checkpointFormDraftAfterCreation();
    }
  }

  List<MasterColumnDef<Map<String, dynamic>>> get _columns => [
    for (final field in const [
      ('goodsName', '材料名称', 210.0),
      ('goodsCode', '编号', 130.0),
      ('colorName', '颜色', 90.0),
      ('unitName', '单位', 72.0),
      ('requiredQty', '原定额', 100.0),
      ('approvedIncrementQty', '已批准追加', 110.0),
      ('netIssuedQty', '实际净领', 100.0),
      ('availableQty', '可用余料', 100.0),
    ])
      MasterColumnDef(
        key: field.$1,
        label: field.$2,
        width: field.$3,
        value: (row) => row[field.$1]?.toString() ?? '—',
      ),
    MasterColumnDef(
      key: 'deltaQty',
      label: '本次追加数量',
      width: 170,
      info: '每项材料可填写不同数量，最多4位小数；批准后新增该材料领用额度，实际发料数量由仓库核对。',
      value: (row) => _controller(row['originalDemandId'] as String).text,
      cellBuilder: (context, row) => TextField(
        key: ValueKey('increment-quantity-${row['originalDemandId']}'),
        controller: _controller(row['originalDemandId'] as String),
        enabled: _editable && _eligible(row),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: UtenInputDecoration(
          InputDecoration(
            isDense: true,
            suffixText: row['unitName']?.toString(),
          ),
        ),
        onChanged: (value) {
          if (value.trim().isNotEmpty) {
            setState(() => _selectedIds.add(row['originalDemandId'] as String));
          }
        },
      ),
    ),
    MasterColumnDef(
      key: 'pending',
      label: '申请状态',
      width: 170,
      value: (row) => row['pendingRequestId'] == null
          ? '可申请'
          : '已有追加 ${row['pendingDeltaQty']} 待审批',
      cellBuilder: (context, row) => row['pendingRequestId'] == null
          ? const Text('可申请')
          : TextButton(
              onPressed: _busy
                  ? null
                  : () => context.push(
                      RoutePath.productionMaterialIncrementRequest(
                        row['pendingRequestId'] as String,
                      ),
                    ),
              child: Text('追加 ${row['pendingDeltaQty']} 待审批'),
            ),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return withFormDraft(
      Scaffold(
        appBar: UtenAppBar(
          title: '申请追加用料',
          leading: UtenBackButton(
            onPressed: () => popOrBackTo(
              context,
              defaultPath: RouteName.productionWorkshopTasks,
            ),
          ),
        ),
        body: SafeArea(
          child: UtenContentContainer.wide(
            child: LayoutBuilder(
              builder: (context, constraints) => UtenPageEdgePadding.scroll(
                padding: EdgeInsets.fromLTRB(
                  16,
                  16,
                  16,
                  math.max(24, UtenCapsuleNavScope.occlusionOf(context)),
                ),
                builder: (context, padding) => SingleChildScrollView(
                  padding: padding,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (data != null)
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '工单：${data.segmentCode ?? '—'}',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                            const UtenFieldHintIcon(
                              info:
                                  '勾选本次需要补领的原工单材料，分别填写追加数量。计划部按材料审批后，仓库按实际数量发料；原定额及历史领料记录保留。',
                            ),
                          ],
                        ),
                      const SizedBox(height: 12),
                      SizedBox(
                        height: math.max(
                          240,
                          math.min(420, constraints.maxHeight - 290),
                        ),
                        child: MasterDataTableView<Map<String, dynamic>>(
                          tableKey:
                              'production.material_increment.create.materials',
                          virtualized: true,
                          columns: _columns,
                          items: _demands,
                          facets: const {},
                          nullCounts: const {},
                          filters: const {},
                          onFilterChanged: (_, _) {},
                          selectable: true,
                          rowKeyOf: (row) => row['originalDemandId'] as String,
                          idOf: (row) => _editable && _eligible(row)
                              ? row['originalDemandId'] as String
                              : null,
                          selectedIds: _selectedIds,
                          onClearSelection: _editable
                              ? () => setState(_selectedIds.clear)
                              : null,
                          onSelectedIdsChanged: (ids) {
                            if (_editable) {
                              setState(() {
                                _selectedIds
                                  ..clear()
                                  ..addAll(ids);
                              });
                            }
                          },
                          isLoading: _loading,
                          emptyMessage: '当前工单没有可追加的原冻结材料',
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        key: const ValueKey('increment-reason'),
                        controller: _reason,
                        enabled: _editable,
                        minLines: 2,
                        maxLines: 4,
                        decoration: const UtenInputDecoration(
                          InputDecoration(labelText: '申请原因（必填）'),
                        ),
                      ),
                      if (data?.blockingReason?.isNotEmpty == true)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(data!.blockingReason!),
                        ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      const SizedBox(height: 20),
                      Wrap(
                        alignment: WrapAlignment.end,
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          OutlinedButton(
                            onPressed: _editable
                                ? () => _load(userTriggered: true)
                                : null,
                            child: const Text('重新核对来源'),
                          ),
                          FilledButton(
                            onPressed:
                                !_busy &&
                                    !_loading &&
                                    ((_uncertain && _frozenRequests != null) ||
                                        (data?.canSubmit == true &&
                                            !_sourceChanged &&
                                            _selectedIds.isNotEmpty))
                                ? _submit
                                : null,
                            child: Text(_uncertain ? '重试原追加申请' : '提交计划部审批'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
