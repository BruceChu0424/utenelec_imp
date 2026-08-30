// 生产日报编辑页（新建/编辑，全页路由）：与生产计划/销售编辑页同构（统一模板）。
//
// 日报特点：
//   - 明细只记录完工申报数量；品质通过与仓库实收分别决定可入库量和 iqty。
//   - 单据号系统自动生成（后端 DocNumberService，PRODUCTION_DAILY_REPORT），本页只读显示。
//   - 仓库 = 下拉（UtenDropdownField，warehouseId）；车间 = 部门选择器（department_id + 部门名冗余 workshop_name）；
//     生产参与人员 = 多选员工(workerIds；首位兼容 workerId)。
//   - 明细行：goodsId（必填）+ qty 完工量（必填）+ color/unit + 精确来源子任务 + remark。
//
// 仅草稿可编辑（后端校验；已审走详情页红冲）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/inputs/uten_employee_multi_picker.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/document_scope_capability.dart';
import '../../../core/utils/china_datetime.dart';
import '../../department/models/department_node.dart';
import '../../department/repositories/department_repository.dart';
import '../../department/widgets/uten_department_picker.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../models/production_daily_report.dart';
import '../models/reportable_plan_line.dart';
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
  // 本次日报整单参与人员；不表达行级贡献或计件分配。
  List<UtenEmployeePickerItem> _workers = const [];
  final Map<String, UtenEmployeePickerItem> _empCache = {};

  /// 生产工 picker 默认范围：生产部（DEPT_PROD）子树 id；解析前 picker 回退全公司。
  String? _productionDeptId;

  final _grid = UtenEditableGridController<DailyGridRow>();
  final _scrollCtl = ScrollController();
  bool _saving = false;
  bool _loading = false;
  int _rowVersion = 0;
  final String _createIdempotencyKey =
      'daily-report-create-${const Uuid().v4()}';
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
    await _resolveDeptIds();
    if (widget.id != null) {
      try {
        final d = await ref
            .read(productionDailyReportRepositoryProvider)
            .detail(widget.id!);
        final writable =
            d.status == kProductionStatusDraft &&
            await loadDocumentOwnerCanWrite(
              ref,
              DocumentDataScope.productionPlan,
              d.makerId,
            );
        if (!mounted) return;
        if (!writable) {
          context.appWarning(documentScopeReadOnlyMessage, force: true);
          context.replace(RoutePath.productionDailyReportDetail(widget.id!));
          return;
        }
        final goodsIds = d.items
            .map((e) => e.goodsId)
            .whereType<String>()
            .toSet();
        await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
        await _preloadEmployees(d.workerIds);
        if (!mounted) return;
        _billNo.text = d.billNo ?? '';
        _remark.text = d.remark ?? '';
        if (d.billDate != null) {
          _billDate = DateTime.tryParse(d.billDate!) ?? _billDate;
        }
        _warehouseId = d.warehouseId;
        _departmentId = d.departmentId;
        _workshopName = d.workshopName;
        _workers = [
          for (final id in d.workerIds)
            _empCache[id] ?? UtenEmployeePickerItem(id: id, name: '已选生产工'),
        ];
        _makerName = d.makerName;
        _createdAt = d.createdAt;
        _rowVersion = d.rowVersion;
        final rows = <DailyGridRow>[];
        for (final it in d.items) {
          final row = DailyGridRow()
            ..planNo.text = it.planNo ?? ''
            ..remark.text = it.remark ?? ''
            ..planItemId = it.planItemId
            ..executionSegmentId = it.executionSegmentId
            ..executionSegmentSalesAllocationId =
                it.executionSegmentSalesAllocationId
            ..fqcRecoveryAuthorizationId = it.fqcRecoveryAuthorizationId
            ..fqcRecoveryDispositionCode = it.fqcRecoveryAuthorizationId == null
                ? null
                : 'RECOVERY'
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
      await _loadInitialSource(
        _grid.rows.first,
        executionSegmentId: initialSegmentId,
      );
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
            employeeCode: p.code,
            departmentName: p.departmentName,
          );
        } catch (_) {
          // 静默
        }
      }),
    );
  }

  Future<void> _pickGoods(DailyGridRow row) async {
    await _pickSource(row);
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
    if (!source.canReport) {
      context.appWarning(
        source.blockedReason ?? '当前来源没有可报数量，请刷新后重试',
        force: true,
      );
      return;
    }
    _applySource(row, source);
  }

  /// 卡片“分批报工”已给出精确执行子任务。若读侧只有一条可报分摊，直接
  /// 应用并预填数量；同一执行段包含多条销售分摊时仍让用户确认，避免串单。
  Future<void> _loadInitialSource(
    DailyGridRow row, {
    required String executionSegmentId,
  }) async {
    try {
      final page = await ref
          .read(productionDailyReportRepositoryProvider)
          .reportablePlanLines(
            size: 2,
            departmentId: _departmentId,
            executionSegmentId: executionSegmentId,
          );
      if (!mounted) return;
      final source = uniqueReportablePlanLine(page.items, page.total);
      if (source != null) {
        if (!source.canReport) {
          context.appWarning(
            source.blockedReason ?? '当前执行子计划没有可报数量，请刷新后重试',
            force: true,
          );
          return;
        }
        _applySource(row, source);
        return;
      }
      if (page.total == 0 || page.items.isEmpty) {
        context.appWarning('当前执行子计划没有可报来源，任务状态可能已被其他人更新', force: true);
        return;
      }
      context.appWarning('当前执行子计划包含多个销售分摊，请确认本次报工对应的订单来源', force: true);
      await _pickSource(row, executionSegmentId: executionSegmentId);
    } catch (error) {
      if (!mounted) return;
      context.appError(
        productionErrorMessage(error, fallback: '当前执行子计划加载失败，请稍后重试'),
      );
    }
  }

  void _applySource(DailyGridRow row, ReportablePlanLine source) {
    if (!mounted) return;
    setState(() {
      row
        ..planItemId = source.planItemId
        ..executionSegmentId = source.executionSegmentId
        ..executionSegmentSalesAllocationId =
            source.executionSegmentSalesAllocationId
        ..executionSegmentCode = source.executionSegmentCode
        ..executionSegmentVersion = source.executionSegmentVersion
        ..fqcRecoveryAuthorizationId = source.fqcRecoveryAuthorizationId
        ..fqcRecoveryDispositionCode = source.fqcRecoveryDispositionCode
        ..fqcSourceReportNo = source.fqcSourceReportNo
        ..isFinal = false
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
        ..fqcRecoveryAuthorizationId = null
        ..fqcRecoveryDispositionCode = null
        ..fqcSourceReportNo = null
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
        context.appError('第 ${i + 1} 行完工申报量必须大于 0');
        return;
      }
      if (!r.hasLinkedSource || r.executionSegmentId == null) {
        context.appError('第 ${i + 1} 行必须先选择已开工的精确执行子任务');
        return;
      }
      if (r.hasLinkedSource &&
          (r.unitId == null || r.unitRate == null || r.unitRate! <= 0)) {
        context.appError('第 ${i + 1} 行来源任务缺少有效单位或换算率，请维护计划后重试');
        return;
      }
      if (r.maxReportQty != null && qty > r.maxReportQty! + 0.000001) {
        context.appError(
          '第 ${i + 1} 行完工申报量超过当前可报数量 ${_quantityText(r.maxReportQty!)}',
        );
        return;
      }
      if (r.fqcRecoveryAuthorizationId != null && r.isFinal) {
        context.appError('第 ${i + 1} 行是 FQC 返工/补产恢复报工，不能勾选完结');
        return;
      }
    }
    final sourceTotals = <String, double>{};
    final sourceCaps = <String, double>{};
    for (final r in rows.where((row) => row.hasLinkedSource)) {
      final key =
          r.fqcRecoveryAuthorizationId ??
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
        context.appError('同一来源子任务的累计完工申报量超过当前可报数量 ${_quantityText(cap)}');
        return;
      }
    }
    final itemsBody = <Map<String, dynamic>>[];
    for (final r in rows) {
      if (r.goods == null) continue;
      if (r.planItemId == null && r.planNo.text.trim().isNotEmpty) {
        context.appError('旧报工行只有计划号快照，不能自动猜关联；请重新选择来源子任务或清除来源');
        return;
      }
      if (r.salesOrderItemId == null &&
          (r.salesOrderNo?.trim().isNotEmpty ?? false)) {
        context.appError('旧报工行只有销售订单号快照，请重新选择来源子任务或清除来源');
        return;
      }
      final qty = double.tryParse(r.qty.text) ?? 0;
      itemsBody.add({
        'goodsId': r.goods!.id,
        'qty': qty,
        if (r.colorId != null) 'colorId': r.colorId,
        if (r.unitId != null) 'unitId': r.unitId,
        if (r.unitRate != null) 'unitRate': r.unitRate,
        if (r.planItemId != null) 'planItemId': r.planItemId,
        if (r.executionSegmentId != null)
          'executionSegmentId': r.executionSegmentId,
        if (r.executionSegmentSalesAllocationId != null)
          'executionSegmentSalesAllocationId':
              r.executionSegmentSalesAllocationId,
        if (r.fqcRecoveryAuthorizationId != null)
          'fqcRecoveryAuthorizationId': r.fqcRecoveryAuthorizationId,
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
      if (_workers.isNotEmpty) 'workerId': _workers.first.id,
      'workerIds': [for (final worker in _workers) worker.id],
      if (_remark.text.trim().isNotEmpty) 'remark': _remark.text.trim(),
      'items': itemsBody,
    };
    setState(() => _saving = true);
    try {
      final repo = ref.read(productionDailyReportRepositoryProvider);
      final d = widget.id == null
          ? await repo.create(body, idempotencyKey: _createIdempotencyKey)
          : await repo.update(widget.id!, body, expectedVersion: _rowVersion);
      if (!mounted) return;
      context.appSuccess(widget.id == null ? '已创建' : '已保存');
      context.replace('/production/daily-reports/${d.id}');
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == 'CONFLICT' && widget.id != null) {
        context.appWarning(
          '保存冲突：该日报已被其他人修改。当前输入仍保留，请核对后重新进入最新草稿再编辑。',
          force: true,
        );
      } else {
        context.appError(e.message);
      }
    } catch (_) {
      if (mounted) context.appError('保存失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 预解析生产部（DEPT_PROD）子树 id，供生产工 picker 默认收敛范围。
  Future<void> _resolveDeptIds() async {
    try {
      final tree = await ref.read(departmentRepositoryProvider).tree();
      _productionDeptId = findDepartmentByCode(tree, kDeptCodeProduction)?.id;
    } catch (_) {
      // 解析失败：picker 回退全公司，不阻塞编辑。
    }
  }

  Widget _workerPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        UtenEmployeeMultiPicker(
          key: ValueKey(_workers.map((worker) => worker.id).join('|')),
          enabled: _departmentId != null || _productionDeptId != null,
          label: '生产参与人员',
          hint: '可选择多人或整条流水线成员',
          sheetTitle: '选择本次报工参与人员',
          searchHint: '搜索生产部员工姓名 / 工号',
          emptyMessage: '当前生产部门没有匹配的在职或试用员工',
          initialSelection: _workers,
          loader: (kw) async {
            final deptId = _departmentId ?? _productionDeptId;
            if (deptId == null) return const <UtenEmployeePickerItem>[];
            final res = await ref
                .read(employeeRepositoryProvider)
                .list(
                  size: 100,
                  search: kw,
                  statuses: const {'active', 'probation'},
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
          onChanged: (items) => setState(() {
            _workers = List.unmodifiable(items);
            for (final item in items) {
              _empCache[item.id] = item;
            }
          }),
        ),
        const SizedBox(height: UtenSpacing.s4),
        Text(
          '候选范围：制造与研发管理中心 / 生产部。选择车间后收窄到该车间及班组；'
          '这里记录整单参与人员，不代表个人产量或计件工资。',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
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
    final workforceTree = ref
        .watch(productionWorkforceTreeProvider)
        .valueOrNull;
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
                                    errorBuilder: utenTextFieldErrorBuilder,
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
                                    hint: '选择生产车间(部门)',
                                    selectablePredicate: (node) =>
                                        workforceTree?.productionDepartmentId !=
                                            null &&
                                        node.parentId ==
                                            workforceTree!
                                                .productionDepartmentId,
                                    treeOverride:
                                        workforceTree?.tree ?? const [],
                                    expandOnRowTap: true,
                                    initiallyExpandedIds:
                                        workforceTree?.initiallyExpandedIds ??
                                        const {},
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
                                  _workerPicker(),
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
                                '数量口径：这里只填写本次实际完工申报量。审核后先进入生产成品质检；'
                                '只有品质通过数量会生成仓库待点收任务，仓库实收后才增加库存与完成率。'
                                '疑似不良也应按实际完工事实申报，由品质登记通过、返工、报废或拒收。',
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
