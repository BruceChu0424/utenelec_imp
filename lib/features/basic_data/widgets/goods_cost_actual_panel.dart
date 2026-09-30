import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_totals_summary_bar.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/formatters/money_display.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/auth/cost_workbench_capability.dart';
import '../../../shared/stock_ledger/stock_ledger_models.dart';
import '../models/goods_cost_sheet.dart';
import '../repositories/goods_cost_repository.dart';
import 'master_data_table_view.dart';

/// Reads valuation evidence only. Neither quantities nor ledger values can be
/// edited in this panel, and pending scopes remain visibly incomplete.
class GoodsCostActualPanel extends ConsumerStatefulWidget {
  const GoodsCostActualPanel({super.key, required this.goodsId});
  final String goodsId;
  @override
  ConsumerState<GoodsCostActualPanel> createState() =>
      _GoodsCostActualPanelState();
}

class _GoodsCostActualPanelState extends ConsumerState<GoodsCostActualPanel> {
  Map<String, dynamic>? _snapshot;
  List<Map<String, dynamic>> _objects = [];
  List<Map<String, dynamic>> _baselines = [];
  GoodsCostSheet? _baseline;
  String? _baselineId;
  DateTime? _from, _to;
  String? _segment, _revision, _error;
  bool _loading = false;
  int _tab = 0, _request = 0;
  AppLocalizations get _l => AppLocalizations.of(context);
  Map<String, dynamic> get _filters => {
    if (_segment != null) 'executionSegmentId': _segment,
    if (_revision != null) 'revisionId': _revision,
    if (_from != null) 'from': _from!.toIso8601String().split('T').first,
    if (_to != null) 'to': _to!.toIso8601String().split('T').first,
  };
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!ref.read(costWorkbenchCapabilityProvider).canRead) return;
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snapshot = await ref
          .read(goodsCostRepositoryProvider)
          .actual(widget.goodsId, _filters);
      final baselines = await ref
          .read(goodsCostRepositoryProvider)
          .list(widget.goodsId);
      if (!mounted || request != _request) return;
      setState(() {
        _snapshot = snapshot;
        _baselines = baselines
            .where((s) => s['status'] == 'CONFIRMED')
            .toList();
        if (_segment == null) _objects = costMaps(snapshot['costObjects']);
      });
    } catch (e) {
      if (mounted && request == _request) {
        setState(() => _error = e is ApiException ? e.message : _l.commonError);
      }
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  Widget _text(Object? value) => Text(
    costText(value) ?? '—',
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
  );
  MasterColumnDef<Map<String, dynamic>> _column(
    String key,
    String label,
    double width, {
    bool numeric = false,
    bool visible = true,
  }) => MasterColumnDef(
    key: key,
    label: label,
    width: width,
    type: numeric ? 'number' : 'text',
    defaultVisible: visible,
    value: (r) => costText(r[key]),
    cellBuilder: (_, r) => Align(
      alignment: numeric ? Alignment.centerRight : Alignment.centerLeft,
      child: Text(
        costText(r[key]) ?? '—',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: numeric ? TextAlign.right : null,
      ),
    ),
  );
  String _state(Object? state) => switch (state) {
    'FINAL' => _l.costComplete,
    'PROVISIONAL' ||
    'APPLYING' ||
    'PENDING_BASIS' ||
    'PENDING_CLASSIFICATION' => _l.costPending,
    _ => _l.costPending,
  };
  String _gapLabel(String code) => switch (code) {
    'LABOR_ACTUAL_NOT_LINKED' => _l.costGapLabor,
    'OVERHEAD_ACTUAL_NOT_LINKED' => _l.costGapOverhead,
    'NO_VALUATION_EVIDENCE' => _l.costGapNoValuation,
    'ORIGINAL_INPUT_IDENTITY_MISSING' => _l.costGapIdentity,
    'INPUT_REVISION_EVIDENCE_MISSING' ||
    'MISSING_REVISION_EVIDENCE' => _l.costGapRevision,
    'NO_APPROVED_COST_REVISION' => _l.costGapNoApprovedRevision,
    'ALLOCATION_APPLYING' || 'COST_STATE_APPLYING' => _l.costGapApplying,
    'SOURCE_REFRESH_PENDING' => _l.costGapSourceRefresh,
    'COST_STATE_PENDING_CLASSIFICATION' => _l.costGapClassification,
    'OUTPUT_BASIS_PENDING' ||
    'COST_STATE_PENDING_BASIS' => _l.costGapOutputBasis,
    'SCOPE_NOT_COMPLETE' => _l.costGapScope,
    'NO_INPUT_COST_EVIDENCE' || 'INPUT_COST_PENDING' => _l.costGapInput,
    _ => _l.costGapOther,
  };
  String _gapNext(String code) => switch (code) {
    'LABOR_ACTUAL_NOT_LINKED' ||
    'OVERHEAD_ACTUAL_NOT_LINKED' => _l.costGapActionCharges,
    'ORIGINAL_INPUT_IDENTITY_MISSING' ||
    'INPUT_REVISION_EVIDENCE_MISSING' ||
    'MISSING_REVISION_EVIDENCE' => _l.costGapActionHistory,
    'ALLOCATION_APPLYING' ||
    'COST_STATE_APPLYING' ||
    'SOURCE_REFRESH_PENDING' => _l.costGapActionRefresh,
    _ => _l.costGapActionSource,
  };
  List<Map<String, dynamic>> _pendingItems() {
    final objects = costMaps(_snapshot?['costObjects']);
    final unique = <String, Map<String, dynamic>>{};
    void add(Map<String, dynamic> gap) {
      final code = costText(gap['code']) ?? '';
      if (code.isEmpty) return;
      final object = objects
          .where((o) => o['costObjectId'] == gap['costObjectId'])
          .firstOrNull;
      unique['$code|${gap['costObjectId']}|${gap['sourceId']}'] = {
        ...gap,
        'problem': _gapLabel(code),
        'nextStep': _gapNext(code),
        'scopeName': object?['executionNo'] ?? _l.costTotalLabel,
      };
    }

    for (final gap in costMaps(_snapshot?['gaps'])) {
      add(gap);
    }
    for (final object in objects) {
      for (final code
          in (object['pendingReasons'] as List? ?? const <Object>[])
              .whereType<String>()) {
        add({
          'code': code,
          'costObjectId': object['costObjectId'],
          'sourceId': object['revisionId'],
        });
      }
    }
    return unique.values.toList();
  }

  Map<String, dynamic> _sourceFacts(Map<String, dynamic> row) {
    if (row['sourceDocId'] != null) return row;
    final match = costMaps(_snapshot?['revisions'])
        .where(
          (r) =>
              r['costObjectId'] == row['costObjectId'] &&
              r['revisionId'] == row['revisionId'],
        )
        .firstOrNull;
    return match == null
        ? row
        : {
            ...row,
            'sourceDocType': match['sourceDocType'],
            'sourceDocId': match['sourceDocId'],
            'sourceItemId': match['sourceItemId'],
          };
  }

  String? _sourceRoute(Map<String, dynamic> row) {
    final source = _sourceFacts(row);
    final path = stockSourceDocPath(
      sourceDocType: costText(source['sourceDocType']),
      sourceDocId: costText(source['sourceDocId']),
      sourceDocCode: costText(source['sourceDocCode']),
    );
    if (path == null ||
        !locationAllowedFor(
          ref.read(currentPermissionsProvider),
          false,
          path,
        )) {
      return null;
    }
    return path;
  }

  MasterColumnDef<Map<String, dynamic>> _sourceColumn() => MasterColumnDef(
    key: 'sourceDocId',
    label: _l.costSourceDocument,
    width: 125,
    value: (_) => _l.costViewSource,
    cellBuilder: (_, row) => UtenButton(
      key: ValueKey(
        'cost-actual-source-${row['sourceDocId'] ?? row['inputNodeId'] ?? row['sourceNodeId']}',
      ),
      type: UtenButtonType.tonal,
      onPressed: () {
        final path = _sourceRoute(row);
        if (path == null) {
          _showEvidence(row);
        } else {
          context.push(path);
        }
      },
      child: Text(
        _sourceRoute(row) == null ? _l.costViewEvidence : _l.costViewSource,
        maxLines: 1,
      ),
    ),
  );
  Future<void> _showPending() async {
    final pending = _pendingItems();
    final selected = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(_l.costPendingItems),
        content: SizedBox(
          width: 1150,
          height: MediaQuery.sizeOf(context).height * .65,
          child: MasterDataTableView<Map<String, dynamic>>(
            tableKey: 'master.goods.cost.pending',
            columns: [
              _column('problem', _l.costPendingItems, 290),
              _column('scopeName', _l.costEvidenceScope, 170),
              MasterColumnDef(
                key: 'nextStep',
                label: _l.costEvidenceNextStep,
                width: 470,
                value: (r) => costText(r['nextStep']),
                cellBuilder: (_, r) => Tooltip(
                  message: costText(r['nextStep']) ?? '',
                  child: _text(r['nextStep']),
                ),
              ),
              MasterColumnDef(
                key: 'evidence',
                label: _l.costViewEvidence,
                width: 110,
                value: (_) => _l.costViewEvidence,
                cellBuilder: (_, r) => UtenButton(
                  type: UtenButtonType.tonal,
                  onPressed: () => Navigator.pop(dialog, r),
                  child: Text(_l.costOpen, maxLines: 1),
                ),
              ),
            ],
            items: pending,
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(_l.commonBack),
          ),
        ],
      ),
    );
    if (selected == null || !mounted) return;
    final source =
        [
              ...costMaps(_snapshot?['inputs']),
              ...costMaps(_snapshot?['outputs']),
              ...costMaps(_snapshot?['costObjects']),
            ]
            .where(
              (r) =>
                  r['costObjectId'] == selected['costObjectId'] &&
                  (r['inputNodeId'] == selected['sourceId'] ||
                      r['sourceNodeId'] == selected['sourceId'] ||
                      r['revisionId'] == selected['sourceId']),
            )
            .firstOrNull;
    await _showEvidence({...?source, ...selected});
  }

  Future<void> _showEvidence(Map<String, dynamic> record) async {
    final row = _sourceFacts(record);
    final reasons = _pendingItems()
        .where((g) => g['costObjectId'] == row['costObjectId'])
        .map((g) => g['problem'])
        .toSet();
    final values = <Map<String, dynamic>>[];
    void add(String key, String label, Object? value) {
      if (value != null && value.toString().isNotEmpty) {
        values.add({'key': key, 'label': label, 'value': value.toString()});
      }
    }

    add(
      'problem',
      _l.costPendingItems,
      row['problem'] ?? (reasons.isEmpty ? null : reasons.join(' · ')),
    );
    add('nextStep', _l.costEvidenceNextStep, row['nextStep']);
    add('goodsName', _l.costGoodsName, row['goodsName']);
    add('goodsCode', _l.costGoodsCode, row['goodsCode']);
    add('unitName', _l.costUnit, row['unitName']);
    add('quantityBasis', _l.costQuantityBasis, switch (row['quantityBasis']) {
      'DIRECT_CONSUMPTION' => _l.costDirectConsumption,
      'PERIODIC_ALLOCATION' => _l.costPeriodicAllocation,
      'FEE_EVIDENCE' => _l.costFeeEvidence,
      _ => row['quantityBasis'],
    });
    add('amountBasis', _l.costAmountBasis, switch (row['amountBasis']) {
      'VALUATION_BOOKED_LOCAL' => _l.costBookedBasis,
      'LEGACY_UNVERIFIED' => _l.costLegacyBasis,
      'MISSING_REVISION_EVIDENCE' => _l.costGapRevision,
      _ => row['amountBasis'],
    });
    add('knownAmountLocal', _l.costLocalAmount, row['knownAmountLocal']);
    add('exactAmountLower', _l.costAmountLower, row['exactAmountLower']);
    add('exactAmountUpper', _l.costAmountUpper, row['exactAmountUpper']);
    add('valueRevision', _l.costValueRevision, row['valueRevision']);
    add('revisionId', _l.costVersion, row['revisionId']);
    add('sourceDocType', _l.costSourceType, row['sourceDocType']);
    add('sourceDocId', _l.costSourceIdentifier, row['sourceDocId']);
    add('sourceItemId', _l.costSourceLineIdentifier, row['sourceItemId']);
    add(
      'inputNodeId',
      _l.costEvidenceIdentifier,
      row['inputNodeId'] ?? row['sourceNodeId'] ?? row['sourceId'],
    );
    add('costObjectId', _l.costEvidenceScope, row['costObjectId']);
    add('code', _l.costGapCode, row['code']);
    add('occurredAt', _l.costUpdated, row['occurredAt'] ?? row['businessDate']);
    final path = _sourceRoute(row);
    await showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        key: const Key('cost-actual-evidence'),
        title: Text(_l.costViewEvidence),
        content: SizedBox(
          width: 1000,
          height: MediaQuery.sizeOf(context).height * .68,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (path == null) ...[
                Text(_l.costSourceUnavailable),
                const SizedBox(height: 12),
              ],
              Expanded(
                child: MasterDataTableView<Map<String, dynamic>>(
                  tableKey: 'master.goods.cost.actual.evidence',
                  columns: [
                    _column('label', _l.costEvidenceField, 220),
                    MasterColumnDef(
                      key: 'value',
                      label: _l.costEvidenceValue,
                      width: 620,
                      value: (r) => costText(r['value']),
                      cellBuilder: (_, r) => Tooltip(
                        message: costText(r['value']) ?? '',
                        child: _text(r['value']),
                      ),
                    ),
                    MasterColumnDef(
                      key: 'copy',
                      label: _l.costCopyValue,
                      width: 100,
                      value: (_) => _l.costCopyValue,
                      cellBuilder: (_, r) => IconButton(
                        key: ValueKey('cost-actual-copy-${r['key']}'),
                        tooltip: _l.costCopyValue,
                        icon: const Icon(Icons.copy_outlined),
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: costText(r['value']) ?? ''),
                          );
                          if (mounted) context.appSuccess(_l.commonSuccess);
                        },
                      ),
                    ),
                  ],
                  items: values,
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
          if (path != null)
            TextButton(
              onPressed: () {
                Navigator.pop(dialog);
                context.push(path);
              },
              child: Text(_l.costViewSource),
            ),
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(_l.commonBack),
          ),
        ],
      ),
    );
  }

  Widget _baselineComparison(Map<String, dynamic> summary) {
    final baseline = _baseline;
    final sameQuantity =
        baseline != null &&
        financeExactTrimmed(costText(baseline.input['batchQty'])) ==
            financeExactTrimmed(costText(summary['outputQtyBase']));
    final baselineLocal = baseline == null
        ? null
        : financeExactMultiplyTexts([
            costText(baseline.calculation.totals['knownTotal']),
            costText(baseline.input['exchangeRateToLocal']),
          ]);
    final complete =
        baseline?.calculation.complete == true &&
        summary['fullCostComplete'] == true &&
        summary['pending'] != true;
    final difference = complete && sameQuantity && baselineLocal != null
        ? financeExactSumTexts([
            costText(summary['allocatedOutputCostLocal']),
            '-$baselineLocal',
          ])
        : null;
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          UtenDropdownField(
            label: _l.costBudgetBaseline,
            value: _baselineId,
            items: [
              for (final b in _baselines)
                UtenDropdownItem(
                  value: costText(b['id']),
                  label:
                      '${b['name'] ?? ''} · ${_l.costBatch} ${b['batchQty']}',
                ),
            ],
            onChanged: (id) async {
              if (id == null) {
                setState(() {
                  _baselineId = null;
                  _baseline = null;
                });
                return;
              }
              setState(() => _baselineId = id);
              try {
                final sheet = await ref
                    .read(goodsCostRepositoryProvider)
                    .detail(id);
                if (mounted && _baselineId == id) {
                  setState(
                    () =>
                        _baseline = sheet.status == 'CONFIRMED' ? sheet : null,
                  );
                }
              } catch (e) {
                if (mounted && _baselineId == id) {
                  setState(
                    () =>
                        _error = e is ApiException ? e.message : _l.commonError,
                  );
                }
              }
            },
          ),
          if (baseline != null) ...[
            const SizedBox(height: 12),
            Text(
              !sameQuantity || baselineLocal == null
                  ? _l.costBasisMismatch
                  : !complete
                  ? _l.costCoverageMismatch
                  : _l.costVariance,
            ),
            const SizedBox(height: 8),
            UtenTotalsSummaryBar(
              entries: [
                UtenTotalEntry(
                  _l.costBudgetLocal,
                  financeMoneyText(baselineLocal),
                ),
                UtenTotalEntry(
                  _l.costActualRecorded,
                  financeMoneyText(
                    costText(summary['allocatedOutputCostLocal']),
                  ),
                ),
                if (difference != null)
                  UtenTotalEntry(_l.costVariance, financeMoneyText(difference)),
              ],
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(costWorkbenchCapabilityProvider).canRead) {
      return Center(child: Text(_l.costNoPermission));
    }
    final summary = costMap(_snapshot?['summary']);
    final rows = costMaps(
      _snapshot?[switch (_tab) {
        1 => 'outputs',
        2 => 'costObjects',
        _ => 'inputs',
      }],
    );
    final columns = <MasterColumnDef<Map<String, dynamic>>>[
      if (_tab == 0) ...[
        _column('goodsName', _l.costGoodsName, 220),
        _column('goodsCode', _l.costGoodsCode, 150),
        _column('unitName', _l.costUnit, 100),
        _column('netQtyBase', _l.costActualQty, 140, numeric: true),
        _column('knownAmountLocal', _l.costLocalAmount, 170, numeric: true),
        _column(
          'allocatedAmountLocal',
          _l.costActualOutput,
          170,
          numeric: true,
        ),
        _column('heldAmountLocal', _l.costActualWip, 150, numeric: true),
        _column('sourceDocType', _l.costSourceType, 150, visible: false),
        _sourceColumn(),
      ] else if (_tab == 1) ...[
        _column('businessDate', _l.costEffectiveDate, 160),
        _column('effectiveQtyBase', _l.costActualQty, 150, numeric: true),
        _column('knownAmountLocal', _l.costLocalAmount, 180, numeric: true),
        _column('sourceDocType', _l.costSourceType, 150, visible: false),
        _sourceColumn(),
      ] else ...[
        _column('executionNo', _l.costSegment, 200),
        _column('revisionVersion', _l.costVersion, 110),
        _column('scopeOutputQtyBase', _l.costActualQty, 150, numeric: true),
        _column(
          'allocatedOutputCostLocal',
          _l.costActualOutput,
          170,
          numeric: true,
        ),
        _column('heldWipLocal', _l.costActualWip, 150, numeric: true),
        MasterColumnDef(
          key: 'state',
          label: _l.costStatus,
          width: 140,
          value: (r) => _state(r['state']),
          cellBuilder: (_, r) => InkWell(
            onTap: () => _showEvidence(r),
            child: Tooltip(
              message: _l.costViewEvidence,
              child: _text(_state(r['state'])),
            ),
          ),
        ),
      ],
      if (_tab != 2)
        MasterColumnDef(
          key: 'pending',
          label: _l.costStatus,
          width: 140,
          value: (r) => r['pending'] == true ? _l.costPending : _l.costComplete,
          cellBuilder: (_, r) => InkWell(
            onTap: () => _showEvidence(r),
            child: Tooltip(
              message: _l.costViewEvidence,
              child: _text(
                r['pending'] == true ? _l.costPending : _l.costComplete,
              ),
            ),
          ),
        ),
    ];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 60),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          UtenCard(
            child: LayoutBuilder(
              builder: (context, box) {
                final width = box.maxWidth < 480 ? box.maxWidth : 230.0;
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    SizedBox(
                      width: width,
                      child: UtenDateField(
                        label: _l.costActualFrom,
                        value: _from,
                        onChanged: (d) => setState(() => _from = d),
                      ),
                    ),
                    SizedBox(
                      width: width,
                      child: UtenDateField(
                        label: _l.costActualTo,
                        value: _to,
                        onChanged: (d) => setState(() => _to = d),
                      ),
                    ),
                    SizedBox(
                      width: width,
                      child: UtenDropdownField(
                        label: _l.costSegment,
                        value: _segment,
                        items: [
                          for (final object in {
                            for (final o in _objects)
                              costText(o['executionSegmentId']): o,
                          }.values)
                            if (object['executionSegmentId'] != null)
                              UtenDropdownItem(
                                value: costText(object['executionSegmentId']),
                                label: costText(object['executionNo']) ?? '—',
                              ),
                        ],
                        onChanged: (v) => setState(() => _segment = v),
                      ),
                    ),
                    SizedBox(
                      width: width,
                      child: UtenDropdownField(
                        label: _l.costVersion,
                        value: _revision,
                        items: [
                          for (final revision in {
                            for (final r in costMaps(_snapshot?['revisions']))
                              r['revisionId']: r,
                          }.values)
                            UtenDropdownItem(
                              value: costText(revision['revisionId']),
                              label:
                                  '${_l.costVersion} ${revision['version']} · ${revision['occurredAt'] ?? ''}',
                            ),
                        ],
                        onChanged: (v) => setState(() => _revision = v),
                      ),
                    ),
                    UtenButton(
                      onPressed: _loading ? null : _load,
                      child: Text(_l.commonRefresh),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (_loading) const LinearProgressIndicator(),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (label, key) in [
                (_l.costScopeInput, 'knownInputCostLocal'),
                (_l.costPeriodOutput, 'allocatedOutputCostLocal'),
                (_l.costExcludedOutput, 'excludedOutputCostLocal'),
                (_l.costActualWip, 'heldWipLocal'),
                (_l.costUnitCost, 'actualUnitCostLocal'),
              ])
                SizedBox(
                  width: 212,
                  child: UtenCard(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label),
                        const SizedBox(height: 8),
                        Text(
                          financeMoneyText(costText(summary[key])),
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          if (_snapshot != null && summary['fullCostComplete'] != true)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(_l.costActualIncomplete),
            ),
          if (_pendingItems().isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: UtenButton(
                key: const Key('cost-actual-pending'),
                type: UtenButtonType.tonal,
                onPressed: _showPending,
                child: Text(
                  '${_l.costPendingItems} (${_pendingItems().length})',
                ),
              ),
            ),
          if (_snapshot != null) ...[
            const SizedBox(height: 12),
            _baselineComparison(summary),
            const SizedBox(height: 12),
          ],
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (index, label) in [
                (0, _l.costActualKnown),
                (1, _l.costActualOutput),
                (2, _l.costVersions),
              ])
                UtenButton(
                  type: _tab == index
                      ? UtenButtonType.primary
                      : UtenButtonType.tonal,
                  onPressed: () => setState(() => _tab = index),
                  child: Text(label),
                ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 520,
            child: MasterDataTableView<Map<String, dynamic>>(
              key: ValueKey('cost-actual-$_tab'),
              tableKey: 'master.goods.cost.actual.$_tab',
              columns: columns,
              items: rows,
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
              isLoading: _loading,
              emptyMessage: _l.costNoActual,
              summaryBar: UtenTotalsSummaryBar(
                entries: [
                  UtenTotalEntry(
                    _l.costActualOutput,
                    financeMoneyText(
                      costText(summary['allocatedOutputCostLocal']),
                    ),
                  ),
                  UtenTotalEntry(
                    _l.costActualQty,
                    costText(summary['outputQtyBase']) ?? '—',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (_snapshot != null &&
              ref.watch(costWorkbenchCapabilityProvider).canExport)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final format in ['xlsx', 'pdf'])
                  UtenExportButton(
                    endpoint: '${DioGoodsCostRepository.base}/actual/export',
                    report: '',
                    queryParams: const {},
                    requiredPermission:
                        CostWorkbenchCapability.exportPermission,
                    enabled: !_loading,
                    tableKey: 'master.goods.cost.actual.$_tab',
                    label: format == 'xlsx'
                        ? _l.costDownloadExcel
                        : _l.costDownloadPdf,
                    prepareExport: () async => UtenExportSelection(
                      extension: format,
                      filename: 'actual_cost_${widget.goodsId}',
                      bodyParams: {
                        'goodsId': widget.goodsId,
                        ...costMap(_snapshot?['filter']),
                        'format': format,
                        'expectedDigest': _snapshot?['contentDigest'],
                      },
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
