// 仓库单据详情页：主表头卡 + 只读明细子表 + 状态门控操作（审核/红冲/编辑/删除）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../../shared/auth/document_permission_set.dart';
import '../../../shared/auth/document_scope_capability.dart';
import '../../../shared/auth/document_scope_write_notice.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/widgets/source_doc_link.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../models/stock_doc.dart';
import '../providers/production_draw_count_provider.dart';
import '../providers/production_finished_inbound_task_count_provider.dart';
import '../repositories/stock_doc_repository.dart';

class StockDocDetailPage extends ConsumerStatefulWidget {
  const StockDocDetailPage({
    super.key,
    required this.docType,
    required this.id,
  });
  final StockDocType docType;
  final String id;

  @override
  ConsumerState<StockDocDetailPage> createState() => _StockDocDetailPageState();
}

class _StockDocDetailPageState extends ConsumerState<StockDocDetailPage> {
  StockDocDetail? _d;
  bool _loading = false;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  bool _allows(DocumentPermissionAction action) => DocumentPermissionCatalog
      .stockDocument
      .allows(ref.read(currentPermissionsProvider), action);

  bool get _ordinaryWritable => documentOwnerCanWrite(
    ref.read(documentScopeCapabilityProvider(DocumentDataScope.stockDocument)),
    _d?.makerId,
  );

  bool get _canCreate => _allows(DocumentPermissionAction.create);
  bool get _canEdit => _allows(DocumentPermissionAction.edit);
  bool get _canDelete => _allows(DocumentPermissionAction.delete);
  bool get _canApprove => _allows(DocumentPermissionAction.approve);
  bool get _canReverse => _allows(DocumentPermissionAction.reverse);
  bool get _canIssue =>
      ref.read(currentPermissionsProvider).contains(Perm.stockDocIssue);
  bool get _canReverseIssue =>
      ref.read(currentPermissionsProvider).contains(Perm.stockDocReverseIssue);

  Future<void> _load() async {
    ref.invalidate(
      documentScopeCapabilityProvider(DocumentDataScope.stockDocument),
    );
    setState(() => _loading = true);
    try {
      await ref.read(masterNameServiceProvider).ensureLoaded();
      final d = await ref
          .read(stockDocRepositoryProvider(widget.docType))
          .detail(widget.id);
      final goodsIds = d.items
          .map((e) => e.goodsId)
          .whereType<String>()
          .toSet();
      await ref.read(masterNameServiceProvider).loadGoodsDetails(goodsIds);
      if (!mounted) return;
      setState(() => _d = d);
    } catch (e) {
      if (mounted) {
        context.appError('加载详情失败');
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _act(
    String confirm,
    Future<void> Function() fn,
    String ok, {
    bool reviewerResponsibility = false,
  }) async {
    if (_busy) return;
    final c = reviewerResponsibility
        ? await showUtenReviewerConfirmDialog(context, message: confirm)
        : await showDialog<bool>(
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
      await fn();
      if (!mounted) return;
      context.appSuccess(ok);
      bumpListRefresh(ref, widget.docType.refreshKey);
      ref.invalidate(warehouseProductionDrawPendingCountProvider);
      ref.invalidate(warehouseProductionFinishedInboundPendingCountProvider);
      await _load();
    } catch (_) {
      if (mounted) context.appError('操作失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// DRAW 出库/取消出库对话框：按行输入本次数量；取消必须说明原因。
  Future<void> _issueDialog({required bool reverse}) async {
    if (_busy || _d == null) return;
    final names = ref.read(masterNameServiceProvider);
    final lines = _d!.items
        .where((it) => reverse ? (it.issuedQty ?? 0) > 0 : it.remainingQty > 0)
        .toList();
    final ctrls = {
      for (final it in lines)
        it.id!: TextEditingController(
          text: (reverse ? (it.issuedQty ?? 0) : it.remainingQty)
              .toStringAsFixed(2),
        ),
    };
    final reasonController = reverse ? TextEditingController() : null;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(reverse ? '取消出库' : '出库'),
        content: SizedBox(
          width: 420,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final it in lines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: Text(
                          '${names.goods(it.goodsId)}\n${reverse ? '可取消 ${(it.issuedQty ?? 0).toStringAsFixed(2)}' : '本次最多 ${it.remainingQty.toStringAsFixed(2)}'}',
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(fontWeight: FontWeight.w400),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: ctrls[it.id!],
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (reasonController != null) ...[
                const SizedBox(height: UtenSpacing.s8),
                TextField(
                  controller: reasonController,
                  maxLength: 1000,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: '取消原因(必填)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ],
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(reverse ? '确认取消出库' : '确认出库'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      for (final c in ctrls.values) {
        c.dispose();
      }
      reasonController?.dispose();
      return;
    }
    final cancellationReason = reasonController?.text.trim();
    reasonController?.dispose();
    if (reverse &&
        (cancellationReason == null || cancellationReason.length < 2)) {
      for (final c in ctrls.values) {
        c.dispose();
      }
      if (mounted) context.appError('取消出库必须填写至少 2 个字的原因');
      return;
    }

    // 组装请求行（>0 才提交；后端会再校验上限）
    final body = <Map<String, dynamic>>[];
    for (final it in lines) {
      final q = double.tryParse(ctrls[it.id]!.text.trim()) ?? 0;
      if (q > 0) body.add({'itemId': it.id, 'qty': q});
    }
    for (final c in ctrls.values) {
      c.dispose();
    }
    if (body.isEmpty) {
      if (mounted) context.appError('没有有效的数量');
      return;
    }
    final canonical = body
        .map((line) {
          final itemId = line['itemId'] as String;
          final current = _d!.items
              .firstWhere((item) => item.id == itemId)
              .issuedQty;
          return '$itemId|issued=${current ?? 0}|delta=${line['qty']}';
        })
        .join(';');
    final idempotencyKey = businessIdempotencyKey(
      reverse ? 'DRAW-ISSUE-REVERSE' : 'DRAW-ISSUE',
      '${widget.id}|$canonical',
    );

    setState(() => _busy = true);
    try {
      final repo = ref.read(stockDocRepositoryProvider(widget.docType));
      if (reverse) {
        await repo.reverseIssue(
          widget.id,
          body,
          idempotencyKey,
          cancellationReason!,
        );
      } else if (_d!.status == 0) {
        await repo.approveAndIssue(widget.id, body, idempotencyKey);
      } else {
        await repo.issue(widget.id, body, idempotencyKey);
      }
      if (!mounted) return;
      context.appSuccess(reverse ? '已取消出库' : '已出库');
      bumpListRefresh(ref, widget.docType.refreshKey);
      ref.invalidate(warehouseProductionDrawPendingCountProvider);
      ref.invalidate(warehouseProductionFinishedInboundPendingCountProvider);
      await _load();
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message);
    } catch (_) {
      if (mounted) context.appError(reverse ? '取消出库失败' : '出库失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// FQC PASS 只形成“待点收上限”；仓库逐行点收后，实收量才成为库存/iqty 权威。
  Future<void> _confirmFinishedInboundDialog() async {
    if (_busy || _d == null || _d!.items.isEmpty) return;
    final detail = _d!;
    final names = ref.read(masterNameServiceProvider);
    final controllers = <String, TextEditingController>{
      for (final item in detail.items)
        item.id!: TextEditingController(
          text: _quantityInputText(item.reportedQty ?? item.qty ?? 0),
        ),
    };
    final reasonController = TextEditingController();
    String? dialogError;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('确认成品实收数量'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '当前数量是已审核报工或 FQC PASS 形成的待点收上限，并不等于仓库已收。'
                    '请按实物逐行确认；少收部分会自动保留为新的待点收余量单。',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                  for (final item in detail.items)
                    Padding(
                      padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 3,
                            child: Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: Text(
                                '${names.goods(item.goodsId)}\n'
                                '待点收上限 ${_quantityInputText(item.reportedQty ?? item.qty ?? 0)} '
                                '${names.unit(item.unitId)}',
                              ),
                            ),
                          ),
                          const SizedBox(width: UtenSpacing.s8),
                          Expanded(
                            flex: 2,
                            child: TextField(
                              controller: controllers[item.id!],
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              decoration: UtenInputDecoration(
                                InputDecoration(
                                  label: fieldLabel(
                                    '仓库实收',
                                    Theme.of(context),
                                    info: '不超过待点收上限；整单全部填 0 表示拒收退回生产',
                                  ),
                                  border: const OutlineInputBorder(),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  TextField(
                    controller: reasonController,
                    minLines: 2,
                    maxLines: 4,
                    decoration: UtenInputDecoration(
                      InputDecoration(
                        label: fieldLabel(
                          '少收差异原因',
                          Theme.of(context),
                          info: '任一行实收少于申报量时必填，例如：本次只交接 80 件，余量待下批。',
                        ),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                  if (dialogError != null) ...[
                    const SizedBox(height: UtenSpacing.s8),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        dialogError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.inventory_rounded),
              onPressed: () {
                var hasVariance = false;
                for (final item in detail.items) {
                  final proposed = item.reportedQty ?? item.qty ?? 0;
                  final accepted = double.tryParse(
                    controllers[item.id]!.text.trim(),
                  );
                  if (accepted == null || accepted < 0) {
                    setDialogState(() => dialogError = '每行必须填写不小于 0 的实收数量');
                    return;
                  }
                  if (accepted > proposed + 0.0000001) {
                    setDialogState(() => dialogError = '实收数量不能超过待点收上限');
                    return;
                  }
                  hasVariance = hasVariance || accepted < proposed - 0.0000001;
                }
                if (hasVariance && reasonController.text.trim().isEmpty) {
                  setDialogState(() => dialogError = '少收时必须填写差异原因');
                  return;
                }
                Navigator.pop(dialogContext, true);
              },
              label: const Text('确认实收并入库'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) {
      for (final controller in controllers.values) {
        controller.dispose();
      }
      reasonController.dispose();
      return;
    }
    final lines = <Map<String, dynamic>>[
      for (final item in detail.items)
        {
          'itemId': item.id,
          'acceptedQty': double.parse(controllers[item.id]!.text.trim()),
        },
    ];
    final canonical = lines
        .map((line) => '${line['itemId']}|${line['acceptedQty']}')
        .join(';');
    final idempotencyKey = businessIdempotencyKey(
      'FINISHED-IN-CONFIRM',
      '${widget.id}|$canonical|${reasonController.text.trim()}',
    );
    for (final controller in controllers.values) {
      controller.dispose();
    }
    final reason = reasonController.text.trim();
    reasonController.dispose();

    setState(() => _busy = true);
    try {
      final result = await ref
          .read(stockDocRepositoryProvider(widget.docType))
          .confirmFinishedInbound(
            widget.id,
            lines,
            idempotencyKey,
            varianceReason: reason,
          );
      if (!mounted) return;
      context.appSuccess(
        result.status == -1
            ? '已整单拒收并退回生产核对；本次未增加库存或入库累计'
            : '仓库实收已确认，库存与入库累计已按实收量更新',
      );
      bumpListRefresh(ref, widget.docType.refreshKey);
      ref.invalidate(warehouseProductionFinishedInboundPendingCountProvider);
      await _load();
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message);
    } catch (_) {
      if (mounted) context.appError('成品实收确认失败，请刷新后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _quantityInputText(double value) => value
      .toStringAsFixed(4)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');

  Future<void> _delete() async {
    if (_busy) return;
    final c = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除'),
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
          .read(stockDocRepositoryProvider(widget.docType))
          .delete(widget.id);
      if (!mounted) return;
      context.appSuccess('已删除');
      bumpListRefresh(ref, widget.docType.refreshKey);
      context.go(RoutePath.stockDocList(widget.docType.code));
    } catch (_) {
      if (mounted) context.appError('删除失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Action buttons include issue/reverse permissions that are not part of
    // the document-owner scope provider. Watch the session permission snapshot
    // explicitly so grants/revokes update the DRAW toolbar without reopening.
    ref.watch(currentPermissionsProvider);
    final scopeCapability = ref.watch(
      documentScopeCapabilityProvider(DocumentDataScope.stockDocument),
    );
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    return Scaffold(
      appBar: UtenAppBar(
        title: '${widget.docType.label}详情',
        showBackButton: true,
        actions: [
          UtenButton(
            type: UtenButtonType.tonal,
            icon: Icons.history_rounded,
            onPressed: () =>
                context.push(RoutePath.stockDocList(widget.docType.code)),
            child: const Text('查看历史'),
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.narrow(
          child: _loading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
              : _d == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(UtenSpacing.s12),
                    child: Text(
                      _error == null ? '单据不存在' : '加载失败：$_error(可能是无权限或单据已被删除)',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                )
              : SelectionArea(
                  child: ListView(
                    padding: const EdgeInsets.all(UtenSpacing.s12),
                    children: [
                      DocumentScopeWriteNotice(
                        capability: scopeCapability,
                        ownerEmployeeId: _d!.makerId,
                        onRetry: () => ref.invalidate(
                          documentScopeCapabilityProvider(
                            DocumentDataScope.stockDocument,
                          ),
                        ),
                      ),
                      if (_d!.productionLinked) ...[
                        Material(
                          color: theme.colorScheme.primaryContainer,
                          borderRadius: UtenRadius.mdAll,
                          child: Padding(
                            padding: const EdgeInsets.all(UtenSpacing.s12),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  Icons.account_tree_outlined,
                                  color: theme.colorScheme.onPrimaryContainer,
                                ),
                                const SizedBox(width: UtenSpacing.s8),
                                Expanded(
                                  child: Text(
                                    '生产链自动生成\n'
                                    '${_d!.restrictionReason ?? '请在对应生产任务中维护'}',
                                    style: TextStyle(
                                      color:
                                          theme.colorScheme.onPrimaryContainer,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: UtenSpacing.s12),
                      ],
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(UtenSpacing.s12),
                          child: UtenFormGrid(
                            children: [
                              _kv('单据号', _d!.billNo, theme),
                              _kv('日期', _d!.billDate, theme),
                              _kv('制单员', _d!.makerName, theme),
                              _kv('制单时间', utenFmtIsoTime(_d!.createdAt), theme),
                              _kv(
                                '仓库',
                                names.warehouse(_d!.warehouseId),
                                theme,
                              ),
                              if (widget.docType == StockDocType.transfer)
                                _kv(
                                  '调入仓',
                                  names.warehouse(_d!.toWarehouseId),
                                  theme,
                                ),
                              if (widget.docType == StockDocType.draw) ...[
                                _kv(
                                  '领料车间',
                                  names.department(_d!.departmentId),
                                  theme,
                                ),
                                _kv(
                                  '出库进度',
                                  drawIssueStatusLabel(_d!.issueStatus),
                                  theme,
                                ),
                              ],
                              if (_d!.remark?.isNotEmpty == true)
                                _kv('备注', _d!.remark, theme),
                              _kv(
                                '状态',
                                widget.docType == StockDocType.finishedIn &&
                                        _d!.status == -1 &&
                                        _d!.finishedInboundDecision ==
                                            'REJECTED'
                                    ? '仓库拒收 · 待生产更正'
                                    : stockStatusLabel(_d!.status),
                                theme,
                              ),
                              if (widget.docType == StockDocType.finishedIn &&
                                  (_d!
                                          .finishedInboundVarianceReason
                                          ?.isNotEmpty ==
                                      true))
                                _kv(
                                  '差异原因',
                                  _d!.finishedInboundVarianceReason,
                                  theme,
                                ),
                              SourceDocLink(
                                label: '生产计划',
                                billNo: _d!.planNo,
                                onTap: _d!.sourcePlanId == null
                                    ? null
                                    : () => context.push(
                                        RoutePath.productionPlanDetail(
                                          _d!.sourcePlanId!,
                                        ),
                                      ),
                              ),
                              SourceDocLink(
                                label: '来源报工',
                                billNo: _d!.sourceDocNo,
                                onTap: _d!.sourceDailyReportId == null
                                    ? null
                                    : () => context.push(
                                        '/production/daily-reports/${_d!.sourceDailyReportId}',
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s12),
                      // 明细区：统一表格样式（嵌入模式，与全站报表/主档同款），不再是卡片 ListTile。
                      Text(
                        '明细 (${_d!.items.length})',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s8),
                      MasterDataTableView<StockDocItem>(
                        embedded: true,
                        columns: [
                          MasterColumnDef(
                            key: 'goodsCode',
                            label: '物料编码',
                            width: 110,
                            value: (it) =>
                                names.goodsInfo(it.goodsId)?.code ?? '—',
                          ),
                          MasterColumnDef(
                            key: 'goods',
                            label: '货品名称',
                            width: 200,
                            value: (it) => names.goods(it.goodsId),
                          ),
                          MasterColumnDef(
                            key: 'series',
                            label: '系列',
                            width: 80,
                            value: (it) =>
                                names.goodsInfo(it.goodsId)?.series ?? '—',
                          ),
                          MasterColumnDef(
                            key: 'stockPlace',
                            label: '库位号',
                            width: 80,
                            value: (it) => it.place?.trim().isNotEmpty == true
                                ? it.place!
                                : names.goodsInfo(it.goodsId)?.stockPlace ??
                                      '—',
                          ),
                          MasterColumnDef(
                            key: 'color',
                            label: '颜色',
                            width: 80,
                            value: (it) => names.color(it.colorId),
                          ),
                          MasterColumnDef(
                            key: 'unit',
                            label: '单位',
                            width: 64,
                            value: (it) => names.unit(it.unitId),
                          ),
                          MasterColumnDef(
                            key: 'weight',
                            label: '实际重量',
                            width: 90,
                            type: 'number',
                            value: (it) => it.weight?.toStringAsFixed(2) ?? '—',
                          ),
                          if (widget.docType == StockDocType.check) ...[
                            MasterColumnDef(
                              key: 'bookQty',
                              label: '账面数量',
                              width: 90,
                              type: 'number',
                              value: (it) => (it.qty ?? 0).toStringAsFixed(2),
                            ),
                            MasterColumnDef(
                              key: 'countQty',
                              label: '实盘数量',
                              width: 90,
                              type: 'number',
                              value: (it) => it.countQty?.toStringAsFixed(1),
                            ),
                            MasterColumnDef(
                              key: 'surplusQty',
                              label: '盈亏',
                              width: 90,
                              type: 'number',
                              value: (it) => it.surplusQty?.toStringAsFixed(1),
                            ),
                          ] else if (widget.docType == StockDocType.draw) ...[
                            MasterColumnDef(
                              key: 'qty',
                              label: '数量',
                              width: 90,
                              type: 'number',
                              value: (it) => (it.qty ?? 0).toStringAsFixed(2),
                            ),
                            MasterColumnDef(
                              key: 'issuedQty',
                              label: '已出库',
                              width: 90,
                              type: 'number',
                              value: (it) =>
                                  (it.issuedQty ?? 0).toStringAsFixed(2),
                            ),
                            MasterColumnDef(
                              key: 'remainingQty',
                              label: '剩余',
                              width: 90,
                              type: 'number',
                              value: (it) => it.remainingQty.toStringAsFixed(2),
                            ),
                          ] else if (widget.docType ==
                              StockDocType.finishedIn) ...[
                            MasterColumnDef(
                              key: 'reportedQty',
                              label: '待点收上限',
                              width: 100,
                              type: 'number',
                              value: (it) => (it.reportedQty ?? it.qty ?? 0)
                                  .toStringAsFixed(2),
                            ),
                            MasterColumnDef(
                              key: 'acceptedQty',
                              label: _d!.status == 1 ? '仓库实收' : '待点收',
                              width: 100,
                              type: 'number',
                              value: (it) => (it.qty ?? 0).toStringAsFixed(2),
                            ),
                          ] else
                            MasterColumnDef(
                              key: 'qty',
                              label: '数量',
                              width: 90,
                              type: 'number',
                              value: (it) => (it.qty ?? 0).toStringAsFixed(2),
                            ),
                        ],
                        items: _d!.items,
                        facets: const {},
                        nullCounts: const {},
                        filters: const {},
                        onFilterChanged: (_, _) {},
                        emptyMessage: '暂无明细',
                      ),
                    ],
                  ),
                ),
        ),
      ),
      bottomNavigationBar: _d == null || _busy ? null : _actions(theme),
    );
  }

  Widget _kv(String label, String? value, ThemeData theme) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 84,
        child: Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      const SizedBox(width: UtenSpacing.s8),
      Expanded(child: Text(value ?? '—')),
    ],
  );

  Widget _actions(ThemeData theme) {
    final detail = _d!;
    final children = <Widget>[];

    void addAction(Widget action) {
      if (children.isNotEmpty) {
        children.add(const SizedBox(width: UtenSpacing.s8));
      }
      children.add(action);
    }

    void addBack() {
      addAction(
        UtenButton(
          type: UtenButtonType.secondary,
          onPressed: () =>
              context.go(RoutePath.stockDocList(widget.docType.code)),
          child: const Text('返回列表'),
        ),
      );
    }

    if (detail.status == 0) {
      if (!detail.productionLinked &&
          _ordinaryWritable &&
          _canDelete &&
          detail.canDelete) {
        addAction(
          UtenButton(
            type: UtenButtonType.danger,
            icon: Icons.delete_outline,
            onPressed: _delete,
            child: const Text('删除'),
          ),
        );
      }
      if (!detail.productionLinked &&
          _ordinaryWritable &&
          _canEdit &&
          detail.canEdit) {
        addAction(
          UtenButton(
            type: UtenButtonType.secondary,
            icon: Icons.edit_outlined,
            onPressed: () => context.push(
              RoutePath.stockDocEdit(widget.docType.code, widget.id),
            ),
            child: const Text('编辑'),
          ),
        );
      }
      if (widget.docType == StockDocType.draw &&
          (_canApprove || _canIssue) &&
          (detail.productionLinked || _ordinaryWritable)) {
        addAction(
          UtenButton(
            icon: Icons.logout_rounded,
            onPressed: _canApprove && _canIssue
                ? () => _issueDialog(reverse: false)
                : null,
            onDisabledTap: () => context.appWarning(
              '草稿生产领料单只允许“出库即审核”；当前账号需要同时具备审核和出库权限。',
              force: true,
            ),
            child: const Text('出库'),
          ),
        );
      } else if (widget.docType != StockDocType.draw &&
          _canApprove &&
          (detail.productionLinked || _ordinaryWritable)) {
        addAction(
          UtenButton(
            icon:
                detail.productionLinked &&
                    widget.docType == StockDocType.finishedIn
                ? Icons.inventory_rounded
                : Icons.check_circle_outline,
            onPressed:
                detail.productionLinked &&
                    widget.docType == StockDocType.finishedIn
                ? _confirmFinishedInboundDialog
                : () => _act(
                    '审核将联动库存，确认？',
                    () => ref
                        .read(stockDocRepositoryProvider(widget.docType))
                        .approve(widget.id),
                    '已审核',
                    reviewerResponsibility: true,
                  ),
            child: Text(
              detail.productionLinked &&
                      widget.docType == StockDocType.finishedIn
                  ? '确认实收并入库'
                  : '审核',
            ),
          ),
        );
      }
      if (children.isEmpty) addBack();
    } else if (detail.status == 1) {
      if (widget.docType == StockDocType.draw) {
        final anyRemaining = detail.items.any((item) => item.remainingQty > 0);
        final anyIssued = detail.items.any((item) => (item.issuedQty ?? 0) > 0);
        if (anyRemaining && _canIssue) {
          addAction(
            UtenButton(
              icon: Icons.logout_rounded,
              onPressed: () => _issueDialog(reverse: false),
              child: const Text('出库'),
            ),
          );
        }
        if (anyIssued && _canCreate) {
          addAction(
            UtenButton(
              type: UtenButtonType.tonal,
              icon: Icons.assignment_return_outlined,
              onPressed: () =>
                  context.push(RoutePath.stockWdrawNewFromDraw(widget.id)),
              child: const Text('余料退库'),
            ),
          );
        }
        if (anyIssued && _canReverseIssue) {
          addAction(
            UtenButton(
              type: UtenButtonType.secondary,
              icon: Icons.undo_rounded,
              onPressed: () => _issueDialog(reverse: true),
              child: const Text('取消出库'),
            ),
          );
        }
      }
      if (_canReverse &&
          (detail.productionLinked || _ordinaryWritable) &&
          (!detail.productionLinked ||
              widget.docType == StockDocType.finishedIn)) {
        final productionFinishedInbound =
            detail.productionLinked &&
            widget.docType == StockDocType.finishedIn;
        addAction(
          UtenButton(
            type: UtenButtonType.danger,
            icon: Icons.undo_outlined,
            onPressed: () => _act(
              productionFinishedInbound
                  ? '红冲将反向库存与入库累计，并按原实收量重建待点收草稿，确认？'
                  : '红冲将反向冲销库存，确认？',
              () {
                final repository = ref.read(
                  stockDocRepositoryProvider(widget.docType),
                );
                return productionFinishedInbound
                    ? repository.reverseFinishedInbound(widget.id)
                    : repository.reverse(widget.id);
              },
              productionFinishedInbound ? '已红冲并重建待点收任务' : '已红冲',
            ),
            child: const Text('红冲'),
          ),
        );
      }
      if (children.isEmpty) addBack();
    } else {
      addBack();
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
