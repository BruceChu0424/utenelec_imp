part of 'finance_material_statement_dialog.dart';

Future<Map<String, dynamic>?> _materialReference(
  BuildContext context,
  String kind, {
  Map<String, dynamic>? scope,
}) => showDialog<Map<String, dynamic>>(
  context: context,
  barrierDismissible: false,
  builder: (_) => UtenDialogFrame(
    child: SizedBox(
      width: 1000,
      height: MediaQuery.sizeOf(context).height * .8,
      child: _MaterialReferencePicker(kind: kind, scope: scope),
    ),
  ),
);

class _MaterialReferencePicker extends ConsumerStatefulWidget {
  const _MaterialReferencePicker({required this.kind, this.scope});
  final String kind;
  final Map<String, dynamic>? scope;
  @override
  ConsumerState<_MaterialReferencePicker> createState() =>
      _MaterialReferencePickerState();
}

class _MaterialReferencePickerState
    extends ConsumerState<_MaterialReferencePicker>
    with ReadViewActivityMixin<_MaterialReferencePicker> {
  @override
  Future<void> onReadViewResumed() => _load();
  final _search = TextEditingController();
  List<Map<String, dynamic>> _rows = [];
  int _read = 0;
  bool _busy = true, _retired = false;
  String? _error;
  late final bool Function() _owner;
  bool get _current => mounted && !_retired && _owner();
  @override
  void initState() {
    super.initState();
    _owner = captureReadOwner(ref);
    listenReadOwner(ref, () {
      if (mounted) {
        setState(() {
          _retired = true;
          _rows = [];
        });
      }
    });
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// 完整结果与逐批前缀同一投影：解码后仅保留可选的已审核分组。
  List<Map<String, dynamic>> _referenceRows(Object? items) {
    final rows = _ml(items);
    if (widget.kind != 'contexts') return rows;
    return rows
        .where(
          (r) =>
              r['state'] == 'APPROVED' &&
              (widget.scope?['account_code'] == null ||
                  r['accountCode'] == widget.scope!['account_code']),
        )
        .toList();
  }

  Future<void> _load() async {
    if (!_current) return;
    final generation = ++_read;
    var partialRows = false;
    setState(() => _busy = true);
    try {
      final api = ref.read(apiClientProvider),
          scope = await api.captureRequestScope(
            isCurrent: () => _current && generation == _read,
          );
      final result = await readViewActivity.runRead(
        () => _current && generation == _read,
        () => scope.run(
          () => _readMaterialPages(
            current: () => _current && generation == _read && scope.isCurrent,
            fetch: (batch, size) => api.get(
              widget.kind == 'contexts'
                  ? _materialBase
                  : '$_materialBase/options/${widget.kind}',
              query: {
                ...?_scopeQuery(),
                'q': _search.text.trim(),
                'page': batch,
                'size': size,
              },
            ),
            onRows: (items) {
              if (!_current || !scope.isCurrent || generation != _read) return;
              setState(() {
                _rows = _referenceRows(items);
                partialRows = true;
              });
            },
          ),
        ),
      );
      if (!_current || !scope.isCurrent || generation != _read) return;
      setState(() {
        _rows = _referenceRows(result['items']);
        partialRows = false;
        _error = null;
      });
    } catch (e) {
      if (isRetiredViewRead(e)) return;
      if (_current && generation == _read) {
        setState(() {
          _error = _problem(e);
          if (partialRows || pagedReadAccessDenied(e)) _rows = [];
        });
      }
    } finally {
      if (_current && generation == _read) setState(() => _busy = false);
    }
  }

  Map<String, dynamic>? _scopeQuery() => widget.scope == null
      ? null
      : {
          'auxiliaryId': widget.scope!['auxiliary_id'],
          'accountingCurrencyId': widget.scope!['accounting_currency_id'],
        };
  @override
  Widget build(BuildContext context) => Material(
    child: Column(
      children: [
        UtenDialogSurface(
          child: UtenDialogHeader(
            title: const Text('选择真实编码和名称'),
            showCloseButton: true,
            onClose: () => Navigator.of(context).pop(),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: UtenSearchBar(
            controller: _search,
            hint: '编码／名称',
            onInputChanged: (_) {
              _read++;
            },
            onChanged: (_) => _load(),
            onSubmitted: (_) => _load(),
          ),
        ),
        Expanded(
          child: financeSourceTable(
            tableKey: 'finance.material.reference.${widget.kind}',
            rows: _current ? _rows : const [],
            idOf: (r) => (r['id'] ?? r['contextId']).toString(),
            columns: [
              // 2026-11-11 口径：编码列可排序 + 按值筛选（全量参考目录快照）。
              financeSourceColumn(
                widget.kind == 'contexts' ? 'accountCode' : 'code',
                '编码',
                width: 190,
                sortable: true,
                filterByValue: true,
              ),
              financeSourceColumn(
                widget.kind == 'contexts' ? 'productNameCaption' : 'name',
                '名称',
                width: 390,
              ),
            ],
            busy: _busy,
            error: _error,
            retry: () => _load(),
            onOpen: _current
                ? (row) {
                    if (_current && !_busy && _rows.contains(row)) {
                      Navigator.of(context).pop(row);
                    }
                  }
                : null,
          ),
        ),
      ],
    ),
  );
}

Future<Map<String, dynamic>?> _materialMovement(
  BuildContext context,
  String contextId,
  String from,
  String to, {
  bool finishedOnly = false,
}) => showDialog<Map<String, dynamic>>(
  context: context,
  barrierDismissible: false,
  builder: (_) => UtenDialogFrame(
    child: SizedBox(
      width: 1200,
      height: MediaQuery.sizeOf(context).height * .85,
      child: _MaterialMovementPicker(
        contextId: contextId,
        from: from,
        to: to,
        finishedOnly: finishedOnly,
      ),
    ),
  ),
);

class _MaterialMovementPicker extends ConsumerStatefulWidget {
  const _MaterialMovementPicker({
    required this.contextId,
    required this.from,
    required this.to,
    required this.finishedOnly,
  });
  final String contextId, from, to;
  final bool finishedOnly;
  @override
  ConsumerState<_MaterialMovementPicker> createState() =>
      _MaterialMovementPickerState();
}

class _MaterialMovementPickerState
    extends ConsumerState<_MaterialMovementPicker>
    with ReadViewActivityMixin<_MaterialMovementPicker> {
  @override
  Future<void> onReadViewResumed() => _load();
  final _from = TextEditingController(),
      _to = TextEditingController(),
      _search = TextEditingController();
  List<Map<String, dynamic>> _rules = [], _rows = [];
  Map<String, dynamic>? _rule;
  int _read = 0;
  bool _busy = true, _retired = false;
  String? _error;
  late final bool Function() _owner;
  bool get _current => mounted && !_retired && _owner();
  @override
  void initState() {
    super.initState();
    _owner = captureReadOwner(ref);
    listenReadOwner(ref, () {
      if (mounted) {
        setState(() {
          _retired = true;
          _rows = [];
        });
      }
    });
    _from.text = widget.from;
    _to.text = widget.to;
    _initial();
  }

  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _initial() async {
    try {
      final api = ref.read(apiClientProvider),
          scope = await api.captureRequestScope(isCurrent: () => _current);
      final value = await scope.run(
        () => api.get('$_materialBase/${widget.contextId}'),
      );
      if (!_current || !scope.isCurrent) return;
      setState(() {
        _rules = [
          for (final e in _ml(value['approved']))
            if (e['kind'] == 'GOODS' &&
                (!widget.finishedOnly ||
                    _effective(e)['flowRole'] == 'FINISHED_OUT'))
              {..._effective(e), 'evidenceId': e['id']},
        ];
        _rule = _rules.firstOrNull;
      });
      await _load();
    } catch (e) {
      if (_current) {
        setState(() {
          _busy = false;
          _error = _problem(e);
        });
      }
    }
  }

  /// 完整结果与逐批前缀同一投影：来源事实逐条展开为实物影响行。
  List<Map<String, dynamic>> _movementRows(Object? items) {
    final rows = <Map<String, dynamic>>[];
    for (final fact in _ml(items)) {
      for (final effect in _ml(fact['effects'])) {
        if (widget.finishedOnly && effect['reversal'] == true) continue;
        rows.add({
          ...effect,
          'billNo': fact['billNo'],
          'originalSummary': [
            _mm(fact['sourceSnapshot'])['document_remark'],
            _mm(fact['sourceSnapshot'])['item_remark'],
          ].whereType<String>().where((value) => value.isNotEmpty).join('；'),
          'goodsCode': fact['goodsCode'],
          'goodsName': fact['goodsName'],
          'source': fact['key'],
          'sourceIdentityFingerprint': fact['identityFingerprint'],
          'approved': fact['approved'],
          'identityComplete': fact['identityComplete'],
        });
      }
    }
    return rows;
  }

  Future<void> _load() async {
    if (!_current) return;
    if (_rule == null) {
      setState(() {
        _busy = false;
        _error = '请先维护并审核真实材料／产品对应；不按当前商品名猜来源。';
      });
      return;
    }
    final generation = ++_read;
    var partialRows = false;
    setState(() => _busy = true);
    try {
      final api = ref.read(apiClientProvider),
          scope = await api.captureRequestScope(
            isCurrent: () => _current && generation == _read,
          );
      final result = await readViewActivity.runRead(
        () => _current && generation == _read,
        () => scope.run(
          () => _readMaterialPages(
            current: () => _current && generation == _read && scope.isCurrent,
            identity: (row) => row['key'],
            fetch: (batch, size) => api.get(
              '$_materialBase/sources',
              query: {
                'contextId': widget.contextId,
                'kind': _rule!['sourceKind'],
                'sourceGoodsId': _rule!['goodsId'],
                'sourceColorId': _rule!['colorId'],
                'dateFrom': _from.text.trim(),
                'dateTo': _to.text.trim(),
                'q': _search.text.trim(),
                'page': batch,
                'size': size,
              },
            ),
            onRows: (items) {
              if (!_current || !scope.isCurrent || generation != _read) return;
              setState(() {
                _rows = _movementRows(items);
                partialRows = true;
              });
            },
          ),
        ),
      );
      if (!_current || !scope.isCurrent || generation != _read) return;
      final rows = _movementRows(result['items']);
      setState(() {
        _rows = rows;
        partialRows = false;
        _error = null;
      });
    } catch (e) {
      if (isRetiredViewRead(e)) return;
      if (_current && generation == _read) {
        setState(() {
          _error = _problem(e);
          if (partialRows || pagedReadAccessDenied(e)) _rows = [];
        });
      }
    } finally {
      if (_current && generation == _read) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Material(
    child: Column(
      children: [
        UtenDialogSurface(
          child: UtenDialogHeader(
            title: Text(widget.finishedOnly ? '选择真实成品其他出库' : '选择真实原单及物理切片'),
            showCloseButton: true,
            onClose: () => Navigator.of(context).pop(),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: UtenFormGrid(
            maxColumns: 3,
            children: [
              UtenInput(label: '业务日期起', controller: _from),
              UtenInput(label: '业务日期止', controller: _to),
              UtenDropdownField(
                label: '已核材料／产品对应',
                value: _rule?['evidenceId']?.toString(),
                items: [
                  for (final rule in _rules)
                    UtenDropdownItem(
                      value: rule['evidenceId'].toString(),
                      label:
                          '${_sourceKinds[rule['sourceKind']]} / ${rule['goodsId']}',
                    ),
                ],
                onChanged: (id) {
                  setState(
                    () => _rule = _rules
                        .where((r) => r['evidenceId'] == id)
                        .firstOrNull,
                  );
                  _load();
                },
              ),
              UtenSearchBar(
                controller: _search,
                hint: '原单号／原货品',
                onInputChanged: (_) {
                  _read++;
                },
                onChanged: (_) => _load(),
              ),
              UtenButton(
                onPressed: _busy ? null : () => _load(),
                child: const Text('读取实际来源'),
              ),
            ],
          ),
        ),
        Expanded(
          child: financeSourceTable(
            tableKey: 'finance.material.movement-picker',
            rows: _current ? _rows : const [],
            idOf: (r) => r['movementId'].toString(),
            columns: [
              // 2026-11-11 口径：单号/编码列可排序 + 按值筛选；日期/数量列可排序
              //（全量快照就地排序、收集桶）。
              financeSourceColumn(
                'billNo',
                '原单号',
                width: 190,
                sortable: true,
                filterByValue: true,
              ),
              financeSourceColumn(
                'originalSummary',
                '原摘要／备注（人工核对）',
                width: 340,
              ),
              financeSourceColumn('businessDate', '原表业务日期', sortable: true),
              financeSourceColumn(
                'confirmationDate',
                '实际确认／反向日',
                width: 190,
                sortable: true,
              ),
              financeSourceColumn(
                'goodsCode',
                '真实货品编码',
                sortable: true,
                filterByValue: true,
              ),
              financeSourceColumn('goodsName', '真实货品名称', width: 220),
              financeSourceColumn(
                'baseQuantity',
                '库存基本量',
                type: 'number',
                sortable: true,
              ),
              financeSourceColumn(
                'weightKg',
                '实称(KG)',
                type: 'number',
                sortable: true,
              ),
              financeSourceColumn(
                'estimatedWeightKg',
                '参考(KG)',
                type: 'number',
                sortable: true,
              ),
            ],
            busy: _busy,
            error: _error,
            retry: () => _load(),
            canOpen: (r) =>
                _current &&
                r['approved'] == true &&
                r['identityComplete'] == true,
            onOpen: _current
                ? (r) {
                    if (_current && !_busy && _rows.contains(r)) {
                      Navigator.of(context).pop(r);
                    }
                  }
                : null,
          ),
        ),
      ],
    ),
  );
}

Future<Map<String, dynamic>?> _materialGl(
  BuildContext context,
  String contextId,
  String from,
  String to,
) => showDialog<Map<String, dynamic>>(
  context: context,
  barrierDismissible: false,
  builder: (_) => UtenDialogFrame(
    child: SizedBox(
      width: 1150,
      height: MediaQuery.sizeOf(context).height * .8,
      child: _MaterialGlPicker(contextId: contextId, from: from, to: to),
    ),
  ),
);

class _MaterialGlPicker extends ConsumerStatefulWidget {
  const _MaterialGlPicker({
    required this.contextId,
    required this.from,
    required this.to,
    this.receivable,
    this.purpose = 'VAT',
  });
  final Map<String, dynamic>? receivable;
  final String purpose;
  final String contextId, from, to;
  @override
  ConsumerState<_MaterialGlPicker> createState() => _MaterialGlPickerState();
}

class _MaterialGlPickerState extends ConsumerState<_MaterialGlPicker>
    with ReadViewActivityMixin<_MaterialGlPicker> {
  @override
  Future<void> onReadViewResumed() => _load();
  final _from = TextEditingController(),
      _to = TextEditingController(),
      _search = TextEditingController();
  List<Map<String, dynamic>> _rows = [];
  int _read = 0;
  bool _busy = true, _retired = false;
  String? _error;
  late final bool Function() _owner;
  bool get _current => mounted && !_retired && _owner();
  @override
  void initState() {
    super.initState();
    _owner = captureReadOwner(ref);
    listenReadOwner(ref, () {
      if (mounted) {
        setState(() {
          _retired = true;
          _rows = [];
        });
      }
    });
    _from.text = widget.from;
    _to.text = widget.to;
    _load();
  }

  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!_current) return;
    final generation = ++_read;
    var partialRows = false;
    setState(() => _busy = true);
    try {
      final api = ref.read(apiClientProvider),
          scope = await api.captureRequestScope(
            isCurrent: () => _current && generation == _read,
          );
      final value = await readViewActivity.runRead(
        () => _current && generation == _read,
        () => scope.run(
          () => _readMaterialPages(
            current: () => _current && generation == _read && scope.isCurrent,
            identity: (row) =>
                row['entry_id'] == null || row['allocation_no'] == null
                ? null
                : (row['entry_id'], row['allocation_no']),
            fetch: (batch, size) => api.get(
              widget.receivable == null
                  ? '$_materialBase/gl-sources'
                  : '$_materialBase/adjustment-sources',
              query: {
                if (widget.receivable != null) ...{
                  'receivableEntry': widget.receivable!['entryId'],
                  'receivableAllocation': widget.receivable!['allocationNo'],
                  'purpose': widget.purpose,
                },
                'contextId': widget.contextId,
                'dateFrom': _from.text.trim(),
                'dateTo': _to.text.trim(),
                'q': _search.text.trim(),
                'page': batch,
                'size': size,
              },
            ),
            onRows: (items) {
              if (!_current || !scope.isCurrent || generation != _read) return;
              setState(() {
                _rows = _ml(items);
                partialRows = true;
              });
            },
          ),
        ),
      );
      if (!_current || !scope.isCurrent || generation != _read) return;
      setState(() {
        _rows = _ml(value['items']);
        partialRows = false;
        _error = null;
      });
    } catch (e) {
      if (isRetiredViewRead(e)) return;
      if (_current && generation == _read) {
        setState(() {
          _error = _problem(e);
          if (partialRows || pagedReadAccessDenied(e)) _rows = [];
        });
      }
    } finally {
      if (_current && generation == _read) setState(() => _busy = false);
    }
  }

  Future<void> _choose(Map<String, dynamic> row) async {
    if (_busy || !_current || !_rows.contains(row)) return;
    setState(() => _busy = true);
    try {
      final api = ref.read(apiClientProvider),
          scope = await api.captureRequestScope(isCurrent: () => _current);
      final value = await scope.run(
        () => api.get(
          '${widget.receivable == null ? '$_materialBase/gl-sources' : '$_materialBase/adjustment-sources'}/${row['entry_id']}/${row['allocation_no']}',
          query: {
            'contextId': widget.contextId,
            if (widget.receivable != null) ...{
              'receivableEntry': widget.receivable!['entryId'],
              'receivableAllocation': widget.receivable!['allocationNo'],
              'purpose': widget.purpose,
            },
          },
        ),
      );
      if (!mounted) return;
      if (_current && scope.isCurrent) Navigator.of(context).pop(value);
    } catch (e) {
      if (mounted && _current) {
        if (pagedReadAccessDenied(e)) {
          setState(() {
            _rows = [];
            _error = _problem(e);
          });
        }
        context.appApiError(e);
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Material(
    child: Column(
      children: [
        UtenDialogSurface(
          child: UtenDialogHeader(
            title: const Text('选择真实其他应收原分录'),
            showCloseButton: true,
            onClose: () => Navigator.of(context).pop(),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: UtenFormGrid(
            maxColumns: 3,
            children: [
              UtenInput(label: '财务日期起', controller: _from, enabled: !_busy),
              UtenInput(label: '财务日期止', controller: _to, enabled: !_busy),
              UtenSearchBar(
                controller: _search,
                hint: '原凭证号／摘要',
                onInputChanged: (_) {
                  _read++;
                },
                onChanged: (_) => _load(),
              ),
              UtenButton(
                onPressed: _busy ? null : () => _load(),
                child: const Text('读取原分录'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(UtenSpacing.s8),
          child: Text(
            widget.receivable == null
                ? '只选真实借方债权；普通回款贷方不列为加工款。'
                : '仅列同原应收凭证、明确性质的实际贷方；按真实原额分配，不从别张凭证猜对象。',
          ),
        ),
        Expanded(
          child: financeSourceTable(
            tableKey: 'finance.material.gl-picker',
            rows: _current ? _rows : const [],
            idOf: (r) => '${r['entry_id']}:${r['allocation_no']}',
            columns: [
              financeSourceColumn('voucher_no', '原凭证号', width: 190),
              financeSourceColumn('entry_date', '实际财务日期'),
              financeSourceColumn('summary', '原摘要', width: 270),
              financeSourceColumn('amount_local', '本币原额', type: 'money'),
              financeSourceColumn('amount_original', '真实原币原额', type: 'money'),
              financeSourceColumn('original_currency_id', '实际原币单位', width: 230),
            ],
            busy: _busy,
            error: _error,
            retry: () => _load(),
            onOpen: _busy ? null : _choose,
          ),
        ),
      ],
    ),
  );
}
