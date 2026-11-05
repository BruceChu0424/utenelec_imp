part of 'finance_material_statement_dialog.dart';

class _FeeRow extends EditableGridRow {
  _FeeRow({Map<String, dynamic>? input}) {
    data = _mm(input);
    adjustments.replaceAll([
      for (final row in _ml(data['adjustments']))
        _MaterialAdjustmentRow(row, source: false),
    ]);
    for (final key in [
      'amountLocal',
      'amountOriginal',
      'quotedProcessingPrice',
      'quotationReference',
    ]) {
      text[key] = TextEditingController(text: data[key]?.toString() ?? '');
    }
  }
  final adjustments = UtenEditableGridController<_MaterialAdjustmentRow>();
  String get localId => (data['_localId'] ??= const Uuid().v4()).toString();
  late Map<String, dynamic> data;
  final text = <String, TextEditingController>{};
  final changed = ValueNotifier<int>(0);
  Map<String, dynamic> capture() => {
    ...data,
    '_localId': localId,
    'adjustments': [for (final row in adjustments.rows) row.capture()],
    for (final e in text.entries) e.key: e.value.text,
  };
  @override
  void dispose() {
    for (final c in text.values) {
      c.dispose();
    }
    changed.dispose();
    adjustments.dispose();
    super.dispose();
  }
}

class _SourceRow extends EditableGridRow {
  _SourceRow(this.data);
  final Map<String, dynamic> data;
}

const _refs = <String, String>{
  'accountCode': 'accounts',
  'auxiliaryId': 'auxiliaries',
  'accountingCurrencyId': 'currencies',
  'originalCurrencyId': 'currencies',
  'goodsId': 'goods',
  'colorId': 'colors',
  'sourceGoodsId': 'goods',
  'sourceColorId': 'colors',
  'sourceUnitId': 'units',
  'sideQuantityUnitId': 'units',
  'materialContextId': 'contexts',
  'referenceCurrencyId': 'currencies',
};
const _labels = <String, String>{
  'accountCode': '财务科目代码',
  'auxiliaryId': '财务辅助项目',
  'accountingCurrencyId': '会计币别（属性）',
  'originalCurrencyId': '真实原币单位',
  'goodsId': '本组对应货品',
  'colorId': '本组颜色',
  'productNameCaption': '产品名称（57#）',
  'specificationCaption': '规格',
  'sortOrder': '原表顺序',
  'sideSlot': '原隐藏旁算位置（1至4，可留空待核）',
  'effectiveFrom': '有效起点（YYYY-MM-DD）',
  'sideQuantityUnitId': '旁算数量单位',
  'quantityUnitCaption': '原表单位文字',
  'sourceReference': '核对依据',
  'slot': '原隐藏位置（1至4）',
  'unitCaption': '原单位文字',
  'referencePrice': '本型号／有效期间参考报价',
  'referenceCurrencyId': '参考报价实际币别',
  'materialContextId': '明确引用的真实材料组（可留空仅参考）',
  'sourceGoodsId': '真实原料／产物货品',
  'sourceColorId': '真实颜色',
  'sourceUnitId': '原单单位',
  'sourceUnitRate': '匹配的原库存换算率',
  'kgPerSourceUnit': '每单位折合KG',
  'pcsPerSourceUnit': '每单位折合PCS',
  'balanceWeightKg': '期初结余(KG)',
  'actualWeightKg': '本切片实称重量(KG)',
  'actualQuantityPcs': '本切片实点数量(PCS)',
  'dateFrom': '范围开始日期',
  'dateTo': '范围结束日期',
  'nativePartyId': '对应来源单位',
  'quotationCurrencyId': '报价真实币别',
  'nonprocessingLocal': '明确非加工余项（本币）',
  'nonprocessingOriginal': '明确非加工余项（原币）',
};
const _fields = <String, List<String>>{
  'CONTEXT': [
    'accountCode',
    'auxiliaryId',
    'accountingCurrencyId',
    'goodsId',
    'colorId',
    'productNameCaption',
    'specificationCaption',
    'sortOrder',
    'sideSlot',
    'effectiveFrom',
    'amountBasis',
    'originalCurrencyId',
    'sideQuantityUnitId',
    'quantityUnitCaption',
    'sourceReference',
  ],
  'GOODS': [
    'sourceKind',
    'goodsId',
    'colorId',
    'flowRole',
    'productNameCaption',
    'specificationCaption',
    'enabled',
    'sourceReference',
  ],
  'NATIVE_PARTY': [
    'sourceKind',
    'nativeRole',
    'nativePartyId',
    'enabled',
    'sourceReference',
  ],
  'UNIT': [
    'sourceGoodsId',
    'sourceColorId',
    'sourceUnitId',
    'quantityBasis',
    'sourceUnitRate',
    'kgPerSourceUnit',
    'kgBasis',
    'pcsPerSourceUnit',
    'enabled',
    'sourceReference',
  ],
  'OPENING': ['effectiveFrom', 'balanceWeightKg', 'sourceReference'],
  'WEIGHT': [
    'source',
    'actualWeightKg',
    'actualQuantityPcs',
    'enabled',
    'sourceReference',
  ],
  'SOURCE_RELATION': ['source', 'enabled', 'sourceReference'],
  'ZERO': ['source', 'zeroProcessing', 'sourceReference'],
  'COVERAGE': [
    'sourceKind',
    'dateFrom',
    'dateTo',
    'completeReviewed',
    'enabled',
    'sourceReference',
  ],
  'FEE': [
    'feeSource',
    'nonprocessingLocal',
    'nonprocessingOriginal',
    'sourceReference',
  ],
  'SIDEBAR': [
    'slot',
    'dateFrom',
    'dateTo',
    'productNameCaption',
    'unitCaption',
    'referencePrice',
    'referenceCurrencyId',
    'materialContextId',
    'enabled',
    'sourceReference',
  ],
  'CLOSE': ['sourceReference'],
};

class _MaterialEditor extends ConsumerStatefulWidget {
  const _MaterialEditor({
    this.initialContextId,
    this.initialEvidenceId,
    required this.kind,
    required this.mode,
    this.resumeDraftId,
    this.seed,
    this.dateFrom,
    this.dateTo,
  });
  final String? initialContextId,
      initialEvidenceId,
      resumeDraftId,
      dateFrom,
      dateTo;
  final String kind, mode;
  final Map<String, dynamic>? seed;
  @override
  ConsumerState<_MaterialEditor> createState() => _MaterialEditorState();
}

class _MaterialEditorState extends ConsumerState<_MaterialEditor>
    with FormDraftMixin<_MaterialEditor> {
  final _form = GlobalKey<FormState>();
  final _text = <String, TextEditingController>{};
  final _fees = UtenEditableGridController<_FeeRow>(),
      _range = UtenEditableGridController<_SourceRow>();
  final _creditSources = UtenEditableGridController<_MaterialAdjustmentRow>();
  _FeeRow? _editingAdjustment;
  final _gridPages = <String, int>{};
  Map<String, dynamic> _data = {}, _referenceLabels = {};
  Map<String, dynamic>? _context, _evidence, _pending, _feeSource;
  late String _kind, _mode;
  String? _contextId, _evidenceId, _baseApprovedId, _error;
  bool _loading = true, _busy = false;
  int _read = 0;
  bool get _action =>
      const {'submit', 'approve', 'reject', 'withdraw'}.contains(_mode);
  bool get _view => _mode == 'VIEW';
  bool get _canEdit =>
      ref.read(authenticatedScopeProvider)?.readOnly == false &&
      ref.read(currentPermissionsProvider).contains(Perm.paymentStyleEdit);
  bool get _editable =>
      !_view && !_action && !_loading && !_busy && _pending == null && _canEdit;
  bool get _canAction =>
      ref.read(authenticatedScopeProvider)?.readOnly == false &&
      ref
          .read(currentPermissionsProvider)
          .contains(
            const {'approve', 'reject'}.contains(_mode)
                ? Perm.financePostExecute
                : Perm.paymentStyleEdit,
          );
  @override
  FormDraftSpec get formDraftSpec => FormDraftCatalog.financeMaterialStatement
      .spec(title: '${FinanceRequirementNames.otherReceivableStatement}资料');
  @override
  bool get formDraftUsesRouterGuard => false;
  @override
  bool get formDraftUseCurrentRoute => false;
  @override
  bool get formDraftEnabled => !_view || widget.resumeDraftId != null;
  @override
  String? get formDraftResumeId => widget.resumeDraftId;
  @override
  bool get formDraftBusy => _busy;
  @override
  bool get formDraftCanReplaySubmission => _pending != null;
  @override
  Iterable<Listenable> get formDraftListenables => [
    _fees,
    _range,
    _creditSources,
    for (final row in _creditSources.rows) ...row.text.values,
    for (final fee in _fees.rows) fee.adjustments,
    for (final fee in _fees.rows)
      for (final row in fee.adjustments.rows) ...row.text.values,
    ..._text.values,
    for (final row in _fees.rows) ...row.text.values,
  ];
  Map<String, dynamic> _captureInput() => {
    ..._data,
    for (final e in _text.entries) e.key: e.value.text,
  };
  @override
  Map<String, dynamic> captureFormDraft() => {
    'mode': _mode,
    'kind': _kind,
    'contextId': _contextId,
    'evidenceId': _evidenceId,
    'baseApprovedId': _baseApprovedId,
    'input': _captureInput(),
    'labels': _referenceLabels,
    'feeParts': [for (final row in _fees.rows) row.capture()],
    'rangeRows': [for (final row in _range.rows) row.data],
    'feeSource': _feeSource,
    'gridPages': _gridPages,
    'editingAdjustment': _editingAdjustment == null
        ? null
        : _fees.rows.indexOf(_editingAdjustment!),
    'creditSources': [for (final row in _creditSources.rows) row.capture()],
    'pending': _pending,
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> saved) async {
    final kind = saved['kind']?.toString(), mode = saved['mode']?.toString();
    if (!_materialKinds.containsKey(kind) ||
        !const {
          'EDIT',
          'NEW',
          'VIEW',
          'submit',
          'approve',
          'reject',
          'withdraw',
        }.contains(mode)) {
      throw StateError('原资料草稿的类型或动作无效');
    }
    if (widget.initialContextId != null &&
        saved['contextId'] != null &&
        widget.initialContextId != saved['contextId']) {
      throw StateError('原草稿所属分组不一致，不能移到当前分组');
    }
    _kind = kind!;
    _mode = mode!;
    _contextId = saved['contextId']?.toString();
    _evidenceId = saved['evidenceId']?.toString();
    _baseApprovedId = saved['baseApprovedId']?.toString();
    _gridPages.addAll(
      _mm(saved['gridPages']).map((key, value) => MapEntry(key, _mi(value))),
    );
    _putInput(_mm(saved['input']));
    _referenceLabels = _mm(saved['labels']);
    _feeSource = saved['feeSource'] is Map ? _mm(saved['feeSource']) : null;
    _creditSources.replaceAll([
      for (final row in _ml(saved['creditSources']))
        _MaterialAdjustmentRow(row, source: true),
    ]);
    _fees.replaceAll([
      for (final row in _ml(saved['feeParts'])) _FeeRow(input: row),
    ]);
    final selected = saved['editingAdjustment'];
    if (selected != null) {
      final at = _mi(selected);
      if (at < 0 || at >= _fees.length) {
        throw StateError('原附加款编辑行已不在原完整清单，输入仍保留');
      }
      _editingAdjustment = _fees[at];
    }
    _range.replaceAll([
      for (final row in _ml(saved['rangeRows'])) _SourceRow(row),
    ]);
    _pending = saved['pending'] is Map ? _mm(saved['pending']) : null;
    if (_pending != null &&
        (_pending!['actorId'] != ref.read(authenticatedScopeProvider)?.userId ||
            _mm(_pending!['body'])['requestId'] == null)) {
      throw StateError('原请求身份不一致，不能重放');
    }
    try {
      await _readServer(hydrate: false);
    } catch (e) {
      _error = '原输入及请求仍保留，当前资料暂未恢复：${_problem(e)}';
    }
  }

  @override
  void initState() {
    super.initState();
    _kind = widget.kind;
    _mode = widget.mode;
    _contextId = _mode == 'NEW' ? null : widget.initialContextId;
    _evidenceId = widget.initialEvidenceId;
    for (final key in _labels.keys) {
      _text[key] = TextEditingController();
    }
    _text['reason'] = TextEditingController();
    _data = {
      'amountBasis': 'LOCAL',
      'unitCaption': 'PCS',
      'enabled': true,
      'completeReviewed': false,
      'colorId': null,
      'sourceColorId': null,
    };
    _text['effectiveFrom']!.text = widget.dateFrom ?? '';
    _text['dateFrom']!.text = widget.dateFrom ?? '';
    _text['dateTo']!.text = widget.dateTo ?? '';
    if (widget.seed != null) {
      _putInput(widget.seed!);
      if (widget.seed!['_feePart'] is Map) {
        final source = _mm(widget.seed!['_feePart']);
        _fees.addRow(
          _FeeRow(
            input: {
              'contextId': _contextId,
              'outboundSource': source['source'],
              'outboundMovementId': source['movementId'],
              '_sourceLabel': source['_sourceLabel'],
            },
          ),
        );
      }
    }
    _fees.addListener(_retireDeletedPart);
    startFormDraftIdentityGuard();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initial());
  }

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    _fees.removeListener(_retireDeletedPart);
    _fees.dispose();
    _range.dispose();
    _creditSources.dispose();
    super.dispose();
  }

  void _retireDeletedPart() {
    if (_editingAdjustment != null &&
        !_fees.rows.contains(_editingAdjustment) &&
        mounted) {
      setState(() => _editingAdjustment = null);
    }
  }

  void _rememberGridPage(String key, int page) {
    _gridPages[key] = page;
    markFormDraftChanged();
  }

  void _putInput(Map<String, dynamic> input) {
    _data = {...input};
    if (const {
          'GOODS',
          'NATIVE_PARTY',
          'UNIT',
          'WEIGHT',
          'SOURCE_RELATION',
          'COVERAGE',
          'SIDEBAR',
        }.contains(_kind) &&
        !_data.containsKey('enabled')) {
      _data['enabled'] = true;
    }
    for (final e in _text.entries) {
      if (input.containsKey(e.key)) {
        e.value.text = input[e.key]?.toString() ?? '';
      }
    }
  }

  Future<void> _initial() async {
    try {
      if (widget.resumeDraftId == null) await _readServer(hydrate: true);
    } catch (e) {
      if (mounted && formDraftIdentityIsCurrent) _error = _problem(e);
    } finally {
      if (mounted && formDraftIdentityIsCurrent) {
        if (formDraftEnabled) await initializeFormDraft();
        if (mounted) setState(() => _loading = false);
      }
    }
  }

  Future<void> _readServer({required bool hydrate}) async {
    final generation = ++_read,
        scope = await captureFormDraftRequestScope(),
        api = ref.read(apiClientProvider);
    Map<String, dynamic>? evidence;
    if (_evidenceId != null) {
      evidence = await scope.run(
        () => api.get('$_materialBase/evidence/$_evidenceId'),
      );
    }
    final contextId = _contextId ?? evidence?['context_id']?.toString();
    final context = contextId == null
        ? null
        : await scope.run(() => api.get('$_materialBase/$contextId'));
    if (!mounted ||
        !formDraftIdentityIsCurrent ||
        !scope.isCurrent ||
        generation != _read) {
      return;
    }
    _contextId = contextId;
    _context = context;
    _evidence = evidence;
    if (hydrate) {
      if (evidence == null && _kind == 'CONTEXT' && context != null) {
        evidence = _ml(
          context['approved'],
        ).where((r) => r['kind'] == 'CONTEXT').firstOrNull;
        _evidence = evidence;
      }
      if (evidence != null) {
        _kind = evidence['kind'].toString();
        _putInput(_mm(evidence['input']));
        if (_kind == 'FEE') {
          _creditSources.replaceAll([
            for (final row in _ml(_data['adjustmentSources']))
              _MaterialAdjustmentRow(row, source: true),
          ]);
          _fees.replaceAll([
            for (final row in _ml(_data['processingParts']))
              _FeeRow(input: row),
          ]);
        }
        if (_kind == 'COVERAGE') {
          _range.replaceAll([
            for (final key in _ml(_data['completeSources']))
              _SourceRow({
                'source': key,
                '_sourceLabel':
                    '${_sourceKinds[key['kind']]} / ${key['lineId']}',
              }),
          ]);
        }
        if (!const {'DRAFT'}.contains(evidence['status']) &&
            !_action &&
            !_view) {
          _baseApprovedId = evidence['current_approved'] == true
              ? evidence['id']?.toString()
              : null;
          _evidenceId = null;
        }
      }
    }
    final requests = <String, Set<String>>{};
    void collect(String kind, Object? value) {
      if (value != null && value.toString().isNotEmpty) {
        (requests[kind] ??= {}).add(value.toString());
      }
    }

    for (final field in _refs.entries) {
      collect(field.value, _data[field.key]);
    }
    if (_data['nativePartyId'] != null) {
      collect(
        _data['nativeRole'] == 'CUSTOMER' ? 'clients' : 'suppliers',
        _data['nativePartyId'],
      );
    }
    for (final row in _fees.rows) {
      collect('contexts', row.data['contextId']);
      collect('currencies', row.data['quotationCurrencyId']);
    }
    final labels = requests.isEmpty
        ? <String, dynamic>{}
        : await scope.run(
            () => api.post(
              '$_materialBase/reference-labels',
              body: {for (final e in requests.entries) e.key: e.value.toList()},
            ),
          );
    if (!mounted ||
        !formDraftIdentityIsCurrent ||
        !scope.isCurrent ||
        generation != _read) {
      return;
    }
    for (final field in _refs.entries) {
      final label = _mm(labels[field.value])[_data[field.key]?.toString()];
      if (label != null) _referenceLabels[field.key] = label.toString();
    }
    if (_data['nativePartyId'] != null) {
      final label = _mm(
        labels[_data['nativeRole'] == 'CUSTOMER' ? 'clients' : 'suppliers'],
      )[_data['nativePartyId'].toString()];
      if (label != null) _referenceLabels['nativePartyId'] = label.toString();
    }
    for (final row in _fees.rows) {
      row.data['_contextIdLabel'] = _mm(
        labels['contexts'],
      )[row.data['contextId']?.toString()];
      row.data['_quotationCurrencyIdLabel'] = _mm(
        labels['currencies'],
      )[row.data['quotationCurrencyId']?.toString()];
    }
    if (_kind == 'FEE' && _data['source'] is Map && _contextId != null) {
      final key = _mm(_data['source']);
      _feeSource = await scope.run(
        () => api.get(
          '$_materialBase/gl-sources/${key['entryId']}/${key['allocationNo']}',
          query: {'contextId': _contextId},
        ),
      );
      if (!mounted ||
          !formDraftIdentityIsCurrent ||
          !scope.isCurrent ||
          generation != _read) {
        return;
      }
    }
    if (mounted) setState(() => _error = null);
  }

  void _changed() {
    markFormDraftChanged();
    if (mounted) setState(() {});
  }

  Future<void> _pickReference(String field, String kind, {_FeeRow? row}) async {
    if (!_editable) return;
    final scope = await captureFormDraftRequestScope();
    if (!mounted || !scope.isCurrent) return;
    final choice = await _materialReference(
      context,
      kind,
      scope: kind == 'contexts' ? _context : null,
    );
    if (choice == null ||
        !mounted ||
        !formDraftIdentityIsCurrent ||
        !scope.isCurrent) {
      return;
    }
    final id = (choice['id'] ?? choice['contextId']).toString(),
        label =
            '${choice['code'] ?? choice['accountCode'] ?? ''} ${choice['name'] ?? choice['productNameCaption'] ?? choice['goodsName'] ?? ''}'
                .trim();
    if (row == null) {
      _data[field] = id;
      _referenceLabels[field] = label;
    } else {
      row.data[field] = id;
      row.data['_${field}Label'] = label;
      row.changed.value++;
    }
    _changed();
  }

  Future<void> _pickMovement({_FeeRow? fee, bool addRange = false}) async {
    if (!_editable || _contextId == null) return;
    final scope = await captureFormDraftRequestScope();
    if (!mounted || !scope.isCurrent) return;
    final choice = await _materialMovement(
      context,
      (fee?.data['contextId'] ?? _contextId).toString(),
      _text['dateFrom']!.text.isEmpty
          ? widget.dateFrom ?? ''
          : _text['dateFrom']!.text,
      _text['dateTo']!.text.isEmpty
          ? widget.dateTo ?? ''
          : _text['dateTo']!.text,
      finishedOnly: fee != null,
    );
    if (choice == null ||
        !mounted ||
        !scope.isCurrent ||
        !formDraftIdentityIsCurrent) {
      return;
    }
    final source = _mm(choice['source']),
        label =
            '${choice['billNo']} ${choice['goodsCode']} ${choice['businessDate']}';
    if (addRange) {
      if (_range.rows.any(
        (r) => jsonEncode(r.data['source']) == jsonEncode(source),
      )) {
        context.appWarning('该原单行已在完整清单中');
        return;
      }
      _range.addRow(_SourceRow({'source': source, '_sourceLabel': label}));
    } else if (fee != null) {
      fee.data.addAll({
        'outboundSource': source,
        'outboundMovementId': choice['movementId'],
        '_sourceLabel': label,
      });
      fee.changed.value++;
    } else {
      _data.addAll({
        'source': source,
        'movementId': choice['movementId'],
        'expectedIdentityFingerprint': choice['sourceIdentityFingerprint'],
        'expectedEffectFingerprint': choice['identityFingerprint'],
        '_sourceLabel': label,
      });
    }
    _changed();
  }

  Future<void> _pickGl() async {
    if (!_editable || _contextId == null) return;
    final scope = await captureFormDraftRequestScope();
    if (!mounted || !scope.isCurrent) return;
    final chosen = await _materialGl(
      context,
      _contextId!,
      _text['dateFrom']!.text,
      _text['dateTo']!.text,
    );
    if (chosen == null ||
        !mounted ||
        !scope.isCurrent ||
        !formDraftIdentityIsCurrent) {
      return;
    }
    setState(() {
      _feeSource = chosen;
      _data['source'] = {
        'entryId': chosen['entry_id'],
        'allocationNo': chosen['allocation_no'],
      };
      _data['expectedSourceFingerprint'] = chosen['identityFingerprint'];
      _baseApprovedId = chosen['approvedAssignmentId']?.toString();
    });
    _changed();
  }

  Map<String, dynamic> _input() {
    final ctx = _contextId;
    final all = _captureInput();
    final result = <String, dynamic>{};
    for (final field in _fields[_kind] ?? const <String>[]) {
      if (const {
        'feeSource',
        'source',
        'enabled',
        'completeReviewed',
      }.contains(field)) {
        continue;
      }
      var value = all[field];
      if (value is String) {
        value = value.trim();
        if (value.isEmpty) value = null;
      }
      result[field] = value;
    }
    result['contextId'] = ctx;
    if (_kind == 'SIDEBAR') {
      result['slot'] = int.tryParse(_text['slot']!.text.trim());
    }
    if (const {
      'NATIVE_PARTY',
      'UNIT',
      'OPENING',
      'WEIGHT',
      'FEE',
    }.contains(_kind)) {
      result['requestId'] = null;
      result['expectedVersion'] = _mi(_context?['row_version']);
    }
    if (const {
      'GOODS',
      'NATIVE_PARTY',
      'UNIT',
      'WEIGHT',
      'SOURCE_RELATION',
      'COVERAGE',
      'SIDEBAR',
    }.contains(_kind)) {
      result['enabled'] = _data['enabled'] == true;
    }
    if (_kind == 'WEIGHT' || _kind == 'SOURCE_RELATION' || _kind == 'ZERO') {
      result['source'] = _data['source'];
      result['expectedIdentityFingerprint'] =
          _data['expectedIdentityFingerprint'];
    }
    if (_kind == 'ZERO') {
      result['zeroProcessing'] = _data['zeroProcessing'] == true;
    }
    if (_kind == 'WEIGHT' || _kind == 'ZERO') {
      result.addAll({
        'movementId': _data['movementId'],
        'expectedEffectFingerprint': _data['expectedEffectFingerprint'],
      });
    }
    if (_kind == 'COVERAGE') {
      result.addAll({
        'completeReviewed': _data['completeReviewed'] == true,
        'completeSources': [for (final row in _range.rows) row.data['source']],
      });
    }
    if (_kind == 'FEE') {
      result['source'] = _data['source'];
      result['adjustmentSources'] = [
        for (final source in _creditSources.rows) source.input(),
      ];
      result['expectedSourceFingerprint'] = _data['expectedSourceFingerprint'];
      result['processingParts'] = [
        for (final row in _fees.rows)
          {
            'contextId': row.data['contextId'],
            'outboundSource': row.data['outboundSource'],
            'outboundMovementId': row.data['outboundMovementId'],
            'amountLocal': row.text['amountLocal']!.text.trim(),
            'amountOriginal':
                _feeSource != null && _feeSource!['amount_original'] == null
                ? null
                : row.text['amountOriginal']!.text.trim(),
            'quotedProcessingPrice':
                row.text['quotedProcessingPrice']!.text.trim().isEmpty
                ? null
                : row.text['quotedProcessingPrice']!.text.trim(),
            'quotationCurrencyId': row.data['quotationCurrencyId'],
            'quotationReference': row.text['quotationReference']!.text.trim(),
            'quotationTaxBasis': row.data['quotationTaxBasis'],
            'adjustmentReviewed': row.data['adjustmentReviewed'] == true,
            'adjustments': [
              for (final extra in row.adjustments.rows) extra.input(),
            ],
          },
      ];
      if (_feeSource != null && _feeSource!['amount_original'] == null) {
        result['nonprocessingOriginal'] = null;
      }
    }
    return result;
  }

  Map<String, dynamic> _command() {
    final request = const Uuid().v4();
    if (_action) {
      if (_evidenceId == null || _evidence == null || _context == null) {
        throw StateError('请先读取实际草稿及分组版本');
      }
      return {
        'path': '$_materialBase/evidence/$_evidenceId/$_mode',
        'body': {
          'requestId': request,
          'expectedVersion': _mi(
            _evidence!['version'] ?? _evidence!['row_version'],
          ),
          'expectedContextVersion': _mi(_context!['row_version']),
          'reason': _text['reason']!.text.trim(),
        },
      };
    }
    if (_kind == 'CONTEXT') {
      final body = _input()..remove('contextId');
      body.addAll({
        'requestId': request,
        'id': _contextId,
        'expectedVersion': _contextId == null
            ? -1
            : _mi(_context?['row_version']),
        'draftId': _evidence?['status'] == 'DRAFT' ? _evidenceId : null,
        'expectedDraftVersion': _evidence?['status'] == 'DRAFT'
            ? _mi(_evidence?['version'] ?? _evidence?['row_version'])
            : null,
        'requiredSourceKinds':
            (_data['requiredSourceKinds'] as List? ?? const []),
        'sortOrder': int.tryParse(_text['sortOrder']!.text.trim()),
        'sideSlot': int.tryParse(_text['sideSlot']!.text.trim()),
      });
      return {'path': '$_materialBase/contexts', 'body': body};
    }
    if (ctxMissing) throw StateError('请先新增并读取实际材料分组');
    return {
      'path': '$_materialBase/drafts',
      'body': {
        'requestId': request,
        'id': _evidenceId,
        'expectedVersion': _evidenceId == null
            ? -1
            : _mi(_evidence?['version'] ?? _evidence?['row_version']),
        'contextId': _contextId,
        'expectedContextVersion': _mi(_context?['row_version']),
        'expectedApprovedId': _baseApprovedId,
        'kind': _kind,
        'input': _input(),
      },
    };
  }

  bool get ctxMissing => _contextId == null || _context == null;
  Future<void> _send() async {
    if (_busy ||
        _loading ||
        !formDraftIdentityIsCurrent ||
        (_action ? !_canAction : !_canEdit)) {
      return;
    }
    if (_pending == null && !(_form.currentState?.validate() ?? false)) return;
    final wasUnknown = formDraftHasUnknownSubmission;
    setState(() => _busy = true);
    try {
      final scope = await captureFormDraftRequestScope();
      if (!mounted || !scope.isCurrent) return;
      _pending ??= {
        ..._command(),
        'actorId': ref.read(authenticatedScopeProvider)?.userId,
      };
      final command = _mm(jsonDecode(jsonEncode(_pending)));
      await runFormDraftSubmission(
        () => scope.run(
          () => ref
              .read(apiClientProvider)
              .post(command['path'].toString(), body: command['body']),
        ),
        isDefiniteRejection: (e) =>
            !wasUnknown &&
            (e.details?['notWritten'] == true ||
                e.hasResponseCode &&
                    const {
                      'VALIDATION_FAILED',
                      'CONFLICT',
                      'FORBIDDEN',
                      'NOT_FOUND',
                    }.contains(e.code)),
      );
      if (!mounted || !scope.isCurrent || !formDraftIdentityIsCurrent) return;
      await completeFormDraft();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!formDraftHasUnknownSubmission) _pending = null;
      if (mounted && formDraftIdentityIsCurrent) {
        context.appApiError(e, fallback: '原输入和请求已保留，请核对结果');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _receipt() async {
    if (_busy || _pending == null) return;
    setState(() => _busy = true);
    try {
      final scope = await captureFormDraftRequestScope();
      final id = _mm(_pending!['body'])['requestId'];
      final receipt = await scope.run(
        () => ref
            .read(apiClientProvider)
            .post(
              '$_materialBase/operations/$id/verify',
              body: {'path': _pending!['path'], 'body': _pending!['body']},
            ),
      );
      if (!mounted || !scope.isCurrent || !formDraftIdentityIsCurrent) return;
      await _acceptVerifiedReceipt(receipt);
    } catch (e) {
      if (mounted && formDraftIdentityIsCurrent) {
        context.appApiError(e, fallback: '尚未取得原请求成功回执，不改原参数');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _acceptVerifiedReceipt(Map<String, dynamic> receipt) async {
    if (receipt['receiptState'] != 'CANCELLED_NOT_WRITTEN') {
      await completeFormDraft();
      if (mounted) Navigator.of(context).pop(true);
      return;
    }
    if (receipt['requestId']?.toString() !=
            _mm(_pending?['body'])['requestId']?.toString() ||
        receipt['actorId']?.toString() !=
            ref.read(authenticatedScopeProvider)?.userId) {
      throw StateError('终止回执不属于本次原请求，原参数仍冻结');
    }
    try {
      await runFormDraftSubmission<void>(
        () async {
          throw ApiException(
            'CONFLICT',
            '原请求已明确终止且未写入，原输入保留。',
            hasResponseCode: true,
            httpStatus: 409,
            details: const {'materialCancelledNotWritten': true},
          );
        },
        isDefiniteRejection: (error) =>
            error.details?['materialCancelledNotWritten'] == true,
      );
    } on ApiException catch (error) {
      if (error.details?['materialCancelledNotWritten'] != true) rethrow;
    }
    _pending = null;
    await saveFormDraftNow();
    await _readServer(hydrate: false);
    if (mounted) setState(() => _error = '原请求已终止且未写入；输入仍保留，可核对最新版本后重新保存。');
  }

  Future<void> _cancelUnwritten() async {
    if (_busy || _pending == null) return;
    setState(() => _busy = true);
    try {
      final scope = await captureFormDraftRequestScope(),
          id = _mm(_pending!['body'])['requestId'];
      final receipt = await scope.run(
        () => ref
            .read(apiClientProvider)
            .post(
              '$_materialBase/operations/$id/cancel-unwritten',
              body: {'path': _pending!['path'], 'body': _pending!['body']},
            ),
      );
      if (!mounted || !formDraftIdentityIsCurrent || !scope.isCurrent) return;
      await _acceptVerifiedReceipt(receipt);
    } catch (error) {
      if (mounted && formDraftIdentityIsCurrent) {
        context.appApiError(error, fallback: '尚未取得原请求明确结果，参数仍冻结');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget? get formDraftSubmissionRecoveryAction => UtenResponsiveActionWrap(
    children: [
      UtenButton(
        type: UtenButtonType.secondary,
        onPressed: _busy ? null : _receipt,
        child: const Text('核对原请求结果'),
      ),
      UtenButton(onPressed: _busy ? null : _send, child: const Text('按原请求重试')),
      UtenButton(
        type: UtenButtonType.secondary,
        onPressed: _busy ? null : _cancelUnwritten,
        child: const Text('终止尚未写入的原请求'),
      ),
    ],
  );
  Future<void> _close() async {
    if (!_busy && (!_view ? await confirmFormDraftExit() : true) && mounted) {
      Navigator.of(context).pop(false);
    }
  }

  Widget _reference(String field, String kind, {_FeeRow? row}) {
    final id = row == null ? _data[field] : row.data[field];
    final label = row == null
        ? _referenceLabels[field]
        : row.data['_${field}Label'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_labels[field] ?? field),
        const SizedBox(height: UtenSpacing.s4),
        UtenButton(
          type: UtenButtonType.secondary,
          onPressed: _editable
              ? () => _pickReference(field, kind, row: row)
              : null,
          child: Text(label?.toString() ?? id?.toString() ?? '选择编码和名称'),
        ),
        if (const {'colorId', 'sourceColorId'}.contains(field))
          TextButton(
            onPressed: _editable
                ? () {
                    _data[field] = null;
                    _referenceLabels[field] = '无颜色（不含其他颜色）';
                    _changed();
                  }
                : null,
            child: Text(id == null ? '无颜色（不含其他颜色）' : '明确无颜色'),
          ),
      ],
    );
  }

  Widget _field(String key) {
    if (_refs.containsKey(key)) return _reference(key, _refs[key]!);
    final choices = switch (key) {
      'sourceKind' => _sourceKinds,
      'flowRole' => _flowRoles,
      'amountBasis' => const {'LOCAL': '本位币金额', 'ORIGINAL': '实际原币金额'},
      'nativeRole' => const {'SUPPLIER': '供应商', 'CUSTOMER': '客户'},
      'quantityBasis' => const {'BASE': '按原库存基本量', 'SOURCE': '按原单单位量（匹配原换算率）'},
      'kgBasis' => const {
        'EXACT_UNIT': '已核重量单位定义',
        'ESTIMATE': '估计单重（只参考，不当实称）',
      },
      _ => const <String, String>{},
    };
    if (choices.isNotEmpty) {
      return UtenDropdownField(
        label: switch (key) {
          'sourceKind' => '实际来源',
          'flowRole' => '对应物量',
          'amountBasis' => '金额口径',
          'nativeRole' => '原单位类别',
          'quantityBasis' => '数量依据',
          'kgBasis' => 'KG依据',
          _ => key,
        },
        value: _data[key]?.toString(),
        enabled: _editable,
        items: [
          for (final c in choices.entries)
            UtenDropdownItem(value: c.key, label: c.value),
        ],
        onChanged: (v) {
          _data[key] = v;
          _changed();
        },
      );
    }
    if (key == 'enabled' ||
        key == 'completeReviewed' ||
        key == 'zeroProcessing') {
      return CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        value: _data[key] == true,
        title: Text(
          key == 'enabled'
              ? '启用这条真实对应关系'
              : key == 'zeroProcessing'
              ? '明确本实际成品切片免加工款；取消勾选并复核可恢复认领真实GL'
              : '已核对本段实际来源完整；确为空清单也须明确确认',
        ),
        onChanged: _editable
            ? (v) {
                _data[key] = v == true;
                _changed();
              }
            : null,
      );
    }
    if (key == 'nativePartyId') {
      return _reference(
        key,
        _data['nativeRole'] == 'CUSTOMER' ? 'clients' : 'suppliers',
      );
    }
    if (key == 'source') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('真实来源行／实际切片'),
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: _editable ? () => _pickMovement() : null,
            child: Text(
              _data['_sourceLabel']?.toString() ??
                  _mm(_data['source'])['lineId']?.toString() ??
                  '选择实际出入库',
            ),
          ),
        ],
      );
    }
    if (key == 'feeSource') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          UtenButton(
            onPressed: _editable ? _pickGl : null,
            child: const Text('选择真实其他应收原分录'),
          ),
          if (_feeSource != null)
            Text(
              '${_feeSource!['voucher_no']}；本币原额：${_feeSource!['amount_local']}；原币原额：${_feeSource!['amount_original'] ?? '缺证据，不能填0'}',
            ),
        ],
      );
    }
    final controller = _text.putIfAbsent(key, () => TextEditingController());
    return UtenInput(
      key: ValueKey('material-$key'),
      label: _labels[key] ?? key,
      controller: controller,
      maxLines: key == 'sourceReference' ? 3 : 1,
      enabled:
          _editable &&
          !(key == 'nonprocessingOriginal' &&
              _feeSource != null &&
              _feeSource!['amount_original'] == null),
      validator: (v) {
        if (key == 'sourceReference' && (v?.trim().isEmpty ?? true)) {
          return '请填写实际凭证、称重或核对依据';
        }
        return null;
      },
    );
  }

  Widget _feeGrid() => FinanceEditableGridWindow<_FeeRow>(
    initialPage: _gridPages['processing'] ?? 1,
    onPageChanged: (page) => _rememberGridPage('processing', page),
    controller: _fees,
    tableKey: 'finance.material.processing-parts',
    showAddRow: _editable,
    createBlankRow: () => _FeeRow(input: {'contextId': _contextId}),
    showRowDelete: _editable,
    showRemoveRowsAction: _editable,
    columns: [
      EditableGridColumn(
        key: 'context',
        label: '财务材料分组',
        width: 240,
        listenableOf: (r) => r.changed,
        cellBuilder: (_, r) => ValueListenableBuilder(
          valueListenable: r.changed,
          builder: (_, _, _) => UtenButton(
            type: UtenButtonType.secondary,
            onPressed: _editable
                ? () => _pickReference('contextId', 'contexts', row: r)
                : null,
            child: Text(
              r.data['_contextIdLabel']?.toString() ??
                  r.data['contextId']?.toString() ??
                  '选择已核分组',
            ),
          ),
        ),
      ),
      EditableGridColumn(
        key: 'source',
        label: '真实成品出库',
        width: 270,
        textOf: (r) => r.data['_sourceLabel']?.toString() ?? '',
        listenableOf: (r) => r.changed,
        cellBuilder: (_, r) => ValueListenableBuilder(
          valueListenable: r.changed,
          builder: (_, _, _) => UtenButton(
            type: UtenButtonType.secondary,
            onPressed: _editable ? () => _pickMovement(fee: r) : null,
            child: Text(r.data['_sourceLabel']?.toString() ?? '选择实际成品出库'),
          ),
        ),
      ),
      for (final f in [
        ('amountLocal', '加工份额（本币）'),
        ('amountOriginal', '加工份额（来源实际原币）'),
        ('quotedProcessingPrice', '加工单价'),
        ('quotationReference', '原报价／成交依据'),
      ])
        EditableGridColumn(
          key: f.$1,
          label: f.$2,
          width: f.$1 == 'quotationReference' ? 260 : 190,
          textOf: (r) => r.text[f.$1]!.text,
          listenableOf: (r) => r.text[f.$1]!,
          cellBuilder: (_, r) => UtenInput(
            controller: r.text[f.$1],
            enabled:
                _editable &&
                !(f.$1 == 'amountOriginal' &&
                    _feeSource != null &&
                    _feeSource!['amount_original'] == null),
          ),
        ),
      EditableGridColumn(
        key: 'adjustments',
        label: '真实附加款／含入J说明',
        width: 240,
        cellBuilder: (_, row) => UtenButton(
          type: UtenButtonType.secondary,
          onPressed: _busy
              ? null
              : () {
                  setState(() => _editingAdjustment = row);
                },
          child: Text(
            row.data['adjustmentReviewed'] == true ? '已核调整口径：查看／更正' : '核对附加来源',
          ),
        ),
      ),
      EditableGridColumn(
        key: 'currency',
        label: '报价真实币别',
        width: 210,
        listenableOf: (r) => r.changed,
        cellBuilder: (_, r) => ValueListenableBuilder(
          valueListenable: r.changed,
          builder: (_, _, _) => UtenButton(
            type: UtenButtonType.secondary,
            onPressed: _editable
                ? () => _pickReference(
                    'quotationCurrencyId',
                    'currencies',
                    row: r,
                  )
                : null,
            child: Text(
              r.data['_quotationCurrencyIdLabel']?.toString() ??
                  r.data['quotationCurrencyId']?.toString() ??
                  '选择真实币别',
            ),
          ),
        ),
      ),
      EditableGridColumn(
        key: 'tax',
        label: '原报价含税说明',
        width: 220,
        listenableOf: (r) => r.changed,
        cellBuilder: (_, r) => ValueListenableBuilder(
          valueListenable: r.changed,
          builder: (_, _, _) => UtenDropdownField(
            value: r.data['quotationTaxBasis']?.toString(),
            enabled: _editable,
            items: const [
              UtenDropdownItem(value: 'INCLUDED', label: '含税'),
              UtenDropdownItem(value: 'EXCLUDED', label: '未税'),
              UtenDropdownItem(value: 'NOT_APPLICABLE', label: '不适用'),
            ],
            onChanged: (v) {
              r.data['quotationTaxBasis'] = v;
              r.changed.value++;
              _changed();
            },
          ),
        ),
      ),
    ],
  );
  Future<void> _pickCredit(_MaterialAdjustmentRow row) async {
    if (!_editable || _contextId == null || _data['source'] is! Map) return;
    final root = _mm(_data['source']);
    final scope = await captureFormDraftRequestScope();
    if (!mounted || !scope.isCurrent) return;
    final selected = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => UtenDialogFrame(
        child: SizedBox(
          width: 1150,
          height: MediaQuery.sizeOf(context).height * .8,
          child: _MaterialGlPicker(
            contextId: _contextId!,
            from: _text['dateFrom']!.text,
            to: _text['dateTo']!.text,
            receivable: root,
            purpose: row.data['purpose']?.toString() ?? 'VAT',
          ),
        ),
      ),
    );
    if (!mounted ||
        !formDraftIdentityIsCurrent ||
        !scope.isCurrent ||
        selected == null) {
      return;
    }
    row.data.addAll({
      'source': {
        'entryId': selected['entry_id'],
        'allocationNo': selected['allocation_no'],
      },
      'expectedSourceFingerprint': selected['identityFingerprint'],
      '_sourceLabel':
          '${selected['voucher_no']} / 分录 ${selected['line_no']} / 本币 ${selected['amount_local']} / 原币 ${selected['amount_original'] ?? '缺证据'}',
      '_originalKnown': selected['amount_original'] != null,
    });
    if (selected['amount_original'] == null) {
      row.text['unrelatedOriginal']!.clear();
    }
    row.changed.value++;
    _changed();
  }

  Widget _adjustmentSourcesGrid() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 12),
      const Text('原凭证实际附加款来源：收客户税点是营业外收入；VAT另选真实应交税费贷方。完整分配一次，不套固定税率。'),
      SizedBox(
        height: 290,
        child: FinanceEditableGridWindow<_MaterialAdjustmentRow>(
          initialPage: _gridPages['creditSources'] ?? 1,
          onPageChanged: (page) => _rememberGridPage('creditSources', page),
          controller: _creditSources,
          tableKey: 'finance.material.credit-sources',
          showAddRow: _editable,
          createBlankRow: () =>
              _MaterialAdjustmentRow({'purpose': 'VAT'}, source: true),
          showRowDelete: _editable,
          columns: [
            EditableGridColumn(
              key: 'purpose',
              label: '实际性质',
              width: 230,
              cellBuilder: (_, row) => UtenDropdownField(
                value: row.data['purpose']?.toString(),
                enabled: _editable,
                items: const [
                  UtenDropdownItem(value: 'VAT', label: '真实VAT应交税费'),
                  UtenDropdownItem(
                    value: 'CUSTOMER_TAXPOINT',
                    label: '收客户税点（营业外收入）',
                  ),
                ],
                onChanged: (v) {
                  row.data['purpose'] = v;
                  row.data.remove('source');
                  row.data.remove('expectedSourceFingerprint');
                  row.data.remove('_sourceLabel');
                  row.changed.value++;
                  _changed();
                },
              ),
            ),
            EditableGridColumn(
              key: 'source',
              label: '同凭证真实原贷方',
              width: 510,
              listenableOf: (row) => row.changed,
              cellBuilder: (_, row) => ValueListenableBuilder(
                valueListenable: row.changed,
                builder: (_, _, _) => UtenButton(
                  type: UtenButtonType.secondary,
                  onPressed: _editable ? () => _pickCredit(row) : null,
                  child: Text(
                    row.data['_sourceLabel']?.toString() ?? '选择实际分录和原值',
                  ),
                ),
              ),
            ),
            for (final field in [
              ('unrelatedLocal', '明确非本表余项（本币）'),
              ('unrelatedOriginal', '明确非本表余项（原币）'),
              ('sourceReference', '原贷方核对依据'),
            ])
              EditableGridColumn(
                key: field.$1,
                label: field.$2,
                width: field.$1 == 'sourceReference' ? 300 : 230,
                cellBuilder: (_, row) => UtenInput(
                  controller: row.text[field.$1],
                  enabled:
                      _editable &&
                      !(field.$1 == 'unrelatedOriginal' &&
                          row.data['_originalKnown'] == false),
                ),
              ),
          ],
        ),
      ),
    ],
  );
  Widget _adjustmentPartGrid(_FeeRow part) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        value: part.data['adjustmentReviewed'] == true,
        title: const Text('本加工份额的调整口径已核对；确无附加款也须明确确认'),
        onChanged: _editable
            ? (v) {
                part.data['adjustmentReviewed'] = v == true;
                part.changed.value++;
                _changed();
              }
            : null,
      ),
      SizedBox(
        height: 300,
        child: FinanceEditableGridWindow<_MaterialAdjustmentRow>(
          initialPage: _gridPages['creditParts:${part.localId}'] ?? 1,
          onPageChanged: (page) =>
              _rememberGridPage('creditParts:${part.localId}', page),
          controller: part.adjustments,
          tableKey: 'finance.material.credit-parts',
          showAddRow: _editable,
          createBlankRow: () => _MaterialAdjustmentRow({}, source: false),
          showRowDelete: _editable,
          columns: [
            EditableGridColumn(
              key: 'source',
              label: '已列原贷方来源',
              width: 450,
              listenableOf: (row) => row.changed,
              cellBuilder: (_, row) => UtenDropdownField(
                value: _adjustmentKey(row.data['source']),
                enabled: _editable,
                items: [
                  for (final source in _creditSources.rows)
                    if (source.data['source'] is Map)
                      UtenDropdownItem(
                        value: _adjustmentKey(source.data['source'])!,
                        label:
                            source.data['_sourceLabel']?.toString() ??
                            _adjustmentKey(source.data['source'])!,
                      ),
                ],
                onChanged: (key) {
                  final source = _creditSources.rows.firstWhereOrNull(
                    (s) => _adjustmentKey(s.data['source']) == key,
                  );
                  row.data['source'] = source?.data['source'];
                  row.data['_originalKnown'] = source?.data['_originalKnown'];
                  row.changed.value++;
                  _changed();
                },
              ),
            ),
            for (final field in [
              ('amountLocal', '附加份额（本币）'),
              ('amountOriginal', '附加份额（真实原币）'),
            ])
              EditableGridColumn(
                key: field.$1,
                label: field.$2,
                width: 250,
                cellBuilder: (_, row) => UtenInput(
                  controller: row.text[field.$1],
                  enabled:
                      _editable &&
                      !(field.$1 == 'amountOriginal' &&
                          row.data['_originalKnown'] == false),
                ),
              ),
            EditableGridColumn(
              key: 'included',
              label: '已含在主J加工款中',
              width: 190,
              cellBuilder: (_, row) => Checkbox(
                value: row.data['includedInProcessing'] == true,
                onChanged: _editable
                    ? (v) {
                        row.data['includedInProcessing'] = v == true;
                        row.changed.value++;
                        _changed();
                      }
                    : null,
              ),
            ),
          ],
        ),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) {
    if (!formDraftIdentityIsCurrent) {
      return withFormDraft(
        const Material(child: Center(child: Text('登录身份、权限或服务器已变化，原草稿已保留。'))),
      );
    }
    return withFormDraft(
      Material(
        child: Column(
          children: [
            UtenDialogSurface(
              child: UtenDialogHeader(
                title: UtenDialogTitleWithHint(
                  title: Text(
                    '${FinanceRequirementNames.otherReceivableStatement}／${_materialKinds[_kind] ?? _kind}',
                  ),
                  info: _pending != null
                      ? '原请求结果待核，参数已冻结，不能换版本重复发送。'
                      : switch (_kind) {
                          'CONTEXT' =>
                            '产品名称和规格按财务原文维护；本组货品只作分组标识，真实入料与产物另在“材料／产品对应”逐项选择。原币单位与会计币别分开。',
                          'GOODS' =>
                            '原料与成品可以是不同真实货品。委外材料出仓／退料只计重量，成品其他出库才计PCS与加工款。',
                          'UNIT' =>
                            '按真实货品、颜色、原单位及原换算率核对；估计单重只作参考，不当实称。基本量的KG/PCS意义须有实际证据。',
                          'FEE' =>
                            '只分配同一真实其他应收原分录，不再生成收入或分录。普通回款贷方不当负加工费；跨月补记按实际财务日期，不重复实物。',
                          'CLOSE' =>
                            '撤销本次错误维护需另一财务审核；先处理仍引用本组的加工份额。原GL、仓库实物和旧记录保持，当前来源归属释放后可重建。',
                          _ => null,
                        },
                ),
                showCloseButton: true,
                onClose: _busy ? null : _close,
              ),
            ),
            if (_loading || _busy) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(UtenSpacing.s8),
                child: Text(_error!),
              ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(UtenSpacing.s16),
                child: Form(
                  key: _form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_evidence?['submission_reason'] != null)
                        Text('原提交依据：${_evidence!['submission_reason']}'),
                      if (_evidence?['decision_reason'] != null)
                        Text('原审核／退回／撤回依据：${_evidence!['decision_reason']}'),
                      if (_evidence != null)
                        Text(
                          '原记录：${_evidence!['id']}；${_states[_evidence!['status']] ?? _evidence!['status']}',
                        ),
                      const SizedBox(height: UtenSpacing.s12),
                      UtenFormGrid(
                        maxColumns: 3,
                        children: [
                          for (final key in _fields[_kind] ?? const <String>[])
                            _field(key),
                        ],
                      ),
                      if (_kind == 'CONTEXT')
                        Wrap(
                          children: [
                            for (final kind in _sourceKinds.entries)
                              SizedBox(
                                width: 300,
                                child: CheckboxListTile(
                                  value:
                                      (_data['requiredSourceKinds'] as List? ??
                                              const [])
                                          .contains(kind.key),
                                  title: Text(kind.value),
                                  onChanged: _editable
                                      ? (v) {
                                          final selected = List<String>.from(
                                            (_data['requiredSourceKinds']
                                                        as List? ??
                                                    const [])
                                                .map((x) => x.toString()),
                                          );
                                          if (v == true) {
                                            selected.add(kind.key);
                                          } else {
                                            selected.remove(kind.key);
                                          }
                                          _data['requiredSourceKinds'] =
                                              selected;
                                          _changed();
                                        }
                                      : null,
                                ),
                              ),
                          ],
                        ),
                      if (_kind == 'FEE') ...[
                        _feeGrid(),
                        _adjustmentSourcesGrid(),
                        if (_editingAdjustment != null &&
                            _fees.rows.contains(_editingAdjustment))
                          _adjustmentPartGrid(_editingAdjustment!),
                      ],
                      if (_kind == 'COVERAGE')
                        Column(
                          children: [
                            UtenButton(
                              type: UtenButtonType.secondary,
                              onPressed: _editable
                                  ? () => _pickMovement(addRange: true)
                                  : null,
                              child: const Text('加入实际来源行'),
                            ),
                            FinanceEditableGridWindow<_SourceRow>(
                              initialPage: _gridPages['coverage'] ?? 1,
                              onPageChanged: (page) =>
                                  _rememberGridPage('coverage', page),
                              controller: _range,
                              showRowDelete: _editable,
                              showRemoveRowsAction: _editable,
                              columns: [
                                EditableGridColumn(
                                  key: 'source',
                                  label: '完整来源清单',
                                  width: 600,
                                  textOf: (r) =>
                                      r.data['_sourceLabel']?.toString() ?? '',
                                  cellBuilder: (_, r) => Text(
                                    r.data['_sourceLabel']?.toString() ?? '',
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      if (_action)
                        UtenInput(
                          label: '本次提交／审核／撤回依据',
                          controller: _text['reason'],
                          maxLines: 3,
                          enabled: !_busy && _pending == null,
                          validator: (v) =>
                              (v?.trim().isEmpty ?? true) ? '请填写本次依据' : null,
                        ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(UtenSpacing.s12),
              child: Column(
                children: [
                  if (_pending != null) ...[formDraftSubmissionRecoveryAction!],
                  UtenDialogActions(
                    padding: EdgeInsets.zero,
                    showDivider: false,
                    children: [
                      if (!_view)
                        UtenButton(
                          onPressed: _busy || _loading || _pending != null
                              ? null
                              : _send,
                          child: Text(
                            _action
                                ? switch (_mode) {
                                    'approve' => '确认审核',
                                    'reject' => '退回核对',
                                    'withdraw' => '撤回原提交',
                                    _ => '提交核对',
                                  }
                                : '保存草稿',
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            if (_busy)
              const UtenBusyOverlay(
                title: '正在核对材料来源资料',
                showDoNotLeaveHint: false,
              ),
          ],
        ),
      ),
    );
  }
}

String? _adjustmentKey(Object? value) {
  final source = _mm(value);
  return source['entryId'] == null
      ? null
      : '${source['entryId']}:${source['allocationNo']}';
}

class _MaterialAdjustmentRow extends EditableGridRow {
  _MaterialAdjustmentRow(Map<String, dynamic> input, {required this.source})
    : data = _mm(input) {
    for (final key
        in source
            ? ['unrelatedLocal', 'unrelatedOriginal', 'sourceReference']
            : ['amountLocal', 'amountOriginal']) {
      text[key] = TextEditingController(text: data[key]?.toString() ?? '');
    }
  }
  final bool source;
  final Map<String, dynamic> data;
  final text = <String, TextEditingController>{};
  final changed = ValueNotifier<int>(0);
  Map<String, dynamic> capture() => {
    for (final key
        in source
            ? ['source', 'expectedSourceFingerprint', 'purpose']
            : ['source', 'includedInProcessing'])
      key: data[key],
    for (final entry in text.entries)
      entry.key:
          (entry.key.endsWith('Original') &&
              (data['_originalKnown'] == false ||
                  entry.value.text.trim().isEmpty)
          ? null
          : entry.value.text.trim()),
    for (final key in ['_sourceLabel', '_originalKnown'])
      if (data.containsKey(key)) key: data[key],
  };
  Map<String, dynamic> input() =>
      capture()..removeWhere((key, _) => key.startsWith('_'));
  @override
  void dispose() {
    for (final controller in text.values) {
      controller.dispose();
    }
    changed.dispose();
    super.dispose();
  }
}
