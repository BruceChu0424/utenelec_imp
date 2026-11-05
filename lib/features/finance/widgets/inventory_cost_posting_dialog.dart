import 'package:uten_imp/components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_dialog_modules.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../shared/finance_workbench_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_date_range_selection_button.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_table_cell_action.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/cost_workbench_capability.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import 'finance_durable_command_dialog.dart';

const inventoryCostPostingEndpoint = '/finance/gl/inventory-cost';

Future<Map<String, dynamic>?> showInventoryCostCommand(
  BuildContext context, {
  required FinanceDurableOperation operation,
  String target = '',
  Map<String, dynamic>? initialBody,
  Map<String, dynamic> initialContext = const {},
  String? resumeDraftId,
}) {
  if (!operation.inventory) throw const FormatException('原操作不属于库存成本');
  return showFinanceDurableCommandDialog(
    context,
    operation: operation,
    target: target,
    initialBody: initialBody,
    initialContext: initialContext,
    resumeDraftId: resumeDraftId,
    saveLabel: '确认',
    reviewLoader: (api, body, source, target) =>
        _reviewInventoryCostCommand(operation, api, body, source, target),
    hint: switch (operation) {
      FinanceDurableOperation.inventoryPolicy =>
        '启用前核对本期原价值及历史凭证差额；生效日期和核对依据按原版本保存。',
      FinanceDurableOperation.inventoryPeriod =>
        '按原成本来源及原金额指定期间，不改原发生日期或按当前价格重算。',
      FinanceDurableOperation.inventoryPost =>
        '按所选期间处理服务器当前已具备完整来源的实际成本。原请求回执与结果保留；重试原请求不会处理后来新到的来源。',
      _ => '关期按原期间版本校验。必须处理完原来源并填写关闭依据；原请求结果独立保存。',
    },
    editorBuilder: (context, editor) {
      final l10n = AppLocalizations.of(context);
      final body = editor.body, source = editor.contextData;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (operation == FinanceDurableOperation.inventoryPolicy) ...[
            UtenDialogSettingTile(
              canRequestFocus: false,
              icon: Icons.inventory_2_outlined,
              title: Text(l10n.inventoryCostEnabled),
              onTap: editor.editable
                  ? () => editor.set('enabled', body['enabled'] != true)
                  : null,
              trailing: Switch(
                value: body['enabled'] == true,
                onChanged: editor.editable
                    ? (value) => editor.set('enabled', value)
                    : null,
              ),
            ),
            const SizedBox(height: 12),
            UtenDateField(
              label: l10n.inventoryCostEffectiveDate,
              value: DateTime.tryParse('${body['effectiveFrom'] ?? ''}'),
              enabled: editor.editable,
              onChanged: (value) =>
                  editor.set('effectiveFrom', ChinaDateTime.formatDate(value)),
            ),
            const SizedBox(height: 12),
            UtenInput(
              label: l10n.inventoryCostEvidence,
              controller: editor.controller('reconciliationReference'),
              enabled: editor.editable,
              maxLines: 3,
              required: body['enabled'] == true,
              validator: (value) =>
                  editor.body['enabled'] == true &&
                      (value ?? '').trim().length < 8
                  ? l10n.inventoryCostEvidenceRequired
                  : null,
            ),
          ],
          if (operation == FinanceDurableOperation.inventoryPeriod) ...[
            SelectableText(
              '${l10n.inventoryCostSource}: $target\n${l10n.inventoryCostAmount}: ${source['amountLocal'] ?? '—'}\n${l10n.inventoryCostSourcePeriod}: ${source['sourcePeriod'] ?? '—'}',
            ),
            const SizedBox(height: 12),
            UtenDropdownField(
              label: l10n.inventoryCostTargetPeriod,
              value: body['targetPeriod']?.toString(),
              enabled: editor.editable,
              allowClear: false,
              items: [
                for (final period in source['openPeriods'] as List? ?? const [])
                  UtenDropdownItem(
                    value: period.toString(),
                    label: period.toString(),
                  ),
              ],
              onChanged: (value) {
                if (value != null) editor.set('targetPeriod', value);
              },
            ),
            const SizedBox(height: 12),
            UtenInput(
              label: l10n.inventoryCostReason,
              controller: editor.controller('reason'),
              enabled: editor.editable,
              required: true,
              validator: (value) => (value ?? '').trim().length < 4
                  ? l10n.inventoryCostReasonRequired
                  : null,
            ),
          ],
          if (operation == FinanceDurableOperation.inventoryPost ||
              operation == FinanceDurableOperation.inventoryClose) ...[
            SelectableText(
              '${l10n.inventoryCostTargetPeriod}: $target\n${operation == FinanceDurableOperation.inventoryPost ? l10n.inventoryCostReady : l10n.inventoryCostPendingCount}: ${source['sourceCount'] ?? '—'}',
            ),
            if (operation == FinanceDurableOperation.inventoryClose) ...[
              const SizedBox(height: 12),
              UtenInput(
                label: l10n.inventoryCostReason,
                controller: editor.controller('reason'),
                enabled: editor.editable,
                required: true,
                validator: (value) => (value ?? '').trim().isEmpty
                    ? l10n.inventoryCostReasonRequired
                    : null,
              ),
            ],
          ],
        ],
      );
    },
  );
}

Future<FinanceCommandReview> _reviewInventoryCostCommand(
  FinanceDurableOperation operation,
  ApiClient api,
  Map<String, dynamic> body,
  Map<String, dynamic> source,
  String target,
) async {
  if (operation == FinanceDurableOperation.inventoryPolicy) {
    final policy = await api.get('$inventoryCostPostingEndpoint/policy');
    if (policy['version'] is! int) throw StateError('当前成本策略缺少版本依据');
    return FinanceCommandReview(
      versionPatch: {'expectedVersion': policy['version']},
      rows: [
        (
          '实际成本过账',
          body['enabled'] == true ? '启用' : '关闭',
          policy['enabled'] == true ? '启用' : '关闭',
        ),
        (
          '生效日期',
          '${body['effectiveFrom'] ?? '未设置'}',
          '${policy['effectiveFrom'] ?? '未设置'}',
        ),
        (
          '核对依据',
          '${body['reconciliationReference'] ?? ''}',
          '${policy['reconciliationReference'] ?? ''}',
        ),
      ],
    );
  }
  if (operation == FinanceDurableOperation.inventoryPeriod) {
    if (source['queryFrom'] is! String || source['queryTo'] is! String) {
      throw StateError('原来源范围缺失，请保留本次输入并从原成本来源重新核对');
    }
    final rows = await api.getList(
      '$inventoryCostPostingEndpoint/postings',
      query: {'from': source['queryFrom'], 'to': source['queryTo']},
    );
    final posting = rows.where((row) => row['postingId'] == target).firstOrNull;
    if (posting == null ||
        !const {
          'TARGET_PERIOD_REQUIRED',
          'TARGET_PERIOD_CLOSED',
          'READY',
        }.contains(posting['postingStatus'])) {
      throw StateError('原成本来源不再允许指定期间，请在原表核对当前结果');
    }
    return FinanceCommandReview(
      rows: [
        (
          '入账期间',
          '${body['targetPeriod'] ?? '未指定'}',
          '${posting['targetPeriod'] ?? '未指定'}',
        ),
        (
          '原来源金额',
          '${source['amountLocal'] ?? '待核对'}',
          '${posting['amountLocal'] ?? '待核对'}',
        ),
      ],
    );
  }
  final periods = await api.getList(
    '$inventoryCostPostingEndpoint/periods',
    query: {'from': target, 'to': target},
  );
  final period = periods.where((row) => row['period'] == target).firstOrNull;
  if (period == null || period['status'] != 'OPEN') {
    throw StateError('当前成本期间未开放，请保留输入并核对原表');
  }
  if (operation == FinanceDurableOperation.inventoryClose &&
      period['version'] is! int) {
    throw StateError('当前成本期间缺少版本依据');
  }
  return FinanceCommandReview(
    versionPatch: {
      if (operation == FinanceDurableOperation.inventoryClose)
        'expectedVersion': period['version'],
    },
    rows: [
      ('成本期间', target, '${period['period']}（开放）'),
      (
        '待处理来源',
        '${source['sourceCount'] ?? '待核对'}',
        '${period['pendingCount'] ?? '待核对'}',
      ),
    ],
  );
}

Future<bool> showInventoryCostPostingDialog(
  BuildContext context, {
  required DateTime from,
  required DateTime to,
}) async =>
    await showFinanceWorkbenchPanel<bool>(
      context: context,
      builder: (_) => InventoryCostPostingDialog(from: from, to: to),
    ) ??
    false;

class InventoryCostPostingDialog extends ConsumerStatefulWidget {
  const InventoryCostPostingDialog({
    required this.from,
    required this.to,
    super.key,
  });
  final DateTime from;
  final DateTime to;
  @override
  ConsumerState<InventoryCostPostingDialog> createState() =>
      _InventoryCostPostingDialogState();
}

class _InventoryCostPostingDialogState
    extends ConsumerState<InventoryCostPostingDialog> {
  late DateTime _from = ChinaDateTime.dateOnly(widget.from);
  late DateTime _to = ChinaDateTime.dateOnly(widget.to);
  List<Map<String, dynamic>> _rows = const [];
  List<Map<String, dynamic>> _periods = const [];
  Map<String, dynamic>? _policy;
  String? _period;
  String? _error;
  bool _busy = false;
  bool _commandOpen = false;
  bool _changed = false;
  int _loadGeneration = 0;
  late final ApiClient _api;
  late final int _ownerEpoch;
  bool get _current =>
      mounted &&
      _ownerEpoch == ref.read(exportContextEpochProvider) &&
      identical(_api, ref.read(apiClientProvider));
  bool get _canRead =>
      _current && ref.read(costWorkbenchCapabilityProvider).canReadPostings;
  bool get _canPost =>
      _current && ref.read(costWorkbenchCapabilityProvider).canPost;
  static String _month(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}';
  static String _date(DateTime date) =>
      '${_month(date)}-${date.day.toString().padLeft(2, '0')}';
  String _value(Map<String, dynamic> row, String key) =>
      row[key]?.toString() ?? '—';

  @override
  void initState() {
    super.initState();
    _api = ref.read(apiClientProvider);
    _ownerEpoch = ref.read(exportContextEpochProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!_canRead || _commandOpen) return;
    final generation = ++_loadGeneration;
    final l10n = AppLocalizations.of(context);
    if (_from.isAfter(_to)) {
      setState(() => _error = l10n.inventoryCostInvalidRange);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final rows = await _api.getList(
        '$inventoryCostPostingEndpoint/postings',
        query: {'from': _date(_from), 'to': _date(_to)},
      );
      Map<String, dynamic>? policy;
      List<Map<String, dynamic>> periods = const [];
      if (_canPost) {
        policy = await _api.get('$inventoryCostPostingEndpoint/policy');
        periods = await _api.getList(
          '$inventoryCostPostingEndpoint/periods',
          query: {
            'from': _month(_from),
            'to': _month(DateTime(_to.year, _to.month + 1)),
          },
        );
      }
      if (!_canRead || generation != _loadGeneration) return;
      setState(() {
        _rows = rows;
        _policy = policy;
        _periods = periods;
        if (!periods.any((item) => item['period'] == _period)) {
          _period =
              periods
                  .where((item) => item['period'] == _month(_to))
                  .firstOrNull?['period']
                  ?.toString() ??
              periods.firstOrNull?['period']?.toString();
        }
      });
    } on ApiException catch (error) {
      if (_current && generation == _loadGeneration) {
        setState(() => _error = error.message);
      }
    } catch (_) {
      if (_current && generation == _loadGeneration) {
        setState(() => _error = l10n.inventoryCostLoadFailed);
      }
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _busy = false);
      }
    }
  }

  void _close() {
    if (!mounted || _current && (_busy || _commandOpen)) {
      return;
    }
    Navigator.pop(context, _changed);
  }

  Future<void> _runCommand(
    FinanceDurableOperation operation, {
    String target = '',
    required Map<String, dynamic> body,
    Map<String, dynamic> contextData = const {},
  }) async {
    if (!_canPost || _busy || _commandOpen) return;
    setState(() => _commandOpen = true);
    try {
      final result = await showInventoryCostCommand(
        context,
        operation: operation,
        target: target,
        initialBody: body,
        initialContext: {
          'queryFrom': _date(_from),
          'queryTo': _date(_to),
          ...contextData,
        },
      );
      if (_current && result != null) _changed = true;
    } finally {
      if (mounted) setState(() => _commandOpen = false);
      if (_current) await _load();
    }
  }

  Future<void> _configure() async {
    final policy = _policy;
    if (!_canPost || policy == null || _busy || _commandOpen) return;
    await _runCommand(
      FinanceDurableOperation.inventoryPolicy,
      body: {
        'enabled': policy['enabled'] == true,
        'effectiveFrom': policy['effectiveFrom'],
        'reconciliationReference': policy['reconciliationReference'] ?? '',
        'expectedVersion': policy['version'],
      },
    );
  }

  Future<void> _choosePeriod(Map<String, dynamic> row) async {
    if (!_canPost || _busy || _commandOpen) return;
    final open = _periods
        .where((period) => period['status'] == 'OPEN')
        .toList();
    if (open.isEmpty) {
      context.appError(AppLocalizations.of(context).inventoryCostNoOpenPeriod);
      return;
    }
    final selected = open.any((period) => period['period'] == _period)
        ? _period!
        : open.last['period'].toString();
    await _runCommand(
      FinanceDurableOperation.inventoryPeriod,
      target: row['postingId'].toString(),
      body: {'targetPeriod': selected, 'reason': ''},
      contextData: {
        'amountLocal': row['amountLocal'],
        'sourcePeriod': row['sourcePeriod'],
        'openPeriods': [for (final period in open) period['period'].toString()],
      },
    );
  }

  Future<void> _post() async {
    final period = _period;
    if (!_canPost || period == null || _busy || _commandOpen) return;
    await _runCommand(
      FinanceDurableOperation.inventoryPost,
      target: period,
      body: const {},
      contextData: {
        'sourceCount': _rows
            .where(
              (row) =>
                  row['targetPeriod'] == period &&
                  row['postingStatus'] == 'READY',
            )
            .length,
      },
    );
  }

  Future<void> _closePeriod() async {
    final row = _periods.where((item) => item['period'] == _period).firstOrNull;
    if (!_canPost || row == null || _busy || _commandOpen) return;
    await _runCommand(
      FinanceDurableOperation.inventoryClose,
      target: row['period'].toString(),
      body: {'expectedVersion': row['version'], 'reason': ''},
      contextData: {'sourceCount': row['pendingCount']},
    );
  }

  @override
  Widget build(BuildContext context) {
    final capability = ref.watch(costWorkbenchCapabilityProvider);
    ref.watch(exportContextEpochProvider);
    final l10n = AppLocalizations.of(context);
    if (!_current || !capability.canReadPostings) {
      return UtenAlertDialog(
        showCloseButton: true,
        onClose: _close,
        title: Text(l10n.inventoryCostTitle),
        content: Text(l10n.inventoryCostNoAccess),
      );
    }
    final canPost = capability.canPost;
    final selectedPeriod = _periods
        .where((item) => item['period'] == _period)
        .firstOrNull;
    final isOpen = selectedPeriod?['status'] == 'OPEN';
    final ready = _rows.any(
      (row) =>
          row['targetPeriod'] == _period && row['postingStatus'] == 'READY',
    );
    final fields = <(String, String, double)>[
      ('postingStatus', l10n.inventoryCostStatus, 72),
      ('amountLocal', l10n.inventoryCostAmount, 175),
      ('businessDate', l10n.inventoryCostBusinessDate, 120),
      ('sourcePeriod', l10n.inventoryCostSourcePeriod, 115),
      ('targetPeriod', l10n.inventoryCostTargetPeriod, 115),
      ('sourceDocType', l10n.inventoryCostSourceType, 205),
      ('sourceDocId', l10n.inventoryCostSourceDocument, 290),
      ('postingId', l10n.inventoryCostSource, 290),
      ('valueRevision', l10n.inventoryCostRevision, 95),
      ('voucherId', l10n.inventoryCostVoucher, 290),
    ];
    final columns = fields
        .map(
          (field) => MasterColumnDef<Map<String, dynamic>>(
            key: field.$1,
            label: field.$2,
            width: field.$3,
            value: (row) => field.$1 == 'postingStatus'
                ? inventoryCostStatusLabel(l10n, _value(row, field.$1))
                : _value(row, field.$1),
            exactValueOf: field.$1 == 'amountLocal'
                ? (row) => row['amountLocal']?.toString()
                : null,
            cellBuilder: (context, row) {
              final text = field.$1 == 'postingStatus'
                  ? inventoryCostStatusLabel(l10n, _value(row, field.$1))
                  : _value(row, field.$1);
              return Tooltip(
                message: text,
                child: Text(
                  text,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                ),
              );
            },
          ),
        )
        .toList();
    if (canPost) {
      // 状态列（postingStatus）保持全分支首位，操作列插在其后。
      columns.insert(
        1,
        MasterColumnDef<Map<String, dynamic>>(
          key: 'choosePeriod',
          label: l10n.inventoryCostAssignPeriod,
          width: 140,
          value: (_) => '',
          cellBuilder: (context, row) => UtenTableCellAction(
            label: l10n.inventoryCostAssignPeriod,
            onPressed:
                !_busy &&
                    {
                      'TARGET_PERIOD_REQUIRED',
                      'TARGET_PERIOD_CLOSED',
                      'READY',
                    }.contains(row['postingStatus'])
                ? () => _choosePeriod(row)
                : null,
          ),
        ),
      );
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: UtenDialogFrame(
        insetPadding: const EdgeInsets.all(UtenSpacing.s12),
        child: SizedBox(
          width: 1200,
          height: MediaQuery.sizeOf(context).height * .9,
          child: Padding(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                UtenDialogHeader(
                  padding: const EdgeInsets.only(bottom: UtenSpacing.s16),
                  icon: Icons.account_balance_wallet_outlined,
                  title: Text(l10n.inventoryCostTitle),
                  showCloseButton: true,
                  onClose: _busy ? null : _close,
                ),
                Wrap(
                  spacing: UtenSpacing.s8,
                  runSpacing: UtenSpacing.s8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    UtenButton(
                      type: UtenButtonType.secondary,
                      onPressed: _busy ? null : _load,
                      child: Text(l10n.commonRefresh),
                    ),
                    if (canPost)
                      UtenButton(
                        key: const ValueKey('inventory-cost-policy'),
                        type: UtenButtonType.secondary,
                        onPressed: _busy || _policy == null ? null : _configure,
                        child: Text(l10n.inventoryCostPolicy),
                      ),
                    if (_policy != null)
                      Text(
                        _policy!['enabled'] == true
                            ? l10n.inventoryCostEnabled
                            : l10n.inventoryCostDisabled,
                      ),
                  ],
                ),
                if (canPost && _periods.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: UtenSpacing.s8),
                    child: Wrap(
                      spacing: UtenSpacing.s8,
                      runSpacing: UtenSpacing.s8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SizedBox(
                          width: 220,
                          child: UtenDropdownField(
                            label: l10n.inventoryCostTargetPeriod,
                            value: _period,
                            enabled: !_busy && !_commandOpen,
                            allowClear: false,
                            items: [
                              for (final row in _periods)
                                UtenDropdownItem(
                                  value: row['period'].toString(),
                                  label:
                                      '${row['period']} · ${row['status'] == 'CLOSED' ? l10n.inventoryCostClosed : l10n.inventoryCostOpen}',
                                ),
                            ],
                            onChanged: (value) {
                              if (!_busy && !_commandOpen && value != null) {
                                setState(() => _period = value);
                              }
                            },
                          ),
                        ),
                        Text(
                          '${l10n.inventoryCostPendingCount}: ${selectedPeriod?['pendingCount'] ?? 0}',
                        ),
                        UtenButton(
                          key: const ValueKey('inventory-cost-post'),
                          onPressed: !_busy && isOpen && ready ? _post : null,
                          child: Text(l10n.inventoryCostPost),
                        ),
                        UtenButton(
                          key: const ValueKey('inventory-cost-close-period'),
                          type: UtenButtonType.secondary,
                          onPressed:
                              !_busy &&
                                  _policy?['enabled'] == true &&
                                  isOpen &&
                                  selectedPeriod?['pendingCount'] == 0
                              ? _closePeriod
                              : null,
                          child: Text(l10n.inventoryCostClosePeriod),
                        ),
                      ],
                    ),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: UtenSpacing.s8,
                    ),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: UtenSpacing.s8),
                Expanded(
                  child: MasterDataTableView<Map<String, dynamic>>(
                    expensiveRowMounts: false,
                    tableKey: 'finance.inventory_cost_posting',
                    toolbarActions: [
                      UtenDateRangeSelectionButton(
                        from: _from,
                        to: _to,
                        enabled: !_busy,
                        helpText: '选择成本来源日期范围',
                        onChanged: (start, end) {
                          setState(() {
                            _from = ChinaDateTime.dateOnly(start!);
                            _to = ChinaDateTime.dateOnly(end!);
                          });
                          return _load();
                        },
                      ),
                    ],
                    columns: columns,
                    items: _rows,
                    facets: const {},
                    nullCounts: const {},
                    filters: const {},
                    onFilterChanged: (_, _) {},
                    isLoading: _busy,
                    error: _error,
                    onRetry: _load,
                    emptyMessage: l10n.commonNoData,
                    rowKeyOf: (row) => row['postingId']?.toString() ?? '',
                  ),
                ),
                if (_busy)
                  const UtenBusyOverlay(
                    title: '正在处理库存成本过账',
                    showDoNotLeaveHint: false,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String inventoryCostStatusLabel(AppLocalizations l10n, String value) =>
    switch (value) {
      'POSTED' => l10n.inventoryCostPosted,
      'READY' => l10n.inventoryCostReady,
      'DISABLED_PENDING_RECONCILIATION' => l10n.inventoryCostDisabled,
      'BEFORE_CUTOVER' => l10n.inventoryCostBeforeCutover,
      'SOURCE_IDENTITY_PENDING' => l10n.inventoryCostSourcePending,
      'COST_PENDING' => l10n.inventoryCostValuePending,
      'LEGACY_VOUCHER_RECONCILIATION_REQUIRED' =>
        l10n.inventoryCostLegacyConflict,
      'TARGET_PERIOD_CLOSED' => l10n.inventoryCostTargetClosed,
      'TARGET_PERIOD_REQUIRED' => l10n.inventoryCostTargetRequired,
      _ => value,
    };
