import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_table_cell_action.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/cost_workbench_capability.dart';
import '../../basic_data/widgets/master_data_table_view.dart';

const inventoryCostPostingEndpoint = '/finance/gl/inventory-cost';

Future<bool> showInventoryCostPostingDialog(
  BuildContext context, {
  required DateTime from,
  required DateTime to,
}) async =>
    await showDialog<bool>(
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
  bool _changed = false;
  int _loadGeneration = 0;
  ApiClient get _api => ref.read(apiClientProvider);
  bool get _canRead =>
      ref.read(costWorkbenchCapabilityProvider).canReadPostings;
  bool get _canPost => ref.read(costWorkbenchCapabilityProvider).canPost;
  static String _month(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}';
  static String _date(DateTime date) =>
      '${_month(date)}-${date.day.toString().padLeft(2, '0')}';
  String _value(Map<String, dynamic> row, String key) =>
      row[key]?.toString() ?? '—';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted || !_canRead) return;
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
      if (!mounted || generation != _loadGeneration || !_canRead) return;
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
      if (mounted && generation == _loadGeneration) {
        setState(() => _error = error.message);
      }
    } catch (_) {
      if (mounted && generation == _loadGeneration) {
        setState(() => _error = l10n.inventoryCostLoadFailed);
      }
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _busy = false);
      }
    }
  }

  Future<bool> _confirm(String action, String details) async {
    final l10n = AppLocalizations.of(context);
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(action),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Text(details),
            ),
            actions: [
              UtenButton(
                type: UtenButtonType.secondary,
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(l10n.commonCancel),
              ),
              UtenButton(
                key: const ValueKey('inventory-cost-confirm'),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(l10n.commonConfirm),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<T?> _inputDialog<T>({
    required WidgetBuilder builder,
    required List<TextEditingController> controllers,
  }) async {
    final route = DialogRoute<T>(context: context, builder: builder);
    final result = await Navigator.of(context, rootNavigator: true).push(route);
    await route.completed;
    for (final controller in controllers) {
      controller.dispose();
    }
    return result;
  }

  Future<void> _write(Future<void> Function() action) async {
    if (!_canPost || _busy) return;
    final l10n = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) return;
      _changed = true;
      context.appSuccess(l10n.commonSuccess);
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message);
    } catch (_) {
      if (mounted) context.appError(l10n.inventoryCostWriteFailed);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _load();
      }
    }
  }

  Future<void> _configure() async {
    final policy = _policy;
    if (!_canPost || policy == null || _busy) return;
    final l10n = AppLocalizations.of(context);
    final reference = TextEditingController(
      text: policy['reconciliationReference']?.toString() ?? '',
    );
    bool enabled = policy['enabled'] == true;
    DateTime effective =
        DateTime.tryParse(policy['effectiveFrom']?.toString() ?? '') ??
        DateTime(_to.year, _to.month);
    final form = GlobalKey<FormState>();
    final result = await _inputDialog<Map<String, dynamic>>(
      controllers: [reference],
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, localSetState) => AlertDialog(
          title: Text(l10n.inventoryCostPolicy),
          content: SizedBox(
            width: 500,
            child: Form(
              key: form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(l10n.inventoryCostPolicyHint),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.inventoryCostEnabled),
                    value: enabled,
                    onChanged: (value) => localSetState(() => enabled = value),
                  ),
                  UtenDateField(
                    label: l10n.inventoryCostEffectiveDate,
                    value: effective,
                    onChanged: (value) =>
                        localSetState(() => effective = value),
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                  TextFormField(
                    errorBuilder: utenTextFieldErrorBuilder,
                    controller: reference,
                    minLines: 1,
                    maxLines: 3,
                    decoration: UtenInputDecoration(
                      InputDecoration(labelText: l10n.inventoryCostEvidence),
                    ),
                    validator: (value) =>
                        enabled && (value?.trim().length ?? 0) < 8
                        ? l10n.inventoryCostEvidenceRequired
                        : null,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            UtenButton(
              type: UtenButtonType.secondary,
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(l10n.commonCancel),
            ),
            UtenButton(
              onPressed: () {
                if (form.currentState!.validate()) {
                  Navigator.pop(dialogContext, {
                    'enabled': enabled,
                    'effectiveFrom': _date(effective),
                    'reconciliationReference': reference.text.trim(),
                    'expectedVersion': policy['version'],
                  });
                }
              },
              child: Text(l10n.commonConfirm),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    final action = result['enabled'] == true
        ? l10n.inventoryCostEnable
        : l10n.inventoryCostDisable;
    if (!await _confirm(
          action,
          '${l10n.inventoryCostEffectiveDate}: ${result['effectiveFrom']}\n${l10n.inventoryCostEvidence}: ${result['reconciliationReference']}\n${l10n.inventoryCostPolicyHint}',
        ) ||
        !mounted) {
      return;
    }
    await _write(() async {
      await _api.put('$inventoryCostPostingEndpoint/policy', body: result);
    });
  }

  Future<void> _choosePeriod(Map<String, dynamic> row) async {
    if (!_canPost || _busy) return;
    final l10n = AppLocalizations.of(context);
    final open = _periods
        .where((period) => period['status'] == 'OPEN')
        .toList();
    if (open.isEmpty) {
      context.appError(l10n.inventoryCostNoOpenPeriod);
      return;
    }
    String selected = open.any((period) => period['period'] == _period)
        ? _period!
        : open.last['period'].toString();
    final reason = TextEditingController();
    final form = GlobalKey<FormState>();
    final result = await _inputDialog<Map<String, dynamic>>(
      controllers: [reason],
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, localSetState) => AlertDialog(
          title: Text(l10n.inventoryCostAssignPeriod),
          content: SizedBox(
            width: 500,
            child: Form(
              key: form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SelectableText(
                    '${l10n.inventoryCostSource}: ${_value(row, 'postingId')}\n${l10n.inventoryCostAmount}: ${_value(row, 'amountLocal')}\n${l10n.inventoryCostSourcePeriod}: ${_value(row, 'sourcePeriod')}',
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: selected,
                    decoration: UtenInputDecoration(
                      InputDecoration(
                        labelText: l10n.inventoryCostTargetPeriod,
                      ),
                    ),
                    items: open
                        .map(
                          (period) => DropdownMenuItem(
                            value: period['period'].toString(),
                            child: Text(period['period'].toString()),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) localSetState(() => selected = value);
                    },
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                  TextFormField(
                    errorBuilder: utenTextFieldErrorBuilder,
                    controller: reason,
                    decoration: UtenInputDecoration(
                      InputDecoration(labelText: l10n.inventoryCostReason),
                    ),
                    validator: (value) => (value?.trim().length ?? 0) < 4
                        ? l10n.inventoryCostReasonRequired
                        : null,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            UtenButton(
              type: UtenButtonType.secondary,
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(l10n.commonCancel),
            ),
            UtenButton(
              onPressed: () {
                if (form.currentState!.validate()) {
                  Navigator.pop(dialogContext, {
                    'targetPeriod': selected,
                    'reason': reason.text.trim(),
                  });
                }
              },
              child: Text(l10n.commonConfirm),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    if (!await _confirm(
          l10n.inventoryCostAssignPeriod,
          '${l10n.inventoryCostSource}: ${_value(row, 'postingId')}\n${l10n.inventoryCostAmount}: ${_value(row, 'amountLocal')}\n${l10n.inventoryCostTargetPeriod}: ${result['targetPeriod']}\n${l10n.inventoryCostReason}: ${result['reason']}',
        ) ||
        !mounted) {
      return;
    }
    await _write(() async {
      await _api.post(
        '$inventoryCostPostingEndpoint/postings/${row['postingId']}/period',
        body: result,
      );
    });
  }

  Future<void> _post() async {
    final period = _period;
    if (!_canPost || period == null || _busy) return;
    final l10n = AppLocalizations.of(context);
    final ready = _rows
        .where(
          (row) =>
              row['targetPeriod'] == period && row['postingStatus'] == 'READY',
        )
        .length;
    if (!await _confirm(
          l10n.inventoryCostPost,
          '${l10n.inventoryCostTargetPeriod}: $period\n${l10n.inventoryCostReady}: $ready\n${l10n.inventoryCostPostHint}',
        ) ||
        !mounted) {
      return;
    }
    await _write(() async {
      await _api.post(
        '$inventoryCostPostingEndpoint/periods/$period/post',
        body: const <String, dynamic>{},
      );
    });
  }

  Future<void> _closePeriod() async {
    final row = _periods.where((item) => item['period'] == _period).firstOrNull;
    if (!_canPost || row == null || _busy) return;
    final l10n = AppLocalizations.of(context);
    final reason = TextEditingController();
    final result = await _inputDialog<String>(
      controllers: [reason],
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.inventoryCostClosePeriod),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${l10n.inventoryCostTargetPeriod}: ${row['period']}\n${l10n.inventoryCostPendingCount}: ${row['pendingCount']}\n${l10n.inventoryCostCloseHint}',
              ),
              const SizedBox(height: UtenSpacing.s12),
              TextField(
                controller: reason,
                decoration: UtenInputDecoration(
                  InputDecoration(labelText: l10n.inventoryCostReason),
                ),
              ),
            ],
          ),
        ),
        actions: [
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.commonCancel),
          ),
          UtenButton(
            onPressed: () {
              if (reason.text.trim().isNotEmpty) {
                Navigator.pop(dialogContext, reason.text.trim());
              }
            },
            child: Text(l10n.commonConfirm),
          ),
        ],
      ),
    );
    if (result == null || !mounted) return;
    await _write(() async {
      await _api.post(
        '$inventoryCostPostingEndpoint/periods/${row['period']}/close',
        body: {'expectedVersion': row['version'], 'reason': result},
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final capability = ref.watch(costWorkbenchCapabilityProvider);
    final l10n = AppLocalizations.of(context);
    if (!capability.canReadPostings) {
      return AlertDialog(
        content: Text(l10n.inventoryCostNoAccess),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _changed),
            child: Text(MaterialLocalizations.of(context).closeButtonLabel),
          ),
        ],
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
    return Dialog(
      insetPadding: const EdgeInsets.all(UtenSpacing.s12),
      child: SizedBox(
        width: 1200,
        height: MediaQuery.sizeOf(context).height * .9,
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.inventoryCostTitle,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    onPressed: _busy
                        ? null
                        : () => Navigator.pop(context, _changed),
                    icon: const Icon(Icons.close),
                    tooltip: MaterialLocalizations.of(context).closeButtonLabel,
                  ),
                ],
              ),
              Wrap(
                spacing: UtenSpacing.s8,
                runSpacing: UtenSpacing.s8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 170,
                    child: UtenDateField(
                      label: l10n.inventoryCostFrom,
                      value: _from,
                      enabled: !_busy,
                      onChanged: (value) {
                        setState(() => _from = ChinaDateTime.dateOnly(value));
                        _load();
                      },
                    ),
                  ),
                  SizedBox(
                    width: 170,
                    child: UtenDateField(
                      label: l10n.inventoryCostTo,
                      value: _to,
                      enabled: !_busy,
                      onChanged: (value) {
                        setState(() => _to = ChinaDateTime.dateOnly(value));
                        _load();
                      },
                    ),
                  ),
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
                        child: DropdownButtonFormField<String>(
                          isExpanded: true,
                          key: ValueKey(_period),
                          initialValue: _period,
                          decoration: UtenInputDecoration(
                            InputDecoration(
                              labelText: l10n.inventoryCostTargetPeriod,
                            ),
                          ),
                          items: _periods
                              .map(
                                (row) => DropdownMenuItem(
                                  value: row['period'].toString(),
                                  child: Text(
                                    '${row['period']} · ${row['status'] == 'CLOSED' ? l10n.inventoryCostClosed : l10n.inventoryCostOpen}',
                                    maxLines: 1,
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: _busy
                              ? null
                              : (value) => setState(() => _period = value),
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
                  padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
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
                  tableKey: 'finance.inventory_cost_posting',
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
            ],
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
