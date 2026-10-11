// 仓库单据详情页：主表头卡 + 只读明细子表 + 状态门控操作（审核/红冲/编辑/删除）。
//
// 2026-09-11 折叠头+表内滚改版（对齐采购/货品资料页）：整页 ListView 改
// UtenCollapsingHeaderScrollView——上滑先折叠头部（提示条/生产链横幅/表头卡/出库凭证），
// 之后滚明细表内部（2026-09-25 起「明细 (N)」计数标题随全站退役）。
//
// 重量 (ADR-135): 领料出库「本次重量」紧跟「本次出库」, 「已出库重量」紧跟「已出库」,
// 取消出库弹窗只读显示按比例退回的重量; 生产退料收仓在明细表逐行录实称重量 (随收仓确认
// 一起提交, 登记数量只读); 其它单据明细的重量按显示单位排在数量之后。重量从不阻断过账。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_app_bar_action_button.dart';
import '../../../components/inputs/uten_autofill_text_controller.dart';
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
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../../shared/attachments/business_attachment_section.dart';
import '../../../shared/auth/document_permission_set.dart';
import '../../../shared/formatters/quantity_display.dart';
import '../../../shared/auth/document_scope_capability.dart';
import '../../../shared/auth/document_scope_write_notice.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/measurement/weight_params.dart';
import '../../../shared/measurement/widgets/weight_params_load_notice.dart';
import '../../../shared/measurement/weight_predictor.dart';
import '../../../shared/measurement/weight_prefs.dart';
import '../../../shared/measurement/weight_unit.dart';
import '../../../shared/measurement/widgets/weight_grid_column.dart';
import '../../../shared/measurement/widgets/weight_text.dart';
import '../../../shared/measurement/widgets/weight_totals.dart';
import '../../../shared/widgets/source_doc_link.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../models/outbound_weight_entry.dart';
import '../models/stock_doc.dart';
import '../widgets/outbound_weight_columns.dart';
import '../widgets/production_draw_detail_table.dart';
import '../widgets/production_material_return_receive_dialog.dart';
import '../widgets/warehouse_stock_outbound_detail_table.dart';
import '../../production/providers/production_execution_refresh.dart';
import '../repositories/stock_doc_repository.dart';
import '../../../shared/auth/session_snapshot_provider.dart';

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

  /// 本次收仓提交的逐行实称重量 (与 [_materialReturnKey] 同生同灭: 回执不明重试时原样重发)。
  List<Map<String, dynamic>>? _materialReturnLines;
  bool _confirmingMaterialReturn = false;

  // 2026-09-12 用户口径「数量在表格里改，出库只弹总结」：DRAW 待出库行的
  // 「本次出库/行备注」输入由页面持有（_load 后按最新明细重建，随路由销毁）；
  // 总备注在表格上方单独一个输入框。
  final Map<String, UtenAutofillTextController> _issueQty = {};
  final Map<String, TextEditingController> _lineRemarks = {};

  /// 领料「本次重量」(键 = item.id), 与 [_issueQty] 同生同灭。
  final Map<String, OutboundWeightEntry> _issueWeights = {};

  /// 生产退料收仓的逐行实称重量 (键 = item.id); 只在草稿退料单且可审核时有。
  final Map<String, OutboundWeightEntry> _returnWeights = {};

  /// 本次 build 盯住的页内单重参数缓存 (有要称重的行时才建)。
  WeightParamsCache? _weightCache;
  final TextEditingController _issueRemark = TextEditingController();
  bool get _isOrdinaryOutbound =>
      widget.docType == StockDocType.otherOut ||
      widget.docType == StockDocType.finishedOut;

  /// 行级仓库类型（V787，与编辑页同口径）：仓库在明细行上逐行展示；
  /// 调拨/盘点仍看表头。
  bool get _usesLineWarehouse => switch (widget.docType) {
    StockDocType.otherIn ||
    StockDocType.otherOut ||
    StockDocType.finishedIn ||
    StockDocType.finishedOut ||
    StockDocType.draw => true,
    _ => false,
  };

  Iterable<OutboundWeightEntry> get _weightEntries => [
    ..._issueWeights.values,
    ..._returnWeights.values,
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _disposeIssueInputs();
    _disposeReturnWeights();
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
    for (final entry in _issueWeights.values) {
      entry.dispose();
    }
    _issueWeights.clear();
  }

  void _disposeReturnWeights() {
    for (final entry in _returnWeights.values) {
      entry.dispose();
    }
    _returnWeights.clear();
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
    setState(() {
      _loading = true;
      _error = null;
      _outboundReviewToken = null;
    });
    final names = ref.read(masterNameServiceProvider);
    // 字典与详情并行，首屏只等详情(ADR-108)；名称在首屏之后补齐再重绘一次。
    final dictionaries = names.ensureLoaded();
    try {
      final repo = ref.read(stockDocRepositoryProvider(widget.docType));
      final review = _isOrdinaryOutbound ? await repo.review(widget.id) : null;
      final d = review?.document ?? await repo.detail(widget.id);
      if (!mounted) return;
      unawaited(_resolveDisplayNames(names, d, dictionaries));
      setState(() {
        _d = d;
        _outboundReviewToken = review?.reviewToken;
        if (d.status != 0) {
          _materialReturnWarehouseId = null;
          _materialReturnKey = null;
          _materialReturnLines = null;
        }
      });
      _rebuildIssueInputs();
      _rebuildReturnWeights();
      // 缓存在 build 里按需盯住: 下一帧再按行批量取单重参数。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(ensureOutboundWeightParams(_weightCache, _weightEntries));
        }
      });
    } catch (e) {
      if (mounted) {
        context.appError('加载详情失败');
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 首屏之后并行补齐字典与明细货品名/编号/库位号(库存单据明细服务端暂未随单下发货品
  /// 展示字段，由一次批量货品查询补齐)，完成后重绘一次。
  Future<void> _resolveDisplayNames(
    MasterNameService names,
    StockDocDetail d,
    Future<void> dictionaries,
  ) async {
    try {
      await Future.wait([
        dictionaries,
        names.loadGoodsDetails(
          d.items.map((e) => e.goodsId).whereType<String>(),
        ),
      ]);
    } catch (_) {
      // 名称补齐失败只影响占位符，不影响正文。
    }
    if (mounted && identical(_d, d)) setState(() {});
  }

  Future<void> _confirmOrdinaryOutbound() async {
    if (_busy ||
        _loading ||
        _confirmingOutbound ||
        !_canApprove ||
        _outboundReviewToken == null) {
      return;
    }
    final l10n = _detailL10n;
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
    // 重量格里看不懂的输入先拦下 (重量本身选填, 不称也能收仓)。
    final names = ref.read(masterNameServiceProvider);
    for (final item in detail.items) {
      if (_returnWeights[item.id]?.weight.hasError == true) {
        context.appError(
          '${names.goods(item.goodsId)}：实称重量看不懂，请改成如 12.5 或 850g',
        );
        return;
      }
    }
    setState(() => _confirmingMaterialReturn = true);
    try {
      final warehouseId =
          _materialReturnWarehouseId ??
          await showProductionMaterialReturnReceiveDialog(
            context,
            hierarchy: names.warehouseHierarchy,
            mainWarehouseId: detail.materialReturnMainWarehouseId,
            initialWarehouseId: detail.warehouseId,
            weightSummary: _returnWeights.isEmpty
                ? null
                : _returnWeightSummary(detail),
          );
      if (warehouseId == null || !mounted) return;
      setState(() {
        _materialReturnWarehouseId = warehouseId;
        // 本次提交的逐行重量随幂等键一起定格: 回执不明重试时原样重发。
        _materialReturnLines ??= [
          for (final item in detail.items)
            if (_returnWeights[item.id]?.kg case final kg?)
              {'itemId': item.id, 'weightKg': kg},
        ];
        _materialReturnKey ??= businessIdempotencyKey(
          'material-return-confirm',
          '${widget.id}|$warehouseId|${_materialReturnLines!.map((line) => '${line['itemId']}=${weightKeyPart(line['weightKg'] as double?)}').join(',')}',
        );
        _busy = true;
      });
      await ref
          .read(stockDocRepositoryProvider(widget.docType))
          .confirmMaterialReturn(
            widget.id,
            warehouseId: warehouseId,
            idempotencyKey: _materialReturnKey!,
            lines: _materialReturnLines!,
          );
      if (!mounted) return;
      setState(() {
        _materialReturnWarehouseId = null;
        _materialReturnKey = null;
        _materialReturnLines = null;
      });
      context.appSuccess('余料已收进实际仓库，库存与车间台账已更新');
      bumpListRefresh(ref, widget.docType.refreshKey);
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
          _materialReturnLines = null;
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
    final unit = ref.read(warehouseWeightUnitsPrefsProvider).entry;
    for (final item in detail.items) {
      if (item.remainingQty <= 0 || item.id == null) continue;
      final qty = UtenAutofillTextController(
        text: _quantityInputText(item.remainingQty),
        autofilled: false,
      );
      _issueQty[item.id!] = qty;
      _issueWeights[item.id!] = drawIssueWeightEntry(
        item,
        qty,
        unit: unit,
        warehouseId: detail.warehouseId,
      );
      _lineRemarks[item.id!] = TextEditingController();
    }
  }

  /// 生产退料收仓: 草稿退料单 + 有审核权时逐行录实称重量 (回执不明重试期间保留原值)。
  void _rebuildReturnWeights() {
    final detail = _d;
    final capture =
        widget.docType == StockDocType.wdraw &&
        detail != null &&
        detail.productionMaterialReturn &&
        detail.status == 0 &&
        _canApprove;
    if (!capture) {
      _disposeReturnWeights();
      return;
    }
    if (_materialReturnKey != null) return;
    _disposeReturnWeights();
    final unit = ref.read(warehouseWeightUnitsPrefsProvider).entry;
    for (final item in detail.items) {
      final id = item.id;
      if (id == null) continue;
      _returnWeights[id] = OutboundWeightEntry(
        goodsId: item.goodsId,
        colorId: item.colorId,
        warehouseId: detail.warehouseId,
        qtyOf: () => item.qty,
        unitRate: item.unitRate ?? 1,
        unit: unit,
      );
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
      final weight = _issueWeights[item.id!];
      if (weight?.weight.hasError == true) {
        context.appError(
          '${names.goods(item.goodsId)}：本次重量看不懂，请改成如 12.5 或 850g',
        );
        return;
      }
      final qty = double.tryParse(controller.text.trim()) ?? 0;
      if (qty <= 0) continue; // 明确填 0 的行跳过（分批出库）
      body.add({
        'itemId': item.id,
        'qty': qty,
        // 本次实称 (千克 4 位, ADR-135 §3.6): 只落出库流水, 不写回领料明细。
        'weightKg': ?weight?.kg,
        if (weight?.qtyFromWeight == true) 'qtyFromWeight': true,
      });
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
    // 称重只提醒不拦截：总结里列出本次实称合计与偏差行(「比应发多约 35 个 (+1.5%)」)。
    final issuedWeights = [
      for (final line in body) _issueWeights[line['itemId']],
    ].whereType<OutboundWeightEntry>().toList();
    final weightSummary = outboundWeightTotals(
      issuedWeights,
      params: _weightCache,
    );
    final deviations = <String>[
      for (final line in body)
        if (_issueWeights[line['itemId']] case final entry?)
          if (_deviationText(entry) case final text?)
            '${names.goods(entry.goodsId)}：$text',
    ];
    final confirmed = await UtenDialog.show(
      context,
      title: '确认出库（$lineCount 行）',
      confirmLabel: '确认出库',
      content: _issueSummaryPoints(
        totalsText,
        remark,
        weightText: weightSummary.weighedRows == 0
            ? null
            : weightTotalEntry(weightSummary).value,
        deviations: deviations,
      ),
    );
    if (confirmed != true || !mounted) return;
    await _executeIssue(body, reverse: false, remark: remark);
  }

  /// 一行的称重偏差短句 (WARN/ALERT 才有): 「比应发多约35个 (+1.5%)」。
  String? _deviationText(OutboundWeightEntry entry) {
    if (entry.kg == null) return null;
    final check = entry.check(_weightCache);
    if (check == null || check.level == WeightAlertLevel.none) return null;
    final unitId = ref
        .read(masterNameServiceProvider)
        .goodsInfo(entry.goodsId)
        ?.unitId;
    return weightCheckShortText(
      check,
      mode: WeightCaptureMode.outbound,
      unitName: unitId == null
          ? null
          : ref.read(masterNameServiceProvider).unit(unitId),
    );
  }

  Widget _issueSummaryPoints(
    String totalsText,
    String remark, {
    String? weightText,
    List<String> deviations = const [],
  }) {
    final theme = Theme.of(context);
    final points = <String>[
      '本次出库 $totalsText；提交后按行核销待出库量并写入库存。',
      if (weightText != null) '本次实称 $weightText (只记入出库流水，不改领料明细)。',
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
        if (deviations.isNotEmpty)
          Padding(
            key: const Key('draw-issue-weight-deviations'),
            padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
            child: Text(
              '· 称重偏差 (请复核，不影响出库)：\n${deviations.join('\n')}',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: weightAlertColor(theme, WeightAlertLevel.warn),
              ),
            ),
          ),
      ],
    );
  }

  /// 收仓弹窗里的重量说明: 「随收仓提交实称 12.5 kg (未称 1 行)」, 有偏差再提醒复核。
  String _returnWeightSummary(StockDocDetail detail) {
    final entries = [
      for (final item in detail.items) _returnWeights[item.id],
    ].whereType<OutboundWeightEntry>();
    final summary = outboundWeightTotals(
      entries,
      params: _weightCache,
      mode: WeightCaptureMode.inbound,
    );
    if (summary.weighedRows == 0) {
      return '本次没有录实称重量 (选填，不称也能收仓)。';
    }
    final deviation = summary.deviationRows > 0
        ? '；称重偏差 ${summary.deviationRows} 行，请复核实物'
        : '';
    return '随收仓提交实称 ${weightTotalEntry(summary).value}$deviation。';
  }

  /// 取消出库对话框（按行输入可退量，必填原因）；正向出库走 _issueFromTable。
  /// 退回的重量由服务端按原出库流水镜像 (全退=原重量, 部分退=按比例), 弹窗只读显示。
  Future<void> _cancelIssueDialog() async {
    if (_busy || _d == null) return;
    final names = ref.read(masterNameServiceProvider);
    final lines = _d!.items.where((it) => (it.issuedQty ?? 0) > 0).toList();
    // 输入控制器由弹窗自己持有（随路由销毁）：此前在 showDialog 返回后立刻
    // dispose，退场动画期间的重建会再次订阅已销毁的控制器（备注框带字数计数
    // 器时必现）。
    final input = await showDialog<_CancelIssueInput>(
      context: context,
      builder: (ctx) => _CancelIssueDialog(
        lines: lines,
        warehouseLabel: '退回原仓：${names.warehouse(_d!.warehouseId)}',
        names: names,
      ),
    );
    if (input == null || !mounted) return;
    // 取消出库必填原因(审计)。
    final cancellationReason = input.reason;
    if (cancellationReason.length < 2) {
      context.appError('取消出库必须填写至少 2 个字的原因');
      return;
    }

    // 组装请求行(>0 才提交；后端会再校验上限)；取消出库不带重量(服务端按原流水镜像)。
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
      reverse: true,
      cancellationReason: cancellationReason,
    );
  }

  /// 出库执行段(表格流与取消出库弹窗共用)：幂等键按行issued/delta/重量指纹派生，
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
          // 服务端出库哈希含重量: 改了重量就是另一次请求, 键必须跟着变。
          final weight =
              '${weightKeyPart(line['weightKg'] as double?)}|'
              '${line['qtyFromWeight'] == true ? 1 : 0}';
          return '$itemId|issued=${current ?? 0}|delta=${line['qty']}|w=$weight';
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
      await _load();
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message);
    } catch (_) {
      if (mounted) context.appError(reverse ? '取消出库失败' : '出库失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// FQC PASS 只形成“待点收上限”；仓库按实物批(ADR-148)点收后，实收量才成为库存/iqty 权威。
  /// 一批 = 同一报工、同一产出批次的需求份 / 计划公共 / 实际超产，只填一个实收数；
  /// 服务端把实收先分给需求份，少收先扣实际超产。
  Future<void> _confirmFinishedInboundDialog() async {
    if (_busy || _d == null || _d!.items.isEmpty) return;
    final detail = _d!;
    final lots = detail.finishedLots;
    if (lots.isEmpty) {
      context.appWarning('本单没有可点收的实物批，请刷新后重试');
      return;
    }
    final names = ref.read(masterNameServiceProvider);
    final controllers = <String, TextEditingController>{
      for (final lot in lots)
        lot.lotId: TextEditingController(text: _quantityInputText(lot.qty)),
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
                    '一行是一批实物(需求份 / 计划公共 / 实际超产合在一起)，按实物点一次；'
                    '实收先满足需求份，少收先扣实际超产，少收部分会自动保留为新的待点收余量单。',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                  for (final lot in lots)
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
                                '${names.goods(lot.goodsId)}\n'
                                '待点收上限 ${_quantityInputText(lot.qty)} '
                                '${names.unit(lot.unitId)}'
                                '${lot.splitText == null ? '' : '\n其中 ${lot.splitText}'}'
                                '${lot.shortageHint == null ? '' : '\n${lot.shortageHint}'}'
                                // 产成品重量在到货登记时称 (按放行量分摊), 这里只读。
                                '${lot.weight == null ? '' : '\n登记重量 ${formatWeightValue(lot.weight)}'}',
                              ),
                            ),
                          ),
                          const SizedBox(width: UtenSpacing.s8),
                          Expanded(
                            flex: 2,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                TextField(
                                  key: Key('finished-in-lot-${lot.lotId}'),
                                  controller: controllers[lot.lotId],
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
                                if (lot.weight != null)
                                  _FinishedInboundWeightHint(
                                    weight: lot.weight!,
                                    baseQty: lot.qty,
                                    accepted: controllers[lot.lotId]!,
                                  ),
                              ],
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
                          info: '任一批实收少于申报量时必填，例如：本次只交接 80 件，余量待下批。',
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
                for (final lot in lots) {
                  final proposed = lot.qty;
                  final accepted = double.tryParse(
                    controllers[lot.lotId]!.text.trim(),
                  );
                  if (accepted == null || accepted < 0) {
                    setDialogState(() => dialogError = '每批必须填写不小于 0 的实收数量');
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
    final lotLines = <Map<String, dynamic>>[
      for (final lot in lots)
        {
          'lotId': lot.lotId,
          'acceptedQty': double.parse(controllers[lot.lotId]!.text.trim()),
        },
    ];
    final canonical = lotLines
        .map((line) => '${line['lotId']}|${line['acceptedQty']}')
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
            lotLines,
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
            style: FilledButton.styleFrom(
              backgroundColor: UtenColors.error,
            ), // 与全站删除确认对话框同款语义色。
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

  /// 详情页文案；没挂本地化的轻量宿主(测试)回落中文。
  AppLocalizations get _detailL10n =>
      Localizations.of<AppLocalizations>(context, AppLocalizations) ??
      AppLocalizationsZh();

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
    final weightUnits = ref.watch(warehouseWeightUnitsPrefsProvider);
    // 有要称重且带货品的行时才盯住页内单重参数缓存 (离开页面随之释放)。
    _weightCache = _weightEntries.any((entry) => entry.paramsLine != null)
        ? ref.watch(weightParamsCacheProvider)
        : null;
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
                                  onRetry: () => ref
                                      .read(sessionSnapshotProvider.notifier)
                                      .refresh(),
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
                                        // V787 行级仓库：这几类的实际仓在各明细行上，
                                        // 表头仓只是首行仓的回显，不再单列展示。
                                        if (widget.docType !=
                                                StockDocType.draw &&
                                            !_usesLineWarehouse)
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
                                        // ADR-146 不良品专门通道: 调拨类型与原因。
                                        if (widget.docType ==
                                                StockDocType.transfer &&
                                            _d!.transferKind != null &&
                                            _d!.transferKind != 'NORMAL') ...[
                                          _kv(
                                            _detailL10n.stockTransferKindLabel,
                                            _d!.transferKind == 'TO_DEFECTIVE'
                                                ? _detailL10n
                                                      .defectiveMoveToDefective
                                                : _detailL10n
                                                      .defectiveMoveRelease,
                                            theme,
                                          ),
                                          _kv(
                                            _detailL10n.defectiveMoveReason,
                                            _d!.defectReason,
                                            theme,
                                          ),
                                        ],
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
                        // body：表格占满内滚（primary 拾取联动控制器）。
                        body: Padding(
                          padding: const EdgeInsets.all(UtenSpacing.s12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // 明细区：统一表格样式（与全站报表/主档同款），不再是卡片 ListTile。
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
                              WeightParamsLoadNotice(cache: _weightCache),
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
                                        issueWeights: _canIssue
                                            ? _issueWeights
                                            : null,
                                        weightParams: _weightCache,
                                        weightEntryUnit: weightUnits.entry,
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
                                    : _itemTable(names, weightUnits.entry),
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

  /// 非领料/非普通出库单据的明细表: 数量之后显示重量 (按显示单位, 估算「≈」, 没称「未称」);
  /// 盘点单另列账面重量/实盘重量; 生产退料收仓待确认时逐行录实称重量并核对登记数量。
  Widget _itemTable(MasterNameService names, WeightUnit entryUnit) {
    final detail = _d!;
    final capturing = _returnWeights.isNotEmpty;
    final editable = !_busy && _materialReturnKey == null;
    String? baseUnitName(String? goodsId) {
      final unitId = names.goodsInfo(goodsId)?.unitId;
      return unitId == null ? null : names.unit(unitId);
    }

    final byEntry = <OutboundWeightEntry, StockDocItem>{
      for (final item in detail.items) ?_returnWeights[item.id]: item,
    };
    // 2026-10-10「数量 + 单位」内联口径：单位列删除，单位名直接拼在数量后；
    // names.unit 未加载/未知返回「—」，拼装前滤掉，避免出现「5 —」。
    String? unitOf(StockDocItem it) {
      final name = names.unit(it.unitId);
      return name == '—' ? null : name;
    }

    MasterColumnDef<StockDocItem> weightDisplay(
      String key,
      String label,
      double? Function(StockDocItem item) kgOf, {
      bool Function(StockDocItem item)? estimatedOf,
    }) => MasterColumnDef(
      key: key,
      label: label,
      width: 110,
      type: 'number',
      value: (it) => formatWeightValue(
        kgOf(it),
        estimated: estimatedOf?.call(it) ?? false,
      ),
      cellBuilder: (context, it) =>
          WeightText(kg: kgOf(it), estimated: estimatedOf?.call(it) ?? false),
    );

    return MasterDataTableView<StockDocItem>(
      tableKey: 'warehouse.${widget.docType.name}.items',
      primary: true,
      enableTextSelection: !capturing,
      bottomContentPadding: UtenFloatingActionGroup.scrollClearance,
      toolbarActions: capturing ? const [WeightEntryUnitButton()] : null,
      summaryBar: capturing
          ? OutboundWeightSummaryBar(
              entries: byEntry.keys.toList(growable: false),
              params: _weightCache,
              mode: WeightCaptureMode.inbound,
            )
          : null,
      columns: [
        // 2026-09-14 全站列序统一(ADR-081 §4.1)：名称 → 编号 → 颜色。
        MasterColumnDef(
          key: 'goods',
          label: '货品名称',
          width: 200,
          value: (it) => names.goods(it.goodsId),
        ),
        MasterColumnDef(
          key: 'goodsCode',
          label: '编号',
          width: 110,
          value: (it) => names.goodsInfo(it.goodsId)?.code ?? '—',
        ),
        MasterColumnDef(
          key: 'color',
          label: '颜色',
          width: 80,
          value: (it) => names.color(it.colorId),
        ),
        MasterColumnDef(
          key: 'series',
          label: '系列',
          width: 80,
          value: (it) => names.goodsInfo(it.goodsId)?.series ?? '—',
        ),
        // V787 行级仓库：明细行各自落的仓（跨仓单据逐行可见）；空 = 表头仓。
        if (_usesLineWarehouse)
          MasterColumnDef(
            key: 'warehouse',
            label: '仓库',
            width: 140,
            value: (it) => names.warehouse(it.warehouseId ?? _d!.warehouseId),
          ),
        MasterColumnDef(
          key: 'stockPlace',
          label: '库位号',
          width: 80,
          value: (it) => it.place?.trim().isNotEmpty == true
              ? it.place!
              : names.goodsInfo(it.goodsId)?.stockPlace ?? '—',
        ),
        if (widget.docType == StockDocType.check) ...[
          MasterColumnDef(
            key: 'bookQty',
            label: '账面数量',
            width: 125,
            type: 'number',
            value: (it) => formatQtyWithUnit(it.qty ?? 0, unitOf(it)),
          ),
          MasterColumnDef(
            key: 'countQty',
            label: '实盘数量',
            width: 125,
            type: 'number',
            value: (it) =>
                formatQtyWithUnit(it.countQty, unitOf(it), maxDecimals: 1),
          ),
          MasterColumnDef(
            key: 'surplusQty',
            label: '盈亏',
            width: 125,
            type: 'number',
            value: (it) =>
                formatQtyWithUnit(it.surplusQty, unitOf(it), maxDecimals: 1),
          ),
          // 盘点重量 (ADR-135 §3.4): 账面重量 = 保存时的库存重量快照, 实盘重量选填。
          weightDisplay('bookWeight', '账面重量', (it) => it.bookWeight),
          weightDisplay('countWeight', '实盘重量', (it) => it.countWeight),
        ] else if (widget.docType == StockDocType.finishedIn) ...[
          MasterColumnDef(
            key: 'reportedQty',
            label: '待点收上限',
            width: 135,
            type: 'number',
            value: (it) => formatQtyWithUnit(
              it.reportedQty ?? it.qty ?? 0,
              unitOf(it),
              maxDecimals: 2,
            ),
          ),
          MasterColumnDef(
            key: 'acceptedQty',
            label: detail.status == 1 ? '仓库实收' : '待点收',
            width: 135,
            type: 'number',
            value: (it) =>
                formatQtyWithUnit(it.qty ?? 0, unitOf(it), maxDecimals: 2),
          ),
          weightDisplay('weight', '重量', (it) => it.weight),
        ] else ...[
          MasterColumnDef(
            key: 'qty',
            label: '数量',
            width: 125,
            type: 'number',
            value: (it) =>
                formatQtyWithUnit(it.qty ?? 0, unitOf(it), maxDecimals: 2),
          ),
          if (capturing) ...[
            // 生产退料收仓 (ADR-135 §3.9): 登记数量只读, 逐行录实称重量, 随收仓确认提交。
            outboundWeightColumn<StockDocItem>(
              entryOf: (it) => _returnWeights[it.id],
              entryUnit: entryUnit,
              params: _weightCache,
              mode: WeightCaptureMode.inbound,
              enabledOf: (_) => editable,
              baseUnitNameOf: (entry) => baseUnitName(entry.goodsId),
              onWeighCount: (context, entry) {
                final item = byEntry[entry];
                return weighOutboundEntry(
                  context,
                  entry: entry,
                  goodsTitle: item == null
                      ? ''
                      : [
                          names.goods(item.goodsId),
                          names.goodsInfo(item.goodsId)?.code ?? '',
                          item.colorId == null ? '' : names.color(item.colorId),
                        ].where((part) => part.trim().isNotEmpty).join(' '),
                  cache: _weightCache,
                  baseUnitName: baseUnitName(entry.goodsId),
                  lineUnitName: item == null ? null : names.unit(item.unitId),
                  sampleRemark: detail.billNo,
                );
              },
            ),
            outboundWeightCheckColumn<StockDocItem>(
              entryOf: (it) => _returnWeights[it.id],
              params: _weightCache,
              mode: WeightCaptureMode.inbound,
              unitNameOf: (entry) => baseUnitName(entry.goodsId),
              textOf: (check, entry) {
                final unit = baseUnitName(entry.goodsId);
                String qty(double value) => formatWeighQtyWithUnit(
                  value,
                  unitName: unit,
                  integer: check.integerQty,
                );
                return '登记退 ${qty(check.qtyBase)}, 称重约 ${qty(check.count.estimatedQty)}';
              },
            ),
          ] else if (widget.docType == StockDocType.wdraw)
            // 生产退料: 收料重量只落收仓出入库流水 (不写回明细), 显示服务端按流水累计的实收重量
            // (issuedWeightKg, 实收减红冲); 还没收仓时没有流水, 显示「未称」。
            weightDisplay(
              'receivedWeight',
              '实收重量',
              (it) => it.issuedWeightKg,
              estimatedOf: (it) => it.issuedWeightEstimated,
            )
          else
            weightDisplay('weight', '重量', (it) => it.weight),
        ],
      ],
      items: detail.items,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      emptyMessage: '暂无明细',
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
              onPressed: _cancelIssueDialog,
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
                  ? '红冲后，系统会把这次入库的库存和累计数量减回去，并按原来实际收到的数量重新生成待点收草稿。确认红冲？'
                  : materialReturn
                  ? '撤回后，系统会按原来那笔收仓记录恢复车间余料和库存。若这批料已被后面的工单领用，要先处理完那些领用。确认撤回本次收仓？'
                  : '红冲会把这次入库的库存减回去，确认？',
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

/// 取消出库弹窗的输入结果：行 id → 本次取消数量文本；reason = 取消原因。
typedef _CancelIssueInput = ({Map<String, String> quantities, String reason});

/// DRAW 取消出库弹窗：控制器归弹窗所有，随路由销毁。
class _CancelIssueDialog extends StatefulWidget {
  const _CancelIssueDialog({
    required this.lines,
    required this.warehouseLabel,
    required this.names,
  });

  final List<StockDocItem> lines;
  final String warehouseLabel;
  final MasterNameService names;

  @override
  State<_CancelIssueDialog> createState() => _CancelIssueDialogState();
}

class _CancelIssueDialogState extends State<_CancelIssueDialog> {
  late final Map<String, TextEditingController> _quantities = {
    for (final it in widget.lines)
      it.id!: TextEditingController(
        text: _StockDocDetailPageState._quantityInputText(it.issuedQty ?? 0),
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
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('取消出库'),
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
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: Text(
                        '${widget.names.goods(it.goodsId)}\n'
                        '可取消 ${_StockDocDetailPageState._quantityInputText(it.issuedQty ?? 0)}',
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextField(
                            controller: _quantities[it.id!],
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                          _ReturnedWeightHint(
                            item: it,
                            quantity: _quantities[it.id!]!,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: UtenSpacing.s8),
            TextField(
              controller: _reason,
              maxLength: 1000,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: '取消原因(必填)',
                border: OutlineInputBorder(),
              ),
            ),
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
          onPressed: () => Navigator.pop<_CancelIssueInput>(context, (
            quantities: {
              for (final entry in _quantities.entries)
                entry.key: entry.value.text.trim(),
            },
            reason: _reason.text.trim(),
          )),
          child: const Text('确认取消出库'),
        ),
      ],
    );
  }
}

/// 取消出库一行的退回重量 (只读): 已出库重量 x 取消数量 / 已出库数量; 全退即原重量。
/// 服务端按原出库流水镜像, 这里只是提示, 不随请求发出。
class _ReturnedWeightHint extends StatelessWidget {
  const _ReturnedWeightHint({required this.item, required this.quantity});

  final StockDocItem item;
  final TextEditingController quantity;

  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<TextEditingValue>(
    valueListenable: quantity,
    builder: (context, value, _) {
      final issuedQty = item.issuedQty ?? 0;
      final issuedKg = item.issuedWeightKg;
      final qty = double.tryParse(value.text.trim());
      final String text;
      if (issuedKg == null) {
        text = '退回重量 $weightUnknownText';
      } else if (qty == null || qty <= 0 || issuedQty <= 0) {
        text = '退回重量 —';
      } else {
        final full = (qty - issuedQty).abs() < 0.0000001;
        final kg = full ? issuedKg : roundKgLine(issuedKg * qty / issuedQty);
        text =
            '退回重量 ${formatWeightValue(kg, estimated: item.issuedWeightEstimated)}'
            '${full ? '' : ' (按比例)'}';
      }
      final theme = Theme.of(context);
      return Padding(
        padding: const EdgeInsets.only(top: UtenSpacing.s4),
        child: Text(
          text,
          key: ValueKey('cancel-issue-weight-${item.id}'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    },
  );
}

/// 成品点收弹窗: 实收改小时入库重量按比例缩 (与服务端 round(重量 x 实收/待点收, 4) 同口径),
/// 只读提示, 不在这里改重量。
class _FinishedInboundWeightHint extends StatelessWidget {
  const _FinishedInboundWeightHint({
    required this.weight,
    required this.baseQty,
    required this.accepted,
  });

  /// 本批登记重量(千克)与待点收上限：实收按比例折算入库重量。
  final double weight;
  final double baseQty;
  final TextEditingController accepted;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: accepted,
        builder: (context, value, _) {
          final base = baseQty;
          final qty = double.tryParse(value.text.trim());
          final String text;
          if (qty == null || qty < 0 || base <= 0) {
            text = '入库重量按实收比例计算';
          } else if ((qty - base).abs() < 0.0000001) {
            text = '入库重量 ${formatWeightValue(weight)}';
          } else {
            text =
                '入库重量 ${formatWeightValue(roundKgLine(weight * qty / base))}';
          }
          final theme = Theme.of(context);
          return Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s4),
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          );
        },
      );
}
