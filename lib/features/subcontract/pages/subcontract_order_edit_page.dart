// 委外订货单专属编辑页（2026-09 行级商业条款改造起从共享单据编辑页拆出）。
//
// 与共享页的差异：单头不再录币种/汇率/税率/结算方式（委外商此前已在明细行）——
// 商业条款全部下移明细行，逐行选择/填写（委外汇率此前固定 1，2026-09 起随条款
// 行级录入，支持跨币种委外）：
//  - 多选行「统一设置条款」一次写全套（委外商+结算方式+币种+汇率+税率，留空保持原值）；
//  - 行内点选结算方式/币种时，行处于多选选中态则联动填到所有选中行；
//  - 「学习模式」：按货品记住上次委外订货的整套条款（/last-terms），下次自动带出
//    （无记忆时回落默认：币种人民币、汇率 1、税率 0）；
//  - 保存走 createBatch 按「委外商+商业条款」组合自动拆单，每组条款归集到单头；
//  - 数量允许超过申请剩余量（超委外备货，2026-09 放开上限）；重量无上限；
//  - 每行末尾「备注」列，随行提交 remark；
//  - V304：手工行（无申请来源）仍允许——委外自建订货单。
//
// 编辑既有单：一单一套条款——行内改动同步全部明细行（保存时行条款=单头条款）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_drafts_button.dart';
import '../../../components/buttons/uten_edit_floating_actions.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/buttons/uten_import_button.dart';
import '../../../components/data_display/uten_totals_summary_bar.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
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
import '../../../core/utils/currency_display.dart';
import '../../basic_data/models/reference_method_option.dart';
import '../../basic_data/repositories/reference_method_repository.dart';
import '../../basic_data/widgets/uten_goods_picker.dart';
import '../../basic_data/widgets/uten_supplier_picker.dart';
import '../../department/repositories/department_repository.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../../shared/auth/document_scope_capability.dart';
import '../../../shared/attachments/business_attachment_section.dart';
import '../../../shared/attachments/pending_attachment_controller.dart';
import '../../../shared/attachments/pending_attachment_flow.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/measurement/measurement_totals.dart';
import '../../../shared/models/procurement_commercial_terms.dart';
import '../../../shared/presentation/workflow_field_guidance.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../../shared/providers/editable_grid_column_prefs.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/widgets/commercial_terms_batch_sheet.dart';
import '../../../shared/widgets/editable_grid_totals_bar.dart';
import '../../../shared/widgets/warehouse_hierarchy_dropdown.dart';
import '../config/subcontract_doc_config.dart';
import '../models/subcontract_doc.dart';
import '../repositories/subcontract_repository.dart';
import '../services/subcontract_save_workflow.dart';
import '../widgets/subcontract_grid_columns.dart';
import '../widgets/subcontract_link_picker.dart';

class SubcontractOrderEditPage extends ConsumerStatefulWidget {
  const SubcontractOrderEditPage({
    super.key,
    this.id,
    this.applicationItemIds = const [],
  });

  final String? id; // null=新建
  final List<String> applicationItemIds;

  @override
  ConsumerState<SubcontractOrderEditPage> createState() =>
      _SubcontractOrderEditPageState();
}

class _SubcontractOrderEditPageState
    extends ConsumerState<SubcontractOrderEditPage> {
  SubcontractDocConfig get _cfg => SubcontractDocConfig.order;

  bool get _canSubmitFinance => ref
      .read(currentPermissionsProvider)
      .contains(Perm.subcontractOrderSubmitFinance);
  bool get _isCreate => widget.id == null;

  /// 新建委外订货单保存前暂存的附件（ADR-074：保存拿到 UUID 后逐个确认上传）。
  final _pendingFiles = PendingAttachmentController();

  /// 订货单已生成但仍有附件上传失败：再点「保存」只重试附件，不重复建单。
  List<SubcontractDocDetail>? _createdOrders;

  final _billNo = TextEditingController(); // 只读显示（后端自动生成）
  final _remark = TextEditingController();
  DateTime _billDate = ChinaDateTime.today();
  DateTime? _deliverDate;
  String? _purchaserId;
  String? _warehouseId;
  final Map<String, UtenEmployeePickerItem> _empCache = {};

  final _grid = UtenEditableGridController<SubcontractGridRow>();
  final _scrollCtl = ScrollController();
  bool _saving = false;
  bool _loading = false;
  bool _orderSourceReady = true;
  String? _sourceApplicationBillNo;
  // 制单信息（服务端权威，只读展示）
  String? _makerName;
  String? _createdAt;
  // 币种默认（人民币 id）：新建行无记忆时的回落默认。
  String? _defaultCurrencyId;
  int _termsLoadGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
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
    for (final entry
        in ref.read(masterNameServiceProvider).currencyEntries.entries) {
      if (entry.value.contains('人民币')) {
        _defaultCurrencyId = entry.key;
        break;
      }
    }
    // 采购员默认当前登录人。
    final meId = ref.read(sessionProvider).user?.employeeId;
    if (meId != null && meId.isNotEmpty) {
      _purchaserId = meId;
      await _preloadEmployees([meId]);
    }
    if (_isCreate) {
      await _prefillFromApplication();
    } else {
      await _loadExisting();
    }
    if (_grid.isEmpty) _grid.addRow(_blankRow());
    if (mounted) setState(() => _loading = false);
  }

  /// 空白行带条款默认（币种人民币/汇率 1/税率 0）：学习记忆只在字段为空时回填，
  /// 先给默认会被记忆覆盖——顺序是「学习预填 → 默认兜底」，空白行直接给默认。
  SubcontractGridRow _blankRow() => SubcontractGridRow()
    ..currencyId = _defaultCurrencyId
    ..exchangeRate.text = '1'
    ..taxRate.text = '0';

  DateTime? _parseDate(String? s) =>
      (s == null || s.isEmpty) ? null : DateTime.tryParse(s);

  /// 并发按 id 拉人员字段名字（picker 的 initial 显示用）。失败静默。
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

  /// 任务中心带单新建：按委外申请明细 id 拉分解预览，预填行（数量=剩余量，可改大）。
  /// V463（ADR-069）：同「货品+颜色+单位」的申请明细自动合并成一行——数量加总、
  /// 来源申请逐条保留（保存时随行提交 applicationItemIds，服务端按剩余量 FIFO 拆分）。
  Future<void> _prefillFromApplication() async {
    final selectedIds = widget.applicationItemIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    // 列表页「直接委外下单」：留空白单手工录入（V304 手工行放行）或「从上游引入」。
    if (selectedIds.isEmpty) return;
    try {
      final open = await ref
          .read(subcontractRepositoryProvider(SubcontractDocType.application))
          .decompositionPreview(selectedIds);
      if (open.isEmpty) {
        throw StateError('所选申请明细已全部分解，请返回委外任务中心刷新');
      }
      final goodsIds = open.map((item) => item.goodsId).toSet();
      await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
      if (!mounted) return;
      final names = ref.read(masterNameServiceProvider);
      final rows = <SubcontractGridRow>[];
      // 同货品+颜色+单位 合并：数量=剩余量之和，来源逐条聚合（保留预览顺序）。
      final merged = <String, SubcontractGridRow>{};
      for (final item in open) {
        final key =
            '${item.goodsId}|${item.colorId ?? ''}|${item.unitId ?? ''}|${item.unitRate ?? 1}';
        final existing = merged[key];
        if (existing != null) {
          final total =
              (double.tryParse(existing.qty.text) ?? 0) + item.remainingQty;
          existing.qty.text = _formatQty(total);
          existing.maxQty = (existing.maxQty ?? 0) + item.remainingQty;
          existing.upstreamItemIds = [
            ...existing.upstreamItemIds,
            item.sourceItemId,
          ];
          existing.sourceDocs = [
            ...existing.sourceDocs,
            SubcontractSourceApplicationRef(
              applicationItemId: item.sourceItemId,
              applicationId: item.sourceDocumentId,
              billNo: item.sourceDocumentNo,
            ),
          ];
          continue;
        }
        final linked = LinkedItem(
          goodsId: item.goodsId,
          qty: item.remainingQty,
          maxQty: item.remainingQty,
          upstreamItemId: item.sourceItemId,
          colorId: item.colorId,
          unitId: item.unitId,
        );
        final row =
            SubcontractGridRow.fromLinked(
                linked,
                GoodsOption(id: item.goodsId, name: names.goods(item.goodsId)),
              )
              ..unitRate = item.unitRate
              ..sourceDocNo = item.sourceDocumentNo
              ..upstreamItemIds = [item.sourceItemId]
              ..sourceDocs = [
                SubcontractSourceApplicationRef(
                  applicationItemId: item.sourceItemId,
                  applicationId: item.sourceDocumentId,
                  billNo: item.sourceDocumentNo,
                ),
              ];
        rows.add(row);
        merged[key] = row;
      }
      if (rows.isEmpty) throw StateError('所选委外申请明细缺少有效货品');
      _grid.replaceAll(rows);
      await _prefillRememberedTerms();
      final dates =
          open
              .map((line) => _parseDate(line.needDate))
              .whereType<DateTime>()
              .toList()
            ..sort();
      _deliverDate = dates.isEmpty ? null : dates.first;
      _sourceApplicationBillNo = open
          .map((line) => line.sourceDocumentNo)
          .where((number) => number.isNotEmpty)
          .toSet()
          .join('、');
      _orderSourceReady = true;
    } on StateError catch (error) {
      _orderSourceReady = false;
      if (mounted) context.appError(error.message);
    } on ApiException catch (error) {
      _orderSourceReady = false;
      if (mounted) context.appError(error.message);
    } catch (_) {
      _orderSourceReady = false;
      if (mounted) context.appError('读取委外申请失败，请返回委外任务中心重试');
    }
  }

  /// 数量显示：整数值去掉小数尾巴，避免合并求和出现 100.00000000001。
  static String _formatQty(num value) =>
      value == value.roundToDouble() ? value.toInt().toString() : '$value';

  Future<void> _loadExisting() async {
    try {
      final d = await ref
          .read(subcontractRepositoryProvider(SubcontractDocType.order))
          .detail(widget.id!);
      final writable =
          d.status == kSubcontractStatusDraft &&
          d.canEdit &&
          await loadDocumentOwnerCanWrite(
            ref,
            DocumentDataScope.subcontract,
            d.makerId,
          );
      if (!mounted) return;
      if (!writable) {
        context.appWarning(documentScopeReadOnlyMessage, force: true);
        context.replace(SubcontractRoute.detail(_cfg.pathSegment, widget.id!));
        return;
      }
      final goodsIds = d.items
          .map((e) => e.goodsId)
          .whereType<String>()
          .toSet();
      await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
      await _preloadEmployees([d.purchaserId]);
      if (!mounted) return;
      _billNo.text = d.billNo ?? '';
      _remark.text = d.remark ?? '';
      if (d.billDate != null) {
        _billDate = DateTime.tryParse(d.billDate!) ?? _billDate;
      }
      _purchaserId = d.purchaserId;
      _warehouseId = d.warehouseId;
      _deliverDate = _parseDate(d.deliverDate);
      _makerName = d.makerName;
      _createdAt = d.createdAt;
      final rows = <SubcontractGridRow>[];
      for (final it in d.items) {
        final row =
            SubcontractGridRow(sourceLocked: it.applicationItemId != null)
              ..goods = it.goodsId == null
                  ? null
                  : GoodsOption(
                      id: it.goodsId!,
                      name: ref
                          .read(masterNameServiceProvider)
                          .goods(it.goodsId),
                    )
              ..qty.text = it.qty?.toString() ?? ''
              ..price.text = it.price?.toString() ?? ''
              ..weight.text = it.weight?.toString() ?? ''
              ..upstreamItemId = it.applicationItemId
              // V463：多来源合并行回显（来源明细 ids + 单号逐条带回）。
              ..upstreamItemIds = [
                if (it.applicationItemId != null) it.applicationItemId!,
                ...it.sourceApplications
                    .map((source) => source.applicationItemId)
                    .where((id) => id != it.applicationItemId),
              ]
              ..sourceDocs = it.sourceApplications
              ..colorId = it.colorId
              ..unitId = it.unitId
              ..unitRate = it.unitRate
              ..sourceDocNo = it.sourceDocNo;
        row.remark.text = it.remark ?? '';
        // 既有单一套条款：明细不落条款，编辑回显按单头条款回填各行。
        row
          ..supplierId = d.supplierId
          ..settlementMethodId = d.settlementMethodId
          ..currencyId = d.currencyId;
        row.exchangeRate.text = d.exchangeRate?.toString() ?? '1';
        row.taxRate.text = d.taxRate?.toString() ?? '0';
        rows.add(row);
      }
      _grid.replaceAll(rows);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      // 静默降级
    }
  }

  Future<void> _pickGoods(SubcontractGridRow row) async {
    if (row.sourceLocked) return;
    // 委外订货/进仓/退货选成品（sellable 为选择器默认范围）。
    final g = await showUtenGoodsPicker(context, ref);
    if (g == null) return;
    row
      ..goods = GoodsOption(id: g.id, code: g.code, name: g.name)
      ..colorId = g.colorId
      ..unitId = g.unitId
      ..stockPlaceNotifier.value = g.stockPlace;
    // 换货品后按「学习记忆」预填该货品上次委外订货的整套条款（不覆盖已选值）。
    await _prefillRememberedTerms();
  }

  /// 行级条款「学习预填」（/last-terms）：按货品查最近一次委外订货的整套条款，
  /// 回填各行尚未填的字段（委外商只回填启用中的；条款字典外的死值跳过）。
  /// 记忆未覆盖的字段回落默认（币种人民币/汇率 1/税率 0）。失败静默（提效加分项）。
  Future<void> _prefillRememberedTerms() async {
    final generation = ++_termsLoadGeneration;
    final session = ref.read(sessionProvider);
    final targets = {
      for (final row in _grid.rows)
        if (row.goods != null) row: (row.goods!.id, row.supplierId),
    };
    final pending = targets.keys
        .where(
          (r) =>
              r.goods != null &&
              (r.supplierId == null ||
                  r.settlementMethodId == null ||
                  r.currencyId == null ||
                  r.exchangeRate.text.trim().isEmpty ||
                  r.taxRate.text.trim().isEmpty),
        )
        .map((r) => r.goods!.id)
        .toSet();
    if (pending.isEmpty) return;
    Map<String, ProcurementLastTerms> remembered = const {};
    try {
      remembered = await ref
          .read(subcontractRepositoryProvider(SubcontractDocType.order))
          .lastTermsByGoods(pending);
    } catch (_) {
      // 学习预填失败静默：用户可逐行手选或勾选多行统一设置。
    }
    if (!mounted) return;
    final names = ref.read(masterNameServiceProvider);
    final settlementEntries = await _settlementEntries();
    if (!mounted ||
        generation != _termsLoadGeneration ||
        !identical(session, ref.read(sessionProvider))) {
      return;
    }
    final currencyEntries = names.currencyEntries;
    final currentRows = _grid.rows.toSet();
    var changed = false;
    for (final target in targets.entries) {
      final r = target.key;
      if (!currentRows.contains(r) ||
          r.goods?.id != target.value.$1 ||
          r.supplierId != target.value.$2) {
        continue;
      }
      final goodsId = target.value.$1;
      final terms = remembered[goodsId];
      if (terms != null) {
        if (r.supplierId == null &&
            terms.supplierId != null &&
            terms.supplierId!.isNotEmpty &&
            !names.isSupplierDisabled(terms.supplierId)) {
          r.supplierId = terms.supplierId;
          r.markTermsAutofilled('supplier', terms.supplierId!);
          changed = true;
        }
        if (r.settlementMethodId == null &&
            terms.settlementMethodId != null &&
            settlementEntries.containsKey(terms.settlementMethodId)) {
          r.settlementMethodId = terms.settlementMethodId;
          r.markTermsAutofilled('settlement', terms.settlementMethodId!);
          changed = true;
        }
        if (r.currencyId == null &&
            terms.currencyId != null &&
            currencyEntries.containsKey(terms.currencyId)) {
          r.currencyId = terms.currencyId;
          r.markTermsAutofilled('currency', terms.currencyId!);
          changed = true;
        }
        if (r.exchangeRate.text.trim().isEmpty && terms.exchangeRate != null) {
          r.exchangeRate.text = terms.exchangeRate.toString();
          r.markTermsAutofilled('rate', r.exchangeRate.text);
          changed = true;
        }
        if (r.taxRate.text.trim().isEmpty && terms.taxRate != null) {
          r.taxRate.text = terms.taxRate.toString();
          r.markTermsAutofilled('tax', r.taxRate.text);
          changed = true;
        }
      }
      changed = _applyTermDefaults(r) || changed;
    }
    if (changed && mounted) setState(() {});
  }

  /// 记忆未覆盖时回落默认：币种人民币、汇率 1、税率 0（结算方式无全局默认，
  /// 由供应商主档默认 V452 在选商后预填）。
  bool _applyTermDefaults(SubcontractGridRow r) {
    var changed = false;
    if (r.currencyId == null && _defaultCurrencyId != null) {
      r.currencyId = _defaultCurrencyId;
      r.markTermsAutofilled('currency', _defaultCurrencyId!);
      changed = true;
    }
    if (r.exchangeRate.text.trim().isEmpty) {
      r.exchangeRate.text = '1';
      r.markTermsAutofilled('rate', '1');
      changed = true;
    }
    if (r.taxRate.text.trim().isEmpty) {
      r.taxRate.text = '0';
      r.markTermsAutofilled('tax', '0');
      changed = true;
    }
    return changed;
  }

  /// 结算方式字典（启用中）：id → 名称(代码)。
  Future<Map<String, String>> _settlementEntries() async {
    try {
      final methods = await ref.read(settlementMethodOptionsProvider.future);
      return {for (final m in methods) m.id: '${m.name}(${m.code})'};
    } catch (_) {
      return const {};
    }
  }

  /// 委外商确定后预填结算方式（V452 供应商主档默认）：只预填启用中的方式，
  /// 不覆盖已选值。按行生效（行级条款）。
  Future<void> _prefillSettlementForRows(
    Iterable<SubcontractGridRow> rows,
    String supplierId,
  ) async {
    final targets = rows
        .where((r) => r.settlementMethodId == null)
        .toList(growable: false);
    if (targets.isEmpty) return;
    final candidate = ref
        .read(masterNameServiceProvider)
        .supplierDefaultSettlement(supplierId);
    if (candidate == null || candidate.isEmpty) return;
    final settlementEntries = await _settlementEntries();
    if (!settlementEntries.containsKey(candidate)) return;
    if (!mounted) return;
    final currentRows = _grid.rows.toSet();
    for (final r in targets) {
      if (!currentRows.contains(r) ||
          r.supplierId != supplierId ||
          r.settlementMethodId != null) {
        continue;
      }
      r.settlementMethodId = candidate;
      // 委外商主档默认也是系统带入：黄标提醒核对。
      r.markTermsAutofilled('settlement', candidate);
    }
    setState(() {});
  }

  /// 落值范围：新建=多选选中行（点的行在选中集→整组；否则仅本行）；
  /// 编辑既有单=全部行（一单一套条款）。
  List<SubcontractGridRow> _writeTargets(SubcontractGridRow row) {
    if (!_isCreate) return _grid.rows;
    final selected = _grid.selectedRows;
    return selected.contains(row) ? selected : [row];
  }

  /// 多选行「统一设置条款」：打开批量面板一次写全套（委外商+结算方式+币种+汇率+
  /// 税率；留空的项保持各行原值）。
  Future<void> _batchSetTerms() async {
    final rows = _grid.selectedRows;
    if (rows.isEmpty) return;
    final names = ref.read(masterNameServiceProvider);
    final settlementEntries = await _settlementEntries();
    if (!mounted) return;
    final result = await showCommercialTermsBatchSheet(
      context,
      ref,
      selectedCount: rows.length,
      currencyEntries: names.currencyEntries,
      settlementEntries: settlementEntries,
      partyNoun: '委外商',
      settlementLabel: '结算方式',
    );
    if (result == null || !mounted) return;
    // 编辑既有单只能一套条款：批量写全部行。
    final targets = _isCreate ? rows : _grid.rows;
    for (final r in targets) {
      // 用户显式批量设置=已核对：写到的字段清掉学习预填黄标。
      if (result.supplierId != null) {
        r.supplierId = result.supplierId;
        r.clearTermsAutofilled('supplier');
      }
      if (result.settlementMethodId != null) {
        r.settlementMethodId = result.settlementMethodId;
        r.clearTermsAutofilled('settlement');
      }
      if (result.currencyId != null) {
        r.currencyId = result.currencyId;
        r.clearTermsAutofilled('currency');
      }
      if (result.exchangeRate != null) {
        r.exchangeRate.text = result.exchangeRate.toString();
        r.clearTermsAutofilled('rate');
      }
      if (result.taxRate != null) {
        r.taxRate.text = result.taxRate.toString();
        r.clearTermsAutofilled('tax');
      }
    }
    setState(() {});
    if (result.supplierId != null) {
      unawaited(_prefillSettlementForRows(targets, result.supplierId!));
    }
    if (!_isCreate) {
      context.appInfo('既有委外订货单保持一套商业条款，已同步全部明细行');
    }
  }

  /// 行级委外商选择：滑入面板选中后按多选范围落值（编辑态=全部行）。
  Future<void> _pickRowSupplier(SubcontractGridRow row) async {
    final picked = await showUtenSupplierPicker(context, ref, title: '选择委外商');
    if (picked == null || !mounted) return;
    _applyRowSupplier(row, picked.id);
  }

  void _applyRowSupplier(SubcontractGridRow row, String? value) {
    final targets = _writeTargets(row);
    for (final r in targets) {
      r.supplierId = value;
      // 用户手选=已核对，清掉学习预填黄标。
      r.clearTermsAutofilled('supplier');
    }
    if (!_isCreate) {
      context.appInfo('既有委外订货单保持一单一商，已同步全部明细行');
    } else if (targets.length > 1) {
      context.appSuccess('已为 ${targets.length} 行设置同一委外商');
    }
    setState(() {});
    if (value != null && value.isNotEmpty) {
      unawaited(_prefillSettlementForRows(targets, value));
    }
  }

  /// 行级币种/结算方式选择落值（下拉菜单）：多选联动同委外商。
  /// [clearKey] 本次改的条款 key：对全部落值行清掉学习预填黄标（用户改=已核对）。
  void _applyRowTerm(
    SubcontractGridRow row,
    void Function(SubcontractGridRow r) write, {
    String? clearKey,
  }) {
    final targets = _writeTargets(row);
    for (final r in targets) {
      write(r);
      if (clearKey != null) r.clearTermsAutofilled(clearKey);
    }
    setState(() {});
  }

  /// 「从上游引入」：从计划申请拉明细（本次数量默认剩余量，可改大——超委外允许）。
  Future<void> _importFromUpstream() async {
    final result = await showSubcontractLinkPicker(
      context,
      ref,
      _cfg,
      allowOverRemaining: true,
    );
    if (!mounted) return;
    if (result == null || result.items.isEmpty) return;
    final goodsIds = result.items
        .map((e) => e.goodsId)
        .where((id) => id.isNotEmpty)
        .toSet();
    if (goodsIds.isNotEmpty) {
      await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
    }
    if (!mounted) return;
    // V463：同「货品+颜色+单位」的引入项并入既有行（数量加总、来源聚合）。
    for (final li in result.items) {
      if (li.goodsId.isEmpty) continue;
      final goods = GoodsOption(
        id: li.goodsId,
        name: ref.read(masterNameServiceProvider).goods(li.goodsId),
      );
      final row = SubcontractGridRow.fromLinked(li, goods)
        ..sourceDocs = [
          // 引入选择器不回来源单头信息：先带明细 id 占位，单号留待保存后由
          // 服务端 sources 回显（跳详情在详情页逐行可见）。
          if (li.upstreamItemId != null && li.upstreamItemId!.isNotEmpty)
            SubcontractSourceApplicationRef(
              applicationItemId: li.upstreamItemId!,
            ),
        ];
      final key =
          '${row.goods?.id ?? ''}|${row.colorId ?? ''}|${row.unitId ?? ''}|${row.unitRate ?? 1}';
      var hit = false;
      for (final existing in _grid.rows) {
        final existingKey =
            '${existing.goods?.id ?? ''}|${existing.colorId ?? ''}|${existing.unitId ?? ''}|${existing.unitRate ?? 1}';
        if (existingKey != key) continue;
        final total =
            (double.tryParse(existing.qty.text) ?? 0) +
            (double.tryParse(row.qty.text) ?? 0);
        existing.qty.text = _formatQty(total);
        existing.maxQty = (existing.maxQty ?? 0) + (row.maxQty ?? 0);
        existing.upstreamItemIds = [
          ...existing.upstreamItemIds,
          ...row.upstreamItemIds,
        ];
        existing.sourceDocs = [...existing.sourceDocs, ...row.sourceDocs];
        hit = true;
        break;
      }
      if (!hit) _grid.addRow(row);
    }
    _grid.removeWhere(
      (r) =>
          r.goods == null &&
          r.qty.text.trim().isEmpty &&
          r.price.text.trim().isEmpty,
    );
    await _prefillRememberedTerms();
  }

  /// 委外商显示名映射：启用中的供应商；被引用的禁用商补进并标「已禁用」。
  Map<String, String> _supplierDropdownEntries() {
    final names = ref.read(masterNameServiceProvider);
    final entries = {...names.supplierActiveEntries};
    for (final id in _grid.rows.map((r) => r.supplierId)) {
      if (id == null || id.isEmpty || entries.containsKey(id)) continue;
      final name = names.supplierEntries[id];
      if (name == null || name.isEmpty) continue;
      entries[id] = '$name（已禁用）';
    }
    return entries;
  }

  /// 行条款组合键（拆单预览/一致性校验用）：数量值按数值等价（1.0 与 1 同组）。
  String _comboKey(SubcontractGridRow r) {
    final rate = double.tryParse(r.exchangeRate.text.trim()) ?? 0;
    final tax = double.tryParse(r.taxRate.text.trim()) ?? 0;
    return '${r.supplierId}|${r.settlementMethodId}|${r.currencyId}|'
        '${rate.toStringAsFixed(6)}|${tax.toStringAsFixed(4)}';
  }

  Future<void> _save() async {
    if (_createdOrders case final created?) {
      // 订货单已生成、附件未全部上传：只补传附件，成功后再提交财务/进入详情。
      setState(() => _saving = true);
      try {
        await _finishCreatedOrders(created);
      } finally {
        if (mounted) setState(() => _saving = false);
      }
      return;
    }
    final rows = _grid.rows.where((r) => r.goods != null).toList();
    if (rows.isEmpty) {
      context.appError('请至少添加一条明细');
      return;
    }
    // 行级条款完整性：委外商/结算方式/币种必填，汇率>0，税率 0-100。
    for (final r in rows) {
      if (r.supplierId == null) {
        context.appError('${r.goods!.name} 未选择委外商；可勾选多行统一设置');
        return;
      }
      if (r.settlementMethodId == null) {
        context.appError('${r.goods!.name} 未选择结算方式；可勾选多行统一设置');
        return;
      }
      if (r.currencyId == null) {
        context.appError('${r.goods!.name} 未选择币种；可勾选多行统一设置');
        return;
      }
      final rate = double.tryParse(r.exchangeRate.text.trim());
      if (rate == null || rate <= 0) {
        context.appError('${r.goods!.name} 的汇率必须大于 0');
        return;
      }
      final taxError = validateSubcontractTaxRate(
        r.taxRate.text,
        required: true,
      );
      if (taxError != null) {
        context.appError('${r.goods!.name}：$taxError');
        return;
      }
    }
    // 编辑既有单：一单一套条款（行条款必须全一致）。
    if (!_isCreate && rows.map(_comboKey).toSet().length != 1) {
      context.appError('既有委外订货单必须保持一套商业条款（委外商/结算方式/币种/汇率/税率）');
      return;
    }
    final settlementEntries = await _settlementEntries();
    if (!mounted) return;
    for (final r in rows) {
      if (!settlementEntries.containsKey(r.settlementMethodId)) {
        context.appError('${r.goods!.name} 的结算方式已停用，请重新选择');
        return;
      }
    }
    final itemsBody = <Map<String, dynamic>>[];
    for (final r in rows) {
      final qty = double.tryParse(r.qty.text) ?? 0;
      if (qty <= 0) {
        context.appError('${r.goods!.name} 的数量必须大于 0');
        return;
      }
      // 2026-09 起订货允许超过申请剩余量（超委外备货）：不再校验 qty ≤ maxQty。
      final priceError = validateSubcontractOrderPrice(
        docType: SubcontractDocType.order,
        goodsName: r.goods!.name ?? r.goods!.code ?? '该货品',
        priceText: r.price.text,
      );
      if (priceError != null) {
        context.appError(priceError);
        return;
      }
      final price = double.tryParse(r.price.text)!;
      final weightText = r.weight.text.trim();
      final weight = weightText.isEmpty ? null : double.tryParse(weightText);
      if (weightText.isNotEmpty && (weight == null || weight <= 0)) {
        context.appError('${r.goods!.name} 的实际重量必须大于 0');
        return;
      }
      final rate = double.tryParse(r.exchangeRate.text.trim())!;
      final tax = double.tryParse(r.taxRate.text.trim())!;
      final remarkText = r.remark.text.trim();
      itemsBody.add({
        'goodsId': r.goods!.id,
        'qty': qty,
        'price': price,
        'amountOriginal': qty * price,
        'amountLocal': qty * price * rate,
        if (r.upstreamItemId != null) 'applicationItemId': r.upstreamItemId,
        // V463 同货品合并行：多来源申请明细逐条提交，服务端按剩余量 FIFO 拆分。
        if (r.upstreamItemIds.length > 1)
          'applicationItemIds': r.upstreamItemIds,
        if (r.sourceDocNo?.isNotEmpty == true) 'sourceDocNo': r.sourceDocNo,
        if (r.colorId != null) 'colorId': r.colorId,
        if (r.unitId != null) 'unitId': r.unitId,
        if (r.unitRate != null) 'unitRate': r.unitRate,
        'weight': ?weight,
        'supplierId': r.supplierId,
        'settlementMethodId': r.settlementMethodId,
        'currencyId': r.currencyId,
        'exchangeRate': rate,
        'taxRate': tax,
        if (remarkText.isNotEmpty) 'remark': remarkText,
      });
    }
    final comboCount = rows.map(_comboKey).toSet().length;
    final body = <String, dynamic>{
      'billDate': _fmt(_billDate),
      'remark': _remark.text.trim().isEmpty ? null : _remark.text.trim(),
      'purchaserId': _purchaserId,
      'warehouseId': _warehouseId,
      if (_deliverDate != null) 'deliverDate': _fmt(_deliverDate!),
      'items': itemsBody,
    };
    setState(() => _saving = true);
    try {
      final repo = ref.read(
        subcontractRepositoryProvider(SubcontractDocType.order),
      );
      if (_isCreate) {
        final created = await repo.createBatch(body);
        if (!mounted) return;
        await _finishCreatedOrders(created, comboCount: comboCount);
        return;
      }
      // 编辑既有单：单头条款 = 全行一致的条款（行值即单头值）。
      final first = rows.first;
      body['supplierId'] = first.supplierId;
      body['settlementMethodId'] = first.settlementMethodId;
      body['currencyId'] = first.currencyId;
      body['exchangeRate'] = double.tryParse(first.exchangeRate.text.trim());
      body['taxRate'] = double.tryParse(first.taxRate.text.trim());
      final outcome = await saveSubcontractDocument(
        repository: repo,
        docType: SubcontractDocType.order,
        body: body,
        id: widget.id,
        submitFinance: _canSubmitFinance,
      );
      if (!mounted) return;
      final d = outcome.detail;
      if (outcome.financeSubmitError case final error?) {
        context.appWarning('委外订货单已保存，但未提交财务：$error。可在详情页重新提交。');
        bumpListRefresh(ref, _cfg.refreshKey);
        context.replace(SubcontractRoute.detail(_cfg.pathSegment, d.id));
        return;
      }
      if (!mounted) return;
      context.appSuccess(_canSubmitFinance ? '委外订货单已提交财务审核' : '委外订货单草稿已保存');
      bumpListRefresh(ref, _cfg.refreshKey);
      context.replace(SubcontractRoute.detail(_cfg.pathSegment, d.id));
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('保存失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 新建拆单收尾：先把暂存附件挂到每张新委外订货单（提交财务后对象策略不再允许改附件），
  /// 全部成功再提交财务并跳转；任一附件失败则留在本页，保留失败项供重试。
  Future<void> _finishCreatedOrders(
    List<SubcontractDocDetail> created, {
    int? comboCount,
  }) async {
    final repo = ref.read(
      subcontractRepositoryProvider(SubcontractDocType.order),
    );
    final groups = comboCount ?? created.length;
    try {
      if (_pendingFiles.isNotEmpty) {
        if (_createdOrders == null) setState(() => _createdOrders = created);
        final ok = await flushPendingAttachments(
          context,
          ref,
          _pendingFiles,
          ownerType: 'SUBCONTRACT_ORDER',
          ownerIds: [for (final createdDoc in created) createdDoc.id],
        );
        if (!mounted || !ok) return;
      }
      if (_createdOrders != null) setState(() => _createdOrders = null);
      String? financeError;
      if (_canSubmitFinance) {
        for (final createdDoc in created) {
          try {
            await repo.submitFinance(createdDoc.id);
          } on ApiException catch (e) {
            financeError ??= e.message;
          }
        }
      }
      if (!mounted) return;
      bumpListRefresh(ref, _cfg.refreshKey);
      if (financeError != null) {
        context.appWarning(
          '已生成 ${created.length} 张委外订货单，部分未提交财务：$financeError',
        );
      } else if (_canSubmitFinance) {
        context.appSuccess(
          groups > 1
              ? '已按「委外商+条款组合」拆分为 $groups 组共 ${created.length} 张委外订货单并提交财务'
              : '委外订货单已提交财务审核',
        );
      } else {
        context.appSuccess(
          groups > 1
              ? '已按「委外商+条款组合」拆分并保存 ${created.length} 张委外订货单草稿'
              : '委外订货单草稿已保存',
        );
      }
      if (created.length == 1) {
        context.replace(
          SubcontractRoute.detail(_cfg.pathSegment, created.first.id),
        );
      } else {
        context.go('/subcontract/${_cfg.type.pathSegment}');
      }
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('保存失败，请稍后重试');
    }
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// 新建态 AppBar 右上角「草稿(N)」入口。
  ///
  /// 管理卡 skipListOnCreate 直达新建页，从 hub 打不开列表；本按钮是用户回到自己
  /// 草稿的唯一入口（点击进列表并预选草稿段）。编辑既有单据时不显示。
  List<Widget>? get _draftsAction {
    if (!_isCreate || !_cfg.skipListOnCreate) return null;
    final kind = _cfg.draftKind;
    if (kind == null) return null;
    return [UtenDraftsButton(kind: kind, listLocation: _cfg.listLocation)];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    return Scaffold(
      appBar: UtenAppBar(
        title: _isCreate ? '新建${_cfg.label}' : '编辑${_cfg.label}',
        leading: UtenBackButton(
          onPressed: () => popOrBackTo(context, defaultPath: '/subcontract'),
        ),
        actions: _draftsAction,
      ),
      // 底部固定操作条 2026-09-11 撤除（全站同改）：改右下角悬浮「取消 / 保存」；
      // 加载中不出按钮，避免数据没就位就能点保存。
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: _loading
          ? null
          : UtenEditFloatingActions(
              onCancel: () => popOrBackTo(context, defaultPath: '/subcontract'),
              onSave: _save,
              saving: _saving,
              saveLabel: _canSubmitFinance ? '保存并提交财务审核' : '保存订货单草稿',
              saveIcon: _canSubmitFinance
                  ? Icons.send_outlined
                  : Icons.save_outlined,
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
                    // 底部多留一个悬浮组的高度，最后一行明细不被「取消/保存」压住。
                    padding: const EdgeInsets.fromLTRB(
                      UtenSpacing.s12,
                      UtenSpacing.s12,
                      UtenSpacing.s12,
                      UtenSpacing.s12 + 88,
                    ),
                    children: [
                      if (_isCreate) ...[
                        _orderSourceBanner(theme),
                        const SizedBox(height: UtenSpacing.s12),
                      ],
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(UtenSpacing.s12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              UtenFormGrid(
                                children: [
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
                                  _employeePicker(
                                    label: '采购员',
                                    currentId: _purchaserId,
                                    onChanged: (id) =>
                                        setState(() => _purchaserId = id),
                                  ),
                                  UtenDateField(
                                    label: '交货日期',
                                    value: _deliverDate,
                                    onChanged: (d) =>
                                        setState(() => _deliverDate = d),
                                  ),
                                  if (_grid.rows.any(
                                    (row) => !row.sourceLocked,
                                  ))
                                    UtenDropdownField(
                                      key: const Key(
                                        'subcontract-preparation-warehouse',
                                      ),
                                      label: workflowFieldText(
                                        context,
                                      ).subcontractPreparationWarehouse,
                                      info: workflowFieldText(
                                        context,
                                      ).subcontractPreparationWarehouseHint,
                                      value: _warehouseId,
                                      enabled: !_saving,
                                      items: warehouseHierarchyItems(
                                        names.warehouseHierarchy,
                                        currentValue: _warehouseId,
                                      ),
                                      onChanged: (id) =>
                                          setState(() => _warehouseId = id),
                                    ),
                                ],
                              ),
                              const SizedBox(height: UtenSpacing.s12),
                              TextField(
                                controller: _remark,
                                decoration: const InputDecoration(
                                  labelText: '单据备注',
                                ),
                                maxLines: 2,
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s12),
                      // 委外订货单附件：已有单直接挂 SUBCONTRACT_ORDER；新建单先本地暂存，
                      // 拆单生成后逐张确认上传，再提交财务（ADR-074）。
                      if (!_isCreate)
                        BusinessAttachmentSection(
                          ownerType: 'SUBCONTRACT_ORDER',
                          ownerId: widget.id!,
                          canView: ref
                              .watch(currentPermissionsProvider)
                              .contains(Perm.attachmentView),
                          // 进入编辑页即已确认可写；对象范围与状态由服务端附件策略再校验。
                          canManage: true,
                          title: '附件（合同/加工要求/图片）',
                          categories: const ['合同', '加工要求', '图片', '其他'],
                        )
                      else ...[
                        if (_createdOrders != null)
                          const PendingAttachmentRetryNotice(
                            documentLabel: '委外订货单',
                          ),
                        BusinessAttachmentSection.draft(
                          key: const ValueKey(
                            'subcontract-order-draft-attachments',
                          ),
                          controller: _pendingFiles,
                          canManage: ref
                              .watch(currentPermissionsProvider)
                              .contains(Perm.subcontractOrderCreate),
                          title: '附件（合同/加工要求/图片）',
                          categories: const ['合同', '加工要求', '图片', '其他'],
                        ),
                      ],
                      const SizedBox(height: UtenSpacing.s12),
                      // 「明细 (N)」标题行 2026-09-11 撤除；同日「从上游引入」也并入
                      // 明细表工具条，与「表头设置」同排同高（不再单独占一行）。
                      // 列显隐/排序持久化（本页固定订货模式，单桶即可；账号级）。
                      Builder(
                        builder: (_) {
                          final columnPrefs = ref.watch(
                            subcontractOrderGridColumnPrefsProvider,
                          )['order'];
                          return UtenEditableGrid<SubcontractGridRow>(
                            controller: _grid,
                            showColumnSettings: true,
                            initialColumnOrder: columnPrefs?.order,
                            initialHiddenColumnKeys: columnPrefs?.hidden,
                            onColumnSettingsChanged: (order, hidden) => ref
                                .read(
                                  subcontractOrderGridColumnPrefsProvider
                                      .notifier,
                                )
                                .updateFor('order', order, hidden),
                            toolbarActions: [
                              UtenImportButton(
                                label: '从上游引入',
                                onPressed: _importFromUpstream,
                              ),
                            ],
                            // 「统一设置条款」2026-09-11 从工具条撤到行右键菜单
                            // （与采购订货单同改：多选右键已有入口，工具条上重复）。
                            rowMenuExtraBuilder: (ctx, selected) => [
                              UtenMenuItem(
                                label: '统一设置条款 (${selected.length})',
                                icon: Icons.tune_rounded,
                                enabled: selected.isNotEmpty,
                                onTap: _batchSetTerms,
                              ),
                            ],
                            columns: subcontractGridColumns(
                              _pickGoods,
                              _cfg,
                              context: context,
                              unitEntries: names.unitEntries,
                              supplierEntries: _supplierDropdownEntries(),
                              supplierRequired: true,
                              onPickSupplier: _pickRowSupplier,
                              // 行级商业条款（2026-09）：单头不再录，逐行选择/填写。
                              showCommercial: true,
                              currencyEntries: names.currencyEntries,
                              settlementEntries:
                                  ref
                                      .watch(settlementMethodOptionsProvider)
                                      .valueOrNull
                                      ?.asEntries() ??
                                  const {},
                              onPickCurrency: (row) =>
                                  (value) => _applyRowTerm(
                                    row,
                                    (r) => r.currencyId = value,
                                    clearKey: 'currency',
                                  ),
                              onPickSettlement: (row) =>
                                  (value) => _applyRowTerm(row, (r) {
                                    r.settlementMethodId = value;
                                  }, clearKey: 'settlement'),
                              // 每行末尾备注列。
                              showRemark: true,
                            ),
                            // 合计条（全站统一口径）：底部固定操作条 2026-09-11 改
                            // 右下角悬浮后合计回到表尾。数量按单位分组绝不相加；
                            // 订货条款行级，只有全单币种唯一时才标注币种。
                            footer: EditableGridTotalsBar<SubcontractGridRow>(
                              key: const Key('subcontract-order-edit-totals'),
                              controller: _grid,
                              showDivider: false,
                              watchOf: (row) => [row.qty],
                              entriesBuilder: (rows) {
                                final currencyIds = rows
                                    .map((row) => row.currencyId)
                                    .whereType<String>()
                                    .where((id) => id.isNotEmpty)
                                    .toSet();
                                return [
                                  utenQuantityTotalEntry(
                                    rows
                                        .where((row) => row.goods != null)
                                        .map(
                                          (row) => MeasuredAmount(
                                            value:
                                                double.tryParse(
                                                  row.qty.text.trim(),
                                                ) ??
                                                0,
                                            unitId: row.unitId,
                                            unitName:
                                                names.unitEntries[row.unitId],
                                          ),
                                        ),
                                  ),
                                  UtenTotalEntry(
                                    utenAmountTotalLabel(
                                      currencyIds.length == 1
                                          ? financeCurrencyDisplayLabel(
                                              name: names.currency(
                                                currencyIds.first,
                                              ),
                                            )
                                          : null,
                                    ),
                                    _grid.totalListenable.value.toStringAsFixed(
                                      2,
                                    ),
                                    danger: true,
                                  ),
                                ];
                              },
                            ),
                            createBlankRow: _blankRow,
                            cloneRow: (r) => r.clone(),
                            // V304：订货单放开手工行（委外自建订货单，无申请来源）。
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  /// 来源横幅：物料分析带单 / 直接委外下单；条款行级说明与超委外允许。
  Widget _orderSourceBanner(ThemeData theme) {
    final ready = _orderSourceReady;
    final source = _sourceApplicationBillNo?.trim();
    final fromMaterialAnalysis =
        source?.isNotEmpty == true || widget.applicationItemIds.isNotEmpty;
    final background = ready
        ? theme.colorScheme.secondaryContainer
        : theme.colorScheme.errorContainer;
    final foreground = ready
        ? theme.colorScheme.onSecondaryContainer
        : theme.colorScheme.onErrorContainer;
    return Semantics(
      container: true,
      label: !ready
          ? '必须先从委外任务中心选择计划下达申请'
          : '委外商与结算方式、币种、汇率、税率都在明细行填写；勾选多行可统一设置；'
                '系统会记住每个货品上次的条款并在下次自动带出；数量允许超过申请剩余量。',
      child: Card(
        color: background,
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                ready ? Icons.tune_rounded : Icons.task_alt_rounded,
                color: foreground,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      !ready
                          ? '请先选择委外申请明细'
                          : fromMaterialAnalysis
                          ? '物料分析下达委外 · 条款在明细行填写'
                          : '直接委外下单 · 条款在明细行填写',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      !ready
                          ? '来源申请未加载完整。请回到委外任务中心重新选择需要分解的申请明细。'
                          : '委外商与结算方式、币种、汇率、税率逐行选择；勾选多行后可'
                                '「统一设置条款」一次写全套。同一货品会记住上次委外的条款，'
                                '下次自动带出。保存时按「委外商+条款组合」自动拆单。'
                                '数量允许超过申请剩余量（超委外备货）。',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: foreground,
                      ),
                    ),
                    if (!ready) ...[
                      const SizedBox(height: UtenSpacing.s12),
                      UtenButton(
                        icon: Icons.arrow_back_rounded,
                        onPressed: () => goFrom(
                          context,
                          RouteName.operationsSubcontractWorkbench,
                        ),
                        child: const Text('返回委外任务中心选择'),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
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

extension _SettlementEntries on List<ReferenceMethodOption> {
  /// 结算方式字典映射：id → 名称(代码)。
  Map<String, String> asEntries() => {
    for (final m in this) m.id: '${m.name}(${m.code})',
  };
}
