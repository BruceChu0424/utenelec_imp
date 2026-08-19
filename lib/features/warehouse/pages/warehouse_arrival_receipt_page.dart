// 仓库登记实际到货独立页（/warehouse/inbound/receipts/new）。
//
// 与采购/委外收货单编辑页分立的仓库专属登记页：
//   - 不出现币种/汇率/结帐方式/交货人/单价金额（价格对仓库不可见，审核时服务端权威回填）；
//   - 采购员、收货人必选（收货人=仓库收货人，默认当前登录人，默认部门仓储 SUB_WH）；
//   - 明细逐行登记本次实收 + 库位号/物料系列/物料编码（主档带出，保存后「学习」回写）；
//   - 入库仓库：预计到货带建议仓（物料分析目标仓）时预填并锁定，防入错仓导致分析进度不刷新；
//   - 保存成功后回写货品资料 → 回预计到货任务中心（不跳收货单详情，仓库看不到金额）。
// 审核通过后采购/委外侧即生成同一张收货单记录（本页创建的就是该单据的草稿）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../department/models/department_node.dart';
import '../../department/repositories/department_repository.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../purchase/config/purchase_doc_config.dart';
import '../../purchase/models/purchase_doc.dart';
import '../../purchase/repositories/purchase_repository.dart';
import '../../subcontract/config/subcontract_doc_config.dart';
import '../../subcontract/models/subcontract_doc.dart';
import '../../subcontract/repositories/subcontract_repository.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/providers/session_provider.dart';
import '../providers/procurement_inbound_count_providers.dart';
import '../repositories/procurement_inbound_repository.dart';

class WarehouseArrivalReceiptPage extends ConsumerStatefulWidget {
  const WarehouseArrivalReceiptPage({super.key, this.prefill});

  /// 预计到货任务带入的预填；null = 无来源直达（不允许，需从任务中心进入）。
  final ProcurementReceiptPrefill? prefill;

  @override
  ConsumerState<WarehouseArrivalReceiptPage> createState() =>
      _WarehouseArrivalReceiptPageState();
}

class _WarehouseArrivalReceiptPageState
    extends ConsumerState<WarehouseArrivalReceiptPage> {
  final _remark = TextEditingController();
  final _scrollCtl = ScrollController();
  final Map<String, UtenEmployeePickerItem> _empCache = {};

  DateTime _billDate = ChinaDateTime.today();
  String? _warehouseId;
  String? _purchaserId; // 仅采购收货（委外进仓单主档无采购员列）
  String? _receiverId;
  bool _loading = false;
  bool _saving = false;

  List<_ArrivalReceiptLine> _lines = const [];

  bool get _isPurchase =>
      widget.prefill?.orderType == ProcurementInboundOrderType.purchase;

  /// 建议仓（物料分析目标仓）存在时预填并锁定：防手选别仓导致合格库存落错仓、
  /// 物料分析齐套/品质放行后进度不刷新。无建议时自由选仓（多分析不同仓等合法场景）。
  bool get _warehouseLocked =>
      widget.prefill?.suggestedWarehouseId?.isNotEmpty == true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _remark.dispose();
    _scrollCtl.dispose();
    for (final line in _lines) {
      line.dispose();
    }
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
    _lines = [
      for (final item in prefill.items)
        _ArrivalReceiptLine(item, onChanged: _onLineChanged),
    ];
    await _preloadEmployees([prefill.purchaserId, meId]);
    if (mounted) setState(() => _loading = false);
  }

  void _onLineChanged() {
    if (mounted) setState(() {});
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
            departmentName: p.departmentName,
          );
        } catch (_) {
          // 静默：picker 的 initial 为 null 时不显示名字，不阻塞流程。
        }
      }),
    );
  }

  Future<void> _save() async {
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
      context.appError('请选择收货人（仓库收货人）');
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
        // 不带 price：价格对仓库不可见，收货审核时服务端按订货明细权威回填金额。
      });
    }
    final body = <String, dynamic>{
      'billDate': _fmt(_billDate),
      'warehouseId': _warehouseId,
      'supplierId': prefill.supplierId,
      'remark': _remark.text.trim().isEmpty ? null : _remark.text.trim(),
      if (_isPurchase) ...{
        'purchaserId': _purchaserId,
        'receiverId': _receiverId,
      } else
        // 委外进仓单主档仅 sender_id 一个人员列（服务端按「收货人」语义解析）。
        'senderId': _receiverId,
      'items': itemsBody,
    };
    setState(() => _saving = true);
    try {
      if (_isPurchase) {
        await ref
            .read(purchaseRepositoryProvider(PurchaseDocType.receipt))
            .create(body);
      } else {
        await ref
            .read(subcontractRepositoryProvider(SubcontractDocType.receipt))
            .create(body);
      }
      // 货品资料「学习」回写（best-effort）：库位号/系列/编码写回主档，下次登记自动带出。
      await _learnGoodsProfiles();
      if (!mounted) return;
      bumpListRefresh(
        ref,
        _isPurchase
            ? PurchaseDocConfig.by(PurchaseDocType.receipt).refreshKey
            : SubcontractDocConfig.by(SubcontractDocType.receipt).refreshKey,
      );
      ref.invalidate(warehouseInboundExpectationCountProvider);
      context.appSuccess('到货已登记，待审核');
      context.go(RouteName.warehouseInboundExpectations);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('保存失败，请稍后重试');
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
            : _buildForm(context, theme, prefill),
      ),
      bottomNavigationBar: prefill == null ? null : _buildBottomBar(theme),
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
            onPressed: () =>
                context.go(RouteName.warehouseInboundExpectations),
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
                          readOnly: true,
                          initialValue: prefill.supplierName ?? '—',
                          decoration: const InputDecoration(
                            labelText: '供应商',
                            filled: true,
                          ),
                        ),
                        _dropdown(
                          '入库仓库',
                          _warehouseId,
                          names.warehouseEntries,
                          (v) => setState(() => _warehouseId = v),
                          required: true,
                          enabled: !_warehouseLocked,
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
                    if (_warehouseLocked) ...[
                      const SizedBox(height: UtenSpacing.s8),
                      Row(
                        children: [
                          Icon(
                            Icons.lock_outline,
                            size: 16,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: UtenSpacing.s4),
                          Expanded(
                            child: Text(
                              '已按物料分析目标仓锁定'
                              '${prefill.suggestedWarehouseName == null ? '' : '：${prefill.suggestedWarehouseName}'}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          ),
                        ],
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
            Text(
              '明细（${_lines.length} 行）',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            for (var i = 0; i < _lines.length; i++) ...[
              _lineCard(theme, _lines[i]),
              if (i != _lines.length - 1) const SizedBox(height: UtenSpacing.s8),
            ],
            const SizedBox(height: UtenSpacing.s24),
          ],
        ),
      ),
    );
  }

  Widget _arrivalBanner(ThemeData theme, ProcurementReceiptPrefill prefill) {
    return Semantics(
      container: true,
      label:
          '请按实际到货数量登记。超出财务批准剩余量时不会直接入库，'
          '系统会隔离并通知指定财务负责人审批。',
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
                      '请按实际到货数量登记',
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
                      '本页只登记数量与库位，不涉及价格与金额。'
                      '实到数量超过财务批准剩余量时仍可如实填写——超出部分不会入库、'
                      '不会生成应付，系统会自动隔离并通知指定财务负责人审批。',
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

  Widget _lineCard(ThemeData theme, _ArrivalReceiptLine line) {
    final item = line.item;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${item.goodsName}（${item.goodsCode}）',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              [
                if (item.colorName?.isNotEmpty == true) '颜色 ${item.colorName}',
                if (item.unitName?.isNotEmpty == true) '单位 ${item.unitName}',
                '批准剩余 ${procurementQty(item.approvedRemainingQty)}',
              ].join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            UtenFormGrid(
              children: [
                TextField(
                  controller: line.qty,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: '本次实收',
                    hintText: '大于 0',
                  ),
                ),
                TextField(
                  controller: line.stockPlace,
                  decoration: const InputDecoration(labelText: '库位号'),
                ),
                TextField(
                  controller: line.series,
                  decoration: const InputDecoration(labelText: '物料系列'),
                ),
                TextField(
                  controller: line.goodsCode,
                  decoration: const InputDecoration(labelText: '物料编码'),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              '库位/系列/编码由货品资料带出，可直接修改；保存后会写回货品资料，下次自动带出。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(ThemeData theme) {
    final total = _lines.fold<double>(
      0,
      (sum, line) => sum + (double.tryParse(line.qty.text.trim()) ?? 0),
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
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 仓库视角只有数量，没有金额。
            Text(
              '明细 ${_lines.length} 行 · 实收合计 ${procurementQty(total)} 件',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: UtenSpacing.s16),
            UtenButton(
              type: UtenButtonType.secondary,
              onPressed: () => context.pop(),
              child: const Text('取消'),
            ),
            const SizedBox(width: UtenSpacing.s12),
            UtenButton(
              isLoading: _saving,
              icon: Icons.save_outlined,
              onPressed: _saving ? null : _save,
              child: const Text('保存'),
            ),
          ],
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

  Widget _dropdown(
    String label,
    String? value,
    Map<String, String> entries,
    ValueChanged<String?> onChanged, {
    bool required = false,
    bool enabled = true,
  }) {
    return UtenDropdownField(
      label: label,
      value: value,
      required: required,
      enabled: enabled,
      items: [
        for (final e in entries.entries)
          UtenDropdownItem(value: e.key, label: e.value),
        if (value != null && value.isNotEmpty && !entries.containsKey(value))
          UtenDropdownItem(value: value, label: value),
      ],
      onChanged: onChanged,
    );
  }
}

/// 一行到货登记明细的本地状态（数量 + 库位/系列/编码学习字段）。
class _ArrivalReceiptLine {
  _ArrivalReceiptLine(this.item, {required this.onChanged})
    : qty = TextEditingController(
        text: procurementQty(item.approvedRemainingQty),
      ),
      stockPlace = TextEditingController(text: item.goodsStockPlace ?? ''),
      series = TextEditingController(text: item.goodsSeries ?? ''),
      goodsCode = TextEditingController(text: item.goodsCode) {
    qty.addListener(onChanged);
  }

  final ProcurementReceiptPrefillItem item;
  final VoidCallback onChanged;
  final TextEditingController qty;
  final TextEditingController stockPlace;
  final TextEditingController series;
  final TextEditingController goodsCode;

  void dispose() {
    qty.removeListener(onChanged);
    qty.dispose();
    stockPlace.dispose();
    series.dispose();
    goodsCode.dispose();
  }
}
