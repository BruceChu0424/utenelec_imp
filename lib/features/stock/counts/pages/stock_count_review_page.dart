import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../../components/buttons/uten_back_button.dart';
import '../../../../components/buttons/uten_button.dart';
import '../../../../components/feedback/uten_inline_notice.dart';
import '../../../../components/inputs/uten_dropdown_field.dart';
import '../../../../components/layout/uten_app_bar.dart';
import '../../../../components/layout/uten_content_container.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/router/nav_helpers.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../../core/ui/app_notification.dart';
import '../../../../shared/auth/permissions.dart';
import '../../../../shared/badges/badge_registry.dart';
import '../../../../shared/formatters/exact_decimal.dart';
import '../../../../shared/models/paged_result.dart';
import '../../../basic_data/widgets/master_data_table_view.dart';
import '../../../warehouse/materialbin/widgets/workshop_material_first_use_card.dart';
import '../models/stock_count_request.dart';
import '../repositories/stock_count_request_repository.dart';

/// A submitted stock count changes stock only after its designated reviewer approves.
class StockCountReviewPage extends ConsumerStatefulWidget {
  const StockCountReviewPage({super.key, this.reviewRoute, this.requestId});
  final String? reviewRoute;
  final String? requestId;

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
  int _sequence = 0;
  final _keys = <String, String>{};
  final _confirmedSetup = <String>{};

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
            _confirmedSetup.clear();
          }
        });
      }
    } catch (error) {
      if (mounted && sequence == _sequence) {
        setState(() => _error = _message(error));
      }
    } finally {
      if (mounted && sequence == _sequence) setState(() => _loading = false);
    }
  }

  Future<void> _decide(String action) async {
    final detail = _detail;
    if (detail == null || _working || !_authorized) return;
    if (action == 'approve' && !_setupConfirmed(detail)) return;
    if (action == 'approve' && !detail.canApprove ||
        action == 'reject' && !detail.canReject ||
        action == 'cancel' && !detail.canCancel) {
      return;
    }
    final reason = await _confirmDecision(context, action);
    if (reason == null || !mounted || !_authorized) return;
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
      setState(() => _detail = result);
      refreshBadges(ref);
      context.appSuccess(
        action == 'approve'
            ? '审核通过，库存已按盘点更新'
            : action == 'reject'
            ? '已退回，库存未改变'
            : '已撤回，库存未改变',
      );
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    ref.watch(isSuperAdminProvider);
    final allowed = _authorized;
    return Scaffold(
      appBar: UtenAppBar(
        title: _title,
        leading: UtenBackButton(
          onPressed: () {
            if (_detail != null) {
              setState(() => _detail = null);
              _load();
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
      body: UtenContentContainer(
        child: !allowed
            ? const Center(child: Text('未获本页盘点授权'))
            : Column(
                children: [
                  if (_error != null)
                    UtenInlineNotice(
                      message: _error!,
                      level: UtenInlineNoticeLevel.error,
                    ),
                  if (_working || _loading) const LinearProgressIndicator(),
                  Expanded(
                    child: _detail == null ? _list() : _detailBody(_detail!),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _list() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: UtenDropdownField(
          label: '状态',
          value: _status,
          enabled: !_working,
          allowClear: false,
          items: const [
            UtenDropdownItem(value: 'PENDING', label: '待审核'),
            UtenDropdownItem(value: 'APPROVED', label: '已通过'),
            UtenDropdownItem(value: 'REJECTED', label: '已退回'),
            UtenDropdownItem(value: 'CANCELLED', label: '已撤回'),
            UtenDropdownItem(value: '', label: '全部'),
          ],
          onChanged: (value) {
            if (value != null) {
              setState(() {
                _status = value;
                _page = null;
              });
              _load();
            }
          },
        ),
      ),
      Expanded(
        child: MasterDataTableView<StockCountRequest>(
          tableKey: 'stock.count-requests',
          columns: [
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
              key: 'status',
              label: '状态',
              width: 95,
              value: (r) => _statusText(r.status),
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
              value: (r) => r.submittedAt,
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
              cellBuilder: (_, r) => TextButton(
                onPressed: () => _open(r.id),
                child: const Text('查看明细'),
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
          paginationScope: (widget.reviewRoute, _status),
          onRetry: _load,
        ),
      ),
    ],
  );

  Widget _detailBody(StockCountRequest detail) {
    final stale = detail.lines.any((line) => line.stale);
    final setup = {
      for (final line in detail.lines)
        if (line.materialSetupBasis != null) line.goodsId: line,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
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
              const Text('仅变更的旧数值显示红色删除线；审核通过后才更新库存。'),
            ],
          ),
        ),
        Expanded(
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
            ],
            items: detail.lines,
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            emptyMessage: '没有盘点明细',
          ),
        ),
        if (detail.status == 'PENDING' && detail.canApprove && setup.isNotEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 300),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: UtenSpacing.s12,
                ),
                child: Column(
                  children: [
                    for (final line in setup.values)
                      WorkshopMaterialFirstUseCard(
                        key: ValueKey(
                          'count-setup-${detail.id}-${detail.version}-${line.goodsId}',
                        ),
                        goodsId: line.goodsId,
                        goodsName: line.goodsName,
                        canConfigure: _canConfigureMaterials,
                        enabled: !_working,
                        fixedBasis: line.materialSetupBasis,
                        expectedVersion: line.goodsVersion,
                        approvalContext: true,
                        onChanged: (value) {
                          if (!mounted) return;
                          setState(() {
                            if (value == null) {
                              _confirmedSetup.remove(line.goodsId);
                            } else {
                              _confirmedSetup.add(line.goodsId);
                            }
                          });
                        },
                      ),
                  ],
                ),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Wrap(
            spacing: UtenSpacing.s12,
            runSpacing: UtenSpacing.s8,
            children: [
              if (detail.canApprove)
                UtenButton(
                  key: const Key('stock-count-approve'),
                  onPressed:
                      _working || _loading || stale || !_setupConfirmed(detail)
                      ? null
                      : () => _decide('approve'),
                  child: const Text('审核通过并更新库存'),
                ),
              if (detail.canReject)
                UtenButton(
                  key: const Key('stock-count-reject'),
                  type: UtenButtonType.secondary,
                  onPressed: _working || _loading
                      ? null
                      : () => _decide('reject'),
                  child: const Text('退回'),
                ),
              if (detail.canCancel)
                UtenButton(
                  key: const Key('stock-count-cancel'),
                  type: UtenButtonType.secondary,
                  onPressed: _working || _loading
                      ? null
                      : () => _decide('cancel'),
                  child: const Text('撤回申请'),
                ),
            ],
          ),
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

  bool _setupConfirmed(StockCountRequest detail) {
    final setup = detail.lines
        .where((line) => line.materialSetupBasis != null)
        .map((line) => line.goodsId)
        .toSet();
    return setup.isEmpty ||
        (_canConfigureMaterials && _confirmedSetup.containsAll(setup));
  }
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

Future<String?> _confirmDecision(BuildContext context, String action) async {
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
