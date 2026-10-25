import '../../../shared/documents/imported_document_policy.dart';
import '../../../shared/documents/document_unapproval_action.dart';
import '../../../shared/models/procurement_quantity.dart';
import '../../../shared/documents/document_unapproval.dart';
import '../../../shared/auth/native_read_view_scope_mixin.dart';
import '../../../shared/business_columns/business_columns_table.dart';
// 采购单据详情页（全页路由）：主表头卡 + 只读明细子表 + 状态门控操作（审核/反审/编辑/删除）。
//
// 计划下达的采购申请始终只读；订货走财务审批；收货/退货才沿用各自的草稿/审核/反审动作。
// 财务决定只存在于财务任务中心；本页仅消费业务动作能力与 SUBMIT_FINANCE。
// 名称解析：供应商/仓库/币种/颜色/单位用 MasterNameService；货品按明细 id 批量 lookup。
//
// 2026-09-09 折叠头+表内滚改版（与货品资料页统一）：整页 ListView 改
// UtenCollapsingHeaderScrollView——上滑先折叠头部（表头卡/横幅/附件），表头顶到
// 页面顶部后再滚明细表内部；附件等小卡并入折叠头尾部（随头部一起收起）。
import 'dart:async';

import 'package:flutter/material.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../shared/models/historical_receipt_facts.dart';
import '../../../shared/widgets/historical_receipt_totals.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../components/data_display/uten_detail_summary_card.dart';
import '../../../components/data_display/uten_selection_summary_pill.dart';
import '../../../components/data_display/uten_totals_summary_bar.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/document_scope_capability.dart';
import '../../../shared/auth/document_scope_write_notice.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/attachments/business_attachment_section.dart';
import '../../../core/utils/currency_display.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../../../shared/formatters/money_display.dart';
import '../../../shared/formatters/quantity_display.dart'
    show formatQtyWithUnit, formatExactQtyWithUnit;
import '../../../shared/widgets/source_doc_link.dart';
import '../../../shared/widgets/procurement_document_layout.dart';
import '../../../shared/measurement/exact_measurement_totals.dart';
import '../../../shared/measurement/document_quantity.dart';
import '../../basic_data/repositories/reference_method_repository.dart';
import '../../basic_data/models/reference_method_option.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../config/purchase_doc_config.dart';
import '../models/purchase_doc.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../repositories/purchase_repository.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_access_policy.dart';
import '../widgets/purchase_status_badge.dart';
import '../widgets/purchase_order_print_preview.dart';
import '../../../shared/auth/session_snapshot_provider.dart';

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

class _PurchaseDocDetailPageState extends ConsumerState<PurchaseDocDetailPage>
    with NativeReadViewScopeMixin<PurchaseDocDetailPage> {
  static const _financeApprovalTasksPath = '/finance/procurement-approvals';

  PurchaseDocConfig get _cfg => PurchaseDocConfig.by(widget.docType);
  PurchaseDocDetail? _detail;
  bool _loading = false;
  bool _busy = false;
  // 处理中遮罩标题（跟随动作，如「正在审核…」「正在删除…」）。
  String _busyTitle = '正在处理，请稍候';
  bool _openingOrder = false;
  bool _openingPrint = false;
  final Set<String> _selectedRequestItemIds = {};
  String? _myLocation;

  bool get _canGenerateRequestOrder =>
      _qtyInputConflicts.isEmpty &&
      widget.docType == PurchaseDocType.request &&
      _detail?.status == kPurchaseStatusApproved &&
      _detail?.closed == false &&
      _hasPermission(Perm.purchaseOrderCreate) &&
      _hasPermission(Perm.purchaseOrderDecompose);

  BigInt? _remainingRequestUnits(PurchaseDocItem item) {
    final recorded = financeExactDecimalUnits(
      item.remainingQtyText ?? item.remainingQty?.toString(),
    );
    if (recorded != null) return recorded.isNegative ? BigInt.zero : recorded;
    final requested = financeExactDecimalUnits(
      item.qtyText ?? item.qty?.toString(),
    );
    final ordered = financeExactDecimalUnits(
      item.orderedQtyText ?? (item.orderedQty ?? 0).toString(),
    );
    final pending = financeExactDecimalUnits(
      item.pendingQtyText ?? (item.pendingQty ?? 0).toString(),
    );
    if (requested == null || ordered == null || pending == null) return null;
    final remaining = requested - ordered - pending;
    return remaining.isNegative ? BigInt.zero : remaining;
  }

  String? _remainingRequestQtyText(PurchaseDocItem item) {
    final units = _remainingRequestUnits(item);
    return units == null
        ? null
        : financeExactTrimmed(financeExactDecimalFromUnits(units));
  }

  BigInt? _remainingPhysicalRequestUnits(PurchaseDocItem item) {
    final recorded = financeExactDecimalUnits(item.physicalRemainingQtyText);
    if (recorded != null) return recorded.isNegative ? BigInt.zero : recorded;
    if (item.quantitySemantics != null &&
            item.quantitySemantics != procurementLegacyQuantity ||
        (financeExactDecimalUnits(item.giftOrderedQtyText) ?? BigInt.zero) >
            BigInt.zero ||
        (financeExactDecimalUnits(item.pendingGiftQtyText) ?? BigInt.zero) >
            BigInt.zero) {
      return null;
    }
    return _remainingRequestUnits(item);
  }

  String? _physicalRequestCommitmentText(
    PurchaseDocItem item, {
    required bool pending,
  }) {
    final recorded = pending
        ? item.physicalPendingQtyText
        : item.physicalOrderedQtyText;
    if (recorded != null) return recorded;
    if (item.quantitySemantics != null &&
        item.quantitySemantics != procurementLegacyQuantity) {
      return null;
    }
    final paid = pending
        ? item.pendingQtyText ?? item.pendingQty?.toString()
        : item.orderedQtyText ?? item.orderedQty?.toString();
    final gift = pending ? item.pendingGiftQtyText : item.giftOrderedQtyText;
    return financeExactSumTexts([paid ?? '0', gift ?? '0']);
  }

  String? _remainingPhysicalRequestText(PurchaseDocItem item) {
    final units = _remainingPhysicalRequestUnits(item);
    return units == null
        ? null
        : financeExactTrimmed(financeExactDecimalFromUnits(units));
  }

  bool _canSelectRequestItem(PurchaseDocItem item) =>
      !_busy &&
      item.id?.isNotEmpty == true &&
      (_remainingPhysicalRequestUnits(item) ?? BigInt.zero) > BigInt.zero;

  static String _requestQtyText(String? exact, double? value) =>
      financeExactTrimmed(exact ?? value?.toString()) ?? '—';

  Future<void> _generateSelectedOrder() async {
    if (!nativeReadCanWrite) return;
    final ownsNative = captureNativeOwnership();
    if (!_canGenerateRequestOrder ||
        _openingOrder ||
        _busy ||
        _changedQtyItems.isNotEmpty) {
      return;
    }
    final ids = [
      for (final item in _detail!.items)
        if (_selectedRequestItemIds.contains(item.id) &&
            _canSelectRequestItem(item))
          item.id!,
    ];
    if (ids.isEmpty) return;
    setState(() => _openingOrder = true);
    try {
      await context.push(
        '/purchase/orders/new?requestItemIds=${ids.join(',')}',
      );
      if (mounted && ownsNative()) {
        _selectedRequestItemIds.clear();
        await _load();
      }
    } finally {
      if (mounted && ownsNative()) setState(() => _openingOrder = false);
    }
  }

  // V477 分解前数量修正：申请明细行内编辑（键=明细 id）。仅计划下达的
  // 已审核申请、且明细尚无订货/待审占用时可编辑；保存走专用修正端点。
  final Map<String, TextEditingController> _qtyControllers = {};
  final Map<
    String,
    ({String qty, String ordered, String pending, String source, int? version})
  >
  _qtyInputBases = {};
  final Set<String> _qtyInputConflicts = {};

  // Set before dispatch. Neither a failed PUT nor a same-quantity GET proves
  // which actor committed it; only explicit review can adopt a new baseline.
  final Set<String> _qtyWriteReviewRequired = {};

  String get _qtyConflictSummary {
    final id = _qtyInputConflicts.first;
    PurchaseDocItem? current;
    for (final item in _detail?.items ?? const <PurchaseDocItem>[]) {
      if (item.id == id) {
        current = item;
        break;
      }
    }
    final values = current == null
        ? '该行内容已有变化。'
        : '原数量 ${_qtyInputBases[id]?.qty ?? '—'}，当前数量 ${_requestQtyText(current.qtyText, current.qty)}，'
              '你填的是 ${_qtyControllers[id]?.text ?? '—'}。';
    return '${_qtyInputConflicts.length} 行数量需要核对：可能别人也改过，或已被订货占用。$values'
        '${_qtyWriteReviewRequired.isEmpty ? '' : '之前有一次提交结果不明；即使当前数量和你填的一样，也不能当作已保存成功。'}'
        '你填的内容已保留；核对清楚前不能保存或生成订货单。';
  }

  ({String qty, String ordered, String pending, String source, int? version})
  _qtyInputBase(PurchaseDocItem item) => (
    qty: _requestQtyText(item.qtyText, item.qty),
    version: item.rowVersion,
    ordered:
        financeExactTrimmed(
          _physicalRequestCommitmentText(item, pending: false),
        ) ??
        '—',
    pending:
        financeExactTrimmed(
          _physicalRequestCommitmentText(item, pending: true),
        ) ??
        '—',
    source:
        '${item.goodsId}/${item.colorId}/${item.unitId}/${item.sourceDocNo}/${item.productionPlanNo}/${item.salesOrderNo}',
  );

  void _reconcileQtyInputBases(PurchaseDocDetail detail) {
    final items = {for (final item in detail.items) item.id: item};
    for (final entry in _qtyControllers.entries) {
      final old = _qtyInputBases[entry.key];
      final current = items[entry.key];
      if (old == null ||
          current == null ||
          _qtyWriteReviewRequired.contains(entry.key)) {
        _qtyInputConflicts.add(entry.key);
        continue;
      }
      final next = _qtyInputBase(current);
      if (entry.value.text.trim() == old.qty) {
        _qtyInputBases[entry.key] = next;
        entry.value.text = next.qty;
        _qtyInputConflicts.remove(entry.key);
      } else if (old != next) {
        // Never pair an old local edit with a silently adopted new baseline.
        _qtyInputConflicts.add(entry.key);
      }
    }
  }

  bool get _canAdjustRequestQty =>
      nativeReadCanWrite &&
      widget.docType == PurchaseDocType.request &&
      _detail?.status == 1 &&
      _hasPermission(Perm.purchaseRequestView) &&
      _hasPermission(Perm.purchaseOrderDecompose);

  bool _itemQtyEditable(PurchaseDocItem item) =>
      _canAdjustRequestQty &&
      !_qtyInputConflicts.contains(item.id) &&
      item.rowVersion != null &&
      item.rowVersion! >= 0 &&
      financeExactDecimalUnits(
            _physicalRequestCommitmentText(item, pending: false),
          ) ==
          BigInt.zero &&
      financeExactDecimalUnits(
            _physicalRequestCommitmentText(item, pending: true),
          ) ==
          BigInt.zero &&
      item.id != null;

  TextEditingController _qtyControllerOf(PurchaseDocItem item) {
    final id = item.id!;
    var controller = _qtyControllers[id];
    if (controller == null) {
      controller = TextEditingController(
        text: item.qtyText == null && item.qty == null
            ? ''
            : _requestQtyText(item.qtyText, item.qty),
      );
      controller.addListener(() {
        if (mounted) setState(() {});
      });
      _qtyControllers[id] = controller;
      _qtyInputBases[id] = _qtyInputBase(item);
    }
    return controller;
  }

  /// 有改动的明细（文本与原值不同的可编辑行）。
  List<(PurchaseDocItem, String)> get _changedQtyItems {
    if (!_canAdjustRequestQty) return const [];
    return [
      for (final item in _detail!.items)
        if (_itemQtyEditable(item) &&
            _qtyControllerOf(item).text.trim() !=
                (item.qtyText == null && item.qty == null
                    ? ''
                    : _requestQtyText(item.qtyText, item.qty)))
          (item, _qtyControllerOf(item).text.trim()),
    ];
  }

  bool get _canReviewQtyInputs =>
      nativeReadCanWrite &&
      !(_detail?.legacyImported ?? false) &&
      !_busy &&
      _qtyInputConflicts.isNotEmpty &&
      _qtyInputConflicts.every(
        (id) => _detail!.items.any(
          (item) => item.id == id && item.rowVersion != null,
        ),
      );

  Future<void> _adoptCurrentQtyInputs() async {
    final detail = _detail;
    if (detail == null || !_canReviewQtyInputs) return;
    final ownsNative = captureNativeOwnership();
    final choice = await showDialog<bool>(
      context: context,
      builder: (ctx) => trackNativeReadDialog(
        ctx,
        UtenAlertDialog(
          scrollable: false,
          title: const Text('核对数量变化'),
          content: SingleChildScrollView(
            child: Text(
              '${[for (final item in detail.items)
                if (_qtyInputConflicts.contains(item.id)) '第 ${detail.items.indexOf(item) + 1} 行：原数量 ${_qtyInputBases[item.id]?.qty ?? '—'}，'
                      '当前数量 ${_requestQtyText(item.qtyText, item.qty)}，'
                      '你填的是 ${_qtyControllers[item.id]?.text ?? '—'}。'].join('\n')}\n'
              '请选择「保留我填的数量」，或「采用当前数量」。此操作只更新本页的对照基准，不会提交修改，也不能认定先前那次提交已成功。',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('暂不处理'),
            ),
            TextButton(
              key: const Key('purchase-request-qty-adopt-version'),
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('保留我填的数量'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('采用当前数量'),
            ),
          ],
        ),
      ),
    );
    if (choice == null ||
        !mounted ||
        !ownsNative() ||
        !_canReviewQtyInputs ||
        !identical(_detail, detail)) {
      return;
    }
    for (final item in detail.items) {
      if (!_qtyInputConflicts.contains(item.id)) continue;
      final controller = _qtyControllers[item.id];
      if (controller == null) continue;
      final current = _qtyInputBase(item);
      _qtyInputBases[item.id!] = current;
      if (choice) controller.text = current.qty;
      _qtyInputConflicts.remove(item.id);
      _qtyWriteReviewRequired.remove(item.id);
    }
    setState(() {});
  }

  Future<void> _saveQtyAdjustments() async {
    if (_busy || !nativeReadCanWrite || _qtyInputConflicts.isNotEmpty) return;
    final ownsNative = captureNativeOwnership();
    final changes = _changedQtyItems;
    if (changes.isEmpty || !mounted || !ownsNative() || !nativeReadCanWrite) {
      return;
    }
    final invalid = changes
        .where((change) => positiveDocumentQuantityText(change.$2) == null)
        .toList();
    if (invalid.isNotEmpty) {
      context.appError('数量必须大于 0，最多 14 位整数和 4 位小数');
      return;
    }
    setState(() {
      _busy = true;
      _busyTitle = '正在保存数量修正，请稍候';
    });
    try {
      for (final (item, qty) in changes) {
        if (!mounted || !ownsNative() || !nativeReadCanWrite) return;
        final id = item.id!;
        final base = _qtyInputBases[id];
        final expectedVersion = base?.version;
        if (expectedVersion == null) return;
        final dispatchedDetail = _detail;
        final submittedText = _qtyControllers[id]!.text;
        _qtyWriteReviewRequired.add(id);
        _qtyInputConflicts.add(id);
        final updated = await ref
            .read(purchaseRepositoryProvider(widget.docType))
            .adjustRequestItemQty(
              requestId: widget.id,
              itemId: id,
              qty: qty,
              expectedVersion: expectedVersion,
            );
        if (!mounted ||
            !ownsNative() ||
            !nativeReadCanWrite ||
            !identical(_detail, dispatchedDetail)) {
          return;
        }
        final acknowledged = updated.items
            .where((row) => row.id == id)
            .firstOrNull;
        if (acknowledged == null ||
            acknowledged.rowVersion == null ||
            acknowledged.rowVersion! <= expectedVersion ||
            financeExactDecimalUnits(
                  acknowledged.qtyText ?? acknowledged.qty?.toString(),
                ) !=
                financeExactDecimalUnits(qty)) {
          throw const FormatException(
            'Missing or mismatched quantity acknowledgement',
          );
        }
        _qtyWriteReviewRequired.remove(id);
        _qtyInputConflicts.remove(id);
        final controller = _qtyControllers[id]!;
        final nextBase = _qtyInputBase(acknowledged);
        _qtyInputBases[id] = nextBase;
        if (controller.text == submittedText) controller.text = nextBase.qty;
        _reconcileQtyInputBases(updated);
        setState(() => _detail = updated);
        // Each accepted line is a completed command even if a later line fails.
        bumpListRefresh(ref, _cfg.refreshKey);
        if (_qtyInputConflicts.isNotEmpty) break;
      }
      if (!mounted || !ownsNative()) return;
      if (_qtyInputConflicts.isEmpty) context.appSuccess('数量已修正');
    } on ApiException catch (error) {
      if (!mounted || !ownsNative()) return;
      context.appError('${error.message}。你填的数量已保留；可能别人也改过这一行，请核对当前数量后再操作。');
      await _load();
    } catch (_) {
      if (!mounted || !ownsNative()) return;
      context.appError('还不确定刚才是否提交成功；你填的数量已保留，页面已重新读取当前数量，请核对后再操作。');
      await _load();
    } finally {
      if (mounted && ownsNative()) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    for (final controller in _qtyControllers.values) {
      controller.dispose();
    }
    _qtyControllers.clear();
    super.dispose();
  }

  bool get _canViewCommercialAmounts {
    return nativeReadAccessConfirmed &&
        _cfg.canViewCommercial(ref.read(currentPermissionsProvider)) &&
        !(_detail?.priceMasked ?? false);
  }

  String? _error;

  bool get _orderFinanceApproved =>
      _detail?.status == kPurchaseStatusApproved &&
      _detail?.financeApproval?.isApproved == true;

  Future<void> _printOrder() async {
    if (_openingPrint ||
        _busy ||
        _loading ||
        !nativeReadAccessConfirmed ||
        _detail == null) {
      return;
    }
    if (!_orderFinanceApproved) {
      context.appWarning('采购单须财务审核通过后才能打印；改量后须等待财务复核通过');
      return;
    }
    final ownsNative = captureNativeOwnership();
    setState(() => _openingPrint = true);
    try {
      final confirmed = await UtenDialog.show(
        context,
        title: '确认打印采购单',
        content: Text('将打开采购单 ${_detail!.billNo ?? widget.id} 的打印预览，请核对单号后继续。'),
        confirmLabel: '确认打印',
        waitForExit: true,
      );
      if (confirmed != true || !mounted || !ownsNative()) return;
      final document = await ref
          .read(purchaseRepositoryProvider(PurchaseDocType.order))
          .orderPrintDocument(widget.id);
      if (!mounted || !ownsNative()) return;
      await showPurchaseOrderPrintPreview(
        context,
        document,
        loader: () => ref
            .read(purchaseRepositoryProvider(PurchaseDocType.order))
            .orderPrintDocument(widget.id),
      );
    } on ApiException catch (error) {
      if (mounted && ownsNative()) context.appError(error.message);
    } catch (_) {
      if (mounted && ownsNative()) context.appError('采购单暂时读取不出来，请稍后重试');
    } finally {
      if (mounted && ownsNative()) setState(() => _openingPrint = false);
    }
  }

  @override
  void initState() {
    super.initState();
    initializeNativeReadScope();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  bool _hasPermission(String? code) =>
      code != null &&
      importedDocumentPermissionAllowed(
        code,
        _detail?.legacyImported ?? false,
      ) &&
      nativeReadAccessConfirmed &&
      ((code.endsWith(':view') ||
              code.contains(':view:') ||
              code.endsWith(':print') ||
              code.endsWith(':download')) ||
          nativeReadCanWrite) &&
      ref.read(currentPermissionsProvider).contains(code);

  bool get _historicalReceipt =>
      widget.docType == PurchaseDocType.receipt &&
      (_detail?.legacyImported ?? false);

  bool get _ordinaryWritable =>
      nativeReadCanWrite &&
      !(_detail?.legacyImported ?? false) &&
      !_historicalReceipt &&
      widget.docType != PurchaseDocType.request &&
      documentOwnerCanWrite(
        ref.read(documentScopeCapabilityProvider(DocumentDataScope.purchase)),
        _detail?.makerId,
      );

  bool get _canEdit => _ordinaryWritable && _hasPermission(_cfg.editPerm);
  bool get _canDelete => _ordinaryWritable && _hasPermission(_cfg.deletePerm);
  bool get _canApprove => _ordinaryWritable && _hasPermission(_cfg.approvePerm);
  bool get _canReverse => _ordinaryWritable && _hasPermission(_cfg.reversePerm);

  bool get _financeReviewOnly =>
      widget.docType == PurchaseDocType.order &&
      _hasPermission(Perm.financeOrderApprovalView) &&
      !_hasPermission(_cfg.listPerm);

  /// 批准后改量（对齐销售 V482）：财务批准后的订货单可逐行改数量；改后
  /// 服务端自动重回财务复核，财务在审批详情看到修改清单（以前→现在）。
  bool get _canChangeQty =>
      _ordinaryWritable &&
      widget.docType == PurchaseDocType.order &&
      _detail?.status == kPurchaseStatusApproved &&
      _detail?.financeApproval?.isPending != true &&
      _hasPermission(Perm.purchaseOrderChangeQty);

  String get _defaultBackPath =>
      _financeReviewOnly ? _financeApprovalTasksPath : RouteName.purchase;

  String get _returnLabel => _financeReviewOnly ? '返回订货审批任务中心' : '返回列表';

  String get _listPath => '/purchase/${_cfg.type.pathSegment}';

  /// 「返回列表」显隐：与列表路由守卫同源（财务核单等无列表权限的入口 push
  /// 进来时不渲染，否则按钮会把人带到 /access-denied；2026-09-10 审计）。
  bool get _canOpenList => locationAllowedFor(
    ref.read(currentPermissionsProvider),
    ref.read(isSuperAdminProvider),
    _listPath,
  );

  @override
  void nativeReadOwnerChanged() => setState(() {
    _detail = null;
    _loading = false;
    _busy = false;
    _error = '登录身份或服务器已变化，原页面信息已隐藏，请重新加载';
    _selectedRequestItemIds.clear();
    _qtyInputBases.clear();
    _qtyInputConflicts.clear();
    _qtyWriteReviewRequired.clear();
    _openingOrder = false;
    final controllers = _qtyControllers.values.toList();
    _qtyControllers.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final controller in controllers) {
        controller.dispose();
      }
    });
  });
  @override
  void nativeReadPermissionChanged() => setState(() {
    _busy = false;
  });
  @override
  Future<void> nativeReadReload() => _load();

  Future<void> _load() async {
    final acceptsRead = captureNativeRead(
      '${widget.docType.name}/${widget.id}',
      () => '${widget.docType.name}/${widget.id}',
    );
    if (!acceptsRead()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final names = ref.read(masterNameServiceProvider);
    // 字典与详情并行，首屏只等详情(ADR-108)；名称在首屏之后补齐再重绘一次。
    final dictionaries = names.ensureLoaded();
    try {
      final d = await ref
          .read(purchaseRepositoryProvider(widget.docType))
          .detail(widget.id);
      if (!acceptsRead()) return;
      unawaited(_resolveDisplayNames(names, d, dictionaries));
      if (widget.docType == PurchaseDocType.request) _reconcileQtyInputBases(d);
      acceptNativeRead();
      setState(() {
        _detail = d;
        _selectedRequestItemIds.retainAll({
          for (final item in d.items)
            if (item.id != null &&
                (_remainingRequestUnits(item) ?? BigInt.zero) > BigInt.zero)
              item.id!,
        });
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!acceptsRead()) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!acceptsRead()) return;
      setState(() {
        _error = '加载详情失败';
        _loading = false;
      });
    }
  }

  /// 首屏之后并行补齐字典与明细货品名/编号/库位号(采购明细服务端暂未随单下发货品
  /// 展示字段，由一次批量货品查询补齐)，完成后重绘一次。
  /// 人员姓名(工号)优先用服务端随单下发的解析值；旧后端未下发时按 id 补查本地字典。
  Future<void> _resolveDisplayNames(
    MasterNameService names,
    PurchaseDocDetail d,
    Future<void> dictionaries,
  ) async {
    try {
      await Future.wait([
        dictionaries,
        names.loadGoodsDetails(
          d.items.map((e) => e.goodsId).whereType<String>(),
        ),
        if (d.purchaserName == null ||
            d.senderName == null ||
            d.receiverName == null)
          names.loadEmployeeNames([
            if (_cfg.hasPurchaser && d.purchaserName == null) d.purchaserId,
            if (_cfg.hasSender && d.senderName == null) d.senderId,
            if (_cfg.hasReceiver && d.receiverName == null) d.receiverId,
          ]),
      ]);
    } catch (_) {
      // 名称补齐失败只影响占位符，不影响正文。
    }
    if (mounted && identical(_detail, d)) setState(() {});
  }

  Future<void> _approveDocument() async {
    if (!nativeReadCanWrite) return;
    final message = widget.docType == PurchaseDocType.receipt
        ? '审核后货品进入待检隔离(IQC，不入库存)：品质部在「品质任务中心→待检处置」'
              '检验，合格后转仓库待入库任务；仓库确认实物和库位后库存才增加。'
              '同时回写订货已收并立应付。'
              '单价按订货单自动带入，无需填写。'
        : '审核后将驱动下游库存和来源回写。';
    await _doAction(
      message,
      (repo) => repo.approve(widget.id),
      '已审核',
      busyTitle: '正在审核，请稍候',
      reviewerConfirmation: true,
      reviewerActionLabel: '${_cfg.shortLabel}审核',
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
    '提交后订货单将锁定并进入财务审核组共享待办；下一步由财务在'
        '「订货审批任务中心」审核。确认提交？',
    (repo) => repo.submitFinance(widget.id),
    '已提交财务审核组，等待财务审核',
    busyTitle: '正在提交财务审核，请稍候',
  );

  Future<void> _reverse() async => _doAction(
    documentUnapprovalConfirmation,
    (repo) => repo.reverse(widget.id),
    '已反审，进入草稿',
    busyTitle: '正在反审，请稍候',
  );

  /// 批准后改量：弹窗逐行改数量（照销售订货详情 _changeQty 结构）。改后自动
  /// 重回财务复核；驳回不会自动还原数量。
  Future<void> _changeQty() async {
    if (!_canChangeQty) return;
    final ownsNative = captureNativeOwnership();
    if (_busy) {
      context.appInfo('正在处理，请稍候…');
      return;
    }
    final detail = _detail;
    if (detail == null) return;
    final l10n = AppLocalizations.of(context);
    final names = ref.read(masterNameServiceProvider);
    final ctrls = <String, TextEditingController>{};
    for (final it in detail.items) {
      if (it.id != null) {
        ctrls[it.id!] = TextEditingController(
          text: it.qtyText ?? it.qty?.toString() ?? '',
        );
      }
    }
    final ok = await UtenDialog.showAndWaitForExit<Map<String, String>>(
      context,
      builder: (ctx) => trackNativeReadDialog(
        ctx,
        UtenAlertDialog(
          scrollable: false,
          key: const Key('purchase-order-change-qty-dialog'),
          title: Text(l10n.orderChangeQtyTitle),
          content: SizedBox(
            width: 420,
            child: ListView(
              shrinkWrap: true,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
                  child: Text(
                    l10n.orderChangeQtyWarning,
                    style: Theme.of(ctx).textTheme.labelMedium?.copyWith(
                      color: Theme.of(ctx).colorScheme.error,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                for (final it in detail.items)
                  if (it.id != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${names.goods(it.goodsId)}'
                              '(${names.color(it.colorId)} · ${names.unit(it.unitId)}) '
                              '${l10n.orderChangeQtyCurrent(financeExactTrimmed(it.qtyText ?? it.qty?.toString()) ?? '—')}',
                              style: Theme.of(ctx).textTheme.labelMedium
                                  ?.copyWith(fontWeight: FontWeight.w400),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          SizedBox(
                            width: 100,
                            child: TextField(
                              key: Key('purchase-order-change-qty-${it.id}'),
                              controller: ctrls[it.id!],
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              decoration: UtenInputDecoration(
                                InputDecoration(
                                  isDense: true,
                                  labelText: l10n.orderChangeQtyNewQty,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
              ],
            ),
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.commonCancel),
            ),
            FilledButton(
              key: const Key('purchase-order-change-qty-submit'),
              onPressed: () => Navigator.pop(ctx, {
                for (final entry in ctrls.entries) entry.key: entry.value.text,
              }),
              child: Text(l10n.orderChangeQtyConfirm),
            ),
          ],
        ),
      ),
    );
    if (ok == null || !mounted || !ownsNative() || !_canChangeQty) {
      _disposeChangeQtyControllers(ctrls.values);
      return;
    }
    final changes = <Map<String, dynamic>>[];
    for (final it in detail.items) {
      if (it.id == null) continue;
      final v = positiveDocumentQuantityText(ok[it.id!] ?? '');
      if (v == null) {
        _disposeChangeQtyControllers(ctrls.values);
        if (mounted && ownsNative()) {
          context.appError(l10n.orderChangeQtyInvalid);
        }
        return;
      }
      if (v != financeExactTrimmed(it.qtyText ?? it.qty?.toString())) {
        changes.add({'orderItemId': it.id, 'newQty': v});
      }
    }
    _disposeChangeQtyControllers(ctrls.values);
    if (changes.isEmpty || !mounted || !ownsNative() || !_canChangeQty) {
      return;
    }
    setState(() {
      _busy = true;
      _busyTitle = '正在提交数量修改，请稍候';
    });
    try {
      await ref
          .read(purchaseRepositoryProvider(widget.docType))
          .changeQty(widget.id, changes);
      if (!mounted || !ownsNative()) return;
      context.appSuccess(l10n.orderChangeQtySuccess);
      bumpListRefresh(ref, _cfg.refreshKey);
      await _load();
    } on ApiException catch (e) {
      if (mounted && ownsNative()) context.appError(e.message);
    } catch (_) {
      if (mounted && ownsNative()) context.appError(l10n.orderChangeQtyFailed);
    } finally {
      if (mounted && ownsNative()) setState(() => _busy = false);
    }
  }

  /// 调用方已等待弹层完全退出，逐个释放临时控制器。
  void _disposeChangeQtyControllers(
    Iterable<TextEditingController> controllers,
  ) {
    for (final controller in controllers) {
      controller.dispose();
    }
  }

  Future<void> _cancelOrder() async => _doAction(
    '取消后该草稿订货单转为「已取消」并保留轨迹'
        '（若已提交财务审核，财务侧任务同步撤回），不可再编辑或提交。确认取消？',
    (repo) => repo.cancelOrder(widget.id),
    '订货单已取消',
    busyTitle: '正在取消，请稍候',
  );

  Future<void> _doAction(
    String confirm,
    Future<Object?> Function(PurchaseRepository) fn,
    String ok, {
    void Function(ApiException error)? onApiError,
    bool reviewerConfirmation = false,
    String reviewerActionLabel = '审核',
    String? busyTitle,
  }) async {
    if (!nativeReadCanWrite) return;
    final ownsNative = captureNativeOwnership();
    if (_busy || _historicalReceipt) return;
    final c = reviewerConfirmation
        ? await showNativeReadReviewerConfirm(
            context,
            message: confirm,
            actionLabel: reviewerActionLabel,
          )
        : await showDialog<bool>(
            context: context,
            builder: (ctx) => trackNativeReadDialog(
              ctx,
              UtenAlertDialog(
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
            ),
          );
    if (c != true || !mounted || !ownsNative() || !nativeReadCanWrite) return;
    setState(() {
      _busy = true;
      _busyTitle = busyTitle ?? '正在处理，请稍候';
    });
    try {
      final result = await fn(
        ref.read(purchaseRepositoryProvider(widget.docType)),
      );
      if (!mounted || !ownsNative()) return;
      bumpListRefresh(ref, _cfg.refreshKey);
      if (result is PurchaseDocDetail && result.id != widget.id) {
        showDocumentUnapprovalResult(context, result.status);
        openUnapprovedDraft(
          context,
          RoutePath.purchaseDocDetail(widget.docType.pathSegment, result.id),
        );
        return;
      }
      context.appSuccess(ok);
      await _load();
    } on ApiException catch (e) {
      if (mounted && ownsNative()) {
        final handler = onApiError;
        if (handler != null) {
          handler(e);
        } else {
          context.appError(e.message);
        }
      }
    } catch (_) {
      if (mounted && ownsNative()) context.appError('操作失败，请稍后重试');
    } finally {
      if (mounted && ownsNative()) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    if (!nativeReadCanWrite) return;
    final ownsNative = captureNativeOwnership();
    if (_busy || _historicalReceipt) return;
    final c = await showDialog<bool>(
      context: context,
      builder: (ctx) => trackNativeReadDialog(
        ctx,
        UtenAlertDialog(
          title: const Text('删除单据'),
          content: const Text('确定删除该草稿单据吗？'),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除'),
            ),
          ],
        ),
      ),
    );
    if (c != true || !mounted || !ownsNative() || !nativeReadCanWrite) return;
    setState(() {
      _busy = true;
      _busyTitle = '正在删除，请稍候';
    });
    try {
      await ref
          .read(purchaseRepositoryProvider(widget.docType))
          .delete(widget.id);
      if (!mounted || !ownsNative()) return;
      context.appSuccess('已删除');
      // 删除也 bump：来源列表就在栈顶可见时立即去掉这行，草稿计数/徽章即时
      // 重拉（其余写动作都有 bump，唯独删除漏了）。
      bumpListRefresh(ref, _cfg.refreshKey);
      // 返回键契约（路由设计 §十一）：pop 回来源，栈空回 hub/任务中心。
      popOrBackTo(context, defaultPath: _defaultBackPath);
    } on ApiException catch (e) {
      if (mounted && ownsNative()) context.appError(e.message);
    } catch (_) {
      if (mounted && ownsNative()) context.appError('删除失败，请稍后重试');
    } finally {
      if (mounted && ownsNative()) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scopeCapability = widget.docType == PurchaseDocType.request
        ? null
        : ref.watch(
            documentScopeCapabilityProvider(DocumentDataScope.purchase),
          );
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    // 返回即刷新(ADR-108)：编辑保存后的落点已改为 pop 回宿主，本页靠这里重取
    // 保存后的新数据；从本页 push 出去的子页（关联单据/审核等）返回时同样生效。
    _myLocation ??= currentLocationOr(
      context,
      RoutePath.purchaseDocDetail(_cfg.type.pathSegment, widget.id),
    );
    ref.onPageResume(_myLocation!, _load);
    return Scaffold(
      appBar: UtenAppBar(
        title: '${_cfg.label}详情',
        actions: [
          if (widget.docType == PurchaseDocType.order)
            Tooltip(
              message: _orderFinanceApproved
                  ? '打印采购单'
                  : '财务审核通过后才能打印，改量后须等待财务复核通过',
              child: UtenButton(
                key: const Key('purchase-order-print'),
                icon: Icons.print_outlined,
                isLoading: _openingPrint,
                onPressed:
                    !_loading &&
                        !_busy &&
                        nativeReadAccessConfirmed &&
                        _orderFinanceApproved
                    ? _printOrder
                    : null,
                child: const Text('打印单据'),
              ),
            ),
        ],
        leading: UtenBackButton(
          onPressed: () => popOrBackTo(context, defaultPath: _defaultBackPath),
        ),
      ),
      body: SafeArea(
        // 2026-09-05 用户口径：明细表是本页主体，用全宽容器（与单据列表页
        // 同款），不再 narrow 居中导致宽屏两侧大片空白。
        child: Stack(
          children: [
            UtenContentContainer.wide(
              child: _loading
                  ? Semantics(
                      label: AppLocalizations.of(context).commonLoading,
                      liveRegion: true,
                      child: const UtenSkeletonList(),
                    )
                  : _error != null
                  ? UtenEmpty.error(
                      message: _error,
                      actionLabel: AppLocalizations.of(context).commonRetry,
                      onAction: () async {
                        if (!_loading) await _load();
                      },
                    )
                  : !nativeReadAccessConfirmed
                  ? nativeReadAccessNotice()
                  : _detail == null
                  ? const SizedBox.shrink()
                  // 2026-09-09 折叠头+表内滚（与货品资料页统一）：上滑先收头部
                  // （表头卡/横幅/附件），表头顶到页面顶部后再滚明细表内部。
                  : UtenCollapsingHeaderScrollView(
                      collapsingHeader: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          UtenSpacing.s12,
                          UtenSpacing.s12,
                          UtenSpacing.s12,
                          0,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_historicalReceipt)
                              const Card(
                                child: Padding(
                                  padding: EdgeInsets.all(UtenSpacing.s12),
                                  child: Text(historicalReceiptReadOnlyMessage),
                                ),
                              ),
                            if (scopeCapability != null)
                              DocumentScopeWriteNotice(
                                capability: scopeCapability,
                                ownerEmployeeId: _detail!.makerId,
                                onRetry: () => ref
                                    .read(sessionSnapshotProvider.notifier)
                                    .refresh(),
                              ),
                            // 表头信息卡文字可框选：外层 UtenContentContainer 已默认包局部
                            // SelectionArea（准则 §3.4），无需再单独包。
                            documentUnapprovalBannerForRoute(
                              'purchase',
                              widget.docType.pathSegment,
                              widget.id,
                            ),
                            _headerCard(theme, names),
                            if (widget.docType == PurchaseDocType.order &&
                                (_detail!.status == kPurchaseStatusDraft ||
                                    _detail!.status ==
                                        kPurchaseStatusApproved) &&
                                (_detail!.financeApproval?.isPending == true ||
                                    _detail!.financeApproval?.isRejected ==
                                        true)) ...[
                              const SizedBox(height: UtenSpacing.s12),
                              _financeApprovalBanner(theme),
                            ],
                            if (_detail!.productionLinked) ...[
                              const SizedBox(height: UtenSpacing.s12),
                              _productionSourceBanner(theme),
                            ],
                            // 附件属「备注类小卡」：并入折叠头尾部，随头部一起收起。
                            if (widget.docType == PurchaseDocType.order) ...[
                              const SizedBox(height: UtenSpacing.s12),
                              BusinessAttachmentSection(
                                ownerType: 'PURCHASE_ORDER',
                                ownerId: _detail!.id,
                                canView:
                                    _canViewCommercialAmounts &&
                                    (_hasPermission(Perm.purchaseOrderView) ||
                                        (_hasPermission(
                                              Perm.financeOrderApprovalView,
                                            ) &&
                                            _detail!
                                                    .financeApproval
                                                    ?.isPending ==
                                                true)),
                                // 详情=审核页：文件只读（增删回编辑页）。
                                canManage: false,
                                readOnlyNote: BusinessAttachmentSection
                                    .kReviewReadOnlyAttachmentNote,
                                categories: const ['合同', '供应商确认', '图片', '其他'],
                              ),
                            ],
                          ],
                        ),
                      ),
                      // body：明细标题行（钉住）+ 表格占满内滚（primary 拾取联动控制器）。
                      body: Padding(
                        // 底部让位右下悬浮操作组：末行可滚出按钮区。
                        padding: const EdgeInsets.fromLTRB(
                          UtenSpacing.s12,
                          UtenSpacing.s12,
                          UtenSpacing.s12,
                          UtenFloatingActionGroup.controlHeight +
                              UtenSpacing.s32,
                        ),
                        child: _itemsCard(theme, names),
                      ),
                    ),
            ),
            // 处理中屏幕中央加载遮罩（对齐销售单据详情 UtenBusyOverlay 口径）：
            // 只跟随网络等待段，结果提示展示期间已撤下；按钮禁用逻辑不变。
            if (_busy)
              Positioned.fill(child: UtenBusyOverlay(title: _busyTitle)),
          ],
        ),
      ),
      // 2026-09-14 UI 统一口径：底部吸底操作条改右下悬浮组，大小/高度/禁用态
      // 与全站一致。
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton:
          !nativeReadAccessConfirmed ||
              _detail == null ||
              _busy ||
              _loading ||
              _error != null
          ? null
          : _actions(theme),
    );
  }

  Widget _headerCard(ThemeData theme, MasterNameService names) {
    final d = _detail!;
    final canViewCommercialAmounts = _canViewCommercialAmounts;
    final rows = <_KV>[
      _KV('单据号', d.billNo),
      _KV('日期', d.billDate),
      _KV('制单员', d.makerName),
      _KV('制单时间', utenFmtIsoTime(d.createdAt)),
      if (_cfg.hasSupplier) _KV('供应商', names.supplier(d.supplierId)),
      // 订货单不涉及仓库：入库仓库到收货登记时才产生。
      if (_cfg.hasWarehouse) _KV('仓库', names.warehouse(d.warehouseId)),
      if (_cfg.hasDepartment) _KV('申请部门', names.department(d.departmentId)),
      if (canViewCommercialAmounts &&
          _cfg.hasCurrency &&
          financeExactDecimal(d.totalOriginalText) == null)
        _KV('单据币种', names.currency(d.currencyId)),
      if (canViewCommercialAmounts &&
          (_historicalReceipt || d.exchangeRate != null))
        _KV(
          '汇率',
          _historicalReceipt
              ? historicalReceiptRate(d.exchangeRateText)
              : d.exchangeRate?.toString(),
        ),
      if (_cfg.hasApplicant) _KV('申请人', d.applicantName ?? '—'),
      // 人员身份统一 姓名(工号)：优先服务端随单解析值，旧后端未下发时退回本地员工字典。
      if (_cfg.hasPurchaser)
        _KV('采购员', names.employeeOr(d.purchaserName, d.purchaserId)),
      if (_cfg.hasSender)
        _KV('交货人', names.employeeOr(d.senderName, d.senderId)),
      if (_cfg.hasReceiver)
        _KV('收货人', names.employeeOr(d.receiverName, d.receiverId)),
      if (_cfg.hasNeedDate) _KV('需求日', d.needDate),
      if (_cfg.hasDeliverDate) _KV('交货日', d.deliverDate),
      if (canViewCommercialAmounts && _historicalReceipt) ...[
        _KV(
          '原始表头原币合计',
          financeMoneyWithUnitSuffix(
            historicalReceiptAmount(d.totalOriginalText),
            currencyName: names.currency(d.currencyId),
            fullCurrencyName: true,
          ),
        ),
        _KV(
          '原始表头本币合计',
          financeMoneyWithUnitSuffix(
            historicalReceiptAmount(d.totalLocalText),
            currencyName: '人民币',
            fullCurrencyName: true,
          ),
        ),
      ],
      if (canViewCommercialAmounts &&
          widget.docType != PurchaseDocType.request &&
          !_historicalReceipt) ...[
        if (_cfg.hasCurrency)
          _KV(
            '单据金额',
            financeMoneyWithUnitSuffix(
              d.totalOriginalText,
              currencyName: names.currency(d.currencyId),
              fullCurrencyName: true,
            ),
          ),
        _KV(
          '合计(本币)',
          financeMoneyWithUnitSuffix(
            d.totalLocalText,
            currencyName: '人民币',
            fullCurrencyName: true,
          ),
        ),
      ],
      if (d.remark?.isNotEmpty == true) _KV('备注', d.remark),
      if (widget.docType == PurchaseDocType.order) ...[
        _KV('财务审批', _financeApprovalLabel()),
        if (d.financeApproval?.isPending == true)
          const _KV('审核方式', '财务审核组共享待审')
        else if (d.financeApproval?.assigneeName?.isNotEmpty == true)
          _KV('历史负责人快照', d.financeApproval!.assigneeName),
      ],
      _KV(
        '状态',
        d.legacyImported
            ? importedBusinessHistoryLabel
            : widget.docType == PurchaseDocType.request && d.status == 1
            ? '计划已下达，等待采购分解'
            : null,
        badge:
            d.legacyImported ||
                (widget.docType == PurchaseDocType.request && d.status == 1)
            ? null
            : PurchaseStatusBadge(
                status: d.status,
                closed: d.closed,
                // 订货单在审/退回期间按财务审批投影显示，避免误显「草稿」。
                financeApproval: widget.docType == PurchaseDocType.order
                    ? d.financeApproval
                    : null,
              ),
      ),
    ];
    final primaryLabels = {
      '单据金额',
      if (d.totalOriginalText == null || !_cfg.hasCurrency) '合计(本币)',
      '原始表头原币合计',
      '原始表头本币合计',
    };
    const factLabels = {'日期', '供应商', '仓库', '申请部门', '申请人', '需求日', '交货日', '财务审批'};
    return UtenDetailSummaryCard(
      heading: Text(
        d.billNo ?? '—',
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
      status: rows.last.badge ?? Text(rows.last.value ?? '—'),
      primary: [
        for (final r in rows)
          if (primaryLabels.contains(r.label)) _kvRow(theme, r),
      ],
      facts: [
        for (final r in rows)
          if (factLabels.contains(r.label)) _kvRow(theme, r),
      ],
      details: [
        UtenSummaryFacts(
          children: [
            for (final r in rows)
              if (r.label != '单据号' &&
                  r.label != '状态' &&
                  !primaryLabels.contains(r.label) &&
                  !factLabels.contains(r.label))
                _kvRow(theme, r),
            if (widget.docType == PurchaseDocType.order &&
                (d.sourceRequestId != null || d.sourceRequestNo != null))
              SourceDocLink(
                label: '来源申请',
                billNo: d.sourceRequestNo,
                onTap: d.sourceRequestId == null
                    ? null
                    : () => context.push(
                        RoutePath.purchaseDocDetail(
                          'requests',
                          d.sourceRequestId!,
                        ),
                      ),
              ),
            if (widget.docType != PurchaseDocType.order &&
                widget.docType != PurchaseDocType.request &&
                (d.sourceOrderId != null || d.sourceOrderNo != null))
              SourceDocLink(
                label: '来源订货单',
                billNo: d.sourceOrderNo,
                onTap: d.sourceOrderId == null
                    ? null
                    : () => context.push(
                        RoutePath.purchaseDocDetail('orders', d.sourceOrderId!),
                      ),
              ),
            if (d.sourceDocNo?.isNotEmpty == true &&
                widget.docType != PurchaseDocType.order)
              SourceDocLink(label: '来源单据', billNo: d.sourceDocNo),
            if (d.items.any(
              (it) =>
                  (it.productionPlanNo?.isNotEmpty == true) ||
                  (it.salesOrderNo?.isNotEmpty == true),
            ))
              SourceDocLink(
                label: '计划/销售来源',
                billNo: d.items
                    .map((it) => it.productionPlanNo)
                    .whereType<String>()
                    .toSet()
                    .join('、'),
                subtitle: d.items
                    .map((it) => it.salesOrderNo)
                    .whereType<String>()
                    .toSet()
                    .join('、'),
              ),
          ],
        ),
      ],
    );
  }

  Widget _kvRow(ThemeData theme, _KV r) {
    return UtenSummaryField(
      label: r.label,
      value: r.value,
      emphasis: r.label == '单据金额' || r.label == '合计(本币)',
      danger: r.label == '单据金额',
    );
  }

  /// 明细区：统一表格样式（MasterDataTableView 嵌入模式，与全站报表/主档同款：
  /// 表头设置列显隐 + 网格线 + 横滚），不再是卡片式拼凑行。
  Widget _itemsCard(ThemeData theme, MasterNameService names) {
    final d = _detail!;
    final items = d.items;
    final settlementOptions = ref.watch(settlementMethodOptionsProvider);
    final hasTotalPricing =
        widget.docType == PurchaseDocType.order &&
        items.any((it) => it.totalAmountInputText != null);
    final canViewCommercialAmounts = _canViewCommercialAmounts;
    final changedCount = _changedQtyItems.length;
    // 「数量+单位」内联（2026-10-10 T9 全站表格口径）：独立单位列撤除，单位直接
    // 跟在数字后；空数量仍显 —。排序由表格数值容错解析兜底（剥单位后缀按数字排）。
    String? unitOf(PurchaseDocItem it) {
      final id = it.unitId;
      if (id == null || id.isEmpty) return null;
      return _dictText(names.unit(id));
    }

    String qtyWithUnit(num? value, PurchaseDocItem it) => value == null
        ? '—'
        : formatQtyWithUnit(value, unitOf(it), maxDecimals: 4);

    // 历史收货：保留原始记录文本（未知/未记载不拼单位，避免造数字）。
    String historicalQtyWithUnit(PurchaseDocItem it) {
      final text = historicalReceiptAmount(it.qtyText);
      final unit = unitOf(it);
      return (unit == null || text == '未知') ? text : '$text $unit';
    }

    String qtyDisplayOf(PurchaseDocItem it) => _historicalReceipt
        ? historicalQtyWithUnit(it)
        : (it.qtyText == null
              ? qtyWithUnit(it.qty, it)
              : formatExactQtyWithUnit(it.qtyText, unitOf(it)));

    // 金额「数值 币种」后缀（2026-10-10 口径）：明细行币种随单据表头
    // d.currencyId（names.currency 对缺失 id/未加载返回 '—'，助手遇 '—'
    // 不拼单位，历史记录「未知」原文同理）。
    final docCurrencyName = names.currency(_detail!.currencyId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_qtyInputConflicts.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
            child: Text(
              _qtyConflictSummary,
              key: const Key('purchase-request-qty-input-conflict'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        if (_qtyInputConflicts.isNotEmpty && nativeReadCanWrite)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const Key('purchase-request-qty-adopt-current'),
              onPressed: _canReviewQtyInputs ? _adoptCurrentQtyInputs : null,
              child: const Text('核对后采用当前数量'),
            ),
          ),
        if (_canAdjustRequestQty &&
            items.any((item) => item.rowVersion == null))
          const Padding(
            padding: EdgeInsets.only(bottom: UtenSpacing.s8),
            child: Text(
              '部分明细的数据不完整，请重新加载后再修改。',
              key: Key('purchase-request-qty-missing-version'),
            ),
          ),
        // 2026-09-25 用户口径：纯计数标题「明细 (N)」退役；生成订货单提示与
        // 数量修正入口保留（Spacer 维持原右对齐落位）。
        if (_canGenerateRequestOrder || changedCount > 0) ...[
          Row(
            children: [
              const Spacer(),
              if (_canGenerateRequestOrder)
                const UtenFieldHintIcon(
                  info: '勾选这次需要采购的明细，再生成订货单；下一页可填写本批数量。剩余部分以后再选，不会带入未勾选的明细。',
                ),
              // V477：分解前的数量修正（有改动才出现）。
              if (changedCount > 0) ...[
                Text(
                  '$changedCount 行待保存',
                  key: const Key('purchase-request-qty-dirty-count'),
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: UtenSpacing.s8),
                UtenButton(
                  key: const Key('purchase-request-qty-save'),
                  type: UtenButtonType.danger,
                  onPressed: _busy || _qtyInputConflicts.isNotEmpty
                      ? null
                      : _saveQtyAdjustments,
                  child: const Text('保存修改'),
                ),
              ],
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
        ],
        // primary:true → 表体占满 body 并参与「头部折叠 → 表格内滚」联动。
        Expanded(
          child: MasterDataTableView<PurchaseDocItem>(
            tableKey: 'purchase.${widget.docType.name}.items',
            primary: true,
            selectable: _canGenerateRequestOrder,
            // 已选胶囊随右下悬浮组（与「按所选生成采购订货单」同框），表头不驻留。
            showSelectionSummary: false,
            idOf: (item) => _canSelectRequestItem(item) ? item.id : null,
            rowKeyOf: (item) => item.id,
            rowWidgetKeyOf: (item) =>
                ValueKey('purchase-request-row-${item.id}'),
            selectedIds: _selectedRequestItemIds,
            onSelectedIdsChanged: (next) => setState(() {
              _selectedRequestItemIds
                ..clear()
                ..addAll(next);
            }),
            columns: canonicalProcurementColumns<MasterColumnDef<PurchaseDocItem>>(
              [
                MasterColumnDef(
                  key: 'goods',
                  label: '货品名称',
                  // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色各占一列。
                  // 同名不同色、同名不同编号在本系统极普遍，只看名称会认错货；拼成
                  // 一格又不能各自排序筛选。2026-09-19 单位独立成列（数量之后），
                  // 名称格不再带单位副行。
                  width: 200,
                  value: (it) => _dictText(names.goods(it.goodsId)) ?? '—',
                  cellBuilderHandlesSemantics: true,
                  cellBuilder: (context, it) => UtenGoodsIdentityCell(
                    name: _dictText(names.goods(it.goodsId)),
                  ),
                ),
                MasterColumnDef(
                  key: 'goodsCode',
                  label: '编号',
                  width: 130,
                  value: (it) => UtenGoodsAttributeCell.text(
                    names.goodsInfo(it.goodsId)?.code,
                  ),
                  cellBuilder: (context, it) =>
                      UtenGoodsAttributeCell(names.goodsInfo(it.goodsId)?.code),
                ),
                MasterColumnDef(
                  key: 'colorName',
                  label: '颜色',
                  width: 96,
                  value: (it) => UtenGoodsAttributeCell.text(
                    _dictText(names.color(it.colorId)),
                  ),
                  cellBuilder: (context, it) => UtenGoodsAttributeCell(
                    _dictText(names.color(it.colorId)),
                  ),
                ),
                // 收货/退货实物单据：库位号（主档带出，上架/拣货指引）。
                if (widget.docType == PurchaseDocType.receipt ||
                    widget.docType == PurchaseDocType.returnDoc)
                  MasterColumnDef(
                    key: 'stockPlace',
                    label: '库位号',
                    width: 90,
                    value: (it) =>
                        names.goodsInfo(it.goodsId)?.stockPlace ?? '—',
                  ),
                // 收货单逐行来源订货单编号（编号非 id；表头来源链可点跳详情）。
                if (widget.docType == PurchaseDocType.receipt)
                  MasterColumnDef(
                    key: 'orderBillNo',
                    label: '来源订货单',
                    width: 150,
                    value: (it) => it.orderBillNo ?? '',
                  ),
                MasterColumnDef(
                  key: 'giftQty',
                  label: '赠品数量',
                  width: 145,
                  type: 'number',
                  value: (it) =>
                      '${financeExactTrimmed(it.giftQtyText ?? it.giftQty?.toString()) ?? '—'}${it.quantitySemantics == procurementChargedPlusGiftQuantity ? '' : '（旧标记）'}',
                ),
                MasterColumnDef(
                  key: 'physicalQty',
                  label: '实物数量',
                  width: 155,
                  type: 'number',
                  value: (it) =>
                      '${it.recordedPhysicalQtyText ?? '数量未留存'} ${names.unit(it.unitId)}',
                ),
                MasterColumnDef(
                  key: 'qty',
                  label: '数量',
                  // 单位内联（2026-10-10 T9）：单位撤独立列，跟在数字后；改量输入
                  // 框同样带单位 suffix。
                  width: _canAdjustRequestQty || _qtyControllers.isNotEmpty
                      ? 150
                      : 110,
                  type: 'number',
                  value: qtyDisplayOf,
                  cellBuilderHandlesSemantics: true,
                  // V477：申请明细在分解前可直接改量（已订货/待审占用的行只读）。
                  cellBuilder: (context, it) =>
                      (_itemQtyEditable(it) ||
                          _qtyControllers.containsKey(it.id))
                      ? SizedBox(
                          width: 130,
                          child: TextField(
                            key: ValueKey('purchase-request-qty-${it.id}'),
                            controller: _qtyControllerOf(it),
                            enabled: !_busy && _itemQtyEditable(it),
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: UtenInputDecoration(
                              InputDecoration(
                                isDense: true,
                                labelText: '数量',
                                suffixText: unitOf(it),
                              ),
                            ),
                          ),
                        )
                      : Align(
                          alignment: Alignment.centerLeft,
                          child: Text(qtyDisplayOf(it)),
                        ),
                ),
                if (widget.docType != PurchaseDocType.request &&
                    canViewCommercialAmounts) ...[
                  MasterColumnDef(
                    key: 'price',
                    label: '单价',
                    width: hasTotalPricing ? 220 : 120,
                    type: 'money',
                    info: hasTotalPricing
                        ? '标注“参考”的单价由填写的总金额反算；除不尽时仅显示参考值，结算按单据记录的总金额。'
                        : null,
                    value: (it) =>
                        widget.docType == PurchaseDocType.order &&
                            it.totalAmountInputText != null
                        ? '${financeMoneyWithUnitSuffix(financeExactTrimmed(it.priceText ?? it.price?.toString()), currencyName: docCurrencyName)}（参考）'
                        : _historicalReceipt
                        ? financeMoneyWithUnitSuffix(
                            historicalReceiptAmount(it.priceText),
                            currencyName: docCurrencyName,
                          )
                        : financeMoneyWithUnitSuffix(
                            it.priceText,
                            currencyName: docCurrencyName,
                          ),
                  ),
                  MasterColumnDef(
                    key: 'amount',
                    label: _historicalReceipt
                        ? '原币金额'
                        : widget.docType == PurchaseDocType.order
                        ? '总金额'
                        : '金额',
                    width: 130,
                    type: 'money',
                    // 总金额计价保留服务端原文；记录缺失时不能回乘参考单价补造金额。
                    value: (it) =>
                        widget.docType == PurchaseDocType.order &&
                            it.totalAmountInputText != null
                        ? financeMoneyWithUnitSuffix(
                            it.amountOriginalText ?? it.amountLocalText,
                            currencyName: docCurrencyName,
                          )
                        : _historicalReceipt
                        ? financeMoneyWithUnitSuffix(
                            historicalReceiptAmount(it.amountOriginalText),
                            currencyName: docCurrencyName,
                          )
                        : financeMoneyWithUnitSuffix(
                            it.amountOriginalText ?? it.amountLocalText,
                            currencyName: docCurrencyName,
                          ),
                  ),
                  if (_historicalReceipt)
                    MasterColumnDef(
                      key: 'recordedLocalAmount',
                      label: '本币金额',
                      width: 180,
                      type: 'money',
                      // 恒本币：折合人民币金额带「元」后缀（历史「未知」原文不拼）。
                      value: (it) => financeLocalMoneyWithUnitSuffix(
                        historicalReceiptAmount(it.amountLocalText),
                      ),
                    ),
                ],
                if (_historicalReceipt)
                  MasterColumnDef(
                    key: 'recordedUnitRate',
                    label: '单位换算率',
                    width: 180,
                    value: (it) => historicalReceiptRate(it.unitRateText),
                  ),
                if (widget.docType == PurchaseDocType.request ||
                    widget.docType == PurchaseDocType.order) ...[
                  if (widget.docType == PurchaseDocType.request) ...[
                    MasterColumnDef(
                      key: 'approvedOrderQty',
                      label: '已批准订货',
                      width: 115,
                      type: 'number',
                      value: (it) => formatExactQtyWithUnit(
                        it.orderedQtyText ?? it.orderedQty?.toString(),
                        unitOf(it),
                      ),
                    ),
                    MasterColumnDef(
                      key: 'pendingOrderQty',
                      label: '在审/退回占用',
                      info: '已提交财务审核或财务退回待修订的原订货单仍占用这部分来源；取消、删除或修订减量后才释放对应份额。',
                      width: 115,
                      type: 'number',
                      value: (it) => formatExactQtyWithUnit(
                        it.pendingQtyText ?? it.pendingQty?.toString(),
                        unitOf(it),
                      ),
                    ),
                    MasterColumnDef(
                      key: 'remainingOrderQty',
                      label: '可继续采购(收费)',
                      width: 115,
                      type: 'number',
                      value: (it) => formatExactQtyWithUnit(
                        _remainingRequestQtyText(it),
                        unitOf(it),
                      ),
                    ),
                    MasterColumnDef(
                      key: 'remainingGiftOrderQty',
                      label: '待补赠品',
                      width: 115,
                      type: 'number',
                      value: (it) => formatExactQtyWithUnit(
                        it.hasExtraGift ? it.remainingGiftQtyText : '0',
                        unitOf(it),
                      ),
                    ),
                    MasterColumnDef(
                      key: 'physicalApprovedOrderQty',
                      label: '已批准实物',
                      width: 120,
                      type: 'number',
                      value: (it) => formatExactQtyWithUnit(
                        _physicalRequestCommitmentText(it, pending: false),
                        unitOf(it),
                      ),
                    ),
                    MasterColumnDef(
                      key: 'physicalPendingOrderQty',
                      label: '待财审实物',
                      width: 120,
                      type: 'number',
                      value: (it) => formatExactQtyWithUnit(
                        _physicalRequestCommitmentText(it, pending: true),
                        unitOf(it),
                      ),
                    ),
                    MasterColumnDef(
                      key: 'physicalRemainingOrderQty',
                      label: '待补实物',
                      width: 120,
                      type: 'number',
                      value: (it) {
                        final text = _remainingPhysicalRequestText(it);
                        return text == null
                            ? '实物剩余未核定'
                            : formatExactQtyWithUnit(text, unitOf(it));
                      },
                    ),
                  ],
                  MasterColumnDef(
                    // 2026-09-25 单号列统一：明细全量加载，就地排序+按值筛选。
                    key: 'planNo',
                    sortable: true,
                    filterFromRows: true,
                    label: '生产计划',
                    width: 130,
                    value: (it) => it.productionPlanNo ?? '',
                  ),
                  MasterColumnDef(
                    key: 'salesOrderNo',
                    sortable: true,
                    filterFromRows: true,
                    label: '销售订单',
                    width: 150,
                    value: (it) => it.salesOrderNo ?? '',
                  ),
                  // V463：合并订货行的来源申请单号（多来源顿号连接，单来源一条）。
                  if (widget.docType == PurchaseDocType.order)
                    MasterColumnDef(
                      key: 'sourceRequests',
                      sortable: true,
                      filterFromRows: true,
                      label: '申请来源',
                      width: 170,
                      value: (it) => it.sourceRequests
                          .map((source) => source.billNo)
                          .whereType<String>()
                          .where((no) => no.isNotEmpty)
                          .join('、'),
                    ),
                ],
                if (widget.docType == PurchaseDocType.order) ...[
                  MasterColumnDef(
                    key: 'supplier',
                    label: '供应商',
                    width: 170,
                    value: (_) => names.supplier(d.supplierId),
                  ),
                  if (canViewCommercialAmounts) ...[
                    MasterColumnDef(
                      key: 'currency',
                      label: '币种',
                      width: 110,
                      value: (_) => names.currency(d.currencyId),
                    ),
                    MasterColumnDef(
                      key: 'taxRate',
                      label: '税率(%)',
                      width: 100,
                      value: (_) => d.taxRate?.toString(),
                    ),
                    MasterColumnDef(
                      key: 'settlement',
                      label: '结账方式',
                      width: 150,
                      value: (_) {
                        for (final method
                            in settlementOptions.value ??
                                const <ReferenceMethodOption>[]) {
                          if (method.id == d.settlementMethodId) {
                            return method.name;
                          }
                        }
                        return d.settlementMethodId == null
                            ? '—'
                            : settlementOptions.isLoading
                            ? '加载中…'
                            : '未能解析(${d.settlementMethodId})';
                      },
                    ),
                  ],
                ],
                // ADR-144：订货行允许超收%（累计收货在 数量×(1+允许超收) 以内照常入库立应付，
                // 超出部分才转财务）。比例不是价格，不随价格遮蔽。
                if (_cfg.itemHasAllowedOverReceiptPct)
                  MasterColumnDef(
                    key: 'allowedOverReceiptPct',
                    label: '允许超收%',
                    width: 100,
                    type: 'number',
                    info:
                        '供应商累计送货最多可到 数量×(1+允许超收%)，在这以内照常入库、立应付；超出部分才转财务审批。未设 = 不允许超收。',
                    value: (it) => it.allowedOverReceiptPct == null
                        ? '未设'
                        : purchasePercentText(it.allowedOverReceiptPct!),
                  ),
                MasterColumnDef(
                  key: 'giftReceivedQty',
                  label: '已收赠品',
                  width: 130,
                  type: 'number',
                  value: (it) => it.giftReceivedQtyText ?? '—',
                ),
                MasterColumnDef(
                  key: 'giftReturnedQty',
                  label: '已退赠品',
                  width: 130,
                  type: 'number',
                  value: (it) => it.giftReturnedQtyText ?? '—',
                ),
                if (_cfg.showReceived)
                  MasterColumnDef(
                    key: 'received',
                    label: '已收',
                    width: 100,
                    type: 'number',
                    value: (it) =>
                        '${financeExactTrimmed(it.receivedQtyText ?? it.receivedQty?.toString()) ?? '—'} ${names.unit(it.unitId)}',
                  ),
                if (_cfg.showReturned)
                  MasterColumnDef(
                    key: 'returned',
                    label: '已退',
                    width: 100,
                    type: 'number',
                    value: (it) =>
                        '${financeExactTrimmed(it.returnedQtyText ?? it.returnedQty?.toString()) ?? '—'} ${names.unit(it.unitId)}',
                  ),
                MasterColumnDef(
                  key: 'remark',
                  label: '备注',
                  width: 220,
                  value: (it) => it.remark,
                ),
                ...businessReadOnlyColumns<PurchaseDocItem>(
                  items,
                  columnsOf: (line) => line.extraColumns,
                  priceMasked: !canViewCommercialAmounts,
                ),
              ],
              keyOf: (column) => column.key,
              enabled: widget.docType == PurchaseDocType.order,
            ),
            items: items,
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            // 右下悬浮操作组让位：末行可滚出按钮区。
            bottomContentPadding: UtenFloatingActionGroup.scrollClearance,
            emptyMessage: '暂无明细',
            // 明细下合计条（全站统一 summaryBar 槽位口径）：数量按单位分组，
            // 金额受商务金额门控；由表格统一挂在表体下方。
            summaryBar: items.isNotEmpty ? _totalsBar(names, items) : null,
          ),
        ),
      ],
    );
  }

  /// 明细表下的合计条：合计数量（按单位分组，绝不跨单位相加）+
  /// 合计金额（原币，标红）+ 合计（本币）。申请单无金额口径，仅出数量。
  Widget _totalsBar(MasterNameService names, List<PurchaseDocItem> items) {
    final d = _detail!;
    if (_historicalReceipt) {
      return HistoricalReceiptTotals(
        key: const Key('purchase-detail-totals'),
        showAmounts: _canViewCommercialAmounts,
        currencyLabel: names.currency(d.currencyId),
        lines: [
          for (final item in items)
            HistoricalReceiptLineFacts(
              quantity: item.qtyText,
              unitId: item.unitId,
              unitName: names.unit(item.unitId),
              original: item.amountOriginalText,
              local: item.amountLocalText,
            ),
        ],
      );
    }
    final showAmounts =
        _canViewCommercialAmounts && widget.docType != PurchaseDocType.request;
    final totalOriginal =
        d.totalOriginalText ??
        financeExactSumTexts(items.map((it) => it.amountOriginalText));
    return UtenTotalsSummaryBar(
      key: const Key('purchase-detail-totals'),
      density: true,
      compact: true,
      rowCount: items.length,
      entries: [
        UtenTotalEntry(
          '收费量 / 原数量',
          exactMeasurementTotalsText(
            items.map(
              (it) => ExactMeasuredAmount(
                value: it.qtyText ?? it.qty?.toString(),
                unitId: it.unitId,
                unitName: names.unit(it.unitId),
              ),
            ),
          ),
        ),
        UtenTotalEntry(
          '赠品量',
          exactMeasurementTotalsText(
            items.map(
              (it) => ExactMeasuredAmount(
                value: it.hasExtraGift
                    ? (it.giftQtyText ?? it.giftQty?.toString())
                    : '0',
                unitId: it.unitId,
                unitName: names.unit(it.unitId),
              ),
            ),
          ),
        ),
        UtenTotalEntry(
          '实物量',
          exactMeasurementTotalsText(
            items.map(
              (it) => ExactMeasuredAmount(
                value: it.recordedPhysicalQtyText,
                unitId: it.unitId,
                unitName: names.unit(it.unitId),
              ),
            ),
          ),
        ),
        if (showAmounts) ...[
          UtenTotalEntry(
            utenAmountTotalLabel(
              _cfg.hasCurrency
                  ? financeCurrencyDisplayLabel(
                      name: names.currency(d.currencyId),
                    )
                  : null,
            ),
            financeExactMoneyDisplay(totalOriginal),
            danger: true,
          ),
          UtenTotalEntry('合计(本币)', financeExactMoneyDisplay(d.totalLocalText)),
        ],
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
                    ? '$reason\n此申请由计划部下达；分解前可在明细表直接修正数量（已生成订货单的行除外），再在本页或任务中心生成订货单。'
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
    if (_detail!.status == kPurchaseStatusCanceled ||
        _detail!.status == kPurchaseStatusReversed) {
      return switch (approval.status) {
        'REJECTED' => '历史审批：财务已退回',
        'APPROVED' => '历史审批：财务已通过',
        _ => '原审批已结束',
      };
    }
    return switch (approval.status) {
      'DRAFT' => '未提交财务',
      'PENDING' => '等待财务审核组审核',
      'REJECTED' => '财务已退回，等待采购修改',
      'APPROVED' => '财务已通过',
      'CANCELED' => '审批已取消',
      'LEGACY_EFFECTIVE' => '历史已生效',
      'LEGACY_REVERSED' => '历史已反审',
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
    final reviewing = _detail!.status == kPurchaseStatusApproved;
    final title = reviewing
        ? (rejected ? '改量财务已退回，请修订后重新提交' : '改量等待财务复核')
        : (rejected ? '财务已退回，请修改后重新提交' : '等待财务审核组处理');
    final detail = rejected
        ? (approval.rejectionReason ?? '财务未填写退回原因')
        : '审核期间仅可查看，财务将在订货审批中处理。';
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
    // 「返回列表」显隐随权限快照即时刷新（_canOpenList 用 read，这里挂 watch）。
    ref.watch(currentPermissionsProvider);
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
      if (_canOpenList) {
        addAction(
          UtenButton(
            type: UtenButtonType.secondary,
            size: UtenButtonSize.large,
            onPressed: () => popOrBackTo(context, defaultPath: _listPath),
            child: const Text('返回列表'),
          ),
        );
      }
      // Only selected still-available sources enter the shared decomposition flow.
      // The backend rechecks quantity and ownership when opening and saving the order.
      // 2026-09-19 口径：主操作红色（danger）且排组内最右（贴近屏幕右缘），
      // 与财审/批量审批等页「secondary 返回在左、红主钮在右」全站一致。
      if (_canGenerateRequestOrder && d.items.isNotEmpty) {
        addAction(
          UtenButton(
            key: const Key('purchase-request-generate-order'),
            type: UtenButtonType.danger,
            size: UtenButtonSize.large,
            icon: Icons.add_shopping_cart_rounded,
            isLoading: _openingOrder,
            onPressed:
                _selectedRequestItemIds.isEmpty ||
                    _busy ||
                    _changedQtyItems.isNotEmpty
                ? null
                : _generateSelectedOrder,
            onDisabledTap: () => context.appInfo(
              _changedQtyItems.isNotEmpty ? '请先保存明细数量的修改' : '请先勾选本次需要采购的明细',
            ),
            child: const Text('按所选生成采购订货单'),
          ),
        );
      }
    } else if (widget.docType == PurchaseDocType.order) {
      final approval = d.financeApproval;
      final pending = approval?.isPending == true;
      if (s == kPurchaseStatusDraft && !pending && _canDelete && d.canDelete) {
        addAction(
          UtenButton(
            type: UtenButtonType.danger,
            size: UtenButtonSize.large,
            icon: Icons.delete_outline,
            onPressed: _delete,
            child: const Text('删除'),
          ),
        );
      }
      if (s == kPurchaseStatusDraft && !pending && _canEdit && d.canEdit) {
        addAction(
          UtenButton(
            type: UtenButtonType.secondary,
            size: UtenButtonSize.large,
            icon: Icons.edit_outlined,
            onPressed: () => context.push(
              RoutePath.purchaseDocEdit(_cfg.type.pathSegment, widget.id),
            ),
            child: const Text('编辑'),
          ),
        );
      }
      // 取消订单（2026-09-05）：草稿单即可取消——含在审单（同步撤回财务审核
      // 任务与弹卡）；财务驳回后的草稿同样可取消。
      if (s == kPurchaseStatusDraft &&
          _ordinaryWritable &&
          _hasPermission(Perm.purchaseOrderCancel)) {
        addAction(
          UtenButton(
            type: UtenButtonType.danger,
            size: UtenButtonSize.large,
            icon: Icons.block_outlined,
            onPressed: _cancelOrder,
            child: const Text('取消订单'),
          ),
        );
      }
      if (s == kPurchaseStatusDraft &&
          !pending &&
          _ordinaryWritable &&
          _hasPermission(Perm.purchaseOrderSubmitFinance) &&
          approval?.canSubmit == true) {
        addAction(
          UtenButton(
            size: UtenButtonSize.large,
            icon: Icons.send_outlined,
            onPressed: _submitFinance,
            child: Text(approval?.isRejected == true ? '重新提交财务' : '提交财务审核'),
          ),
        );
      }
      // 批准后改量（2026-09-05）：财务批准后的订货单逐行改数量，
      // 改后自动重回财务复核；无 PENDING 审批任务时可操作。
      if (s == kPurchaseStatusApproved && _canChangeQty) {
        addAction(
          UtenButton(
            key: const Key('purchase-order-change-qty'),
            type: UtenButtonType.secondary,
            size: UtenButtonSize.large,
            icon: Icons.edit_note_outlined,
            onPressed: _changeQty,
            child: Text(AppLocalizations.of(context).orderChangeQtyButton),
          ),
        );
      }
      if (s == kPurchaseStatusApproved && _canReverse) {
        addAction(
          DocumentUnapprovalAction(
            family: unapprovalFamilyForRoute(
              'purchase',
              widget.docType.pathSegment,
            )!,
            documentId: widget.id,
            revision: d,
            onPressed: _reverse,
          ),
        );
      }
      if (children.isEmpty) {
        addAction(
          UtenButton(
            type: UtenButtonType.secondary,
            size: UtenButtonSize.large,
            onPressed: () =>
                popOrBackTo(context, defaultPath: _defaultBackPath),
            child: Text(_returnLabel),
          ),
        );
      }
    } else if (s == kPurchaseStatusDraft) {
      if (_canDelete && d.canDelete) {
        children.add(
          UtenButton(
            type: UtenButtonType.danger,
            size: UtenButtonSize.large,
            icon: Icons.delete_outline,
            onPressed: _delete,
            child: const Text('删除'),
          ),
        );
      }
      if (_canEdit && d.canEdit) {
        if (children.isNotEmpty) {
          children.add(const SizedBox(width: UtenSpacing.s8));
        }
        children.add(
          UtenButton(
            type: UtenButtonType.secondary,
            size: UtenButtonSize.large,
            icon: Icons.edit_outlined,
            onPressed: () => context.push(
              RoutePath.purchaseDocEdit(_cfg.type.pathSegment, widget.id),
            ),
            child: const Text('编辑'),
          ),
        );
      }
      if (_canApprove) {
        if (children.isNotEmpty) {
          children.add(const SizedBox(width: UtenSpacing.s8));
        }
        children.add(
          UtenButton(
            size: UtenButtonSize.large,
            icon: Icons.check_circle_outline,
            onPressed: _approveDocument,
            child: const Text('审核'),
          ),
        );
      }
      if (children.isEmpty && _canOpenList) {
        children.add(
          UtenButton(
            type: UtenButtonType.secondary,
            size: UtenButtonSize.large,
            onPressed: () => popOrBackTo(context, defaultPath: _listPath),
            child: const Text('返回列表'),
          ),
        );
      }
    } else if (s == kPurchaseStatusApproved && _canReverse) {
      children.add(
        DocumentUnapprovalAction(
          family: unapprovalFamilyForRoute(
            'purchase',
            widget.docType.pathSegment,
          )!,
          documentId: widget.id,
          revision: d,
          onPressed: _reverse,
        ),
      );
    } else if (_canOpenList) {
      children.add(
        UtenButton(
          type: UtenButtonType.secondary,
          size: UtenButtonSize.large,
          onPressed: () => popOrBackTo(context, defaultPath: _listPath),
          child: const Text('返回列表'),
        ),
      );
    }
    if (children.isEmpty) return const SizedBox.shrink();
    // 2026-09-14 UI 统一口径：底部吸底操作条改右下悬浮组（UtenFloatingActionGroup），
    // 按钮统一 large 尺寸；SizedBox 间距占位是历史写法，这里过滤掉（组自带 8px 间距）。
    return UtenFloatingActionGroup(
      children: [
        // 已选胶囊随悬浮组首位（2026-10-04 全站口径：已选恒右下悬浮，不驻表头），
        // 与「按所选生成采购订货单」同框；✕ 清空勾选。
        if (_canGenerateRequestOrder)
          UtenSelectionSummaryPill(
            count: _selectedRequestItemIds.length,
            onClear: _selectedRequestItemIds.isEmpty || _busy
                ? null
                : () => setState(_selectedRequestItemIds.clear),
          ),
        ...children.where((child) => child is! SizedBox),
      ],
    );
  }
}

/// 字典未命中时 MasterNameService 返回「—」：身份格不显示这类占位词，统一转 null
/// （组件会自然省略该项）。
String? _dictText(String value) => value == '—' ? null : value;

/// 明细货品身份文本（名称 + 编号 · 颜色 · 单位）：与格内渲染同源，
/// 排序/筛选/导出/语义标签和眼睛看到的一致。
class _KV {
  const _KV(this.label, this.value, {this.badge});
  final String label;
  final String? value;
  final Widget? badge;
}
