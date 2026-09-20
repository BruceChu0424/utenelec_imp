// 仓库单据详情页：主表头卡 + 只读明细子表 + 状态门控操作（审核/红冲/编辑/删除）。
//
// 2026-09-11 折叠头+表内滚改版（对齐采购/货品资料页）：整页 ListView 改
// UtenCollapsingHeaderScrollView——上滑先折叠头部（提示条/生产链横幅/表头卡/出库凭证），
// 「明细 (N)」标题顶到页面顶部后再滚明细表内部。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_app_bar_action_button.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/l10n/gen/app_localizations_zh.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../../shared/attachments/business_attachment_section.dart';
import '../../../shared/auth/document_permission_set.dart';
import '../../../shared/auth/document_scope_capability.dart';
import '../../../shared/auth/document_scope_write_notice.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/widgets/source_doc_link.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../models/stock_doc.dart';
import '../widgets/production_draw_detail_table.dart';
import '../widgets/production_material_return_receive_dialog.dart';
import '../widgets/warehouse_stock_outbound_detail_table.dart';
import '../providers/production_draw_count_provider.dart';
import '../providers/production_return_count_provider.dart';
import '../../production/providers/production_execution_refresh.dart';
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
  bool _confirmingOutbound = false;
  String? _outboundReviewToken;
  String? _materialReturnWarehouseId, _materialReturnKey;
  bool _confirmingMaterialReturn = false;

  // 2026-09-12 用户口径「数量在表格里改，出库只弹总结」：DRAW 待出库行的
  // 「本次出库/行备注」输入由页面持有（_load 后按最新明细重建，随路由销毁）；
  // 总备注在表格上方单独一个输入框。
  final Map<String, TextEditingController> _issueQty = {};
  final Map<String, TextEditingController> _lineRemarks = {};
  final TextEditingController _issueRemark = TextEditingController();
  bool get _isOrdinaryOutbound =>
      widget.docType == StockDocType.otherOut ||
      widget.docType == StockDocType.finishedOut;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _disposeIssueInputs();
    _issueRemark.dispose();
    super.dispose();
  }

  void _disposeIssueInputs() {
    for (final controller in _issueQty.values) {
      controller.dispose();
    }
    _issueQty.clear();
    for (final controller in _lineRemarks.values) {
      controller.dispose();
    }
    _lineRemarks.clear();
  }

  bool _allows(DocumentPermissionAction action) => DocumentPermissionCatalog
      .stockDocument
      .allows(ref.read(currentPermissionsProvider), action);

  bool get _ordinaryWritable => documentOwnerCanWrite(
    ref.read(documentScopeCapabilityProvider(DocumentDataScope.stockDocument)),
    _d?.makerId,
  );

  bool get _canEdit =>
      widget.docType.supportsManualDraft &&
      _allows(DocumentPermissionAction.edit);
  bool get _canDelete => _allows(DocumentPermissionAction.delete);
  bool get _canApprove => _allows(DocumentPermissionAction.approve);
  bool get _canReverse => _allows(DocumentPermissionAction.reverse);
  bool get _canView =>
      ref.read(currentPermissionsProvider).contains(Perm.stockDocView);
  bool get _canIssue =>
      ref.read(currentPermissionsProvider).contains(Perm.stockDocIssue);
  bool get _canReverseIssue =>
      ref.read(currentPermissionsProvider).contains(Perm.stockDocReverseIssue);

  /// 「返回列表」显隐：与列表路由守卫同源（build 已 watch 权限快照）。
  bool get _canOpenList => locationAllowedFor(
    ref.read(currentPermissionsProvider),
    ref.read(isSuperAdminProvider),
    RoutePath.stockDocList(widget.docType.code),
  );

  Future<void> _load() async {
    ref.invalidate(
      documentScopeCapabilityProvider(DocumentDataScope.stockDocument),
    );
    setState(() {
      _loading = true;
      _error = null;
      _outboundReviewToken = null;
    });
    try {
      await ref.read(masterNameServiceProvider).ensureLoaded();
      final repo = ref.read(stockDocRepositoryProvider(widget.docType));
      final review = _isOrdinaryOutbound ? await repo.review(widget.id) : null;
      final d = review?.document ?? await repo.detail(widget.id);
      final goodsIds = d.items
          .map((e) => e.goodsId)
          .whereType<String>()
          .toSet();
      await ref.read(masterNameServiceProvider).loadGoodsDetails(goodsIds);
      if (!mounted) return;
      setState(() {
        _d = d;
        _outboundReviewToken = review?.reviewToken;
        if (d.status != 0) {
          _materialReturnWarehouseId = null;
          _materialReturnKey = null;
        }
      });
      _rebuildIssueInputs();
    } catch (e) {
      if (mounted) {
        context.appError('加载详情失败');
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _confirmOrdinaryOutbound() async {
    if (_busy ||
        _loading ||
        _confirmingOutbound ||
        !_canApprove ||
        _outboundReviewToken == null) {
      return;
    }
    final l10n =
        Localizations.of<AppLocalizations>(context, AppLocalizations) ??
        AppLocalizationsZh();
    final token = _outboundReviewToken!;
    setState(() => _confirmingOutbound = true);
    try {
      final confirmed = await UtenDialog.show(
        context,
        title: l10n.warehouseStockOutboundConfirmSingle,
        confirmLabel: l10n.warehouseStockOutboundConfirmSingle,
        content: Text(l10n.warehouseStockOutboundConfirmMessage(1)),
      );
      if (confirmed != true || !mounted) return;
      setState(() => _busy = true);
      await ref
          .read(stockDocRepositoryProvider(widget.docType))
          .approveReviewed(widget.id, expectedReviewToken: token);
      if (!mounted) return;
      context.appSuccess(l10n.warehouseStockOutboundCompleted(1));
      bumpListRefresh(ref, widget.docType.refreshKey);
      await _load();
    } catch (e) {
      if (mounted) {
        setState(() => _outboundReviewToken = null);
        context.appError(
          e is ApiException ? e.message : l10n.warehouseOutboundBatchUnknown,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _confirmingOutbound = false;
        });
      }
    }
  }

  Future<void> _confirmMaterialReturn() async {
    final detail = _d;
    if (_busy ||
        _loading ||
        _confirmingMaterialReturn ||
        !_canApprove ||
        detail == null ||
        detail.status != 0 ||
        !detail.productionMaterialReturn) {
      return;
    }
    setState(() => _confirmingMaterialReturn = true);
    try {
      final warehouseId =
          _materialReturnWarehouseId ??
          await showProductionMaterialReturnReceiveDialog(
            context,
            hierarchy: ref.read(masterNameServiceProvider).warehouseHierarchy,
            mainWarehouseId: detail.materialReturnMainWarehouseId,
            initialWarehouseId: detail.warehouseId,
          );
      if (warehouseId == null || !mounted) return;
      setState(() {
        _materialReturnWarehouseId = warehouseId;
        _materialReturnKey ??= businessIdempotencyKey(
          'material-return-confirm',
          '${widget.id}|$warehouseId',
        );
        _busy = true;
      });
      await ref
          .read(stockDocRepositoryProvider(widget.docType))
          .confirmMaterialReturn(
            widget.id,
            warehouseId: warehouseId,
            idempotencyKey: _materialReturnKey!,
          );
      if (!mounted) return;
      setState(() {
        _materialReturnWarehouseId = null;
        _materialReturnKey = null;
      });
      context.appSuccess('余料已收进实际仓库，库存与车间台账已更新');
      bumpListRefresh(ref, widget.docType.refreshKey);
      ref.invalidate(warehouseProductionDrawPendingCountProvider);
      ref.invalidate(warehouseProductionReturnPendingCountProvider);
      ref.invalidate(warehouseProductionFinishedInboundPendingCountProvider);
      refreshAfterProductionPlanGenerated(ref);
      await _load();
    } on ApiException catch (error) {
      if (!mounted) return;
      final uncertain =
          error is NetworkException ||
          error is NetworkTimeoutException ||
          error.code == 'INTERNAL' ||
          (error.httpStatus != null && error.httpStatus! >= 500);
      if (!uncertain) {
        setState(() {
          _materialReturnWarehouseId = null;
          _materialReturnKey = null;
        });
      }
      context.appError(
        uncertain
            ? '暂未确认收料结果，请重试本次收料；原收料仓库和提交信息已保留。'
            : error.fieldErrors?.firstOrNull?.message ?? error.message,
      );
    } catch (_) {
      if (mounted) context.appError('暂未确认收料结果，请重试本次收料；原收料仓库和提交信息已保留。');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _confirmingMaterialReturn = false;
        });
      }
    }
  }

  Future<void> _act(
    String confirm,
    Future<void> Function() fn,
    String ok, {
    bool reviewerResponsibility = false,
    String? confirmLabel,
    String? confirmTitle,
  }) async {
    if (_busy) return;
    final c = reviewerResponsibility
        ? await showUtenReviewerConfirmDialog(
            context,
            message: confirm,
            title: confirmTitle ?? (confirmLabel == null ? '确认审核' : '核对退料实收'),
            confirmLabel: confirmLabel ?? '确认审核',
            actionLabel: confirmLabel ?? '审核',
          )
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
      ref.invalidate(warehouseProductionReturnPendingCountProvider);
      ref.invalidate(warehouseProductionFinishedInboundPendingCountProvider);
      if (widget.docType == StockDocType.wdraw) {
        refreshAfterProductionPlanGenerated(ref);
      }
      await _load();
    } catch (error) {
      if (mounted) context.appApiError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 按最新明细重建「本次出库/行备注」输入（默认=待出库；行备注保持已输入值
  /// 不易做——重载后明细可能变化，统一重置为空，与旧弹窗每次重开同口径）。
  void _rebuildIssueInputs() {
    if (widget.docType != StockDocType.draw || !_canIssue) {
      _disposeIssueInputs();
      return;
    }
    final detail = _d;
    if (detail == null) {
      _disposeIssueInputs();
      return;
    }
    _disposeIssueInputs();
    for (final item in detail.items) {
      if (item.remainingQty <= 0 || item.id == null) continue;
      _issueQty[item.id!] = TextEditingController(
        text: _quantityInputText(item.remainingQty),
      );
      _lineRemarks[item.id!] = TextEditingController();
    }
  }

  /// 2026-09-12 用户口径：出库数量/备注在表格里改好，点「出库」只弹**总结**
  /// 确认（不再在弹窗里改数字、也不再传附件——出库凭证区详情页常驻）。
  Future<void> _issueFromTable() async {
    if (_busy || _d == null) return;
    final detail = _d!;
    final names = ref.read(masterNameServiceProvider);
    // 逐行校验（只看待出库行；0 行留给合计拦截）。
    final body = <Map<String, dynamic>>[];
    var lineCount = 0;
    for (final item in detail.items) {
      if (item.remainingQty <= 0 || item.id == null) continue;
      final controller = _issueQty[item.id!];
      if (controller == null) continue;
      final row = ProductionDrawDetailRow(detail, item);
      final problem = drawIssueQtyError(row, controller.text);
      if (problem != null) {
        context.appError('${names.goods(item.goodsId)}：$problem');
        return;
      }
      final qty = double.tryParse(controller.text.trim()) ?? 0;
      if (qty <= 0) continue; // 明确填 0 的行跳过（分批出库）
      body.add({'itemId': item.id, 'qty': qty});
      lineCount++;
    }
    if (body.isEmpty) {
      context.appError('请先在表格里填写本次出库数量');
      return;
    }
    // 备注合成：总备注在前，行备注（货品：备注）随后，用「；」连接；服务端
    // 单次出库 remark 上限 200、多轮拼接总长 500，超长在这里就地拦下。
    final parts = <String>[
      if (_issueRemark.text.trim().isNotEmpty) _issueRemark.text.trim(),
      for (final entry in _lineRemarks.entries)
        if (entry.value.text.trim().isNotEmpty)
          '${names.goods(detail.items.firstWhere((it) => it.id == entry.key).goodsId)}：${entry.value.text.trim()}',
    ];
    final remark = parts.join('；');
    if (remark.length > 200) {
      context.appError('备注合计 ${remark.length} 字超过单次出库 200 字上限，请精简总备注或行备注');
      return;
    }
    // 合计（按单位分组，跨单位绝不相加——全站口径）。
    final byUnit = <String, double>{};
    for (final line in body) {
      final item = detail.items.firstWhere((it) => it.id == line['itemId']);
      final unit = item.unitId == null ? '' : names.unit(item.unitId!);
      byUnit.update(
        unit,
        (sum) => sum + (line['qty'] as double),
        ifAbsent: () => line['qty'] as double,
      );
    }
    final totalsText = [
      for (final entry in byUnit.entries)
        '${_quantityInputText(entry.value)}${entry.key.isEmpty ? '' : ' ${entry.key}'}',
    ].join(' · ');
    final confirmed = await UtenDialog.show(
      context,
      title: '确认出库（$lineCount 行）',
      confirmLabel: '确认出库',
      content: _issueSummaryPoints(totalsText, remark),
    );
    if (confirmed != true || !mounted) return;
    await _executeIssue(body, reverse: false, remark: remark);
  }

  Widget _issueSummaryPoints(String totalsText, String remark) {
    final theme = Theme.of(context);
    final points = <String>[
      '本次出库 $totalsText；提交后按行核销待出库量并写入库存。',
      if (remark.isNotEmpty) '备注：$remark',
      '出库凭证/照片请在页面附件区上传（提交前后均可）。',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final point in points)
          Padding(
            padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
            child: Text('· $point', style: theme.textTheme.bodyMedium),
          ),
      ],
    );
  }

  /// 取消出库对话框（按行输入可退量，必填原因）；正向出库走 _issueFromTable。
  Future<void> _issueDialog({required bool reverse}) async {
    if (_busy || _d == null) return;
    final names = ref.read(masterNameServiceProvider);
    final lines = _d!.items
        .where((it) => reverse ? (it.issuedQty ?? 0) > 0 : it.remainingQty > 0)
        .toList();
    // 输入控制器由弹窗自己持有（随路由销毁）：此前在 showDialog 返回后立刻
    // dispose，退场动画期间的重建会再次订阅已销毁的控制器（备注框带字数计数
    // 器时必现）。
    final input = await showDialog<_IssueDialogInput>(
      context: context,
      builder: (ctx) => _IssueDialog(
        reverse: reverse,
        lines: lines,
        warehouseLabel:
            '${reverse ? '退回原仓' : '领料仓库'}：${names.warehouse(_d!.warehouseId)}',
        names: names,
        docId: widget.id,
        canView: _canView,
        canIssue: _canIssue,
      ),
    );
    if (input == null || !mounted) return;
    // 取消出库=必填原因（审计）；正向出库=选填备注（追加到单据 remark 留痕）。
    final cancellationReason = input.reason;
    final issueRemark = reverse ? null : cancellationReason;
    if (reverse && cancellationReason.length < 2) {
      context.appError('取消出库必须填写至少 2 个字的原因');
      return;
    }

    // 组装请求行（>0 才提交；后端会再校验上限）
    final body = <Map<String, dynamic>>[];
    for (final it in lines) {
      final q = double.tryParse(input.quantities[it.id!] ?? '') ?? 0;
      if (q > 0) body.add({'itemId': it.id, 'qty': q});
    }
    if (body.isEmpty) {
      context.appError('没有有效的数量');
      return;
    }
    await _executeIssue(
      body,
      reverse: reverse,
      remark: issueRemark,
      cancellationReason: cancellationReason,
    );
  }

  /// 出库执行段（表格流与取消出库弹窗共用）：幂等键按行issued/delta指纹派生，
  /// 响应丢失重试复用同键安全重放；成功后重拉详情并失效仓库计数。
  Future<void> _executeIssue(
    List<Map<String, dynamic>> body, {
    required bool reverse,
    String? remark,
    String? cancellationReason,
  }) async {
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
          cancellationReason ?? '',
        );
      } else if (_d!.status == 0) {
        // 首轮出库（出库即审核）同样带备注：此前没传，备注被静默丢弃。
        await repo.approveAndIssue(
          widget.id,
          body,
          idempotencyKey,
          remark: remark,
        );
      } else {
        await repo.issue(widget.id, body, idempotencyKey, remark: remark);
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
      // 返回键契约（路由设计 §十一）：pop 回来源，栈空回列表（无列表权限回 hub）。
      popOrBackTo(
        context,
        defaultPath: _canOpenList
            ? RoutePath.stockDocList(widget.docType.code)
            : RouteName.warehouse,
      );
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
    return PopScope(
      canPop: !_isOrdinaryOutbound || (!_busy && !_confirmingOutbound),
      child: Scaffold(
        appBar: UtenAppBar(
          title: '${widget.docType.label}详情',
          showBackButton: true,
          actions: [
            if (_isOrdinaryOutbound)
              UtenAppBarActionButton(
                label:
                    (Localizations.of<AppLocalizations>(
                              context,
                              AppLocalizations,
                            ) ??
                            AppLocalizationsZh())
                        .commonRefresh,
                icon: Icons.refresh_rounded,
                isLoading: _loading,
                onPressed: _loading || _busy || _confirmingOutbound
                    ? null
                    : _load,
              ),
          ],
        ),
        body: Stack(
          children: [
            SafeArea(
              child: UtenContentContainer(
                // 2026-09-15 宽度口径（用户反馈）：非普通出库弃 narrow(1120)（两侧
                // 大留白），改默认 1600 钳制对齐新建销售订货单页；普通出库仍全宽。
                maxWidth: _isOrdinaryOutbound
                    ? UtenContentContainer.wideMaxWidth
                    : UtenBreakpoints.maxContentWidth,
                center: !_isOrdinaryOutbound,
                child: _loading
                    ? const Center(
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      )
                    : _d == null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(UtenSpacing.s12),
                          child: Text(
                            _error == null
                                ? '单据不存在'
                                : '加载失败：$_error(可能是无权限或单据已被删除)',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                      )
                    // 2026-09-11 折叠头+表内滚（对齐采购/货品资料页）：上滑先收头部
                    // （提示条/生产链横幅/表头卡/出库凭证），明细标题吸顶后表格内部继续滚。
                    : UtenCollapsingHeaderScrollView(
                        collapsingHeader: Padding(
                          padding: const EdgeInsets.fromLTRB(
                            UtenSpacing.s12,
                            UtenSpacing.s12,
                            UtenSpacing.s12,
                            0,
                          ),
                          // 表头文字框选：只包折叠头（表格自带选择能力，不再套在
                          // 页面级 SelectionArea 里）。
                          child: SelectionArea(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
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
                                      padding: const EdgeInsets.all(
                                        UtenSpacing.s12,
                                      ),
                                      child: Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Icon(
                                            Icons.account_tree_outlined,
                                            color: theme
                                                .colorScheme
                                                .onPrimaryContainer,
                                          ),
                                          const SizedBox(width: UtenSpacing.s8),
                                          Expanded(
                                            child: Text(
                                              '生产链自动生成\n'
                                              '${_d!.restrictionReason ?? '请在对应生产任务中维护'}',
                                              style: TextStyle(
                                                color: theme
                                                    .colorScheme
                                                    .onPrimaryContainer,
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
                                    padding: const EdgeInsets.all(
                                      UtenSpacing.s12,
                                    ),
                                    child: UtenFormGrid(
                                      children: [
                                        _kv('单据号', _d!.billNo, theme),
                                        _kv('日期', _d!.billDate, theme),
                                        _kv('制单员', _d!.makerName, theme),
                                        _kv(
                                          '制单时间',
                                          utenFmtIsoTime(_d!.createdAt),
                                          theme,
                                        ),
                                        if (widget.docType != StockDocType.draw)
                                          _kv(
                                            _d!.productionMaterialReturn
                                                ? '实际收料仓库'
                                                : '仓库',
                                            _d!.productionMaterialReturn &&
                                                    _d!.warehouseId == null
                                                ? '待仓库确认'
                                                : names.warehouse(
                                                    _d!.warehouseId,
                                                  ),
                                            theme,
                                          ),
                                        if (widget.docType ==
                                            StockDocType.transfer)
                                          _kv(
                                            '调入仓',
                                            names.warehouse(_d!.toWarehouseId),
                                            theme,
                                          ),
                                        if (_d!.remark?.isNotEmpty == true)
                                          _kv('备注', _d!.remark, theme),
                                        _kv(
                                          '状态',
                                          widget.docType ==
                                                      StockDocType.finishedIn &&
                                                  _d!.status == -1 &&
                                                  _d!.finishedInboundDecision ==
                                                      'REJECTED'
                                              ? '仓库拒收 · 待生产更正'
                                              : stockStatusLabel(_d!.status),
                                          theme,
                                        ),
                                        if (widget.docType ==
                                                StockDocType.finishedIn &&
                                            (_d!
                                                    .finishedInboundVarianceReason
                                                    ?.isNotEmpty ==
                                                true))
                                          _kv(
                                            '差异原因',
                                            _d!.finishedInboundVarianceReason,
                                            theme,
                                          ),
                                        if (widget.docType != StockDocType.draw)
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
                                        if (widget.docType != StockDocType.draw)
                                          SourceDocLink(
                                            label: '来源报工',
                                            billNo: _d!.sourceDocNo,
                                            onTap:
                                                _d!.sourceDailyReportId == null
                                                ? null
                                                : () => context.push(
                                                    '/production/daily-reports/${_d!.sourceDailyReportId}',
                                                  ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                                if (widget.docType == StockDocType.draw) ...[
                                  const SizedBox(height: UtenSpacing.s12),
                                  // 出库凭证常驻单据详情（2026-09-10）：此前只在出库弹窗内，出完
                                  // 或没有出库权限的人再也看不到凭证。可管口径与服务端
                                  // StockDocumentAttachmentAccessPolicy 一致：红冲冻结；草稿=
                                  // 审核∩出库（出库即审核）；已审=出库权限。弹窗内的同款区保留。
                                  BusinessAttachmentSection(
                                    key: const Key('stock-doc-attachments'),
                                    ownerType: 'STOCK_DOCUMENT',
                                    ownerId: widget.id,
                                    canView: _canView,
                                    canManage:
                                        _d!.status != -1 &&
                                        (_d!.status == 1
                                            ? _canIssue
                                            : (_canApprove && _canIssue)),
                                    title: '出库凭证/照片',
                                    categories: const ['出库凭证', '照片', '其他'],
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                        // body：明细标题（钉住）+ 表格占满内滚（primary 拾取联动控制器）。
                        body: Padding(
                          padding: const EdgeInsets.all(UtenSpacing.s12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // 明细区：统一表格样式（与全站报表/主档同款），不再是卡片 ListTile。
                              Text(
                                '明细 (${_d!.items.length})',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: UtenSpacing.s8),
                              // 2026-09-12 用户口径「备注上面一个总的，下面每行
                              // 一个小的」：总备注在这里，行备注在表格「行备注」列。
                              if (widget.docType == StockDocType.draw &&
                                  _canIssue &&
                                  _issueQty.isNotEmpty) ...[
                                TextField(
                                  key: const Key('draw-issue-remark'),
                                  controller: _issueRemark,
                                  enabled: !_busy,
                                  maxLength: 200,
                                  decoration: const InputDecoration(
                                    labelText: '出库备注(选填)',
                                    hintText: '随本次出库追加到单据备注留痕',
                                    counterText: '',
                                    isDense: true,
                                  ),
                                ),
                                const SizedBox(height: UtenSpacing.s8),
                              ],
                              Expanded(
                                child: widget.docType == StockDocType.draw
                                    ? ProductionDrawDetailTable(
                                        documents: [_d!],
                                        names: names,
                                        permissions: ref.watch(
                                          currentPermissionsProvider,
                                        ),
                                        superAdmin: ref.watch(
                                          isSuperAdminProvider,
                                        ),
                                        primary: true,
                                        issueQtyControllers: _canIssue
                                            ? _issueQty
                                            : null,
                                        lineRemarkControllers: _canIssue
                                            ? _lineRemarks
                                            : null,
                                        issueSaving: _busy,
                                      )
                                    : widget.docType == StockDocType.otherOut ||
                                          widget.docType ==
                                              StockDocType.finishedOut
                                    ? WarehouseStockOutboundDetailTable(
                                        documents: [_d!],
                                        names: names,
                                        primary: true,
                                      )
                                    : MasterDataTableView<StockDocItem>(
                                        primary: true,
                                        bottomContentPadding:
                                            UtenFloatingActionGroup
                                                .scrollClearance,
                                        columns: [
                                          // 2026-09-14 全站列序统一（ADR-081 §4.1）：名称 → 编号 → 颜色。
                                          MasterColumnDef(
                                            key: 'goods',
                                            label: '货品名称',
                                            width: 200,
                                            value: (it) =>
                                                names.goods(it.goodsId),
                                          ),
                                          MasterColumnDef(
                                            key: 'goodsCode',
                                            label: '编号',
                                            width: 110,
                                            value: (it) =>
                                                names
                                                    .goodsInfo(it.goodsId)
                                                    ?.code ??
                                                '—',
                                          ),
                                          MasterColumnDef(
                                            key: 'color',
                                            label: '颜色',
                                            width: 80,
                                            value: (it) =>
                                                names.color(it.colorId),
                                          ),
                                          MasterColumnDef(
                                            key: 'series',
                                            label: '系列',
                                            width: 80,
                                            value: (it) =>
                                                names
                                                    .goodsInfo(it.goodsId)
                                                    ?.series ??
                                                '—',
                                          ),
                                          MasterColumnDef(
                                            key: 'stockPlace',
                                            label: '库位号',
                                            width: 80,
                                            value: (it) =>
                                                it.place?.trim().isNotEmpty ==
                                                    true
                                                ? it.place!
                                                : names
                                                          .goodsInfo(it.goodsId)
                                                          ?.stockPlace ??
                                                      '—',
                                          ),
                                          MasterColumnDef(
                                            key: 'unit',
                                            label: '单位',
                                            width: 64,
                                            value: (it) =>
                                                names.unit(it.unitId),
                                          ),
                                          MasterColumnDef(
                                            key: 'weight',
                                            label: '实际重量',
                                            width: 90,
                                            type: 'number',
                                            value: (it) =>
                                                it.weight?.toStringAsFixed(2) ??
                                                '—',
                                          ),
                                          if (widget.docType ==
                                              StockDocType.check) ...[
                                            MasterColumnDef(
                                              key: 'bookQty',
                                              label: '账面数量',
                                              width: 90,
                                              type: 'number',
                                              value: (it) => _quantityInputText(
                                                it.qty ?? 0,
                                              ),
                                            ),
                                            MasterColumnDef(
                                              key: 'countQty',
                                              label: '实盘数量',
                                              width: 90,
                                              type: 'number',
                                              value: (it) => it.countQty
                                                  ?.toStringAsFixed(1),
                                            ),
                                            MasterColumnDef(
                                              key: 'surplusQty',
                                              label: '盈亏',
                                              width: 90,
                                              type: 'number',
                                              value: (it) => it.surplusQty
                                                  ?.toStringAsFixed(1),
                                            ),
                                          ] else if (widget.docType ==
                                              StockDocType.finishedIn) ...[
                                            MasterColumnDef(
                                              key: 'reportedQty',
                                              label: '待点收上限',
                                              width: 100,
                                              type: 'number',
                                              value: (it) =>
                                                  (it.reportedQty ??
                                                          it.qty ??
                                                          0)
                                                      .toStringAsFixed(2),
                                            ),
                                            MasterColumnDef(
                                              key: 'acceptedQty',
                                              label: _d!.status == 1
                                                  ? '仓库实收'
                                                  : '待点收',
                                              width: 100,
                                              type: 'number',
                                              value: (it) => (it.qty ?? 0)
                                                  .toStringAsFixed(2),
                                            ),
                                          ] else
                                            MasterColumnDef(
                                              key: 'qty',
                                              label: '数量',
                                              width: 90,
                                              type: 'number',
                                              value: (it) => (it.qty ?? 0)
                                                  .toStringAsFixed(2),
                                            ),
                                        ],
                                        items: _d!.items,
                                        facets: const {},
                                        nullCounts: const {},
                                        filters: const {},
                                        onFilterChanged: (_, _) {},
                                        emptyMessage: '暂无明细',
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ),
              ),
            ),
            if (_isOrdinaryOutbound && _busy)
              Positioned.fill(
                child: UtenBusyOverlay(
                  title:
                      (Localizations.of<AppLocalizations>(
                                context,
                                AppLocalizations,
                              ) ??
                              AppLocalizationsZh())
                          .warehouseStockOutboundProcessing,
                ),
              ),
          ],
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
        floatingActionButton: _d == null || _busy ? null : _actions(),
      ),
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

  Widget _actions() {
    final detail = _d!;
    final children = <Widget>[];

    void addAction(Widget action) {
      children.add(action);
    }

    // 「返回列表」只对能进列表页的人渲染（无列表权限的入口 push 进来时按钮
    // 会落到 /access-denied；2026-09-10 审计）；走返回键契约 pop 回来源。
    void addBack() {
      if (!_canOpenList) return;
      addAction(
        UtenButton(
          size: UtenButtonSize.large,
          type: UtenButtonType.secondary,
          onPressed: () => popOrBackTo(
            context,
            defaultPath: RoutePath.stockDocList(widget.docType.code),
          ),
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
            size: UtenButtonSize.large,
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
            size: UtenButtonSize.large,
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
            size: UtenButtonSize.large,
            type: UtenButtonType.danger,
            icon: Icons.logout_rounded,
            onPressed: _canApprove && _canIssue ? _issueFromTable : null,
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
            size: UtenButtonSize.large,
            type: UtenButtonType.danger,
            icon:
                detail.productionLinked &&
                    widget.docType == StockDocType.finishedIn
                ? Icons.inventory_rounded
                : Icons.check_circle_outline,
            onPressed:
                detail.productionLinked &&
                    widget.docType == StockDocType.finishedIn
                ? _confirmFinishedInboundDialog
                : detail.productionMaterialReturn &&
                      widget.docType == StockDocType.wdraw
                ? (_confirmingMaterialReturn ? null : _confirmMaterialReturn)
                : _isOrdinaryOutbound
                ? (_outboundReviewToken == null || _confirmingOutbound
                      ? null
                      : _confirmOrdinaryOutbound)
                : () => _act(
                    widget.docType == StockDocType.wdraw
                        ? '请逐行核对退料实物、单位和数量。确认本单全部实物已收齐后，系统才增加库存并结清本单退料。数量不符时请返回，由车间撤回后重新提交，确认实收？'
                        : '审核将联动库存，确认？',
                    () => ref
                        .read(stockDocRepositoryProvider(widget.docType))
                        .approve(widget.id),
                    widget.docType == StockDocType.wdraw
                        ? '退料实收已确认，库存与车间台账已更新'
                        : '已审核',
                    reviewerResponsibility: true,
                    confirmLabel: widget.docType == StockDocType.wdraw
                        ? '确认收料'
                        : null,
                  ),
            child: Text(
              detail.productionLinked &&
                      widget.docType == StockDocType.finishedIn
                  ? '确认实收并入库'
                  : _isOrdinaryOutbound
                  ? (Localizations.of<AppLocalizations>(
                              context,
                              AppLocalizations,
                            ) ??
                            AppLocalizationsZh())
                        .warehouseStockOutboundConfirmSingle
                  : widget.docType == StockDocType.wdraw
                  ? (_materialReturnKey == null ? '确认实收并入库' : '重试本次收料')
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
              size: UtenButtonSize.large,
              type: UtenButtonType.danger,
              icon: Icons.logout_rounded,
              onPressed: _issueFromTable,
              child: const Text('出库'),
            ),
          );
        }
        if (anyIssued && _canReverseIssue) {
          addAction(
            UtenButton(
              size: UtenButtonSize.large,
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
              widget.docType == StockDocType.finishedIn ||
              (widget.docType == StockDocType.wdraw &&
                  detail.productionMaterialReturn))) {
        final productionFinishedInbound =
            detail.productionLinked &&
            widget.docType == StockDocType.finishedIn;
        final materialReturn =
            widget.docType == StockDocType.wdraw &&
            detail.productionMaterialReturn;
        addAction(
          UtenButton(
            size: UtenButtonSize.large,
            type: UtenButtonType.danger,
            icon: Icons.undo_outlined,
            onPressed: () => _act(
              productionFinishedInbound
                  ? '红冲将反向库存与入库累计，并按原实收量重建待点收草稿，确认？'
                  : materialReturn
                  ? '撤回后按原凭据恢复车间余料与库存。若已有后续领用，须先处理对应后续业务。确认撤回本次收仓？'
                  : '红冲将反向冲销库存，确认？',
              () {
                final repository = ref.read(
                  stockDocRepositoryProvider(widget.docType),
                );
                return productionFinishedInbound
                    ? repository.reverseFinishedInbound(widget.id)
                    : repository.reverse(widget.id);
              },
              productionFinishedInbound
                  ? '已红冲并重建待点收任务'
                  : materialReturn
                  ? '已撤回收仓'
                  : '已红冲',
              reviewerResponsibility: materialReturn,
              confirmLabel: materialReturn ? '撤回收仓' : null,
              confirmTitle: materialReturn ? '核对并撤回收仓' : null,
            ),
            child: Text(materialReturn ? '撤回收仓' : '红冲'),
          ),
        );
      }
      if (children.isEmpty) addBack();
    } else {
      addBack();
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return UtenFloatingActionGroup(children: children);
  }
}

/// 出库/取消出库弹窗的输入结果：行 id → 本次数量文本；reason=取消原因 / 出库备注。
typedef _IssueDialogInput = ({Map<String, String> quantities, String reason});

/// DRAW 出库/取消出库弹窗：控制器归弹窗所有，随路由销毁。
class _IssueDialog extends StatefulWidget {
  const _IssueDialog({
    required this.reverse,
    required this.lines,
    required this.warehouseLabel,
    required this.names,
    required this.docId,
    required this.canView,
    required this.canIssue,
  });

  final bool reverse;
  final List<StockDocItem> lines;
  final String warehouseLabel;
  final MasterNameService names;
  final String docId;
  final bool canView;
  final bool canIssue;

  @override
  State<_IssueDialog> createState() => _IssueDialogState();
}

class _IssueDialogState extends State<_IssueDialog> {
  late final Map<String, TextEditingController> _quantities = {
    for (final it in widget.lines)
      it.id!: TextEditingController(
        text: _StockDocDetailPageState._quantityInputText(
          widget.reverse ? (it.issuedQty ?? 0) : it.remainingQty,
        ),
      ),
  };
  final TextEditingController _reason = TextEditingController();

  @override
  void dispose() {
    for (final controller in _quantities.values) {
      controller.dispose();
    }
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reverse = widget.reverse;
    return AlertDialog(
      title: Text(reverse ? '取消出库' : '出库'),
      content: SizedBox(
        width: 420,
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(widget.warehouseLabel),
            ),
            for (final it in widget.lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: Text(
                        '${widget.names.goods(it.goodsId)}\n'
                        '${reverse ? '可取消 ${_StockDocDetailPageState._quantityInputText(it.issuedQty ?? 0)}' : '本次最多 ${_StockDocDetailPageState._quantityInputText(it.remainingQty)}'}',
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(fontWeight: FontWeight.w400),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: _quantities[it.id!],
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
            const SizedBox(height: UtenSpacing.s8),
            TextField(
              controller: _reason,
              // 正向出库备注服务端单条上限 200（多轮用「；」连接、总长 500），
              // 输入框与之同值，不再让用户填 1000 字后被静默截断。
              maxLength: reverse ? 1000 : 200,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(
                labelText: reverse ? '取消原因(必填)' : '备注(选填)',
                hintText: reverse ? null : '随出库追加到单据备注留痕',
                border: const OutlineInputBorder(),
              ),
            ),
            if (!reverse) ...[
              const SizedBox(height: UtenSpacing.s8),
              // 出库凭证（2026-09-09）：与单据同生命周期，品质/仓库均可回看；
              // 2026-09-10 起详情页也常驻同款区。
              BusinessAttachmentSection(
                ownerType: 'STOCK_DOCUMENT',
                ownerId: widget.docId,
                canView: widget.canView,
                canManage: widget.canIssue,
                title: '出库凭证/照片',
                categories: const ['出库凭证', '照片', '其他'],
              ),
            ],
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop<_IssueDialogInput>(context, (
            quantities: {
              for (final entry in _quantities.entries)
                entry.key: entry.value.text.trim(),
            },
            reason: _reason.text.trim(),
          )),
          child: Text(reverse ? '确认取消出库' : '确认出库'),
        ),
      ],
    );
  }
}
