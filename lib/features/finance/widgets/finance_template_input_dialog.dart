import 'package:flutter/material.dart';
import '../shared/finance_template_source_upload.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/ui/human_error_message.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import 'finance_entry_file_picker.dart';

/// Opens only a selected source row. Names never establish the target identity.
Future<bool> showFinanceTemplateInputDialog(
  BuildContext context, {
  required String kind,
  required Map<String, dynamic> scope,
  String? resumeDraftId,
}) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => UtenDialogFrame(
        child: SizedBox(
          width: 900,
          height: MediaQuery.sizeOf(context).height * .88,
          child: FinanceTemplateInputSurface(
            kind: kind,
            scope: scope,
            resumeDraftId: resumeDraftId,
          ),
        ),
      ),
    ) ??
    false;

class FinanceTemplateInputSurface extends ConsumerStatefulWidget {
  FinanceTemplateInputSurface({
    super.key,
    required this.kind,
    required Map<String, dynamic> scope,
    this.resumeDraftId,
  }) : scope = Map<String, dynamic>.unmodifiable(scope);
  final String kind;
  final Map<String, dynamic> scope;
  final String? resumeDraftId;
  @override
  ConsumerState<FinanceTemplateInputSurface> createState() =>
      _FinanceTemplateInputSurfaceState();
}

class _FinanceTemplateInputSurfaceState
    extends ConsumerState<FinanceTemplateInputSurface>
    with FormDraftMixin<FinanceTemplateInputSurface> {
  final _form = GlobalKey<FormState>();
  final Map<String, TextEditingController> _text = {};
  String _requestId = const Uuid().v4();
  Map<String, dynamic>? _sent;
  bool _loading = true, _saving = false, _confirmed = false;
  String? _error, _channel, _taxRate, _expenseCaption, _loadedValidFrom;
  int _version = -1;
  Map<String, dynamic>? _source;
  String? _sourceUnitName;
  String? _sourceRow;
  String? _sectionKey;
  Map<String, String> _sectionChoices = const {};
  bool get _asset => widget.kind == 'asset';
  String get _base => _asset
      ? '/finance/asset-template-inputs'
      : '/finance/cost-template-inputs';
  String get _title => widget.kind == 'copper'
      ? '原表分类'
      : _asset
      ? '资产原表资料'
      : widget.kind == 'sales'
      ? '销售成本汇总资料'
      : widget.kind == 'plastic'
      ? '塑料领用及占比资料'
      : '订单号资料';
  List<(String, String)> get _fields => switch (widget.kind) {
    'sales' => [
      ('clientName', '客户名称'),
      ('sellerName', '业务员'),
      ('region', '区域'),
      ('director', '总监'),
      ('freightLocal', '运费'),
      ('exchangeRate', '汇率'),
      ('sourceReference', '核对依据'),
    ],
    'plastic' => [
      ('materialName', '材料名称'),
      ('templateRow', '序号'),
      ('weightKgPerUnit', '每原单位折合KG'),
      ('rejectReturnQty', '安装挑选不良（退料）'),
      ('rejectIssueQty', '安装挑选不良（耗用）'),
      ('reason', '原因'),
      ('sourceReference', '核对依据'),
    ],
    'order' => [('orderNo', '订单号'), ('sourceReference', '核对依据')],
    'copper' => [('sourceReference', '核对依据')],
    'asset' => [
      ('validFrom', '资料有效日'),
      ('sourceMonth', '月份'),
      ('locationCaption', '存放地点'),
      (
        'partyName',
        widget.scope['objectType'] == 'FIXED_ASSET' ? '名称（原表C列）' : '供应商单位名称',
      ),
      ('unitSpecification', '单位'),
      ('usageCaption', '使用情况'),
      ('categoryCaption', '类别'),
      ('documentDate', '日期'),
      ('firstLevelCaption', '一级科目'),
      ('secondLevelCaption', '二级明细'),
      ('acceptanceCaption', '验收合格'),
      ('sourceReference', '核对依据'),
    ],
    _ => const [],
  };
  @override
  FormDraftSpec get formDraftSpec =>
      (_asset
              ? FormDraftCatalog.financeAssetTemplateInput
              : FormDraftCatalog.financeCostTemplateInput)
          .spec(
            title: _title,
            routeParameters: {
              'inputKind': widget.kind,
              for (final entry in widget.scope.entries)
                if (entry.value != null)
                  'input.${entry.key}': entry.value.toString(),
            },
          );
  @override
  bool get formDraftUsesRouterGuard => false;
  @override
  bool get formDraftUseCurrentRoute => false;
  @override
  bool get formDraftBusy => _saving;
  @override
  String? get formDraftResumeId => widget.resumeDraftId;
  @override
  bool get formDraftCanReplaySubmission => _sent != null;
  @override
  Iterable<Listenable> get formDraftListenables => _text.values;
  @override
  Map<String, dynamic> captureFormDraft() => {
    'kind': widget.kind,
    'scope': widget.scope,
    'text': {for (final e in _text.entries) e.key: e.value.text},
    'channel': _channel,
    'taxRate': _taxRate,
    'confirmed': _confirmed,
    'version': _version,
    'requestId': _requestId,
    'sent': _sent,
    'sourceImportId': _source?['importId'],
    'sourceRow': _sourceRow,
    'sectionKey': _sectionKey,
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    final savedScope = data['scope'];
    if (data['kind'] != widget.kind ||
        savedScope is! Map ||
        savedScope.length != widget.scope.length ||
        widget.scope.entries.any((e) => savedScope[e.key] != e.value)) {
      throw StateError('原表草稿的来源行或月份不一致');
    }
    final values = data['text'];
    if (values is Map) {
      for (final e in _text.entries) {
        e.value.text = values[e.key]?.toString() ?? '';
      }
    }
    _channel = data['channel'] as String?;
    _taxRate = data['taxRate'] as String?;
    _confirmed = data['confirmed'] == true;
    _version = (data['version'] as num?)?.toInt() ?? -1;
    final id = data['requestId'];
    if (id is! String || !Uuid.isValidUUID(fromString: id)) {
      throw StateError('原请求编号缺失，不能重放提交');
    }
    _requestId = id;
    _sent = data['sent'] is Map
        ? Map<String, dynamic>.from(data['sent'] as Map)
        : null;
    if (_sent != null) {
      final identities = switch (widget.kind) {
        'sales' => ['period', 'clientId'],
        'plastic' => ['periodLineId'],
        'order' => ['requisitionId'],
        'copper' => ['sourceLineId'],
        _ => ['objectType', 'objectId'],
      };
      if (_sent!['requestId'] != _requestId ||
          identities.any((key) => _sent![key] != widget.scope[key])) {
        throw StateError('原提交的请求编号或来源身份不一致，不能重新提交');
      }
    }
    final sourceId = data['sourceImportId'];
    _sourceRow = data['sourceRow']?.toString();
    _sectionKey = data['sectionKey']?.toString();
    if (sourceId is String) {
      final scope = await captureFormDraftRequestScope();
      final source = await scope.run(
        () => ref
            .read(apiClientProvider)
            .get('/finance/template-imports/$sourceId'),
      );
      if (!formDraftIdentityIsCurrent || !scope.isCurrent) {
        throw StateError('原表来源身份已变化');
      }
      _source = source;
    }
  }

  @override
  void initState() {
    super.initState();
    for (final field in _fields) {
      _text[field.$1] = TextEditingController();
    }
    startFormDraftIdentityGuard();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final scope = await captureFormDraftRequestScope();
      final api = ref.read(apiClientProvider);
      final result = await scope.run(
        () => switch (widget.kind) {
          'sales' => api.get(
            '$_base/sales',
            query: {
              'period': widget.scope['period'],
              'clientId': widget.scope['clientId'],
            },
          ),
          'plastic' => api.get(
            '$_base/plastic/${widget.scope['periodLineId']}',
          ),
          'order' => api.get('$_base/order/${widget.scope['requisitionId']}'),
          'copper' => api.get('$_base/copper/${widget.scope['sourceLineId']}'),
          'asset' => api.get(
            _base,
            query: {
              'objectType': widget.scope['objectType'],
              'objectId': widget.scope['objectId'],
              'asOf': widget.scope['validFrom'],
            },
          ),
          _ => throw StateError('原表资料类型不正确'),
        },
      );
      if (!mounted || !formDraftIdentityIsCurrent || !scope.isCurrent) return;
      _version = (result['version'] as num?)?.toInt() ?? -1;
      _sourceUnitName = result['sourceUnitName']?.toString();
      _sectionKey = result['sectionKey']?.toString();
      if (result['sectionChoices'] is Map) {
        _sectionChoices = {
          for (final e in (result['sectionChoices'] as Map).entries)
            e.key.toString(): e.value.toString(),
        };
      }
      _loadedValidFrom = result['validFrom']?.toString();
      for (final e in _text.entries) {
        e.value.text =
            result[e.key]?.toString() ?? widget.scope[e.key]?.toString() ?? '';
      }
      if (_asset && _text['validFrom']!.text.isEmpty) {
        _text['validFrom']!.text = DateTime.now().toIso8601String().substring(
          0,
          10,
        );
      }
      _channel = result['channel'] as String?;
      _taxRate = result['taxRate'] == null
          ? null
          : RegExp(r'^0(?:\.0+)?$').hasMatch(result['taxRate'].toString())
          ? '0'
          : '0.10';
      _expenseCaption = result['expectedExpenseCaption'] as String?;
      _confirmed = result['confirmed'] == true;
      setState(() => _loading = false);
      await initializeFormDraft();
    } catch (error) {
      if (mounted && formDraftIdentityIsCurrent) {
        setState(() {
          _loading = false;
          _error = humanErrorMessage(error) ?? '原表资料加载失败';
        });
      }
    }
  }

  Map<String, dynamic> _payload() {
    final result = <String, dynamic>{
      'requestId': _requestId,
      'expectedVersion': _version,
      'confirmed': _confirmed,
    };
    for (final e in _text.entries) {
      final value = e.value.text.trim();
      result[e.key] =
          value.isEmpty &&
              const {
                'freightLocal',
                'exchangeRate',
                'weightKgPerUnit',
                'documentDate',
                'templateRow',
              }.contains(e.key)
          ? null
          : value;
    }
    if (widget.kind == 'sales') {
      result.addAll({
        'period': widget.scope['period'],
        'clientId': widget.scope['clientId'],
        'channel': _channel,
        'taxRate': _taxRate,
      });
    } else if (widget.kind == 'plastic') {
      result['periodLineId'] = widget.scope['periodLineId'];
      result['templateRow'] = int.tryParse(_text['templateRow']!.text.trim());
    } else if (widget.kind == 'order') {
      result['requisitionId'] = widget.scope['requisitionId'];
    } else if (widget.kind == 'copper') {
      result.addAll({
        'sourceLineId': widget.scope['sourceLineId'],
        'sectionKey': _sectionKey,
      });
    } else {
      result.addAll({
        'objectType': widget.scope['objectType'],
        'objectId': widget.scope['objectId'],
      });
      if (result['validFrom'] != _loadedValidFrom) {
        result['expectedVersion'] = -1;
      }
    }
    return result;
  }

  Future<void> _save() async {
    if (_saving || !formDraftIdentityIsCurrent) return;
    if (_sent == null && !(_form.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    try {
      final scope = await captureFormDraftRequestScope();
      if (!mounted || !scope.isCurrent) return;
      _sent ??= _payload();
      final api = ref.read(apiClientProvider);
      final wasUnknown = formDraftHasUnknownSubmission;
      await runFormDraftSubmission(
        () => scope.run(
          () => api.post(_asset ? _base : '$_base/${widget.kind}', body: _sent),
        ),
        isDefiniteRejection: (error) =>
            !wasUnknown &&
            (error.details?['notWritten'] == true ||
                error.hasResponseCode &&
                    const {
                      'VALIDATION_FAILED',
                      'CONFLICT',
                      'FORBIDDEN',
                      'NOT_FOUND',
                    }.contains(error.code)),
      );
      if (!mounted || !formDraftIdentityIsCurrent || !scope.isCurrent) return;
      await completeFormDraft();
      if (mounted) {
        context.appSuccess('原表资料已保存');
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      // Unknown outcomes retain the identical command and request ID. Definite
      // rejection permits correction; an unknown prior attempt stays frozen.
      if (!formDraftHasUnknownSubmission) _sent = null;
      if (mounted && formDraftIdentityIsCurrent) {
        context.appApiError(error, fallback: '保存未完成，原资料和请求编号已保留');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _receipt() async {
    if (_saving || _sent == null) return;
    setState(() => _saving = true);
    try {
      final scope = await captureFormDraftRequestScope();
      if (!mounted || !scope.isCurrent) return;
      final result = await scope.run(
        () => ref.read(apiClientProvider).get('$_base/operations/$_requestId'),
      );
      if (!mounted || !formDraftIdentityIsCurrent || !scope.isCurrent) return;
      if (result['requestId'] != _requestId) throw StateError('回执与原请求不一致');
      await completeFormDraft();
      if (mounted) {
        context.appSuccess('原请求已保存成功');
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (mounted && formDraftIdentityIsCurrent) {
        context.appApiError(error, fallback: '尚未取得原请求成功回执，继续保留原资料');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String get _template => switch (widget.kind) {
    'sales' => 'salesCostSummary',
    'plastic' => 'plasticUsage',
    'order' => 'plasticIssue',
    'copper' => 'copperDetail',
    _ =>
      widget.scope['template']?.toString() ??
          (widget.scope['objectType'] == 'DEFERRED_EXPENSE'
              ? 'amortization'
              : 'depreciation'),
  };
  List<Map<String, dynamic>> get _sourceRows => [
    if (_source?['rows'] is List)
      for (final row in _source!['rows'] as List)
        if (row is Map) Map<String, dynamic>.from(row),
  ];
  String _cell(Map<String, dynamic> row, int column) {
    final cells = row['cells'];
    if (cells is List) {
      for (final cell in cells) {
        if (cell is Map && cell['column'] == column) {
          return (cell['number'] ?? cell['text'] ?? '').toString();
        }
      }
    }
    return '';
  }

  Future<void> _import() async {
    if (_saving || _sent != null || !formDraftIdentityIsCurrent) return;
    setState(() => _saving = true);
    try {
      final scope = await captureFormDraftRequestScope();
      await saveFormDraftNow();
      final date = _text['validFrom']?.text ?? '';
      final period =
          widget.scope['period']?.toString() ??
          (date.length >= 7 ? date.substring(0, 7) : '');
      if (!RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(period)) {
        throw StateError('请先选择原表会计月份或资料有效日');
      }
      final file = await ref.read(financeEntryFilePickerProvider)();
      if (file == null || !mounted || !scope.isCurrent) return;
      final bytes = file.bytes, limit = (_asset ? 64 : 15) * 1024 * 1024;
      if (!const {'xls', 'xlsx'}.contains(file.extension?.toLowerCase()) ||
          bytes == null ||
          bytes.isEmpty ||
          bytes.length > limit) {
        context.appWarning('请选择完整的XLS或XLSX原表，最大${_asset ? 64 : 15}MB');
        return;
      }
      final result = await scope.run(
        () => uploadFinanceTemplateSource(
          context: context,
          api: ref.read(apiClientProvider),
          bytes: bytes,
          asset: _asset,
          isCurrent: () =>
              mounted && formDraftIdentityIsCurrent && scope.isCurrent,
          query: {
            'template': _template,
            'period': period,
            'filename': file.name,
          },
        ),
      );
      if (result == null ||
          !mounted ||
          !formDraftIdentityIsCurrent ||
          !scope.isCurrent) {
        return;
      }
      setState(() {
        _source = result;
        _sourceRow = null;
      });
      markFormDraftChanged();
      if ((result['issues'] as List?)?.isNotEmpty == true) {
        context.appWarning('原表已保留，请先核对预览中的读取问题');
      }
    } catch (error) {
      if (mounted && formDraftIdentityIsCurrent) {
        context.appApiError(error, fallback: '原表未读取完成；可重新选择同一文件恢复已保存预览');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _useSourceRow() {
    final row = _sourceRows
        .where((r) => r['sourceRow'].toString() == _sourceRow)
        .firstOrNull;
    if (row == null || (_source?['issues'] as List?)?.isNotEmpty == true) {
      return;
    }
    if ((row['issues'] as List?)?.isNotEmpty == true) {
      context.appWarning((row['issues'] as List).join('；'));
      return;
    }
    final Map<String, int> columns = switch (widget.kind) {
      'sales' => {
        'clientName': 1,
        'sellerName': 2,
        'region': 3,
        'director': 4,
        'freightLocal': 11,
        'exchangeRate': 14,
      },
      'plastic' => {'materialName': 2, 'templateRow': 1, 'reason': 13},
      'order' => {'orderNo': 3},
      'copper' => {},
      _ =>
        widget.scope['objectType'] == 'DEFERRED_EXPENSE'
            ? {
                'sourceMonth': 1,
                'partyName': 2,
                'usageCaption': 4,
                'categoryCaption': 5,
                'documentDate': 6,
                'firstLevelCaption': 22,
                'secondLevelCaption': 23,
                'acceptanceCaption': 27,
              }
            : {
                'sourceMonth': 1,
                'partyName': 3,
                'locationCaption': 2,
                'usageCaption': 4,
                'categoryCaption': 5,
                'unitSpecification': 7,
                'firstLevelCaption': 37,
                'acceptanceCaption': 39,
              },
    };
    for (final entry in columns.entries) {
      _text[entry.key]?.text = _cell(row, entry.value);
    }
    _text['sourceReference']!.text =
        '${_source!['sourceName']} / ${_source!['sourceSheet']} / 第$_sourceRow行 / SHA256:${_source!['sha256']} / ${_source!['importId']}';
    setState(() => _confirmed = false);
    markFormDraftChanged();
  }

  @override
  Widget? get formDraftSubmissionRecoveryAction => TextButton(
    onPressed: _saving ? null : _receipt,
    child: const Text('核对原请求结果'),
  );
  Future<void> _close() async {
    if (!_saving && await confirmFormDraftExit() && mounted) {
      Navigator.of(context).pop(false);
    }
  }

  String? _validate(String key, String? value) {
    final v = value?.trim() ?? '';
    if (key == 'sourceReference' && v.isEmpty) return '请填写原文档、工作表和行号等核对依据';
    if (const {
      'freightLocal',
      'exchangeRate',
      'weightKgPerUnit',
      'rejectReturnQty',
      'rejectIssueQty',
    }.contains(key)) {
      if (v.isEmpty &&
          const {'rejectReturnQty', 'rejectIssueQty'}.contains(key)) {
        return '请明确填写数量（确为零请填0）';
      }
      if (v.isNotEmpty && !RegExp(r'^-?\d+(\.\d+)?$').hasMatch(v)) {
        return '请输入十进制数字';
      }
    }
    if (const {'validFrom', 'documentDate'}.contains(key) &&
        (v.isNotEmpty || key == 'validFrom')) {
      final parsed = DateTime.tryParse(v);
      if (parsed == null || parsed.toIso8601String().substring(0, 10) != v) {
        return '请填写YYYY-MM-DD日期';
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => withFormDraft(
    Material(
      child: Column(
        children: [
          UtenDialogSurface(
            child: UtenDialogHeader(
              icon: Icons.table_chart_outlined,
              title: Text(_title),
              showCloseButton: true,
              onClose: _saving ? null : _close,
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(child: Text(_error!))
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(UtenSpacing.s20),
                    child: Form(
                      key: _form,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (widget.kind == 'sales')
                            Text(
                              '月份：${widget.scope['period']}。销售出货金额与销售成本取已核对业务事实；本表按原表管理比例计算。',
                            ),
                          if (widget.kind == 'plastic')
                            Text(
                              '已结算原单位：${_sourceUnitName ?? '尚未明确'}。退料中的不良和耗用中的不良分别填写，不能重复计入。',
                            ),
                          if (_asset)
                            Text(
                              '实际核算一级科目：${_expenseCaption ?? '尚未对应财务科目'}。原值、日期、年限和实际计提在资产流程中维护。',
                            ),
                          const SizedBox(height: UtenSpacing.s16),
                          UtenButton(
                            type: UtenButtonType.secondary,
                            onPressed: _saving || _sent != null
                                ? null
                                : _import,
                            child: const Text('导入原表'),
                          ),
                          if (_source != null) ...[
                            const SizedBox(height: UtenSpacing.s12),
                            Text(
                              '${_source!['sourceName']} · ${_source!['sourceSheet']}',
                            ),
                            if (_source!['issues'] is List)
                              for (final issue in _source!['issues'] as List)
                                Text(
                                  issue.toString(),
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                ),
                            UtenDropdownField(
                              label: '原表数据行',
                              enabled: !_saving && _sent == null,
                              value: _sourceRow,
                              items: [
                                for (final row in _sourceRows)
                                  UtenDropdownItem(
                                    value: row['sourceRow'].toString(),
                                    label:
                                        '第${row['sourceRow']}行 ${_cell(row, _asset && widget.scope['objectType'] == 'FIXED_ASSET'
                                            ? 6
                                            : widget.kind == 'plastic'
                                            ? 2
                                            : 1)}',
                                  ),
                              ],
                              onChanged: (v) => setState(() {
                                _sourceRow = v;
                                markFormDraftChanged();
                              }),
                            ),
                            UtenButton(
                              type: UtenButtonType.secondary,
                              onPressed:
                                  _sourceRow == null || _sent != null || _saving
                                  ? null
                                  : _useSourceRow,
                              child: const Text('带入所选行资料'),
                            ),
                            const SizedBox(height: UtenSpacing.s12),
                          ],
                          UtenFormGrid(
                            maxColumns: 3,
                            children: [
                              if (widget.kind == 'copper')
                                UtenDropdownField(
                                  label: '分类',
                                  enabled: !_saving && _sent == null,
                                  value: _sectionKey,
                                  items: [
                                    for (final e in _sectionChoices.entries)
                                      UtenDropdownItem(
                                        value: e.key,
                                        label: e.value,
                                      ),
                                  ],
                                  onChanged: (v) => setState(() {
                                    _sectionKey = v;
                                    markFormDraftChanged();
                                  }),
                                ),
                              for (final field in _fields)
                                UtenInput(
                                  label: field.$2,
                                  controller: _text[field.$1],
                                  enabled: !_saving && _sent == null,
                                  validator: (value) =>
                                      _validate(field.$1, value),
                                ),
                              if (widget.kind == 'sales')
                                UtenDropdownField(
                                  label: '销售费用',
                                  value: _channel,
                                  items: const [
                                    UtenDropdownItem(
                                      value: 'OEM',
                                      label: 'OEM 1%',
                                    ),
                                    UtenDropdownItem(
                                      value: 'FOREIGN',
                                      label: '外贸 6%',
                                    ),
                                    UtenDropdownItem(
                                      value: 'DOMESTIC',
                                      label: '内销 25%',
                                    ),
                                  ],
                                  enabled: !_saving && _sent == null,
                                  onChanged: (v) => setState(() {
                                    _channel = v;
                                    markFormDraftChanged();
                                  }),
                                ),
                              if (widget.kind == 'sales')
                                UtenDropdownField(
                                  label: '税费10%',
                                  value: _taxRate,
                                  items: const [
                                    UtenDropdownItem(
                                      value: '0',
                                      label: '本行不适用（0）',
                                    ),
                                    UtenDropdownItem(
                                      value: '0.10',
                                      label: '本行适用10%',
                                    ),
                                  ],
                                  enabled: !_saving && _sent == null,
                                  onChanged: (v) => setState(() {
                                    _taxRate = v;
                                    markFormDraftChanged();
                                  }),
                                ),
                            ],
                          ),
                          const SizedBox(height: UtenSpacing.s12),
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('已按原表及来源核对本行资料'),
                            value: _confirmed,
                            onChanged: _saving || _sent != null
                                ? null
                                : (v) => setState(() {
                                    _confirmed = v == true;
                                    markFormDraftChanged();
                                  }),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(UtenSpacing.s16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                const SizedBox(width: UtenSpacing.s12),
                UtenButton(
                  onPressed: _saving || _loading || _error != null
                      ? null
                      : _save,
                  child: Text(
                    _saving
                        ? '保存中…'
                        : _sent != null
                        ? '使用原请求重试'
                        : '保存',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
