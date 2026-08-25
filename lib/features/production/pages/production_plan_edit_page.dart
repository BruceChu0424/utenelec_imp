// 生产计划单编辑页（新建/编辑，全页路由）：主表头表单 + 明细可编辑 Excel 表（UtenEditableGrid）+ 保存。
//
// 与销售/采购编辑页同构（统一模板：UtenFormGrid 表头 + UtenDateField 日期 + UtenEditableGrid 明细）。
// 生产计划特点：
//   - 无币种/供应商/金额（数量驱动）：明细排产量→表尾「排产合计」（qtyNotifier 复用 grid.totalListenable）。
//   - 单据号系统自动生成（后端 DocNumberService，PRODUCTION_PLAN "SJ"），本页只读显示。
//   - 车间=部门选择器（UtenDepartmentPicker，落 department_id；部门名冗余写 workshop_name 供报表 facet）。
//   - 跟单员/生产工=员工选择器（UtenEmployeePicker，落 seller_id/worker_id，加列；name 留底）。
//   - 来源单号=销售订单选择器（showSalesOrderPicker，回填单号字符串；头表来源单号是冗余文本）。
//   - 明细行：productNo 可显式填写，留空由后端按计划号分配；goodsId/qty 必填。
//
// 仅草稿可编辑（后端校验，前端不再重复判断；已审单据走详情页红冲）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../basic_data/widgets/uten_goods_picker.dart';
import '../../department/models/department_node.dart';
import '../../department/repositories/department_repository.dart';
import '../../department/widgets/uten_department_picker.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../../shared/auth/document_scope_capability.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/widgets/sales_order_picker.dart';
import '../providers/production_department_provider.dart';
import '../models/production_material_analysis.dart';
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
  static const _manualSourceOptions = <String, String>{
    'REWORK': '返工',
    'TRIAL': '试制',
    'SAMPLE': '样品',
    'STOCK': '备库',
    'OTHER': '其他',
  };

  final _billNo = TextEditingController(); // 只读显示（后端自动生成）
  final _remark = TextEditingController();
  final _manualSourceRef = TextEditingController();
  final _manualSourceReason = TextEditingController();
  String? _manualSourceType;
  DateTime _billDate = ChinaDateTime.today();
  DateTime? _deliveryDate;

  // 来源单号：由明细行 salesOrderNo 派生（去重合并），与明细相互同步、支持多个来源订单。
  // 点击来源单号字段弹销售订单选择器，可多次选择不同订单，各自带入明细行。
  String _sourceDocDisplay = '';

  // 车间 = 部门
  String? _departmentId;
  String? _workshopName; // 部门名冗余（供报表 workshop_name facet）

  // 跟单员 / 生产工（id + picker initial 缓存）
  String? _sellerId;
  String? _workerId;
  final Map<String, UtenEmployeePickerItem> _empCache = {};

  /// 跟单员是否由选订单自动回填（软联动）：true 时，明细中不再有该销售员的行才自动清除；
  /// 用户手选跟单员后置 false，不会被自动清除。
  bool _sellerAutoFilled = false;

  /// 部门化 picker 默认范围 id（_init 预解析；解析前 picker 回退全公司）。
  String? _marketingDeptId;
  String? _productionDeptId;

  final _grid = UtenEditableGridController<ProductionGridRow>();
  final _scrollCtl = ScrollController();
  bool _saving = false;
  bool _loading = true;
  String? _initializationError;
  // 制单信息（服务端权威，只读展示）
  String? _makerName;
  String? _createdAt;

  @override
  void initState() {
    super.initState();
    // 行增删（addRow/removeAt/replaceAll）时刷新来源单号派生显示。
    _grid.addListener(_refreshSourceDoc);
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _billNo.dispose();
    _remark.dispose();
    _manualSourceRef.dispose();
    _manualSourceReason.dispose();
    _grid.removeListener(_refreshSourceDoc);
    _grid.dispose(); // 自动 dispose 各行控制器
    _scrollCtl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _initializationError = null;
    });
    try {
      await ref.read(masterNameServiceProvider).ensureLoaded();
      await _resolveDeptIds();
      if (widget.id == null) {
        // 跟单员默认当前登录人（生产工是车间侧人员，不预填）。
        final meId = ref.read(sessionProvider).user?.employeeId;
        if (meId != null && meId.isNotEmpty) {
          _sellerId = meId;
          await _preloadEmployees([meId]);
        }
      }
      if (widget.id != null) {
        final d = await ref
            .read(productionPlanRepositoryProvider)
            .detail(widget.id!);
        final writable =
            d.allowedActions.contains('EDIT') &&
            await loadDocumentOwnerCanWrite(
              ref,
              DocumentDataScope.productionPlan,
              d.makerId,
            );
        if (!mounted) return;
        if (!writable) {
          context.appWarning(documentScopeReadOnlyMessage, force: true);
          context.replace(RoutePath.productionPlanDetail(widget.id!));
          return;
        }
        final goodsIds = d.items
            .map((e) => e.goodsId)
            .whereType<String>()
            .toSet();
        await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
        await _preloadEmployees([d.sellerId, d.workerId]);
        if (!mounted) return;
        _billNo.text = d.billNo ?? '';
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
        for (final r in rows) {
          _wireRow(r);
        }
        _grid.replaceAll(rows);
      }
      if (_grid.isEmpty) {
        final blank = ProductionGridRow();
        _wireRow(blank);
        _grid.addRow(blank);
      }
    } on ApiException catch (e) {
      _initializationError = e.message;
    } catch (_) {
      _initializationError = '无法读取完整单据数据，请检查网络或权限后重试';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  DateTime? _parseDate(String? s) =>
      (s == null || s.isEmpty) ? null : DateTime.tryParse(s);

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// 预解析跟单员（MKT_CENTER）/生产工（DEPT_PROD）默认部门 id，供 picker loader 收敛范围。
  Future<void> _resolveDeptIds() async {
    try {
      final tree = await ref.read(departmentRepositoryProvider).tree();
      _marketingDeptId = findDepartmentByCode(tree, kDeptCodeMarketing)?.id;
      _productionDeptId = findDepartmentByCode(tree, kDeptCodeProduction)?.id;
    } catch (_) {
      // 解析失败：picker 回退全公司，不阻塞编辑。
    }
  }

  /// 按 code 取已解析的部门 id（loader 关键字为空时用）。
  String? _deptIdFor(String code) {
    switch (code) {
      case kDeptCodeMarketing:
        return _marketingDeptId;
      case kDeptCodeProduction:
        return _productionDeptId;
      default:
        return null;
    }
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

  Future<void> _pickGoods(ProductionGridRow row) async {
    final g = await showUtenGoodsPicker(context, ref);
    if (g == null) return;
    row
      ..goods = GoodsOption(id: g.id, code: g.code, name: g.name)
      // 颜色/单位直接回填货品主档 UUID，单元格只读显示。
      ..colorId = g.colorId
      ..unitId = g.unitId;
  }

  Future<void> _pickSourceOrder() async {
    final d = await showSalesOrderPicker(
      context,
      ref,
      initialSeller: _sellerId == null ? null : _empCache[_sellerId],
    );
    if (d == null || !mounted) return;
    // 来源单号由明细行派生（见 _refreshSourceDoc），可多次选择不同订单，
    // 各自带入明细行，来源单号自动累加并始终与明细同步。
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
          ..salesOrderNo.text = d.billNo ?? ''
          ..qty.text = _numText(l.needQty)
          ..oqty.text = _numText(l.qty)
          ..salesOrderItemId = l.orderItemId
          ..clientName = l.clientName
          ..sellerId = d.sellerId
          ..sellerName = d.sellerName
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
        _wireRow(row);
        _grid.addRow(row);
      }
    });
    _autoFillSellerFromOrder(d.sellerId, d.sellerName);
  }

  /// 明细行「关联销售订单号」可点单元格：弹来源订单选择器，给本行挂订单+销售员（不引入新行）。
  Future<void> _pickRowSalesOrder(ProductionGridRow row) async {
    final d = await showSalesOrderPicker(
      context,
      ref,
      initialSeller: _sellerId == null ? null : _empCache[_sellerId],
    );
    if (d == null || !mounted) return;
    setState(() {
      row.salesOrderNo.text = d.billNo ?? '';
      row.sellerId = d.sellerId;
      row.sellerName = d.sellerName;
    });
    _autoFillSellerFromOrder(d.sellerId, d.sellerName);
  }

  /// 软联动：跟单员为空时，用所选订单的销售员自动回填，并标记为「自动」（可被自动清除）。
  void _autoFillSellerFromOrder(String? sellerId, String? sellerName) {
    if (sellerId == null || sellerId.isEmpty) return;
    if (_sellerId != null) return; // 已有跟单员（手选或先前自动）不覆盖
    _empCache[sellerId] = UtenEmployeePickerItem(
      id: sellerId,
      name: sellerName ?? '',
    );
    setState(() {
      _sellerId = sellerId;
      _sellerAutoFilled = true;
    });
  }

  String _numText(double? v) => v == null
      ? ''
      : (v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2));

  /// 把明细行的 salesOrderNo 接入来源单号派生刷新：编辑该列即同步头表来源单号显示。
  /// 控制器 dispose 时自动移除监听，无需手动解绑。
  void _wireRow(ProductionGridRow r) {
    r.salesOrderNo.removeListener(_refreshSourceDoc);
    r.salesOrderNo.addListener(_refreshSourceDoc);
  }

  /// 来源单号 = 全部明细行 salesOrderNo 去重合并（排序后以「、」连接）。
  /// 由明细派生 ⇒ 头表与明细相互同步、天然支持多个来源订单。
  /// 同时联动清除：自动回填的跟单员，若明细中不再有该销售员的行则清空。
  void _refreshSourceDoc() {
    final nos = <String>{};
    for (final r in _grid.rows) {
      final s = r.salesOrderNo.text.trim();
      if (s.isNotEmpty) nos.add(s);
    }
    final next = (nos.toList()..sort()).join('、');
    final displayChanged = next != _sourceDocDisplay;
    _sourceDocDisplay = next;
    final sellerChanged = _reconcileSellerAutoClear();
    if ((displayChanged || sellerChanged) && mounted) setState(() {});
  }

  /// 自动回填的跟单员：明细中无任何行 sellerId==跟单员 时清空（手动选的不动）。
  bool _reconcileSellerAutoClear() {
    if (!_sellerAutoFilled || _sellerId == null) return false;
    final has = _grid.rows.any((r) => r.sellerId == _sellerId);
    if (!has) {
      _sellerId = null;
      _sellerAutoFilled = false;
      return true;
    }
    return false;
  }

  Future<void> _save() async {
    final rows = _grid.rows;
    if (rows.isEmpty || rows.every((r) => r.goods == null)) {
      context.appError('请至少添加一条明细');
      return;
    }
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      if (r.goods == null) continue;
      final qty = double.tryParse(r.qty.text);
      if (qty == null || !qty.isFinite || qty <= 0) {
        context.appError('第 ${i + 1} 行排产量无效');
        return;
      }
    }
    final effectiveRows = rows.where((row) => row.goods != null).toList();
    final manualRows = effectiveRows
        .where((row) => row.salesOrderItemId == null)
        .toList(growable: false);
    if (widget.id == null && manualRows.isNotEmpty) {
      if (manualRows.length > 1) {
        context.appWarning('多个手工产品需求请从物料分析准备页逐项填写不同的需求编号');
        return;
      }
      if (_manualSourceType == null) {
        context.appWarning('手工计划必须选择返工、试制、样品、备库或其他来源');
        return;
      }
      if (_manualSourceRef.text.trim().isEmpty) {
        context.appWarning('手工计划必须填写稳定的需求编号');
        return;
      }
      if (_manualSourceRef.text.trim().length > 200) {
        context.appWarning('手工计划需求编号不能超过 200 个字符');
        return;
      }
      if (_manualSourceReason.text.trim().isEmpty) {
        context.appWarning('手工计划必须填写来源原因');
        return;
      }
    }
    final itemsBody = <Map<String, dynamic>>[];
    for (final r in rows) {
      if (r.goods == null) continue;
      itemsBody.add({
        if (r.productNo.text.trim().isNotEmpty)
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
      if (_sourceDocDisplay.isNotEmpty) 'sourceDocNo': _sourceDocDisplay,
      if (_remark.text.trim().isNotEmpty) 'remark': _remark.text.trim(),
      'items': itemsBody,
    };
    if (widget.id == null) {
      final sources = <MaterialAnalysisSourceInput>[
        for (final row in effectiveRows)
          MaterialAnalysisSourceInput(
            salesOrderItemId: row.salesOrderItemId,
            sourceType: row.salesOrderItemId == null ? _manualSourceType : null,
            sourceRef: row.salesOrderItemId == null
                ? _manualSourceRef.text.trim()
                : null,
            goodsId: row.salesOrderItemId == null ? row.goods!.id : null,
            colorId: row.salesOrderItemId == null ? row.colorId : null,
            unitId: row.salesOrderItemId == null ? row.unitId : null,
            requestedQty: double.parse(row.qty.text),
            sourceReason: row.salesOrderItemId == null
                ? _manualSourceReason.text.trim()
                : null,
            deliveryDate: row.outboundDate?.trim().isNotEmpty == true
                ? row.outboundDate
                : _deliveryDate == null
                ? null
                : _fmt(_deliveryDate!),
            initialProductNo: row.productNo.text.trim().isEmpty
                ? null
                : row.productNo.text.trim(),
          ),
      ];
      await context.push(
        RouteName.productionMaterialAnalysis,
        extra: ProductionMaterialAnalysisSeed(
          billDate: _fmt(_billDate),
          deliveryDate: _deliveryDate == null ? null : _fmt(_deliveryDate!),
          departmentId: _departmentId,
          workshopName: _workshopName,
          workerId: _workerId,
          sources: sources,
        ),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      final repo = ref.read(productionPlanRepositoryProvider);
      final d = await repo.update(widget.id!, body);
      if (!mounted) return;
      context.appSuccess('已保存');
      context.replace('/production/plans/${d.id}');
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('保存失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 人员选择器：关键字为空时默认收敛到职能部门子树、有关键字时全公司搜（兼顾别部门下单人）。
  Widget _employeePicker({
    required String label,
    required String? currentId,
    required String defaultDeptCode,
    required ValueChanged<String?> onChanged,
  }) {
    return UtenEmployeePicker(
      key: ValueKey('${label}_$currentId'),
      label: label,
      hint: '请选择$label',
      sheetTitle: '选择$label',
      initial: currentId == null ? null : _empCache[currentId],
      loader: (kw) async {
        final deptId = (kw == null || kw.isEmpty)
            ? _deptIdFor(defaultDeptCode)
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

  /// 来源单号：只读 outlined 框 + 放大镜，点按弹销售订单选择器（可多次选择不同订单）。
  /// 显示内容由明细行 salesOrderNo 派生（_refreshSourceDoc），与明细相互同步。
  Widget _sourceDocField(ThemeData theme) {
    final empty = _sourceDocDisplay.isEmpty;
    return InkWell(
      onTap: _pickSourceOrder,
      borderRadius: BorderRadius.circular(UtenSpacing.s8),
      child: InputDecorator(
        decoration: const InputDecoration(
          labelText: '来源单号',
          suffixIcon: Icon(Icons.search_rounded, size: 18),
        ),
        child: Text(
          empty ? '点击选择销售订单（可多选）' : _sourceDocDisplay,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: empty ? theme.colorScheme.onSurfaceVariant : null,
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
        actions: _loading || _initializationError != null
            ? null
            : [
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
            : _initializationError != null
            ? UtenEmpty.error(
                key: const ValueKey('production-plan-edit-load-error'),
                message: '生产计划单加载失败',
                description:
                    '${_initializationError!}\n当前未加载任何可编辑数据。请重试，或使用左上角返回按钮退出编辑。',
                actionLabel: '重试',
                onAction: _init,
              )
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
                                    selectablePredicate:
                                        isBusinessDepartmentNode,
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
                                    defaultDeptCode: kDeptCodeMarketing,
                                    onChanged: (id) => setState(() {
                                      _sellerId = id;
                                      _sellerAutoFilled = false; // 手选：不自动清除
                                    }),
                                  ),
                                  _employeePicker(
                                    label: '生产工',
                                    currentId: _workerId,
                                    defaultDeptCode: kDeptCodeProduction,
                                    onChanged: (id) =>
                                        setState(() => _workerId = id),
                                  ),
                                  _sourceDocField(theme),
                                  if (widget.id == null)
                                    DropdownButtonFormField<String>(
                                      key: const Key(
                                        'production-manual-source-type',
                                      ),
                                      initialValue: _manualSourceType,
                                      isExpanded: true,
                                      decoration: const InputDecoration(
                                        labelText: '手工计划来源',
                                        helperText: '仅手工添加的货品行必填',
                                      ),
                                      items: [
                                        for (final entry
                                            in _manualSourceOptions.entries)
                                          DropdownMenuItem(
                                            value: entry.key,
                                            child: Text(entry.value),
                                          ),
                                      ],
                                      onChanged: _saving
                                          ? null
                                          : (value) => setState(
                                              () => _manualSourceType = value,
                                            ),
                                    ),
                                  if (widget.id == null)
                                    TextFormField(
                                      key: const Key(
                                        'production-manual-source-ref',
                                      ),
                                      controller: _manualSourceRef,
                                      maxLength: 200,
                                      decoration: const InputDecoration(
                                        labelText: '手工计划需求编号',
                                        helperText: '同一需求后续处理必须沿用同一个编号',
                                      ),
                                    ),
                                  if (widget.id == null)
                                    TextFormField(
                                      key: const Key(
                                        'production-manual-source-reason',
                                      ),
                                      controller: _manualSourceReason,
                                      decoration: const InputDecoration(
                                        labelText: '手工计划原因',
                                        helperText: '返工、试制、样品、备库或其他计划不得绕过物料分析',
                                      ),
                                      minLines: 1,
                                      maxLines: 2,
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
                          onPickSalesOrder: _pickRowSalesOrder,
                          colorEntries: names.colorEntries,
                          unitEntries: names.unitEntries,
                        ),
                        createBlankRow: () {
                          final r = ProductionGridRow();
                          _wireRow(r);
                          return r;
                        },
                      ),
                    ],
                  ),
                ),
              ),
      ),
      bottomNavigationBar: _loading || _initializationError != null
          ? null
          : SafeArea(
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
                      icon: widget.id == null
                          ? Icons.insights_outlined
                          : Icons.save_outlined,
                      onPressed: _saving ? null : _save,
                      child: Text(widget.id == null ? '进入物料分析' : '保存'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
