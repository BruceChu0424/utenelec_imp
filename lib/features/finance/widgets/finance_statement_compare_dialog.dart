import 'package:flutter/material.dart';
import '../shared/finance_template_source_upload.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../core/network/api_client.dart';
import '../../../core/ui/human_error_message.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import 'finance_entry_file_picker.dart';
import 'finance_source_table.dart';

List<Map<String, dynamic>> _maps(Object? value) => [
  if (value is List)
    for (final item in value)
      if (item is Map) Map<String, dynamic>.from(item),
];
Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
const _base = '/finance/statement-documents/comparisons';

Future<void> showFinanceStatementCompareDialog(
  BuildContext context, {
  required Map<String, dynamic> scope,
  String? resumeDraftId,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) =>
      _Comparison(scope: Map.unmodifiable(scope), resumeDraftId: resumeDraftId),
);

class _Comparison extends ConsumerStatefulWidget {
  const _Comparison({required this.scope, this.resumeDraftId});
  final Map<String, dynamic> scope;
  final String? resumeDraftId;
  @override
  ConsumerState<_Comparison> createState() => _ComparisonState();
}

class _ComparisonState extends ConsumerState<_Comparison>
    with FormDraftMixin<_Comparison> {
  Map<String, dynamic>? _source, _actual, _result;
  final _mapping = <int, int>{};
  String? _mappingFingerprint, _error;
  int? _selected;
  int _sourcePage = 1, _actualPage = 1, _resultPage = 1;
  bool _busy = false, _loading = true;
  bool get _current => mounted && formDraftIdentityIsCurrent;
  bool get _stale =>
      _mapping.isNotEmpty &&
      _mappingFingerprint != _actual?['sourceFingerprint'];
  List<Map<String, dynamic>> get _sourceRows => _maps(_source?['rows']);
  List<Map<String, dynamic>> get _actualRows => _maps(_actual?['rows']);
  List<Map<String, dynamic>> get _columns => _maps(_actual?['columns']);
  @override
  FormDraftSpec get formDraftSpec =>
      FormDraftCatalog.financeStatementComparison.spec(
        routeParameters: {
          for (final field in widget.scope.entries)
            'statement.${field.key}': field.value.toString(),
        },
      );
  @override
  bool get formDraftUsesRouterGuard => false;
  @override
  bool get formDraftUseCurrentRoute => false;
  @override
  bool get formDraftBusy => _busy || _loading;
  @override
  String? get formDraftResumeId => widget.resumeDraftId;
  @override
  Map<String, dynamic> captureFormDraft() => {
    'scope': widget.scope,
    'sourceImportId': _source?['importId'],
    'sourceSha256': _source?['sha256'],
    'fingerprint': _mappingFingerprint,
    'mapping': {for (final row in _mapping.entries) '${row.key}': row.value},
    'selected': _selected,
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> saved) async {
    final old = _map(saved['scope']);
    if (old.length != widget.scope.length ||
        widget.scope.entries.any((item) => old[item.key] != item.value)) {
      throw StateError('原表比对草稿的对象、币别或期间不一致');
    }
    _mapping.clear();
    for (final item in _map(saved['mapping']).entries) {
      final source = int.tryParse(item.key),
          actual = int.tryParse(item.value.toString());
      if (source == null || actual == null || source < 1 || actual < 1) {
        throw StateError('原行对应草稿不完整');
      }
      _mapping[source] = actual;
    }
    if (_mapping.length > 2000 ||
        _mapping.values.toSet().length != _mapping.length) {
      throw StateError('原行对应重复或超过上限');
    }
    _selected = (saved['selected'] as num?)?.toInt();
    _mappingFingerprint = saved['fingerprint']?.toString();
    final id = saved['sourceImportId'];
    if (id is String) {
      final request = await captureFormDraftRequestScope();
      final source = await request.run(
        () => ref.read(apiClientProvider).get('/finance/template-imports/$id'),
      );
      if (!_current || !request.isCurrent) throw StateError('原表比对身份已变化');
      if (source['sha256'] != saved['sourceSha256']) {
        throw StateError('原文件校验与草稿不一致');
      }
      _source = source;
      await _preview();
    }
  }

  @override
  void initState() {
    super.initState();
    startFormDraftIdentityGuard();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await initializeFormDraft();
      } catch (error) {
        if (_current) _error = humanErrorMessage(error) ?? '原表草稿未恢复，请保留原记录';
      } finally {
        if (mounted) setState(() => _loading = false);
      }
    });
  }

  Future<void> _preview() async {
    final request = await captureFormDraftRequestScope();
    final response = await request.run(
      () => ref
          .read(apiClientProvider)
          .post(
            '$_base/preview',
            body: {
              'sourceImportId': _source?['importId'],
              'context': widget.scope,
            },
          ),
    );
    if (!_current || !request.isCurrent) return;
    _source = _map(response['source']);
    _actual = _map(response['actual']);
    _result = null;
    if (_mapping.isEmpty) {
      _mappingFingerprint = _actual?['sourceFingerprint']?.toString();
    }
  }

  Future<void> _upload() async {
    if (!_current || _busy || _loading) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await saveFormDraftNow();
      final request = await captureFormDraftRequestScope();
      final file = await ref.read(financeEntryFilePickerProvider)();
      if (file == null || !_current || !request.isCurrent) return;
      final bytes = file.bytes;
      if (!const {'xls', 'xlsx'}.contains(file.extension?.toLowerCase()) ||
          bytes == null ||
          bytes.isEmpty ||
          bytes.length > 15 * 1024 * 1024) {
        throw StateError('请选择完整的XLS或XLSX原表，最大15MB');
      }
      if (_mapping.isNotEmpty) {
        throw StateError('当前原文件已有行对应，请先保留并关闭本份比对，再从原入口打开另一份');
      }
      final source = await request.run(
        () => uploadFinanceTemplateSource(
          context: context,
          api: ref.read(apiClientProvider),
          bytes: bytes,
          asset: false,
          isCurrent: () => _current && request.isCurrent,
          query: {
            'template': widget.scope['templateKey'],
            'period': widget.scope['dateTo'].toString().substring(0, 7),
            'filename': file.name,
          },
        ),
      );
      if (source == null || !_current || !request.isCurrent) return;
      _source = source;
      markFormDraftChanged();
      await saveFormDraftNow();
      await _preview();
      markFormDraftChanged();
    } catch (error) {
      if (_current) {
        _error = humanErrorMessage(error) ?? '原表未读取完成；原文件可重新上传恢复同一批次';
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _compare() async {
    if (!_current || _busy || _mapping.isEmpty || _stale) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await saveFormDraftNow();
      final request = await captureFormDraftRequestScope();
      final result = await request.run(
        () => ref
            .read(apiClientProvider)
            .post(
              _base,
              body: {
                'sourceImportId': _source?['importId'],
                'context': widget.scope,
                'expectedSourceFingerprint': _mappingFingerprint,
                'rows': [
                  for (final item in _mapping.entries)
                    {'sourceRow': item.key, 'reportRowNumber': item.value},
                ],
              },
            ),
      );
      if (_current && request.isCurrent) {
        setState(() {
          _result = result;
          _resultPage = 1;
        });
      }
    } catch (error) {
      if (_current) _error = humanErrorMessage(error) ?? '比对未完成，原行对应和文件保留';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    if (!_current || _busy || _source == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _preview();
      markFormDraftChanged();
    } catch (error) {
      if (_current) _error = humanErrorMessage(error) ?? '当前原件未刷新，原对应保留';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _close() async {
    if (await confirmFormDraftExit() && mounted) Navigator.pop(context);
  }

  void _assign(Map<String, dynamic> row) {
    if (_selected == null || _busy || _stale || !_current) return;
    final target = row['__number'] as int;
    if (_mapping.entries.any(
      (item) => item.key != _selected && item.value == target,
    )) {
      setState(() => _error = '该实际行已对应另一原行，请先核对并解除原对应');
      return;
    }
    setState(() {
      _mapping[_selected!] = target;
      _mappingFingerprint = _actual?['sourceFingerprint']?.toString();
      _result = null;
      _error = null;
    });
    markFormDraftChanged();
  }

  List<Map<String, dynamic>> _slice(
    List<Map<String, dynamic>> rows,
    int page,
  ) => rows.skip((page - 1) * 50).take(50).toList();
  @override
  Widget build(BuildContext context) {
    ref.watch(exportContextEpochProvider);
    ref.watch(apiClientProvider);
    final permissions = ref.watch(currentPermissionsProvider);
    if (!_current) {
      return withFormDraft(
        UtenAlertDialog(
          title: const Text('访问范围已变化'),
          content: const Text('请从原入口重新打开；原文件和原账号草稿仍保留。'),
          actions: [TextButton(onPressed: _close, child: const Text('关闭'))],
        ),
      );
    }
    final sourceRows = [
      for (final row in _sourceRows)
        <String, dynamic>{
          ...row,
          '__mapping': _stale
              ? '旧对应待核对'
              : _mapping[row['sourceRow']]?.toString() ?? '',
          for (final cell in _maps(row['cells']))
            'c${cell['column']}': cell['number'] ?? cell['text'],
        },
    ];
    final actualFacts = _actualRows;
    final actualRows = [
      for (int index = 0; index < actualFacts.length; index++)
        <String, dynamic>{...actualFacts[index], '__number': index + 1},
    ];
    final differences = <Map<String, dynamic>>[
      for (final row in _maps(_result?['results']))
        for (final cell in _maps(row['cells']))
          if (cell['status'] != 'EQUAL')
            {
              ...cell,
              'sourceRow': row['sourceRow'],
              'reportRowNumber': row['reportRowNumber'],
            },
    ];
    return withFormDraft(
      UtenDialogFrame(
        maxWidth: 1380,
        fillHeight: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            UtenDialogHeader(
              title: const Text('原表导入比对'),
              showCloseButton: true,
              onClose: _busy ? null : _close,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${widget.scope['dateFrom']} 至 ${widget.scope['dateTo']}　先点原文件行，再点实际行；不按同名自动匹配。',
                  ),
                  if (_source != null)
                    SelectableText(
                      '${_source!['sourceName']}　SHA：${_source!['sha256']}',
                    ),
                  if (_selected != null)
                    Text('正在对应原文件第$_selected行，已对应${_mapping.length}行'),
                  if (_stale) const Text('实际原件已变化，旧行对应保留供核对；重新对应前不能提交比对。'),
                  if (_source?['issues'] case final List<Object?> issues
                      when issues.isNotEmpty)
                    Text(issues.join('；')),
                  if (_error != null)
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : sourceRows.isEmpty
                  ? const Center(child: Text('请导入对应入口的原19列或原8列文件'))
                  : Column(
                      children: [
                        Expanded(
                          child: financeSourceTable(
                            tableKey: 'finance.statement.compare.source',
                            columns: [
                              financeSourceColumn(
                                'sourceRow',
                                '原文件行',
                                type: 'int',
                              ),
                              financeSourceColumn('__mapping', '对应实际行'),
                              for (
                                int index = 0;
                                index <
                                    (_source?['headers'] as List? ?? const [])
                                        .length;
                                index++
                              )
                                financeSourceColumn(
                                  'c${index + 1}',
                                  (_source!['headers'] as List)[index]
                                      .toString(),
                                  width: 170,
                                ),
                            ],
                            rows: _slice(sourceRows, _sourcePage),
                            idOf: (row) => '${row['sourceRow']}',
                            page: _sourcePage,
                            pages: (sourceRows.length / 50).ceil(),
                            onPage: (page) =>
                                setState(() => _sourcePage = page),
                            busy: _busy,
                            canOpen: (_) => !_busy,
                            onOpen: (row) => setState(
                              () =>
                                  _selected = (row['sourceRow'] as num).toInt(),
                            ),
                            scope: (_source?['importId'], widget.scope),
                          ),
                        ),
                        Expanded(
                          child: financeSourceTable(
                            tableKey: 'finance.statement.compare.actual',
                            columns: [
                              financeSourceColumn(
                                '__number',
                                '实际行',
                                type: 'int',
                              ),
                              for (final column in _columns)
                                financeSourceColumn(
                                  '${column['key']}',
                                  '${column['label']}',
                                  type: column['type']?.toString() ?? 'text',
                                  width: 170,
                                ),
                            ],
                            rows: _slice(actualRows, _actualPage),
                            idOf: (row) => '${row['__number']}',
                            page: _actualPage,
                            pages: (actualRows.length / 50).ceil(),
                            onPage: (page) =>
                                setState(() => _actualPage = page),
                            busy: _busy,
                            canOpen: (_) =>
                                !_busy && !_stale && _selected != null,
                            onOpen: _assign,
                            scope: _actual?['sourceFingerprint'],
                          ),
                        ),
                        if (_result != null)
                          Expanded(
                            child: financeSourceTable(
                              tableKey: 'finance.statement.compare.differences',
                              columns: [
                                financeSourceColumn(
                                  'sourceRow',
                                  '原文件行',
                                  type: 'int',
                                ),
                                financeSourceColumn(
                                  'reportRowNumber',
                                  '实际行',
                                  type: 'int',
                                ),
                                financeSourceColumn('label', '列名'),
                                financeSourceColumn('source', '原值', width: 250),
                                financeSourceColumn(
                                  'actual',
                                  '实际值',
                                  width: 250,
                                ),
                                financeSourceColumn(
                                  'status',
                                  '结果',
                                  value: (row) => row['status'] == 'PENDING'
                                      ? '待核对'
                                      : '不一致',
                                ),
                              ],
                              rows: _slice(differences, _resultPage),
                              idOf: (row) =>
                                  '${row['sourceRow']}:${row['column']}',
                              page: _resultPage,
                              pages: (differences.length / 50).ceil(),
                              onPage: (page) =>
                                  setState(() => _resultPage = page),
                              scope: _mappingFingerprint,
                            ),
                          ),
                      ],
                    ),
            ),
            if (_result != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  '已比对${_mapping.length}行，差异或待核对${differences.length}格；未对应原行${(_result!['unmappedSourceRows'] as List?)?.length ?? 0}，未对应实际行${(_result!['unmappedActualRows'] as List?)?.length ?? 0}。比对不写库存、银行、往来或总账。',
                ),
              ),
            UtenDialogActions(
              children: [
                if (permissions.contains(Perm.paymentStyleEdit))
                  UtenButton(
                    type: UtenButtonType.secondary,
                    onPressed: _busy || _loading || _mapping.isNotEmpty
                        ? null
                        : _upload,
                    child: const Text('导入原表'),
                  ),
                UtenButton(
                  type: UtenButtonType.secondary,
                  onPressed: _busy || _source == null ? null : _refresh,
                  child: const Text('刷新实际原件'),
                ),
                if (_selected != null && !_stale)
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () {
                            setState(() => _mapping.remove(_selected));
                            markFormDraftChanged();
                          },
                    child: const Text('解除选中原行对应'),
                  ),
                if (_stale)
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () {
                            setState(() {
                              _mapping.clear();
                              _mappingFingerprint =
                                  _actual?['sourceFingerprint']?.toString();
                              _result = null;
                            });
                            markFormDraftChanged();
                          },
                    child: const Text('重新对应当前原表'),
                  ),
                UtenButton(
                  onPressed: _busy || _mapping.isEmpty || _stale
                      ? null
                      : _compare,
                  isLoading: _busy,
                  child: const Text('逐列比对'),
                ),
                TextButton(
                  onPressed: _busy ? null : _close,
                  child: const Text('关闭'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
