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
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../production/repositories/production_repository.dart';
import '../config/sales_doc_config.dart';
import '../models/sales_doc.dart';
import '../providers/master_name_provider.dart';
import '../repositories/sales_repository.dart';
import '../widgets/sales_plan_progress_sheet.dart';
import '../widgets/sales_status_badge.dart';

class SalesDocDetailPage extends ConsumerStatefulWidget {
  const SalesDocDetailPage({
    super.key,
    required this.docType,
    required this.id,
  });
  final SalesDocType docType;
  final String id;

  @override
  ConsumerState<SalesDocDetailPage> createState() => _SalesDocDetailPageState();
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

  /// 仓库驳回权限（V96，仅出货单）：PMC/销售可在草稿（待备货）态驳回。
  bool get _canReject =>
      widget.docType == SalesDocType.shipment &&
      ref.read(currentPermissionsProvider).contains(Perm.salesShipmentReject);

  /// 报价转订货权限（SOP §三1，仅报价单）：写订货单需 sales_order:edit。
  bool get _canConvert =>
      widget.docType == SalesDocType.quote &&
      ref.read(currentPermissionsProvider).contains(Perm.salesOrderEdit);

  /// 报价转订货：已审报价一键生成订货草稿（行带入+价格留痕），转后跳订货编辑页。
  Future<void> _convertToOrder() async {
    if (_busy) return;
    final c = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('转订货单'),
        content: const Text('将按报价行生成订货草稿（货品/数量/价格带入，可再修改），确认转入？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('转入'),
          ),
        ],
      ),
    );
    if (c != true) return;
    setState(() => _busy = true);
    try {
      final order = await ref
          .read(salesRepositoryProvider(SalesDocType.quote))
          .convertToOrder(widget.id);
      if (!mounted) return;
      context.appSuccess('已生成订货草稿 ${order.billNo ?? ''}');
      context.push(
        SalesRoutePath.docEdit(SalesDocType.order.pathSegment, order.id),
      );
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('转入失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

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
      final goodsIds = d.items
          .map((e) => e.goodsId)
          .whereType<String>()
          .toSet();
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

  Future<void> _approve() async => _doAction(
    '审核后将驱动下游（库存/应收），确认审核？',
    (repo) => repo.approve(widget.id),
    '已审核',
  );
  Future<void> _reverse() async =>
      _doAction('红冲将反向冲销，确认？', (repo) => repo.reverse(widget.id), '已红冲');

  /// 订单取消（V100）：整单取消=释放预留+断排产联动；已发货订单后端会拒绝并提示改量。
  Future<void> _cancel() async => _doAction(
    '取消将释放全部预留并断开排产联动，确认取消订单？',
    (repo) => repo.cancel(widget.id),
    '已取消',
  );

  /// 订单改量（V100）：弹窗逐行改数量（增量重走预留/减量释放，已排产行需生产部权限）。
  Future<void> _changeQty() async {
    if (_busy || _detail == null) return;
    final ctrls = <String, TextEditingController>{};
    for (final it in _detail!.items) {
      if (it.id != null) {
        ctrls[it.id!] = TextEditingController(
          text: it.qty?.toStringAsFixed(2) ?? '',
        );
      }
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('订单改量'),
        content: SizedBox(
          width: 420,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final it in _detail!.items)
                if (it.id != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${it.clientModel ?? ''} 现 ${it.qty?.toStringAsFixed(2) ?? '—'}'
                            ' 已发 ${it.shippedQty?.toStringAsFixed(2) ?? '0'}',
                            style: const TextStyle(fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        SizedBox(
                          width: 100,
                          child: TextField(
                            controller: ctrls[it.id!],
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              isDense: true,
                              labelText: '新数量',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认改量'),
          ),
        ],
      ),
    );
    if (ok != true) {
      for (final c in ctrls.values) {
        c.dispose();
      }
      return;
    }
    final changes = <Map<String, dynamic>>[];
    for (final it in _detail!.items) {
      if (it.id == null) continue;
      final v = double.tryParse(ctrls[it.id!]!.text);
      ctrls[it.id!]!.dispose();
      if (v == null) {
        if (mounted) context.appError('存在无效数量，请检查');
        return;
      }
      if (v != it.qty) {
        changes.add({'orderItemId': it.id, 'newQty': v});
      }
    }
    if (changes.isEmpty) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(salesRepositoryProvider(widget.docType))
          .changeQty(widget.id, changes);
      if (!mounted) return;
      context.appSuccess('已改量');
      await _load();
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('改量失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// C6 财务审核发货（出货单）：响应带结算方式+未收余额，审核后刷新详情。
  Future<void> _financeAudit() async {
    if (_busy) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('财务审核发货'),
        content: const Text('现金结算客户请先核对到款；月结客户可直接审。确认审核发货？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('审核发货'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final info = await ref
          .read(salesRepositoryProvider(widget.docType))
          .financeAudit(widget.id);
      if (!mounted) return;
      final outstanding = info['outstanding'];
      context.appSuccess(
        '已财务审核发货'
        '${info['cashClient'] == true ? '（该客户未收余额 $outstanding）' : ''}',
      );
      await _load();
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('财务审核失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// C6 财务反审（仅未审核出货的单据）。
  Future<void> _financeAuditReverse() async {
    if (_busy) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('财务反审'),
        content: const Text('回退财务审核后，现金客户的出货单将无法仓库审核。确认反审？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('反审'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(salesRepositoryProvider(widget.docType))
          .financeAuditReverse(widget.id);
      if (!mounted) return;
      context.appSuccess('已财务反审');
      await _load();
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('财务反审失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 仓库驳回（V96）：填原因 → 释放预留 + 订单行回退待排产。
  Future<void> _reject() async {
    if (_busy) return;
    final reasonCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('驳回出货单'),
        content: TextField(
          controller: reasonCtrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '驳回原因（如：预留货物损坏 / 找不到）'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认驳回'),
          ),
        ],
      ),
    );
    final reason = reasonCtrl.text;
    reasonCtrl.dispose();
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(salesRepositoryProvider(widget.docType))
          .reject(widget.id, reason: reason);
      if (!mounted) return;
      context.appSuccess('已驳回，对应订单行已回退待处理');
      await _load();
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('驳回失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _doAction(
    String confirm,
    Future<SalesDocDetail> Function(SalesRepository) fn,
    String ok,
  ) async {
    if (_busy) return;
    final c = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认'),
        content: Text(confirm),
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
      await ref.read(salesRepositoryProvider(widget.docType)).delete(widget.id);
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
      appBar: UtenAppBar(
        title: '${_cfg.label}详情',
        showBackButton: true,
        actions: [
          UtenButton(
            type: UtenButtonType.tonal,
            icon: Icons.history_rounded,
            onPressed: () => context.push('/sales/${_cfg.type.pathSegment}'),
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
                    _headerCard(theme, names),
                    const SizedBox(height: UtenSpacing.s12),
                    _itemsCard(theme, names),
                  ],
                ),
        ),
      ),
      bottomNavigationBar: _detail == null || _busy ? null : _actions(theme),
    );
  }

  Widget _headerCard(ThemeData theme, SalesMasterNameService names) {
    final d = _detail!;
    final rows = <_KV>[
      _KV('单据号', d.billNo),
      _KV('日期', d.billDate),
      _KV('制单员', d.makerName),
      _KV('制单时间', utenFmtIsoTime(d.createdAt)),
      _KV('客户', names.client(d.clientId)),
      if (_cfg.hasWarehouse) _KV('仓库', names.warehouse(d.warehouseId)),
      if (_cfg.hasCurrency) _KV('币种', names.currency(d.currencyId)),
      if (d.exchangeRate != null) _KV('汇率', d.exchangeRate?.toString()),
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
      if (_cfg.hasContractInfo && (d.deposit != null || d.priceMasked))
        _KV('订金', d.priceMasked ? '***' : d.deposit?.toString()),
      if (_cfg.hasShipInfo && d.parcelCount != null)
        _KV('件数', d.parcelCount?.toString()),
      if (_cfg.hasOutType && (d.outType?.isNotEmpty ?? false))
        _KV('出库类型', d.outType),
      // 价格脱敏（SOP §三8）：无 sales_order:price:view 时价格族渲染 ***
      _KV('合计(本币)', d.priceMasked ? '***' : d.totalLocal?.toStringAsFixed(2)),
      if (d.remark?.isNotEmpty == true) _KV('备注', d.remark),
      _KV(
        '状态',
        null,
        badge: SalesStatusBadge(
          status: d.status,
          closed: d.closed,
          stopped: d.stopped,
          arPosted: d.arPosted,
        ),
      ),
      if (d.rejected) _KV('驳回原因', d.rejectReason ?? '仓库备货异常'),
      // C6 财务发货审核（出货单）：现金客户须「已审发货」仓库才可审核
      if (_cfg.type == SalesDocType.shipment && d.financeAudit != null)
        _KV(
          '财务审核',
          d.financeAudit == 1
              ? '已审发货${d.financeAuditedAt != null ? '（${d.financeAuditedAt!.substring(0, 10)}）' : ''}'
              : '未审',
        ),
      // 报价转入回链（SOP §三1）：来源报价可点跳报价详情，行级报价单价见明细
      if (_cfg.type == SalesDocType.order && d.sourceQuoteId != null)
        _KV(
          '来源报价',
          null,
          badge: GestureDetector(
            onTap: () => context.push(
              SalesRoutePath.docDetail(
                SalesDocType.quote.pathSegment,
                d.sourceQuoteId!,
              ),
            ),
            child: Text(
              d.sourceDocNo ?? '查看报价',
              style: TextStyle(
                color: theme.colorScheme.primary,
                decoration: TextDecoration.underline,
              ),
            ),
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

  /// 明细区：统一表格样式（MasterDataTableView 嵌入模式，与全站报表/主档同款）。
  /// 口径保留：价格脱敏（无权限订单单价/金额 = ***）；报价来源行「单价（报价 X）」对比；
  /// 订单行含可发/已排/已产；链路状态并入货品列文本。
  Widget _itemsCard(ThemeData theme, SalesMasterNameService names) {
    final items = _detail!.items;
    final isOrder = _cfg.type == SalesDocType.order;
    final masked = _detail!.priceMasked && isOrder;
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
        MasterDataTableView<SalesDocItem>(
          embedded: true,
          columns: [
            MasterColumnDef(
              key: 'goods',
              label: '货品',
              width: 240,
              value: (it) {
                final base =
                    '${names.goods(it.goodsId)}（${names.color(it.colorId)} · ${names.unit(it.unitId)}）';
                return (isOrder && it.chainStatus != null && it.chainStatus != 0)
                    ? '$base · ${chainStatusLabel(it.chainStatus)}'
                    : base;
              },
            ),
            MasterColumnDef(
              key: 'qty',
              label: '数量',
              width: 90,
              type: 'number',
              value: (it) => it.qty?.toStringAsFixed(2),
            ),
            MasterColumnDef(
              key: 'price',
              label: '单价',
              width: 120,
              type: 'money',
              value: (it) {
                if (masked) return '***';
                final p = it.price?.toStringAsFixed(2);
                return (isOrder && it.quotePrice != null)
                    ? '$p（报价 ${it.quotePrice!.toStringAsFixed(2)}）'
                    : p;
              },
            ),
            MasterColumnDef(
              key: 'amount',
              label: '金额',
              width: 100,
              type: 'money',
              value: (it) => masked
                  ? '***'
                  : ((it.qty ?? 0) * (it.price ?? 0)).toStringAsFixed(2),
            ),
            if (_cfg.showShipped)
              MasterColumnDef(
                key: 'shipped',
                label: '已发',
                width: 90,
                type: 'number',
                value: (it) => it.shippedQty?.toStringAsFixed(2),
              ),
            if (_cfg.showReturned)
              MasterColumnDef(
                key: 'returned',
                label: '已退',
                width: 90,
                type: 'number',
                value: (it) => it.returnedQty?.toStringAsFixed(2),
              ),
            if (isOrder) ...[
              MasterColumnDef(
                key: 'reserved',
                label: '可发',
                width: 90,
                type: 'number',
                value: (it) => it.reservedQty?.toStringAsFixed(2),
              ),
              MasterColumnDef(
                key: 'planned',
                label: '已排',
                width: 90,
                type: 'number',
                value: (it) => it.plannedQty?.toStringAsFixed(2),
              ),
              MasterColumnDef(
                key: 'produced',
                label: '已产',
                width: 90,
                type: 'number',
                value: (it) => it.producedQty?.toStringAsFixed(2),
              ),
            ],
          ],
          items: items,
          facets: const {},
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
          onRowTap: (_) {},
          emptyMessage: '（无明细）',
        ),
      ],
    );
  }

  /// D3（李主管）：订单物料分析底表——BOM 展开 毛需求/库存/在途/净需求（自制件标记）。
  Future<void> _showMrpAnalysis() async {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        expand: false,
        builder: (_, ctl) => FutureBuilder<List<MrpRow>>(
          future: ref
              .read(productionPlanRepositoryProvider)
              .mrpOrderPreview(widget.id),
          builder: (_, snap) {
            if (snap.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(UtenSpacing.s16),
                  child: Text('物料分析失败：${snap.error}'),
                ),
              );
            }
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final rows = snap.data!;
            if (rows.isEmpty) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(UtenSpacing.s16),
                  child: Text('订单货品均未维护 BOM，无物料需求'),
                ),
              );
            }
            String fmt(double? v) => v == null
                ? '—'
                : v.toStringAsFixed(v == v.roundToDouble() ? 0 : 2);
            return ListView(
              controller: ctl,
              padding: const EdgeInsets.all(UtenSpacing.s12),
              children: [
                Text(
                  '物料分析（本订单 BOM 展开）',
                  style: Theme.of(
                    ctx,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: UtenSpacing.s8),
                Row(
                  children: [
                    _mrpHead('物料', 3),
                    _mrpHead('毛需求', 1),
                    _mrpHead('库存', 1),
                    _mrpHead('在途', 1),
                    _mrpHead('净需求', 1),
                  ],
                ),
                const Divider(height: 1),
                for (final r in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: Text(
                            '${r.goodsName ?? ''}${r.selfMade ? '（自制）' : ''}',
                            style: const TextStyle(fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        _mrpCell(fmt(r.gross)),
                        _mrpCell(fmt(r.onhand)),
                        _mrpCell(fmt(r.openPo)),
                        _mrpCell(fmt(r.net), bold: true),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _mrpHead(String t, int flex) => Expanded(
    flex: flex,
    child: Text(
      t,
      textAlign: flex == 3 ? TextAlign.left : TextAlign.right,
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
    ),
  );

  Widget _mrpCell(String t, {bool bold = false}) => Expanded(
    child: Text(
      t,
      textAlign: TextAlign.right,
      style: TextStyle(
        fontSize: 12,
        fontWeight: bold ? FontWeight.w700 : FontWeight.normal,
      ),
    ),
  );

  Widget _actions(ThemeData theme) {
    final s = _detail!.status;
    final rejected = _detail!.rejected;
    final children = <Widget>[];
    if (s == kSalesStatusDraft && !rejected) {
      // C6：出货单财务审核入口（财务视角权限 finance_report:view；与仓库审核分开）
      if (_cfg.type == SalesDocType.shipment &&
          (ref.read(isSuperAdminProvider) ||
              ref
                  .read(currentPermissionsProvider)
                  .contains('finance_report:view'))) {
        if (_detail!.financeAudit == 1) {
          children
            ..add(
              UtenButton(
                type: UtenButtonType.secondary,
                icon: Icons.fact_check_outlined,
                onPressed: _financeAuditReverse,
                child: const Text('财务反审'),
              ),
            )
            ..add(const SizedBox(width: UtenSpacing.s8));
        } else {
          children
            ..add(
              UtenButton(
                icon: Icons.fact_check_outlined,
                onPressed: _financeAudit,
                child: const Text('财务审核'),
              ),
            )
            ..add(const SizedBox(width: UtenSpacing.s8));
        }
      }
      if (_canEdit) {
        children
          ..add(
            UtenButton(
              type: UtenButtonType.danger,
              icon: Icons.delete_outline,
              onPressed: _delete,
              child: const Text('删除'),
            ),
          )
          ..add(const SizedBox(width: UtenSpacing.s8))
          ..add(
            UtenButton(
              type: UtenButtonType.secondary,
              icon: Icons.edit_outlined,
              onPressed: () => context.push(
                SalesRoutePath.docEdit(_cfg.type.pathSegment, widget.id),
              ),
              child: const Text('编辑'),
            ),
          )
          ..add(const SizedBox(width: UtenSpacing.s8))
          ..add(
            UtenButton(
              icon: Icons.check_circle_outline,
              onPressed: _approve,
              child: const Text('审核'),
            ),
          );
      }
      if (_canReject) {
        if (children.isNotEmpty)
          children.add(const SizedBox(width: UtenSpacing.s8));
        children.add(
          UtenButton(
            type: UtenButtonType.danger,
            icon: Icons.block_outlined,
            onPressed: _reject,
            child: const Text('驳回'),
          ),
        );
      }
      if (children.isEmpty) {
        children.add(
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: () =>
                context.go(SalesRoutePath.list(_cfg.type.pathSegment)),
            child: const Text('返回列表'),
          ),
        );
      }
    } else if (s == kSalesStatusDraft && rejected) {
      // 已驳回（草稿终态）：只可删除重开
      if (_canEdit) {
        children
          ..add(
            UtenButton(
              type: UtenButtonType.danger,
              icon: Icons.delete_outline,
              onPressed: _delete,
              child: const Text('删除重开'),
            ),
          )
          ..add(const SizedBox(width: UtenSpacing.s8));
      }
      children.add(
        UtenButton(
          type: UtenButtonType.secondary,
          onPressed: () =>
              context.go(SalesRoutePath.list(_cfg.type.pathSegment)),
          child: const Text('返回列表'),
        ),
      );
    } else if (s == kSalesStatusApproved && _canEdit) {
      // 报价转订货（SOP §三1）：已审报价一键生成订货草稿
      if (_cfg.type == SalesDocType.quote && _canConvert) {
        children
          ..add(
            UtenButton(
              icon: Icons.transform_outlined,
              onPressed: _convertToOrder,
              child: const Text('转订货单'),
            ),
          )
          ..add(const SizedBox(width: UtenSpacing.s8));
      }
      if (_cfg.type == SalesDocType.order && !_detail!.stopped) {
        children
          ..add(
            UtenButton(
              type: UtenButtonType.secondary,
              icon: Icons.edit_note_outlined,
              onPressed: _changeQty,
              child: const Text('改量'),
            ),
          )
          ..add(const SizedBox(width: UtenSpacing.s8))
          // D3（李主管）：收到确定订单后即物料分析（BOM 展开 毛/净需求）
          ..add(
            UtenButton(
              type: UtenButtonType.secondary,
              icon: Icons.account_tree_outlined,
              onPressed: _showMrpAnalysis,
              child: const Text('物料分析'),
            ),
          )
          ..add(const SizedBox(width: UtenSpacing.s8))
          // 排产进度：销售端看链路另一端（每行 已排/已产 + 关联计划单溯源）
          ..add(
            UtenButton(
              type: UtenButtonType.secondary,
              icon: Icons.precision_manufacturing_outlined,
              onPressed: () =>
                  showPlanProgressSheet(context, ref, widget.id),
              child: const Text('排产进度'),
            ),
          )
          ..add(const SizedBox(width: UtenSpacing.s8))
          ..add(
            UtenButton(
              type: UtenButtonType.danger,
              icon: Icons.cancel_outlined,
              onPressed: _cancel,
              child: const Text('取消订单'),
            ),
          )
          ..add(const SizedBox(width: UtenSpacing.s8));
      }
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
          onPressed: () =>
              context.go(SalesRoutePath.list(_cfg.type.pathSegment)),
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
