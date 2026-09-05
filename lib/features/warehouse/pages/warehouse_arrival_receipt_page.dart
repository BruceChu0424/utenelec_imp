// 仓库登记实际到货独立页（/warehouse/inbound/receipts/new）。
//
// 与采购/委外收货单编辑页分立的仓库专属登记页：
//   - 不出现币种/汇率/结帐方式/交货人/单价金额（价格对仓库不可见，审核时服务端权威回填）；
//   - 采购员、收货人必选（收货人=仓库收货人，默认当前登录人，默认部门仓储 SUB_WH）；
//   - 明细逐行登记本次实收 + 库位号/物料系列/物料编码（主档带出，保存后「学习」回写）；
//   - 入库仓库：预计到货带建议仓（物料分析目标仓）时预填，仓库可按实际更换，
//     改离建议仓时给出提示（合格库存将入所选仓，分析进度按所选仓刷新）；
//   - 「登记并送检」一步完成：保存（服务端按订货单回填币族并建收货单草稿）+ 审核
//     （转品质部待检 IQC）同事务；实到超量时服务端隔离并通知财务，返回隔离结果。
//     登记后 pop(结果) 回预计到货任务中心就地刷新——仓库流程全程不进入采购/委外模块，
//     也不再有「保存→跳转→手动审核」的中间跳转。
// 审核通过后采购/委外侧即生成同一张收货单记录（本页创建的就是该单据）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/inputs/uten_field_message.dart';
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
import '../../../shared/widgets/warehouse_hierarchy_dropdown.dart';
import '../../../shared/providers/session_provider.dart';
import '../providers/warehouse_count_refresh.dart';
import '../repositories/procurement_inbound_repository.dart';
import '../widgets/warehouse_inbound_allocation_view.dart';

class WarehouseArrivalReceiptPage extends ConsumerStatefulWidget {
  const WarehouseArrivalReceiptPage({
    super.key,
    this.prefill,
    this.canRegister,
  });

  /// 预计到货任务带入的预填；null = 无来源直达（不允许，需从任务中心进入）。
  final ProcurementReceiptPrefill? prefill;

  /// 仅供独立预览/测试覆盖；正式路由为空时从当前登录权限实时推导。
  final bool? canRegister;

  @override
  ConsumerState<WarehouseArrivalReceiptPage> createState() =>
      _WarehouseArrivalReceiptPageState();
}

class _WarehouseArrivalReceiptPageState
    extends ConsumerState<WarehouseArrivalReceiptPage> {
  final _remark = TextEditingController();
  final _scrollCtl = ScrollController();
  final Map<String, UtenEmployeePickerItem> _empCache = {};
  late final String _arrivalIdempotencyKey = businessIdempotencyKey(
    'warehouse-arrival-create',
    '${DateTime.now().microsecondsSinceEpoch}:${UniqueKey()}',
  );

  DateTime _billDate = ChinaDateTime.today();
  String? _warehouseId;
  String? _purchaserId; // 仅采购收货（委外进仓单主档无采购员列）
  String? _receiverId;
  bool _loading = false;
  bool _saving = false;
  int _removedLineCount = 0;

  final UtenEditableGridController<_ArrivalReceiptLine> _lineGrid =
      UtenEditableGridController<_ArrivalReceiptLine>();

  List<_ArrivalReceiptLine> get _lines => _lineGrid.rows;

  bool get _isPurchase =>
      widget.prefill?.orderType == ProcurementInboundOrderType.purchase;

  bool get _canRegisterNow {
    final override = widget.canRegister;
    if (override != null) return override;
    if (ref.read(isSuperAdminProvider)) return true;
    final permissions = ref.read(currentPermissionsProvider);
    return permissions.contains(Perm.warehouseInboundView) &&
        permissions.contains(Perm.warehouseInboundStockIn);
  }

  /// 建议仓（物料分析目标仓）存在时预填；仓库可按实际到货情况更换，
  /// 改离建议仓时必须明示：合格库存不会计入原物料分析的目标仓备料。
  String? get _suggestedWarehouseId {
    final id = widget.prefill?.suggestedWarehouseId;
    return id == null || id.isEmpty ? null : id;
  }

  String? get _selectedWarehouseName {
    final id = _warehouseId;
    if (id == null) return null;
    final value = ref.read(masterNameServiceProvider).warehouse(id);
    return value == '—' ? null : value;
  }

  double _lineInputBaseQty(_ArrivalReceiptLine line) {
    final input = double.tryParse(line.qty.text.trim()) ?? 0;
    final rate = line.item.unitRate.toDouble();
    return input * (rate.isFinite && rate > 0 ? rate : 1);
  }

  List<WarehouseInboundAllocation> _lineProjectedAllocations(
    _ArrivalReceiptLine line,
  ) => warehouseInboundAllocationForWarehouse(
    line.item.expectedAllocations,
    double.tryParse(line.qty.text.trim()) ?? 0,
    actualWarehouseId: _warehouseId,
    actualWarehouseName: _selectedWarehouseName,
    unitRate: line.item.unitRate.toDouble(),
  );

  String _lineBaseUnitLabel(_ArrivalReceiptLine line) =>
      line.item.baseUnitName?.trim().isNotEmpty == true
      ? line.item.baseUnitName!.trim()
      : line.item.expectedAllocations
                .map((item) => item.baseUnitName)
                .whereType<String>()
                .where((name) => name.trim().isNotEmpty)
                .firstOrNull ??
            '基本量';

  String _lineTargetWarehouseText(_ArrivalReceiptLine line) {
    final names = <String>{
      for (final allocation in line.item.expectedAllocations)
        if (!allocation.isPublic) ?allocation.targetWarehouseName,
    }..removeWhere((name) => name.trim().isEmpty);
    if (names.isEmpty) {
      names.addAll(
        line.item.expectedAllocations
            .expand((item) => item.intendedWarehouseNames)
            .where((name) => name.trim().isNotEmpty),
      );
    }
    return names.isEmpty ? '无特定主仓' : names.join(' / ');
  }

  WarehouseInboundAllocationSection _lineAllocationSection(
    _ArrivalReceiptLine line,
  ) => WarehouseInboundAllocationSection(
    id: line.item.orderItemId,
    goodsLabel: '${line.item.goodsName}(${line.item.goodsCode})',
    quantity: _lineInputBaseQty(line),
    unitName: _lineBaseUnitLabel(line),
    sourceOrderNo: widget.prefill?.orderBillNo,
    allocations: _lineProjectedAllocations(line),
  );

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
    final prefill = widget.prefill;
    if (prefill == null) return;
    setState(() => _loading = true);
    await ref.read(masterNameServiceProvider).ensureLoaded();
    _warehouseId = prefill.suggestedWarehouseId?.isNotEmpty == true
        ? prefill.suggestedWarehouseId
        : prefill.warehouseId;
    if (_isPurchase && prefill.purchaserId?.isNotEmpty == true) {
      _purchaserId = prefill.purchaserId;
    }
    // 收货人默认当前登录人（仓库收货人，非采购员）。
    final meId = ref.read(sessionProvider).user?.employeeId;
    if (meId != null && meId.isNotEmpty) {
      _receiverId = meId;
    }
    _lineGrid.replaceAll([
      for (final item in prefill.items)
        _ArrivalReceiptLine(item, onChanged: _onLineChanged),
    ]);
    _removedLineCount = 0;
    await _preloadEmployees([prefill.purchaserId, meId]);
    if (mounted) setState(() => _loading = false);
  }

  void _onLineChanged() {
    if (mounted) setState(() {});
  }

  /// 仅从当前登记请求移出，不调用删除 API、不改来源订货或到货累计。
  /// 返回任务中心后，这些行仍按服务端剩余量显示为“待登记送检”。
  void _removeFromThisRegistration(List<_ArrivalReceiptLine> rows) {
    if (_saving || !_canRegisterNow || rows.isEmpty) return;
    _lineGrid.removeRows(rows);
    if (!mounted) return;
    setState(() => _removedLineCount += rows.length);
    context.appInfo('已从本次登记移出 ${rows.length} 行；未写入数据库，返回任务中心后仍可继续登记送检');
  }

  /// 并发按 id 拉人员名字（picker 的 initial 显示用）。失败静默。
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
        } catch (_) {
          // 静默：picker 的 initial 为 null 时不显示名字，不阻塞流程。
        }
      }),
    );
  }

  Future<void> _save() async {
    if (!_canRegisterNow) {
      context.appError('当前账号没有登记并送检权限，请返回任务中心刷新权限');
      return;
    }
    final prefill = widget.prefill;
    if (prefill == null) return;
    if (_warehouseId == null || _warehouseId!.isEmpty) {
      context.appError('请选择入库仓库');
      return;
    }
    if (_isPurchase && (_purchaserId == null || _purchaserId!.isEmpty)) {
      context.appError('请选择采购员');
      return;
    }
    if (_receiverId == null || _receiverId!.isEmpty) {
      context.appError('请选择收货人(仓库收货人)');
      return;
    }
    if (_lines.isEmpty) {
      context.appError('该任务没有可登记明细，请返回任务中心刷新');
      return;
    }
    final itemsBody = <Map<String, dynamic>>[];
    for (final line in _lines) {
      final qty = double.tryParse(line.qty.text.trim()) ?? 0;
      if (qty <= 0) {
        context.appError('${line.item.goodsName} 的本次实收必须大于 0');
        return;
      }
      final weightText = line.weight.text.trim();
      final weight = weightText.isEmpty ? null : double.tryParse(weightText);
      if (weightText.isNotEmpty && (weight == null || weight <= 0)) {
        context.appError('${line.item.goodsName} 的实际重量必须大于 0');
        return;
      }
      itemsBody.add({
        'goodsId': line.item.goodsId,
        'qty': qty,
        'orderItemId': line.item.orderItemId,
        // 来源单据编号谱系（来源订货单号），与编辑页口径一致。
        'sourceDocNo': prefill.orderBillNo,
        if (line.item.colorId != null) 'colorId': line.item.colorId,
        if (line.item.unitId != null) 'unitId': line.item.unitId,
        // 委外进仓明细带单位换算率（与委外编辑页口径一致）；采购收货不需要。
        if (!_isPurchase) 'unitRate': line.item.unitRate,
        'weight': ?weight,
        // 不带 price：价格对仓库不可见，收货审核时服务端按订货明细权威回填金额。
      });
    }
    // 一步完成 = 登记保存 + 送检审核。预计去向已按员工本次实收、
    // unitRate 和所选实际仓重算；真正归属仍由后续 IQC 入库事务决定。
    final projectedSections = [
      for (final line in _lines) _lineAllocationSection(line),
    ];
    final hasCrossWarehouse = projectedSections.any(
      (section) => section.allocations.any((item) => item.isCrossWarehouse),
    );
    final confirmed = await showWarehouseInboundAllocationConfirmDialog(
      context,
      title: '登记并送检',
      actionLabel: '登记送检',
      confirmLabel: hasCrossWarehouse ? '确认跨仓登记送检' : '确认登记送检',
      sections: projectedSections,
      description:
          '确认后按本次实收数量登记到货并直接送品质部待检(IQC)：'
          '检验合格后转仓库待入库任务，仓库确认实物与库位后库存才增加；'
          '${hasCrossWarehouse ? '红色跨仓部分只是预计，将不绑定原计划并按实际仓公共入库，请重点复核；' : ''}'
          '实到超过财务批准量时系统自动隔离并通知财务审核组，'
          '不会入库、不会生成应付。最终预定归属以 IQC 合格后仓库确认入库事务为准。',
    );
    if (!confirmed) return;
    final body = <String, dynamic>{
      // 页面生命周期内固定；响应丢失后的重试必须复用，不能再造一张收货单。
      'idempotencyKey': _arrivalIdempotencyKey,
      'billDate': _fmt(_billDate),
      'warehouseId': _warehouseId,
      'supplierId': prefill.supplierId,
      'remark': _remark.text.trim().isEmpty ? null : _remark.text.trim(),
      if (_isPurchase) ...{
        'purchaserId': _purchaserId,
        'receiverEmployeeId': _receiverId,
      } else
        // 委外进仓单主档仅 sender_id 一个人员列（服务端按「收货人」语义解析）。
        'receiverEmployeeId': _receiverId,
      'items': itemsBody,
    };
    setState(() => _saving = true);
    try {
      final registration = await ref
          .read(procurementInboundRepositoryProvider)
          .registerArrival(orderType: prefill.orderType, body: body);
      // 货品资料「学习」回写（best-effort）：不阻塞返回任务中心，失败静默。
      unawaited(_learnGoodsProfiles());
      if (!mounted) return;
      bumpListRefresh(
        ref,
        _isPurchase
            ? PurchaseDocConfig.by(PurchaseDocType.receipt).refreshKey
            : SubcontractDocConfig.by(SubcontractDocType.receipt).refreshKey,
      );
      invalidateWarehouseTaskCounts(ref);
      // pop(登记结果) 让任务中心就地刷新并提示下一步；不再跳采购/委外收货单详情页——
      // 仓库流程全程不离开仓储模块（超收时任务中心引导到「到货异常任务中心」）。
      if (context.canPop()) {
        context.pop(registration);
      } else {
        context.go(RouteName.warehouseInboundExpectations);
      }
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('登记送检失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 学习回写：仅上报用户实际填了值的字段（空值跳过由服务端兜底）。失败不阻断主流程。
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
    } catch (_) {
      // 静默：学习回写失败不影响已保存的到货登记。
    }
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final prefill = widget.prefill;
    final theme = Theme.of(context);
    final permissionSnapshot = widget.canRegister == null
        ? ref.watch(currentPermissionsProvider)
        : const <String>{};
    final isAdmin =
        widget.canRegister == null && ref.watch(isSuperAdminProvider);
    final canRegister =
        widget.canRegister ??
        (isAdmin ||
            (permissionSnapshot.contains(Perm.warehouseInboundView) &&
                permissionSnapshot.contains(Perm.warehouseInboundStockIn)));
    return Scaffold(
      appBar: UtenAppBar(
        title: prefill == null
            ? '登记实际到货'
            : '登记实际到货 · ${prefill.orderType.label}',
        leading: UtenBackButton(
          onPressed: () => popOrBackTo(
            context,
            defaultPath: RouteName.warehouseInboundExpectations,
          ),
        ),
      ),
      body: SafeArea(
        child: prefill == null
            ? _missingPrefill(context)
            : _loading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
            : AbsorbPointer(
                absorbing: _saving || !canRegister,
                child: _buildForm(context, theme, prefill, canRegister),
              ),
      ),
      bottomNavigationBar: prefill == null
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
          const Text('请从「预计到货任务中心」选择任务后登记到货'),
          const SizedBox(height: UtenSpacing.s16),
          UtenButton(
            type: UtenButtonType.tonal,
            icon: Icons.arrow_back_rounded,
            onPressed: () => context.go(RouteName.warehouseInboundExpectations),
            child: const Text('返回任务中心'),
          ),
        ],
      ),
    );
  }

  Widget _buildForm(
    BuildContext context,
    ThemeData theme,
    ProcurementReceiptPrefill prefill,
    bool canRegister,
  ) {
    final names = ref.watch(masterNameServiceProvider);
    return UtenContentContainer(
      child: Scrollbar(
        controller: _scrollCtl,
        thumbVisibility: true,
        child: ListView(
          controller: _scrollCtl,
          padding: const EdgeInsets.all(UtenSpacing.s12),
          children: [
            _arrivalBanner(theme, prefill),
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
                        // 供应商来自预计到货任务，只读防改坏来源关联。
                        TextFormField(
                          errorBuilder: utenTextFieldErrorBuilder,
                          readOnly: true,
                          initialValue: prefill.supplierName ?? '—',
                          decoration: const InputDecoration(
                            labelText: '供应商',
                            filled: true,
                          ),
                        ),
                        // V476：仓库下拉带主/子层级（父仓置灰分组，收货落具体仓）。
                        UtenDropdownField(
                          key: const Key('warehouse-arrival-warehouse'),
                          label: '入库仓库',
                          value: _warehouseId,
                          required: true,
                          items: warehouseHierarchyItems(
                            names.warehouseHierarchy,
                          ),
                          onChanged: (v) => setState(() => _warehouseId = v),
                        ),
                        // 采购员（采购收货必选；委外进仓单主档无此列，不录）。
                        if (_isPurchase)
                          _employeePicker(
                            label: '采购员',
                            currentId: _purchaserId,
                            defaultDeptCode: kDeptCodePurchase,
                            onChanged: (id) =>
                                setState(() => _purchaserId = id),
                          ),
                        _employeePicker(
                          label: '收货人',
                          currentId: _receiverId,
                          defaultDeptCode: kDeptCodeWarehouse,
                          onChanged: (id) => setState(() => _receiverId = id),
                        ),
                      ],
                    ),
                    if (_suggestedWarehouseId != null) ...[
                      const SizedBox(height: UtenSpacing.s8),
                      // liveRegion：换仓警告对读屏用户即时播报
                      Semantics(
                        key: const Key(
                          'warehouse-arrival-suggested-warehouse-status',
                        ),
                        container: true,
                        liveRegion: true,
                        child: Row(
                          children: [
                            Icon(
                              _warehouseId == _suggestedWarehouseId
                                  ? Icons.recommend_outlined
                                  : Icons.warning_amber_rounded,
                              size: 16,
                              color: _warehouseId == _suggestedWarehouseId
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.error,
                            ),
                            const SizedBox(width: UtenSpacing.s4),
                            Expanded(
                              child: Text(
                                _warehouseId == _suggestedWarehouseId
                                    ? '已按物料分析目标仓预填'
                                          '${prefill.suggestedWarehouseName == null ? '' : '：${prefill.suggestedWarehouseName}'}，可按实际到货更换'
                                    : '已更换物料分析建议仓'
                                          '${prefill.suggestedWarehouseName == null ? '' : '(${prefill.suggestedWarehouseName})'}：'
                                          '合格库存将入所选仓，不会计入原物料分析目标仓，'
                                          '计划部仍会显示缺料；请确认实物确需存放所选仓',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: _warehouseId == _suggestedWarehouseId
                                      ? theme.colorScheme.primary
                                      : theme.colorScheme.error,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
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
            ..._allocationWarehouseNotices(theme),
            Text(
              '明细(${_lines.length} 行)',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            LayoutBuilder(
              builder: (context, constraints) => constraints.maxWidth < 840
                  ? Padding(
                      padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
                      child: Row(
                        children: [
                          Icon(
                            Icons.swipe_rounded,
                            size: 18,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: UtenSpacing.s8),
                          Expanded(
                            child: Text(
                              '表格可左右滑动；可勾选或右键/长按明细移出本次登记，'
                              '数量、实际重量、库位、系列和物料编码可直接编辑。',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            UtenEditableGrid<_ArrivalReceiptLine>(
              key: const Key('warehouse-arrival-lines-grid'),
              controller: _lineGrid,
              columns: _arrivalLineColumns,
              createBlankRow: () => throw UnsupportedError('到货任务明细由订货单固定带入'),
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
              emptyMessage: '该任务没有可登记明细，请返回任务中心刷新',
              footer: Padding(
                padding: const EdgeInsets.fromLTRB(
                  UtenSpacing.s12,
                  UtenSpacing.s8,
                  UtenSpacing.s12,
                  UtenSpacing.s12,
                ),
                child: Text(
                  _removedLineCount == 0
                      ? '库位、系列、编码由货品资料带出，可直接修改；送检后会学习回写，下次自动带出。'
                      : '已移出 $_removedLineCount 行（仅本页临时选择）；这些来源行未写收货、未写库存，仍在待登记送检。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            const SizedBox(height: UtenSpacing.s24),
          ],
        ),
      ),
    );
  }

  List<Widget> _allocationWarehouseNotices(ThemeData theme) {
    final targetNames = <String>{
      for (final line in _lines)
        for (final allocation in line.item.expectedAllocations)
          if (!allocation.isPublic) ?allocation.targetWarehouseName,
    }.where((name) => name.trim().isNotEmpty).toList(growable: false);
    final crossLineCount = _warehouseId == null
        ? 0
        : _lines
              .where(
                (line) => _lineProjectedAllocations(
                  line,
                ).any((allocation) => allocation.isCrossWarehouse),
              )
              .length;
    if (targetNames.length <= 1 && crossLineCount == 0) return const [];
    final cross = crossLineCount > 0;
    final color = cross ? theme.colorScheme.error : theme.colorScheme.tertiary;
    final title = targetNames.length > 1
        ? '本任务包含 ${targetNames.length} 个预定主仓：${targetNames.join(' / ')}'
        : '当前输入含跨仓预定';
    final detail = cross
        ? '当前有 $crossLineCount 行包含跨仓部分。可把本次实收改小到所选仓预定量，'
              '或勾选/右键移出整行，按实际到仓分批登记；若实物确实到当前仓，'
              '确认后跨仓部分预计转公共库存，最终由 IQC 入库事务复核。'
        : '请按实际到仓分批登记；可改小本次实收，或勾选/右键移出本次未到的明细。';
    return [
      Semantics(
        container: true,
        liveRegion: cross,
        label: '$title。$detail',
        child: Container(
          key: const Key('warehouse-arrival-allocation-warehouse-notice'),
          padding: const EdgeInsets.all(UtenSpacing.s12),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            borderRadius: UtenRadius.mdAll,
            border: Border.all(color: color.withValues(alpha: 0.55)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                cross ? Icons.warning_amber_rounded : Icons.call_split_rounded,
                color: color,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: color,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                    Text(detail, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: UtenSpacing.s12),
    ];
  }

  Widget _arrivalBanner(ThemeData theme, ProcurementReceiptPrefill prefill) {
    return Semantics(
      container: true,
      label:
          '请按实际到货数量登记；需要重量统计的货品同时填写实称总重量。'
          '超出财务批准剩余量时不会直接入库，'
          '系统会隔离并通知财务审核组共享处理。',
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '请按实际到货数量和实称重量登记',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onTertiaryContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      '来源订货单：${prefill.orderBillNo}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onTertiaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      '本页登记带单位的数量、可选实称总重量与库位，不涉及价格与金额。'
                      '实到数量超过财务批准剩余量时仍可如实填写——超出部分不会入库、'
                      '不会生成应付，系统会自动隔离并通知财务审核组共享处理。',
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

  List<EditableGridColumn<_ArrivalReceiptLine>> get _arrivalLineColumns => [
    EditableGridColumn(
      key: 'goods',
      label: '货品',
      width: 220,
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
      width: 110,
      textOf: (line) => line.item.colorName ?? '—',
      cellBuilder: (context, line) => Text(line.item.colorName ?? '—'),
    ),
    EditableGridColumn(
      key: 'unit',
      label: '单位',
      width: 80,
      textOf: (line) => line.item.unitName ?? '—',
      cellBuilder: (context, line) => Text(line.item.unitName ?? '—'),
    ),
    EditableGridColumn(
      key: 'approvedRemainingQty',
      label: '批准剩余',
      width: 110,
      numeric: true,
      cellBuilder: (context, line) => Text(
        procurementQty(line.item.approvedRemainingQty),
        textAlign: TextAlign.right,
      ),
    ),
    EditableGridColumn(
      key: 'qty',
      label: '本次实收',
      width: 130,
      numeric: true,
      required: true,
      textOf: (line) => line.qty.text,
      listenableOf: (line) => line.qty,
      cellBuilder: (context, line) => RequiredCellFrame(
        listenable: line.qty,
        isEmpty: () => (double.tryParse(line.qty.text.trim()) ?? 0) <= 0,
        child: Semantics(
          textField: true,
          label: '${line.item.goodsName} 本次实收',
          child: TextField(
            key: ValueKey('warehouse-arrival-qty-${line.item.orderItemId}'),
            controller: line.qty,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textAlign: TextAlign.right,
            decoration: const InputDecoration(hintText: '大于 0', isDense: true),
          ),
        ),
      ),
    ),
    EditableGridColumn(
      key: 'targetWarehouse',
      label: '预定主仓',
      width: 150,
      textOf: _lineTargetWarehouseText,
      cellBuilder: (context, line) => Text(
        _lineTargetWarehouseText(line),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    ),
    EditableGridColumn(
      key: 'expectedAllocation',
      label: '预计去向(基本量)',
      width: 240,
      textOf: (line) => warehouseInboundAllocationSummaryText(
        _lineProjectedAllocations(line),
        (value) => '${procurementQty(value)} ${_lineBaseUnitLabel(line)}',
      ),
      listenableOf: (line) => line.qty,
      cellBuilder: (context, line) => ValueListenableBuilder<TextEditingValue>(
        valueListenable: line.qty,
        builder: (context, _, _) {
          final allocations = _lineProjectedAllocations(line);
          return WarehouseInboundAllocationSummary(
            allocations: allocations,
            qtyText: (value) =>
                '${procurementQty(value)} ${_lineBaseUnitLabel(line)}',
            onTap: () => showWarehouseInboundAllocationDetails(
              context,
              title: '预计去向 · ${line.item.goodsName}',
              sections: [_lineAllocationSection(line)],
            ),
          );
        },
      ),
    ),
    EditableGridColumn(
      key: 'weight',
      label: '实际重量',
      width: 130,
      numeric: true,
      textOf: (line) => line.weight.text,
      listenableOf: (line) => line.weight,
      cellBuilder: (context, line) => Semantics(
        textField: true,
        label: '${line.item.goodsName} 实际重量',
        child: TextField(
          key: ValueKey('warehouse-arrival-weight-${line.item.orderItemId}'),
          controller: line.weight,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textAlign: TextAlign.right,
          decoration: const InputDecoration(hintText: '可选', isDense: true),
        ),
      ),
    ),
    EditableGridColumn(
      key: 'stockPlace',
      label: '库位号',
      width: 140,
      textOf: (line) => line.stockPlace.text,
      listenableOf: (line) => line.stockPlace,
      cellBuilder: (context, line) => Semantics(
        textField: true,
        label: '${line.item.goodsName} 库位号',
        child: TextField(
          controller: line.stockPlace,
          decoration: const InputDecoration(hintText: '可修改', isDense: true),
        ),
      ),
    ),
    EditableGridColumn(
      key: 'series',
      label: '物料系列',
      width: 140,
      textOf: (line) => line.series.text,
      listenableOf: (line) => line.series,
      cellBuilder: (context, line) => Semantics(
        textField: true,
        label: '${line.item.goodsName} 物料系列',
        child: TextField(
          controller: line.series,
          decoration: const InputDecoration(hintText: '可修改', isDense: true),
        ),
      ),
    ),
    EditableGridColumn(
      key: 'goodsCode',
      label: '物料编码',
      width: 160,
      textOf: (line) => line.goodsCode.text,
      listenableOf: (line) => line.goodsCode,
      cellBuilder: (context, line) => Semantics(
        textField: true,
        label: '${line.item.goodsName} 物料编码',
        child: TextField(
          controller: line.goodsCode,
          decoration: const InputDecoration(hintText: '可修改', isDense: true),
        ),
      ),
    ),
  ];

  Widget _buildBottomBar(ThemeData theme, bool canRegister) {
    final totals = measurementTotalsText(
      _lines.map(
        (line) => MeasuredAmount(
          value: double.tryParse(line.qty.text.trim()) ?? 0,
          unitId: line.item.unitId,
          unitName: line.item.unitName,
        ),
      ),
    );
    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final summary = Text(
              '明细 ${_lines.length} 行 · 实收 $totals',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            );
            final actions = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                UtenButton(
                  type: UtenButtonType.secondary,
                  onPressed: _saving ? null : () => context.pop(),
                  child: const Text('取消'),
                ),
                const SizedBox(width: UtenSpacing.s12),
                UtenButton(
                  isLoading: _saving,
                  icon: Icons.fact_check_outlined,
                  onPressed: !canRegister || _saving || _lines.isEmpty
                      ? null
                      : _save,
                  child: const Text('登记并送检'),
                ),
              ],
            );
            if (constraints.maxWidth < 680) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  summary,
                  const SizedBox(height: UtenSpacing.s8),
                  Align(alignment: Alignment.centerRight, child: actions),
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: summary),
                const SizedBox(width: UtenSpacing.s16),
                actions,
              ],
            );
          },
        ),
      ),
    );
  }

  /// 人员选择器：关键字为空且指定 [defaultDeptCode] 时收敛到该部门子树、否则全公司搜。
  Widget _employeePicker({
    required String label,
    required String? currentId,
    required ValueChanged<String?> onChanged,
    String? defaultDeptCode,
  }) {
    return UtenEmployeePicker(
      key: ValueKey('${label}_$currentId'),
      label: label,
      hint: '请选择$label',
      sheetTitle: '选择$label',
      required: true,
      initial: currentId == null ? null : _empCache[currentId],
      loader: (kw) async {
        final deptId = (kw == null || kw.isEmpty) && defaultDeptCode != null
            ? (ref.read(departmentCodeIdMapProvider).valueOrNull ??
                  const {})[defaultDeptCode]
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

/// 一行到货登记明细的本地状态（数量 + 实际总重量 + 库位/系列/编码学习字段）。
class _ArrivalReceiptLine extends EditableGridRow {
  _ArrivalReceiptLine(this.item, {required this.onChanged})
    : qty = TextEditingController(
        text: procurementQty(item.approvedRemainingQty),
      ),
      weight = TextEditingController(),
      stockPlace = TextEditingController(text: item.goodsStockPlace ?? ''),
      series = TextEditingController(text: item.goodsSeries ?? ''),
      goodsCode = TextEditingController(text: item.goodsCode) {
    qty.addListener(onChanged);
    weight.addListener(onChanged);
  }

  final ProcurementReceiptPrefillItem item;
  final VoidCallback onChanged;
  final TextEditingController qty;
  final TextEditingController weight;
  final TextEditingController stockPlace;
  final TextEditingController series;
  final TextEditingController goodsCode;

  @override
  void dispose() {
    qty.removeListener(onChanged);
    weight.removeListener(onChanged);
    qty.dispose();
    weight.dispose();
    stockPlace.dispose();
    series.dispose();
    goodsCode.dispose();
    super.dispose();
  }
}
