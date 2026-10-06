import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../../components/buttons/uten_back_button.dart';
import '../../../../components/buttons/uten_button.dart';
import '../../../../components/feedback/uten_inline_notice.dart';
import '../../../../components/inputs/uten_table_cell_action.dart';
import '../../../../components/layout/uten_app_bar.dart';
import '../../../../components/layout/uten_content_container.dart';
import '../../../../components/layout/uten_filter_toolbar.dart';
import '../../../../components/layout/uten_floating_action_group.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/router/nav_helpers.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../../core/ui/app_notification.dart';
import '../../../../core/utils/display_datetime.dart';
import '../../../../shared/auth/permissions.dart';
import '../../../../shared/badges/badge_registry.dart';
import '../../../../shared/formatters/exact_decimal.dart';
import '../../../../shared/models/paged_result.dart';
import '../../../../shared/warehouse/warehouse_task_scope.dart';
import '../../../basic_data/models/goods_issue_method.dart';
import '../../../basic_data/repositories/goods_issue_method_repository.dart';
import '../../../basic_data/widgets/master_data_table_view.dart';
import '../../../../shared/warehouse/workshop_material_first_use_impact.dart';
import '../models/stock_count_request.dart';
import '../repositories/stock_count_request_repository.dart';

/// A submitted stock count changes stock only after its designated reviewer approves.
class StockCountReviewPage extends ConsumerStatefulWidget {
  const StockCountReviewPage({
    super.key,
    this.reviewRoute,
    this.requestId,
    this.embedded = false,
    this.externalHeader,
    this.externalRefreshTick,
    this.warehouseScope = const WarehouseTaskScope.all(),
    this.keyword,
    this.onChanged,
  });
  final String? reviewRoute;
  final String? requestId;
  final bool embedded;
  final Widget? externalHeader;
  final int? externalRefreshTick;
  final WarehouseTaskScope warehouseScope;
  final String? keyword;
  final VoidCallback? onChanged;

  @override
  ConsumerState<StockCountReviewPage> createState() =>
      _StockCountReviewPageState();
}

class _StockCountReviewPageState extends ConsumerState<StockCountReviewPage> {
  PagedResult<StockCountRequest>? _page;
  StockCountRequest? _detail;
  String _status = 'PENDING';
  String? _error;
  bool _loading = true;
  bool _working = false;
  bool _confirming = false;
  int _sequence = 0;
  final _keys = <String, String>{};
  final _setupPreviews = <String, GoodsIssueMethodPreview>{};
  final _setupErrors = <String, String>{};
  final _setupLoading = <String>{};

  bool get _authorized {
    final permission = switch (widget.reviewRoute) {
      'FINANCE' => Perm.stockCountFinanceReview,
      'WAREHOUSE' => Perm.stockCountWarehouseReview,
      _ => Perm.stockCountSubmit,
    };
    return ref.read(isSuperAdminProvider) ||
        ref.read(currentPermissionsProvider).contains(permission);
  }

  String get _title => switch (widget.reviewRoute) {
    'FINANCE' => '普通仓盘点财务审核',
    'WAREHOUSE' => '车间内料仓盘点审核',
    _ => '我的盘点',
  };

  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => widget.requestId == null ? _load() : _open(widget.requestId!),
    );
  }

  @override
  void didUpdateWidget(covariant StockCountReviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.warehouseScope != widget.warehouseScope ||
        oldWidget.keyword != widget.keyword ||
        oldWidget.reviewRoute != widget.reviewRoute) {
      _sequence++;
      _detail = null;
      _page = null;
      _load();
    } else if (oldWidget.externalRefreshTick != widget.externalRefreshTick &&
        !_working) {
      _detail == null ? _load() : _open(_detail!.id);
    }
  }

  Future<void> _load([int page = 1]) async {
    if (!_authorized) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final sequence = ++_sequence;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(stockCountRequestRepositoryProvider)
          .list(
            reviewRoute: widget.reviewRoute,
            status: _status.isEmpty ? null : _status,
            scopeWarehouseId: widget.warehouseScope.warehouseId,
            keyword: widget.keyword,
            page: page,
          );
      if (mounted && sequence == _sequence) setState(() => _page = result);
    } catch (error) {
      if (mounted && sequence == _sequence) {
        setState(() => _error = _message(error));
      }
    } finally {
      if (mounted && sequence == _sequence) setState(() => _loading = false);
    }
  }

  Future<void> _open(String id) async {
    if (!_authorized || _working) return;
    final sequence = ++_sequence;
    setState(() {
      _loading = true;
      _error = null;
      _setupPreviews.clear();
      _setupErrors.clear();
      _setupLoading.clear();
    });
    try {
      final detail = await ref
          .read(stockCountRequestRepositoryProvider)
          .detail(id);
      if (mounted && sequence == _sequence) {
        setState(() {
          if (widget.reviewRoute != null &&
              detail.reviewRoute != widget.reviewRoute) {
            _error = '该盘点不属于当前审核队列';
          } else {
            _detail = detail;
          }
        });
        if (identical(_detail, detail)) {
          await _loadSetupPreviews(detail, sequence);
        }
      }
    } catch (error) {
      if (mounted && sequence == _sequence) {
        setState(() => _error = _message(error));
      }
    } finally {
      if (mounted && sequence == _sequence) setState(() => _loading = false);
    }
  }

  Map<String, StockCountRequestLine> _setupLines(StockCountRequest detail) => {
    for (final line in detail.lines)
      if (line.materialSetupBasis != null) line.goodsId: line,
  };

  Future<void> _loadSetupPreviews(
    StockCountRequest detail,
    int sequence,
  ) async {
    if (detail.status != 'PENDING' ||
        !detail.canApprove ||
        !_canConfigureMaterials) {
      return;
    }
    final lines = _setupLines(detail).values.toList();
    var next = 0;
    // Bound preview requests for large counts; each goods identity is read once.
    await Future.wait([
      for (var worker = 0; worker < 4 && worker < lines.length; worker++)
        () async {
          while (mounted && sequence == _sequence && next < lines.length) {
            await _loadSetupPreview(lines[next++], detail, sequence);
          }
        }(),
    ]);
  }

  Future<void> _loadSetupPreview(
    StockCountRequestLine line,
    StockCountRequest detail,
    int sequence,
  ) async {
    if (!mounted ||
        sequence != _sequence ||
        _detail?.id != detail.id ||
        !_canConfigureMaterials ||
        _setupLoading.contains(line.goodsId)) {
      return;
    }
    setState(() {
      _setupLoading.add(line.goodsId);
      _setupPreviews.remove(line.goodsId);
      _setupErrors.remove(line.goodsId);
    });
    try {
      final preview = await ref
          .read(goodsIssueMethodRepositoryProvider)
          .preview(
            line.goodsId,
            target: 'PERIODIC',
            costBasis: line.materialSetupBasis,
          );
      if (mounted && sequence == _sequence && _detail?.id == detail.id) {
        setState(() => _setupPreviews[line.goodsId] = preview);
      }
    } catch (error) {
      if (mounted && sequence == _sequence && _detail?.id == detail.id) {
        setState(() {
          _setupErrors[line.goodsId] = error is ApiException
              ? error.message
              : '用途影响读取失败，请重试';
        });
      }
    } finally {
      if (mounted && sequence == _sequence && _detail?.id == detail.id) {
        setState(() => _setupLoading.remove(line.goodsId));
      }
    }
  }

  Future<void> _decide(String action) async {
    final detail = _detail;
    if (detail == null || _working || _confirming || _loading || !_authorized) {
      return;
    }
    final decisionSequence = _sequence;
    if (action == 'approve' &&
        (!_setupReady(detail) || detail.lines.any((line) => line.stale))) {
      return;
    }
    if (action == 'approve' && !detail.canApprove ||
        action == 'reject' && !detail.canReject ||
        action == 'cancel' && !detail.canCancel) {
      return;
    }
    _confirming = true;
    String? reason;
    try {
      reason = await _confirmDecision(
        context,
        action,
        setupCount: _setupLines(detail).length,
      );
    } finally {
      _confirming = false;
    }
    if (reason == null ||
        !mounted ||
        !_authorized ||
        decisionSequence != _sequence ||
        _detail?.id != detail.id ||
        _detail?.version != detail.version ||
        (action == 'approve' && !_setupReady(detail))) {
      return;
    }
    final key = _keys.putIfAbsent(
      '${detail.id}:${detail.version}:$action:$reason',
      const Uuid().v4,
    );
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final repo = ref.read(stockCountRequestRepositoryProvider);
      final result = switch (action) {
        'approve' => await repo.approve(
          detail.id,
          expectedVersion: detail.version,
          idempotencyKey: key,
          reason: reason,
        ),
        'reject' => await repo.reject(
          detail.id,
          expectedVersion: detail.version,
          idempotencyKey: key,
          reason: reason,
        ),
        _ => await repo.cancel(
          detail.id,
          expectedVersion: detail.version,
          idempotencyKey: key,
          reason: reason,
        ),
      };
      if (!mounted) return;
      if (decisionSequence == _sequence) {
        setState(() {
          _detail = action == 'approve' ? null : result;
          if (action == 'approve') _page = null;
          _setupPreviews.clear();
          _setupErrors.clear();
          _setupLoading.clear();
        });
      }
      refreshBadges(ref);
      widget.onChanged?.call();
      if (decisionSequence != _sequence) {
        // Approval has completed, but the user is now viewing another scope.
        // Refresh that queue without restoring the old request or its message.
        await _load();
        return;
      }
      context.appSuccess(
        action == 'approve'
            ? '审核通过，库存已按盘点更新'
            : action == 'reject'
            ? '已退回，库存未改变'
            : '已撤回，库存未改变',
      );
      if (action == 'approve') await _load();
    } catch (error) {
      if (mounted && decisionSequence == _sequence) {
        setState(() => _error = _message(error));
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    ref.watch(isSuperAdminProvider);
    final allowed = _authorized;
    final content = !allowed
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 无权态也钉住宿主分类栏（2026-10-01 用户口径：分类栏不得消失）。
              if (widget.externalHeader != null) ...[
                widget.externalHeader!,
                const SizedBox(height: UtenSpacing.s12),
              ],
              const Expanded(child: Center(child: Text('未获本页盘点授权'))),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.externalHeader != null) ...[
                widget.externalHeader!,
                const SizedBox(height: UtenSpacing.s12),
              ],
              if (widget.embedded && _detail != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const Key('stock-count-review-back-to-list'),
                    onPressed: _working ? null : _backToList,
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('返回审核列表'),
                  ),
                ),
              if (_error != null)
                UtenInlineNotice(
                  message: _error!,
                  level: UtenInlineNoticeLevel.error,
                ),
              Expanded(
                child: _detail == null ? _list() : _detailBody(_detail!),
              ),
            ],
          );
    return Scaffold(
      appBar: widget.embedded
          ? null
          : UtenAppBar(
              title: _title,
              leading: UtenBackButton(
                onPressed: () {
                  if (_detail != null) {
                    _backToList();
                  } else {
                    backTo(
                      context,
                      defaultPath: widget.reviewRoute == 'FINANCE'
                          ? RouteName.finance
                          : RouteName.warehouse,
                    );
                  }
                },
              ),
              actions: [
                IconButton(
                  tooltip: '刷新',
                  onPressed: !allowed || _working
                      ? null
                      : () => _detail == null ? _load() : _open(_detail!.id),
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
      body: widget.embedded ? content : UtenContentContainer(child: content),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton: allowed && _detail != null
          ? _floatingActions(_detail!)
          : null,
    );
  }

  void _backToList() {
    if (_working) return;
    setState(() => _detail = null);
    _load();
  }

  Widget _list() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
        child: UtenFilterToolbar<String>(
          segmentsKey: const Key('stock-count-status-segments'),
          selected: {_status},
          enabled: !_working,
          segments: const [
            UtenFilterSegment(value: 'PENDING', label: '待审核'),
            UtenFilterSegment(value: 'APPROVED', label: '已通过'),
            UtenFilterSegment(value: 'REJECTED', label: '已退回'),
            UtenFilterSegment(value: 'CANCELLED', label: '已撤回'),
            UtenFilterSegment(value: '', label: '全部'),
          ],
          onSelectionChanged: (value) {
            setState(() {
              _status = value;
              _page = null;
            });
            _load();
          },
        ),
      ),
      Expanded(
        child: MasterDataTableView<StockCountRequest>(
          tableKey: 'stock.count-requests',
          columns: [
            MasterColumnDef(
              key: 'status',
              label: '状态',
              width: 72,
              value: (r) => _statusText(r.status),
            ),
            MasterColumnDef(
              key: 'requestNo',
              label: '盘点单号',
              width: 190,
              value: (r) => r.requestNo,
            ),
            MasterColumnDef(
              key: 'warehouse',
              label: '仓库',
              width: 180,
              value: (r) => r.warehouseName,
            ),
            MasterColumnDef(
              key: 'reviewRoute',
              label: '审核方',
              width: 90,
              value: (r) => r.reviewRoute == 'WAREHOUSE' ? '仓库' : '财务',
            ),
            MasterColumnDef(
              key: 'submittedBy',
              label: '提交人',
              width: 110,
              value: (r) => r.submittedByName,
            ),
            MasterColumnDef(
              key: 'submittedAt',
              label: '提交时间',
              width: 180,
              value: (r) => DisplayDateTime.format(r.submittedAt),
            ),
            MasterColumnDef(
              key: 'reason',
              label: '盘点说明',
              width: 240,
              value: (r) => r.reason,
            ),
            MasterColumnDef(
              key: 'open',
              label: '查看',
              width: 90,
              value: (_) => '查看明细',
              // 2026-10-06 行高统一口径：单行文字动作，不用 min40 的 TextButton。
              cellBuilder: (_, r) => UtenTableCellAction(
                onPressed: () => _open(r.id),
                label: '查看明细',
              ),
            ),
          ],
          items: _page?.items ?? const [],
          facets: const {},
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
          onRowTap: (r) => _open(r.id),
          isLoading: _loading && _page == null,
          emptyMessage: '暂无盘点申请',
          currentPage: _page?.page ?? 1,
          totalPages: _page?.totalPages ?? 1,
          onPageChange: _load,
          paginationScope: (
            widget.reviewRoute,
            _status,
            widget.warehouseScope,
            widget.keyword,
          ),
          onRetry: _load,
        ),
      ),
    ],
  );

  Widget _detailBody(StockCountRequest detail) {
    final stale = detail.lines.any((line) => line.stale);
    final reviewingSetup =
        detail.status == 'PENDING' &&
        detail.canApprove &&
        _setupLines(detail).isNotEmpty;
    return ListView(
      key: const Key('stock-count-detail-scroll'),
      padding: const EdgeInsets.only(
        bottom: UtenFloatingActionGroup.scrollClearance,
      ),
      children: [
        Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${detail.requestNo} · ${detail.warehouseName} · ${_statusText(detail.status)}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text(
                '提交人：${detail.submittedByName ?? '—'}；说明：${detail.reason ?? '—'}',
              ),
              if (detail.reviewReason?.isNotEmpty == true)
                Text('审核说明：${detail.reviewReason}'),
              if (stale && detail.status == 'PENDING')
                const UtenInlineNotice(
                  level: UtenInlineNoticeLevel.warning,
                  message: '提交后库存已变化，请退回重新盘点；本次不能直接覆盖当前库存。',
                ),
              if (reviewingSetup && !_canConfigureMaterials)
                const UtenInlineNotice(
                  level: UtenInlineNoticeLevel.warning,
                  message: '首次材料用途确认需货品及 BOM 编辑权限。',
                ),
            ],
          ),
        ),
        SizedBox(
          height: (150.0 + detail.lines.length * 48).clamp(245.0, 560.0),
          child: MasterDataTableView<StockCountRequestLine>(
            tableKey: 'stock.count-request-lines',
            columns: [
              MasterColumnDef(
                key: 'goods',
                label: '货品',
                width: 170,
                value: (r) => r.goodsName,
              ),
              MasterColumnDef(
                key: 'code',
                label: '编号',
                width: 100,
                value: (r) => r.goodsCode,
              ),
              MasterColumnDef(
                key: 'color',
                label: '颜色',
                width: 85,
                value: (r) => r.colorName,
              ),
              MasterColumnDef(
                key: 'unit',
                label: '单位',
                width: 70,
                value: (r) => r.unitName,
              ),
              MasterColumnDef(
                key: 'beforeQty',
                label: '原数量',
                width: 110,
                value: (r) => r.beforeQty,
                cellBuilder: (_, r) =>
                    StockCountOldValue(before: r.beforeQty, after: r.targetQty),
              ),
              MasterColumnDef(
                key: 'targetQty',
                label: '盘点数量',
                width: 115,
                value: (r) => r.targetQty,
              ),
              MasterColumnDef(
                key: 'deltaQty',
                label: '数量差额',
                width: 110,
                value: (r) => r.deltaQty,
              ),
              MasterColumnDef(
                key: 'beforeWeight',
                label: '原重量 (kg)',
                width: 115,
                value: (r) => r.beforeWeightKg,
                cellBuilder: (_, r) => StockCountOldValue(
                  before: r.beforeWeightKg,
                  after: r.weightChanged ? r.targetWeightKg : r.beforeWeightKg,
                ),
              ),
              MasterColumnDef(
                key: 'targetWeight',
                label: '盘点重量 (kg)',
                width: 125,
                value: (r) =>
                    r.weightChanged ? r.targetWeightKg ?? '未知' : '未修改',
              ),
              MasterColumnDef(
                key: 'deltaWeight',
                label: '重量差额 (kg)',
                width: 125,
                value: (r) => r.weightChanged ? r.deltaWeightKg ?? '未知' : '—',
              ),
              MasterColumnDef(
                key: 'currentQty',
                label: '当前数量',
                width: 110,
                value: (r) => r.currentQty,
              ),
              MasterColumnDef(
                key: 'stale',
                label: '快照核对',
                width: 135,
                value: (r) => r.stale ? '库存已变化' : '一致',
              ),
              MasterColumnDef(
                key: 'basis',
                label: '首次材料用途',
                width: 135,
                value: (r) => switch (r.materialSetupBasis) {
                  'OWN' => '主料',
                  'SHARED' => '辅料',
                  'EXPENSE' => '车间费用',
                  _ => '—',
                },
              ),
              if (reviewingSetup)
                MasterColumnDef(
                  key: 'materialImpact',
                  label: '用途及 BOM 影响',
                  width: 235,
                  value: _setupImpactLabel,
                  cellBuilderHandlesSemantics: true,
                  cellBuilder: (_, line) => _setupImpactCell(detail, line),
                ),
            ],
            items: detail.lines,
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            emptyMessage: '没有盘点明细',
          ),
        ),
      ],
    );
  }

  String _setupImpactLabel(StockCountRequestLine line) {
    if (line.materialSetupBasis == null) return '—';
    if (!_canConfigureMaterials) return '需货品及 BOM 编辑权限';
    if (_setupLoading.contains(line.goodsId)) return '正在核对用途影响…';
    if (_setupErrors.containsKey(line.goodsId)) return '读取失败，点击重试';
    final preview = _setupPreviews[line.goodsId];
    if (preview == null) return '等待核对用途影响';
    final blockers = workshopMaterialFirstUseBlockers(
      preview: preview,
      goodsId: line.goodsId,
      basis: line.materialSetupBasis!,
      expectedVersion: line.goodsVersion,
    );
    if (blockers.isNotEmpty) return blockers.first;
    final changed = preview.bomRows
        .where((row) => row.action != GoodsIssueMethodBomRow.actionKeep)
        .length;
    return '关联 BOM ${preview.bomRows.length} 行，调整 $changed 行';
  }

  Widget _setupImpactCell(
    StockCountRequest detail,
    StockCountRequestLine line,
  ) {
    if (line.materialSetupBasis == null) return const Text('—');
    final label = _setupImpactLabel(line);
    final preview = _setupPreviews[line.goodsId];
    final canOpen =
        !_working &&
        !_setupLoading.contains(line.goodsId) &&
        _canConfigureMaterials &&
        (preview != null || _setupErrors.containsKey(line.goodsId));
    // 2026-10-06 行高统一口径：影响格改单行文字动作（原来是 maxLines 2 的
    // TextButton，会把明细行撑高）；完整说明仍挂 Tooltip。
    return UtenTableCellAction(
      key: ValueKey('stock-count-impact-${line.goodsId}'),
      label: label,
      tooltip: _setupErrors[line.goodsId] ?? label,
      onPressed: !canOpen
          ? null
          : () {
              if (preview == null) {
                _loadSetupPreview(line, detail, _sequence);
              } else {
                _showSetupImpact(line, preview);
              }
            },
    );
  }

  Future<void> _showSetupImpact(
    StockCountRequestLine line,
    GoodsIssueMethodPreview preview,
  ) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('${line.goodsName} · 用途及 BOM 影响'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: WorkshopMaterialFirstUseImpact(
            preview: preview,
            goodsId: line.goodsId,
            basis: line.materialSetupBasis!,
            expectedVersion: line.goodsVersion,
            approvalContext: true,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );

  Widget _floatingActions(StockCountRequest detail) {
    final stale = detail.lines.any((line) => line.stale);
    // 2026-10-02 用户口径：审核视图（仓库/财务队列）只有「退回 + 审批通过」，审批通过
    // 摆最右；「撤回申请」是提交人动作，只出现在我的盘点（/stock/count-requests）视图。
    final reviewerView = widget.reviewRoute != null;
    return UtenFloatingActionGroup(
      children: [
        if (!reviewerView && detail.canCancel)
          UtenButton(
            key: const Key('stock-count-cancel'),
            type: UtenButtonType.secondary,
            onPressed: _working || _loading ? null : () => _decide('cancel'),
            child: const Text('撤回申请'),
          ),
        if (detail.canReject)
          UtenButton(
            key: const Key('stock-count-reject'),
            type: UtenButtonType.secondary,
            onPressed: _working || _loading ? null : () => _decide('reject'),
            child: const Text('退回'),
          ),
        if (detail.canApprove)
          UtenButton(
            key: const Key('stock-count-approve'),
            isLoading: _working,
            onPressed: _working || _loading || stale || !_setupReady(detail)
                ? null
                : () => _decide('approve'),
            child: const Text('审核通过'),
          ),
      ],
    );
  }

  bool get _canConfigureMaterials =>
      ref.read(isSuperAdminProvider) ||
      ref.read(currentPermissionsProvider).containsAll({
        Perm.goodsEdit,
        Perm.goodsBomEdit,
      });

  bool _setupReady(StockCountRequest detail) => detail.lines
      .where((line) => line.materialSetupBasis != null)
      .every(
        (line) => canConfirmWorkshopMaterialFirstUse(
          preview: _setupPreviews[line.goodsId],
          goodsId: line.goodsId,
          basis: line.materialSetupBasis!,
          expectedVersion: line.goodsVersion,
          canConfigure: _canConfigureMaterials,
          loading: _setupLoading.contains(line.goodsId),
        ),
      );
}

/// Exact text comparison: 1 and 1.0000 are equal without a double round trip.
class StockCountOldValue extends StatelessWidget {
  const StockCountOldValue({
    super.key,
    required this.before,
    required this.after,
  });
  final String? before;
  final String? after;
  @override
  Widget build(BuildContext context) {
    final changed = before == null || after == null
        ? before != after
        : financeAmountUnits(before) != financeAmountUnits(after);
    return Text(
      before ?? '未知',
      style: changed
          ? TextStyle(
              color: Theme.of(context).colorScheme.error,
              decoration: TextDecoration.lineThrough,
              decorationColor: Theme.of(context).colorScheme.error,
            )
          : null,
    );
  }
}

Future<String?> _confirmDecision(
  BuildContext context,
  String action, {
  int setupCount = 0,
}) async {
  final input = TextEditingController();
  try {
    return await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(
            action == 'approve'
                ? '审核通过并更新库存'
                : action == 'reject'
                ? '退回盘点'
                : '撤回盘点',
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                action == 'approve'
                    ? '将按提交的目标数量和重量更新库存，并保留审核及差额记录。'
                    : '库存保持不变。',
              ),
              if (action == 'approve' && setupCount > 0)
                Text('同时按申请用途确认 $setupCount 种材料，关联 BOM 调整对所有使用该材料的产品生效。'),
              const SizedBox(height: UtenSpacing.s12),
              TextField(
                key: const Key('stock-count-review-reason'),
                controller: input,
                maxLength: 500,
                decoration: InputDecoration(
                  labelText: action == 'reject' ? '退回原因（必填）' : '说明（选填）',
                ),
                onChanged: (_) => setState(() {}),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              key: const Key('stock-count-review-confirm'),
              onPressed: action == 'reject' && input.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(context, input.text.trim()),
              child: const Text('确认'),
            ),
          ],
        ),
      ),
    );
  } finally {
    input.dispose();
  }
}

String _message(Object error) =>
    error is ApiException ? error.message : '盘点数据读取或提交失败，请重试';
String _statusText(String status) => switch (status) {
  'PENDING' => '待审核',
  'APPROVED' => '已通过',
  'REJECTED' => '已退回',
  'CANCELLED' => '已撤回',
  _ => status,
};
