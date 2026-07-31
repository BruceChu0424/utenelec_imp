// 生产日报编辑页（新建/编辑，全页路由）：与生产计划/销售编辑页同构（统一模板）。
//
// 日报特点：
//   - 明细有金额（完工量 × 单价 → 金额，AmountRowMixin；表尾合计 ¥）。
//   - 单据号系统自动生成（后端 DocNumberService，PRODUCTION_DAILY_REPORT），本页只读显示。
//   - 仓库 = 下拉（UtenDropdownField，warehouseId）；车间 = 部门选择器（department_id + 部门名冗余 workshop_name）；
//     生产工 = 员工选择器（workerId）。
//   - 后端 DailyReportSaveRequest 已具备 departmentId/workerId/warehouseId，纯前端改动。
//   - 明细行：goodsId（必填）+ qty 完工量（必填）+ price 单价 + color/unit + planNo（关联计划号）+ remark。
//
// 仅草稿可编辑（后端校验；已审走详情页红冲）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
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
import '../../../shared/providers/master_name_provider.dart';
import '../providers/production_department_provider.dart';
import '../repositories/production_repository.dart';
import '../widgets/production_daily_grid_columns.dart';
import '../widgets/reportable_plan_line_picker.dart';

class ProductionDailyReportEditPage extends ConsumerStatefulWidget {
  const ProductionDailyReportEditPage({
    super.key,
    this.id,
    this.initialExecutionSegmentId,
  });
  final String? id; // null=新建
  final String? initialExecutionSegmentId;

  @override
  ConsumerState<ProductionDailyReportEditPage> createState() =>
      _ProductionDailyReportEditPageState();
}

class _ProductionDailyReportEditPageState
    extends ConsumerState<ProductionDailyReportEditPage> {
  final _billNo = TextEditingController(); // 只读显示（后端自动生成）
  final _remark = TextEditingController();
  DateTime _billDate = ChinaDateTime.today();

  String? _warehouseId;
  // 车间 = 部门
  String? _departmentId;
  String? _workshopName; // 部门名冗余（供报表 workshop_name facet）
  // 生产工
  String? _workerId;
  final Map<String, UtenEmployeePickerItem> _empCache = {};

  final _grid = UtenEditableGridController<DailyGridRow>();
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
    _remark.dispose();
    _grid.dispose(); // 自动 dispose 各行控制器
    _scrollCtl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    setState(() => _loading = true);
    await ref.read(masterNameServiceProvider).ensureLoaded();
    if (widget.id != null) {
      try {
        final d = await ref
            .read(productionDailyReportRepositoryProvider)
            .detail(widget.id!);
        final goodsIds = d.items
            .map((e) => e.goodsId)
            .whereType<String>()
            .toSet();
        await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
        await _preloadEmployees([d.workerId]);
        if (!mounted) return;
        _billNo.text = d.billNo ?? '';
        _remark.text = d.remark ?? '';
        if (d.billDate != null) {
          _billDate = DateTime.tryParse(d.billDate!) ?? _billDate;
        }
        _warehouseId = d.warehouseId;
        _departmentId = d.departmentId;
        _workshopName = d.workshopName;
        _workerId = d.workerId;
        _makerName = d.makerName;
        _createdAt = d.createdAt;
        final rows = <DailyGridRow>[];
        for (final it in d.items) {
          final row = DailyGridRow()
            ..planNo.text = it.planNo ?? ''
            ..remark.text = it.remark ?? ''
            ..planItemId = it.planItemId
            ..executionSegmentId = it.executionSegmentId
            ..executionSegmentSalesAllocationId =
                it.executionSegmentSalesAllocationId
            ..salesOrderItemId = it.salesOrderItemId
            ..salesOrderNo = it.salesOrderNo
            ..clientName = it.clientName
            ..unitRate = it.unitRate
            ..orderQty = it.orderQty
            ..legacyManual =
                it.planItemId == null && (it.planNo?.isEmpty ?? true)
            ..colorId = it.colorId
            ..unitId = it.unitId
            ..goods = it.goodsId == null
                ? null
                : GoodsOption(
                    id: it.goodsId!,
                    name: ref.read(masterNameServiceProvider).goods(it.goodsId),
                  );
          row.qty.text = it.qty?.toString() ?? '';
          row.price.text = it.price?.toString() ?? '';
          row.isFinal = it.isFinal;
          rows.add(row);
        }
        _grid.replaceAll(rows);
      } on ApiException catch (e) {
        if (mounted) context.appError(e.message);
      } catch (_) {
        // 静默降级
      }
    }
    if (_grid.isEmpty) _grid.addRow(DailyGridRow());
    if (!mounted) return;
    setState(() => _loading = false);
    final initialSegmentId = widget.initialExecutionSegmentId;
    if (widget.id == null &&
        initialSegmentId != null &&
        initialSegmentId.isNotEmpty &&
        _grid.rows.isNotEmpty) {
      await _pickSource(_grid.rows.first, executionSegmentId: initialSegmentId);
    }
  }

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
          // 静默
        }
      }),
    );
  }

  Future<void> _pickGoods(DailyGridRow row) async {
    if (!row.legacyManual) {
      await _pickSource(row);
      return;
    }
    final g = await showUtenGoodsPicker(context, ref);
    if (g == null) return;
    final names = ref.read(masterNameServiceProvider);
    row
      ..goods = GoodsOption(id: g.id, code: g.code, name: g.name)
      ..colorId = names.colorIdByLegacy(g.colorLegacyId)
      ..unitId = names.unitIdByLegacy(g.unitLegacyId);
  }

  Future<void> _pickSource(
    DailyGridRow row, {
    String? executionSegmentId,
  }) async {
    final source = await showReportablePlanLinePicker(
      context,
      ref,
      departmentId: _departmentId,
      executionSegmentId: executionSegmentId,
    );
    if (source == null || !mounted) return;
    setState(() {
      row
        ..planItemId = source.planItemId
        ..executionSegmentId = source.executionSegmentId
        ..executionSegmentSalesAllocationId =
            source.executionSegmentSalesAllocationId
        ..executionSegmentCode = source.executionSegmentCode
        ..executionSegmentVersion = source.executionSegmentVersion
        ..salesOrderItemId = source.orderItemId
        ..salesOrderNo = source.orderNo
        ..clientName = source.clientName
        ..unitRate = source.unitRate
        ..orderQty = source.orderQty
        ..maxReportQty = source.maxReportQty
        ..legacyManual = false
        ..planNo.text = source.planNo
        ..goods = GoodsOption(
          id: source.goodsId,
          code: source.goodsCode,
          name: source.goodsName,
        )
        ..colorId = source.colorId
        ..unitId = source.unitId
        ..qty.text = _quantityText(source.maxReportQty);
      if (_departmentId == null && source.departmentId != null) {
        _departmentId = source.departmentId;
        _workshopName = source.workshopName;
      }
    });
  }

  void _clearSource(DailyGridRow row) {
    setState(() {
      row
        ..planItemId = null
        ..executionSegmentId = null
        ..executionSegmentSalesAllocationId = null
        ..executionSegmentCode = null
        ..executionSegmentVersion = null
        ..salesOrderItemId = null
        ..salesOrderNo = null
        ..clientName = null
        ..unitRate = null
        ..orderQty = null
        ..maxReportQty = null
        ..legacyManual = false
        ..planNo.clear()
        ..goods = null
        ..colorId = null
        ..unitId = null
        ..qty.clear();
    });
  }

  String _quantityText(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(4).replaceFirst(RegExp(r'0+$'), '');

  Future<void> _save() async {
    final rows = _grid.rows;
    if (rows.isEmpty || rows.every((r) => r.goods == null)) {
      context.appError('请至少添加一条明细');
      return;
    }
    if (_warehouseId == null &&
        rows.any((row) => row.executionSegmentId != null)) {
      context.appError('执行子计划报工必须选择成品入库仓库');
      return;
    }
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      if (r.goods == null) continue;
      final qty = double.tryParse(r.qty.text);
      if (qty == null || qty <= 0) {
        context.appError('第 ${i + 1} 行合格完工量必须大于 0');
        return;
      }
      if (!r.legacyManual && !r.hasLinkedSource) {
        context.appError('第 ${i + 1} 行必须先选择来源子任务');
        return;
      }
      if (r.hasLinkedSource &&
          (r.unitId == null || r.unitRate == null || r.unitRate! <= 0)) {
        context.appError('第 ${i + 1} 行来源任务缺少有效单位或换算率，请维护计划后重试');
        return;
      }
      if (r.maxReportQty != null && qty > r.maxReportQty! + 0.000001) {
        context.appError(
          '第 ${i + 1} 行合格完工量超过当前可报数量 ${_quantityText(r.maxReportQty!)}',
        );
        return;
      }
    }
    final sourceTotals = <String, double>{};
    final sourceCaps = <String, double>{};
    for (final r in rows.where((row) => row.hasLinkedSource)) {
      final key =
          r.executionSegmentSalesAllocationId ??
          '${r.executionSegmentId ?? r.planItemId}:'
              '${r.salesOrderItemId ?? 'internal'}';
      sourceTotals[key] =
          (sourceTotals[key] ?? 0) + (double.tryParse(r.qty.text) ?? 0);
      if (r.maxReportQty != null) sourceCaps[key] = r.maxReportQty!;
    }
    for (final entry in sourceTotals.entries) {
      final cap = sourceCaps[entry.key];
      if (cap != null && entry.value > cap + 0.000001) {
        context.appError('同一来源子任务的累计合格完工量超过当前可报数量 ${_quantityText(cap)}');
        return;
      }
    }
    final itemsBody = <Map<String, dynamic>>[];
    for (final r in rows) {
      if (r.goods == null) continue;
      final qty = double.tryParse(r.qty.text) ?? 0;
      final price = double.tryParse(r.price.text);
      itemsBody.add({
        'goodsId': r.goods!.id,
        'qty': qty,
        if (price != null) ...{'price': price, 'total': qty * price},
        if (r.colorId != null) 'colorId': r.colorId,
        if (r.unitId != null) 'unitId': r.unitId,
        if (r.unitRate != null) 'unitRate': r.unitRate,
        if (r.planItemId != null) 'planItemId': r.planItemId,
        if (r.executionSegmentId != null)
          'executionSegmentId': r.executionSegmentId,
        if (r.executionSegmentSalesAllocationId != null)
          'executionSegmentSalesAllocationId':
              r.executionSegmentSalesAllocationId,
        if (r.salesOrderItemId != null) 'salesOrderItemId': r.salesOrderItemId,
        if (r.salesOrderNo != null) 'salesOrderNo': r.salesOrderNo,
        if (r.clientName != null) 'clientName': r.clientName,
        if (r.orderQty != null) 'orderQty': r.orderQty,
        if (r.planNo.text.trim().isNotEmpty) 'planNo': r.planNo.text.trim(),
        if (r.isFinal) 'isFinal': true,
        if (r.remark.text.trim().isNotEmpty) 'remark': r.remark.text.trim(),
      });
    }
    // 单据号后端自动生成（DocNumberService），不再随 body 提交。
    final body = <String, dynamic>{
      'billDate': _fmt(_billDate),
      if (_warehouseId != null) 'warehouseId': _warehouseId,
      if (_departmentId != null) 'departmentId': _departmentId,
      if (_workshopName != null && _workshopName!.trim().isNotEmpty)
        'workshopName': _workshopName,
      if (_workerId != null) 'workerId': _workerId,
      if (_remark.text.trim().isNotEmpty) 'remark': _remark.text.trim(),
      'items': itemsBody,
    };
    setState(() => _saving = true);
    try {
      final repo = ref.read(productionDailyReportRepositoryProvider);
      final d = widget.id == null
          ? await repo.create(body)
          : await repo.update(widget.id!, body);
      if (!mounted) return;
      context.appSuccess(widget.id == null ? '已创建' : '已保存');
      context.replace('/production/daily-reports/${d.id}');
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

  Widget _dropdown(
    String label,
    String? value,
    Map<String, String> entries,
    ValueChanged<String?> onChanged,
  ) {
    return UtenDropdownField(
      label: label,
      value: value,
      items: [
        for (final e in entries.entries)
          UtenDropdownItem(value: e.key, label: e.value),
        if (value != null && value.isNotEmpty && !entries.containsKey(value))
          UtenDropdownItem(value: value, label: value),
      ],
      onChanged: onChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    final workshopTree = ref.watch(productionWorkshopTreeProvider).valueOrNull;
    return Scaffold(
      appBar: UtenAppBar(
        title: widget.id == null ? '新建生产日报' : '编辑生产日报',
        showBackButton: true,
        actions: [
          UtenButton(
            type: UtenButtonType.tonal,
            icon: Icons.history_rounded,
            onPressed: () => context.push('/production/daily-reports'),
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
                                  _dropdown(
                                    '仓库',
                                    _warehouseId,
                                    names.warehouseEntries,
                                    (v) {
                                      setState(() => _warehouseId = v);
                                    },
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
                                    label: '生产工',
                                    currentId: _workerId,
                                    onChanged: (id) =>
                                        setState(() => _workerId = id),
                                  ),
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
                      Container(
                        padding: const EdgeInsets.all(UtenSpacing.s12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.tertiaryContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.info_outline_rounded,
                              color: theme.colorScheme.onTertiaryContainer,
                            ),
                            const SizedBox(width: UtenSpacing.s8),
                            Expanded(
                              child: Text(
                                '数量口径：这里只填写可进入成品入库的合格完工量，不良品不得计入。'
                                '发现不良时请暂停审核并交由生产主管处理；不良品隔离、返工和补产链路'
                                '未上线前，系统不会把不良数量自动当成合格成品。',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onTertiaryContainer,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s12),
                      Text(
                        '明细 (${_grid.length})',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      UtenEditableGrid<DailyGridRow>(
                        controller: _grid,
                        columns: dailyGridColumns(
                          onPickGoods: _pickGoods,
                          onPickSource: _pickSource,
                          onClearSource: _clearSource,
                          colorEntries: names.colorEntries,
                          unitEntries: names.unitEntries,
                        ),
                        createBlankRow: () => DailyGridRow(),
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
                  '合计 ¥${total.toStringAsFixed(2)}',
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
