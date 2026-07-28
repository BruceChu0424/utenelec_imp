// 销售单据详情页（全页路由）：主表头卡 + 只读明细子表 + 状态门控操作（审核/红冲/编辑/删除）。
//
// 状态机：草稿(0)→可编辑/删除/审核；已审(1)→仅红冲；红冲(-1)→只读。操作按 edit 权限。
// 名称解析：客户/仓库/币种/颜色/单位用 SalesMasterNameService；货品按明细 id 批量 lookup。
//
// 审核副作用（前端只调 approve 端点，UI 显示状态）：
//  - 出货审核→后端自动库存出库+回写订货已发+立应收+结案
//  - 退货审核→后端自动库存入库+双挂回写+立红字应收+结案
//  - 其它出货审核→仅库存出库
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../config/sales_doc_config.dart';
import '../models/sales_doc.dart';
import '../providers/master_name_provider.dart';
import '../repositories/sales_repository.dart';
import '../widgets/sales_status_badge.dart';

class SalesDocDetailPage extends ConsumerStatefulWidget {
  const SalesDocDetailPage(
      {super.key, required this.docType, required this.id});
  final SalesDocType docType;
  final String id;

  @override
  ConsumerState<SalesDocDetailPage> createState() =>
      _SalesDocDetailPageState();
}

class _SalesDocDetailPageState extends ConsumerState<SalesDocDetailPage> {
  SalesDocConfig get _cfg => SalesDocConfig.by(widget.docType);
  SalesDocDetail? _detail;
  bool _loading = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  bool get _canEdit =>
      ref.read(currentPermissionsProvider).contains(_cfg.editPerm);

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(salesMasterNameServiceProvider).ensureLoaded();
      final d = await ref
          .read(salesRepositoryProvider(widget.docType))
          .detail(widget.id);
      final goodsIds =
          d.items.map((e) => e.goodsId).whereType<String>().toSet();
      await ref.read(salesMasterNameServiceProvider).loadGoodsNames(goodsIds);
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

  Future<void> _approve() async => _doAction('审核后将驱动下游（库存/应收），确认审核？',
      (repo) => repo.approve(widget.id), '已审核');
  Future<void> _reverse() async => _doAction(
      '红冲将反向冲销，确认？', (repo) => repo.reverse(widget.id), '已红冲');

  Future<void> _doAction(
      String confirm,
      Future<SalesDocDetail> Function(SalesRepository) fn,
      String ok) async {
    if (_busy) return;
    final c = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认'),
        content: Text(confirm),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认')),
        ],
      ),
    );
    if (c != true) return;
    setState(() => _busy = true);
    try {
      await fn(ref.read(salesRepositoryProvider(widget.docType)));
      if (!mounted) return;
      context.appSuccess(ok);
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
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
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
          .read(salesRepositoryProvider(widget.docType))
          .delete(widget.id);
      if (!mounted) return;
      context.appSuccess('已删除');
      context.go(SalesRoutePath.list(_cfg.type.pathSegment));
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
    final names = ref.watch(salesMasterNameServiceProvider);
    return Scaffold(
      appBar: UtenAppBar(title: '${_cfg.label}详情', showBackButton: true),
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
                            _headerCard(theme, names),
                            const SizedBox(height: UtenSpacing.s12),
                            _itemsCard(theme, names),
                          ],
                        ),
        ),
      ),
      bottomNavigationBar:
          _detail == null || _busy ? null : _actions(theme),
    );
  }

  Widget _headerCard(ThemeData theme, SalesMasterNameService names) {
    final d = _detail!;
    final rows = <_KV>[
      _KV('单据号', d.billNo),
      _KV('日期', d.billDate),
      _KV('客户', names.client(d.clientId)),
      if (_cfg.hasWarehouse) _KV('仓库', names.warehouse(d.warehouseId)),
      if (_cfg.hasCurrency) _KV('币种', names.currency(d.currencyId)),
      if (d.exchangeRate != null)
        _KV('汇率', d.exchangeRate?.toString()),
      // 业务员/发货人：master_name_provider 暂未含员工 dict，先显示占位；后续可扩。
      if (_cfg.hasSeller) _KV('业务员', _empDisplay(d.sellerId)),
      if (_cfg.hasSender) _KV('发货人', _empDisplay(d.senderId)),
      if (_cfg.hasValidUntil) _KV('有效期', d.validUntil),
      if (_cfg.hasDeliverDate) _KV('交货日', d.deliverDate),
      if (_cfg.hasContractInfo && d.contractNo != null)
        _KV('合同号', d.contractNo),
      if (_cfg.hasContractInfo && (d.linkPhone?.isNotEmpty ?? false))
        _KV('联系电话', d.linkPhone),
      if (_cfg.hasContractInfo && (d.signAddr?.isNotEmpty ?? false))
        _KV('签约地点', d.signAddr),
      if ((d.shipAddr?.isNotEmpty ?? false)) _KV('收货地址', d.shipAddr),
      if (_cfg.hasContractInfo && d.deposit != null)
        _KV('订金', d.deposit?.toString()),
      if (_cfg.hasShipInfo && d.parcelCount != null)
        _KV('件数', d.parcelCount?.toString()),
      if (_cfg.hasOutType && (d.outType?.isNotEmpty ?? false))
        _KV('出库类型', d.outType),
      _KV('合计(本币)', d.totalLocal?.toStringAsFixed(2)),
      if (d.remark?.isNotEmpty == true) _KV('备注', d.remark),
      _KV('状态', null,
          badge: SalesStatusBadge(
            status: d.status,
            closed: d.closed,
            stopped: d.stopped,
            arPosted: d.arPosted,
          )),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: UtenFormGrid(
          children: [for (final r in rows) _kvRow(theme, r)],
        ),
      ),
    );
  }

  /// 人员 id 当前未在 Service 解析（无员工 dict），先显示 UUID 短缀或 '—'。
  /// 后续可在 Service 增 employeeName 缓存；当前 v1 不阻塞详情展示。
  String _empDisplay(String? id) =>
      (id == null || id.isEmpty) ? '—' : '员工 ${id.substring(0, 8)}';

  Widget _kvRow(ThemeData theme, _KV r) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 84,
          child: Text(r.label,
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
        const SizedBox(width: UtenSpacing.s8),
        Expanded(child: r.badge ?? Text(r.value ?? '—')),
      ],
    );
  }

  Widget _itemsCard(ThemeData theme, SalesMasterNameService names) {
    final items = _detail!.items;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(UtenSpacing.s4),
              child: Text('明细 (${items.length})',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ),
            const Divider(height: 1),
            _itemHeader(theme),
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.all(UtenSpacing.s12),
                child: Text('（无明细）',
                    style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant)),
              )
            else
              for (final it in items) _itemRow(theme, names, it),
          ],
        ),
      ),
    );
  }

  Widget _itemHeader(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Row(
        children: [
          _icell('货品', 3, theme, bold: true),
          _icell('数量', 1, theme, bold: true),
          _icell('单价', 1, theme, bold: true),
          _icell('金额', 1, theme, bold: true),
          if (_cfg.showShipped) _icell('已发', 1, theme, bold: true),
          if (_cfg.showReturned) _icell('已退', 1, theme, bold: true),
        ],
      ),
    );
  }

  Widget _itemRow(
      ThemeData theme, SalesMasterNameService names, SalesDocItem it) {
    final amt = (it.qty ?? 0) * (it.price ?? 0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(names.goods(it.goodsId),
                    style: const TextStyle(fontSize: 13)),
                Text(
                  [
                    names.color(it.colorId),
                    names.unit(it.unitId),
                  ].join(' · '),
                  style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          _icell(it.qty?.toStringAsFixed(2), 1, theme),
          _icell(it.price?.toStringAsFixed(2), 1, theme),
          _icell(amt.toStringAsFixed(2), 1, theme),
          if (_cfg.showShipped)
            _icell(it.shippedQty?.toStringAsFixed(2), 1, theme),
          if (_cfg.showReturned)
            _icell(it.returnedQty?.toStringAsFixed(2), 1, theme),
        ],
      ),
    );
  }

  Widget _icell(String? text, int flex, ThemeData theme, {bool bold = false}) {
    return Expanded(
      flex: flex,
      child: Text(
        text ?? '—',
        textAlign: TextAlign.right,
        style: TextStyle(
            fontSize: 12,
            fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
            color: bold ? theme.colorScheme.onSurfaceVariant : null),
      ),
    );
  }

  Widget _actions(ThemeData theme) {
    final s = _detail!.status;
    final children = <Widget>[];
    if (s == kSalesStatusDraft && _canEdit) {
      children
        ..add(UtenButton(
          type: UtenButtonType.danger,
          icon: Icons.delete_outline,
          onPressed: _delete,
          child: const Text('删除'),
        ))
        ..add(const SizedBox(width: UtenSpacing.s8))
        ..add(UtenButton(
          type: UtenButtonType.secondary,
          icon: Icons.edit_outlined,
          onPressed: () => context.push(
              SalesRoutePath.docEdit(_cfg.type.pathSegment, widget.id)),
          child: const Text('编辑'),
        ))
        ..add(const SizedBox(width: UtenSpacing.s8))
        ..add(UtenButton(
          icon: Icons.check_circle_outline,
          onPressed: _approve,
          child: const Text('审核'),
        ));
    } else if (s == kSalesStatusApproved && _canEdit) {
      children.add(UtenButton(
        type: UtenButtonType.danger,
        icon: Icons.undo_outlined,
        onPressed: _reverse,
        child: const Text('红冲'),
      ));
    } else {
      children.add(UtenButton(
        type: UtenButtonType.secondary,
        onPressed: () => context.go(SalesRoutePath.list(_cfg.type.pathSegment)),
        child: const Text('返回列表'),
      ));
    }
    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border:
              Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
        ),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child:
            Row(mainAxisAlignment: MainAxisAlignment.center, children: children),
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
