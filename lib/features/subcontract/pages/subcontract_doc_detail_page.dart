// 委外单据详情页（全页路由）：主表头卡 + 只读明细子表 + 状态门控操作（审核/红冲/编辑/删除）。
//
// 状态机：草稿(0)→可编辑/删除/审核；已审(1)→仅红冲；红冲(-1)→只读。操作按 edit 权限。
// 名称解析：委外商(supplier)/仓库/币种/颜色/单位复用采购 MasterNameService；货品按明细 id 批量 lookup。
// 审核仅调 approve，库存/应付/累计联动由后端承担；新增发料缺冻结 BOM/子件台账时前后端共同禁审。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../config/subcontract_doc_config.dart';
import '../models/subcontract_doc.dart';
import '../repositories/subcontract_repository.dart';
import '../widgets/subcontract_status_badge.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../shared/providers/master_name_provider.dart' as mn;

class SubcontractDocDetailPage extends ConsumerStatefulWidget {
  const SubcontractDocDetailPage({
    super.key,
    required this.docType,
    required this.id,
  });
  final SubcontractDocType docType;
  final String id;

  @override
  ConsumerState<SubcontractDocDetailPage> createState() =>
      _SubcontractDocDetailPageState();
}

class _SubcontractDocDetailPageState
    extends ConsumerState<SubcontractDocDetailPage> {
  SubcontractDocConfig get _cfg => SubcontractDocConfig.by(widget.docType);
  SubcontractDocDetail? _detail;
  bool _loading = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  bool get _hasEditPermission =>
      ref.read(currentPermissionsProvider).contains(_cfg.editPerm);

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(mn.masterNameServiceProvider).ensureLoaded();
      final d = await ref
          .read(subcontractRepositoryProvider(widget.docType))
          .detail(widget.id);
      final goodsIds = d.items
          .map((e) => e.goodsId)
          .whereType<String>()
          .toSet();
      await ref.read(mn.masterNameServiceProvider).loadGoodsNames(goodsIds);
      if (!mounted) return;
      setState(() {
        _detail = d;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '加载详情失败';
        _loading = false;
      });
    }
  }

  Future<void> _approve() async {
    final blockedReason = _cfg.approvalBlockedReason;
    if (blockedReason != null) {
      context.appWarning(
        '$blockedReason\n$kSubcontractMaterialIssueHistoricalCompatibilityNote',
        title: '审核暂不可用',
        force: true,
      );
      return;
    }
    await _doAction(
      '${_cfg.approveEffect}\n\n确认审核？',
      (repo) => repo.approve(widget.id),
      '已审核',
    );
  }

  Future<void> _reverse() async =>
      _doAction('红冲将反向冲销，确认？', (repo) => repo.reverse(widget.id), '已红冲');

  Future<void> _doAction(
    String confirm,
    Future<void> Function(SubcontractRepository) fn,
    String ok,
  ) async {
    if (_busy) return;
    final c = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认'),
        content: Text(confirm),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    if (c != true) return;
    setState(() => _busy = true);
    try {
      await fn(ref.read(subcontractRepositoryProvider(widget.docType)));
      if (!mounted) return;
      context.appSuccess(ok);
      bumpListRefresh(ref, _cfg.refreshKey);
      await _load();
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('操作失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    if (_busy) return;
    final c = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除单据'),
        content: const Text('确定删除该草稿单据吗？'),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (c != true) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(subcontractRepositoryProvider(widget.docType))
          .delete(widget.id);
      if (!mounted) return;
      context.appSuccess('已删除');
      context.go(SubcontractRoute.list(_cfg.pathSegment));
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('删除失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: UtenAppBar(
        title: '${_cfg.label}详情',
        leading: UtenBackButton(
          onPressed: () => popOrBackTo(context, defaultPath: '/subcontract'),
        ),
        actions: [
          UtenButton(
            type: UtenButtonType.tonal,
            icon: Icons.history_rounded,
            onPressed: () =>
                context.push('/subcontract/${_cfg.type.pathSegment}'),
            child: const Text('查看历史'),
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.narrow(
          child: _loading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
              : _error != null
              ? Center(child: Text(_error!))
              : _detail == null
              ? const SizedBox.shrink()
              : ListView(
                  padding: const EdgeInsets.all(UtenSpacing.s12),
                  children: [
                    _headerCard(theme),
                    if (_cfg.approvalBlockedReason != null) ...[
                      const SizedBox(height: UtenSpacing.s12),
                      _materialIssueSafetyBanner(theme),
                    ],
                    if (_detail!.productionLinked) ...[
                      const SizedBox(height: UtenSpacing.s12),
                      _productionSourceBanner(theme),
                    ],
                    const SizedBox(height: UtenSpacing.s12),
                    _itemsCard(theme),
                  ],
                ),
        ),
      ),
      bottomNavigationBar: _detail == null || _busy ? null : _actions(theme),
    );
  }

  Widget _headerCard(ThemeData theme) {
    final d = _detail!;
    final names = ref.watch(mn.masterNameServiceProvider);
    final rows = <_KV>[
      _KV('单据号', d.billNo),
      _KV('日期', d.billDate),
      _KV('制单员', d.makerName),
      _KV('制单时间', utenFmtIsoTime(d.createdAt)),
      if (_cfg.hasSupplier) _KV('委外商', names.supplier(d.supplierId)),
      _KV('仓库', names.warehouse(d.warehouseId)),
      if (_cfg.hasCurrency) _KV('币种', names.currency(d.currencyId)),
      if (d.exchangeRate != null) _KV('汇率', d.exchangeRate?.toString()),
      if (_cfg.hasTaxRate && d.taxRate != null)
        _KV('税率', d.taxRate?.toString()),
      // 人员字段展示 id（员工名解析未接入；与采购详情页同款已知限制，待统一 EmployeeNameService）。
      if (_cfg.hasPurchaser) _KV('采购员', d.purchaserId ?? '—'),
      if (_cfg.hasSender) _KV('交货人', d.senderId ?? '—'),
      if (_cfg.hasWorker) _KV('经办人', d.workerId ?? '—'),
      if (_cfg.hasDeliverDate) _KV('交货日', d.deliverDate),
      if (_cfg.hasLastDate) _KV('最后交货日', d.lastDate),
      if (_cfg.hasBStyle) _KV('bStyle', d.bStyle?.toString()),
      if (_cfg.hasTotalWeight && d.totalWeight != null)
        _KV('总重', d.totalWeight?.toStringAsFixed(2)),
      if (_cfg.hasAmount) _KV('合计(本币)', d.totalLocal?.toStringAsFixed(2)),
      if (d.remark?.isNotEmpty == true) _KV('备注', d.remark),
      _KV(
        '状态',
        null,
        badge: SubcontractStatusBadge(
          status: d.status,
          closed: d.closed,
          apPosted: d.apPosted,
        ),
      ),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: UtenFormGrid(children: [for (final r in rows) _kvRow(theme, r)]),
      ),
    );
  }

  Widget _kvRow(ThemeData theme, _KV r) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 84,
          child: Text(
            r.label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(width: UtenSpacing.s8),
        Expanded(child: r.badge ?? Text(r.value ?? '—')),
      ],
    );
  }

  /// 明细区：统一表格样式（MasterDataTableView 嵌入模式，与全站报表/主档同款），
  /// 不再是卡片式拼凑行；口径保留（价格/重量/已收/已退/损耗按 config 显隐）。
  Widget _itemsCard(ThemeData theme) {
    final d = _detail!;
    final items = d.items;
    final names = ref.watch(mn.masterNameServiceProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '明细 (${items.length})',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        MasterDataTableView<SubcontractDocItem>(
          embedded: true,
          columns: [
            MasterColumnDef(
              key: 'goods',
              label: '货品',
              width: 240,
              value: (it) =>
                  '${names.goods(it.goodsId)}（${names.color(it.colorId)} · ${names.unit(it.unitId)}）',
            ),
            MasterColumnDef(
              key: 'qty',
              label: '数量',
              width: 90,
              type: 'number',
              value: (it) => it.qty?.toStringAsFixed(2),
            ),
            if (_cfg.itemHasPrice) ...[
              MasterColumnDef(
                key: 'price',
                label: '单价',
                width: 90,
                type: 'money',
                value: (it) => it.price?.toStringAsFixed(2),
              ),
              MasterColumnDef(
                key: 'amount',
                label: '金额',
                width: 100,
                type: 'money',
                value: (it) =>
                    ((it.qty ?? 0) * (it.price ?? 0)).toStringAsFixed(2),
              ),
            ],
            if (_cfg.itemHasWeight)
              MasterColumnDef(
                key: 'weight',
                label: '重量',
                width: 90,
                type: 'number',
                value: (it) => it.weight?.toStringAsFixed(2),
              ),
            if (_cfg.showReceived)
              MasterColumnDef(
                key: 'received',
                label: '已收',
                width: 90,
                type: 'number',
                value: (it) => it.receivedQty?.toStringAsFixed(2),
              ),
            if (_cfg.showReturned)
              MasterColumnDef(
                key: 'returned',
                label: '已退',
                width: 90,
                type: 'number',
                value: (it) => it.returnedQty?.toStringAsFixed(2),
              ),
            if (_cfg.showWasted)
              MasterColumnDef(
                key: 'wasted',
                label: '已损耗',
                width: 90,
                type: 'number',
                value: (it) => it.wastedQty?.toStringAsFixed(2),
              ),
            if (_cfg.itemHasWasteFields)
              MasterColumnDef(
                key: 'wasteCause',
                label: '损耗率/原因',
                width: 140,
                value: (it) => [
                  if (it.wasteRate != null) '${it.wasteRate}%',
                  if (it.cause?.isNotEmpty == true) it.cause,
                ].join(' · '),
              ),
          ],
          items: items,
          facets: const {},
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
          emptyMessage: '（无明细）',
        ),
      ],
    );
  }

  Widget _productionSourceBanner(ThemeData theme) {
    final reason = _detail!.restrictionReason ?? '该单据关联生产物料需求，通用修改和删除已锁定。';
    return Card(
      color: theme.colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.lock_outline_rounded,
              color: theme.colorScheme.onTertiaryContainer,
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Text(
                '$reason\n仍可查看和审核；后续调整请从生产计划专用流程发起。',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onTertiaryContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _materialIssueSafetyBanner(ThemeData theme) {
    final reason = _cfg.approvalBlockedReason!;
    return Semantics(
      container: true,
      label:
          '新增发料审核暂不可用。$reason $kSubcontractMaterialIssueHistoricalCompatibilityNote',
      child: Card(
        color: theme.colorScheme.tertiaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.lock_outline_rounded,
                color: theme.colorScheme.onTertiaryContainer,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '新增发料审核暂不可用',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onTertiaryContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      '$reason\n$kSubcontractMaterialIssueHistoricalCompatibilityNote',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onTertiaryContainer,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actions(ThemeData theme) {
    final d = _detail!;
    final s = d.status;
    final children = <Widget>[];
    if (s == kSubcontractStatusDraft && _hasEditPermission) {
      if (d.canDelete) {
        children.add(
          UtenButton(
            type: UtenButtonType.danger,
            icon: Icons.delete_outline,
            onPressed: _delete,
            child: const Text('删除'),
          ),
        );
      }
      if (d.canEdit) {
        if (children.isNotEmpty) {
          children.add(const SizedBox(width: UtenSpacing.s8));
        }
        children.add(
          UtenButton(
            type: UtenButtonType.secondary,
            icon: Icons.edit_outlined,
            onPressed: () => context.push(
              SubcontractRoute.edit(_cfg.pathSegment, widget.id),
            ),
            child: const Text('编辑'),
          ),
        );
      }
      if (children.isNotEmpty) {
        children.add(const SizedBox(width: UtenSpacing.s8));
      }
      children.add(
        UtenButton(
          icon: _cfg.approvalEnabled
              ? Icons.check_circle_outline
              : Icons.lock_outline_rounded,
          onPressed: _cfg.approvalEnabled ? _approve : null,
          onDisabledTap: _cfg.approvalEnabled
              ? null
              : () => context.appWarning(
                  '${_cfg.approvalBlockedReason}\n'
                  '$kSubcontractMaterialIssueHistoricalCompatibilityNote',
                  title: '审核暂不可用',
                  force: true,
                ),
          child: Text(_cfg.approvalEnabled ? '审核' : '审核暂不可用'),
        ),
      );
    } else if (s == kSubcontractStatusApproved &&
        _hasEditPermission &&
        d.canReverse) {
      children.add(
        UtenButton(
          type: UtenButtonType.danger,
          icon: Icons.undo_outlined,
          onPressed: _reverse,
          child: const Text('红冲'),
        ),
      );
    } else {
      children.add(
        UtenButton(
          type: UtenButtonType.secondary,
          onPressed: () => context.go(SubcontractRoute.list(_cfg.pathSegment)),
          child: const Text('返回列表'),
        ),
      );
    }
    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: children,
        ),
      ),
    );
  }
}

class _KV {
  const _KV(this.label, this.value, {this.badge});
  final String label;
  final String? value;
  final Widget? badge;
}
