// 仓库批量登记实际到货页（/warehouse/inbound/receipts/batch）。
//
// 入库任务中心「预计到货」多选「批量登记送检」的落点（2026-09-06）：把多张
// 采购/委外订货单的待登记明细汇成一张行级表——本次实收默认=批准剩余、入库仓库
// 行级必填（建议仓预填，勾选后可用表格批量动作「批量设置入库仓库」「批量填写库位」
// 一次落仓/写库位，未勾选时作用于全部明细行），一次提交按
// 「订货单 × 入库仓库」分组逐张登记并送检（与单张登记页同一条
// registerArrival + 内容派生幂等键链路；部分失败可原地重试不重复登记）。
// 仅断点「已登记 · 待送检」的草稿单不走本页（列表内直接批量送检）。
import 'dart:async';

import 'package:flutter/material.dart';
import '../../../shared/widgets/warehouse_selection.dart';
import '../../../shared/presentation/workflow_field_guidance.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_totals_summary_bar.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_autofill_text_controller.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../department/models/department_node.dart';
import '../../department/repositories/department_repository.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../purchase/config/purchase_doc_config.dart';
import '../../purchase/models/purchase_doc.dart';
import '../../subcontract/config/subcontract_doc_config.dart';
import '../../subcontract/models/subcontract_doc.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/measurement/measurement_totals.dart';
import '../../../shared/models/inbound_allocation.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/widgets/warehouse_picker_panel.dart';
import '../providers/warehouse_count_refresh.dart';
import '../widgets/batch_place_fill_dialog.dart';
import '../widgets/warehouse_autofill_text_field.dart';
import '../widgets/warehouse_arrival_source_field.dart';
import '../repositories/procurement_inbound_repository.dart';

class WarehouseArrivalBatchReceiptPage extends ConsumerStatefulWidget {
  const WarehouseArrivalBatchReceiptPage({
    super.key,
    this.prefills,
    this.canRegister,
  });

  /// 入库任务中心多选带入的预计到货预填（每张=一张订货单）；空 = 直达兜底。
  final List<ProcurementReceiptPrefill>? prefills;

  /// 仅供独立预览/测试覆盖；正式路由为空时从当前登录权限实时推导。
  final bool? canRegister;

  @override
  ConsumerState<WarehouseArrivalBatchReceiptPage> createState() =>
      _WarehouseArrivalBatchReceiptPageState();
}

class _WarehouseArrivalBatchReceiptPageState
    extends ConsumerState<WarehouseArrivalBatchReceiptPage> {
  final _remark = TextEditingController();
  final _scrollCtl = ScrollController();
  final _lineGrid = UtenEditableGridController<_BatchArrivalLine>();
  final Map<String, UtenEmployeePickerItem> _empCache = {};

  DateTime _billDate = ChinaDateTime.today();
  String? _receiverId;
  bool _loading = false;
  bool _saving = false;
  final String _registrationId = const Uuid().v4();
  int _removedLineCount = 0;

  bool get _canRegisterNow {
    final override = widget.canRegister;
    if (override != null) return override;
    if (ref.read(isSuperAdminProvider)) return true;
    final permissions = ref.read(currentPermissionsProvider);
    return permissions.contains(Perm.warehouseInboundView) &&
        permissions.contains(Perm.warehouseInboundStockIn);
  }

  List<_BatchArrivalLine> get _lines => _lineGrid.rows;

  String? _warehouseLabel(String? id) {
    if (id == null || id.isEmpty) return null;
    final names = ref.read(masterNameServiceProvider);
    return warehouseFullLabel(names.warehouseHierarchy, id) ??
        names.warehouse(id);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _remark.dispose();
    _scrollCtl.dispose();
    _lineGrid.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final prefills = widget.prefills;
    if (prefills == null || prefills.isEmpty) return;
    setState(() => _loading = true);
    await ref.read(masterNameServiceProvider).ensureLoaded();
    final meId = ref.read(sessionProvider).user?.employeeId;
    if (meId != null && meId.isNotEmpty) {
      _receiverId = meId;
      await _preloadEmployees([meId]);
    }
    _lineGrid.replaceAll([
      for (final prefill in prefills)
        for (final item in prefill.items)
          _BatchArrivalLine(prefill, item, onChanged: _onLineChanged),
    ]);
    final selectable = WarehouseSelection(
      ref.read(masterNameServiceProvider).warehouseHierarchy,
    ).selectableIds;
    for (final line in _lineGrid.rows) {
      if (!selectable.contains(line.warehouseId)) {
        line.warehouseId = null;
        line.warehouseAutofilled = false;
      }
    }
    _removedLineCount = 0;
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _preloadEmployees(Iterable<String?> ids) async {
    final uniq = ids.whereType<String>().where((id) => id.isNotEmpty).toSet();
    if (uniq.isEmpty) return;
    final repo = ref.read(employeeRepositoryProvider);
    await Future.wait(
      uniq.map((id) async {
        try {
          final p = await repo.getById(id);
          _empCache[id] = UtenEmployeePickerItem(
            id: p.id,
            name: p.fullName ?? '',
            employeeCode: p.code,
            departmentName: p.departmentName,
          );
        } catch (_) {}
      }),
    );
  }

  void _onLineChanged() {
    if (mounted) setState(() {});
  }

  /// 仅从本次批量登记移出：不写库、不改订货或到货累计（返回任务中心仍待登记）。
  void _removeFromThisRegistration(List<_BatchArrivalLine> rows) {
    if (_saving || !_canRegisterNow || rows.isEmpty) return;
    _lineGrid.removeRows(rows);
    if (!mounted) return;
    setState(() => _removedLineCount += rows.length);
    context.appInfo('已从本次登记移出 ${rows.length} 行；未写入数据库，返回任务中心后仍可继续登记送检');
  }

  /// 表格批量动作：勾选若干行后一次设仓 / 一次填库位。
  /// 表格上方的「统一设置入库仓库」按钮 2026-09-11 撤除，能力搬到这里；未勾选
  /// 任何行时沿用它的旧口径作用于全部明细行（计数即作用行数，按钮上可见）。
  List<Widget> _buildBatchActions(
    BuildContext context,
    UtenEditableGridController<_BatchArrivalLine> controller,
  ) {
    final selected = controller.selectedRows;
    final targets = selected.isEmpty ? _lines : selected;
    final count = targets.length;
    return [
      Tooltip(
        message: '把选中行的入库仓库一次设成同一个仓；未勾选时作用于全部明细行，行内仍可单独改仓',
        child: UtenButton(
          key: const Key('warehouse-arrival-batch-apply-warehouse-all'),
          size: UtenButtonSize.large,
          icon: Icons.warehouse_outlined,
          onPressed: _saving || count == 0
              ? null
              : () => _applyWarehouseToLines(targets),
          child: Text('批量设置入库仓库($count)'),
        ),
      ),
      Tooltip(
        message: '一次输入库位号应用到选中行（整托同架场景）；未勾选时作用于全部明细行',
        child: UtenButton(
          key: const Key('warehouse-arrival-batch-place'),
          type: UtenButtonType.secondary,
          size: UtenButtonSize.large,
          icon: Icons.edit_note_outlined,
          onPressed: _saving || count == 0
              ? null
              : () => _batchFillPlace(targets),
          child: Text('批量填写库位($count)'),
        ),
      ),
    ];
  }

  /// 批量落仓：一次写入全部目标行（行内仍可单独改；建议仓预填会被覆盖）。
  /// 批量写入视同已核对，清掉学习预填的黄标。
  Future<void> _applyWarehouseToLines(List<_BatchArrivalLine> rows) async {
    if (_saving || rows.isEmpty) return;
    final whole = rows.length == _lines.length;
    final picked = await showUtenWarehousePickerPanel(
      context,
      hierarchy: ref.read(masterNameServiceProvider).warehouseHierarchy,
      title: '批量设置入库仓库（${whole ? '全部' : '选中'} ${rows.length} 行）',
    );
    if (picked == null || !mounted) return;
    setState(() {
      for (final line in rows) {
        line.warehouseId = picked.id;
        line.warehouseAutofilled = false;
      }
    });
  }

  /// 批量填库位：复用产成品登记页同一个弹窗（不另写校验），一次输入写入全部目标行。
  Future<void> _batchFillPlace(List<_BatchArrivalLine> rows) async {
    if (_saving || rows.isEmpty) return;
    final place = await showBatchPlaceFillDialog(
      context,
      rowCount: rows.length,
      inputKey: const Key('warehouse-arrival-batch-place-input'),
      applyKey: const Key('warehouse-arrival-batch-place-apply'),
    );
    if (place == null || !mounted) return;
    if (place.isEmpty) {
      context.appWarning('库位号不能为空');
      return;
    }
    setState(() {
      for (final line in rows) {
        line.setCheckedStockPlace(place);
      }
    });
  }

  Future<void> _pickLineWarehouse(_BatchArrivalLine line) async {
    if (_saving) return;
    final suggested = line.prefill.suggestedWarehouseId;
    final picked = await showUtenWarehousePickerPanel(
      context,
      hierarchy: ref.read(masterNameServiceProvider).warehouseHierarchy,
      initialWarehouseId: line.warehouseId ?? suggested,
      title: '选择入库仓库 · ${line.item.goodsName}',
    );
    if (picked == null || !mounted) return;
    setState(() {
      line.warehouseId = picked.id;
      line.warehouseAutofilled = false;
    });
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// 按「订货单 × 入库仓库」分组（LinkedHashMap 保序）：每组一张收货单顺序登记。
  Map<String, List<_BatchArrivalLine>> _buildGroups() {
    final groups = <String, List<_BatchArrivalLine>>{};
    for (final line in _lines) {
      final key = '${line.prefill.orderId}:${line.warehouseId}';
      groups.putIfAbsent(key, () => []).add(line);
    }
    return groups;
  }

  /// 行级跨仓预定检测（实收超过所选仓的分析预定量）：确认框警示用。
  bool _hasCrossWarehouseAllocation() {
    for (final line in _lines) {
      final qty = double.tryParse(line.qty.text.trim()) ?? 0;
      final allocations = warehouseInboundAllocationForWarehouse(
        line.item.expectedAllocations,
        qty,
        actualWarehouseId: line.warehouseId,
        actualWarehouseName: _warehouseLabel(line.warehouseId) ?? '',
        sameMainWarehouse: (target, actual) => warehousesShareMain(
          ref.read(masterNameServiceProvider).warehouseHierarchy,
          target,
          actual,
        ),
        unitRate: line.item.unitRate.toDouble(),
      );
      if (allocations.any((a) => a.isCrossWarehouse)) return true;
    }
    return false;
  }

  Future<void> _save() async {
    if (!_canRegisterNow) {
      context.appError('当前账号没有登记并送检权限，请返回任务中心刷新权限');
      return;
    }
    if (_receiverId == null || _receiverId!.isEmpty) {
      context.appError('请选择收货人(仓库收货人)');
      return;
    }
    if (_lines.isEmpty) {
      context.appError('没有可登记明细，请返回任务中心刷新');
      return;
    }
    for (final line in _lines) {
      final qty = double.tryParse(line.qty.text.trim()) ?? 0;
      if (qty <= 0) {
        context.appError('${line.item.goodsName} 的本次实收必须大于 0');
        return;
      }
      if (line.warehouseId == null || line.warehouseId!.isEmpty) {
        context.appError('请为 ${line.item.goodsName} 选择入库仓库');
        return;
      }
    }
    // 采购收货单必须有采购员（批量页取订货负责人预填，不可编辑）。
    final missingPurchaser = _lines
        .where(
          (line) =>
              line.prefill.orderType == ProcurementInboundOrderType.purchase &&
              (line.prefill.purchaserId?.isNotEmpty != true),
        )
        .map((line) => line.prefill.orderBillNo)
        .toSet();
    if (missingPurchaser.isNotEmpty) {
      context.appError('订货单 ${missingPurchaser.join('、')} 缺少采购员，请先在单张登记页处理');
      return;
    }
    final groups = _buildGroups();
    final hasCrossWarehouse = _hasCrossWarehouseAllocation();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('批量登记送检（${groups.length} 张收货单）'),
        content: Text(
          '将按 ${groups.length} 个「订货单 × 入库仓库」组合分别建立收货单，'
          '并在同一事务内登记到货、直接送品质部待检(IQC)：'
          '检验合格后转仓库待入库任务，仓库确认实物与库位后库存才增加。'
          '${hasCrossWarehouse ? '部分行的本次实收超过所选入库仓的分析预定量，跨仓部分只作预计、将转公共库存；' : ''}'
          '实到超过财务批准量的单会自动隔离并通知财务审核组，不会入库、不会生成应付，'
          '也不影响其余单继续送检。',
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.fact_check_outlined),
            label: const Text('确认登记送检'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _saving = true);
    final registrations = <WarehouseArrivalRegistration>[];
    try {
      final repo = ref.read(procurementInboundRepositoryProvider);
      for (final entry in groups.entries) {
        final lines = entry.value;
        final first = lines.first;
        final prefill = first.prefill;
        final isPurchase =
            prefill.orderType == ProcurementInboundOrderType.purchase;
        // 幂等键按「订货单+仓库+行+数量」内容派生：响应丢失重试复用同键安全
        // 重放；部分失败后原地重试，已成功组合按同键重放、不会重复登记。
        final canonical = [
          _registrationId,
          '${prefill.orderType.name}:${entry.key}',
          for (final line in lines)
            '${line.item.orderItemId}:${(double.tryParse(line.qty.text.trim()) ?? 0)}'
                '${line.source.apiValue == null ? '' : ':${line.source.apiValue}'}',
        ].join('|');
        final body = <String, dynamic>{
          'idempotencyKey': businessIdempotencyKey(
            'warehouse-arrival-create',
            canonical,
          ),
          'billDate': _fmt(_billDate),
          'warehouseId': lineWarehouseOf(lines),
          'supplierId': prefill.supplierId,
          'remark': _remark.text.trim().isEmpty ? null : _remark.text.trim(),
          if (isPurchase) ...{
            'purchaserId': prefill.purchaserId,
            'receiverEmployeeId': _receiverId,
          } else
            // 委外进仓单主档仅 sender_id 一个人员列（按「收货人」语义解析）。
            'receiverEmployeeId': _receiverId,
          'items': [
            for (final line in lines)
              {
                'goodsId': line.item.goodsId,
                'qty': double.tryParse(line.qty.text.trim()) ?? 0,
                'orderItemId': line.item.orderItemId,
                if (line.source.apiValue != null)
                  'replacementIntent': line.source.apiValue,
                'sourceDocNo': prefill.orderBillNo,
                if (line.item.colorId != null) 'colorId': line.item.colorId,
                if (line.item.unitId != null) 'unitId': line.item.unitId,
                if (!isPurchase) 'unitRate': line.item.unitRate,
              },
          ],
        };
        try {
          registrations.add(
            await repo.registerArrival(
              orderType: prefill.orderType,
              body: body,
            ),
          );
        } on ApiException catch (e) {
          if (!mounted) return;
          if (registrations.isNotEmpty) {
            context.appError(
              '已登记送检 ${registrations.length} 张收货单；'
              '订货单「${prefill.orderBillNo}」仓库'
              '「${_warehouseLabel(lineWarehouseOf(lines)) ?? '—'}」登记失败：${e.message}。'
              '可直接重试，已成功部分不会重复登记',
            );
          } else {
            context.appError(e.message);
          }
          return;
        }
      }
      unawaited(_learnGoodsProfiles());
      if (!mounted) return;
      bumpListRefresh(
        ref,
        PurchaseDocConfig.by(PurchaseDocType.receipt).refreshKey,
      );
      bumpListRefresh(
        ref,
        SubcontractDocConfig.by(SubcontractDocType.receipt).refreshKey,
      );
      invalidateWarehouseTaskCounts(ref);
      final batch = WarehouseArrivalRegistrationBatch(
        registrations: registrations,
      );
      if (context.canPop()) {
        context.pop(batch);
      } else {
        context.go(RouteName.warehouseInboundExpectations);
      }
    } catch (_) {
      if (mounted) context.appError('批量登记送检失败，请保持当前内容后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? lineWarehouseOf(List<_BatchArrivalLine> lines) =>
      lines.first.warehouseId;

  /// 学习回写（best-effort）：仅上报用户实际填了值的字段；失败不阻断主流程。
  Future<void> _learnGoodsProfiles() async {
    final hints = <Map<String, dynamic>>[
      for (final line in _lines)
        {
          'goodsId': line.item.goodsId,
          if (line.goodsCode.text.trim().isNotEmpty)
            'goodsCode': line.goodsCode.text.trim(),
          if (line.series.text.trim().isNotEmpty)
            'series': line.series.text.trim(),
          if (line.stockPlace.text.trim().isNotEmpty)
            'stockPlace': line.stockPlace.text.trim(),
        },
    ];
    if (hints.isEmpty) return;
    try {
      await ref
          .read(procurementInboundRepositoryProvider)
          .saveGoodsProfileHints(hints);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canRegister = widget.canRegister ?? _canRegisterNow;
    return Scaffold(
      appBar: UtenAppBar(
        title: '批量登记实际到货',
        leading: UtenBackButton(
          onPressed: () => popOrBackTo(
            context,
            defaultPath: RouteName.warehouseInboundExpectations,
          ),
        ),
      ),
      body: SafeArea(
        child: _lines.isEmpty && !_loading
            ? _missingPrefill(context)
            : _loading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
            : AbsorbPointer(
                absorbing: _saving || !canRegister,
                child: _buildForm(context, theme, canRegister),
              ),
      ),
      bottomNavigationBar: _lines.isEmpty
          ? null
          : _buildBottomBar(theme, canRegister),
    );
  }

  Widget _missingPrefill(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.local_shipping_outlined, size: 40),
          const SizedBox(height: UtenSpacing.s12),
          const Text('请从「入库任务中心」多选预计到货任务后批量登记'),
          const SizedBox(height: UtenSpacing.s16),
          UtenButton(
            type: UtenButtonType.tonal,
            icon: Icons.arrow_back_rounded,
            onPressed: () => context.go(RouteName.warehouseInboundTasks),
            child: const Text('返回任务中心'),
          ),
        ],
      ),
    );
  }

  Widget _buildForm(BuildContext context, ThemeData theme, bool canRegister) {
    return UtenContentContainer(
      child: Scrollbar(
        controller: _scrollCtl,
        thumbVisibility: true,
        child: ListView(
          controller: _scrollCtl,
          padding: const EdgeInsets.all(UtenSpacing.s12),
          children: [
            _banner(theme),
            const SizedBox(height: UtenSpacing.s12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(UtenSpacing.s12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    UtenFormGrid(
                      children: [
                        UtenDateField(
                          label: '单据日期',
                          required: true,
                          value: _billDate,
                          onChanged: (d) => setState(() => _billDate = d),
                        ),
                        _employeePicker(
                          label: '收货人',
                          currentId: _receiverId,
                          onChanged: (id) => setState(() => _receiverId = id),
                        ),
                      ],
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                    TextField(
                      controller: _remark,
                      decoration: const InputDecoration(labelText: '备注'),
                      maxLines: 2,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            // 「明细(N 行)」标题与表格上方的「统一设置入库仓库」按钮 2026-09-11
            // 一并撤除（落仓/填库位改由表格操作条的批量动作承载）：这里只留
            // 跨单据聚合信息（几张订货单合并到本批），看表体数不出来。
            Text(
              '来自 $_orderCount 张订货单',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            UtenEditableGrid<_BatchArrivalLine>(
              key: const Key('warehouse-arrival-batch-lines-grid'),
              controller: _lineGrid,
              columns: _lineColumns,
              createBlankRow: () => throw UnsupportedError('明细由所选预计到货任务固定带入'),
              showAddRow: false,
              showRowDelete: false,
              selectable: canRegister,
              selectionEnabled: canRegister && !_saving,
              onRemoveRows: canRegister ? _removeFromThisRegistration : null,
              removeRowsActionLabel: '移出本次登记',
              removeRowsDialogTitle: '移出本次登记',
              removeRowsConfirmLabel: '确认移出',
              removeRowsMessageBuilder: (count) =>
                  '确认从本次登记移出选中的 $count 行？'
                  '该操作不删除订货明细、不改变库存或历史；返回任务中心后仍保持待登记送检。',
              batchActionsBuilder: canRegister ? _buildBatchActions : null,
              emptyMessage: '没有可登记明细，请返回任务中心刷新',
              footer: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _lineTotalsBar(),
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    _removedLineCount == 0
                        ? '本次实收默认=批准剩余量，可改；入库仓库行级必填（建议仓已预填）。'
                              '库位、系列、编码由货品资料带出，送检后会学习回写。'
                        : '已移出 $_removedLineCount 行（仅本页临时选择）；这些来源行未写收货、未写库存，仍在待登记送检。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: UtenSpacing.s24),
          ],
        ),
      ),
    );
  }

  int get _orderCount =>
      _lines.map((line) => line.prefill.orderId).toSet().length;

  Widget _banner(ThemeData theme) {
    return Semantics(
      container: true,
      label: '按实际到货数量登记；提交后直接送品质部待检。超量部分自动隔离待财务定案。',
      child: Card(
        color: theme.colorScheme.tertiaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.fact_check_outlined,
                color: theme.colorScheme.onTertiaryContainer,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(
                  '批量登记 · $_orderCount 张订货单：本次实收默认=批准剩余量；'
                  '入库仓库逐行必填。提交后按「订货单 × 入库仓库」分组建收货单并直接送检，'
                  '实到超量部分自动隔离待财务定案，不会入库、不会生成应付。',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 表头筛选桶标签：空白与主档未解析的「—」不建桶（返回 null → 计入「未填」）。
  String? _bucketOrNull(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == '—') return null;
    return trimmed;
  }

  // 2026-09-11 全站表头快速筛选补齐：批量到货一次拉进多张订货单的上百行，
  // 来源订货单/类型/货品/颜色/单位/入库仓库给表头快速筛选（视图级过滤，
  // 不动行数据、输入值与勾选）。数量/库位等录入列不做筛选。
  List<EditableGridColumn<_BatchArrivalLine>> get _lineColumns => [
    EditableGridColumn(
      key: 'order',
      label: '来源订货单',
      width: 150,
      filterValueOf: (line) => _bucketOrNull(line.prefill.orderBillNo),
      cellBuilder: (context, line) => Tooltip(
        message:
            '${line.prefill.orderType.label} · ${line.prefill.orderBillNo}',
        child: Text(
          line.prefill.orderBillNo,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      textOf: (line) => line.prefill.orderBillNo,
    ),
    EditableGridColumn(
      key: 'orderType',
      label: '类型',
      width: 80,
      filterValueOf: (line) => line.prefill.orderType.label,
      textOf: (line) => line.prefill.orderType.label,
      cellBuilder: (context, line) => Text(line.prefill.orderType.label),
    ),
    EditableGridColumn(
      key: 'goods',
      label: '货品',
      width: 210,
      filterValueOf: (line) =>
          _bucketOrNull('${line.item.goodsName}(${line.item.goodsCode})'),
      textOf: (line) => '${line.item.goodsName}(${line.item.goodsCode})',
      cellBuilder: (context, line) => Tooltip(
        message: '${line.item.goodsName}(${line.item.goodsCode})',
        child: Text(
          '${line.item.goodsName}(${line.item.goodsCode})',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ),
    EditableGridColumn(
      key: 'color',
      label: '颜色',
      width: 100,
      filterValueOf: (line) => _bucketOrNull(line.item.colorName),
      textOf: (line) => line.item.colorName ?? '—',
      cellBuilder: (context, line) => Text(line.item.colorName ?? '—'),
    ),
    EditableGridColumn(
      key: 'approvedRemainingQty',
      label: '批准剩余',
      width: 100,
      numeric: true,
      cellBuilder: (context, line) => Text(
        procurementQty(line.item.approvedRemainingQty),
        textAlign: TextAlign.right,
      ),
    ),
    EditableGridColumn(
      key: 'arrivalSource',
      label: workflowFieldText(context).warehouseArrivalSourceLabel,
      width: 165,
      // 每行相同的通用说明放列头 ⓘ（2026-09-10 全站口径）：格内只留行特有的
      // 错误/预填图标，来源下拉不再自带 44px 说明图标挤占选项文案。
      headerInfo: workflowFieldText(context).warehouseArrivalSourceHint,
      textOf: (line) => line.source.label(context),
      cellBuilder: (context, line) => WarehouseArrivalSourceField(
        key: ValueKey(
          'warehouse-arrival-batch-source-${line.item.orderItemId}',
        ),
        value: line.source,
        enabled: _canRegisterNow && !_saving,
        onChanged: (source) => setState(() => line.source = source),
      ),
    ),
    EditableGridColumn(
      key: 'qty',
      label: '本次实收',
      width: 130,
      numeric: true,
      required: true,
      // 通用说明放列头 ⓘ（2026-09-10 全站口径），与单张到货登记页一致。
      headerInfo: workflowFieldText(context).workflowArrivalQuantityHint,
      textOf: (line) => line.qty.text,
      listenableOf: (line) => line.qty,
      cellBuilder: (context, line) => RequiredCellFrame(
        listenable: line.qty,
        isEmpty: () => (double.tryParse(line.qty.text.trim()) ?? 0) <= 0,
        child: Semantics(
          textField: true,
          label: '${line.item.goodsName} 本次实收',
          child: TextField(
            key: ValueKey(
              'warehouse-arrival-batch-qty-${line.item.orderItemId}',
            ),
            controller: line.qty,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textAlign: TextAlign.right,
            decoration: const UtenInputDecoration(
              InputDecoration(hintText: '大于 0', isDense: true),
            ),
          ),
        ),
      ),
    ),
    EditableGridColumn(
      key: 'unit',
      label: '单位',
      width: 70,
      filterValueOf: (line) => _bucketOrNull(line.item.unitName),
      textOf: (line) => line.item.unitName ?? '—',
      cellBuilder: (context, line) => Text(line.item.unitName ?? '—'),
    ),
    EditableGridColumn(
      key: 'warehouse',
      label: '入库仓库',
      width: 160,
      required: true,
      filterValueOf: (line) => _bucketOrNull(_warehouseLabel(line.warehouseId)),
      textOf: (line) => _warehouseLabel(line.warehouseId) ?? '未选择',
      cellBuilder: (context, line) {
        final theme = Theme.of(context);
        final label = _warehouseLabel(line.warehouseId);
        return Semantics(
          button: true,
          label: '${line.item.goodsName} 入库仓库：${label ?? '未选择'}，点击修改',
          child: InkWell(
            key: ValueKey(
              'warehouse-arrival-batch-wh-${line.item.orderItemId}',
            ),
            onTap: _saving ? null : () => _pickLineWarehouse(line),
            borderRadius: BorderRadius.circular(UtenRadius.control),
            child: InputDecorator(
              // 2026-09-10 单元规格统一：不自带 border/contentPadding/小字/双行，
              // 圆角、内边距、字号吃 UtenEditableGrid 行级主题（与数量格等高）。
              decoration: applyAutofillHint(
                UtenInputDecoration(
                  InputDecoration(
                    isDense: true,
                    enabledBorder: label == null
                        ? requiredEmptyBorder(theme)
                        : null,
                  ),
                  info: line.warehouseAutofilled
                      ? '已带入上次收货仓或来源建议仓，请核对本次实物仓库'
                      : null,
                ),
                theme,
                autofilled: label != null && line.warehouseAutofilled,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label ?? '必选 · 点击选择',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: label == null
                          ? theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.error,
                              fontWeight: FontWeight.w600,
                            )
                          : null,
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
    EditableGridColumn(
      key: 'stockPlace',
      label: '库位号',
      width: 120,
      textOf: (line) => line.stockPlace.text,
      listenableOf: (line) => line.stockPlace,
      cellBuilder: (context, line) => Semantics(
        textField: true,
        label: '${line.item.goodsName} 库位号',
        child: WarehouseAutofillTextField(
          controller: line.stockPlace,
          source: '库位来自货品资料，请核对本次实物存放位置',
          enabled: !_saving,
        ),
      ),
    ),
    EditableGridColumn(
      key: 'series',
      label: '物料系列',
      width: 120,
      textOf: (line) => line.series.text,
      listenableOf: (line) => line.series,
      cellBuilder: (context, line) => Semantics(
        textField: true,
        label: '${line.item.goodsName} 物料系列',
        child: WarehouseAutofillTextField(
          controller: line.series,
          source: '系列来自货品资料，请核对本次到货',
          enabled: !_saving,
        ),
      ),
    ),
    EditableGridColumn(
      key: 'goodsCode',
      label: '物料编码',
      width: 140,
      textOf: (line) => line.goodsCode.text,
      listenableOf: (line) => line.goodsCode,
      cellBuilder: (context, line) => Semantics(
        textField: true,
        label: '${line.item.goodsName} 物料编码',
        child: WarehouseAutofillTextField(
          controller: line.goodsCode,
          source: '编码来自货品资料，请核对本次到货',
          enabled: !_saving,
        ),
      ),
    ),
  ];

  /// 明细表下方的合计条（全站统一 UtenTotalsSummaryBar 口径）：数量严格按单位
  /// UUID 分组，不同单位绝不相加；本页对仓库不可见价格，故没有金额项。
  Widget _lineTotalsBar() => UtenTotalsSummaryBar(
    key: const Key('warehouse-arrival-batch-totals'),
    density: true,
    showDivider: false,
    entries: [
      UtenTotalEntry('明细', '${_lines.length} 行'),
      utenQuantityTotalEntry(
        _lines.map(
          (line) => MeasuredAmount(
            value: double.tryParse(line.qty.text.trim()) ?? 0,
            unitId: line.item.unitId,
            unitName: line.item.unitName,
          ),
        ),
        label: '本次实收',
      ),
    ],
  );

  Widget _buildBottomBar(ThemeData theme, bool canRegister) {
    // 合计不再挂底部操作条（2026-09-11 用户口径：明细表下方已有合计条，
    // 底部再报一遍是重复），这里只剩取消 / 登记并送检。
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
          children: [
            UtenButton(
              type: UtenButtonType.secondary,
              size: UtenButtonSize.large,
              onPressed: _saving ? null : () => context.pop(),
              child: const Text('取消'),
            ),
            const SizedBox(width: UtenSpacing.s12),
            UtenButton(
              key: const Key('warehouse-arrival-batch-submit'),
              // 「点了就往下走一步」的主动作统一红底白字（全站口径）。
              type: UtenButtonType.danger,
              size: UtenButtonSize.large,
              isLoading: _saving,
              icon: Icons.fact_check_outlined,
              onPressed: !canRegister || _saving || _lines.isEmpty
                  ? null
                  : _save,
              child: const Text('登记并送检'),
            ),
          ],
        ),
      ),
    );
  }

  /// 人员选择器：关键字为空时收敛到仓储部子树、否则全公司搜。
  Widget _employeePicker({
    required String label,
    required String? currentId,
    required ValueChanged<String?> onChanged,
  }) {
    return UtenEmployeePicker(
      key: ValueKey('${label}_$currentId'),
      label: label,
      hint: '请选择$label',
      sheetTitle: '选择$label',
      required: true,
      initial: currentId == null ? null : _empCache[currentId],
      loader: (kw) async {
        final deptId = (kw == null || kw.isEmpty)
            ? (ref.read(departmentCodeIdMapProvider).valueOrNull ??
                  const {})[kDeptCodeWarehouse]
            : null;
        final res = await ref
            .read(employeeRepositoryProvider)
            .list(
              size: 30,
              search: kw,
              departmentId: deptId,
              includeSubtree: true,
            );
        return [
          for (final e in res.items)
            UtenEmployeePickerItem(
              id: e.id,
              name: e.fullName,
              employeeCode: e.code,
              departmentName: e.departmentName,
            ),
        ];
      },
      onChanged: (item) {
        if (item != null) _empCache[item.id] = item;
        onChanged(item?.id);
      },
    );
  }
}

/// 一行批量到货登记明细：挂来源订货单预填 + 行级数量/仓库/学习字段。
class _BatchArrivalLine extends EditableGridRow {
  _BatchArrivalLine(this.prefill, this.item, {required this.onChanged})
    : qty = TextEditingController(
        text: procurementQty(item.approvedRemainingQty),
      ),
      stockPlace = UtenAutofillTextController(text: item.goodsStockPlace ?? ''),
      series = UtenAutofillTextController(text: item.goodsSeries ?? ''),
      goodsCode = UtenAutofillTextController(text: item.goodsCode),
      warehouseId =
          item.lastReceiptWarehouseId ??
          (prefill.suggestedWarehouseId?.isNotEmpty == true
              ? prefill.suggestedWarehouseId
              : prefill.warehouseId) {
    warehouseAutofilled = warehouseId?.isNotEmpty == true;
    qty.addListener(onChanged);
  }

  final ProcurementReceiptPrefill prefill;
  final ProcurementReceiptPrefillItem item;
  final VoidCallback onChanged;
  final TextEditingController qty;
  WarehouseArrivalSource source = WarehouseArrivalSource.automatic;

  /// 行级入库仓库（必填：建议仓预填，无建议时留空待选）。
  String? warehouseId;
  bool warehouseAutofilled = false;

  final UtenAutofillTextController stockPlace;
  final UtenAutofillTextController series;
  final UtenAutofillTextController goodsCode;

  /// 批量写入库位：视同已核对，写完不留预填黄标。
  /// 同值写入时 UtenAutofillTextController 不会自行清标（它只在文本变化时清），
  /// 故先置空再写回，逼它翻成手工值。
  void setCheckedStockPlace(String value) {
    if (stockPlace.text == value) stockPlace.value = TextEditingValue.empty;
    stockPlace.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  @override
  void dispose() {
    qty.removeListener(onChanged);
    qty.dispose();
    stockPlace.dispose();
    series.dispose();
    goodsCode.dispose();
    super.dispose();
  }
}
