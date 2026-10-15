import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../components/buttons/uten_button.dart';
import '../../../../components/feedback/uten_dialog.dart';
import '../../../../components/feedback/uten_inline_notice.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../shared/auth/permissions.dart';
import '../../../../shared/auth/document_permission_set.dart';
import '../../../../shared/warehouse/workshop_material_first_use_impact.dart';
import '../../../basic_data/models/goods_issue_method.dart';
import '../../../basic_data/widgets/master_data_table_view.dart';
import '../../../basic_data/repositories/goods_issue_method_repository.dart';
import '../models/stock_count_request.dart';
import '../repositories/stock_count_request_repository.dart';

typedef _CountReviewRow = ({
  StockCountRequest request,
  StockCountRequestLine line,
});

/// Opening the dialog only reads the selected requests. Approval is a single
/// command after current versions, stock changes and first-use impacts are shown.
class StockCountBatchApprovalDialog extends ConsumerStatefulWidget {
  const StockCountBatchApprovalDialog({
    super.key,
    required this.ids,
    required this.reviewRoute,
  });

  final List<String> ids;
  final String reviewRoute;

  @override
  ConsumerState<StockCountBatchApprovalDialog> createState() =>
      _StockCountBatchApprovalDialogState();
}

class _StockCountBatchApprovalDialogState
    extends ConsumerState<StockCountBatchApprovalDialog> {
  StockCountReviewAccess get _reviewAccess => StockCountReviewAccess(
    ref.read(currentPermissionsProvider),
    superAdmin: ref.read(isSuperAdminProvider),
  );
  List<StockCountRequest>? _requests;
  String? _error;
  final _previews = <String, GoodsIssueMethodPreview>{};
  final _previewErrors = <String, String>{};
  final _previewLoading = <String>{};
  int _sequence = 0;

  List<({String key, StockCountRequestLine line})> get _setups => [
    for (final request in _requests ?? const <StockCountRequest>[])
      for (final line in request.lines)
        if (line.materialSetupBasis != null)
          (key: '${request.id}:${line.goodsId}', line: line),
  ];

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    final sequence = ++_sequence;
    setState(() {
      _requests = null;
      _error = null;
      _previews.clear();
      _previewErrors.clear();
      _previewLoading.clear();
    });
    try {
      final repo = ref.read(stockCountRequestRepositoryProvider);
      final requests = <StockCountRequest>[];
      for (final id in widget.ids) {
        final detail = await repo.detail(id);
        if (!mounted || sequence != _sequence) return;
        if (detail.id != id || detail.reviewRoute != widget.reviewRoute) {
          throw const FormatException('盘点不属于当前审核队列，请刷新后重新选择');
        }
        if (detail.status != 'PENDING' ||
            !detail.canApprove ||
            detail.lines.any((line) => line.stale)) {
          throw FormatException('${detail.requestNo} 已被办理、库存变化或无审核权限，请刷新');
        }
        requests.add(detail);
      }
      if (!mounted || sequence != _sequence) return;
      setState(() => _requests = requests);
      if (!_reviewAccess.canConfigureMaterial) {
        return;
      }
      var next = 0;
      final setups = _setups;
      await Future.wait([
        for (var worker = 0; worker < 4 && worker < setups.length; worker++)
          () async {
            while (mounted && sequence == _sequence && next < setups.length) {
              final item = setups[next++];
              await _loadPreview(item.key, item.line, sequence);
            }
          }(),
      ]);
    } catch (error) {
      if (!mounted || sequence != _sequence) return;
      setState(() {
        _error = error is ApiException
            ? error.message
            : error is FormatException
            ? error.message
            : '读取盘点明细失败，请重试';
      });
    }
  }

  Future<void> _loadPreview(
    String key,
    StockCountRequestLine line,
    int sequence,
  ) async {
    if (!mounted || sequence != _sequence || _previewLoading.contains(key)) {
      return;
    }
    if (!_reviewAccess.canConfigureMaterial) {
      return;
    }
    setState(() {
      _previews.remove(key);
      _previewErrors.remove(key);
      _previewLoading.add(key);
    });
    try {
      final preview = await ref
          .read(goodsIssueMethodRepositoryProvider)
          .preview(
            line.goodsId,
            target: 'PERIODIC',
            costBasis: line.materialSetupBasis,
          );
      if (mounted && sequence == _sequence) {
        setState(() => _previews[key] = preview);
      }
    } catch (error) {
      if (mounted && sequence == _sequence) {
        setState(
          () => _previewErrors[key] = error is ApiException
              ? error.message
              : '用途影响读取失败，请重试',
        );
      }
    } finally {
      if (mounted && sequence == _sequence) {
        setState(() => _previewLoading.remove(key));
      }
    }
  }

  String _quantity(String? value, String unit) => value == null
      ? '—'
      : unit.isEmpty
      ? value
      : '$value $unit';

  @override
  Widget build(BuildContext context) {
    final requests = _requests;
    final permissions = ref.watch(currentPermissionsProvider);
    final admin = ref.watch(isSuperAdminProvider);
    final access = StockCountReviewAccess(permissions, superAdmin: admin);
    final canReview = access.canReview(widget.reviewRoute);
    final canConfigure = access.canConfigureMaterial;
    final setups = _setups;
    final ready =
        requests != null &&
        canReview &&
        (setups.isEmpty ||
            setups.every(
              (item) => canConfirmWorkshopMaterialFirstUse(
                preview: _previews[item.key],
                goodsId: item.line.goodsId,
                basis: item.line.materialSetupBasis!,
                expectedVersion: item.line.goodsVersion,
                canConfigure: canConfigure,
                loading: _previewLoading.contains(item.key),
              ),
            ));
    return UtenAlertDialog(
      key: const Key('stock-count-batch-dialog'),
      maxWidth: 1000,
      title: Text('批量通过(${widget.ids.length} 笔)'),
      content: SizedBox(
        width: 920,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null)
              UtenInlineNotice(
                message: _error!,
                level: UtenInlineNoticeLevel.error,
              )
            else if (requests == null)
              const Center(child: CircularProgressIndicator())
            else ...[
              const Text('确认后按以下实盘数量、重量更新库存；任一笔变化，整批保持原样。'),
              SizedBox(
                height:
                    ((requests.fold<int>(
                                  0,
                                  (sum, request) => sum + request.lines.length,
                                ) +
                                1) *
                            48)
                        .clamp(120, 320)
                        .toDouble(),
                child: MasterDataTableView<_CountReviewRow>(
                  tableKey: 'stock.count.batch_review.lines',
                  showColumnChooser: false,
                  showFullscreenToggle: false,
                  rowKeyOf: (row) => '${row.request.id}:${row.line.key}',
                  items: [
                    for (final request in requests)
                      for (final line in request.lines)
                        (request: request, line: line),
                  ],
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
                  columns: [
                    MasterColumnDef(
                      key: 'document',
                      label: '盘点单 / 仓库',
                      width: 220,
                      value: (row) =>
                          '${row.request.requestNo} · ${row.request.warehouseName}',
                    ),
                    MasterColumnDef(
                      key: 'goods',
                      label: '物料',
                      width: 220,
                      value: (row) => [
                        row.line.goodsName,
                        if (row.line.colorName?.isNotEmpty == true)
                          row.line.colorName!,
                      ].join(' · '),
                    ),
                    MasterColumnDef(
                      key: 'beforeQty',
                      label: '账面数量',
                      width: 140,
                      value: (row) =>
                          _quantity(row.line.beforeQty, row.line.unitName),
                    ),
                    MasterColumnDef(
                      key: 'targetQty',
                      label: '实盘数量',
                      width: 140,
                      emphasized: true,
                      value: (row) =>
                          _quantity(row.line.targetQty, row.line.unitName),
                    ),
                    MasterColumnDef(
                      key: 'beforeWeight',
                      label: '账面重量',
                      width: 140,
                      value: (row) => _quantity(row.line.beforeWeightKg, 'kg'),
                    ),
                    MasterColumnDef(
                      key: 'targetWeight',
                      label: '实盘重量',
                      width: 140,
                      emphasized: true,
                      value: (row) => _quantity(row.line.targetWeightKg, 'kg'),
                    ),
                  ],
                ),
              ),
              if (setups.isNotEmpty && !canConfigure)
                const UtenInlineNotice(
                  message: '首次材料用途需要货品及 BOM 编辑权限。',
                  level: UtenInlineNoticeLevel.warning,
                ),
              for (final item in setups)
                ExpansionTile(
                  key: ValueKey('stock-count-batch-setup-${item.key}'),
                  title: Text('${item.line.goodsName} · 首次用途及 BOM 影响'),
                  subtitle: _previewLoading.contains(item.key)
                      ? const Text('正在核对')
                      : _previewErrors[item.key] != null
                      ? Text(_previewErrors[item.key]!)
                      : null,
                  children: [
                    if (_previews[item.key] case final preview?)
                      WorkshopMaterialFirstUseImpact(
                        preview: preview,
                        goodsId: item.line.goodsId,
                        basis: item.line.materialSetupBasis!,
                        expectedVersion: item.line.goodsVersion,
                        approvalContext: true,
                      ),
                    if (_previewErrors[item.key] != null)
                      UtenButton(
                        type: UtenButtonType.secondary,
                        onPressed: canReview && canConfigure
                            ? () => _loadPreview(item.key, item.line, _sequence)
                            : null,
                        child: const Text('重新核对'),
                      ),
                  ],
                ),
            ],
          ],
        ),
      ),
      actions: [
        UtenButton(
          type: UtenButtonType.ghost,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        if (_error != null)
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: _load,
            child: const Text('重试'),
          ),
        UtenButton(
          key: const Key('stock-count-batch-confirm'),
          type: UtenButtonType.success,
          onPressed: ready ? () => Navigator.of(context).pop(requests) : null,
          child: const Text('确认批量通过'),
        ),
      ],
    );
  }
}
