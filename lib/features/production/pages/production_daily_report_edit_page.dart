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
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_edit_floating_actions.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_dialog.dart';
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
import '../../../core/utils/idempotency_key.dart';
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
import '../repositories/production_actual_output_supplement_repository.dart';
import '../repositories/production_overproduction_rate_repository.dart';
import '../widgets/reportable_plan_line_picker.dart';
import '../../../shared/badges/badge_registry.dart';

class ProductionDailyReportEditPage extends ConsumerStatefulWidget {
  const ProductionDailyReportEditPage({
    super.key,
    this.id,
    this.initialExecutionSegmentId,
    this.initialExecutionSegmentIds = const [],
    this.initialSupplement,
    this.returnToWorkshopTasks = false,
  });
  final String? id; // null=新建
  final String? initialExecutionSegmentId;
  final List<String> initialExecutionSegmentIds;
  final ProductionOutputSupplementView? initialSupplement;

  /// 从「我的车间任务」push 进来（2026-09-24 用户口径「点击报工后应该去到任务
  /// 中心，通知数量自动刷新」）：保存成功后 pop 回任务页——它的 await push 收尾
  /// 自带清勾选+整页重拉+徽章刷新；其余入口照旧 replace 成详情页。
  final bool returnToWorkshopTasks;

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

  /// 新建态（2026-09-18 勾选口径，与订货单/到货登记页同款）：勾选=本次要提交的
  /// 成品报工行，保存只认勾选行；编辑既有日报保持整单保存。
  bool get _isCreate => widget.id == null;

  /// ===== V583 报工同页登记实际用料 =====
  /// 每个执行工单的材料台账缓存，键 'planId|物料所属段Id'。一张日报常把同一个工单
  /// 挂在多个成品行下，去重后只拉一次。
  final Map<String, List<ProductionMaterialClearanceRow>> _clearanceCache = {};

  /// 报工段 → 它的合法用料来源段(分批生产时料挂在前批原领料段上)。
  /// 每条来源自带 canSettle，所以不用再单独打 capabilities 接口。
  final Map<String, List<ProductionMaterialUsageSource>> _usageSourceCache = {};

  /// 编辑既有草稿时回填用：demandId → 已登记的本次实际用料。
  final Map<String, ProductionDailyReportMaterialUsage> _savedMaterialUsage =
      {};
  final Map<String, DailyMaterialInput> _materialInputs = {};
  bool _materialOwnershipRefreshQueued = false;
  List<DailyGridRow> _materialProductRows = const [];

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
  bool _detailLoaded = false;
  bool _restoredSupplementContext = false;
  bool _resumeBlocked = false;
  String? _resumeNotice;
  int _rowVersion = 0;
  String _createIdempotencyKey = 'daily-report-create-${const Uuid().v4()}';
  // 制单信息（服务端权威，只读展示）
  String? _makerName;
  String? _createdAt;

  @override
  void initState() {
    super.initState();
    _grid.addListener(_scheduleMaterialOwnershipRefresh);
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _gridPinned.dispose();
    _billNo.dispose();
    _remark.dispose();
    _pendingFiles.dispose();
    _grid.removeListener(_scheduleMaterialOwnershipRefresh);
    _grid.dispose(); // 自动 dispose 各行控制器
    for (final input in _materialInputs.values) {
      input.dispose();
    }
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
          _savedMaterialUsage[usage.demandId] = usage;
        }
        final rows = <DailyGridRow>[];
        for (final group in productionDailyReportInputGroups(d.items)) {
          final it = group.source;
          final row = DailyGridRow()
            ..planNo.text = group.planNo ?? ''
            ..remark.text = it.remark ?? ''
            ..planItemId = group.planItemId
            ..planId = group.planId
            ..remainingPlanQty = it.remainingPlanQty
            ..allowActualOverproduction = it.allowActualOverproduction
            ..executionSegmentId = group.executionSegmentId
            ..executionSegmentSalesAllocationId = group.allocationId
            ..supplementProofId = group.supplementBatch
                ? it.supplementProofId
                : null
            ..supplementApprovedActualQty = group.supplementBatch
                ? group.qty
                : null
            ..fqcRecoveryAuthorizationId = it.fqcRecoveryAuthorizationId
            ..fqcRecoveryDispositionCode = it.fqcRecoveryAuthorizationId == null
                ? null
                : 'RECOVERY'
            ..salesOrderItemId = group.salesOrderItemId
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
          row.qty.text = group.qty?.toString() ?? '';
          row.weight.text = group.weight?.toString() ?? '';
          row.isFinal = it.isFinal;
          // V584/V595：草稿里已选的去向与接收工单是用户的选择，候选加载后原样回填、
          // 不被上次报工记忆覆盖、不标黄。
          row.destination = it.destination ?? 'WAREHOUSE';
          row.pendingDirectTransferDemandId = it.directTransferDemandId;
          row.destinationTouched = true;
          rows.add(row);
        }
        _grid.replaceAll(rows);
        _detailLoaded = true;
      } on ApiException catch (e) {
        if (mounted) context.appError(e.message);
      } catch (_) {
        if (mounted) context.appError('日报草稿读取失败，请重试后再编辑');
      }
    }
    if (_grid.isEmpty) _grid.addRow(DailyGridRow());
    if (!mounted) return;
    final supplement = widget.initialSupplement;
    if (supplement != null) {
      final restored = await _restoreSupplementContext(supplement);
      if (!mounted) return;
      if (!restored && widget.id == null && !_resumeBlocked) {
        final source = supplement.sourceLine;
        if (source == null ||
            supplement.proofId == null ||
            supplement.status != 'APPROVED' ||
            supplement.supplementSegmentStatus != 'IN_PROGRESS') {
          context.appError('追加计划尚未完成审批与开工，请先核对追加计划状态');
        } else {
          final row = _grid.rows.first;
          _applySource(row, source);
          row.qty.text = _quantityText(supplement.actualQty);
          row.supplementRequestId = supplement.id;
          row.supplementProofId = supplement.proofId;
          row.supplementApprovedActualQty = supplement.actualQty;
          _resumeNotice = '仅恢复此追加批次。其余明细、人员、实耗和未提交附件未在本页恢复，请回原填写页面核对。';
        }
      }
    } else if (widget.id == null) {
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
    if (mounted) setState(() => _loading = false);
  }

  Future<bool> _restoreSupplementContext(
    ProductionOutputSupplementView supplement,
  ) async {
    try {
      final snapshot = supplement.reportContext;
      if (snapshot == null) return false;
      final rawItems = snapshot['items'];
      if (rawItems is! List || rawItems.isEmpty) {
        throw const FormatException('申请明细为空');
      }
      if (widget.id != null &&
          (snapshot['expectedVersion'] as num?)?.toInt() != _rowVersion) {
        throw const FormatException('原草稿已被更新，未覆盖其最新内容；请先核对申请时内容与当前草稿');
      }
      final restored = <DailyGridRow>[];
      for (final raw in rawItems) {
        final item = Map<String, dynamic>.from(raw as Map);
        final qty = productionRateNumber(item['qty']);
        if (qty == null ||
            !qty.isFinite ||
            qty <= 0 ||
            item['planItemId'] is! String ||
            item['executionSegmentId'] is! String ||
            item['goodsId'] is! String ||
            item['unitId'] is! String ||
            (productionRateNumber(item['unitRate']) ?? 0) <= 0) {
          throw const FormatException('申请时来源或数量不完整，请回原表核对');
        }
        final row = DailyGridRow()
          ..planItemId = item['planItemId'] as String
          ..executionSegmentId = item['executionSegmentId'] as String
          ..executionSegmentSalesAllocationId =
              item['executionSegmentSalesAllocationId'] as String?
          ..salesOrderItemId = item['salesOrderItemId'] as String?
          ..salesOrderNo = item['salesOrderNo'] as String?
          ..fqcRecoveryAuthorizationId =
              item['fqcRecoveryAuthorizationId'] as String?
          ..unitId = item['unitId'] as String
          ..colorId = item['colorId'] as String?
          ..unitRate = productionRateNumber(item['unitRate'])
          ..goods = GoodsOption(id: item['goodsId'] as String)
          ..qty.text = _quantityText(qty)
          ..weight.text = item['weight']?.toString() ?? ''
          ..planNo.text = item['planNo'] as String? ?? ''
          ..remark.text = item['remark'] as String? ?? ''
          ..destination = item['destination'] as String? ?? 'WAREHOUSE'
          ..pendingDirectTransferDemandId =
              item['directTransferDemandId'] as String?
          ..destinationTouched = true
          ..supplementProofId = item['supplementProofId'] as String?;
        if (row.supplementProofId != null) {
          row.supplementApprovedActualQty = qty;
        }
        restored.add(row);
      }
      final inputSources = supplement.inputSources;
      if (inputSources != null) {
        if (inputSources.length != restored.length) {
          throw const FormatException('申请来源数量与明细不一致');
        }
        for (var i = 0; i < restored.length; i++) {
          final source = inputSources[i];
          if (source == null) throw const FormatException('申请来源行缺失');
          _restoreSourceMetadata(restored[i], source);
        }
      }
      final bindings =
          supplement.relatedSupplements ??
          [
            {
              'id': supplement.id,
              'inputLineIndex': supplement.inputLineIndex,
              'sourceSegmentId': supplement.sourceSegmentId,
              'sourceSalesAllocationId':
                  supplement.sourceLine?.executionSegmentSalesAllocationId,
              'actualQty': supplement.actualQty,
              'proofId': supplement.proofId,
              'status': supplement.status,
              'supplementSegmentStatus': supplement.supplementSegmentStatus,
              'sourceLine': supplement.data['sourceLine'],
            },
          ];
      final activeIndices = <int>{};
      for (final binding in bindings) {
        final index = (binding['inputLineIndex'] as num?)?.toInt();
        if (index == null || index < 0 || index >= restored.length) {
          throw const FormatException('追加行索引不完整');
        }
        // Cancelled history is not an active claim on this input row. A later
        // request may legitimately have replaced it using the same draft key.
        if (binding['status'] == 'CANCELLED') continue;
        if (!activeIndices.add(index)) {
          throw const FormatException('同一输入行存在多个有效追加申请，请先核对');
        }
        final row = restored[index];
        final sourceId =
            binding['sourceExecutionSegmentId'] ?? binding['sourceSegmentId'];
        if (row.executionSegmentId != sourceId ||
            row.executionSegmentSalesAllocationId !=
                binding['sourceSalesAllocationId'] ||
            double.tryParse(row.qty.text) !=
                productionRateNumber(binding['actualQty'])) {
          throw const FormatException('追加申请与原表来源或数量不一致');
        }
        row.supplementRequestId =
            (binding['id'] ?? binding['requestId']) as String?;
        if (binding['status'] == 'APPROVED') {
          row.supplementApprovedActualQty = double.parse(row.qty.text);
        }
        if (binding['status'] == 'APPROVED' &&
            (binding['supplementSegmentStatus'] ?? binding['segmentStatus']) ==
                'IN_PROGRESS') {
          row.supplementProofId = binding['proofId'] as String?;
        }
        if (inputSources != null) continue;
        final sourceJson = binding['sourceLine'];
        var source = sourceJson is Map<String, dynamic>
            ? ReportablePlanLine.fromJson(sourceJson)
            : binding['id'] == supplement.id
            ? supplement.sourceLine
            : null;
        if (source == null && row.supplementRequestId != null) {
          source =
              (await ref
                      .read(productionOutputSupplementRepositoryProvider)
                      .detail(row.supplementRequestId!))
                  .sourceLine;
        }
        if (source != null) {
          _restoreSourceMetadata(row, source);
        }
      }
      // Source plan IDs are read-only context, never inferred from goods names.
      // The normal source endpoint can enrich still-open ordinary rows.
      for (final row in restored.where((row) => row.planId == null)) {
        final page = await ref
            .read(productionDailyReportRepositoryProvider)
            .reportablePlanLines(
              size: 100,
              executionSegmentId: row.executionSegmentId,
            );
        final matches = page.items
            .where(
              (source) =>
                  source.planItemId == row.planItemId &&
                  source.executionSegmentSalesAllocationId ==
                      row.executionSegmentSalesAllocationId &&
                  source.fqcRecoveryAuthorizationId ==
                      row.fqcRecoveryAuthorizationId,
            )
            .toList();
        if (matches.length != 1) {
          throw const FormatException('原表有来源已变化，请回原表核对，未覆盖其他输入');
        }
        _restoreSourceMetadata(row, matches.single);
      }
      if (!mounted) return false;
      final key = snapshot['idempotencyKey'];
      if (widget.id == null && key is String && key.isNotEmpty) {
        _createIdempotencyKey = key;
      }
      _billDate =
          DateTime.tryParse(snapshot['billDate']?.toString() ?? '') ??
          _billDate;
      _departmentId = snapshot['departmentId'] as String?;
      _workshopName = snapshot['workshopName'] as String?;
      _remark.text = snapshot['remark'] as String? ?? '';
      final workerIds = (snapshot['workerIds'] as List? ?? const [])
          .whereType<String>()
          .toList();
      await _preloadEmployees(workerIds);
      if (!mounted) return false;
      _workers = [
        for (final id in workerIds)
          _empCache[id] ?? UtenEmployeePickerItem(id: id, name: '申请时已选人员'),
      ];
      for (final raw in snapshot['materialLines'] as List? ?? const []) {
        final line = Map<String, dynamic>.from(raw as Map);
        final qty = productionRateNumber(line['qtyBase']);
        if (line['demandId'] is! String ||
            qty == null ||
            !qty.isFinite ||
            qty < 0) {
          throw const FormatException('申请时用料信息不完整');
        }
        _savedMaterialUsage[line['demandId']
            as String] = ProductionDailyReportMaterialUsage(
          demandId: line['demandId'] as String,
          qtyBase: qty,
        );
      }
      _surplusReturnRequested = snapshot['surplusReturnRequested'] == true;
      _grid.replaceAll(restored);
      if (_isCreate) _grid.setSelected(restored, true);
      _restoredSupplementContext = true;
      _resumeNotice = '已恢复申请时填写的整单内容（尚未保存日报），请核对其他明细、人员、实耗与未提交附件。';
      return true;
    } catch (error) {
      if (mounted) {
        setState(() {
          _resumeBlocked = true;
          _resumeNotice = '恢复申请内容未完成：$error。原草稿未覆盖，请回追加详情核对。';
        });
      }
      return false;
    }
  }

  /// Enrich identity and limits only. Never replace the captured quantity,
  /// destination, weight, remarks or explicit material consumption.
  void _restoreSourceMetadata(DailyGridRow row, ReportablePlanLine source) {
    if (source.planId == null ||
        source.executionSegmentId != row.executionSegmentId ||
        source.planItemId != row.planItemId ||
        source.executionSegmentSalesAllocationId !=
            row.executionSegmentSalesAllocationId ||
        source.orderItemId != row.salesOrderItemId ||
        source.fqcRecoveryAuthorizationId != row.fqcRecoveryAuthorizationId ||
        source.goodsId != row.goods?.id ||
        source.colorId != row.colorId ||
        source.unitId != row.unitId ||
        source.unitRate != row.unitRate) {
      throw const FormatException('来源快照与申请明细不一致');
    }
    row
      ..planId = source.planId
      ..executionSegmentCode = source.executionSegmentCode
      ..executionSegmentVersion = source.executionSegmentVersion
      ..allowActualOverproduction = source.allowActualOverproduction
      ..maxReportQty = source.fqcRecoveryRequiresMaterial
          ? 0
          : source.maxReportQty
      ..remainingPlanQty = source.remainingCompletionQty
      ..fqcRecoveryDispositionCode = source.fqcRecoveryDispositionCode
      ..fqcSourceReportNo = source.fqcSourceReportNo
      ..clientName = source.clientName
      ..goods = GoodsOption(
        id: source.goodsId,
        name: source.goodsName,
        code: source.goodsCode,
      );
    if (row.planNo.text.isEmpty) row.planNo.text = source.planNo;
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
    if (row.hasFixedSupplement) {
      context.appWarning('已批准追加批次的来源与总量固定；可修改备注、重量和实际用料');
      return;
    }
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
  /// 应用并预填数量；同一执行段有多个订单或备货来源时仍让用户确认，避免串单。
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
        context.appWarning('当前工单暂无可报来源，请核对待审核日报、剩余数量、投料与任务状态', force: true);
        return;
      }
      context.appWarning('当前执行子计划有多个报工来源，请选择本次对应的订单或公共备货', force: true);
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
          '部分工单已变化或有多个报工来源，未自动生成批量报工；请刷新并选择对应的订单或公共备货',
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
      // 选了报工来源 = 这行要进本次日报：新建态自动勾上（保存按钮只认勾选行）。
      if (_isCreate && !row.isMaterialRow) _grid.setSelected([row], true);
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
        ..allowActualOverproduction = source.allowActualOverproduction
        ..supplementRequestId = null
        ..supplementProofId = null
        ..supplementApprovedActualQty = null
        ..remainingPlanQty = source.remainingCompletionQty
        ..legacyManual = false
        ..planNo.text = source.planNo
        ..goods = GoodsOption(
          id: source.goodsId,
          code: source.goodsCode,
          name: source.goodsName,
        )
        ..colorId = source.colorId
        ..unitId = source.unitId
        ..destinationTouched = false
        ..pendingDirectTransferDemandId = null
        ..qty.text = source.maxReportQty > 0
            ? _quantityText(source.maxReportQty)
            : '';
      _watchProductQty(row);
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
    if (row.hasFixedSupplement) {
      context.appWarning('已批准追加批次不能清除来源；如需重开，请先删除整张日报草稿');
      return;
    }
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
        ..allowActualOverproduction = false
        ..supplementRequestId = null
        ..supplementProofId = null
        ..supplementApprovedActualQty = null
        ..remainingPlanQty = null
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

  bool get _materialReadsComplete => _productRows.every((row) {
    if (row.planId == null || row.executionSegmentId == null) return false;
    final sources =
        _usageSourceCache[_materialKey(row.planId!, row.executionSegmentId!)];
    return sources != null &&
        sources.every(
          (source) =>
              source.canOpen &&
              _clearanceCache.containsKey(
                _materialKey(
                  source.sourcePlanId ?? row.planId!,
                  source.executionSegmentId,
                ),
              ),
        );
  });

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
    final targets = {
      for (final row in _productRows)
        if (row.planId != null && row.executionSegmentId != null)
          _materialKey(row.planId!, row.executionSegmentId!): row,
    }.values.toList(growable: false);
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
          final sourcePlanId = source.sourcePlanId ?? row.planId!;
          segments[_materialKey(sourcePlanId, source.executionSegmentId)] = (
            planId: sourcePlanId,
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
                '部分工单用料未能读取；草稿已保存的用料保持不变，请刷新后核对。'
                '新用料可在明细恢复后或材料台账中登记。';
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
            _clearanceCache[_materialKey(
              source.sourcePlanId ?? planId,
              source.executionSegmentId,
            )] ??
            const <ProductionMaterialClearanceRow>[];
        for (final clearance in rows) {
          // 与材料台账同口径：没领过料、或已经没有可继续登记的量，就不占一行。
          if ((clearance.issuedQty <= 0 ||
                  clearance.availableToSettleQty <= 0) &&
              !_savedMaterialUsage.containsKey(clearance.demandId)) {
            continue;
          }
          final row = previous[product]?[clearance.demandId] ?? DailyGridRow();
          reused.add(row);
          row
            ..depth = 1
            ..material = clearance
            ..materialParent = product
            ..materialShared = source.shared
            ..materialReadOnly = !source.canSettle;
          row.bindMaterialInput(
            _materialInputs.putIfAbsent(clearance.demandId, () {
              final input = DailyMaterialInput();
              final saved = _savedMaterialUsage[clearance.demandId];
              if (saved != null) {
                input.used.text = _quantityText(saved.qtyBase);
                input.manuallyEdited = true;
              }
              return input;
            }),
          );
          _watchProductQty(product);
          _watchMaterialUsage(row);
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
    _refreshMaterialInputOwners();
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
    if (row.hasFixedSupplement) {
      context.appWarning('追加批次不能从草稿单独移除；如需重开，请删除整张日报草稿');
      return;
    }
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

  /// 拉每个成品行可转送的同车间上层工单(V584/V585)，并套上次报工的记忆(V595)。
  ///
  /// 只有一个候选时直接选中——用户口径「能简化就简化」，多数情况下同车间上层工单就一个。
  /// 已指定的去向和需求不随候选缺失改变；失效时要求重新核对，不能静默改送其他任务。
  Future<void> _reloadDirectTransferCandidates() async {
    final repo = ref.read(productionMaterialRepositoryProvider);
    final requests =
        <
          (String?, String?, String?, String?),
          Future<DirectTransferCandidatesResult>
        >{};
    final rows = [
      for (final row in _productRows)
        if (row.executionSegmentId != null && row.goods != null) row,
    ];
    await _runBounded([
      for (final row in rows)
        () async {
          final requestVersion = ++row.directTransferRequestVersion;
          final sourceIdentity = (
            row.planId,
            row.executionSegmentId,
            row.goods?.id,
            row.colorId,
          );
          DirectTransferCandidatesResult result;
          try {
            result = await requests.putIfAbsent(
              sourceIdentity,
              () => repo.directTransferCandidates(
                executionSegmentId: row.executionSegmentId!,
                goodsId: row.goods!.id,
                colorId: row.colorId,
              ),
            );
          } catch (_) {
            // Keep the explicit destination and require a fresh valid target.
            result = const DirectTransferCandidatesResult(candidates: []);
          }
          if (!mounted ||
              !_productRows.contains(row) ||
              requestVersion != row.directTransferRequestVersion ||
              sourceIdentity !=
                  (
                    row.planId,
                    row.executionSegmentId,
                    row.goods?.id,
                    row.colorId,
                  )) {
            return;
          }
          row.directTransferCandidates = result.candidates;
          _applyDirectTransferMemory(row, result);
        },
    ]);
  }

  /// 上次报工记忆(V595)：本车间上次报这个货品选的去向与父件产品。
  ///
  /// - 用户已亲手选过(或编辑既有草稿)：原样保留，只按需求 UUID 回填接收工单；
  /// - 否则上次是「转下一道工序」就预填并**标黄**，接收工单按上次的父件产品命中
  ///   (同产品有两个工单时不替人猜，留给人选)；只有一个候选时也直接选中。
  void _applyDirectTransferMemory(
    DailyGridRow row,
    DirectTransferCandidatesResult result,
  ) {
    final candidates = row.directTransferCandidates;
    if (restoreExplicitDirectTransferSelection(row)) return;
    if (candidates.isEmpty) {
      row.destination = 'WAREHOUSE';
      row.directTransfer = null;
      row.destinationAutofilled.value = false;
      row.directTransferAutofilled.value = false;
      return;
    }
    if (result.lastDestination == 'WORKSHOP') {
      row.destination = 'WORKSHOP';
      row.destinationAutofilled.value = true;
      final remembered =
          result.rememberedCandidate ??
          (candidates.length == 1 ? candidates.single : null);
      row.directTransfer = remembered;
      row.directTransferAutofilled.value = remembered != null;
      return;
    }
    row.destinationAutofilled.value = false;
    row.directTransferAutofilled.value = false;
    if (row.isDirectTransfer && row.directTransfer == null) {
      row.directTransfer = candidates.length == 1 ? candidates.single : null;
    }
  }

  void _onDestinationChanged(DailyGridRow row, String destination) {
    setState(() {
      row.destination = destination;
      row.pendingDirectTransferDemandId = null;
      // 用户亲手选了 = 已核对：清掉记忆预填的黄标。
      row.destinationTouched = true;
      row.destinationAutofilled.value = false;
      if (destination != 'WORKSHOP') {
        row.directTransfer = null;
        row.directTransferAutofilled.value = false;
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
    setState(() {
      row.directTransfer = picked;
      row.pendingDirectTransferDemandId = null;
      row.destinationTouched = true;
      row.directTransferAutofilled.value = false;
    });
  }

  // ===================== V595 本次实际用料按完工申报量自动计算 =====================

  final Set<DailyGridRow> _qtyWatched = {};
  final Set<DailyMaterialInput> _usageWatched = {};

  Set<DailyGridRow> get _materialParticipants =>
      (_isCreate ? _grid.selectedRows : _productRows)
          .where((row) => !row.isMaterialRow)
          .toSet();

  void _scheduleMaterialOwnershipRefresh() {
    if (_materialOwnershipRefreshQueued) return;
    _materialOwnershipRefreshQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _materialOwnershipRefreshQueued = false;
      if (!mounted) return;
      final products = _productRows;
      if (!listEquals(products, _materialProductRows)) {
        _materialProductRows = products;
        _applyMaterialRows(const {});
      }
      _refreshMaterialInputOwners();
      setState(() {});
    });
  }

  void _refreshMaterialInputOwners() {
    synchronizeMaterialInputOwners(_grid.rows, _materialParticipants);
    for (final row in _grid.rows) {
      if (!row.materialEditable) continue;
      if (row.materialUsed.text.trim().isEmpty ||
          row.materialAutofillText != null) {
        _autofillMaterialUsage(row);
      }
    }
  }

  /// 成品行完工申报量一变，挂在它下面的物料子行按比例重算并重新标黄。
  void _watchProductQty(DailyGridRow product) {
    if (product.isMaterialRow || !_qtyWatched.add(product)) return;
    product.qty.addListener(() => _recomputeMaterialUsage(product));
  }

  /// 手工实耗是本次事实；改产量、拆分产出去向或调整勾选均不得覆盖它。
  void _watchMaterialUsage(DailyGridRow row) {
    if (!row.isMaterialRow || !_usageWatched.add(row.materialInput)) return;
    final input = row.materialInput;
    final demandId = row.material!.demandId;
    input.used.addListener(() {
      if (input.autofillText != null && input.used.text == input.autofillText) {
        return;
      }
      input.autofilled.value = false;
      input.autofillText = null;
      input.manuallyEdited = true;
      final parentQty = materialReportedQuantity(
        demandId,
        _grid.rows,
        _materialParticipants,
      );
      final value = double.tryParse(input.used.text.trim());
      input.manualRatio = parentQty > 0 && value != null && value.isFinite
          ? value / parentQty
          : null;
    });
  }

  void _recomputeMaterialUsage(DailyGridRow product) {
    final affected = {
      for (final row in _grid.rows)
        if (row.materialParent == product && row.material != null)
          row.material!.demandId,
    };
    var changed = false;
    for (final row in _grid.rows) {
      if (!row.materialEditable || !affected.contains(row.material?.demandId)) {
        continue;
      }
      changed = _autofillMaterialUsage(row) || changed;
    }
    if (changed && mounted) setState(() {});
  }

  /// 只更新尚未手改的建议，已保存草稿和手工填写的实耗原样保留。
  bool _autofillMaterialUsage(DailyGridRow row) {
    final material = row.material;
    if (material == null ||
        row.materialShared ||
        row.materialInput.manuallyEdited) {
      return false;
    }
    final participants = _materialParticipants;
    if (_grid.rows.any(
      (candidate) =>
          candidate.material?.demandId == material.demandId &&
          candidate.materialShared &&
          participants.contains(candidate.materialParent),
    )) {
      return false;
    }
    final parentQty = materialReportedQuantity(
      material.demandId,
      _grid.rows,
      participants,
    );
    final expected = expectedMaterialUsage(
      reportedQty: parentQty,
      material: material,
      ratioOverride: row.materialManualRatio,
    );
    if (expected == null) return false;
    final text = _quantityText(expected);
    row.materialAutofillText = text;
    if (row.materialUsed.text != text) row.materialUsed.text = text;
    row.materialUsageAutofilled.value = true;
    return true;
  }

  /// 收尾差额：最后一次报工的行，其物料还剩多少没登记成消耗。
  ///
  /// 只用本地快照估算「要不要问用户」；真正退多少由服务端在审核时按当时的可退量算，
  /// 因为退料走原领料单位、台账是基本量，两者在换算率不为 1 时对不上。
  List<SurplusReturnCandidate> _surplusCandidates(
    List<DailyGridRow> reportRows,
  ) {
    final seen = <String>{};
    final out = <SurplusReturnCandidate>[];
    for (final row in _grid.rows) {
      if (!row.materialEditable) continue;
      final parent = row.materialParent;
      if (parent == null || !completesProductionTask(parent, reportRows)) {
        continue;
      }
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
      // 从车间任务进来时同样直接回任务页（见 _save 同名分支）。
      if (widget.returnToWorkshopTasks) {
        final navigator = Navigator.of(context);
        if (navigator.canPop()) {
          navigator.pop(true);
        } else {
          context.go(RouteName.productionWorkshopTasks);
        }
        return;
      }
      context.replace('/production/daily-reports/$createdId');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    if (_resumeBlocked) {
      context.appWarning(_resumeNotice ?? '请先核对申请时填写内容');
      return;
    }
    if (!_isCreate && !_detailLoaded) {
      context.appError('原草稿尚未成功读取，请重试后再保存');
      return;
    }
    _refreshMaterialInputOwners();
    if (_createdReportId case final createdId?) {
      // 日报已创建、附件未全部上传：只补传附件，成功后进入详情。
      await _finishCreatedReport(createdId);
      return;
    }
    // 校验与「第 N 行」计数都只看成品报工行：物料子行是挂在它们下面的派生行，
    // 混进来会让行号对不上用户在界面上数到的那一行。
    // 新建态只提交勾选行（2026-09-18，与订货单编辑页同款）；编辑既有单整单保存。
    final candidate = _isCreate
        ? _grid.selectedRows.where((row) => !row.isMaterialRow).toList()
        : _productRows;
    final rows = candidate;
    if (rows.isEmpty || rows.every((r) => r.goods == null)) {
      context.appError(_isCreate ? '请先勾选要报工的明细行' : '请至少添加一条明细');
      return;
    }
    // 有来源却未勾选的成品行：提交前明确告知去向，防「取消勾选=静默不报工」。
    if (_isCreate) {
      final excluded = _productRows
          .where((r) => r.goods != null && !_grid.isSelected(r))
          .length;
      if (excluded > 0) {
        final confirmed = await UtenDialog.show(
          context,
          title: '有 $excluded 行明细未勾选',
          confirmLabel: '只提交勾选行',
          content: Text(
            '本次只提交勾选的 ${rows.length} 行报工；未勾选的 $excluded 行不会写入本张日报，'
            '来源任务仍保持可报状态，可稍后再报。',
          ),
        );
        if (confirmed != true || !mounted) return;
      }
    }
    final submitted = rows.toSet();
    // 行号按用户在界面数到的成品行序（_productRows），未勾选行跳过不校验不报号。
    for (var i = 0; i < _productRows.length; i++) {
      final r = _productRows[i];
      if (r.goods == null || !submitted.contains(r)) continue;
      final qty = double.tryParse(r.qty.text);
      if (qty == null || !qty.isFinite || qty <= 0) {
        context.appError('第 ${i + 1} 行完工申报量必须大于 0');
        return;
      }
      if (r.hasFixedSupplement &&
          (r.supplementApprovedActualQty == null ||
              (qty - r.supplementApprovedActualQty!).abs() > 0.000001)) {
        context.appError('第 ${i + 1} 行属于已批准的固定追加批次，总量不能修改；当前其他输入已保留');
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
      if (r.hasReportQuantityLimit &&
          r.maxReportQty != null &&
          qty > r.maxReportQty! + 0.000001) {
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
    for (final r in rows.where(
      (row) => row.hasLinkedSource && row.hasReportQuantityLimit,
    )) {
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
    // 只看勾选成品行的物料子行：未勾选行不进本次提交，其用料也不校验。
    final materialIssues = <String>[];
    for (final row in _grid.rows) {
      if (!row.materialEditable ||
          !row.materialInvalid ||
          (row.materialParent != null &&
              _isCreate &&
              !submitted.contains(row.materialParent))) {
        continue;
      }
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
      final qty = productionReportBaseQuantity(r);
      if (qty == null) {
        transferIssues.add('第 ${i + 1} 行数量或单位换算无效，请重新核对报工来源');
      } else if (r.hasReportQuantityLimit &&
          qty - picked.remainingQty > 0.000001) {
        transferIssues.add(
          '第 ${i + 1} 行本次基础数量 ${_quantityText(qty)} 超过本来源当前可直送的 '
          '${_quantityText(picked.remainingQty)}；超出的部分请另起一行送入仓库',
        );
      }
    }
    transferIssues.addAll(directTransferAggregateIssues(rows));
    if (transferIssues.isNotEmpty) {
      context.appError(
        '以下 ${transferIssues.length} 项转送需要先改正：${_joinIssues(transferIssues)}',
      );
      return;
    }
    // 最后一次报工(报满或勾完结)且还有料没登记成消耗时，问一次要不要退回仓库。
    // 填 0 / 没有差额 = 不问、不建单、不打扰仓库。
    final surplus = _surplusCandidates(rows);
    if (surplus.isNotEmpty) {
      final wantsReturn = await showProductionReportSurplusReturnDialog(
        context,
        candidates: surplus,
      );
      if (!mounted) return;
      _surplusReturnRequested = wantsReturn == true;
    } else if (_isCreate || _materialReadsComplete) {
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
        if (r.supplementProofId != null)
          'supplementProofId': r.supplementProofId,
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
    // 物料实耗只随勾选的成品行走（新建态）；编辑既有单整单提交不变。
    final editedMaterialBody = <Map<String, dynamic>>[
      for (final row in _grid.rows)
        if (row.materialEditable &&
            (row.materialParent == null ||
                !_isCreate ||
                submitted.contains(row.materialParent)))
          {
            'demandId': row.material!.demandId,
            'qtyBase': row.materialUsedValue ?? 0,
          },
    ];
    final usageSourcesComplete = _productRows.every(
      (row) =>
          row.planId != null &&
          row.executionSegmentId != null &&
          _usageSourceCache.containsKey(
            _materialKey(row.planId!, row.executionSegmentId!),
          ),
    );
    final materialBody = mergeDraftMaterialUsages(
      saved: _savedMaterialUsage.values,
      edited: editedMaterialBody,
      allowedSourceSegmentIds: usageSourcesComplete
          ? {
              for (final row in _productRows)
                for (final source
                    in _usageSourceCache[_materialKey(
                      row.planId!,
                      row.executionSegmentId!,
                    )]!)
                  source.executionSegmentId,
            }
          : null,
    );
    // 单据号后端自动生成（DocNumberService），不再随 body 提交。
    final body = <String, dynamic>{
      'billDate': _fmt(_billDate),
      'idempotencyKey': widget.id == null
          ? _createIdempotencyKey
          : businessIdempotencyKey(
              'daily-report-edit',
              '${widget.id}|$_rowVersion',
            ),
      if (widget.id != null) 'expectedVersion': _rowVersion,
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
    if (!await _prepareActualOutputSupplements(
      rows.where((row) => row.goods != null).toList(),
      body,
    )) {
      return;
    }
    setState(() => _saving = true);
    try {
      final repo = ref.read(productionDailyReportRepositoryProvider);
      final d = widget.id == null
          ? await repo.create(body, idempotencyKey: _createIdempotencyKey)
          : await repo.update(widget.id!, body, expectedVersion: _rowVersion);
      if (!mounted) return;
      context.appSuccess(widget.id == null ? '已创建' : '已保存');
      // 同生产计划单：本页不走 bumpListRefresh，草稿计数在这里单独失效。
      refreshBadges(ref);
      if (widget.id == null && _pendingFiles.isNotEmpty) {
        setState(() => _createdReportId = d.id);
        await _finishCreatedReport(d.id);
        return;
      }
      // 从车间任务进来：保存成功直接回任务页（其 await push 收尾自带刷新与
      // 徽章重拉）；其余入口照旧落详情页。
      if (widget.returnToWorkshopTasks) {
        final navigator = Navigator.of(context);
        if (navigator.canPop()) {
          navigator.pop(true);
        } else {
          context.go(RouteName.productionWorkshopTasks);
        }
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

  /// One authoritative preview covers the complete report, including shared
  /// margins and actual material use. No row receives an independent allowance.
  Future<bool> _prepareActualOutputSupplements(
    List<DailyGridRow> rows,
    Map<String, dynamic> body,
  ) async {
    if (!_restoredSupplementContext &&
        !rows.any(
          (row) =>
              !row.isFqcRecovery &&
              (row.allowActualOverproduction ||
                  row.supplementProofId != null ||
                  row.supplementRequestId != null),
        )) {
      return true;
    }
    final repository = ref.read(productionOutputSupplementRepositoryProvider);
    final pending = <int, ProductionOutputSupplementView>{};
    final items = body['items'] as List<Map<String, Object?>>;
    ProductionOutputSupplementReportPreview preview;
    setState(() => _saving = true);
    try {
      for (var index = 0; index < rows.length; index++) {
        final row = rows[index];
        final id = row.supplementRequestId;
        if (id == null) continue;
        final supplement = await repository.detail(id);
        if (supplement.status == 'CANCELLED') {
          row.supplementRequestId = null;
          row.supplementProofId = null;
          items[index].remove('supplementProofId');
          continue;
        }
        final source = supplement.sourceLine;
        if (supplement.actualQty != double.tryParse(row.qty.text) ||
            source == null ||
            source.executionSegmentId != row.executionSegmentId ||
            source.executionSegmentSalesAllocationId !=
                row.executionSegmentSalesAllocationId) {
          throw ApiException(
            'CONFLICT',
            '第 ${index + 1} 行与已提交追加计划的数量或来源不一致，请先核对原追加计划；本次输入已保留',
          );
        }
        if (supplement.status == 'APPROVED') {
          row.supplementApprovedActualQty = supplement.actualQty;
        }
        if (supplement.status == 'APPROVED' &&
            supplement.proofId != null &&
            supplement.supplementSegmentStatus == 'IN_PROGRESS') {
          row.supplementProofId = supplement.proofId;
          row.supplementApprovedActualQty = supplement.actualQty;
          items[index]['supplementProofId'] = supplement.proofId;
        } else {
          pending[index] = supplement;
        }
      }
      preview = await repository.previewReport(
        body,
        excludedReportId: widget.id,
      );
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message);
      return false;
    } catch (_) {
      if (mounted) context.appError('本次整单超产范围尚未核对成功，请重试；数量、其他明细和实际用料均保留');
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    if (!mounted) return false;
    final required = preview.lines
        .where((line) => line.requiresSupplement)
        .toList();
    if (!preview.requiresSupplements && pending.isEmpty) return true;
    for (final line in required) {
      if (line.inputLineIndex < 0 ||
          line.inputLineIndex >= rows.length ||
          rows[line.inputLineIndex].executionSegmentId !=
              line.sourceSegmentId ||
          rows[line.inputLineIndex].executionSegmentSalesAllocationId !=
              line.sourceSalesAllocationId ||
          double.tryParse(rows[line.inputLineIndex].qty.text) !=
              line.actualQty) {
        context.appError('追加计划预览与当前明细不一致，请重新核对；当前输入保留');
        return false;
      }
    }
    if (required.isEmpty && pending.isEmpty) {
      context.appError('追加计划预览不完整，请重试；当前输入保留');
      return false;
    }
    final indices = {
      ...required.map((line) => line.inputLineIndex),
      ...pending.keys,
    }.toList()..sort();
    final uncreated = required
        .where((line) => rows[line.inputLineIndex].supplementRequestId == null)
        .toList();
    final permissions = ref.read(currentPermissionsProvider);
    final canCreate =
        ref.read(isSuperAdminProvider) ||
        (permissions.contains(Perm.productionExecutionView) &&
            (permissions.contains(productionSupplementRequestPermission) ||
                permissions.contains('production_plan:create')));
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('需要追加生产计划'),
        content: SizedBox(
          width: 680,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('超过已生效的允许范围时，超出原计划的部分整笔进入独立追加计划；不按容差上限截断本次实际产量。'),
                const SizedBox(height: 12),
                for (final index in indices) ...[
                  Text(
                    '第 ${index + 1} 行 · ${rows[index].goods?.name ?? '自制件'}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  for (final line in required.where(
                    (line) => line.inputLineIndex == index,
                  ))
                    Text(
                      '本次实际 ${line.actualQty}；原工单 ${line.originalReportQty}；独立追加 ${line.supplementQty}',
                    ),
                  if (pending[index] case final supplement?) ...[
                    Text(
                      '追加计划 ${supplement.planNo ?? ''} · ${supplement.status == 'APPROVED' ? '已审批，待显式开工' : '待计划部审批'}',
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context, 'view:$index'),
                      child: const Text('查看追加计划'),
                    ),
                  ],
                  const SizedBox(height: 12),
                ],
                Text(
                  '其余 ${rows.length - indices.length} 行与整单实际用料保持原输入；本次日报尚未保存。',
                ),
                if (!canCreate && uncreated.isNotEmpty)
                  const Text('请有追加申请权限的人员或计划员提交追加计划审批。'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('返回原报工表'),
          ),
          if (canCreate && uncreated.isNotEmpty)
            FilledButton(
              onPressed: () => Navigator.pop(context, 'create'),
              child: Text('提交 ${uncreated.length} 份追加计划审批'),
            ),
        ],
      ),
    );
    if (!mounted || action == null) return false;
    if (action.startsWith('view:')) {
      final index = int.parse(action.substring(5));
      await context.push(
        RoutePath.productionActualOutputSupplement(
          rows[index].supplementRequestId!,
        ),
        extra: 'return-to-report',
      );
      return false;
    }
    var created = 0;
    setState(() => _saving = true);
    try {
      for (final line in uncreated) {
        final supplement = await repository.create(
          ProductionOutputSupplementPreview({
            ...line.data,
            'sourceSegmentId': line.sourceSegmentId,
          }),
          billDate: body['billDate'] as String,
          remark: body['remark'] as String?,
          excludedReportId: widget.id,
          reportContext: body,
          inputLineIndex: line.inputLineIndex,
        );
        rows[line.inputLineIndex].supplementRequestId = supplement.id;
        created++;
      }
      if (mounted) {
        refreshBadges(ref);
        context.appInfo('已提交 $created 份追加计划审批；整张日报的数量与用料保留，审批并开工后再完整保存');
      }
    } on ApiException catch (error) {
      if (mounted) {
        context.appError('已提交 $created 份追加计划；${error.message}。其余输入仍保留');
      }
    } catch (_) {
      if (mounted) context.appWarning('已确认提交 $created 份，其他结果请核对后重试；原表全部输入保留');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    return false;
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
        child: Stack(
          children: [
            _loading
                ? const Center(
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                : !_isCreate && !_detailLoaded
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('日报草稿未能读取，原有内容没有改变'),
                        const SizedBox(height: UtenSpacing.s12),
                        FilledButton(
                          onPressed: _init,
                          child: const Text('重新读取草稿'),
                        ),
                      ],
                    ),
                  )
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
                                            workforceTree
                                                    ?.productionDepartmentId !=
                                                null &&
                                            node.parentId ==
                                                workforceTree!
                                                    .productionDepartmentId,
                                        treeOverride:
                                            workforceTree?.tree ?? const [],
                                        expandOnRowTap: true,
                                        initiallyExpandedIds:
                                            workforceTree
                                                ?.initiallyExpandedIds ??
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
                                          final s = sel.isEmpty
                                              ? null
                                              : sel.first;
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
                          // 2026-09-24 简洁口径：常驻教学横幅撤掉；仅恢复草稿/申请
                          // 时显示一条紧凑状态提示（条件渲染，非教学）。
                          if (_resumeNotice != null) ...[
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
                                    color:
                                        theme.colorScheme.onTertiaryContainer,
                                  ),
                                  const SizedBox(width: UtenSpacing.s8),
                                  Expanded(
                                    child: Text(
                                      _resumeNotice!,
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onTertiaryContainer,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: UtenSpacing.s12),
                          ],
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
                              key: const ValueKey(
                                'daily-report-draft-attachments',
                              ),
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
                          if (!_isCreate &&
                              _productRows.any((row) => row.isFinal))
                            Card(
                              child: Padding(
                                padding: const EdgeInsets.all(UtenSpacing.s12),
                                child: Wrap(
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  spacing: 12,
                                  children: [
                                    const Text(
                                      '此草稿含旧版提前完结标记；普通报工会保留原任务的未完成数量。',
                                    ),
                                    TextButton(
                                      onPressed: () => setState(() {
                                        for (final row in _productRows) {
                                          row.isFinal = false;
                                        }
                                        _surplusReturnRequested = false;
                                      }),
                                      child: const Text('改为普通报工'),
                                    ),
                                  ],
                                ),
                              ),
                            ),
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
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: _materialLoading
                                                ? theme
                                                      .colorScheme
                                                      .onSurfaceVariant
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
                            canDeleteRow: (r) =>
                                !r.isMaterialRow && !r.hasFixedSupplement,
                            onDeleteRow: _deleteProductRow,
                            rowColor: (r) => r.isMaterialRow
                                ? theme.colorScheme.surfaceContainerLow
                                : null,
                          ),
                        ],
                      ),
                    ),
                  ),
            // 保存/补传附件网络段的全屏加载遮罩。
            if (_saving)
              UtenBusyOverlay(
                title: widget.id == null ? '正在提交生产日报' : '正在保存生产日报',
                description: '正在写入报工与物料消耗事实，请勿重复提交或离开本页。',
              ),
          ],
        ),
      ),
      // 详情尚未回填时不出按钮：此刻点保存会把空表单当草稿提交。
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      // 新建态保存只认勾选的成品报工行（2026-09-18）：监听表格选择集，一条有货品
      // 的行都没勾时保存置灰（灰态点击说明原因），勾回任意行立即恢复。
      floatingActionButton: _loading || (!_isCreate && !_detailLoaded)
          ? null
          : ListenableBuilder(
              listenable: _grid,
              builder: (context, _) {
                final hasCheckedLine =
                    !_isCreate ||
                    _grid.selectedRows.any(
                      (row) => !row.isMaterialRow && row.goods != null,
                    );
                return UtenEditFloatingActions(
                  onCancel: () => popOrBackTo(
                    context,
                    defaultPath: RouteName.productionDailyReportList,
                  ),
                  onSave: hasCheckedLine ? _save : null,
                  saving: _saving,
                  saveDisabledHint: hasCheckedLine
                      ? null
                      : '请先勾选要报工的明细行（未勾选的行不会写入本张日报）',
                );
              },
            ),
    );
  }
}
