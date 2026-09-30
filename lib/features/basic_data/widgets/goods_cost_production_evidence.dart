import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../shared/auth/cost_workbench_capability.dart';
import '../models/goods_cost_sheet.dart';
import '../repositories/goods_cost_repository.dart';
import 'master_data_table_view.dart';

/// Current production evidence is read independently of a costing draft. It is
/// never captured into DraftInput, written to a cost version or used as batchQty.
class GoodsCostProductionEvidence extends ConsumerStatefulWidget {
  const GoodsCostProductionEvidence({
    super.key,
    required this.goodsId,
    required this.onOpenCosts,
  });
  final String goodsId;
  final ValueChanged<String> onOpenCosts;
  @override
  ConsumerState<GoodsCostProductionEvidence> createState() =>
      _GoodsCostProductionEvidenceState();
}

class _GoodsCostProductionEvidenceState
    extends ConsumerState<GoodsCostProductionEvidence> {
  Map<String, dynamic>? _summary;
  bool _loading = true, _failed = false;
  int _request = 0;
  AppLocalizations get _l => AppLocalizations.of(context);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didUpdateWidget(covariant GoodsCostProductionEvidence oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.goodsId != widget.goodsId) unawaited(_load());
  }

  Future<void> _load() async {
    if (!mounted || !ref.read(costWorkbenchCapabilityProvider).canRead) return;
    final request = ++_request;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final result = await ref
          .read(goodsCostRepositoryProvider)
          .productionOutput(widget.goodsId);
      if (mounted && request == _request) {
        setState(() {
          _summary = result;
          _failed = !const {
            'NONE',
            'IN_PROGRESS',
            'READY',
            'PENDING_UNIT',
          }.contains(result['state']);
        });
      }
    } catch (_) {
      if (mounted && request == _request) setState(() => _failed = true);
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  String _label() {
    if (_loading) return _l.costProductionLoading;
    if (_failed) return _l.costProductionUnavailable;
    if (_summary?['state'] == 'NONE') return _l.costProductionNone;
    if (_summary?['state'] == null) return _l.costProductionUnavailable;
    if (_summary?['state'] == 'PENDING_UNIT') return _l.costProductionPending;
    final qty = costText(_summary?['effectiveCompletedQty']);
    if (qty == null) return _l.costProductionUnavailable;
    final unit = costText(_summary?['unitName']);
    if (unit == null || unit.isEmpty) return _l.costProductionUnitPending;
    return _l.costRecentProductionLabel(
      costText(_summary?['scopeNo']) ?? '—',
      qty,
      unit,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(costWorkbenchCapabilityProvider).canRead) {
      return Text(_l.costNoPermission);
    }
    final label = _label();
    if (_loading || _summary?['state'] == 'NONE' && !_failed) {
      return Text(
        label,
        key: const Key('cost-production-summary'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    return Tooltip(
      message: '$label\n${_l.costProductionScopeHelp}',
      child: UtenButton(
        key: const Key('cost-production-summary'),
        type: UtenButtonType.tonal,
        onPressed: _failed ? _load : _showEvidence,
        child: Flexible(
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
  }

  Future<void> _showEvidence() async {
    if (!ref.read(costWorkbenchCapabilityProvider).canRead) return;
    final data = _summary;
    if (data == null) return;
    final pendingUnit =
        data['state'] == 'PENDING_UNIT' ||
        costText(data['unitName'])?.isNotEmpty != true;
    final rows = <Map<String, dynamic>>[
      {'label': _l.costProductionBatch, 'value': data['scopeNo']},
      if (!pendingUnit) ...[
        {
          'label': _l.costApprovedEffectiveOutput,
          'value': data['effectiveCompletedQty'],
        },
        {
          'label': _l.costApprovedReportedOutput,
          'value': data['approvedReportedQty'],
        },
        {'label': _l.costFqcDeductedOutput, 'value': data['fqcDeductedQty']},
        {
          'label': _l.costReportedDefectOutput,
          'value': data['reportedDefectQty'],
        },
        {'label': _l.costUnit, 'value': data['unitName']},
      ],
      {'label': _l.costProductionFirstReport, 'value': data['firstReportDate']},
      {'label': _l.costProductionLastReport, 'value': data['lastReportDate']},
      {'label': _l.costUpdated, 'value': data['lastReportUpdatedAt']},
      {
        'label': _l.costProductionReportCount,
        'value': data['approvedReportCount'],
      },
      {'label': _l.costProductionMemberCount, 'value': data['memberCount']},
      {
        'label': _l.costProductionDraftReports,
        'value': data['hasDraftReports'] == true ? _l.costYes : _l.costNo,
      },
      for (final source in (data['sourceCodes'] as List? ?? const []))
        {'label': _l.costProductionSource, 'value': _sourceLabel(source)},
      for (final issue in (data['issues'] as List? ?? const []))
        {'label': _l.costPending, 'value': _issueLabel(issue)},
    ];
    final open = await showDialog<bool>(
      context: context,
      builder: (dialog) => Consumer(
        builder: (context, ref, _) {
          if (!mounted || !ref.watch(costWorkbenchCapabilityProvider).canRead) {
            return AlertDialog(
              content: Text(AppLocalizations.of(context).costNoPermission),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialog),
                  child: Text(AppLocalizations.of(context).commonBack),
                ),
              ],
            );
          }
          return AlertDialog(
            title: Text(_l.costProductionEvidence),
            content: SizedBox(
              width: 820,
              height: MediaQuery.sizeOf(context).height * .65,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(_l.costProductionScopeHelp),
                  const SizedBox(height: 12),
                  Expanded(
                    child: MasterDataTableView<Map<String, dynamic>>(
                      tableKey: 'master.goods.cost.production.evidence',
                      columns: [
                        MasterColumnDef(
                          key: 'label',
                          label: _l.costEvidenceField,
                          width: 260,
                          value: (r) => costText(r['label']),
                          cellBuilder: (_, r) => _cell(r['label']),
                        ),
                        MasterColumnDef(
                          key: 'value',
                          label: _l.costEvidenceValue,
                          width: 390,
                          value: (r) => costText(r['value']),
                          cellBuilder: (_, r) => _cell(r['value']),
                        ),
                      ],
                      items: rows,
                      facets: const {},
                      nullCounts: const {},
                      filters: const {},
                      onFilterChanged: (_, _) {},
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(dialog, false);
                  _load();
                },
                child: Text(_l.commonRefresh),
              ),
              if (data['scopeId'] != null) ...[
                TextButton(
                  onPressed: () => Clipboard.setData(
                    ClipboardData(text: data['scopeId'].toString()),
                  ),
                  child: Text(_l.costProductionCopyScope),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(dialog, true),
                  child: Text(_l.costProductionOpenCosts),
                ),
              ],
              TextButton(
                onPressed: () => Navigator.pop(dialog, false),
                child: Text(_l.commonBack),
              ),
            ],
          );
        },
      ),
    );
    if (open == true &&
        mounted &&
        data['scopeId'] != null &&
        ref.read(costWorkbenchCapabilityProvider).canRead) {
      widget.onOpenCosts(data['scopeId'].toString());
    }
  }

  String _sourceLabel(Object? value) => switch (value) {
    'APPROVED_DAILY_REPORT' => _l.costProductionSourceReport,
    'EXECUTION_FAMILY' => _l.costProductionSourceFamily,
    'WORKBENCH_EFFECTIVE_PROGRESS' => _l.costProductionSourceProgress,
    'FROZEN_REPORTING_UNIT' => _l.costProductionSourceUnit,
    'INITIAL_REPORT_DEFECTS' => _l.costProductionSourceDefects,
    _ => _l.costProductionSourceOther,
  };
  String _issueLabel(Object? value) => switch (value) {
    'REPORTING_UNIT_IDENTITY_UNPROVEN' => _l.costProductionUnitPending,
    'WORKBENCH_PROGRESS_NOT_RECONCILED' => _l.costProductionProgressPending,
    _ => _l.costProductionPending,
  };
  Widget _cell(Object? value) => Tooltip(
    message: costText(value) ?? '—',
    child: Text(
      costText(value) ?? '—',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
  );
  @override
  void dispose() {
    _request++;
    super.dispose();
  }
}
