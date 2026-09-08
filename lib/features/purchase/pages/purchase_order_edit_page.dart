// 采购订货单专属编辑页（2026-09 行级商业条款改造起从共享单据编辑页拆出）。
//
// 与共享页的差异：单头不再录币种/汇率/税率/结账方式（供应商此前已在明细行）——
// 商业条款全部下移明细行，逐行选择/填写：
//  - 多选行「统一设置条款」一次写全套（供应商+结账方式+币种+汇率+税率，留空保持原值）；
//  - 行内点选结账方式/币种时，行处于多选选中态则联动填到所有选中行；
//  - 「学习模式」：按货品记住上次订货的整套条款（/last-terms），下次建单自动带出
//    （无记忆时回落默认：币种人民币、汇率 1、税率 0）；
//  - 保存走 createBatch 按「供应商+商业条款」组合自动拆单，每组条款归集到该张单头；
//  - 数量允许超过申请剩余量（超采备货，2026-09 放开上限）；重量无上限。
//  - 每行末尾「备注」列，随行提交 remark。
//
// 编辑既有单：一单一套条款——行内改动同步全部明细行（保存时行条款=单头条款）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_import_button.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../basic_data/models/reference_method_option.dart';
import '../../basic_data/repositories/reference_method_repository.dart';
import '../../basic_data/widgets/uten_goods_picker.dart';
import '../../basic_data/widgets/uten_supplier_picker.dart';
import '../../department/models/department_node.dart';
import '../../department/repositories/department_repository.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../notice/providers/notice_providers.dart';
import '../../../shared/auth/document_scope_capability.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/concurrency/task_claim_session.dart';
import '../../../shared/models/procurement_commercial_terms.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../../shared/providers/editable_grid_column_prefs.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/repositories/task_claim_repository.dart';
import '../../../shared/widgets/commercial_terms_batch_sheet.dart';
import '../config/purchase_doc_config.dart';
import '../models/purchase_doc.dart';
import '../repositories/purchase_repository.dart';
import '../widgets/doc_link_picker.dart';
import '../widgets/purchase_grid_columns.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../core/router/nav_helpers.dart';

class PurchaseOrderEditPage extends ConsumerStatefulWidget {
  const PurchaseOrderEditPage({
    super.key,
    this.id,
    this.sourceRequestId,
    this.sourceRequestItemIds = const [],
  });

  final String? id; // null=新建
  final String? sourceRequestId;
  final List<String> sourceRequestItemIds;

  @override
  ConsumerState<PurchaseOrderEditPage> createState() =>
      _PurchaseOrderEditPageState();
}

class _PurchaseOrderEditPageState extends ConsumerState<PurchaseOrderEditPage> {
  PurchaseDocConfig get _cfg => PurchaseDocConfig.order;

  bool get _canSubmitFinance => ref
      .read(currentPermissionsProvider)
      .contains(Perm.purchaseOrderSubmitFinance);
  bool get _isCreate => widget.id == null;

  final _billNo = TextEditingController(); // 只读显示（后端自动生成）
  final _remark = TextEditingController();
  DateTime _billDate = ChinaDateTime.today();
  DateTime? _deliverDate;

  String? _purchaserId;
  final Map<String, UtenEmployeePickerItem> _empCache = {};

  final _grid = UtenEditableGridController<PurchaseGridRow>();
  final _scrollCtl = ScrollController();
  bool _saving = false;
  bool _loading = false;
  // 制单信息（服务端权威，只读展示）
  String? _makerName;
  String? _createdAt;
  // 采购分解订货的并发认领会话（PURCHASE_DECOMPOSE，按申请 id 认领；他人占用时禁用保存）。
  TaskClaimSession? _decomposeClaim;
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
    _grid.dispose(); // 自动 dispose 各行控制器
    _scrollCtl.dispose();
    _decomposeClaim?.releaseAll(); // 离开编辑页释放分解认领
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
      await _prefillFromRequest();
    } else {
      await _loadExisting();
    }
    if (_grid.isEmpty) _grid.addRow(PurchaseGridRow());
    if (mounted) setState(() => _loading = false);
  }

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

  /// 任务中心带单新建：按申请明细 id 拉分解预览，预填行（数量=剩余量，可改大）。
  /// V463（ADR-069）：同「货品+颜色+单位」的申请明细自动合并成一行——数量加总、
  /// 来源申请逐条保留（保存时随行提交 requestItemIds，服务端按剩余量 FIFO 拆分）。
  Future<void> _prefillFromRequest() async {
    final selectedIds = widget.sourceRequestItemIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    // 卡片直达新建（无任务中心带入的申请行）：留空白单，由用户「从上游引入」拉取。
    if (selectedIds.isEmpty) return;
    try {
      final open = await ref
          .read(purchaseRepositoryProvider(PurchaseDocType.request))
          .decompositionPreview(selectedIds);
      if (open.isEmpty) {
        throw StateError('所选申请明细已全部分解，请返回任务中心刷新');
      }
      final goodsIds = open.map((item) => item.goodsId).toSet();
      await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
      if (!mounted) return;
      final names = ref.read(masterNameServiceProvider);
      final rows = <PurchaseGridRow>[];
      // 同货品+颜色+单位 合并：数量=剩余量之和，来源逐条聚合（保留预览顺序）。
      final merged = <String, PurchaseGridRow>{};
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
            PurchaseSourceRequestRef(
              requestItemId: item.sourceItemId,
              requestId: item.sourceDocumentId,
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
          unitRate: item.unitRate,
        );
        final row = PurchaseGridRow.fromLinked(
          linked,
          GoodsOption(id: item.goodsId, name: names.goods(item.goodsId)),
        );
        row
          ..sourceRequestNo = item.sourceDocumentNo
          ..sourceRequestId = item.sourceDocumentId
          ..upstreamItemIds = [item.sourceItemId]
          ..sourceDocs = [
            PurchaseSourceRequestRef(
              requestItemId: item.sourceItemId,
              requestId: item.sourceDocumentId,
              billNo: item.sourceDocumentNo,
            ),
          ];
        rows.add(row);
        merged[key] = row;
      }
      if (rows.isEmpty) throw StateError('所选采购申请明细缺少有效物料');
      _grid.replaceAll(rows);
      // 引入申请行后按「学习记忆」预填各货品上次订货的整套商业条款。
      await _prefillRememberedTerms();
      final dates =
          open
              .map((line) => _parseDate(line.needDate))
              .whereType<DateTime>()
              .toList()
            ..sort();
      _deliverDate = dates.isEmpty ? null : dates.first;
      // 并发认领（PURCHASE_DECOMPOSE）：仅 UX/防碰撞层；后端守卫是正确性底线。
      final requestIds = open.map((e) => e.sourceDocumentId).toSet();
      if (requestIds.isNotEmpty) {
        _decomposeClaim = TaskClaimSession(
          ref.read(taskClaimRepositoryProvider),
        );
        await _decomposeClaim!.claimAll('PURCHASE_DECOMPOSE', requestIds);
        if (mounted) setState(() {});
      }
    } on StateError catch (error) {
      if (mounted) context.appError(error.message);
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message);
    } catch (_) {
      if (mounted) context.appError('读取采购申请失败，请返回任务中心重新选择');
    }
  }

  /// 数量显示：整数值去掉小数尾巴，避免合并求和出现 100.00000000001。
  static String _formatQty(num value) =>
      value == value.roundToDouble() ? value.toInt().toString() : '$value';

  Future<void> _loadExisting() async {
    try {
      final d = await ref
          .read(purchaseRepositoryProvider(PurchaseDocType.order))
          .detail(widget.id!);
      final writable =
          d.status == kPurchaseStatusDraft &&
          d.canEdit &&
          await loadDocumentOwnerCanWrite(
            ref,
            DocumentDataScope.purchase,
            d.makerId,
          );
      if (!mounted) return;
      if (!writable) {
        context.appWarning(documentScopeReadOnlyMessage, force: true);
        context.replace(
          RoutePath.purchaseDocDetail(_cfg.type.pathSegment, widget.id!),
        );
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
      _deliverDate = _parseDate(d.deliverDate);
      _makerName = d.makerName;
      _createdAt = d.createdAt;
      final rows = <PurchaseGridRow>[];
      for (final it in d.items) {
        final row = PurchaseGridRow(sourceLocked: it.requestItemId != null)
          ..goods = it.goodsId == null
              ? null
              : GoodsOption(
                  id: it.goodsId!,
                  name: ref.read(masterNameServiceProvider).goods(it.goodsId),
                )
          ..upstreamItemId = it.requestItemId
          ..colorId = it.colorId
          ..unitId = it.unitId
          ..unitRate = it.unitRate
          // V463：多来源合并行回显（来源明细 ids + 单号逐条带回）。
          ..upstreamItemIds = [
            if (it.requestItemId != null) it.requestItemId!,
            ...it.sourceRequests
                .map((source) => source.requestItemId)
                .where((id) => id != it.requestItemId),
          ]
          ..sourceDocs = it.sourceRequests;
        row.qty.text = it.qty?.toString() ?? '';
        row.weight.text = it.weight?.toString() ?? '';
        row.price.text = it.price?.toString() ?? '';
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
      // 「申请来源」列回显：有逐行 sources 用之；全单同源旧单退回表头谱系。
      if (d.sourceRequestId != null) {
        for (final row in rows) {
          if (row.sourceDocs.isEmpty) {
            row
              ..sourceRequestId = d.sourceRequestId
              ..sourceRequestNo = d.sourceRequestNo;
          }
        }
      }
      _grid.replaceAll(rows);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      // 静默降级
    }
  }

  Future<void> _pickGoods(PurchaseGridRow row) async {
    if (row.sourceLocked) return;
    final g = await showUtenGoodsPicker(
      context,
      ref,
      scope: UtenGoodsPickerScope.material,
    );
    if (g == null) return;
    row
      ..goods = GoodsOption(id: g.id, code: g.code, name: g.name)
      ..colorId = g.colorId
      ..unitId = g.unitId
      ..unitRate = 1
      ..stockPlaceNotifier.value = g.stockPlace;
    // 换货品后按「学习记忆」预填该货品上次订货的整套条款（不覆盖已选值）。
    await _prefillRememberedTerms();
  }

  /// 行级条款「学习预填」（/last-terms）：按货品查最近一次订货的整套商业条款，
  /// 回填各行尚未填的字段（供应商只回填启用中的；条款字典外的死值跳过）。
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
          .read(purchaseRepositoryProvider(PurchaseDocType.order))
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

  /// 记忆未覆盖时回落默认：币种人民币、汇率 1、税率 0（结账方式无全局默认，
  /// 由供应商主档默认 [SettlementMethodReferenceResolver] 在选商后预填）。
  bool _applyTermDefaults(PurchaseGridRow r) {
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

  /// 结账方式字典（启用中）：id → 名称(代码)。
  Future<Map<String, String>> _settlementEntries() async {
    try {
      final methods = await ref.read(settlementMethodOptionsProvider.future);
      return {for (final m in methods) m.id: '${m.name}(${m.code})'};
    } catch (_) {
      return const {};
    }
  }

  /// 供应商确定后预填结账方式（V452 供应商主档默认）：只预填启用中的方式，
  /// 不覆盖已选值。按行生效（行级条款）。
  Future<void> _prefillSettlementForRows(
    Iterable<PurchaseGridRow> rows,
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
      // 供应商主档默认也是系统带入：黄标提醒核对。
      r.markTermsAutofilled('settlement', candidate);
    }
    setState(() {});
  }

  /// 落值范围：新建=多选选中行（点的行在选中集→整组；否则仅本行）；
  /// 编辑既有单=全部行（一单一套条款）。
  List<PurchaseGridRow> _writeTargets(PurchaseGridRow row) {
    if (!_isCreate) return _grid.rows;
    final selected = _grid.selectedRows;
    return selected.contains(row) ? selected : [row];
  }

  /// 多选行「统一设置条款」：打开批量面板一次写全套（供应商+结账方式+币种+汇率+
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
      context.appInfo('既有订货单保持一套商业条款，已同步全部明细行');
    }
  }

  /// 行级供应商选择：滑入面板选中后按多选范围落值（编辑态=全部行）。
  Future<void> _pickRowSupplier(PurchaseGridRow row) async {
    final picked = await showUtenSupplierPicker(context, ref);
    if (picked == null || !mounted) return;
    _applyRowSupplier(row, picked.id);
  }

  void _applyRowSupplier(PurchaseGridRow row, String? value) {
    final targets = _writeTargets(row);
    for (final r in targets) {
      r.supplierId = value;
      // 用户手选=已核对，清掉学习预填黄标。
      r.clearTermsAutofilled('supplier');
    }
    if (!_isCreate) {
      context.appInfo('既有订货单保持一单一商，已同步全部明细行');
    } else if (targets.length > 1) {
      context.appSuccess('已为 ${targets.length} 行设置同一供应商');
    }
    setState(() {});
    if (value != null && value.isNotEmpty) {
      unawaited(_prefillSettlementForRows(targets, value));
    }
  }

  /// 行级币种/结账方式选择落值（下拉菜单）：多选联动同供应商。
  /// [clearKey] 本次改的条款 key：对全部落值行清掉学习预填黄标（用户改=已核对）。
  void _applyRowTerm(
    PurchaseGridRow row,
    void Function(PurchaseGridRow r) write, {
    String? clearKey,
  }) {
    final targets = _writeTargets(row);
    for (final r in targets) {
      write(r);
      if (clearKey != null) r.clearTermsAutofilled(clearKey);
    }
    setState(() {});
  }

  /// 「从上游引入」：从计划申请拉明细（本次数量默认剩余量，可改大——超采允许）。
  /// V463：同「货品+颜色+单位」的引入项并入既有行（数量加总、来源聚合），
  /// 不再产生同货品重复行。
  Future<void> _importFromUpstream() async {
    final result = await showDocLinkPicker(
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
    void mergeIntoGrid(PurchaseGridRow row) {
      final key =
          '${row.goods?.id ?? ''}|${row.colorId ?? ''}|${row.unitId ?? ''}|${row.unitRate ?? 1}';
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
        return;
      }
      _grid.addRow(row);
    }

    for (final li in result.items) {
      if (li.goodsId.isEmpty) continue;
      final goods = GoodsOption(
        id: li.goodsId,
        name: ref.read(masterNameServiceProvider).goods(li.goodsId),
      );
      final row = PurchaseGridRow.fromLinked(li, goods);
      row
        ..sourceRequestId = result.sourceDocId
        ..sourceRequestNo = result.sourceDocNo
        ..sourceDocs = [
          if (li.upstreamItemId != null && li.upstreamItemId!.isNotEmpty)
            PurchaseSourceRequestRef(
              requestItemId: li.upstreamItemId!,
              requestId: result.sourceDocId,
              billNo: result.sourceDocNo,
            ),
        ];
      mergeIntoGrid(row);
    }
    _grid.removeWhere(
      (r) =>
          r.goods == null &&
          r.qty.text.trim().isEmpty &&
          r.price.text.trim().isEmpty,
    );
    await _prefillRememberedTerms();
  }

  /// 「申请来源」列点击：单来源直接跳申请详情；合并行多来源弹清单逐条跳转。
  Future<void> _openSourceRequest(PurchaseGridRow row) async {
    final docs = row.sourceDocs
        .where((doc) => doc.requestId?.isNotEmpty == true)
        .toList();
    if (docs.length == 1) {
      context.push(
        RoutePath.purchaseDocDetail(
          PurchaseDocType.request.pathSegment,
          docs.first.requestId!,
        ),
      );
      return;
    }
    if (docs.length > 1) {
      final selected = await showModalBottomSheet<String>(
        context: context,
        builder: (context) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.all(UtenSpacing.s16),
                child: Text(
                  '该行合并了 ${docs.length} 张申请的需求，选择要查看的申请：',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              for (final doc in docs)
                ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: Text(doc.billNo ?? doc.requestItemId),
                  subtitle: Text('申请明细 ${doc.requestItemId}'),
                  onTap: () => Navigator.of(context).pop(doc.requestId),
                ),
            ],
          ),
        ),
      );
      if (selected != null && mounted) {
        context.push(
          RoutePath.purchaseDocDetail(
            PurchaseDocType.request.pathSegment,
            selected,
          ),
        );
      }
      return;
    }
    final id = row.sourceRequestId;
    if (id == null || id.isEmpty) return;
    context.push(
      RoutePath.purchaseDocDetail(PurchaseDocType.request.pathSegment, id),
    );
  }

  /// 供应商显示名映射：启用中的供应商；被引用的禁用商补进并标「已禁用」。
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
  String _comboKey(PurchaseGridRow r) {
    final rate = double.tryParse(r.exchangeRate.text.trim()) ?? 0;
    final tax = double.tryParse(r.taxRate.text.trim()) ?? 0;
    return '${r.supplierId}|${r.settlementMethodId}|${r.currencyId}|'
        '${rate.toStringAsFixed(6)}|${tax.toStringAsFixed(4)}';
  }

  Future<void> _save() async {
    final rows = _grid.rows.where((r) => r.goods != null).toList();
    if (rows.isEmpty) {
      context.appError('请至少添加一条明细');
      return;
    }
    // 行级条款完整性：供应商/结账方式/币种必填，汇率>0，税率 0-100。
    String rateTextOf(PurchaseGridRow r) => r.exchangeRate.text.trim();
    String taxTextOf(PurchaseGridRow r) => r.taxRate.text.trim();
    for (final r in rows) {
      if (r.supplierId == null) {
        context.appError('${r.goods!.name} 未选择供应商；可勾选多行统一设置');
        return;
      }
      if (r.settlementMethodId == null) {
        context.appError('${r.goods!.name} 未选择结账方式；可勾选多行统一设置');
        return;
      }
      if (r.currencyId == null) {
        context.appError('${r.goods!.name} 未选择币种；可勾选多行统一设置');
        return;
      }
      final rate = double.tryParse(rateTextOf(r));
      if (rate == null || rate <= 0) {
        context.appError('${r.goods!.name} 的汇率必须大于 0');
        return;
      }
      final tax = double.tryParse(taxTextOf(r));
      if (tax == null || tax < 0 || tax > 100) {
        context.appError('${r.goods!.name} 的税率必须填写 0 至 100 之间的百分比');
        return;
      }
    }
    // 编辑既有单：一单一套条款（行条款必须全一致）。
    if (!_isCreate) {
      final combos = rows.map(_comboKey).toSet();
      if (combos.length != 1) {
        context.appError('既有采购订货单必须保持一套商业条款（供应商/结账方式/币种/汇率/税率）');
        return;
      }
    }
    final settlementEntries = await _settlementEntries();
    if (!mounted) return;
    for (final r in rows) {
      if (!settlementEntries.containsKey(r.settlementMethodId)) {
        context.appError('${r.goods!.name} 的结账方式已停用，请重新选择');
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
      // 2026-09 起订货允许超过申请剩余量（超采备货）：不再校验 qty ≤ maxQty。
      final price = double.tryParse(r.price.text);
      if (price == null || price < 0) {
        context.appError('请填写${r.goods!.name}的有效采购单价');
        return;
      }
      final weightText = r.weight.text.trim();
      final weight = weightText.isEmpty ? null : double.tryParse(weightText);
      if (weightText.isNotEmpty && (weight == null || weight <= 0)) {
        context.appError('${r.goods!.name} 的实际重量必须大于 0');
        return;
      }
      final rate = double.tryParse(rateTextOf(r))!;
      final tax = double.tryParse(taxTextOf(r))!;
      final remarkText = r.remark.text.trim();
      itemsBody.add({
        'goodsId': r.goods!.id,
        'qty': qty,
        'price': price,
        'amountOriginal': qty * price,
        'amountLocal': qty * price * rate,
        if (r.upstreamItemId != null) 'requestItemId': r.upstreamItemId,
        // V463 同货品合并行：多来源申请明细逐条提交，服务端按剩余量 FIFO 拆分。
        if (r.upstreamItemIds.length > 1) 'requestItemIds': r.upstreamItemIds,
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
      if (_deliverDate != null) 'deliverDate': _fmt(_deliverDate!),
      'items': itemsBody,
    };
    setState(() => _saving = true);
    try {
      final repo = ref.read(purchaseRepositoryProvider(PurchaseDocType.order));
      if (_isCreate) {
        final created = await repo.createBatch(body);
        if (!mounted) return;
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
        // 业务动作完成 → 对应通知自动已读（指向来源申请或本次新建订货单）。
        unawaited(
          markNoticesReadByRoute(
            ProviderScope.containerOf(context, listen: false),
            [
              for (final row in _grid.rows)
                if (row.sourceRequestId != null)
                  RoutePath.purchaseDocDetail(
                    PurchaseDocType.request.pathSegment,
                    row.sourceRequestId!,
                  ),
              for (final createdDoc in created)
                RoutePath.purchaseDocDetail(
                  _cfg.type.pathSegment,
                  createdDoc.id,
                ),
            ],
          ),
        );
        if (financeError != null) {
          context.appWarning(
            '已生成 ${created.length} 张订货单，部分未提交财务审核组：$financeError。'
            '请进入对应订货详情重新提交。',
          );
        } else if (_canSubmitFinance) {
          context.appSuccess(
            comboCount > 1
                ? '已按「供应商+条款组合」拆分为 $comboCount 组共 ${created.length} 张订货单并提交财务审核组'
                : '订货单已保存并提交财务审核组；下一步由财务在「订货审批任务中心」审核',
          );
        } else {
          context.appSuccess(
            comboCount > 1
                ? '已按「供应商+条款组合」拆分并保存 ${created.length} 张订货单草稿；下一步请由有权限的人员提交财务审核'
                : '订货单草稿已保存；下一步请由有权限的人员提交财务审核',
          );
        }
        if (created.length == 1) {
          context.replace(
            RoutePath.purchaseDocDetail(
              _cfg.type.pathSegment,
              created.first.id,
            ),
          );
        } else {
          context.go('/purchase/${_cfg.type.pathSegment}');
        }
        return;
      }
      // 编辑既有单：单头条款 = 全行一致的条款（行值即单头值）。
      final first = rows.first;
      body['supplierId'] = first.supplierId;
      body['settlementMethodId'] = first.settlementMethodId;
      body['currencyId'] = first.currencyId;
      body['exchangeRate'] = double.tryParse(rateTextOf(first));
      body['taxRate'] = double.tryParse(taxTextOf(first));
      var d = await repo.update(widget.id!, body);
      if (!mounted) return;
      if (_canSubmitFinance) {
        try {
          d = await repo.submitFinance(d.id);
        } on ApiException catch (e) {
          if (!mounted) return;
          context.appWarning('订货单已保存，但未能提交财务审核组：${e.message}。请在订货详情重新提交。');
          bumpListRefresh(ref, _cfg.refreshKey);
          context.replace(
            RoutePath.purchaseDocDetail(_cfg.type.pathSegment, d.id),
          );
          return;
        }
      }
      if (!mounted) return;
      context.appSuccess(
        _canSubmitFinance
            ? '订货单已保存并提交财务审核组；下一步由财务在「订货审批任务中心」审核'
            : '订货单草稿已保存；下一步请由有权限的人员提交财务审核',
      );
      bumpListRefresh(ref, _cfg.refreshKey);
      unawaited(
        markNoticesReadByRoute(
          ProviderScope.containerOf(context, listen: false),
          [RoutePath.purchaseDocDetail(_cfg.type.pathSegment, d.id)],
        ),
      );
      context.replace(RoutePath.purchaseDocDetail(_cfg.type.pathSegment, d.id));
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('保存失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    return Scaffold(
      appBar: UtenAppBar(
        title: _isCreate ? '新建${_cfg.label}' : '编辑${_cfg.label}',
        leading: UtenBackButton(
          onPressed: () =>
              popOrBackTo(context, defaultPath: RouteName.purchase),
        ),
        actions: [
          UtenButton(
            type: UtenButtonType.tonal,
            icon: Icons.history_rounded,
            onPressed: () => context.push('/purchase/${_cfg.type.pathSegment}'),
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
                      _termsBanner(theme),
                      const SizedBox(height: UtenSpacing.s12),
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
                                    defaultDeptCode: kDeptCodePurchase,
                                    onChanged: (id) =>
                                        setState(() => _purchaserId = id),
                                  ),
                                  UtenDateField(
                                    label: '交货日期',
                                    value: _deliverDate,
                                    onChanged: (d) =>
                                        setState(() => _deliverDate = d),
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
                      if (_decomposeClaim?.blocked ?? false)
                        Padding(
                          padding: const EdgeInsets.only(
                            top: UtenSpacing.s8,
                            bottom: UtenSpacing.s4,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.lock_outline,
                                size: 18,
                                color: theme.colorScheme.error,
                              ),
                              const SizedBox(width: UtenSpacing.s8),
                              Expanded(
                                child: Text(
                                  '${_decomposeClaim?.blockedByName ?? '同事'}'
                                  '正在分解此采购申请，保存已禁用，请稍后再试',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.error,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: UtenSpacing.s12),
                      Row(
                        children: [
                          Text(
                            '明细 (${_grid.length})',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const Spacer(),
                          UtenImportButton(
                            label: '从上游引入',
                            onPressed: _importFromUpstream,
                          ),
                        ],
                      ),
                      // 列显隐/排序持久化（本页固定订货模式，单桶即可；账号级）。
                      Builder(
                        builder: (_) {
                          final columnPrefs = ref.watch(
                            purchaseOrderGridColumnPrefsProvider,
                          )['order'];
                          return UtenEditableGrid<PurchaseGridRow>(
                            controller: _grid,
                            showColumnSettings: true,
                            initialColumnOrder: columnPrefs?.order,
                            initialHiddenColumnKeys: columnPrefs?.hidden,
                            onColumnSettingsChanged: (order, hidden) => ref
                                .read(
                                  purchaseOrderGridColumnPrefsProvider.notifier,
                                )
                                .updateFor('order', order, hidden),
                            batchActionsBuilder: (ctx, ctl) => [
                              TextButton.icon(
                                onPressed: ctl.selectedCount > 0
                                    ? _batchSetTerms
                                    : null,
                                icon: const Icon(Icons.tune_rounded, size: 16),
                                label: Text('统一设置条款 (${ctl.selectedCount})'),
                                style: TextButton.styleFrom(
                                  foregroundColor: Theme.of(
                                    ctx,
                                  ).colorScheme.primary,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 2,
                                  ),
                                  minimumSize: const Size(0, 36),
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  textStyle: Theme.of(ctx).textTheme.titleSmall,
                                ),
                              ),
                            ],
                            columns: purchaseGridColumns(
                              _pickGoods,
                              unitEntries: names.unitEntries,
                              supplierEntries: _supplierDropdownEntries(),
                              supplierRequired: true,
                              onPickSupplier: _pickRowSupplier,
                              showSource: true,
                              onOpenSource: _openSourceRequest,
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
                            createBlankRow: () => PurchaseGridRow()
                              ..currencyId = _defaultCurrencyId
                              ..exchangeRate.text = '1'
                              ..taxRate.text = '0',
                            cloneRow: (r) => r.clone(),
                          );
                        },
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
          child: Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: UtenSpacing.s12,
            runSpacing: UtenSpacing.s8,
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
              UtenButton(
                type: UtenButtonType.secondary,
                onPressed: () => context.pop(),
                child: const Text('取消'),
              ),
              UtenButton(
                isLoading: _saving,
                icon: _canSubmitFinance
                    ? Icons.send_outlined
                    : Icons.save_outlined,
                onPressed: (_saving || (_decomposeClaim?.blocked ?? false))
                    ? null
                    : _save,
                child: Text(_canSubmitFinance ? '保存并提交财务审核' : '保存订货单草稿'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 行级条款说明横幅：条款在行内、批量设置、学习模式、允许超采。
  Widget _termsBanner(ThemeData theme) {
    return Semantics(
      container: true,
      label:
          '供应商与结账方式、币种、汇率、税率都在明细行填写；'
          '勾选多行可统一设置；系统会记住每个货品上次的条款并在下次自动带出；'
          '数量允许超过申请剩余量（超采备货）。',
      child: Card(
        color: theme.colorScheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.tune_rounded,
                color: theme.colorScheme.onSecondaryContainer,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '供应商与商业条款都在明细行填写',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onSecondaryContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      '结账方式、币种、汇率、税率逐行选择；勾选多行后可「统一设置条款」一次写全套。'
                      '同一货品会记住上次订货的条款，下次自动带出。'
                      '保存时按「供应商+条款组合」自动拆单，每组条款归集到各张订货单。'
                      '从任务中心多选带入时，同货品+颜色+单位的需求自动合并成一行、数量加总'
                      '（来源申请逐条保留可点开）。数量允许超过申请剩余量（超采备货）。',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSecondaryContainer,
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
  /// 结账方式字典映射：id → 名称(代码)。
  Map<String, String> asEntries() => {
    for (final m in this) m.id: '${m.name}(${m.code})',
  };
}
