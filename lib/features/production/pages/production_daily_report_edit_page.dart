// 生产日报编辑页（新建/编辑，全页路由）：与生产计划/销售编辑页同构（统一模板）。
//
// 日报特点：
//   - 明细记录完工申报数量及可选实际总重量；品质通过与仓库实收分别决定可入库量和 iqty。
//   - 单据号系统自动生成（后端 DocNumberService，PRODUCTION_DAILY_REPORT），本页只读显示。
//   - 车间 = 部门选择器（department_id + 部门名冗余 workshop_name）；
//     生产参与人员 = 多选员工(workerIds；首位兼容 workerId)。成品仓和库位由仓库登记。
//   - 明细行：goodsId（必填）+ qty 完工量（必填）+ color/unit + 精确来源子任务 + remark。
//
// 仅草稿可编辑（后端校验；已审走详情页红冲）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_edit_floating_actions.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/inputs/uten_employee_multi_picker.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/buttons/uten_drafts_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../shared/providers/draft_counts_provider.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../components/layout/uten_grid_page_scrollbar.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/attachments/business_attachment_section.dart';
import '../../../shared/attachments/pending_attachment_controller.dart';
import '../../../shared/attachments/pending_attachment_flow.dart';
import '../../../shared/auth/document_scope_capability.dart';
import '../../../shared/auth/permissions.dart';
import '../../../core/utils/china_datetime.dart';
import '../../department/models/department_node.dart';
import '../../department/repositories/department_repository.dart';
import '../../department/widgets/uten_department_picker.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../models/production_daily_report.dart';
import '../models/production_direct_transfer_candidate.dart';
import '../models/production_material_usage_source.dart';
import '../models/reportable_plan_line.dart';
import '../providers/production_department_provider.dart';
import '../repositories/production_material_repository.dart';
import '../repositories/production_repository.dart';
import '../widgets/production_daily_grid_columns.dart';
import '../widgets/production_report_surplus_return_dialog.dart';
import '../widgets/reportable_plan_line_picker.dart';

class ProductionDailyReportEditPage extends ConsumerStatefulWidget {
  const ProductionDailyReportEditPage({
    super.key,
    this.id,
    this.initialExecutionSegmentId,
    this.initialExecutionSegmentIds = const [],
  });
  final String? id; // null=新建
  final String? initialExecutionSegmentId;
  final List<String> initialExecutionSegmentIds;

  @override
  ConsumerState<ProductionDailyReportEditPage> createState() =>
      _ProductionDailyReportEditPageState();
}

class _ProductionDailyReportEditPageState
    extends ConsumerState<ProductionDailyReportEditPage> {
  final _billNo = TextEditingController(); // 只读显示（后端自动生成）
  final _remark = TextEditingController();
  DateTime _billDate = ChinaDateTime.today();

  // 车间 = 部门
  String? _departmentId;
  String? _workshopName; // 部门名冗余（供报表 workshop_name facet）
  // 本次日报整单参与人员；不表达行级贡献或计件分配。
  List<UtenEmployeePickerItem> _workers = const [];
  final Map<String, UtenEmployeePickerItem> _empCache = {};

  /// 生产工 picker 默认范围：生产部（DEPT_PROD）子树 id；解析前 picker 回退全公司。
  String? _productionDeptId;

  final _grid = UtenEditableGridController<DailyGridRow>();

  /// ===== V583 报工同页登记实际用料 =====
  /// 每个执行工单的材料台账缓存，键 'planId|物料所属段Id'。一张日报常把同一个工单
  /// 挂在多个成品行下，去重后只拉一次。
  final Map<String, List<ProductionMaterialClearanceRow>> _clearanceCache = {};

  /// 报工段 → 它的合法用料来源段(分批生产时料挂在前批原领料段上)。
  /// 每条来源自带 canSettle，所以不用再单独打 capabilities 接口。
  final Map<String, List<ProductionMaterialUsageSource>> _usageSourceCache = {};

  /// 编辑既有草稿时回填用：demandId → 已登记的本次实际用料。
  final Map<String, String> _savedMaterialUsage = {};

  bool _materialLoading = false;

  /// 物料台账整体读不到(老计划、无权限、接口故障)：物料区降级为提示，不拦报工。
  String? _materialNotice;

  /// 收尾余料退仓意愿：最后一次报工时问过用户，随日报一起提交，审核时才真正发退料单。
  bool _surplusReturnRequested = false;

  /// 批量报工工单太多时不拉物料(N 次台账请求会把页面拖死)，只报工。
  static const int _materialSourceLimit = 20;

  /// 新建日报保存前暂存的附件（ADR-074：保存拿到 UUID 后逐个确认上传）。
  final _pendingFiles = PendingAttachmentController();

  /// 日报已创建但仍有附件上传失败：再点「保存」只重试附件，不重复建单。
  String? _createdReportId;
  final _scrollCtl = ScrollController();

  /// 明细表 sticky 表头是否已置顶(页面滚动条门控：置顶前不显示，置顶后才显示)。
  final _gridPinned = ValueNotifier<bool>(false);
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
    _gridPinned.dispose();
    _billNo.dispose();
    _remark.dispose();
    _pendingFiles.dispose();
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
        _departmentId = d.departmentId;
        _workshopName = d.workshopName;
        _workers = [
          for (final id in d.workerIds)
            _empCache[id] ?? UtenEmployeePickerItem(id: id, name: '已选生产工'),
        ];
        _makerName = d.makerName;
        _createdAt = d.createdAt;
        _rowVersion = d.rowVersion;
        // V583：已登记的实耗按需求 UUID 回填到重新拉取的台账行上(草稿还没记账，
        // 台账数字可能已被别人改动，所以只回填用户填过的数，不回填当时的上限)。
        _surplusReturnRequested = d.surplusReturnRequested;
        for (final usage in d.materialUsages) {
          _savedMaterialUsage[usage.demandId] = _quantityText(usage.qtyBase);
        }
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
          row.weight.text = it.weight?.toString() ?? '';
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
    if (widget.id == null) {
      final initialIds = <String>{
        if (widget.initialExecutionSegmentId?.trim().isNotEmpty == true)
          widget.initialExecutionSegmentId!.trim(),
        for (final id in widget.initialExecutionSegmentIds)
          if (id.trim().isNotEmpty) id.trim(),
      }.take(100).toList(growable: false);
      if (initialIds.length == 1 && _grid.rows.isNotEmpty) {
        await _loadInitialSource(
          _grid.rows.first,
          executionSegmentId: initialIds.single,
        );
      } else if (initialIds.length > 1) {
        await _loadInitialSources(initialIds);
      }
    }
    if (!mounted) return;
    await _reloadMaterialRows();
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

  /// 选报工来源。2026-09-11 起选择器可多选：第一条落到点开的这一行，
  /// 其余各追加一行（用户：「新建生产日报里面应该可以多选」）。
  /// 追加的行插在被点行后面，保持用户勾选的先后顺序。
  Future<void> _pickSource(
    DailyGridRow row, {
    String? executionSegmentId,
  }) async {
    final sources = await showReportablePlanLinePicker(
      context,
      ref,
      departmentId: _departmentId,
      executionSegmentId: executionSegmentId,
    );
    if (sources == null || sources.isEmpty || !mounted) return;
    final blocked = sources.firstWhere(
      (source) => !source.canReport,
      orElse: () => sources.first,
    );
    if (!blocked.canReport) {
      context.appWarning(
        blocked.blockedReason ?? '当前来源没有可报数量，请刷新后重试',
        force: true,
      );
      return;
    }
    _applySource(row, sources.first);
    if (sources.length > 1) {
      var insertAt = _grid.rows.indexOf(row) + 1;
      for (final source in sources.skip(1)) {
        final extra = DailyGridRow();
        _grid.insertAt(insertAt, extra);
        _applySource(extra, source);
        insertAt++;
      }
      if (mounted) {
        context.appInfo('已按所选 ${sources.length} 个报工任务建好 ${sources.length} 行明细');
      }
    }
    // 换了来源工单就要重挂它的物料子行：_reloadMaterialRows 会按成品行顺序重排整表，
    // 上面插在中间的新行也会被归位。
    await _reloadMaterialRows();
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

  Future<void> _loadInitialSources(List<String> executionSegmentIds) async {
    try {
      final page = await ref
          .read(productionDailyReportRepositoryProvider)
          .reportablePlanLines(
            size: 100,
            departmentId: _departmentId,
            executionSegmentIds: executionSegmentIds,
          );
      if (!mounted) return;
      final bySegment = <String, List<ReportablePlanLine>>{};
      for (final source in page.items) {
        final id = source.executionSegmentId;
        if (id == null || id.isEmpty) continue;
        bySegment.putIfAbsent(id, () => []).add(source);
      }
      final invalid = executionSegmentIds.where((id) {
        final rows = bySegment[id];
        return rows == null || rows.length != 1 || !rows.single.canReport;
      });
      if (page.total != executionSegmentIds.length || invalid.isNotEmpty) {
        context.appWarning(
          '部分工单已变化或包含多个销售分摊，未自动生成批量报工；请刷新车间任务后重试',
          force: true,
        );
        return;
      }
      final departments = <String>{};
      for (final id in executionSegmentIds) {
        final departmentId = bySegment[id]!.single.departmentId;
        if (departmentId != null && departmentId.isNotEmpty) {
          departments.add(departmentId);
        }
      }
      if (departments.length > 1) {
        context.appWarning('批量报工必须属于同一车间，请分车间办理', force: true);
        return;
      }
      final rows = [for (final _ in executionSegmentIds) DailyGridRow()];
      _grid.replaceAll(rows);
      for (var index = 0; index < executionSegmentIds.length; index++) {
        _applySource(
          rows[index],
          bySegment[executionSegmentIds[index]]!.single,
        );
      }
    } catch (error) {
      if (mounted) {
        context.appError(
          productionErrorMessage(error, fallback: '批量报工来源加载失败，请稍后重试'),
        );
      }
    }
  }

  void _applySource(DailyGridRow row, ReportablePlanLine source) {
    if (!mounted) return;
    setState(() {
      row
        ..planId = source.planId
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

  Future<void> _openSource(DailyGridRow row) async {
    final planId = row.planId;
    final segmentId = row.executionSegmentId;
    if (planId == null || segmentId == null) return;
    await context.push(
      Uri(
        path: RoutePath.productionPlanDetail(planId),
        queryParameters: {'executionSegmentId': segmentId},
      ).toString(),
    );
  }

  void _clearSource(DailyGridRow row) {
    // 来源没了，挂在这行下面的物料子行也就没有归属：先摘掉再清字段，
    // 否则它们会变成指向已失效工单的孤儿行，提交时被服务端判 403。
    final orphans = [
      for (final candidate in _grid.rows)
        if (candidate.materialParent == row) candidate,
    ];
    if (orphans.isNotEmpty) _grid.removeRows(orphans);
    setState(() {
      row
        ..planId = null
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
        ..qty.clear()
        ..weight.clear();
    });
  }

  String _quantityText(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(4).replaceFirst(RegExp(r'0+$'), '');

  // ===================== V583 物料子行 =====================

  /// 成品报工行(排除挂在它们下面的物料子行)。
  List<DailyGridRow> get _productRows =>
      _grid.rows.where((row) => !row.isMaterialRow).toList(growable: false);

  String _materialKey(String planId, String segmentId) => '$planId|$segmentId';

  /// 有界并发：一次批量报工可能带十几个工单，逐个串行太慢、一把全发会打爆后端。
  Future<void> _runBounded(
    List<Future<void> Function()> tasks, {
    int limit = 4,
  }) async {
    var cursor = 0;
    Future<void> worker() async {
      while (true) {
        final index = cursor++;
        if (index >= tasks.length) return;
        await tasks[index]();
      }
    }

    await Future.wait([
      for (var i = 0; i < limit && i < tasks.length; i++) worker(),
    ]);
  }

  /// 按当前成品行的来源工单重建物料子行。
  ///
  /// 为什么要先问 `material-usage-sources` 再拉台账：分批生产时，本批执行段可能一条
  /// 物料需求都没有，料挂在**前批原领料段**上(ADR-078)。直接拿报工段去查台账会查出
  /// 零条，提交时还会被服务端按段归属判 403。
  Future<void> _reloadMaterialRows() async {
    final targets = [
      for (final row in _productRows)
        if (row.planId != null && row.executionSegmentId != null) row,
    ];
    if (targets.isEmpty) {
      _applyMaterialRows(const {});
      if (mounted) setState(() => _materialNotice = null);
      return;
    }
    if (targets.length > _materialSourceLimit) {
      // 逐工单两次请求，几十个工单会把页面拖到不可用。明说本次不登记实耗，
      // 而不是静默少挂几行——静默会让车间以为料已经登记过了。
      _applyMaterialRows(const {});
      if (mounted) {
        setState(
          () => _materialNotice =
              '本次报工的工单超过 $_materialSourceLimit 个，页面不再逐单加载用料明细；'
              '本单只报工，实际用料请分批报工或到计划详情的材料台账登记。',
        );
      }
      return;
    }
    setState(() {
      _materialLoading = true;
      _materialNotice = null;
    });
    final repo = ref.read(productionMaterialRepositoryProvider);
    final failures = <String>[];
    try {
      // 1) 报工段 → 合法用料来源段(含沿用前批的原领料段)。
      await _runBounded([
        for (final row in targets)
          () async {
            final key = _materialKey(row.planId!, row.executionSegmentId!);
            if (_usageSourceCache.containsKey(key)) return;
            try {
              _usageSourceCache[key] = await repo.materialUsageSources(
                row.planId!,
                executionSegmentId: row.executionSegmentId!,
              );
            } catch (_) {
              _usageSourceCache[key] = const [];
              failures.add(row.executionSegmentCode ?? '工单');
            }
          },
      ]);
      // 2) 每个来源段的材料台账。同一段被多个成品行引用时只拉一次。
      final segments = <String, ({String planId, String segmentId})>{};
      for (final row in targets) {
        final sources =
            _usageSourceCache[_materialKey(
              row.planId!,
              row.executionSegmentId!,
            )] ??
            const <ProductionMaterialUsageSource>[];
        for (final source in sources) {
          if (!source.canOpen) continue;
          segments[_materialKey(row.planId!, source.executionSegmentId)] = (
            planId: row.planId!,
            segmentId: source.executionSegmentId,
          );
        }
      }
      await _runBounded([
        for (final entry in segments.entries)
          () async {
            if (_clearanceCache.containsKey(entry.key)) return;
            try {
              _clearanceCache[entry.key] = await repo.clearance(
                entry.value.planId,
                executionSegmentId: entry.value.segmentId,
              );
            } catch (_) {
              _clearanceCache[entry.key] = const [];
              failures.add('材料台账');
            }
          },
      ]);
      await _reloadDirectTransferCandidates();
      _applyMaterialRows(segments);
    } finally {
      if (mounted) {
        setState(() {
          _materialLoading = false;
          if (failures.isNotEmpty) {
            _materialNotice =
                '部分工单的用料明细没能读取(老计划或无材料权限)，这些工单本次只报工；'
                '实际用料请到计划详情的材料台账单独登记。';
          }
        });
      }
    }
  }

  /// 把缓存里的台账铺成「成品行 + 其物料子行」的扁平行序。
  ///
  /// 复用既有行对象而不是整表重建：用户已经填进去的数字不能因为换了个来源就清空。
  void _applyMaterialRows(Map<String, ({String planId, String segmentId})> _) {
    final previous = <DailyGridRow, Map<String, DailyGridRow>>{};
    for (final row in _grid.rows) {
      final parent = row.materialParent;
      final material = row.material;
      if (!row.isMaterialRow || parent == null || material == null) continue;
      previous.putIfAbsent(parent, () => {})[material.demandId] = row;
    }
    final reused = <DailyGridRow>{};
    final flat = <DailyGridRow>[];
    // 同一个执行工单挂在多个成品行下时，它的物料只有一份额度：第一处可填，
    // 其余只读镜像。否则两行各自按满额填，提交必被服务端守恒守卫拒掉。
    final owned = <String>{};
    for (final product in _productRows) {
      flat.add(product);
      final planId = product.planId;
      final segmentId = product.executionSegmentId;
      if (planId == null || segmentId == null) continue;
      final sources =
          _usageSourceCache[_materialKey(planId, segmentId)] ??
          const <ProductionMaterialUsageSource>[];
      for (final source in sources) {
        if (!source.canOpen) continue;
        final rows =
            _clearanceCache[_materialKey(planId, source.executionSegmentId)] ??
            const <ProductionMaterialClearanceRow>[];
        for (final clearance in rows) {
          // 与材料台账同口径：没领过料、或已经没有可继续登记的量，就不占一行。
          if (clearance.issuedQty <= 0 || clearance.availableToSettleQty <= 0) {
            continue;
          }
          final row = previous[product]?[clearance.demandId] ?? DailyGridRow();
          reused.add(row);
          row
            ..depth = 1
            ..material = clearance
            ..materialParent = product
            ..materialShared = source.shared
            ..materialReadOnly = !source.canSettle
            ..materialOwnsInput = owned.add(clearance.demandId);
          final saved = _savedMaterialUsage[clearance.demandId];
          if (saved != null && row.materialUsed.text.trim().isEmpty) {
            row.materialUsed.text = saved;
          }
          flat.add(row);
        }
      }
    }
    final orphans = [
      for (final row in _grid.rows)
        if (row.isMaterialRow && !reused.contains(row)) row,
    ];
    // swapRows 不 dispose：行对象归本页所有。被丢弃的子行等这一帧的输入框拆掉
    // 之后再 dispose，同帧 dispose 正在使用的控制器会直接抛异常。
    _grid.swapRows(flat);
    if (orphans.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final row in orphans) {
          row.dispose();
        }
      });
    }
    if (mounted) setState(() {});
  }

  /// 删成品行：连带删掉挂在它下面的物料子行，不留孤儿。
  void _deleteProductRow(DailyGridRow row, int index) {
    final victims = [
      row,
      for (final candidate in _grid.rows)
        if (candidate.materialParent == row) candidate,
    ];
    _grid.removeRows(victims);
    setState(() {});
  }

  bool _hasMaterialChildren(DailyGridRow row) =>
      !row.isMaterialRow &&
      _grid.rows.any((candidate) => candidate.materialParent == row);

  bool _isLastMaterialChild(DailyGridRow row) {
    final rows = _grid.rows;
    final index = rows.indexOf(row);
    if (index < 0 || index + 1 >= rows.length) return true;
    return rows[index + 1].materialParent != row.materialParent;
  }

  /// 本行是不是「最后一次报工」：勾了完结，或本次把可报量报满。
  bool _isLastReport(DailyGridRow row) {
    if (row.isFinal) return true;
    final cap = row.maxReportQty;
    if (cap == null) return false;
    final qty = double.tryParse(row.qty.text.trim()) ?? 0;
    return qty >= cap - 0.000001;
  }

  /// 拉每个成品行可转送的同车间上层工单(V584/V585)。
  ///
  /// 只有一个候选时直接选中——用户口径「能简化就简化」，多数情况下下游就一个。
  /// 一个候选都没有时「转下一道工序」保持不可选，并把已选的去向退回送仓库，
  /// 避免留下一个选了去向却投不出去的行。
  Future<void> _reloadDirectTransferCandidates() async {
    final repo = ref.read(productionMaterialRepositoryProvider);
    final rows = [
      for (final row in _productRows)
        if (row.executionSegmentId != null && row.goods != null) row,
    ];
    await _runBounded([
      for (final row in rows)
        () async {
          try {
            row.directTransferCandidates = await repo.directTransferCandidates(
              executionSegmentId: row.executionSegmentId!,
              goodsId: row.goods!.id,
              colorId: row.colorId,
            );
          } catch (_) {
            // 读不到候选不拦报工：这一行退回送仓库那条老路。
            row.directTransferCandidates = const [];
          }
          if (row.directTransferCandidates.isEmpty) {
            row.destination = 'WAREHOUSE';
            row.directTransfer = null;
          } else if (row.isDirectTransfer && row.directTransfer == null) {
            row.directTransfer = row.directTransferCandidates.length == 1
                ? row.directTransferCandidates.single
                : null;
          }
        },
    ]);
  }

  void _onDestinationChanged(DailyGridRow row, String destination) {
    setState(() {
      row.destination = destination;
      if (destination != 'WORKSHOP') {
        row.directTransfer = null;
        return;
      }
      row.directTransfer ??= row.directTransferCandidates.length == 1
          ? row.directTransferCandidates.single
          : null;
    });
  }

  void _onDirectTransferPicked(
    DailyGridRow row,
    ProductionDirectTransferCandidate picked,
  ) {
    setState(() => row.directTransfer = picked);
  }

  /// 收尾差额：最后一次报工的行，其物料还剩多少没登记成消耗。
  ///
  /// 只用本地快照估算「要不要问用户」；真正退多少由服务端在审核时按当时的可退量算，
  /// 因为退料走原领料单位、台账是基本量，两者在换算率不为 1 时对不上。
  List<SurplusReturnCandidate> _surplusCandidates() {
    final seen = <String>{};
    final out = <SurplusReturnCandidate>[];
    for (final row in _grid.rows) {
      if (!row.materialEditable) continue;
      final parent = row.materialParent;
      if (parent == null || !_isLastReport(parent)) continue;
      final material = row.material!;
      if (!seen.add(material.demandId)) continue;
      final remaining =
          material.availableToSettleQty - (row.materialUsedValue ?? 0);
      if (remaining <= 0.0000001) continue;
      out.add(
        SurplusReturnCandidate(
          goodsName: material.goodsName ?? material.goodsCode ?? '物料',
          colorName: material.colorName,
          remainingQty: remaining,
          unitName: material.unitName ?? '',
          segmentLabel: row.materialShared ? row.materialSegmentLabel : null,
        ),
      );
    }
    return out;
  }

  /// 把暂存附件上传到刚创建的日报；全部成功才跳详情，失败项留在页面供重试。
  Future<void> _finishCreatedReport(String createdId) async {
    setState(() => _saving = true);
    try {
      final ok = await flushPendingAttachments(
        context,
        ref,
        _pendingFiles,
        ownerType: 'PRODUCTION_DAILY_REPORT',
        ownerIds: [createdId],
      );
      if (!mounted || !ok) return;
      context.replace('/production/daily-reports/$createdId');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _save() async {
    if (_createdReportId case final createdId?) {
      // 日报已创建、附件未全部上传：只补传附件，成功后进入详情。
      await _finishCreatedReport(createdId);
      return;
    }
    // 校验与「第 N 行」计数都只看成品报工行：物料子行是挂在它们下面的派生行，
    // 混进来会让行号对不上用户在界面上数到的那一行。
    final rows = _productRows;
    if (rows.isEmpty || rows.every((r) => r.goods == null)) {
      context.appError('请至少添加一条明细');
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
      final weightText = r.weight.text.trim();
      final weight = weightText.isEmpty ? null : double.tryParse(weightText);
      if (weightText.isNotEmpty && (weight == null || weight <= 0)) {
        context.appError('第 ${i + 1} 行实际重量必须大于 0');
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
    // V583 物料子行：本次实际用料必填、不能为负、不能超过本次还能登记的量。
    // 允许填 0——「这批料一点没用」是合法事实，逼人编个正数就是在造假账。
    final materialIssues = <String>[];
    for (final row in _grid.rows) {
      if (!row.materialEditable || !row.materialInvalid) continue;
      final material = row.material!;
      final name = material.goodsName ?? material.goodsCode ?? '物料';
      final value = row.materialUsedValue;
      materialIssues.add(
        value == null || !value.isFinite
            ? '$name 未填写本次实际用料'
            : value < 0
            ? '$name 的本次实际用料不能为负'
            : '$name 本次登记 ${_quantityText(value)}，'
                  '超过可登记 ${_quantityText(row.materialCap)} '
                  '${material.unitName ?? ''}',
      );
    }
    if (materialIssues.isNotEmpty) {
      context.appError(
        '以下 ${materialIssues.length} 项用料需要先改正：${_joinIssues(materialIssues)}',
      );
      return;
    }
    // V584/V585 转下一道工序：必须指名投给哪个上层工单，且不得超过它还缺的量。
    // 更强的不变量(同车间、同货品同颜色、同主仓)由服务端与数据库守卫兜底。
    final transferIssues = <String>[];
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      if (r.goods == null || !r.isDirectTransfer) continue;
      final picked = r.directTransfer;
      if (picked == null) {
        transferIssues.add('第 ${i + 1} 行选了转下一道工序，但没有指定接收的上层工单');
        continue;
      }
      final qty = double.tryParse(r.qty.text.trim()) ?? 0;
      if (qty - picked.remainingQty > 0.000001) {
        transferIssues.add(
          '第 ${i + 1} 行本次 ${_quantityText(qty)} 超过上层工单还缺的 '
          '${_quantityText(picked.remainingQty)}；超出的部分请另起一行送入仓库',
        );
      }
    }
    if (transferIssues.isNotEmpty) {
      context.appError(
        '以下 ${transferIssues.length} 项转送需要先改正：${_joinIssues(transferIssues)}',
      );
      return;
    }
    // 最后一次报工(报满或勾完结)且还有料没登记成消耗时，问一次要不要退回仓库。
    // 填 0 / 没有差额 = 不问、不建单、不打扰仓库。
    final surplus = _surplusCandidates();
    if (surplus.isNotEmpty) {
      final wantsReturn = await showProductionReportSurplusReturnDialog(
        context,
        candidates: surplus,
      );
      if (!mounted) return;
      _surplusReturnRequested = wantsReturn == true;
    } else {
      _surplusReturnRequested = false;
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
      final weightText = r.weight.text.trim();
      final weight = weightText.isEmpty ? null : double.tryParse(weightText);
      itemsBody.add({
        'goodsId': r.goods!.id,
        'qty': qty,
        'weight': ?weight,
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
        // V584/V585 产出去向。不传即送仓库，服务端按老口径处理。
        if (r.isDirectTransfer) 'destination': 'WORKSHOP',
        if (r.isDirectTransfer && r.directTransfer != null)
          'directTransferDemandId': r.directTransfer!.demandId,
        if (r.remark.text.trim().isNotEmpty) 'remark': r.remark.text.trim(),
      });
    }
    final materialBody = <Map<String, dynamic>>[
      for (final row in _grid.rows)
        if (row.materialEditable)
          {
            'demandId': row.material!.demandId,
            'qtyBase': row.materialUsedValue ?? 0,
          },
    ];
    // 单据号后端自动生成（DocNumberService），不再随 body 提交。
    final body = <String, dynamic>{
      'billDate': _fmt(_billDate),
      if (_departmentId != null) 'departmentId': _departmentId,
      if (_workshopName != null && _workshopName!.trim().isNotEmpty)
        'workshopName': _workshopName,
      if (_workers.isNotEmpty) 'workerId': _workers.first.id,
      'workerIds': [for (final worker in _workers) worker.id],
      if (_remark.text.trim().isNotEmpty) 'remark': _remark.text.trim(),
      'items': itemsBody,
      // V583：实耗按需求 UUID 整单提交(同一工单挂多个成品行时只算一份额度，
      // 只有 owns 的那一行进来)。计划与物料所属段由服务端从需求行反查。
      if (materialBody.isNotEmpty) 'materialLines': materialBody,
      if (_surplusReturnRequested) 'surplusReturnRequested': true,
    };
    setState(() => _saving = true);
    try {
      final repo = ref.read(productionDailyReportRepositoryProvider);
      final d = widget.id == null
          ? await repo.create(body, idempotencyKey: _createIdempotencyKey)
          : await repo.update(widget.id!, body, expectedVersion: _rowVersion);
      if (!mounted) return;
      context.appSuccess(widget.id == null ? '已创建' : '已保存');
      // 同生产计划单：本页不走 bumpListRefresh，草稿计数在这里单独失效。
      ref.invalidate(draftCountsProvider);
      if (widget.id == null && _pendingFiles.isNotEmpty) {
        setState(() => _createdReportId = d.id);
        await _finishCreatedReport(d.id);
        return;
      }
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

  /// 批量校验的问题清单：最多列前 6 条，其余折成「等 N 项」——顶部通知里十几条会刷屏，
  /// 前几条足够定位，改完再提交剩下的还会继续提示。
  String _joinIssues(List<String> issues) {
    const limit = 6;
    final shown = issues.take(limit).join('；');
    return issues.length <= limit ? shown : '$shown 等 ${issues.length} 项';
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
    return UtenEmployeeMultiPicker(
      key: ValueKey(_workers.map((worker) => worker.id).join('|')),
      enabled: _departmentId != null || _productionDeptId != null,
      label: '生产参与人员',
      hint: '可选择多人或整条流水线成员',
      // 候选范围与口径说明收进标签 ⓘ（悬停/点按查看），不再摊在输入框下面。
      info:
          '候选范围：制造与研发管理中心 / 生产部。选择车间后收窄到该车间及班组；'
          '这里记录整单参与人员，不代表个人产量或计件工资。',
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
    );
  }

  /// 新建态 AppBar 右上角「草稿(N)」入口。
  ///
  /// 生产 hub 卡片直达新建页，从 hub 打不开列表；本按钮是用户回到自己草稿的
  /// 入口（点击进列表并预选草稿段）。编辑既有单据时不显示。
  List<Widget>? get _draftsAction {
    if (widget.id != null) return null;
    return [
      const UtenDraftsButton(
        kind: DraftDocKind.productionDailyReport,
        listLocation: RouteName.productionDailyReportList,
      ),
    ];
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
        actions: _draftsAction,
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
            : UtenGridPageScrollbar(
                pinned: _gridPinned,
                controller: _scrollCtl,
                // 滚动条贴屏幕右缘(2026-09-15)：包装在内容容器之外，右缘窄条
                // 恒在屏幕最右，不随限宽容器/列宽漂移。
                child: UtenContentContainer(
                  child: ListView(
                    controller: _scrollCtl,
                    // 底部多留一段：右下角悬浮的「取消/保存」不压住最后一行明细。
                    padding: const EdgeInsets.fromLTRB(
                      UtenSpacing.s12,
                      UtenSpacing.s12,
                      UtenSpacing.s12,
                      UtenFloatingActionGroup.scrollClearance,
                    ),
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
                                    decoration: UtenInputDecoration(
                                      InputDecoration(
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
                                '计量口径：填写本次实际完工申报量。'
                                '审核后先由仓库登记成品仓和库位并送检；'
                                '只有品质通过且仓库最终点收的数量才会增加库存与完成率。'
                                '疑似不良也应按实际完工事实申报，由品质登记通过、返工、报废或拒收。',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onTertiaryContainer,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      // 日报附件（报工照片/检验记录）：已有单直接挂 PRODUCTION_DAILY_REPORT；
                      // 新建单先本地暂存，保存拿到 UUID 后逐个确认上传（ADR-074）。
                      const SizedBox(height: UtenSpacing.s12),
                      if (widget.id != null)
                        BusinessAttachmentSection(
                          ownerType: 'PRODUCTION_DAILY_REPORT',
                          ownerId: widget.id!,
                          canView: ref
                              .watch(currentPermissionsProvider)
                              .contains(Perm.attachmentView),
                          // 进入编辑页即已确认可写；草稿状态与归属由服务端附件策略再校验。
                          canManage: !_saving,
                          title: '附件（报工照片/检验记录）',
                          categories: const ['报工照片', '检验记录', '签认单', '其他'],
                        )
                      else ...[
                        if (_createdReportId != null)
                          const PendingAttachmentRetryNotice(
                            documentLabel: '生产日报',
                          ),
                        BusinessAttachmentSection.draft(
                          key: const ValueKey('daily-report-draft-attachments'),
                          controller: _pendingFiles,
                          canManage: ref
                              .watch(currentPermissionsProvider)
                              .contains(Perm.productionDailyReportCreate),
                          title: '附件（报工照片/检验记录）',
                          categories: const ['报工照片', '检验记录', '签认单', '其他'],
                        ),
                      ],
                      // 「明细 (N)」标题行 2026-09-11 撤除（全站同改）。
                      const SizedBox(height: UtenSpacing.s12),
                      if (_materialLoading || _materialNotice != null)
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: UtenSpacing.s8,
                          ),
                          child: Row(
                            children: [
                              if (_materialLoading)
                                const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              if (_materialLoading)
                                const SizedBox(width: UtenSpacing.s8),
                              Expanded(
                                child: Text(
                                  _materialLoading
                                      ? '正在读取这些工单已领用的物料…'
                                      : _materialNotice!,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: _materialLoading
                                        ? theme.colorScheme.onSurfaceVariant
                                        : theme.colorScheme.error,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      UtenEditableGrid<DailyGridRow>(
                        controller: _grid,
                        stickyHeaderPinned: _gridPinned,
                        columns: dailyGridColumns(
                          context: context,
                          onPickGoods: _pickGoods,
                          onPickSource: _pickSource,
                          onOpenSource:
                              ref.watch(isSuperAdminProvider) ||
                                  ref
                                      .watch(currentPermissionsProvider)
                                      .contains(Perm.productionPlanView)
                              ? _openSource
                              : null,
                          onClearSource: _clearSource,
                          colorEntries: names.colorEntries,
                          unitEntries: names.unitEntries,
                          hasMaterialChildren: _hasMaterialChildren,
                          isLastMaterialChild: _isLastMaterialChild,
                          onMaterialChanged: () => setState(() {}),
                          onDestinationChanged: _onDestinationChanged,
                          onDirectTransferPicked: _onDirectTransferPicked,
                        ),
                        createBlankRow: () => DailyGridRow(),
                        cloneRow: (r) => r.clone(),
                        // 物料子行是成品行派生出来的：不能单独勾选、复制或删除，
                        // 删成品行时由 _deleteProductRow 连带删掉它们。
                        canSelectRow: (r) => !r.isMaterialRow,
                        showRowSelection: (r) => !r.isMaterialRow,
                        canDeleteRow: (r) => !r.isMaterialRow,
                        onDeleteRow: _deleteProductRow,
                        rowColor: (r) => r.isMaterialRow
                            ? theme.colorScheme.surfaceContainerLow
                            : null,
                      ),
                    ],
                  ),
                ),
              ),
      ),
      // 详情尚未回填时不出按钮：此刻点保存会把空表单当草稿提交。
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton: _loading
          ? null
          : UtenEditFloatingActions(
              onCancel: () => popOrBackTo(
                context,
                defaultPath: RouteName.productionDailyReportList,
              ),
              onSave: _save,
              saving: _saving,
            ),
    );
  }
}
