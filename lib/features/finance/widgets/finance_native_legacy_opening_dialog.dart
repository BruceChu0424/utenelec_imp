import '../../../components/inputs/uten_selected_value_theme.dart';
import '../shared/finance_workbench_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/paging/complete_paged_snapshot.dart';
import '../../../shared/paging/read_view_activity.dart';
import '../../../shared/paging/scoped_paged_read.dart'
    show pagedReadAccessDenied;
import '../../../core/network/business_precision.dart';
import '../../../core/network/business_submission_headers.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import 'finance_source_table.dart';

const _path = '/finance/native-legacy-openings';
Future<void> showFinanceNativeLegacyOpeningDialog(
  BuildContext context, {
  required String ledgerId,
  String? resumeDraftId,
}) => showFinanceWorkbenchPanel<void>(
  context: context,
  builder: (_) =>
      _LegacyOpening(ledgerId: ledgerId, resumeDraftId: resumeDraftId),
);

class _LegacyOpening extends ConsumerStatefulWidget {
  const _LegacyOpening({required this.ledgerId, this.resumeDraftId});
  final String ledgerId;
  final String? resumeDraftId;
  @override
  ConsumerState<_LegacyOpening> createState() => _LegacyOpeningState();
}

class _Share extends EditableGridRow {
  _Share(this.source, String local, String original)
    : local = TextEditingController(text: local),
      original = TextEditingController(text: original);
  final Map<String, dynamic> source;
  final TextEditingController local, original;
  String get key => _key(source);
  @override
  void dispose() {
    local.dispose();
    original.dispose();
    super.dispose();
  }
}

class _LegacyOpeningState extends ConsumerState<_LegacyOpening>
    with FormDraftMixin<_LegacyOpening>, ReadViewActivityMixin<_LegacyOpening> {
  @override
  Future<void> onReadViewResumed() => _load();
  late final ApiClient _api;
  late final int _epoch;
  final _reference = TextEditingController();
  final _grid = UtenEditableGridController<_Share>();
  Map<String, dynamic> _data = {};
  final Map<String, String> _currencyLabels = {};
  List<Map<String, dynamic>> _rows = [];
  Map<String, dynamic>? _pending, _actionPending;
  Map<String, dynamic> _pendingHeaders = {}, _actionHeaders = {};
  String? _pendingActor, _actionActor;
  BusinessPrecisionTransport? _sentTransport;
  int _generation = 0;
  bool _busy = false, _unknown = false, _readDenied = false;
  String? _error, _unknownAction;
  bool get _read => ref.read(currentPermissionsProvider).containsAll({
    'finance_report:view',
    'finance:view:all',
    'ar_ap_ledger:view',
  });
  bool get _frozen => _pending != null || _actionPending != null;
  bool get _current =>
      mounted &&
      _read &&
      formDraftIdentityIsCurrent &&
      _epoch == ref.read(exportContextEpochProvider) &&
      identical(_api, ref.read(apiClientProvider));
  bool get _write =>
      ref.read(currentPermissionsProvider).contains('payment_style:edit') &&
      ref.read(currentPermissionsProvider).contains('finance_post:execute');
  bool get _editable =>
      _current &&
      !_readDenied &&
      _write &&
      !_busy &&
      !_frozen &&
      !_unknown &&
      _unknownAction == null;
  Map<String, dynamic> get _legacy => _data['legacy'] is Map<String, dynamic>
      ? _data['legacy'] as Map<String, dynamic>
      : {};
  Map<String, dynamic>? get _review => _data['review'] is Map<String, dynamic>
      ? _data['review'] as Map<String, dynamic>
      : null;
  List<Map<String, dynamic>> get _reviews =>
      _review == null ? _maps(_data['reviews']) : [_review!];
  @override
  FormDraftSpec get formDraftSpec => FormDraftCatalog.financeNativeLegacyOpening
      .spec(title: '旧未结接续', routeParameters: {'ledgerId': widget.ledgerId});
  @override
  bool get formDraftUsesRouterGuard => false;
  @override
  bool get formDraftUseCurrentRoute => false;
  @override
  bool get formDraftBusy => _busy;
  @override
  String? get formDraftResumeId => widget.resumeDraftId;
  @override
  bool get formDraftCanReplaySubmission =>
      _pending != null || _actionPending != null;
  @override
  Iterable<Listenable> get formDraftListenables => [
    _reference,
    _grid,
    for (final row in _grid.rows) ...[row.local, row.original],
  ];
  @override
  Map<String, dynamic> captureFormDraft() => {
    'ledgerId': widget.ledgerId,
    'data': _data,
    'rows': _rows,
    'currencyLabels': _currencyLabels,
    'pendingHeaders': businessSubmissionHeaders(_pendingHeaders),
    'actionHeaders': businessSubmissionHeaders(_actionHeaders),
    'pendingActor': _pendingActor,
    'actionActor': _actionActor,
    'reference': _reference.text,
    'shares': [
      for (final row in _grid.rows)
        {
          'source': row.source,
          'local': row.local.text,
          'original': row.original.text,
        },
    ],
    'pending': _pending,
    'actionPending': _actionPending,
    'unknown': _unknown,
    'unknownAction': _unknownAction,
    if (_unknown) formDraftUnknownSubmissionKey: true,
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    if (data['ledgerId'] != widget.ledgerId) {
      throw StateError('旧往来草稿的真实UUID不一致');
    }
    _data = Map<String, dynamic>.from(data['data'] as Map? ?? {});
    _rows = _maps(data['rows']);
    _currencyLabels.clear();
    for (final e in (data['currencyLabels'] as Map? ?? {}).entries) {
      _currencyLabels[e.key.toString()] = e.value.toString();
    }
    _pendingHeaders = businessSubmissionHeaders(data['pendingHeaders']);
    _actionHeaders = businessSubmissionHeaders(data['actionHeaders']);
    _pendingActor =
        data['pendingActor']?.toString() ??
        ref.read(authenticatedScopeProvider)?.userId;
    _actionActor =
        data['actionActor']?.toString() ??
        ref.read(authenticatedScopeProvider)?.userId;
    final shares = <_Share>[];
    for (final row in _maps(data['shares'])) {
      if (row['source'] is! Map<String, dynamic>) throw StateError('原期初分配身份缺失');
      shares.add(
        _Share(
          row['source'] as Map<String, dynamic>,
          row['local']?.toString() ?? '',
          row['original']?.toString() ?? '',
        ),
      );
    }
    _grid.replaceAll(shares);
    _reference.text = data['reference']?.toString() ?? '';
    _pending = data['pending'] is Map<String, dynamic>
        ? data['pending'] as Map<String, dynamic>
        : null;
    _actionPending = data['actionPending'] is Map<String, dynamic>
        ? data['actionPending'] as Map<String, dynamic>
        : null;
    _unknown =
        data['unknown'] == true || data[formDraftUnknownSubmissionKey] == true;
    _unknownAction = data['unknownAction']?.toString();
    if (_unknown && _actionPending != null) {
      _unknownAction = _actionPending!['id']?.toString();
      _unknown = false;
    }
    if (_pending != null) {
      if (!Uuid.isValidUUID(
        fromString: _pending!['requestId']?.toString() ?? '',
      )) {
        throw StateError('原接续提交编号缺失');
      }
      for (final row in _maps(_pending!['shares'])) {
        if (row['ledgerId'] != widget.ledgerId) {
          throw StateError('未知接续请求的原往来范围不一致');
        }
      }
    }
    if (_unknownAction != null &&
        (_actionPending?['id'] != _unknownAction ||
            !Uuid.isValidUUID(fromString: _unknownAction!))) {
      throw StateError('原审核/撤回操作编号缺失');
    }
  }

  @override
  void initState() {
    super.initState();
    _api = ref.read(apiClientProvider);
    _epoch = ref.read(exportContextEpochProvider);
    startFormDraftIdentityGuard();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!_current) return;
      await initializeFormDraft();
      if (!_current) return;
      if (_frozen) {
        setState(() {});
        return;
      }
      await _load();
    });
  }

  @override
  void dispose() {
    _reference.dispose();
    _grid.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!_current || _busy || _unknown || _frozen || _unknownAction != null) {
      return;
    }
    final generation = ++_generation;
    bool current() => _current && generation == _generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final loaded = await readViewActivity.runRead(current, () async {
        Map<String, dynamic> first = {};
        final complete = await loadCompletePagedResult<Map<String, dynamic>>(
          isCurrent: current,
          idOf: (row) {
            final ref = row['reference'];
            return ref is Map &&
                    ref['entryId']?.toString().isNotEmpty == true &&
                    ref['allocationNo'] != null
                ? (ref['entryId'], ref['allocationNo'])
                : null;
          },
          loadPage: (batch, size) async {
            final value = await _api.get(
              '$_path/targets/${widget.ledgerId}',
              query: {'page': batch, 'size': size},
            );
            if (batch == 1) first = value;
            final sources = value['sources'];
            if (sources is! Map) {
              if (value['binding'] == null) {
                throw const FormatException('原期初来源读取不完整');
              }
              return PagedResult(
                items: const [],
                page: batch,
                size: size,
                total: 0,
                totalPages: 0,
              );
            }
            return PagedResult.fromJsonResponsive({
              ...Map<String, dynamic>.from(sources),
              'readScopeVersion': value['readScopeVersion'],
            }, (row) => row);
          },
        );
        Map<String, String> currencies = {};
        if (_currencyLabels.isEmpty) {
          final choices = await _api.get(
            '/finance/native-posting-accounts/choices',
          );
          currencies = {
            for (final currency in _maps(choices['currencies']))
              '${currency['id']}': '${currency['code']} ${currency['name']}',
          };
        }
        return (data: first, rows: complete.items, currencies: currencies);
      });
      if (!_current || generation != _generation) return;
      setState(() {
        _data = loaded.data;
        _rows = loaded.rows;
        _currencyLabels.addAll(loaded.currencies);
        _readDenied = false;
      });
    } catch (e) {
      if (isRetiredViewRead(e)) return;
      if (_current && generation == _generation) {
        setState(() {
          _error = _message(e);
          if (pagedReadAccessDenied(e)) {
            _readDenied = _data.isNotEmpty || _grid.rows.isNotEmpty;
            _data = {};
            _rows = [];
          }
        });
      }
    } finally {
      if (_current && generation == _generation) setState(() => _busy = false);
    }
  }

  void _select(Set<String> ids) {
    if (!_editable || !_write) return;
    final known = {for (final row in _grid.rows) row.key: row};
    final selected = <_Share>[];
    for (final id in ids) {
      if (known.containsKey(id)) {
        selected.add(known[id]!);
        continue;
      }
      final matches = _rows.where((r) => _key(r) == id);
      if (matches.isNotEmpty) {
        selected.add(
          _Share(
            matches.first,
            selected.isEmpty && _grid.rows.isEmpty
                ? '${_legacy['local'] ?? ''}'
                : '0',
            selected.isEmpty && _grid.rows.isEmpty
                ? '${_legacy['original'] ?? ''}'
                : '0',
          ),
        );
      }
    }
    _grid.clearSelection();
    _grid.swapRows(selected);
    for (final row in known.values) {
      if (!ids.contains(row.key)) {
        row.dispose();
      }
    }
    setState(() {});
    markFormDraftChanged();
  }

  Future<void> _submit() async {
    if (!_current ||
        (_readDenied && _pending == null) ||
        !_write ||
        _busy ||
        _unknownAction != null ||
        _actionPending != null) {
      return;
    }
    if (_pending == null) {
      if (_grid.rows.isEmpty || _reference.text.trim().isEmpty) {
        setState(() => _error = '请选择原账套期初分配并填写接续依据。');
        return;
      }
      _pendingActor = ref.read(authenticatedScopeProvider)?.userId;
      _pendingHeaders = {};
      _pending = {
        'requestId': const Uuid().v4(),
        'sourceReference': _reference.text.trim(),
        'shares': [
          for (final row in _grid.rows)
            {
              'ledgerId': widget.ledgerId,
              'entryId': (row.source['reference'] as Map)['entryId'],
              'allocationNo': (row.source['reference'] as Map)['allocationNo'],
              'amountLocal': row.local.text,
              'nativeOriginal': row.original.text,
            },
        ],
      };
    }
    final wasUnknown = _unknown;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final scope = await captureFormDraftRequestScope();
      await runFormDraftSubmission(() {
        _sentTransport = BusinessPrecisionTransport.current;
        if (!wasUnknown) _pendingHeaders = _headers(_sentTransport);
        return scope.run(
          () => _api.post(
            _path,
            body: _pending,
            headers: businessSubmissionHeaders(_pendingHeaders),
          ),
        );
      });
      if (_current) {
        setState(() {
          _unknown = false;
        });
        await completeFormDraft();
        if (mounted) Navigator.pop(context);
      }
    } catch (e) {
      if (_sentTransport != null) _pendingHeaders = _headers(_sentTransport);
      if (_current) {
        setState(() {
          _unknown = wasUnknown || !_rejected(e);
          if (!_unknown && !formDraftHasUnknownSubmission) {
            _pending = null;
            _pendingHeaders = {};
            _pendingActor = null;
          }
          _error =
              '${_message(e)}${_unknown ? '；原份额与请求编号已保留，请核对并重试同一提交。' : ''}';
        });
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _act(Map<String, dynamic> review, bool withdraw) async {
    if (!_current || _readDenied || _busy || _unknown || !_write) return;
    final id = '${review['id']}';
    if (_unknownAction != null && _unknownAction != id) return;
    if (_unknownAction == id && _actionPending != null) {
      await _sendAction();
      return;
    }
    if (_grid.rows.isNotEmpty || _reference.text.isNotEmpty) {
      setState(() => _error = '请先保存当前接续内容，再处理原审核记录');
      return;
    }
    Map<String, dynamic> detail;
    setState(() => _busy = true);
    try {
      detail = await _api.get('$_path/$id');
    } catch (e) {
      if (_current) setState(() => _error = _message(e));
      return;
    } finally {
      if (_current) setState(() => _busy = false);
    }
    if (!mounted || !_current) return;
    final plan = detail['plan'] as Map?;
    final targets = {
      for (final t in _maps(plan?['targets']))
        if (t['legacy'] is Map)
          '${(t['legacy'] as Map)['ledgerId']}': t['legacy'] as Map,
    };
    final evidence = <Map<String, dynamic>>[
      for (final item in _maps(plan?['items']))
        {
          ...item['request'] as Map<String, dynamic>,
          'code': (item['source'] as Map?)?['accountCode'],
          'name': (item['source'] as Map?)?['accountName'],
          'financialOriginal': item['financialOriginal'],
          'oldNo':
              targets['${(item['request'] as Map?)?['ledgerId']}']?['billNo'],
        },
    ];
    final reason = TextEditingController();
    final sourceReference = TextEditingController(
      text: detail['source_reference']?.toString() ?? '',
    );
    final label = withdraw ? '撤回接续' : '审核接续';
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => UtenAlertDialog(
        title: Text(label),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            UtenInput(
              label: '接续依据',
              controller: sourceReference,
              enabled: false,
            ),
            SizedBox(
              width: 850,
              height: 250,
              child: financeSourceTable(
                tableKey: 'finance.native-legacy-openings.confirm',
                columns: [
                  financeSourceColumn('oldNo', '旧单号', width: 200),
                  financeSourceColumn('code', '财务科目'),
                  financeSourceColumn('name', '原科目名称', width: 200),
                  financeSourceColumn('amountLocal', '本币份额', type: 'money'),
                  financeSourceColumn(
                    'nativeOriginal',
                    '旧记录原币份额',
                    type: 'money',
                  ),
                  financeSourceColumn(
                    'financialOriginal',
                    '原金融原币份额',
                    type: 'money',
                    value: (r) => r['financialOriginal']?.toString() ?? '待核',
                  ),
                ],
                rows: evidence,
                idOf: (r) =>
                    '${r['ledgerId']}|${r['entryId']}|${r['allocationNo']}',
                scope: (_epoch, id),
              ),
            ),
            if (withdraw) UtenInput(label: '撤回依据', controller: reason),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          UtenButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(label),
          ),
        ],
      ),
    );
    if (yes != true || !_current) {
      reason.dispose();
      sourceReference.dispose();
      return;
    }
    final input = reason.text;
    reason.dispose();
    sourceReference.dispose();
    if (withdraw && input.trim().isEmpty) {
      setState(() => _error = '请填写撤回依据；存在后续实际结算时须先按原顺序撤回。');
      return;
    }
    _actionActor = ref.read(authenticatedScopeProvider)?.userId;
    _actionHeaders = {};
    _actionPending = {
      'id': id,
      'withdraw': withdraw,
      'body': withdraw ? {'reason': input} : null,
    };
    await _sendAction();
  }

  Future<void> _sendAction() async {
    if (!_current || !_write || _busy || _actionPending == null) return;
    final command = _actionPending!;
    final id = command['id'] as String;
    final withdraw = command['withdraw'] == true;
    setState(() {
      _busy = true;
      _error = null;
      _unknownAction = id;
    });
    try {
      final scope = await captureFormDraftRequestScope();
      await runFormDraftSubmission(() {
        _sentTransport = BusinessPrecisionTransport.current;
        if (_actionHeaders.isEmpty) _actionHeaders = _headers(_sentTransport);
        return scope.run(
          () => _api.post(
            '$_path/$id/${withdraw ? 'withdraw' : 'approve'}',
            body: command['body'],
            headers: businessSubmissionHeaders(_actionHeaders),
          ),
        );
      });
      if (_current) {
        await completeFormDraft();
        if (mounted) Navigator.pop(context);
      }
    } catch (e) {
      if (_sentTransport != null) _actionHeaders = _headers(_sentTransport);
      if (_current) {
        setState(() {
          if (_rejected(e) && !formDraftHasUnknownSubmission) {
            _unknownAction = null;
            _actionPending = null;
          }
          _error =
              '${_message(e)}${_unknownAction == null ? '' : '；请刷新核对或重试同一记录。'}';
        });
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Map<String, dynamic> _headers(BusinessPrecisionTransport? t) =>
      businessSubmissionHeaders({
        if (t?.encodedHeader != null) businessPrecisionHeader: t!.encodedHeader,
      });
  Future<void> _readReceipt() async {
    if (!_current || _busy || !_frozen) return;
    final pending = _pending, action = _actionPending;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final scope = await captureFormDraftRequestScope();
      final request = pending?['requestId']?.toString();
      final actionName = action?['withdraw'] == true ? 'withdraw' : 'approve';
      final path = request != null
          ? '$_path/operations/$request'
          : '$_path/${action!['id']}/receipts/$actionName';
      final receipt = await scope.run(() => _api.get(path));
      if (!_current) return;
      final expectedActor = pending != null ? _pendingActor : _actionActor;
      final owner = ref.read(authenticatedScopeProvider)?.userId;
      if (receipt['receiptActorId'] == null ||
          expectedActor != null && receipt['receiptActorId'] != expectedActor ||
          owner != null && receipt['receiptActorId'] != owner ||
          request != null && receipt['receiptRequestId'] != request ||
          request == null &&
              (receipt['id'] != action!['id'] ||
                  receipt['receiptAction'] != actionName)) {
        throw ApiException(
          'LEGACY_RECEIPT_MISMATCH',
          '原接续回执与本人、原编号或原操作不一致，原请求继续保留',
        );
      }
      final targets = _maps((receipt['plan'] as Map?)?['targets']);
      if (!targets.any(
        (t) => (t['legacy'] as Map?)?['ledgerId'] == widget.ledgerId,
      )) {
        throw ApiException(
          'LEGACY_RECEIPT_SCOPE_MISMATCH',
          '本人原回执与此旧往来不一致，原请求继续保留',
        );
      }
      await completeFormDraft();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (_current) setState(() => _error = _message(e));
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _close() async {
    if (_busy) return;
    if (await confirmFormDraftExit() && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(exportContextEpochProvider);
    ref.watch(apiClientProvider);
    ref.watch(currentPermissionsProvider);
    if (!_current || _readDenied) {
      return withFormDraft(
        UtenAlertDialog(
          showCloseButton: true,
          onClose: () => Navigator.pop(context),

          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('旧未结接续'),
              UtenFieldHintIcon(
                info: '身份、权限或公司数据范围已变化。原私有草稿保留，请重新进入。',
                errorMessage: _error,
              ),
            ],
          ),
        ),
      ).withSelectedValueHighlights();
    }
    final bound = _data['binding'] != null;
    final columns = <EditableGridColumn<_Share>>[
      EditableGridColumn(
        key: 'code',
        label: '财务科目',
        width: 220,
        textOf: (r) =>
            '${r.source['accountCode']} ${r.source['accountName'] ?? ''}',
        cellBuilder: (_, r) =>
            Text('${r.source['accountCode']} ${r.source['accountName'] ?? ''}'),
      ),
      for (final local in [true, false])
        EditableGridColumn(
          key: local ? 'local' : 'original',
          label: local ? '本币份额' : '旧系统已核原币份额',
          width: 240,
          textOf: (r) => (local ? r.local : r.original).text,
          exactValueOf: (r) => (local ? r.local : r.original).text,
          listenableOf: (r) => local ? r.local : r.original,
          cellBuilder: (_, r) => UtenInput(
            key: ValueKey(
              'legacy-opening-${local ? 'local' : 'original'}-${r.key}',
            ),
            controller: local ? r.local : r.original,
            enabled: _editable && _write,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => markFormDraftChanged(),
          ),
        ),
    ];
    return withFormDraft(
      Stack(
        children: [
          UtenDialogFrame(
            maxWidth: 1200,
            fillHeight: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                UtenDialogHeader(
                  title: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('旧未结接续'),
                      UtenFieldHintIcon(
                        errorMessage: _error,
                        info:
                            '按真实供应商/客户UUID和原分录核对，不凭同名或同额猜配。金融原币未证时保持待核；旧系统原币独立记录。双审只绑定固定份额，不新增应付、总账、库存或资金；还款不释放已分份额给其他业务。',
                      ),
                    ],
                  ),
                  showCloseButton: true,
                  onClose: _busy ? null : _close,
                ),
                Padding(
                  padding: const EdgeInsets.all(UtenSpacing.s12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_legacy.isNotEmpty)
                        SizedBox(
                          height: 175,
                          child: financeSourceTable(
                            tableKey: 'finance.native-legacy-openings.legacy',
                            columns: [
                              financeSourceColumn(
                                'cutoff',
                                '旧系统截止',
                                type: 'date',
                              ),
                              financeSourceColumn(
                                'local',
                                '已核未结本币',
                                type: 'money',
                              ),
                              financeSourceColumn(
                                'currency',
                                '旧记录币别',
                                width: 220,
                              ),
                              financeSourceColumn(
                                'original',
                                '旧记录原币',
                                type: 'money',
                              ),
                            ],
                            rows: [
                              {
                                ..._legacy,
                                'currency':
                                    _currencyLabels[_legacy['currencyId']] ??
                                    '待核',
                              },
                            ],
                            idOf: (_) => widget.ledgerId,
                            scope: (_epoch, widget.ledgerId),
                          ),
                        ),
                    ],
                  ),
                ),
                if (!bound)
                  Expanded(
                    child: financeSourceTable(
                      tableKey: 'finance.native-legacy-openings.sources',
                      columns: [
                        financeSourceColumn('accountCode', '财务科目代码'),
                        financeSourceColumn('accountName', '原科目名称', width: 220),
                        financeSourceColumn(
                          'effectiveFrom',
                          '原期初日期',
                          type: 'date',
                        ),
                        financeSourceColumn(
                          'accountingCurrencyId',
                          '会计币别属性',
                          value: (r) =>
                              _currencyLabels[r['accountingCurrencyId']] ??
                              '待核',
                        ),
                        financeSourceColumn(
                          'amountLocal',
                          '原本币金额',
                          type: 'money',
                        ),
                        financeSourceColumn(
                          'amountOriginal',
                          '原金融原币',
                          type: 'money',
                          value: (r) => r['amountOriginal']?.toString() ?? '待核',
                        ),
                        financeSourceColumn(
                          'sourceName',
                          '原辅助项目',
                          value: (r) => (r['auxiliary'] as Map?)?['sourceName']
                              ?.toString(),
                        ),
                      ],
                      rows: _rows,
                      idOf: _key,
                      busy: _busy,
                      error: _rows.isEmpty ? _error : null,
                      retry: _load,
                      scope: (_epoch, widget.ledgerId),
                      selectable: _editable && _write,
                      selectedIds: _grid.rows.map((r) => r.key).toSet(),
                      onSelectedIdsChanged: _select,
                    ),
                  ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(UtenSpacing.s12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (!bound && (_write || _frozen)) ...[
                          UtenEditableGrid<_Share>(
                            tableKey: 'finance.native-legacy-openings.shares',
                            controller: _grid,
                            columns: columns,
                            showAddRow: false,
                            showRowDelete: false,
                            showRemoveRowsAction: false,
                            showColumnSettings: false,
                            stickyHeader: false,
                            selectionEnabled: _editable,
                          ),
                          const SizedBox(height: 12),
                          UtenInput(
                            label: '原期初与旧未结接续依据',
                            controller: _reference,
                            enabled: _editable,
                            maxLines: 2,
                            inputFormatters: [
                              LengthLimitingTextInputFormatter(2000),
                            ],
                            onChanged: (_) => markFormDraftChanged(),
                          ),
                        ],
                        if (_reviews.isNotEmpty)
                          SizedBox(
                            height: 240,
                            child: financeSourceTable(
                              tableKey:
                                  'finance.native-legacy-openings.reviews',
                              columns: [
                                financeSourceColumn('status', '状态'),
                                financeSourceColumn(
                                  'source_reference',
                                  '接续依据',
                                  width: 480,
                                ),
                              ],
                              rows: _reviews,
                              idOf: (r) => '${r['id']}',
                              onOpen: (r) {
                                if (r['status'] == 'DRAFT') {
                                  _act(r, false);
                                } else if (r['status'] == 'APPROVED') {
                                  _act(r, true);
                                }
                              },
                              scope: (_epoch, widget.ledgerId),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                UtenDialogActions(
                  children: [
                    UtenButton(
                      onPressed: _busy || _unknown || _frozen
                          ? null
                          : () => _load(),
                      child: const Text('刷新核对'),
                    ),

                    if (_frozen)
                      UtenButton(
                        onPressed: _busy ? null : _readReceipt,
                        child: const Text('只读核对本人原结果'),
                      ),
                    if (!bound && _write)
                      UtenButton(
                        onPressed: _busy || _unknownAction != null
                            ? null
                            : _submit,
                        isLoading: _busy,
                        child: Text(_unknown ? '核对并重试原提交' : '保存待审核接续'),
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (_busy)
            const UtenBusyOverlay(
              title: '正在核对旧未结接续',
              showDoNotLeaveHint: false,
            ),
        ],
      ),
    ).withSelectedValueHighlights();
  }
}

String _key(Map<String, dynamic> row) {
  final ref = row['reference'] as Map?;
  return '${ref?['entryId']}|${ref?['allocationNo']}';
}

List<Map<String, dynamic>> _maps(dynamic rows) => [
  for (final r in rows as List? ?? [])
    if (r is Map<String, dynamic>) r,
];
String _message(Object e) => e is ApiException ? e.message : '操作未完成，请核对网络后重试';
bool _rejected(Object e) =>
    e is ApiException &&
    e.hasResponseCode &&
    (e.httpStatus ?? 0) >= 400 &&
    (e.httpStatus ?? 0) < 500 &&
    e.httpStatus != 408;
