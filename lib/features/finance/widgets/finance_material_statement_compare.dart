part of 'finance_material_statement_dialog.dart';

class _ComparisonRow extends EditableGridRow {
  _ComparisonRow(this.sourceRow, {this.target, this.label});
  final int sourceRow;
  String? target, label;
  final changed = ValueNotifier<int>(0);
  @override
  void dispose() {
    changed.dispose();
    super.dispose();
  }
}

class _MaterialCompare extends ConsumerStatefulWidget {
  const _MaterialCompare({
    this.contextData,
    required this.dateFrom,
    required this.dateTo,
    this.resumeDraftId,
  });
  final Map<String, dynamic>? contextData;
  final String dateFrom, dateTo;
  final String? resumeDraftId;
  @override
  ConsumerState<_MaterialCompare> createState() => _MaterialCompareState();
}

class _MaterialCompareState extends ConsumerState<_MaterialCompare>
    with FormDraftMixin<_MaterialCompare> {
  final _from = TextEditingController(),
      _to = TextEditingController(),
      _sourceId = TextEditingController();
  final _grid = UtenEditableGridController<_ComparisonRow>();
  final _mappingScroll = ScrollController();
  List<Map<String, dynamic>> _mapping = [];
  Map<String, dynamic>? _context, _source, _result;
  Map<String, dynamic> _targetMetadata = {};
  List<Map<String, dynamic>> _targets = [];
  List<Map<String, dynamic>> _originals = [];
  bool _busy = false;
  int _read = 0, _tab = 0;
  String? _error;
  @override
  FormDraftSpec get formDraftSpec => FormDraftCatalog.financeMaterialStatement
      .spec(title: '${FinanceRequirementNames.otherReceivableStatement}原表比对');
  @override
  bool get formDraftUsesRouterGuard => false;
  @override
  bool get formDraftUseCurrentRoute => false;
  @override
  String? get formDraftResumeId => widget.resumeDraftId;
  @override
  bool get formDraftBusy => _busy;
  @override
  Iterable<Listenable> get formDraftListenables => [
    _from,
    _to,
    _sourceId,
    _grid,
  ];
  @override
  Map<String, dynamic> captureFormDraft() => {
    'mode': 'COMPARE',
    'contextId': _context?['id'],
    'sourceImportId': _sourceId.text,
    'dateFrom': _from.text,
    'dateTo': _to.text,
    'mappingPage': 1,
    'mapping': _captureMapping(),
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> saved) async {
    if (saved['mode'] != 'COMPARE') throw StateError('原草稿不属于原表比对');
    final id = saved['contextId']?.toString();
    if (id == null) throw StateError('原草稿缺少真实分组');
    if (widget.contextData != null && _id(widget.contextData) != id) {
      throw StateError('原草稿属于另一个分组，不能改配');
    }
    _sourceId.text = saved['sourceImportId']?.toString() ?? '';
    _from.text = saved['dateFrom']?.toString() ?? '';
    _to.text = saved['dateTo']?.toString() ?? '';
    final scope = await captureFormDraftRequestScope();
    final value = await scope.run(
      () => ref.read(apiClientProvider).get('$_materialBase/$id'),
    );
    if (!mounted || !scope.isCurrent || !formDraftIdentityIsCurrent) return;
    _context = value;
    await _load(mapping: _ml(saved['mapping']));
  }

  @override
  void initState() {
    super.initState();
    _context = widget.contextData;
    _from.text = widget.dateFrom;
    _to.text = widget.dateTo;
    startFormDraftIdentityGuard();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _run(() async {
        try {
          if (widget.resumeDraftId == null) await _load();
        } finally {
          if (mounted && formDraftIdentityIsCurrent) {
            await initializeFormDraft();
          }
        }
      }),
    );
  }

  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    _sourceId.dispose();
    _grid.dispose();
    _mappingScroll.dispose();
    super.dispose();
  }

  void _invalidate(String _) {
    _read++;
    setState(() {
      _source = null;
      _targets = [];
      _originals = [];
      _result = null;
    });
  }

  List<Map<String, dynamic>> _captureMapping() {
    final live = {
      for (final row in _grid.rows)
        row.sourceRow: {
          'sourceRow': row.sourceRow,
          'reportRowKey': row.target,
          'targetLabel': row.label,
        },
    };
    return [
      for (final original in _mapping)
        live[_mi(original['sourceRow'])] ?? original,
    ];
  }

  void _showMapping({bool preserve = true}) {
    if (preserve) _mapping = _captureMapping();
    if (_mappingScroll.hasClients) _mappingScroll.jumpTo(0);
    _grid.replaceAll([
      for (final value in _mapping)
        _ComparisonRow(
          _mi(value['sourceRow']),
          target: value['reportRowKey']?.toString(),
          label: value['targetLabel']?.toString(),
        ),
    ]);
  }

  Future<void> _run(Future<void> Function() body) async {
    if (_busy || !formDraftIdentityIsCurrent) return;
    setState(() => _busy = true);
    try {
      await body();
    } catch (e) {
      if (mounted && formDraftIdentityIsCurrent) {
        setState(() => _error = _problem(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load({List<Map<String, dynamic>>? mapping}) async {
    if (_context == null) return;
    final generation = ++_read;
    final scope = await captureFormDraftRequestScope(),
        api = ref.read(apiClientProvider);
    final target = await scope.run(
      () => api.get(
        '$_materialBase/comparison-targets',
        query: {
          'contextId': _id(_context),
          'dateFrom': _from.text.trim(),
          'dateTo': _to.text.trim(),
        },
      ),
    );
    final source = _sourceId.text.trim().isEmpty
        ? null
        : await scope.run(
            () => api.get('/finance/template-imports/${_sourceId.text.trim()}'),
          );
    if (!mounted ||
        !formDraftIdentityIsCurrent ||
        !scope.isCurrent ||
        generation != _read) {
      return;
    }
    if (source != null && source['template'] != 'otherReceivableStatement') {
      throw StateError('原件入口与本表不一致');
    }
    _targets = _ml(target['rows']);
    _targetMetadata = _mm(target['documentMetadata']);
    _source = source;
    _originals = [];
    final old = mapping ?? _captureMapping();
    final chosen = {for (final row in old) _mi(row['sourceRow']): row};
    final rows = <Map<String, dynamic>>[];
    if (_ml(source?['rows']).length > 2000) {
      throw StateError('原表超过2000行，请按实际原期间分段导入；已存原件保持，不截断冒充完整');
    }
    for (final original in _ml(source?['rows'])) {
      final number = _mi(original['sourceRow']), cells = _ml(original['cells']);
      _originals.add({
        'sourceRow': number,
        for (final cell in cells)
          cell['column'].toString(): cell['number'] ?? cell['text'],
      });
      rows.add({
        'sourceRow': number,
        'reportRowKey': chosen[number]?['reportRowKey'],
        'targetLabel': chosen[number]?['targetLabel'],
      });
      if (rows.length % 200 == 0) {
        await Future<void>.delayed(Duration.zero);
        if (!mounted || !scope.isCurrent || generation != _read) return;
      }
    }
    _mapping = rows;
    _showMapping(preserve: false);
    setState(() => _error = null);
  }

  Future<void> _import() => _run(() async {
    if (!ref.read(currentPermissionsProvider).contains(Perm.paymentStyleEdit)) {
      return;
    }
    final scope = await captureFormDraftRequestScope();
    await saveFormDraftNow();
    final file = await ref.read(financeEntryFilePickerProvider)();
    if (file == null || !mounted || !scope.isCurrent) return;
    final bytes = file.bytes;
    if (!{'xls', 'xlsx'}.contains(file.extension?.toLowerCase()) ||
        bytes == null ||
        bytes.isEmpty ||
        bytes.length > 15 * 1024 * 1024) {
      throw StateError('请选择完整XLS/XLSX原10列表，最大15MB');
    }
    final source = await scope.run(
      () => ref
          .read(apiClientProvider)
          .postBytes(
            '/finance/template-imports/costs/preview',
            bytes,
            query: {
              'template': 'otherReceivableStatement',
              'period': _from.text.substring(0, 7),
              'filename': file.name,
            },
            sendTimeout: const Duration(minutes: 2),
            receiveTimeout: const Duration(minutes: 3),
          ),
    );
    if (!mounted || !scope.isCurrent || !formDraftIdentityIsCurrent) return;
    _sourceId.text = source['importId'].toString();
    markFormDraftChanged();
    await _load();
    await saveFormDraftNow();
  });
  Future<void> _choose(_ComparisonRow row) async {
    final selected = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => UtenDialogFrame(
        child: SizedBox(
          width: 1180,
          height: MediaQuery.sizeOf(context).height * .78,
          child: _ComparisonTargetPicker(rows: _targets),
        ),
      ),
    );
    if (!mounted || !formDraftIdentityIsCurrent || selected == null) return;
    setState(() {
      row.target = selected['__rowKey']?.toString();
      row.label =
          '${selected['billDate']} / ${selected['goodsName']} / ${selected['__billNo'] ?? selected['__rowKind']}';
      _result = null;
    });
    row.changed.value++;
    markFormDraftChanged();
  }

  Future<void> _compare() => _run(() async {
    if (_context == null || _source == null) {
      throw StateError('请先读取完整原表和同源计算结果');
    }
    final scope = await captureFormDraftRequestScope();
    await saveFormDraftNow();
    final result = await scope.run(
      () => ref
          .read(apiClientProvider)
          .post(
            '$_materialBase/compare',
            body: {
              'sourceImportId': _sourceId.text.trim(),
              'auxiliaryId': _context!['auxiliary_id'],
              'accountingCurrencyId': _context!['accounting_currency_id'],
              'contextId': _id(_context),
              'allMaterialContexts': true,
              'dateFrom': _from.text.trim(),
              'dateTo': _to.text.trim(),
              'rows': [
                for (final row in _captureMapping())
                  if (row['reportRowKey'] != null)
                    {
                      'sourceRow': row['sourceRow'],
                      'reportRowKey': row['reportRowKey'],
                    },
              ],
            },
          ),
    );
    if (!mounted || !scope.isCurrent || !formDraftIdentityIsCurrent) return;
    setState(() {
      _result = result;
      _tab = 2;
      _error = null;
    });
  });
  Future<void> _close() async {
    if (!_busy && await confirmFormDraftExit() && mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!formDraftIdentityIsCurrent) {
      return withFormDraft(
        const Material(child: Center(child: Text('账号已切换，原表资料已隐藏'))),
      );
    }
    return withFormDraft(
      Material(
        child: Column(
          children: [
            UtenDialogSurface(
              child: UtenDialogHeader(
                showCloseButton: true,

                title: UtenDialogTitleWithHint(
                  title: Text(
                    '${FinanceRequirementNames.otherReceivableStatement}原表导入比对'
                    '${_result == null ? '' : '（未对应${(_result!['unmappedSourceRows'] as List).length}行）'}',
                  ),
                  info:
                      '比对保留全部原行号、原值及差额；逐行明确对应页每页编辑30行，提交比对使用完整清单。原件及期间载入后冻结，需另一原件或期间时，先关闭保留草稿再另开。',
                ),
                onClose: _busy ? null : _close,
              ),
            ),
            UtenDialogSurface(
              child: Column(
                children: [
                  UtenFormGrid(
                    minFieldWidth: 230,
                    children: [
                      UtenInput(
                        label: '开始日期',
                        controller: _from,
                        onChanged: _invalidate,
                        enabled: !_busy && _source == null,
                      ),
                      UtenInput(
                        label: '结束日期',
                        controller: _to,
                        onChanged: _invalidate,
                        enabled: !_busy && _source == null,
                      ),
                      UtenInput(
                        label: '恢复原件编号',
                        controller: _sourceId,
                        onChanged: _invalidate,
                        enabled: !_busy && _source == null,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  UtenResponsiveActionWrap(
                    children: [
                      UtenButton(
                        onPressed: _busy || _source != null ? null : _import,
                        child: const Text('导入财务原表'),
                      ),
                      UtenButton(
                        type: UtenButtonType.secondary,
                        onPressed: _busy ? null : () => _run(() => _load()),
                        child: const Text('读取原件及同源结果'),
                      ),
                      UtenButton(
                        onPressed: _busy || _source == null ? null : _compare,
                        child: const Text('按明确对应比对'),
                      ),
                      if (_busy)
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                    ],
                  ),
                  if (_source != null)
                    Text(
                      '原件：${_source!['sourceName']}；SHA256：${_source!['sha256']}；原公式仅保留缓存值，不执行。',
                    ),
                  if (_error != null)
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  if (_source?['issues'] is List)
                    for (final issue in _source!['issues'] as List)
                      Text(issue.toString()),
                ],
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: UtenSegmentRow<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('原表10列')),
                  ButtonSegment(value: 1, label: Text('逐行明确对应')),
                  ButtonSegment(value: 2, label: Text('差异结果')),
                  ButtonSegment(value: 3, label: Text('原隐藏旁算区核对')),
                ],
                selected: {_tab},
                onSelectionChanged: (v) => setState(() => _tab = v.single),
              ),
            ),
            Expanded(
              child: _tab == 0
                  ? _source == null
                        ? const Center(child: Text('先导入财务原表或填写原件编号恢复'))
                        : financeSourceTable(
                            tableKey: 'finance.material.original-comparison',
                            columns: [
                              for (
                                var i = 0;
                                i < (_source?['headers'] as List? ?? []).length;
                                i++
                              )
                                financeSourceColumn(
                                  '${i + 1}',
                                  (_source!['headers'] as List)[i].toString(),
                                  width: 165,
                                ),
                            ],
                            rows: _originals,
                            idOf: (r) => r['sourceRow'].toString(),
                            busy: _busy,
                          )
                  : _tab == 1
                  ? Column(
                      children: [
                        Expanded(
                          child: SingleChildScrollView(
                            controller: _mappingScroll,
                            child: UtenEditableGrid<_ComparisonRow>(
                              controller: _grid,
                              stickyHeader: false,
                              showAddRow: false,
                              showRowDelete: false,
                              showRemoveRowsAction: false,
                              columns: [
                                EditableGridColumn(
                                  key: 'sourceRow',
                                  label: '原件行',
                                  width: 95,
                                  cellBuilder: (_, r) =>
                                      Text(r.sourceRow.toString()),
                                ),
                                EditableGridColumn(
                                  key: 'target',
                                  listenableOf: (row) => row.changed,
                                  textOf: (row) => row.label ?? '明确选择，不按名称自动关联',
                                  label: '本系统真实计算行',
                                  width: 650,
                                  cellBuilder: (_, r) => UtenButton(
                                    key: ValueKey(
                                      'finance-material-match-${r.sourceRow}',
                                    ),
                                    type: UtenButtonType.secondary,
                                    onPressed: _busy ? null : () => _choose(r),
                                    child: Text(r.label ?? '明确选择，不按名称自动关联'),
                                  ),
                                ),
                                EditableGridColumn(
                                  key: 'clear',
                                  label: '清除对应',
                                  width: 120,
                                  cellBuilder: (_, r) => TextButton(
                                    onPressed: _busy
                                        ? null
                                        : () {
                                            setState(() {
                                              r.target = null;
                                              r.label = null;
                                              _result = null;
                                            });
                                            markFormDraftChanged();
                                          },
                                    child: const Text('清除'),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    )
                  : _tab == 3
                  ? financeSourceTable(
                      tableKey: 'finance.material.hidden-original-comparison',
                      columns: [
                        financeSourceColumn('sourceCell', '原坐标'),
                        financeSourceColumn('source', '原件缓存值', width: 250),
                        financeSourceColumn('actual', '同源实际值', width: 250),
                        financeSourceColumn('basis', '核对依据', width: 500),
                        financeSourceColumn('pending', '待核'),
                      ],
                      rows: [
                        for (final cell in _ml(_source?['supplementalCells']))
                          {
                            ...cell,
                            'source': cell['number'] ?? cell['text'],
                            ...() {
                              final actual =
                                  _ml(
                                    _targetMetadata['supplementalCells'],
                                  ).firstWhereOrNull(
                                    (v) =>
                                        v['sourceCell'] == cell['sourceCell'],
                                  );
                              return {
                                'actual': actual?['value'],
                                'pending':
                                    actual == null || actual['pending'] == true,
                                'basis': actual?['basis'] ?? '该原位置尚无完整真实来源',
                              };
                            }(),
                          },
                      ],
                      idOf: (r) => r['sourceCell'].toString(),
                      busy: _busy,
                    )
                  : financeSourceTable(
                      tableKey: 'finance.material.comparison-differences',
                      columns: [
                        financeSourceColumn('sourceRow', '原件行'),
                        financeSourceColumn('label', '列名'),
                        financeSourceColumn('source', '原件值', width: 230),
                        financeSourceColumn('actual', '同源计算值', width: 230),
                        financeSourceColumn('issues', '原件问题', width: 250),
                      ],
                      rows: [
                        for (final row in _ml(_result?['results']))
                          if (_ml(row['differences']).isEmpty)
                            {
                              'sourceRow': row['sourceRow'],
                              'label': '已选10列一致',
                              'issues': row['issues'],
                            }
                          else
                            for (final diff in _ml(row['differences']))
                              {
                                ...diff,
                                'sourceRow': row['sourceRow'],
                                'issues': row['issues'],
                              },
                      ],
                      idOf: (r) => '${r['sourceRow']}:${r['label']}',
                      busy: _busy,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ComparisonTargetPicker extends StatefulWidget {
  const _ComparisonTargetPicker({required this.rows});
  final List<Map<String, dynamic>> rows;
  @override
  State<_ComparisonTargetPicker> createState() =>
      _ComparisonTargetPickerState();
}

class _ComparisonTargetPickerState extends State<_ComparisonTargetPicker> {
  final _search = TextEditingController();
  String _term = '';
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Material(
    child: Column(
      children: [
        UtenDialogSurface(
          child: UtenDialogHeader(
            title: const Text('明确选择本系统真实计算行'),
            onClose: () => Navigator.of(context).pop(),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: UtenSearchBar(
            controller: _search,
            hint: '业务日期／原单号／产品名称',
            onChanged: (v) => setState(() => _term = v.toLowerCase()),
          ),
        ),
        Expanded(
          child: financeSourceTable(
            tableKey: 'finance.material.comparison-targets',
            columns: [
              financeSourceColumn('billDate', '日期', width: 180),
              financeSourceColumn('goodsName', '产品名称（57#）', width: 220),
              financeSourceColumn('spec', '规格'),
              financeSourceColumn('__billNo', '原单号', width: 220),
              financeSourceColumn('inWeight', '进仓重量(KG)', width: 200),
              financeSourceColumn('outWeight', '发出重量(KG)', width: 200),
              financeSourceColumn('processAmount', '加工货款', width: 200),
            ],
            rows: widget.rows
                .where(
                  (r) =>
                      _term.isEmpty ||
                      '${r['billDate']} ${r['goodsName']} ${r['spec']} ${r['__billNo']}'
                          .toLowerCase()
                          .contains(_term),
                )
                .toList(),
            idOf: (r) => r['__rowKey'].toString(),
            onOpen: (r) => Navigator.of(context).pop(r),
          ),
        ),
      ],
    ),
  );
}
