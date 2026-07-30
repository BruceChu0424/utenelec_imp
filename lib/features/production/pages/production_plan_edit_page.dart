// 生产计划单编辑页（新建/编辑，全页路由）：主表头表单 + 明细可编辑 Excel 表（UtenEditableGrid）+ 保存。
//
// 与销售/采购编辑页同构（统一模板：UtenFormGrid 表头 + UtenDateField 日期 + UtenEditableGrid 明细）。
// 生产计划特点：
//   - 无币种/供应商/金额（数量驱动）：明细排产量→表尾「排产合计」（qtyNotifier 复用 grid.totalListenable）。
//   - 单据号系统自动生成（后端 DocNumberService，PRODUCTION_PLAN "SJ"），本页只读显示。
//   - 车间=部门选择器（UtenDepartmentPicker，落 department_id；部门名冗余写 workshop_name 供报表 facet）。
//   - 跟单员/生产工=员工选择器（UtenEmployeePicker，落 seller_id/worker_id，V82 加列；name 留底）。
//   - 来源单号=销售订单选择器（showSalesOrderPicker，回填单号字符串；头表来源单号是冗余文本）。
//   - 明细行：productNo（必填）+ goodsId（必填）+ qty 排产量（必填）+ oqty 订货量 + color/unit + salesOrderNo + remark。
//
// 仅草稿可编辑（后端校验，前端不再重复判断；已审单据走详情页红冲）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../basic_data/widgets/uten_goods_picker.dart';
import '../../department/widgets/uten_department_picker.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../sales/widgets/sales_order_picker.dart';
import '../providers/production_department_provider.dart';
import '../repositories/production_repository.dart';
import '../widgets/plan_order_import_sheet.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../core/router/nav_helpers.dart';
import '../widgets/production_grid_columns.dart';

class ProductionPlanEditPage extends ConsumerStatefulWidget {
  const ProductionPlanEditPage({super.key, this.id});
  final String? id; // null=新建

  @override
  ConsumerState<ProductionPlanEditPage> createState() =>
      _ProductionPlanEditPageState();
}

class _ProductionPlanEditPageState
    extends ConsumerState<ProductionPlanEditPage> {
  final _billNo = TextEditingController(); // 只读显示（后端自动生成）
  final _sourceDocNo = TextEditingController(); // 来源单号（销售订单号字符串）
  final _remark = TextEditingController();
  DateTime _billDate = ChinaDateTime.today();
  DateTime? _deliveryDate;

  // 车间 = 部门
  String? _departmentId;
  String? _workshopName; // 部门名冗余（供报表 workshop_name facet）

  // 跟单员 / 生产工（id + picker initial 缓存）
  String? _sellerId;
  String? _workerId;
  final Map<String, UtenEmployeePickerItem> _empCache = {};

  final _grid = UtenEditableGridController<ProductionGridRow>();
  final _scrollCtl = ScrollController();
  bool _saving = false;
  bool _loading = false;
  // 制单信息（服务端权威，只读展示）
  String? _makerName;
  String? _createdAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _billNo.dispose();
    _sourceDocNo.dispose();
    _remark.dispose();
    _grid.dispose(); // 自动 dispose 各行控制器
    _scrollCtl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    setState(() => _loading = true);
    await ref.read(masterNameServiceProvider).ensureLoaded();
    if (widget.id == null) {
      // 跟单员默认当前登录人（生产工是车间侧人员，不预填）。
      final meId = ref.read(sessionProvider).user?.employeeId;
      if (meId != null && meId.isNotEmpty) {
        _sellerId = meId;
        await _preloadEmployees([meId]);
      }
    }
    if (widget.id != null) {
      try {
        final d = await ref
            .read(productionPlanRepositoryProvider)
            .detail(widget.id!);
        final goodsIds = d.items
            .map((e) => e.goodsId)
            .whereType<String>()
            .toSet();
        await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
        await _preloadEmployees([d.sellerId, d.workerId]);
        if (!mounted) return;
        _billNo.text = d.billNo ?? '';
        _sourceDocNo.text = d.sourceDocNo ?? '';
        _remark.text = d.remark ?? '';
        if (d.billDate != null) {
          _billDate = DateTime.tryParse(d.billDate!) ?? _billDate;
        }
        _deliveryDate = _parseDate(d.deliveryDate);
        _departmentId = d.departmentId;
        _workshopName = d.workshopName; // 部门名冗余（老库可能为编号字符串）
        _sellerId = d.sellerId;
        _workerId = d.workerId;
        _makerName = d.makerName;
        _createdAt = d.createdAt;
        final rows = <ProductionGridRow>[];
        for (final it in d.items) {
          final row = ProductionGridRow()
            ..productNo.text = it.productNo ?? ''
            ..salesOrderNo.text = it.salesOrderNo ?? ''
            ..remark.text = it.remark ?? ''
            ..colorId = it.colorId
            ..unitId = it.unitId
            ..salesOrderItemId = it.salesOrderItemId
            ..clientName = it.clientName
            ..unitRate = it.unitRate
            ..orderDate = it.orderDate
            ..outboundDate = it.outboundDate
            ..goods = it.goodsId == null
                ? null
                : GoodsOption(
                    id: it.goodsId!,
                    name: ref.read(masterNameServiceProvider).goods(it.goodsId),
                  );
          row.qty.text = it.qty?.toString() ?? '';
          row.oqty.text = it.oqty?.toString() ?? '';
          rows.add(row);
        }
        _grid.replaceAll(rows);
      } on ApiException catch (e) {
        if (mounted) context.appError(e.message);
      } catch (_) {
        // 静默降级
      }
    }
    if (_grid.isEmpty) _grid.addRow(ProductionGridRow());
    if (mounted) setState(() => _loading = false);
  }

  DateTime? _parseDate(String? s) =>
      (s == null || s.isEmpty) ? null : DateTime.tryParse(s);

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

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

  Future<void> _pickGoods(ProductionGridRow row) async {
    final g = await showUtenGoodsPicker(context, ref);
    if (g == null) return;
    final names = ref.read(masterNameServiceProvider);
    row
      ..goods = GoodsOption(id: g.id, code: g.code, name: g.name)
      // 颜色/单位按货品主档自动回填（legacy id → 新库 UUID），单元格只读显示。
      ..colorId = names.colorIdByLegacy(g.colorLegacyId)
      ..unitId = names.unitIdByLegacy(g.unitLegacyId);
  }

  Future<void> _pickSourceOrder() async {
    final d = await showSalesOrderPicker(context, ref);
    if (d == null || !mounted) return;
    setState(() => _sourceDocNo.text = d.billNo ?? '');
    // 选订单后列出该订单货品（含缺口/零件清单），勾选行直接带入明细网格，
    // 行携 salesOrderItemId —— 审核时回写订单行 planned_qty，业务链闭合。
    final lines = await showPlanOrderImportSheet(
      context,
      ref,
      orderId: d.id,
      billNo: d.billNo ?? '',
    );
    if (lines == null || lines.isEmpty || !mounted) return;
    // 已在网格中的订单行不重复带入（后端审核也有防超排硬校验兜底）
    final existing = _grid.rows
        .map((r) => r.salesOrderItemId)
        .whereType<String>()
        .toSet();
    final fresh = lines
        .where((l) => !existing.contains(l.orderItemId))
        .toList(growable: false);
    if (fresh.isEmpty) {
      context.appInfo('所选货品行已在明细中，未重复带入');
      return;
    }
    setState(() {
      // 清掉新建时的占位空行（未选货品的空行）
      for (var i = _grid.length - 1; i >= 0; i--) {
        final r = _grid.rows[i];
        if (r.goods == null && r.productNo.text.trim().isEmpty) {
          _grid.removeAt(i);
        }
      }
      for (final l in fresh) {
        final row = ProductionGridRow()
          ..productNo.text = '${d.billNo ?? ''}-${l.lineNo ?? ''}'
          ..salesOrderNo.text = d.billNo ?? ''
          ..qty.text = _numText(l.needQty)
          ..oqty.text = _numText(l.qty)
          ..salesOrderItemId = l.orderItemId
          ..clientName = l.clientName
          ..unitRate = l.unitRate
          ..outboundDate = l.deliverDate
          ..colorId = l.colorId
          ..unitId = l.unitId
          ..goods = l.goodsId == null
              ? null
              : GoodsOption(
                  id: l.goodsId!,
                  code: l.goodsCode,
                  name: l.goodsName ?? l.goodsCode ?? '',
                );
        _grid.addRow(row);
      }
    });
  }

  String _numText(double? v) => v == null
      ? ''
      : (v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2));

  Future<void> _save() async {
    final rows = _grid.rows;
    if (rows.isEmpty || rows.every((r) => r.goods == null)) {
      context.appError('请至少添加一条明细');
      return;
    }
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      if (r.goods == null) continue;
      if (r.productNo.text.trim().isEmpty) {
        context.appError('第 ${i + 1} 行缺少产品编号');
        return;
      }
      if (double.tryParse(r.qty.text) == null) {
        context.appError('第 ${i + 1} 行排产量无效');
        return;
      }
    }
    final itemsBody = <Map<String, dynamic>>[];
    for (final r in rows) {
      if (r.goods == null) continue;
      itemsBody.add({
        'productNo': r.productNo.text.trim(),
        'goodsId': r.goods!.id,
        'qty': double.tryParse(r.qty.text) ?? 0,
        if (double.tryParse(r.oqty.text) != null)
          'oqty': double.tryParse(r.oqty.text),
        if (r.colorId != null) 'colorId': r.colorId,
        if (r.unitId != null) 'unitId': r.unitId,
        if (r.salesOrderItemId != null) 'salesOrderItemId': r.salesOrderItemId,
        if (r.clientName != null && r.clientName!.isNotEmpty)
          'clientName': r.clientName,
        if (r.unitRate != null) 'unitRate': r.unitRate,
        if (r.outboundDate != null && r.outboundDate!.isNotEmpty)
          'outboundDate': r.outboundDate,
        if (r.salesOrderNo.text.trim().isNotEmpty)
          'salesOrderNo': r.salesOrderNo.text.trim(),
        if (r.remark.text.trim().isNotEmpty) 'remark': r.remark.text.trim(),
      });
    }
    // 单据号后端自动生成（DocNumberService），不再随 body 提交。
    final body = <String, dynamic>{
      'billDate': _fmt(_billDate),
      if (_deliveryDate != null) 'deliveryDate': _fmt(_deliveryDate!),
      if (_departmentId != null) 'departmentId': _departmentId,
      if (_workshopName != null && _workshopName!.trim().isNotEmpty)
        'workshopName': _workshopName,
      if (_sellerId != null) 'sellerId': _sellerId,
      if (_workerId != null) 'workerId': _workerId,
      if (_sourceDocNo.text.trim().isNotEmpty)
        'sourceDocNo': _sourceDocNo.text.trim(),
      if (_remark.text.trim().isNotEmpty) 'remark': _remark.text.trim(),
      'items': itemsBody,
    };
    setState(() => _saving = true);
    try {
      final repo = ref.read(productionPlanRepositoryProvider);
      final d = widget.id == null
          ? await repo.create(body)
          : await repo.update(widget.id!, body);
      if (!mounted) return;
      context.appSuccess(widget.id == null ? '已创建' : '已保存');
      context.replace('/production/plans/${d.id}');
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('保存失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 人员选择器：用 EmployeeRepository.list 模糊搜索作为 loader，按 id 取缓存作为 initial。
  Widget _employeePicker({
    required String label,
    required String? currentId,
    required ValueChanged<String?> onChanged,
  }) {
    return UtenEmployeePicker(
      key: ValueKey('${label}_$currentId'),
      label: label,
      initial: currentId == null ? null : _empCache[currentId],
      loader: (kw) async {
        final res = await ref
            .read(employeeRepositoryProvider)
            .list(size: 30, search: kw);
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

  /// 来源单号：只读 outlined 框 + 放大镜，点按弹销售订单选择器。
  Widget _sourceDocField(ThemeData theme) {
    return InkWell(
      onTap: _pickSourceOrder,
      borderRadius: BorderRadius.circular(UtenSpacing.s8),
      child: InputDecorator(
        decoration: const InputDecoration(
          labelText: '来源单号',
          suffixIcon: Icon(Icons.search_rounded, size: 18),
        ),
        child: Text(
          _sourceDocNo.text.isEmpty ? '点击选择销售订单' : _sourceDocNo.text,
          style: TextStyle(
            color: _sourceDocNo.text.isEmpty
                ? theme.colorScheme.onSurfaceVariant
                : null,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    final workshopTree = ref.watch(productionWorkshopTreeProvider).valueOrNull;
    return Scaffold(
      appBar: UtenAppBar(
        title: widget.id == null ? '新建生产计划单' : '编辑生产计划单',
        leading: UtenBackButton(
          onPressed: () => popOrBackTo(context, defaultPath: '/production'),
        ),
        actions: [
          UtenButton(
            type: UtenButtonType.tonal,
            icon: Icons.history_rounded,
            onPressed: () => context.push('/production/plans'),
            child: const Text('查看历史'),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
            : UtenContentContainer(
                child: Scrollbar(
                  controller: _scrollCtl,
                  thumbVisibility: true,
                  child: ListView(
                    controller: _scrollCtl,
                    padding: const EdgeInsets.all(UtenSpacing.s12),
                    children: [
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(UtenSpacing.s12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              UtenFormGrid(
                                children: [
                                  // 单据号：系统自动生成，只读显示。
                                  TextFormField(
                                    readOnly: true,
                                    controller: _billNo,
                                    decoration: InputDecoration(
                                      labelText: '单据号',
                                      hintText: _billNo.text.isEmpty
                                          ? '保存后自动生成'
                                          : null,
                                      filled: _billNo.text.isEmpty,
                                      suffixIcon: _billNo.text.isEmpty
                                          ? const Icon(
                                              Icons.autorenew_outlined,
                                              size: 18,
                                            )
                                          : const Icon(
                                              Icons.lock_outline,
                                              size: 16,
                                            ),
                                    ),
                                  ),
                                  // 制单员/制单时间：服务端权威，只读展示（责任制）。
                                  ...utenMakerAuditCells(
                                    ref,
                                    makerName: _makerName,
                                    createdAt: _createdAt,
                                  ),
                                  UtenDateField(
                                    label: '单据日期',
                                    required: true,
                                    value: _billDate,
                                    onChanged: (d) =>
                                        setState(() => _billDate = d),
                                  ),
                                  UtenDateField(
                                    label: '交货日',
                                    value: _deliveryDate,
                                    onChanged: (d) =>
                                        setState(() => _deliveryDate = d),
                                  ),
                                  // 车间 = 部门选择器（落 department_id；部门名冗余 workshop_name）。
                                  UtenDepartmentPicker(
                                    mode: UtenDepartmentPickerMode.single,
                                    label: '车间',
                                    hint: '选择生产车间（部门）',
                                    treeOverride: workshopTree,
                                    initialSelection: _departmentId == null
                                        ? const []
                                        : [
                                            DeptSelection(
                                              id: _departmentId!,
                                              name: _workshopName ?? '',
                                              fullPath: '',
                                              level: '',
                                            ),
                                          ],
                                    onChanged: (sel) {
                                      final s = sel.isEmpty ? null : sel.first;
                                      setState(() {
                                        _departmentId = s?.id;
                                        _workshopName = s?.name; // 部门名冗余
                                      });
                                    },
                                  ),
                                  _employeePicker(
                                    label: '跟单员',
                                    currentId: _sellerId,
                                    onChanged: (id) =>
                                        setState(() => _sellerId = id),
                                  ),
                                  _employeePicker(
                                    label: '生产工',
                                    currentId: _workerId,
                                    onChanged: (id) =>
                                        setState(() => _workerId = id),
                                  ),
                                  _sourceDocField(theme),
                                ],
                              ),
                              const SizedBox(height: UtenSpacing.s12),
                              TextField(
                                controller: _remark,
                                decoration: const InputDecoration(
                                  labelText: '备注',
                                ),
                                maxLines: 2,
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s12),
                      Text(
                        '明细 (${_grid.length})',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      UtenEditableGrid<ProductionGridRow>(
                        controller: _grid,
                        columns: productionGridColumns(
                          onPickGoods: _pickGoods,
                          colorEntries: names.colorEntries,
                          unitEntries: names.unitEntries,
                        ),
                        createBlankRow: () => ProductionGridRow(),
                      ),
                    ],
                  ),
                ),
              ),
      ),
      bottomNavigationBar: SafeArea(
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
              ValueListenableBuilder<double>(
                valueListenable: _grid.totalListenable,
                builder: (_, total, _) => Text(
                  '排产合计 ${total.toStringAsFixed(2)}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
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
      ),
    );
  }
}
