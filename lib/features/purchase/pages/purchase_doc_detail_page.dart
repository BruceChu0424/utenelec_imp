// 采购单据详情页（全页路由）：主表头卡 + 只读明细子表 + 状态门控操作（审核/红冲/编辑/删除）。
//
// 计划下达的采购申请始终只读；订货走财务审批；收货/退货才沿用各自的草稿/审核/红冲动作。
// 所有动作同时受服务端 allowedActions 与权限约束。
// 名称解析：供应商/仓库/币种/颜色/单位用 MasterNameService；货品按明细 id 批量 lookup。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../config/purchase_doc_config.dart';
import '../models/purchase_doc.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../repositories/purchase_repository.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../core/router/nav_helpers.dart';
import '../widgets/purchase_status_badge.dart';

class PurchaseDocDetailPage extends ConsumerStatefulWidget {
  const PurchaseDocDetailPage({
    super.key,
    required this.docType,
    required this.id,
  });
  final PurchaseDocType docType;
  final String id;

  @override
  ConsumerState<PurchaseDocDetailPage> createState() =>
      _PurchaseDocDetailPageState();
}

class _PurchaseDocDetailPageState extends ConsumerState<PurchaseDocDetailPage> {
  PurchaseDocConfig get _cfg => PurchaseDocConfig.by(widget.docType);
  PurchaseDocDetail? _detail;
  bool _loading = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  bool get _hasEditPermission =>
      widget.docType != PurchaseDocType.request &&
      ref.read(currentPermissionsProvider).contains(_cfg.editPerm);

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(masterNameServiceProvider).ensureLoaded();
      final d = await ref
          .read(purchaseRepositoryProvider(widget.docType))
          .detail(widget.id);
      final goodsIds = d.items
          .map((e) => e.goodsId)
          .whereType<String>()
          .toSet();
      await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
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

  Future<void> _approveDocument() async {
    await _doAction(
      '审核后将驱动下游（库存/回写），确认审核？',
      (repo) => repo.approve(widget.id),
      '已审核',
      onApiError: (error) {
        if (widget.docType == PurchaseDocType.receipt &&
            error.code == 'ARRIVAL_EXCEPTION_PENDING') {
          context.appWarning(
            '实际到货超过财务批准数量，已先隔离：尚未入库、尚未生成应付，正在等待财务审批。',
            force: true,
          );
          context.go(RouteName.warehouseArrivalExceptions);
          return;
        }
        context.appError(error.message);
      },
    );
  }

  Future<void> _submitFinance() async => _doAction(
    '提交后订货单将锁定，并只发送给已配置的财务负责人审核。确认提交？',
    (repo) => repo.submitFinance(widget.id),
    '已提交财务审核',
  );

  Future<void> _approveFinance() async {
    final version = _detail?.financeApproval?.version ?? 0;
    if (version <= 0) {
      context.appWarning('审批任务版本无效，请刷新后重试');
      return;
    }
    await _doAction(
      '通过后订货单立即生效，并生成仓库预计到货任务。确认通过？',
      (repo) => repo.approveFinance(widget.id, expectedVersion: version),
      '财务审核已通过',
    );
  }

  Future<void> _rejectFinance() async {
    if (_busy) return;
    var reason = '';
    final confirmedReason = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('退回订货单'),
          content: TextField(
            autofocus: true,
            minLines: 3,
            maxLines: 5,
            maxLength: 1000,
            onChanged: (value) => setDialogState(() => reason = value.trim()),
            decoration: const InputDecoration(
              labelText: '退回原因（必填）',
              hintText: '请写清需要采购修改的内容',
            ),
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: reason.isEmpty
                  ? null
                  : () => Navigator.pop(ctx, reason),
              child: const Text('确认退回'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (confirmedReason == null || confirmedReason.isEmpty) return;
    final version = _detail?.financeApproval?.version ?? 0;
    if (version <= 0) {
      context.appWarning('审批任务版本无效，请刷新后重试');
      return;
    }
    setState(() => _busy = true);
    try {
      await ref
          .read(purchaseRepositoryProvider(widget.docType))
          .rejectFinance(
            widget.id,
            expectedVersion: version,
            reason: confirmedReason,
          );
      if (!mounted) return;
      context.appSuccess('已退回采购修改');
      bumpListRefresh(ref, _cfg.refreshKey);
      await _load();
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('退回失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reverse() async =>
      _doAction('红冲将反向冲销，确认？', (repo) => repo.reverse(widget.id), '已红冲');

  Future<void> _doAction(
    String confirm,
    Future<void> Function(PurchaseRepository) fn,
    String ok, {
    void Function(ApiException error)? onApiError,
  }) async {
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
      await fn(ref.read(purchaseRepositoryProvider(widget.docType)));
      if (!mounted) return;
      context.appSuccess(ok);
      bumpListRefresh(ref, _cfg.refreshKey);
      await _load();
    } on ApiException catch (e) {
      if (mounted) {
        final handler = onApiError;
        if (handler != null) {
          handler(e);
        } else {
          context.appError(e.message);
        }
      }
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
          .read(purchaseRepositoryProvider(widget.docType))
          .delete(widget.id);
      if (!mounted) return;
      context.appSuccess('已删除');
      context.go(
        RoutePath.purchaseDocDetail(
          _cfg.type.pathSegment,
          widget.id,
        ).replaceFirst('/${widget.id}', ''),
      );
      // 回列表
      context.go('/purchase/${_cfg.type.pathSegment}');
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
    final names = ref.watch(masterNameServiceProvider);
    return Scaffold(
      appBar: UtenAppBar(
        title: '${_cfg.label}详情',
        leading: UtenBackButton(
          onPressed: () =>
              popOrBackTo(context, defaultPath: RouteName.purchase),
        ),
        actions: [
          UtenButton(
            type: UtenButtonType.tonal,
            icon: Icons.history_rounded,
            onPressed: () => context.push('/purchase/${_cfg.type.pathSegment}'),
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
                    if (widget.docType == PurchaseDocType.order &&
                        (_detail!.financeApproval?.isPending == true ||
                            _detail!.financeApproval?.isRejected == true)) ...[
                      const SizedBox(height: UtenSpacing.s12),
                      _financeApprovalBanner(theme),
                    ],
                    if (_detail!.productionLinked) ...[
                      const SizedBox(height: UtenSpacing.s12),
                      _productionSourceBanner(theme),
                    ],
                    const SizedBox(height: UtenSpacing.s12),
                    _itemsCard(theme, names),
                  ],
                ),
        ),
      ),
      bottomNavigationBar: _detail == null || _busy ? null : _actions(theme),
    );
  }

  Widget _headerCard(ThemeData theme, MasterNameService names) {
    final d = _detail!;
    final rows = <_KV>[
      _KV('单据号', d.billNo),
      _KV('日期', d.billDate),
      _KV('制单员', d.makerName),
      _KV('制单时间', utenFmtIsoTime(d.createdAt)),
      if (_cfg.hasSupplier) _KV('供应商', names.supplier(d.supplierId)),
      _KV('仓库', names.warehouse(d.warehouseId)),
      if (_cfg.hasCurrency) _KV('币种', names.currency(d.currencyId)),
      if (d.exchangeRate != null) _KV('汇率', d.exchangeRate?.toString()),
      if (_cfg.hasApplicant) _KV('申请人', d.applicantId ?? '—'),
      if (_cfg.hasPurchaser) _KV('采购员', d.purchaserId ?? '—'),
      if (_cfg.hasSender) _KV('交货人', d.senderId ?? '—'),
      if (_cfg.hasReceiver) _KV('收货人', d.receiverId ?? '—'),
      if (_cfg.hasNeedDate) _KV('需求日', d.needDate),
      if (_cfg.hasDeliverDate) _KV('交货日', d.deliverDate),
      if (widget.docType != PurchaseDocType.request)
        _KV('合计(本币)', d.totalLocal?.toStringAsFixed(2)),
      if (d.remark?.isNotEmpty == true) _KV('备注', d.remark),
      if (widget.docType == PurchaseDocType.order) ...[
        _KV('财务审批', _financeApprovalLabel()),
        if (d.financeApproval?.assigneeName?.isNotEmpty == true)
          _KV('审核负责人', d.financeApproval!.assigneeName),
      ],
      _KV(
        '状态',
        widget.docType == PurchaseDocType.request && d.status == 1
            ? '计划已下达，等待采购分解'
            : null,
        badge: widget.docType == PurchaseDocType.request && d.status == 1
            ? null
            : PurchaseStatusBadge(status: d.status, closed: d.closed),
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

  /// 明细区：统一表格样式（MasterDataTableView 嵌入模式，与全站报表/主档同款：
  /// 表头设置列显隐 + 网格线 + 横滚），不再是卡片式拼凑行。
  Widget _itemsCard(ThemeData theme, MasterNameService names) {
    final items = _detail!.items;
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
        MasterDataTableView<PurchaseDocItem>(
          embedded: true,
          columns: [
            MasterColumnDef(
              key: 'goods',
              label: '货品',
              width: 220,
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
            if (widget.docType != PurchaseDocType.request) ...[
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
          ],
          items: items,
          facets: const {},
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
          emptyMessage: '暂无明细',
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
                widget.docType == PurchaseDocType.request
                    ? '$reason\n此申请由计划部下达，采购只能查看并在任务中心生成订货单。'
                    : '$reason\n仍可查看；后续调整请从生产计划专用流程发起。',
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

  String _financeApprovalLabel() {
    final approval = _detail!.financeApproval;
    if (approval == null) return '未获取审批状态';
    return switch (approval.status) {
      'DRAFT' => '未提交财务',
      'PENDING' => '等待财务审核组审核',
      'REJECTED' => '财务已退回，等待采购修改',
      'APPROVED' => '财务已通过',
      'CANCELED' => '审批已取消',
      'LEGACY_EFFECTIVE' => '历史已生效',
      'LEGACY_REVERSED' => '历史已红冲',
      _ => approval.status,
    };
  }

  Widget _financeApprovalBanner(ThemeData theme) {
    final approval = _detail!.financeApproval!;
    final rejected = approval.isRejected;
    final background = rejected
        ? theme.colorScheme.errorContainer
        : theme.colorScheme.secondaryContainer;
    final foreground = rejected
        ? theme.colorScheme.onErrorContainer
        : theme.colorScheme.onSecondaryContainer;
    final title = rejected ? '财务已退回，请修改后重新提交' : '等待财务审核组处理';
    final detail = rejected
        ? (approval.rejectionReason ?? '财务未填写退回原因')
        : '已提交财务审核组，审核期间订货单不能修改或删除。';
    return Semantics(
      container: true,
      label: '$title。$detail',
      child: Card(
        color: background,
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                rejected
                    ? Icons.assignment_return_outlined
                    : Icons.lock_clock_outlined,
                color: foreground,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      detail,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: foreground,
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
    void addAction(Widget action) {
      if (children.isNotEmpty) {
        children.add(const SizedBox(width: UtenSpacing.s8));
      }
      children.add(action);
    }

    if (widget.docType == PurchaseDocType.request) {
      addAction(
        UtenButton(
          type: UtenButtonType.secondary,
          onPressed: () => context.go('/purchase/${_cfg.type.pathSegment}'),
          child: const Text('返回列表'),
        ),
      );
    } else if (widget.docType == PurchaseDocType.order) {
      final approval = d.financeApproval;
      if (approval?.canReject == true) {
        addAction(
          UtenButton(
            type: UtenButtonType.danger,
            icon: Icons.assignment_return_outlined,
            onPressed: _rejectFinance,
            child: const Text('退回修改'),
          ),
        );
      }
      if (approval?.canApprove == true) {
        addAction(
          UtenButton(
            icon: Icons.check_circle_outline,
            onPressed: _approveFinance,
            child: const Text('财务通过'),
          ),
        );
      }
      if (s == kPurchaseStatusDraft && _hasEditPermission && d.canDelete) {
        addAction(
          UtenButton(
            type: UtenButtonType.danger,
            icon: Icons.delete_outline,
            onPressed: _delete,
            child: const Text('删除'),
          ),
        );
      }
      if (s == kPurchaseStatusDraft && _hasEditPermission && d.canEdit) {
        addAction(
          UtenButton(
            type: UtenButtonType.secondary,
            icon: Icons.edit_outlined,
            onPressed: () => context.push(
              RoutePath.purchaseDocEdit(_cfg.type.pathSegment, widget.id),
            ),
            child: const Text('编辑'),
          ),
        );
      }
      if (s == kPurchaseStatusDraft && approval?.canSubmit == true) {
        addAction(
          UtenButton(
            icon: Icons.send_outlined,
            onPressed: _submitFinance,
            child: Text(approval?.isRejected == true ? '重新提交财务' : '提交财务审核'),
          ),
        );
      }
      if (s == kPurchaseStatusApproved && _hasEditPermission && d.canReverse) {
        addAction(
          UtenButton(
            type: UtenButtonType.danger,
            icon: Icons.undo_outlined,
            onPressed: _reverse,
            child: const Text('红冲'),
          ),
        );
      }
      if (children.isEmpty) {
        addAction(
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: () => context.go('/purchase/${_cfg.type.pathSegment}'),
            child: const Text('返回列表'),
          ),
        );
      }
    } else if (s == kPurchaseStatusDraft && _hasEditPermission) {
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
              RoutePath.purchaseDocEdit(_cfg.type.pathSegment, widget.id),
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
          icon: Icons.check_circle_outline,
          onPressed: _approveDocument,
          child: const Text('审核'),
        ),
      );
    } else if (s == kPurchaseStatusApproved &&
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
          onPressed: () => context.go('/purchase/${_cfg.type.pathSegment}'),
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
