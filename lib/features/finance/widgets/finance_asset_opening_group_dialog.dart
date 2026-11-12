import '../../../components/inputs/uten_selected_value_theme.dart';
import '../shared/finance_complete_summary_read.dart';
import 'finance_summary_scope_field.dart';
import '../../../shared/paging/read_view_activity.dart';
import '../shared/finance_workbench_panel.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import '../../../shared/paging/complete_paged_snapshot.dart';
import '../../../shared/models/paged_result.dart';
import '../shared/finance_template_source_upload.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_import_button.dart';
import '../../../components/buttons/uten_refresh_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_action_overflow.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../components/layout/uten_segment_row.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/performance/ui_work_budget.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/ui/human_error_message.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/auth/read_owner_fence.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../config/finance_requirement_names.dart';
import '../models/finance_asset_models.dart';
import 'finance_asset_form.dart';
import 'finance_asset_detail.dart';
import 'finance_asset_ui.dart';
import 'finance_entry_file_picker.dart';
import 'finance_template_input_dialog.dart';

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
List<Map<String, dynamic>> _maps(Object? value) => [
  if (value is List)
    for (final row in value)
      if (row is Map) Map<String, dynamic>.from(row),
];
String _cell(Map<String, dynamic> row, int column) {
  for (final cell in _maps(row['cells'])) {
    if (cell['column'] == column) {
      return (cell['number'] ?? cell['text'] ?? '').toString();
    }
  }
  return '';
}

const _states = {
  'SUBMITTED': '待另一人复核',
  'APPROVED': '已复核',
  'REVOKE_PENDING': '撤销待另一人复核',
  'REVOKED': '已撤销',
};
const _templates = {
  'depreciation': FinanceRequirementNames.depreciation,
  'amortization': FinanceRequirementNames.amortization,
  'depreciationCompleted': FinanceRequirementNames.depreciationCompleted,
};

/// The original table is retained on the server; drafts retain only identities,
/// explicit row mappings and one frozen operation, never the worksheet body.
Future<bool> showFinanceAssetOpeningGroupDialog(
  BuildContext context, {
  String template = 'depreciation',
  String? period,
  String? initialGroupId,
  String? initialSourceImportId,
  String? resumeDraftId,
}) async =>
    await showFinanceWorkbenchPanel<bool>(
      context: context,
      builder: (_) => UtenDialogFrame(
        child: SizedBox(
          width: 1380,
          height: MediaQuery.sizeOf(context).height * .92,
          child: FinanceAssetOpeningGroupSurface(
            template: template,
            period: period,
            initialGroupId: initialGroupId,
            initialSourceImportId: initialSourceImportId,
            resumeDraftId: resumeDraftId,
          ),
        ),
      ),
    ) ??
    false;

class FinanceAssetOpeningGroupSurface extends ConsumerStatefulWidget {
  const FinanceAssetOpeningGroupSurface({
    super.key,
    this.template = 'depreciation',
    this.period,
    this.initialGroupId,
    this.initialSourceImportId,
    this.resumeDraftId,
  });
  final String template;
  final String? period, initialGroupId, initialSourceImportId, resumeDraftId;
  @override
  ConsumerState<FinanceAssetOpeningGroupSurface> createState() =>
      _FinanceAssetOpeningGroupSurfaceState();
}

class _Member extends EditableGridRow {
  _Member(this.sourceRow, {Map<String, dynamic>? data}) {
    asset = _map(data?['asset']);
    remaining.text = data?['remainingMonths']?.toString() ?? '';
  }
  final int sourceRow;
  Map<String, dynamic> asset = {};
  final remaining = TextEditingController();
  final changed = ValueNotifier<int>(0);
  Map<String, dynamic> capture() => {
    'sourceRow': sourceRow,
    // Only a selected summary, not the original source body or approval history.
    'asset': asset,
    'remainingMonths': remaining.text,
  };
  @override
  void dispose() {
    remaining.dispose();
    changed.dispose();
    super.dispose();
  }
}

class _FinanceAssetOpeningGroupSurfaceState
    extends ConsumerState<FinanceAssetOpeningGroupSurface>
    with FormDraftMixin<FinanceAssetOpeningGroupSurface> {
  final _period = TextEditingController(),
      _sourceId = TextEditingController(),
      _groupLookup = TextEditingController(),
      _voucherNo = TextEditingController(),
      _reason = TextEditingController();
  final _members = UtenEditableGridController<_Member>();
  final _sourceRows = <int, Map<String, dynamic>>{};
  final _selectedEntries = <String>{};
  List<Map<String, dynamic>> _originalRows = [], _groups = [], _vouchers = [];
  Map<String, dynamic>? _source, _group, _pending;
  String _template = 'depreciation', _requestId = const Uuid().v4();
  String? _primaryVoucher, _error;
  int _tab = 0, _read = 0;
  bool _busy = false, _loading = true, _reviewed = false;
  FinanceSummaryScope _groupsScope = FinanceSummaryScope.active;
  int _groupsRead = 0;
  bool get _deferred => _template == 'amortization';
  FinanceAssetLedger get _ledger => _deferred
      ? FinanceAssetLedger.deferredExpense
      : FinanceAssetLedger.fixedAsset;
  String get _objectType => _ledger.apiValue;
  String get _state => _group?['status']?.toString() ?? 'DRAFT';
  String? get _actor => ref.read(authenticatedScopeProvider)?.userId;
  bool _permission(String permission) =>
      ref.read(authenticatedScopeProvider)?.readOnly == false &&
      ref.read(currentPermissionsProvider).contains(permission);
  bool get _editable =>
      !_busy &&
      !_loading &&
      _group == null &&
      _pending == null &&
      _permission(Perm.financeAssetEdit);
  bool get _canReadGl =>
      ref.read(currentPermissionsProvider).contains(Perm.financeReportView) &&
      ref.read(currentPermissionsProvider).contains(Perm.financeViewAll);

  @override
  FormDraftSpec get formDraftSpec => FormDraftCatalog.financeAssetOpeningGroup
      .spec(title: '${_templates[_template]}原表接续');
  @override
  bool get formDraftUsesRouterGuard => false;
  @override
  bool get formDraftUseCurrentRoute => false;
  @override
  String? get formDraftResumeId => widget.resumeDraftId;
  @override
  bool get formDraftBusy => _busy;
  @override
  bool get formDraftCanReplaySubmission => _pending != null;
  @override
  Iterable<Listenable> get formDraftListenables => [
    _period,
    _sourceId,
    _groupLookup,
    _voucherNo,
    _reason,
    _members,
    for (final row in _members.rows) row.remaining,
  ];
  @override
  Map<String, dynamic> captureFormDraft() => {
    'schema': 1,
    'template': _template,
    'period': _period.text,
    'sourceImportId': _source?['importId'] ?? _sourceId.text,
    'groupId': _group?['id'],
    'groupLookup': _groupLookup.text,
    'requestId': _requestId,
    'reason': _reason.text,
    'voucherNo': _voucherNo.text,
    'voucherIds': [for (final v in _vouchers) v['id']],
    'voucherReferences': [
      for (final v in _vouchers) {'id': v['id'], 'voucherNo': v['voucherNo']},
    ],
    'entryIds': _selectedEntries.toList(),
    'primaryVoucherId': _primaryVoucher,
    'members': [for (final row in _members.rows) row.capture()],
    'pending': _pending,
    'reviewed': _reviewed,
    'tab': _tab,
  };

  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    if (!_templates.containsKey(data['template']) ||
        data['requestId'] is! String ||
        !Uuid.isValidUUID(fromString: data['requestId'] as String)) {
      throw StateError('接续草稿的来源类型或原请求编号无效');
    }
    _template = data['template'] as String;
    _requestId = data['requestId'] as String;
    _period.text = data['period']?.toString() ?? '';
    _sourceId.text = data['sourceImportId']?.toString() ?? '';
    _groupLookup.text = data['groupLookup']?.toString() ?? '';
    _reason.text = data['reason']?.toString() ?? '';
    _voucherNo.text = data['voucherNo']?.toString() ?? '';
    _primaryVoucher = data['primaryVoucherId']?.toString();
    _selectedEntries
      ..clear()
      ..addAll((data['entryIds'] as List? ?? []).map((v) => v.toString()));
    _members.replaceAll([
      for (final row in _maps(data['members']))
        _Member((row['sourceRow'] as num).toInt(), data: row),
    ]);
    _pending = data['pending'] is Map ? _map(data['pending']) : null;
    if (_pending != null) {
      final action = _pending!['action'];
      if (!{'create', 'approve', 'revoke', 'approve-revoke'}.contains(action) ||
          _pending!['actorId'] != _actor ||
          (action == 'create' &&
              (_map(_pending!['body'])['requestId'] != _requestId ||
                  _map(_pending!['body'])['sourceImportId'] !=
                      _sourceId.text))) {
        throw StateError('原提交的动作、来源或登录人不一致');
      }
    }
    _tab = ((data['tab'] as num?)?.toInt() ?? 0).clamp(0, 3);
    _reviewed = false; // Re-read live member versions before a new submission.
    try {
      if (data['groupId'] is String) {
        await _loadGroup(data['groupId'] as String, hydrate: false);
      } else if (_sourceId.text.isNotEmpty) {
        await _loadSource(_sourceId.text, hydrate: false);
        if (_canReadGl) {
          final scope = await captureFormDraftRequestScope();
          for (final v in _maps(data['voucherReferences'])) {
            final result = await scope.run(
              () => ref
                  .read(apiClientProvider)
                  .get(
                    '/finance/asset-opening-groups/vouchers',
                    query: {'voucherNo': v['voucherNo']},
                  ),
            );
            if (!mounted || !scope.isCurrent || !formDraftIdentityIsCurrent) {
              return;
            }
            final same = _maps(
              result['items'],
            ).where((row) => row['id'] == v['id']);
            if (same.isEmpty) {
              throw StateError('原凭证${v['voucherNo']}当前不能恢复，请核对原凭证状态');
            }
            _vouchers.add(same.single);
          }
        }
      }
    } catch (error) {
      _error = '原选择和请求已保留；原件暂未恢复：${humanErrorMessage(error) ?? '请刷新核对'}';
    }
  }

  @override
  void initState() {
    super.initState();
    _template = _templates.containsKey(widget.template)
        ? widget.template
        : 'depreciation';
    _period.text = widget.period ?? '';
    startFormDraftIdentityGuard();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  @override
  void dispose() {
    _period.dispose();
    _sourceId.dispose();
    _groupLookup.dispose();
    _voucherNo.dispose();
    _reason.dispose();
    _members.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      await _refreshGroups();
      if (widget.initialGroupId != null) {
        await _loadGroup(widget.initialGroupId!);
      } else if (widget.initialSourceImportId != null) {
        await _loadSource(widget.initialSourceImportId!);
      }
    } catch (error) {
      if (mounted && formDraftIdentityIsCurrent) {
        _error = humanErrorMessage(error) ?? '接续资料未加载';
      }
    } finally {
      if (mounted && formDraftIdentityIsCurrent) {
        await initializeFormDraft();
        if (mounted) setState(() => _loading = false);
      }
    }
  }

  void _changed() {
    _reviewed = false;
    markFormDraftChanged();
    if (mounted) setState(() {});
  }

  Future<void> _refreshGroups() async {
    final generation = ++_groupsRead, range = _groupsScope;
    final scope = await captureFormDraftRequestScope();
    final api = ref.read(apiClientProvider);
    bool current() =>
        mounted &&
        formDraftIdentityIsCurrent &&
        scope.isCurrent &&
        generation == _groupsRead &&
        range == _groupsScope &&
        identical(api, ref.read(apiClientProvider));
    final groups = await scope.run(
      () => readCompleteFinanceSummaries(
        isCurrent: current,
        idOf: (row) => row['id'],
        loadPage: (page, size, revision) => api.get(
          '/finance/asset-opening-groups/summaries',
          query: {
            'scope': range.name,
            'page': page,
            'size': size,
            'readSnapshotRevision': ?revision,
          },
        ),
      ),
    );
    if (current()) setState(() => _groups = groups);
  }

  Future<void> _changeGroupsScope(FinanceSummaryScope value) async {
    if (_busy || _loading || _pending != null || value == _groupsScope) return;
    setState(() {
      _groupsScope = value;
      _groups = [];
      _busy = true;
      _error = null;
    });
    try {
      await _refreshGroups();
    } catch (error) {
      if (mounted && formDraftIdentityIsCurrent) {
        setState(() => _error = humanErrorMessage(error) ?? '接续组读取失败，请重试');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _publishSource(
    Map<String, dynamic> source,
    int generation,
  ) async {
    if (!_templates.containsKey(source['template'])) {
      throw StateError('请选择固定资产或长期待摊原表');
    }
    final rows = <Map<String, dynamic>>[],
        indexed = <int, Map<String, dynamic>>{};
    final work = UiWorkBudget(
      maxItems: 32,
      debugLabel: 'finance.asset-opening.original-projection',
      isCurrent: () =>
          mounted && formDraftIdentityIsCurrent && generation == _read,
    );
    for (final row in _maps(source['rows'])) {
      final index = (row['sourceRow'] as num).toInt();
      indexed[index] = row;
      rows.add({
        'sourceRow': index,
        for (final cell in _maps(row['cells']))
          '${cell['column']}': cell['number'] ?? cell['text'],
        'issues': (row['issues'] as List? ?? []).join('；'),
      });
      await work.checkpoint();
    }
    work.ensureCurrent();
    setState(() {
      _source = source;
      _sourceId.text = source['importId'].toString();
      _template = source['template'].toString();
      _period.text = source['period'].toString();
      _sourceRows
        ..clear()
        ..addAll(indexed);
      _originalRows = rows;
    });
  }

  Future<void> _loadSource(String id, {bool hydrate = true}) async {
    if (!Uuid.isValidUUID(fromString: id)) throw StateError('请填写完整原表编号');
    final generation = ++_read, scope = await captureFormDraftRequestScope();
    final result = await scope.run(
      () => ref.read(apiClientProvider).get('/finance/template-imports/$id'),
    );
    if (!mounted ||
        !formDraftIdentityIsCurrent ||
        !scope.isCurrent ||
        generation != _read) {
      return;
    }
    await _publishSource(result, generation);
    if (hydrate) _changed();
  }

  Future<void> _loadGroup(String id, {bool hydrate = true}) async {
    if (!Uuid.isValidUUID(fromString: id)) {
      throw StateError('请填写完整接续组编号');
    }
    final generation = ++_read, scope = await captureFormDraftRequestScope();
    final group = await scope.run(
      () =>
          ref.read(apiClientProvider).get('/finance/asset-opening-groups/$id'),
    );
    final source = await scope.run(
      () => ref
          .read(apiClientProvider)
          .get('/finance/asset-opening-groups/$id/source'),
    );
    if (!mounted ||
        !formDraftIdentityIsCurrent ||
        !scope.isCurrent ||
        generation != _read) {
      return;
    }
    await _publishSource(source, generation);
    setState(() {
      _group = group;
      _groupLookup.text = id;
      if (hydrate) {
        _reason.clear();
        _members.replaceAll([
          for (final m in _maps(group['member_snapshot']))
            _Member(
              (m['sourceRow'] as num).toInt(),
              data: {
                'remainingMonths': m['remainingMonths'],
                'asset': {
                  'id': m['objectId'],
                  'name': m['name'],
                  'code': m['code'],
                  'version': m['row_version'],
                  'originalValue': m['original'],
                  'totalAmount': m['original'],
                  'status': m['lifecycle_status'],
                },
              },
            ),
        ]);
        _vouchers = [];
        _selectedEntries
          ..clear()
          ..addAll(
            _maps(
              group['source_entry_snapshot'],
            ).map((e) => e['id'].toString()),
          );
      }
    });
  }

  Future<void> _runRead(Future<void> Function() task) async {
    if (_busy || _loading || !formDraftIdentityIsCurrent) return;
    setState(() => _busy = true);
    try {
      await UtenBusyOverlay.run(context, title: '正在核对资产期初资料', action: task);
    } on UiWorkCancelled {
      /* Retire stale source projection. */
    } catch (error) {
      if (mounted && formDraftIdentityIsCurrent) {
        context.appApiError(error, fallback: '读取未完成，原选择已保留');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() => _runRead(() async {
    if (_group != null ||
        _pending != null ||
        !_permission(Perm.financeAssetEdit)) {
      return;
    }
    final match = RegExp(
      r'^(\d{4})-(0[1-9]|1[0-2])$',
    ).firstMatch(_period.text.trim());
    if (match == null) throw StateError('请先填写原表会计月份（YYYY-MM）');
    final scope = await captureFormDraftRequestScope();
    await saveFormDraftNow();
    final file = await UtenBusyOverlay.yieldWhile(
      () => ref.read(financeEntryFilePickerProvider)(),
    );
    if (file == null || !mounted || !scope.isCurrent) return;
    final bytes = file.bytes;
    if (!{'xls', 'xlsx'}.contains(file.extension?.toLowerCase()) ||
        bytes == null ||
        bytes.isEmpty ||
        bytes.length > 64 * 1024 * 1024) {
      throw StateError('请选择完整XLS或XLSX资产原表，最大64MB');
    }
    final generation = ++_read;
    final source = await scope.run(
      () => uploadFinanceTemplateSource(
        context: context,
        api: ref.read(apiClientProvider),
        bytes: bytes,
        asset: true,
        isCurrent: () =>
            mounted &&
            formDraftIdentityIsCurrent &&
            scope.isCurrent &&
            generation == _read,
        query: {
          'template': _template,
          'period': _period.text.trim(),
          'filename': file.name,
        },
      ),
    );
    if (source == null ||
        !mounted ||
        !formDraftIdentityIsCurrent ||
        !scope.isCurrent ||
        generation != _read) {
      return;
    }
    // Import is an immutable preview, not a business submission.
    _members.clear();
    _vouchers = [];
    _selectedEntries.clear();
    _primaryVoucher = null;
    await _publishSource(source, generation);
    _changed();
  });

  void _addRow(Map<String, dynamic> row) {
    if (!_editable) return;
    final sourceRow = (row['sourceRow'] as num).toInt();
    if (_members.rows.any((m) => m.sourceRow == sourceRow)) {
      context.appWarning('该原表行已加入成员对应');
      return;
    }
    _members.addRow(_Member(sourceRow));
    _changed();
  }

  Future<void> _chooseAsset(_Member row) async {
    if (!_editable) return;
    final scope = await captureFormDraftRequestScope();
    if (!mounted || !scope.isCurrent) return;
    final choice = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => UtenDialogFrame(
        child: SizedBox(
          width: 1000,
          height: MediaQuery.sizeOf(context).height * .8,
          child: _DraftPicker(ledger: _ledger),
        ),
      ),
    );
    if (choice == null ||
        !mounted ||
        !scope.isCurrent ||
        !formDraftIdentityIsCurrent) {
      return;
    }
    if (_members.rows.any((m) => m != row && m.asset['id'] == choice['id'])) {
      context.appWarning('该草稿已对应本组另一原表行');
      return;
    }
    row.asset = _summary(choice);
    row.changed.value++;
    _changed();
  }

  Future<void> _editAsset(_Member row) async {
    if (_group != null ||
        _pending != null ||
        !_permission(Perm.financeAssetEdit) ||
        row.asset['id'] == null) {
      return;
    }
    final scope = await captureFormDraftRequestScope();
    final value = await scope.run(
      () => ref
          .read(apiClientProvider)
          .get('${_ledger.basePath}/${row.asset['id']}'),
    );
    if (!mounted || !scope.isCurrent || !formDraftIdentityIsCurrent) return;
    final summary = FinanceAssetDetail.fromJson(value, _ledger).summary;
    await saveFormDraftNow();
    if (!mounted || !scope.isCurrent) return;
    if (await showFinanceAssetForm(
      context,
      ledger: _ledger,
      existing: summary,
    )) {
      final updated = await scope.run(
        () => ref
            .read(apiClientProvider)
            .get('${_ledger.basePath}/${row.asset['id']}'),
      );
      if (!mounted || !scope.isCurrent || !formDraftIdentityIsCurrent) return;
      row.asset = _summary(updated);
      row.changed.value++;
      _changed();
    }
  }

  Map<String, dynamic> _summary(Map<String, dynamic> value) {
    final payload = financeAssetPayload(value),
        summary = _map(financeAssetPayload(value)['summary']);
    final v = summary.isEmpty ? payload : summary;
    return {
      for (final key in [
        'id',
        'code',
        'name',
        'status',
        'lifecycleStatus',
        'version',
        'originalValue',
        'totalAmount',
        'salvageRate',
        'categoryName',
      ])
        key: v[key],
    };
  }

  Future<void> _metadata(_Member row) async {
    if (row.asset['id'] == null || !_permission(Perm.financeAssetEdit)) return;
    final scope = await captureFormDraftRequestScope();
    await saveFormDraftNow();
    if (!mounted || !scope.isCurrent) return;
    await showFinanceTemplateInputDialog(
      context,
      kind: 'asset',
      scope: {
        'objectType': _objectType,
        'objectId': row.asset['id'],
        'period': _period.text.trim(),
        'template': _template,
      },
    );
  }

  Future<void> _detail(_Member row) async {
    if (_group == null || _pending != null || row.asset['id'] == null) return;
    final scope = await captureFormDraftRequestScope();
    await saveFormDraftNow();
    if (!mounted || !scope.isCurrent) return;
    await showFinanceAssetDetail(
      context,
      ledger: _ledger,
      id: row.asset['id'].toString(),
      capabilities: FinanceAssetCapabilities(
        canView: true,
        canEdit: _permission(Perm.financeAssetEdit),
        canApprove: _permission(Perm.financeAssetApprove),
        canPost: _permission(Perm.financeAssetPost),
        canReverse: _permission(Perm.financeAssetReverse),
        canDispose: _permission(Perm.financeAssetDispose),
        canManagePeriod: _permission(Perm.financeAssetPeriodManage),
      ),
    );
  }

  Future<void> _addVoucher() => _runRead(() async {
    if (_pending != null || _group != null || !_canReadGl) return;
    final scope = await captureFormDraftRequestScope();
    final result = await scope.run(
      () => ref
          .read(apiClientProvider)
          .get(
            '/finance/asset-opening-groups/vouchers',
            query: {'voucherNo': _voucherNo.text.trim()},
          ),
    );
    if (!mounted || !formDraftIdentityIsCurrent || !scope.isCurrent) return;
    final rows = _maps(result['items']);
    if (rows.isEmpty) throw StateError('没有找到可认领的已入账凭证，请核对完整凭证号');
    setState(() {
      for (final v in rows) {
        _vouchers.removeWhere((old) => old['id'] == v['id']);
        _vouchers.add(v);
      }
    });
    _changed();
  });
  Future<void> _checkMembers() => _runRead(() async {
    if (_pending != null || _group != null) return;
    final scope = await captureFormDraftRequestScope();
    for (final row in _members.rows) {
      if (row.asset['id'] == null) {
        throw StateError('第${row.sourceRow}行尚未选择对应草稿');
      }
      final result = await scope.run(
        () => ref
            .read(apiClientProvider)
            .get('${_ledger.basePath}/${row.asset['id']}'),
      );
      if (!mounted || !scope.isCurrent || !formDraftIdentityIsCurrent) return;
      row.asset = _summary(result);
      row.changed.value++;
    }
    if (!mounted || !scope.isCurrent || !formDraftIdentityIsCurrent) return;
    _validate();
    setState(() => _reviewed = true);
    markFormDraftChanged();
    context.appSuccess('已读取最新成员资料；原表累计、剩余期限和总账合计仍由服务端提交时复核');
  });
  String _rowComparison(_Member row) {
    final source = _sourceRows[row.sourceRow];
    if (source == null) return '原表行未恢复';
    if ((_maps(
          source['cells'],
        ).where((c) => c['kind'] == 'ERROR')).isNotEmpty ||
        (source['issues'] as List? ?? []).isNotEmpty) {
      return '原表行有错误';
    }
    if (row.asset['id'] == null) return '待选择草稿';
    if (row.asset['status'] != 'DRAFT' &&
        row.asset['lifecycleStatus'] != 'DRAFT') {
      return '成员已非草稿';
    }
    if (_cell(source, _deferred ? 3 : 6) != row.asset['name']) return '名称不一致';
    final expected = financeExactTrimmed(_cell(source, _deferred ? 7 : 9));
    final actual = financeExactTrimmed(
      row.asset[_deferred ? 'totalAmount' : 'originalValue']?.toString(),
    );
    if (expected == null || actual == null || expected != actual) {
      return '原值／全额不一致';
    }
    return '名称及原值一致，待服务端复核';
  }

  void _validate() {
    if (_source == null ||
        (_source!['issues'] as List? ?? []).isNotEmpty ||
        _source!['hiddenIncluded'] != true) {
      throw StateError('请先恢复完整原表并核对读取问题，隐藏列也须完整保留');
    }
    if (_members.rows.isEmpty || _members.rows.length > 2000) {
      throw StateError('请选择1至2000条明确对应的原表成员');
    }
    for (final row in _members.rows) {
      if (_rowComparison(row) != '名称及原值一致，待服务端复核') {
        throw StateError('原表第${row.sourceRow}行：${_rowComparison(row)}');
      }
      final n = int.tryParse(row.remaining.text.trim());
      if (n == null || n < 0 || n > 1200 || row.asset['version'] == null) {
        throw StateError('第${row.sourceRow}行须明确填写剩余月份（0至1200）并读取最新版本');
      }
    }
    if (_members.rows.map((r) => r.asset['id']).toSet().length !=
        _members.rows.length) {
      throw StateError('不能将多个原表行对应到同一草稿');
    }
    if (_selectedEntries.isNotEmpty &&
        (_primaryVoucher == null ||
            !_vouchers.any((v) => v['id'] == _primaryVoucher))) {
      throw StateError('请选择本组主要来源凭证');
    }
    if (_selectedEntries.isEmpty && !_deferred) {
      throw StateError('请选择固定资产原值及累计折旧的完整总账条目');
    }
    if (_reason.text.trim().isEmpty) throw StateError('请填写本次核对依据');
  }

  Map<String, dynamic> _createBody() {
    _validate();
    if (!_reviewed) throw StateError('请先点击“读取最新成员并核对”，确认当前成员资料');
    final parts = _period.text.trim().split('-');
    final year = int.tryParse(parts.first),
        month = parts.length == 2 ? int.tryParse(parts.last) : null;
    if (year == null || month == null || month < 1 || month > 12) {
      throw StateError('原表会计月份无效');
    }
    final day = DateTime(year, month + 1, 0).day;
    return {
      'requestId': _requestId,
      'sourceImportId': _source!['importId'],
      'sourceVoucherId': _primaryVoucher,
      'sourceVoucherIds': [for (final v in _vouchers) v['id']],
      'asOf': '${_period.text.trim()}-${day.toString().padLeft(2, '0')}',
      'entryIds': _selectedEntries.toList(),
      'members': [
        for (final r in _members.rows)
          {
            'objectType': _objectType,
            'objectId': r.asset['id'],
            'sourceRow': r.sourceRow,
            'remainingMonths': int.parse(r.remaining.text.trim()),
            'expectedVersion': r.asset['version'],
          },
      ],
      'reason': _reason.text.trim(),
    };
  }

  bool _definite(ApiException e) =>
      e.hasResponseCode &&
      {
        'VALIDATION_FAILED',
        'CONFLICT',
        'FORBIDDEN',
        'NOT_FOUND',
      }.contains(e.code);
  Future<void> _act(String action) async {
    if (_busy || _loading || !formDraftIdentityIsCurrent) return;
    if (!_permission(
      action == 'approve' || action == 'approve-revoke'
          ? Perm.financeAssetApprove
          : Perm.financeAssetEdit,
    )) {
      return;
    }
    setState(() => _busy = true);
    try {
      final scope = await captureFormDraftRequestScope();
      if (!mounted || !scope.isCurrent) return;
      if (_pending == null) {
        if (_reason.text.trim().isEmpty) throw StateError('请填写本次核对／撤销依据');
        _pending = {
          'action': action,
          'actorId': _actor,
          'groupId': action == 'create' ? _requestId : _group!['id'],
          'beforeStatus': _state,
          'sourceFingerprint': _group?['fingerprint'],
          'body': action == 'create'
              ? _createBody()
              : {
                  'expectedVersion': _group!['version'],
                  'reason': _reason.text.trim(),
                },
        };
      }
      final command = _map(jsonDecode(jsonEncode(_pending)));
      final wasUnknown = formDraftHasUnknownSubmission;
      // CAS actions have no separate operation ID. A retry first reads the
      // original group; another actor's later state is never our receipt.
      if (wasUnknown && command['action'] != 'create') {
        final current = await UtenBusyOverlay.run(
          context,
          title: '正在核对原接续操作',
          action: () => scope.run(
            () => ref
                .read(apiClientProvider)
                .get('/finance/asset-opening-groups/${command['groupId']}'),
          ),
        );
        if (_proved(command, current)) {
          await completeFormDraft();
          if (mounted && scope.isCurrent) Navigator.of(context).pop(true);
          return;
        }
        if (current['fingerprint'] != command['sourceFingerprint'] ||
            current['version'] != _map(command['body'])['expectedVersion'] ||
            current['status'] != command['beforeStatus']) {
          throw StateError('接续组已由其他操作推进，原结果尚不能认定；请保留原请求核对，不以新版本重试');
        }
      }
      await runFormDraftSubmission(
        () => UtenBusyOverlay.run(
          context,
          title: '正在处理资产期初接续',
          action: () => scope.run(
            () => ref
                .read(apiClientProvider)
                .post(
                  command['action'] == 'create'
                      ? '/finance/asset-opening-groups'
                      : '/finance/asset-opening-groups/${command['groupId']}/${command['action']}',
                  body: command['body'],
                ),
          ),
        ),
        isDefiniteRejection: (e) => !wasUnknown && _definite(e),
      );
      if (!mounted || !formDraftIdentityIsCurrent || !scope.isCurrent) return;
      await completeFormDraft();
      if (mounted) {
        context.appSuccess('接续操作已完成');
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (!formDraftHasUnknownSubmission) _pending = null;
      if (mounted && formDraftIdentityIsCurrent) {
        context.appApiError(error, fallback: '操作未确认，原请求及核对资料已保留');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _receipt() => _runRead(() async {
    if (_pending == null) return;
    final command = _pending!, scope = await captureFormDraftRequestScope();
    final value = await scope.run(
      () => ref
          .read(apiClientProvider)
          .get('/finance/asset-opening-groups/${command['groupId']}'),
    );
    if (!mounted || !formDraftIdentityIsCurrent || !scope.isCurrent) return;
    if (!_proved(command, value)) {
      throw StateError('未取得与原操作一致的成功依据，请保留原请求核对；不要以新版本重复提交');
    }
    await completeFormDraft();
    if (mounted) {
      context.appSuccess('已核对原接续操作成功');
      Navigator.of(context).pop(true);
    }
  });
  bool _proved(Map<String, dynamic> command, Map<String, dynamic> value) {
    final body = _map(command['body']);
    final version = (value['version'] as num?)?.toInt() ?? -1;
    bool proved = value['id'] == command['groupId'];
    if (command['action'] != 'create') {
      proved =
          proved &&
          command['sourceFingerprint'] != null &&
          value['fingerprint'] == command['sourceFingerprint'];
    }
    switch (command['action']) {
      case 'create':
        proved =
            proved &&
            value['actor_id'] == command['actorId'] &&
            value['source_import_id'] == body['sourceImportId'] &&
            value['reason'] == body['reason'] &&
            value['as_of'] == body['asOf'] &&
            _sameIds(
              _maps(value['source_entry_snapshot']).map((e) => e['id']),
              body['entryIds'],
            ) &&
            _sameIds(
              value['sourceVoucherIds'] as List? ?? [],
              body['sourceVoucherIds'],
            ) &&
            _sameMembers(
              _maps(value['member_snapshot']),
              _maps(body['members']),
            );
      case 'approve':
        proved =
            proved &&
            value['approved_by'] == command['actorId'] &&
            version >= (body['expectedVersion'] as num).toInt() + 1;
      case 'revoke':
        proved =
            proved &&
            value['revoke_actor_id'] == command['actorId'] &&
            value['revoke_reason'] == body['reason'] &&
            version >= (body['expectedVersion'] as num).toInt() + 1;
      case 'approve-revoke':
        proved =
            proved &&
            value['status'] == 'REVOKED' &&
            value['revoke_approved_by'] == command['actorId'] &&
            version >= (body['expectedVersion'] as num).toInt() + 1;
      default:
        proved = false;
    }
    return proved;
  }

  bool _sameIds(Iterable<dynamic> a, Object? b) {
    if (b is! List) return false;
    final left = a.map((v) => v.toString()).toList()..sort();
    final right = b.map((v) => v.toString()).toList()..sort();
    return jsonEncode(left) == jsonEncode(right);
  }

  bool _sameMembers(
    List<Map<String, dynamic>> snapshot,
    List<Map<String, dynamic>> input,
  ) {
    if (snapshot.length != input.length) return false;
    return input.every(
      (m) => snapshot.any(
        (s) =>
            s['objectId'] == m['objectId'] &&
            s['objectType'] == m['objectType'] &&
            s['sourceRow'] == m['sourceRow'] &&
            s['remainingMonths'] == m['remainingMonths'],
      ),
    );
  }

  @override
  Widget? get formDraftSubmissionRecoveryAction => UtenResponsiveActionWrap(
    children: [
      UtenButton(
        type: UtenButtonType.secondary,
        onPressed: _busy ? null : _receipt,
        child: const Text('核对原操作结果'),
      ),
      UtenButton(
        onPressed: _busy || _pending == null
            ? null
            : () => _act(_pending!['action'].toString()),
        child: const Text('使用原请求核对并重试'),
      ),
    ],
  );
  Future<void> _close() async {
    if (!_busy && await confirmFormDraftExit() && mounted) {
      Navigator.of(context).pop(false);
    }
  }

  Future<void> _newGroup() async {
    if (_busy || _pending != null) return;
    await resetFormDraftAfterSubmission(
      preserveCurrentDraft: true,
      prepare: () async {
        setState(() {
          _group = null;
          _source = null;
          _sourceRows.clear();
          _originalRows = [];
          _members.clear();
          _vouchers = [];
          _selectedEntries.clear();
          _primaryVoucher = null;
          _sourceId.clear();
          _groupLookup.clear();
          _voucherNo.clear();
          _reason.clear();
          _requestId = const Uuid().v4();
          _reviewed = false;
          _tab = 0;
        });
      },
    );
  }

  Future<void> _viewGroup(String id) => _runRead(() async {
    if (_pending != null) return;
    await saveFormDraftNow();
    await resetFormDraftAfterSubmission(
      preserveCurrentDraft: true,
      prepare: () => _loadGroup(id),
    );
  });

  MasterColumnDef<Map<String, dynamic>> _column(
    String key,
    String label, {
    double width = 160,
  }) => MasterColumnDef(
    key: key,
    label: label,
    width: width,
    aiSensitive: true,
    value: (row) => row[key]?.toString() ?? '',
  );
  Widget _table(
    String key,
    List<MasterColumnDef<Map<String, dynamic>>> columns,
    List<Map<String, dynamic>> rows,
  ) => MasterDataTableView<Map<String, dynamic>>(
    key: ValueKey(key),
    tableKey: 'finance.asset-opening.$key',
    columns: columns,
    items: rows,
    rowKeyOf: (r) => (r['id'] ?? r['sourceRow'])?.toString(),
    facets: const {},
    nullCounts: const {},
    filters: const {},
    onFilterChanged: (_, _) {},
    virtualized: true,
    showPaginationControls: false,
    showColumnChooser: false,
    expensiveRowMounts: false,
  );
  Widget _original() => _source == null
      ? const Center(child: Text('导入财务原表，或填写原表编号恢复已保存原件'))
      : _table('original-${_source!['importId']}', [
          MasterColumnDef(
            key: 'sourceRow',
            label: '原表行',
            width: 140,
            value: (r) => r['sourceRow'].toString(),
            cellBuilder: (_, r) => UtenButton(
              type: UtenButtonType.secondary,
              onPressed: _editable ? () => _addRow(r) : null,
              child: Text('${r['sourceRow']} 加入对应'),
            ),
          ),
          for (int i = 0; i < (_source!['headers'] as List).length; i++)
            _column(
              '${i + 1}',
              (_source!['headers'] as List)[i].toString(),
              width: 175,
            ),
          MasterColumnDef(
            key: 'map',
            label: '操作',
            width: 120,
            value: (_) => '',
            cellBuilder: (_, row) => UtenButton(
              type: UtenButtonType.secondary,
              onPressed: _editable ? () => _addRow(row) : null,
              child: const Text('加入对应'),
            ),
          ),
          _column('issues', '读取问题', width: 260),
        ], _originalRows);
  String _header(int column) {
    final headers = _source?['headers'] as List? ?? [];
    return column <= headers.length ? headers[column - 1].toString() : '';
  }

  Widget _memberGrid() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(UtenSpacing.s8),
        child: UtenResponsiveActionWrap(
          children: [
            UtenButton(
              type: UtenButtonType.secondary,
              onPressed: _editable ? _checkMembers : null,
              child: const Text('读取最新成员并核对'),
            ),
            Text('已选${_members.rows.length}行；请明确选择草稿和剩余月份。'),
          ],
        ),
      ),
      Expanded(
        child: SingleChildScrollView(
          child: UtenEditableGrid<_Member>(
            controller: _members,
            stickyHeader: false,
            tableKey: 'finance.asset-opening.members',
            showAddRow: false,
            showRowDelete: _editable,
            showRemoveRowsAction: _editable,
            showColumnSettings: false,
            selectionEnabled: _editable,
            emptyMessage: '请在原表中逐行点击“加入对应”，不会按同名自动关联',
            columns: [
              EditableGridColumn(
                key: 'sourceRow',
                label: '原表行',
                width: 85,
                textOf: (r) => '${r.sourceRow}',
                cellBuilder: (_, r) => Text('${r.sourceRow}'),
              ),
              EditableGridColumn(
                key: 'asset',
                label: '对应草稿',
                width: 270,
                aiSensitive: true,
                listenableOf: (r) => r.changed,
                textOf: (r) =>
                    '${r.asset['code'] ?? ''} ${r.asset['name'] ?? ''}',
                cellBuilder: (_, r) => ValueListenableBuilder(
                  valueListenable: r.changed,
                  builder: (_, _, _) => UtenButton(
                    type: UtenButtonType.secondary,
                    onPressed: _editable ? () => _chooseAsset(r) : null,
                    child: Text(
                      r.asset['id'] == null
                          ? '选择草稿'
                          : '${r.asset['code'] ?? ''} ${r.asset['name'] ?? ''}',
                    ),
                  ),
                ),
              ),
              EditableGridColumn(
                key: 'remaining',
                label: '剩余月份',
                width: 130,
                required: true,
                textOf: (r) => r.remaining.text,
                listenableOf: (r) => r.remaining,
                cellBuilder: (_, r) => UtenInput(
                  key: ValueKey('asset-opening-remaining-${r.sourceRow}'),
                  controller: r.remaining,
                  enabled: _editable,
                  onChanged: (_) => _changed(),
                ),
              ),
              for (final field in <(String, String, int)>[
                ('sourceName', _header(_deferred ? 3 : 6), _deferred ? 3 : 6),
                ('sourceAmount', _header(_deferred ? 7 : 9), _deferred ? 7 : 9),
                (
                  'sourceMonthly',
                  _header(_deferred ? 9 : 11),
                  _deferred ? 9 : 11,
                ),
              ])
                EditableGridColumn(
                  key: field.$1,
                  label: field.$2,
                  width: 180,
                  aiSensitive: true,
                  textOf: (r) =>
                      _cell(_sourceRows[r.sourceRow] ?? {}, field.$3),
                  cellBuilder: (_, r) =>
                      Text(_cell(_sourceRows[r.sourceRow] ?? {}, field.$3)),
                ),
              EditableGridColumn(
                key: 'comparison',
                label: '核对情况',
                width: 250,
                aiSensitive: true,
                listenableOf: (r) => r.changed,
                textOf: _rowComparison,
                cellBuilder: (_, r) => ValueListenableBuilder(
                  valueListenable: r.changed,
                  builder: (_, _, _) => Text(_rowComparison(r)),
                ),
              ),
              EditableGridColumn(
                key: 'actions',
                label: '操作',
                width: 400,
                cellBuilder: (_, r) => UtenResponsiveActionWrap(
                  children: [
                    if (_group != null)
                      UtenButton(
                        type: UtenButtonType.secondary,
                        onPressed:
                            !_busy && _pending == null && r.asset['id'] != null
                            ? () => _runRead(() => _detail(r))
                            : null,
                        child: const Text('查看／审批成员'),
                      ),
                    UtenButton(
                      type: UtenButtonType.secondary,
                      onPressed: _editable && r.asset['id'] != null
                          ? () => _runRead(() => _editAsset(r))
                          : null,
                      child: const Text('编辑草稿'),
                    ),
                    UtenButton(
                      type: UtenButtonType.secondary,
                      onPressed:
                          !_busy &&
                              _pending == null &&
                              r.asset['id'] != null &&
                              _permission(Perm.financeAssetEdit)
                          ? () => _runRead(() => _metadata(r))
                          : null,
                      child: const Text('原表资料'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ],
  );
  Widget _entries() {
    final entries = _group == null
        ? [
            for (final v in _vouchers)
              for (final e in _maps(v['entries']))
                {
                  ...e,
                  'voucherId': v['id'],
                  'voucherNo': v['voucherNo'],
                  'voucherDate': v['voucherDate'],
                },
          ]
        : _maps(_group!['source_entry_snapshot']);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(UtenSpacing.s8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_group == null)
                UtenFormGrid(
                  maxColumns: 3,
                  children: [
                    UtenInput(
                      label: '完整原凭证号',
                      controller: _voucherNo,
                      enabled: _editable && _canReadGl,
                    ),
                    UtenButton(
                      onPressed: _editable && _canReadGl ? _addVoucher : null,
                      child: const Text('查找并加入凭证'),
                    ),
                    UtenDropdownField(
                      label: '主要来源凭证',
                      value: _primaryVoucher,
                      enabled: _editable,
                      items: [
                        for (final v in _vouchers)
                          UtenDropdownItem(
                            value: v['id'].toString(),
                            label: '${v['voucherNo']} ${v['voucherDate']}',
                          ),
                      ],
                      onChanged: (v) {
                        _primaryVoucher = v;
                        _changed();
                      },
                    ),
                  ],
                ),
              if (!_canReadGl && _group == null)
                const Text('查找总账凭证还需财务报表查看及公司范围查看权限。'),
              const Text('仅选择本组原值、累计折旧或待摊余额条目；服务端按真实财务科目核对合计，不重复入账。'),
              if (_deferred)
                const Text('已全部摊销且没有条目的待摊记录，须由服务端核对该成本科目的完整零余额来源，缺来源不能当0。'),
            ],
          ),
        ),
        Expanded(
          child: _table('entries', [
            MasterColumnDef(
              key: 'selected',
              label: '认领',
              width: 75,
              value: (r) => _selectedEntries.contains(r['id']) ? '是' : '',
              cellBuilder: (_, r) => Checkbox(
                value: _selectedEntries.contains(r['id']),
                onChanged: _editable && r['claimedGroupId'] == null
                    ? (v) {
                        if (v == true) {
                          _selectedEntries.add(r['id'].toString());
                        } else {
                          _selectedEntries.remove(r['id']);
                        }
                        _changed();
                      }
                    : null,
              ),
            ),
            _column('voucherNo', '凭证号'),
            _column('voucherDate', '日期', width: 130),
            _column('code', '科目代码'),
            _column('name', '科目名称', width: 220),
            MasterColumnDef(
              key: 'direction',
              label: '方向',
              width: 90,
              value: (r) => r['direction'] == 1 ? '借' : '贷',
            ),
            _column('amount', '本币金额', width: 230),
            _column('claimedGroupId', '已认领接续组', width: 250),
            if (_group == null)
              MasterColumnDef(
                key: 'removeVoucher',
                label: '操作',
                width: 150,
                value: (_) => '',
                cellBuilder: (_, r) => UtenButton(
                  type: UtenButtonType.secondary,
                  onPressed: !_editable
                      ? null
                      : () {
                          final id = r['voucherId'];
                          final remove = _vouchers
                              .where((v) => v['id'] == id)
                              .expand((v) => _maps(v['entries']))
                              .map((e) => e['id'].toString())
                              .toSet();
                          _selectedEntries.removeAll(remove);
                          _vouchers.removeWhere((v) => v['id'] == id);
                          if (_primaryVoucher == id) _primaryVoucher = null;
                          _changed();
                        },
                  child: const Text('移除此凭证'),
                ),
              ),
          ], entries),
        ),
      ],
    );
  }

  Widget _records() => Column(
    children: [
      FinanceSummaryScopeField(
        key: const Key('finance-asset-opening-record-scope'),
        label: '接续记录范围',
        value: _groupsScope,
        enabled: !_busy && !_loading && _pending == null,
        info: '待办理保留原提交与撤销待复核事项；已接续及已撤销记录在历史查看，合法申请撤销仍从原记录发起。',
        onChanged: _changeGroupsScope,
      ),
      if (_group != null)
        Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '当前组：${_group!['id']}；${_states[_state] ?? _state}；接续日：${_group!['as_of']}',
              ),
              Text('原核对依据：${_group!['reason'] ?? ''}'),
              if (_group!['revoke_reason'] != null)
                Text('撤销依据：${_group!['revoke_reason']}'),
              Text(
                '提交人：${_group!['actor_id']}；复核人：${_group!['approved_by'] ?? '尚未复核'}',
              ),
              const Text('撤销本次接续须另一人复核。已有平台计提须先按期间倒序红冲；撤销后成员回到草稿，原总账及原接续记录保留。'),
            ],
          ),
        ),
      Expanded(
        child: _table('groups', [
          _column('as_of', '接续日', width: 130),
          MasterColumnDef(
            key: 'status',
            label: '状态',
            width: 200,
            value: (r) => _states[r['status']] ?? r['status']?.toString(),
          ),
          _column('reason', '核对依据', width: 320),
          _column('id', '接续组编号', width: 280),
          MasterColumnDef(
            key: 'open',
            label: '操作',
            width: 100,
            value: (_) => '',
            cellBuilder: (_, r) => UtenButton(
              type: UtenButtonType.secondary,
              onPressed: _busy || _pending != null
                  ? null
                  : () => _viewGroup(r['id'].toString()),
              child: const Text('查看'),
            ),
          ),
        ], _groups),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) => withFormDraft(
    Material(
      child: Column(
        children: [
          UtenDialogSurface(
            child: UtenDialogHeader(
              icon: Icons.account_balance_outlined,
              title: UtenDialogTitleWithHint(
                title: Text('${_templates[_template]}原表接续'),
                info: _pending == null ? null : '上次操作结果待核对，原请求参数已冻结。请核对原请求结果。',
              ),
              showCloseButton: true,
              onClose: _busy ? null : _close,
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, limits) => Column(
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: limits.maxHeight * .37,
                    ),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(UtenSpacing.s12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          UtenFormGrid(
                            maxColumns: 3,
                            children: [
                              UtenDropdownField(
                                label: '原表入口',
                                value: _template,
                                enabled: _editable && _source == null,
                                items: [
                                  for (final t in _templates.entries)
                                    UtenDropdownItem(
                                      value: t.key,
                                      label: t.value,
                                    ),
                                ],
                                onChanged: (v) {
                                  if (v != null) {
                                    _template = v;
                                    _changed();
                                  }
                                },
                              ),
                              UtenInput(
                                label: '原表会计月份（YYYY-MM）',
                                controller: _period,
                                enabled: _editable && _source == null,
                              ),
                              UtenInput(
                                label: '原表编号',
                                controller: _sourceId,
                                enabled: _editable && _source == null,
                              ),
                              UtenInput(
                                label: '接续组编号',
                                controller: _groupLookup,
                                enabled: !_busy && _pending == null,
                              ),
                            ],
                          ),
                          const SizedBox(height: UtenSpacing.s8),
                          UtenResponsiveActionWrap(
                            children: [
                              UtenImportButton(
                                label: '导入财务原表',
                                onPressed: _editable && _source == null
                                    ? _import
                                    : null,
                              ),
                              UtenButton(
                                type: UtenButtonType.secondary,
                                onPressed: _editable && _source == null
                                    ? () => _runRead(
                                        () =>
                                            _loadSource(_sourceId.text.trim()),
                                      )
                                    : null,
                                child: const Text('恢复原表'),
                              ),
                              UtenButton(
                                type: UtenButtonType.secondary,
                                onPressed: _busy || _loading || _pending != null
                                    ? null
                                    : () =>
                                          _viewGroup(_groupLookup.text.trim()),
                                child: const Text('查看接续组'),
                              ),
                              UtenRefreshButton(
                                busy: _busy || _loading,
                                onRefresh: () => _runRead(() async {
                                  await _refreshGroups();
                                  if (_group != null) {
                                    await _loadGroup(
                                      _group!['id'].toString(),
                                      hydrate: false,
                                    );
                                  }
                                }),
                              ),
                              UtenButton(
                                type: UtenButtonType.secondary,
                                onPressed: _busy || _pending != null
                                    ? null
                                    : _newGroup,
                                child: const Text('新建接续组'),
                              ),
                            ],
                          ),
                          if (_source != null)
                            Text(
                              '${_source!['sourceName']} / ${_source!['sourceSheet']} / 原表${_source!['rows'] is List ? (_source!['rows'] as List).length : 0}行 / SHA256:${_source!['sha256']}',
                            ),
                          for (final issue in _source?['issues'] as List? ?? [])
                            Text(
                              issue.toString(),
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          if (_error != null)
                            Text(
                              _error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          if (_loading || _busy)
                            const LinearProgressIndicator(),
                        ],
                      ),
                    ),
                  ),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.all(UtenSpacing.s8),
                    child: UtenSegmentRow<int>(
                      segments: const [
                        ButtonSegment(value: 0, label: Text('原表')),
                        ButtonSegment(value: 1, label: Text('成员对应')),
                        ButtonSegment(value: 2, label: Text('凭证条目')),
                        ButtonSegment(value: 3, label: Text('接续记录')),
                      ],
                      selected: {_tab},
                      onSelectionChanged: (v) {
                        setState(() => _tab = v.single);
                        markFormDraftChanged();
                      },
                    ),
                  ),
                  Expanded(
                    child: switch (_tab) {
                      0 => _original(),
                      1 => _memberGrid(),
                      2 => _entries(),
                      _ => _records(),
                    },
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            child: Column(
              children: [
                if (_pending != null) ...[
                  formDraftSubmissionRecoveryAction!,
                  const SizedBox(height: UtenSpacing.s8),
                ],
                UtenInput(
                  label: '本次核对／撤销依据',
                  controller: _reason,
                  maxLines: 2,
                  enabled: !_busy && _pending == null,
                ),
                const SizedBox(height: UtenSpacing.s8),
                UtenDialogActions(
                  padding: EdgeInsets.zero,
                  showDivider: false,
                  children: [
                    if (_group == null)
                      UtenButton(
                        onPressed: _editable ? () => _act('create') : null,
                        child: const Text('提交接续核对'),
                      ),
                    if (_state == 'SUBMITTED' &&
                        _permission(Perm.financeAssetApprove))
                      UtenButton(
                        onPressed:
                            !_busy &&
                                _pending == null &&
                                _group!['actor_id'] != _actor
                            ? () => _act('approve')
                            : null,
                        child: const Text('复核接续'),
                      ),
                    if ({'SUBMITTED', 'APPROVED'}.contains(_state) &&
                        _permission(Perm.financeAssetEdit))
                      UtenButton(
                        type: UtenButtonType.secondary,
                        onPressed: _busy || _pending != null
                            ? null
                            : () => _act('revoke'),
                        child: const Text('申请撤销本次接续'),
                      ),
                    if (_state == 'REVOKE_PENDING' &&
                        _permission(Perm.financeAssetApprove))
                      UtenButton(
                        onPressed:
                            !_busy &&
                                _pending == null &&
                                _group!['revoke_actor_id'] != _actor
                            ? () => _act('approve-revoke')
                            : null,
                        child: const Text('复核撤销本次接续'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  ).withSelectedValueHighlights();
}

/// Reuses the asset ledger table and native form. Only an explicit click selects
/// an existing draft; a matching name or amount never establishes identity.
class _DraftPicker extends ConsumerStatefulWidget {
  const _DraftPicker({required this.ledger});
  final FinanceAssetLedger ledger;
  @override
  ConsumerState<_DraftPicker> createState() => _DraftPickerState();
}

class _DraftPickerState extends ConsumerState<_DraftPicker>
    with ReadViewActivityMixin<_DraftPicker> {
  @override
  Future<void> onReadViewResumed() => _load();
  final _search = TextEditingController();
  List<Map<String, dynamic>> _rows = [];
  // _rows 是否只是逐批前缀（未到完整结果）；失败时整体下撤。
  bool _partialRows = false;
  int _total = 0, _generation = 0;
  int? _activeGeneration;
  String? _activeQuery;
  bool _loading = true;
  bool _retired = false;
  String? _error;
  late final _owner = ref.read(authenticatedScopeProvider);
  late final _api = ref.read(apiClientProvider);
  bool get _current =>
      mounted &&
      !_retired &&
      ref.read(authenticatedScopeProvider) == _owner &&
      identical(ref.read(apiClientProvider), _api);
  @override
  void initState() {
    super.initState();
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

  Future<void> _load() async {
    if (!_current) return;
    final generation = ++_generation;
    final query = _search.text.trim();
    _activeGeneration = generation;
    _activeQuery = query;
    setState(() => _loading = true);
    try {
      final scope = await _api.captureRequestScope(
        isCurrent: () => _current && generation == _generation,
      );
      final complete = await readViewActivity.runRead(
        () => _current && generation == _generation,
        () => scope.run(
          () => loadCompletePagedResult<Map<String, dynamic>>(
            isCurrent: () =>
                _current && generation == _generation && scope.isCurrent,
            idOf: (row) => row['id'],
            loadPage: (page, size) async {
              final value = await _api.get(
                widget.ledger.basePath,
                query: {
                  'page': page,
                  'size': size,
                  'status': 'DRAFT',
                  'q': query,
                },
              );
              return PagedResult.fromJson(value, (row) => row);
            },
            onProgressiveBatch: (partial) {
              if (!_current || generation != _generation || !scope.isCurrent) {
                return;
              }
              setState(() {
                _rows = partial.items;
                _partialRows = true;
              });
            },
          ),
        ),
      );
      if (!_current || generation != _generation || !scope.isCurrent) return;
      setState(() {
        _rows = complete.items;
        _total = complete.total;
        _partialRows = false;
        _error = null;
      });
    } catch (e) {
      if (isRetiredViewRead(e)) return;
      if (_current && generation == _generation) {
        setState(() {
          // 逐批前缀不是完整结果：读取失败时整体下撤，不能留半张清单。
          if (_partialRows) {
            _rows = [];
            _partialRows = false;
          }
          _error = humanErrorMessage(e) ?? '草稿未读取';
        });
      }
    } finally {
      if (_activeGeneration == generation) {
        _activeGeneration = null;
        _activeQuery = null;
      }
      if (_current && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Material(
    child: Column(
      children: [
        UtenDialogSurface(
          child: UtenDialogHeader(
            title: Text('选择${widget.ledger.label}草稿'),
            showCloseButton: true,
            onClose: () => Navigator.of(context).pop(),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: UtenResponsiveActionWrap(
            children: [
              SizedBox(
                width: 260,
                child: UtenSearchBar(
                  controller: _search,
                  hint: '按编码／名称搜索',
                  onInputChanged: (_) {
                    _generation++;
                    setState(() {
                      _rows = [];
                      _partialRows = false;
                      _loading = true;
                    });
                  },
                  isQueryPending: (value) =>
                      _activeGeneration == _generation &&
                      _activeQuery == value.trim(),
                  onChanged: (_) => _load(),
                  onSubmitted: (_) => _load(),
                ),
              ),
              UtenButton(
                onPressed: _loading
                    ? null
                    : () async {
                        if (await showFinanceAssetForm(
                              context,
                              ledger: widget.ledger,
                            ) &&
                            _current) {
                          await _load();
                        }
                      },
                child: const Text('新增草稿'),
              ),
              UtenRefreshButton(busy: _loading, onRefresh: _load),
            ],
          ),
        ),
        if (_loading) const LinearProgressIndicator(),
        if (_error != null) Text(_error!),
        Expanded(
          child: MasterDataTableView<Map<String, dynamic>>(
            tableKey: 'finance.asset-opening.draft-picker',
            items: _rows,
            columns: [
              // 2026-11-11 口径：编号列可排序 + 按值筛选；金额列可排序；
              // 类别列（会计政策）按值筛选（全量草稿快照就地收集桶）。
              MasterColumnDef(
                key: 'code',
                label: '编码',
                width: 210,
                aiSensitive: true,
                sortable: true,
                filterFromRows: true,
                value: (r) => r['code']?.toString(),
              ),
              for (final f in [('name', '名称')])
                MasterColumnDef(
                  key: f.$1,
                  label: f.$2,
                  width: 210,
                  aiSensitive: true,
                  value: (r) => r[f.$1]?.toString(),
                ),
              MasterColumnDef(
                key: widget.ledger == FinanceAssetLedger.fixedAsset
                    ? 'originalValue'
                    : 'totalAmount',
                label: '原值／全额',
                width: 210,
                aiSensitive: true,
                type: 'money',
                sortable: true,
                value: (r) => r[widget.ledger == FinanceAssetLedger.fixedAsset
                    ? 'originalValue'
                    : 'totalAmount']?.toString(),
              ),
              MasterColumnDef(
                key: 'categoryName',
                label: '会计政策',
                width: 210,
                aiSensitive: true,
                filterFromRows: true,
                value: (r) => r['categoryName']?.toString(),
              ),
              MasterColumnDef(
                key: 'select',
                label: '操作',
                width: 100,
                value: (_) => '',
                cellBuilder: (_, r) => UtenButton(
                  onPressed: _current && !_loading
                      ? () => Navigator.of(context).pop(r)
                      : null,
                  child: const Text('选择'),
                ),
              ),
            ],
            rowKeyOf: (r) => r['id']?.toString(),
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            virtualized: true,
            showPaginationControls: false,
            showColumnChooser: false,
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: UtenResponsiveActionWrap(children: [Text('共$_total条')]),
        ),
      ],
    ),
  );
}
