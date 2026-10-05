// 品质「批量审批」汇总页（2026-09-05）——待检处置列表多选后进入。
//
// 用户口径：多选的内容都汇总到一个页面，可多选/单选，填合格/不合格数量后
// 「提交报告」一次办结：
//   - IQC 收货单区：按单分组，逐行勾选 + 行内编辑合格数量/不合格数量
//     （默认合格 = 剩余待检、不合格 = 0），提交走 decide-batch(每单一事务，
//     按报告顺序逐单发送，失败不连坐、重试只补未确认的单；2026-09-21 起不再 4 通道
//     并行，见 QualityBatchSubmission 的实测说明)；
//   - FQC 自制产成品区：V547 按品质检查单分组（组头三态复选，镜像 IQC 收货单组），
//     无检查单的历史任务单列；勾选任务 = 全部合格（既有 pass-all 语义）；
//   - 右下角 UtenFloatingActionGroup：UtenSelectionSummaryPill（已选计数唯一出处，✕ 一键清空）
//     + 说明文案 + 提交报告；总结确认弹窗（仿计划部下达采购）后执行。
import 'package:flutter/material.dart';
import '../presentation/procurement_inspection_guidance.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_store.dart';
import '../../../shared/drafts/form_draft_values.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../components/data_display/uten_selection_summary_pill.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_grid_page_scrollbar.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../warehouse/repositories/procurement_inspection_repository.dart';
import '../models/production_fqc_inspection.dart';
import '../widgets/production_fqc_dialogs.dart' show fqcQtyText;
import 'production_fqc_handling_page.dart' show fqcStorageText;
import '../repositories/production_fqc_repository.dart';
import '../services/quality_batch_submission.dart';
import '../widgets/inspection_report_confirm_dialog.dart';
import '../../../shared/badges/badge_registry.dart';

/// 列表页多选结果（extra 传入）：IQC 收货单 + FQC 检查单 + 无检查单 FQC 任务。
class QualityBatchApprovalSelection {
  const QualityBatchApprovalSelection({
    this.receipts = const [],
    this.inspections = const [],
    this.sheets = const [],
  });

  final List<PendingInspectionReceipt> receipts;
  final List<ProductionFqcInspection> inspections;
  final List<ProductionFqcInspectionSheet> sheets;
}

/// 一张 FQC 品质检查单的分组（V547）：组头三态复选，行 = 仍待检的 inspection。
class _FqcSheetGroup {
  _FqcSheetGroup(this.sheet, this.inspections, this.loadError);

  final ProductionFqcInspectionSheet sheet;

  /// ADR-148: 一批实物一行(批内各份合计); 行 id 是批号, 勾选并提交时带上批内各份的检查任务。
  final List<ProductionFqcInspection> inspections;
  final String? loadError;

  String get label => '品质检查单 ${sheet.sheetNo}';
}

/// 一行可编辑的 IQC 检验明细（合格默认=剩余待检，不合格默认=0）。
class _EditableIqcRow {
  _EditableIqcRow(this.item)
    : pass = TextEditingController(text: _fmt(item.remainingBaseQty ?? 0)),
      fail = TextEditingController(text: '0');

  final ProcurementInspectionItem item;
  final TextEditingController pass;
  final TextEditingController fail;

  /// Before submission this is a draft. The accepted report freezes this key,
  /// quantities and reason together, so retries never pair it with a new body.
  String idempotencyKey = 'iqc-decide-${const Uuid().v4()}';
  bool selected = true;
  bool completed = false;

  double get _pass => double.tryParse(pass.text.trim()) ?? 0;
  double get _fail => double.tryParse(fail.text.trim()) ?? 0;

  /// null = 校验通过；否则为错误文案。
  String? validate() {
    final remaining = item.remainingBaseQty ?? 0;
    final passQty = double.tryParse(pass.text.trim());
    final failQty = double.tryParse(fail.text.trim());
    if (passQty == null ||
        failQty == null ||
        !passQty.isFinite ||
        !failQty.isFinite) {
      return '请输入有效的合格与不合格数量';
    }
    if (_pass < 0 || _fail < 0) return '数量不能为负';
    if (_pass + _fail <= 0) return '合格与不合格不能同时为 0';
    if (_pass + _fail > remaining + 1e-9) {
      return '合计不能超过剩余待检 ${_fmt(remaining)}';
    }
    return null;
  }

  void dispose() {
    pass.dispose();
    fail.dispose();
  }
}

/// 一张 IQC 收货单的可编辑分组。
class _IqcReceiptGroup {
  _IqcReceiptGroup(this.receipt, this.rows, this.loadError);

  final PendingInspectionReceipt receipt;
  final List<_EditableIqcRow> rows;
  final String? loadError;

  String get label =>
      '${receipt.isSubcontract ? '委外进仓单' : '采购收货单'} ${receipt.billNo ?? receipt.receiptId}';
}

/// 合一审批表的一行：IQC 收货明细或 FQC 检查任务，类型/单号成列区分。
class _ApprovalRow {
  _ApprovalRow.iqc(this.receipt, this.iqc) : fqc = null, sheetNo = null;
  _ApprovalRow.fqc(this.fqc, {this.sheetNo}) : receipt = null, iqc = null;

  final PendingInspectionReceipt? receipt;
  final _EditableIqcRow? iqc;
  final ProductionFqcInspection? fqc;
  final String? sheetNo;

  bool get isFqc => fqc != null;

  String get kindLabel => isFqc
      ? (sheetNo != null ? '检查单' : '报工')
      : (receipt!.isSubcontract ? '委外进仓' : '收货单');

  String get docNo => isFqc
      ? (sheetNo ?? fqc!.reportNo ?? fqc!.id)
      : (receipt!.billNo ?? receipt!.receiptId);

  String? get goodsName => isFqc ? fqc!.goodsName : iqc!.item.goodsName;
  String? get goodsCode => isFqc ? fqc!.goodsCode : iqc!.item.goodsCode;
  String? get colorName => isFqc ? fqc!.colorName : iqc!.item.colorName;

  /// 本行是一批多份的实物批(检查单里的批行, 或无检查单的历史任务所在的多份批)。
  bool get wholeLot =>
      isFqc && ((fqc!.lot?.members.length ?? fqc!.lotSliceCount) > 1);

  /// 批内拆分说明(服务端算好的「需求 1000 · 实际超产 100」)。
  String? get splitText => fqc?.lot?.splitText;

  /// 勾一行就是整行判合格。
  bool get preStocked =>
      isFqc ? fqc!.preStocked != null : iqc!.item.preStocked != null;
  String get preStockedLabel => isFqc
      ? fqcStorageText(fqc!)
      : (iqc!.item.preStocked == null
            ? '待检区'
            : '已入库 · ${iqc!.item.preStocked!.label}');

  /// 表内唯一行标识（IQC 前缀避免与 FQC 的 UUID 撞车）。
  String get selectId => isFqc ? 'fqc:${fqc!.id}' : 'iqc:${iqc!.item.id}';

  /// 已确认提交的 IQC 行不可再选；FQC 行恒可选。
  bool get selectable => isFqc || !iqc!.completed;
}

class QualityBatchApprovalPage extends ConsumerStatefulWidget {
  const QualityBatchApprovalPage({
    super.key,
    required this.selection,
    this.draftId,
  });

  final QualityBatchApprovalSelection selection;
  final String? draftId;

  @override
  ConsumerState<QualityBatchApprovalPage> createState() =>
      _QualityBatchApprovalPageState();
}

class _QualityBatchApprovalPageState
    extends ConsumerState<QualityBatchApprovalPage>
    with FormDraftMixin<QualityBatchApprovalPage> {
  late QualityBatchApprovalSelection _selection;
  String? _draftLoadError;
  String _draftReason = '';
  @override
  bool get formDraftBusy => _submitting || _confirming;
  @override
  bool get formDraftCanReplaySubmission => _submission != null;
  @override
  FormDraftSpec get formDraftSpec =>
      (_selection.receipts.isNotEmpty
              ? FormDraftCatalog.iqcBatchReport
              : FormDraftCatalog.fqcBatchReport)
          .spec();
  @override
  Iterable<Listenable> get formDraftListenables => [
    for (final row in _flatRows ?? <_EditableIqcRow>[]) ...[row.pass, row.fail],
  ];
  @override
  Map<String, dynamic> captureFormDraft() => {
    'selection': {
      'receipts': [
        for (final receipt in _selection.receipts)
          {
            'receiptType': receipt.receiptType,
            'receiptId': receipt.receiptId,
            'billNo': receipt.billNo,
            'billDate': receipt.billDate,
            'supplierId': receipt.supplierId,
            'supplierName': receipt.supplierName,
            'warehouseId': receipt.warehouseId,
          },
      ],
      'sheetIds': _selection.sheets.map((item) => item.id).toList(),
      'inspectionIds': _selection.inspections.map((item) => item.id).toList(),
    },
    'rows': [
      for (final row in _flatRows ?? <_EditableIqcRow>[])
        {
          'id': row.item.id,
          'pass': row.pass.text,
          'fail': row.fail.text,
          'key': row.idempotencyKey,
          'selected': row.selected,
          'completed': row.completed,
        },
    ],
    'selectedFqcIds': _selectedFqcIds.toList(),
    'reason': _draftReason,
    'submission': _submission?.exportDraft(),
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    final rows = {for (final row in draftMaps(data['rows'])) row['id']: row};
    for (final row in _flatRows ?? <_EditableIqcRow>[]) {
      final saved = rows[row.item.id];
      if (saved == null) {
        row.selected = false;
        continue;
      }
      row.pass.text = saved['pass'] as String? ?? '';
      row.fail.text = saved['fail'] as String? ?? '';
      row.idempotencyKey = saved['key'] as String;
      row.selected = saved['selected'] == true;
      row.completed = saved['completed'] == true;
    }
    _selectedFqcIds
      ..clear()
      ..addAll(draftStrings(data['selectedFqcIds']));
    _draftReason = data['reason'] as String? ?? '';
    _submission = data['submission'] == null
        ? null
        : QualityBatchSubmission.fromDraft(draftMap(data['submission']));
  }

  Future<void> _initializeAndLoad() async {
    try {
      if (widget.draftId != null) {
        await ref.read(formDraftsProvider.notifier).ready;
        if (!mounted) return;
        final draft = ref
            .read(formDraftsProvider)
            .where((item) => item.id == widget.draftId)
            .firstOrNull;
        if (draft == null) {
          throw StateError('草稿不存在或无恢复权限');
        }
        final selected = draftMap(draft.data['selection']);
        final fqc = ref.read(productionFqcRepositoryProvider);
        final inspections = <ProductionFqcInspection>[];
        for (final id in draftStrings(selected['inspectionIds'])) {
          inspections.add(await fqc.detail(id));
        }
        if (!mounted) return;
        _selection = QualityBatchApprovalSelection(
          receipts: draftMaps(
            selected['receipts'],
          ).map(PendingInspectionReceipt.fromJson).toList(),
          sheets: [
            for (final id in draftStrings(selected['sheetIds']))
              ProductionFqcInspectionSheet.fromJson({'id': id}),
          ],
          inspections: inspections,
        );
      }
      await _load();
    } catch (error) {
      if (mounted) {
        setState(() {
          _draftLoadError = '$error';
          _loading = false;
        });
      }
    }
  }

  List<_IqcReceiptGroup>? _groups;
  List<_FqcSheetGroup>? _sheetGroups;
  List<_EditableIqcRow>? _flatRows;
  bool _loading = true;
  bool _submitting = false;
  bool _confirming = false;
  bool _leaving = false;
  QualityBatchSubmission? _submission;

  // 2026-09-22 全站表格滚动口径：各分组明细表表头吸顶（stickyHeaderPinned）；
  // 一页动态多表（IQC 按单 + FQC 按检查单），任一张置顶 = 处于「表内滚动」段
  // → 页面滚动条显示（UtenGridPageScrollbar 门控）。
  final ScrollController _pageScroll = ScrollController();
  final Map<String, ValueNotifier<bool>> _tablePins = {};
  final ValueNotifier<bool> _anyPinned = ValueNotifier<bool>(false);
  int _pinnedCount = 0;

  ValueNotifier<bool> _pinOf(String id) => _tablePins.putIfAbsent(id, () {
    final pin = ValueNotifier<bool>(false);
    pin.addListener(() {
      _pinnedCount += pin.value ? 1 : -1;
      if (_pinnedCount < 0) _pinnedCount = 0;
      final any = _pinnedCount > 0;
      if (_anyPinned.value != any) _anyPinned.value = any;
    });
    return pin;
  });

  @override
  void initState() {
    super.initState();
    _selection = widget.selection;
    WidgetsBinding.instance.addPostFrameCallback((_) => _initializeAndLoad());
  }

  @override
  void dispose() {
    _leaving = true;
    _pageScroll.dispose();
    for (final pin in _tablePins.values) {
      pin.dispose();
    }
    _anyPinned.dispose();
    _flatRows?.forEach((row) => row.dispose());
    super.dispose();
  }

  Future<void> _load({bool retryFailuresOnly = false}) async {
    if (_submission != null) return;
    setState(() {
      _loading = true;
    });
    final iqc = ref.read(procurementInspectionRepositoryProvider);
    final fqc = ref.read(productionFqcRepositoryProvider);
    final oldIqc = {
      for (final group in _groups ?? const <_IqcReceiptGroup>[])
        (group.receipt.receiptType, group.receipt.receiptId): group,
    };
    final oldFqc = {
      for (final group in _sheetGroups ?? const <_FqcSheetGroup>[])
        group.sheet.id: group,
    };
    final tasks = <Future<Object> Function()>[
      for (final receipt in _selection.receipts)
        () async {
          final old = oldIqc[(receipt.receiptType, receipt.receiptId)];
          if (retryFailuresOnly && old != null && old.loadError == null) {
            return old;
          }
          try {
            final rows = await iqc.items(
              receipt.receiptType,
              receipt.receiptId,
            );
            return _IqcReceiptGroup(receipt, [
              for (final item in rows)
                if ((item.remainingBaseQty ?? 0) > 0 &&
                    item.status != 'RESOLVED' &&
                    item.status != 'REVERSED')
                  _EditableIqcRow(item),
            ], null);
          } on ApiException catch (error) {
            return _IqcReceiptGroup(receipt, const [], error.message);
          } catch (_) {
            return _IqcReceiptGroup(receipt, const [], '待检明细加载失败');
          }
        },
      for (final sheet in _selection.sheets)
        () async {
          final old = oldFqc[sheet.id];
          if (retryFailuresOnly && old != null && old.loadError == null) {
            return old;
          }
          try {
            final detail = await fqc.sheetDetail(sheet.id);
            // ADR-148: 品质按实物批判定, 一批一行(与检查单办理页同一口径)。
            return _FqcSheetGroup(
              detail.sheet,
              detail.activeLotInspections,
              null,
            );
          } on ApiException catch (error) {
            return _FqcSheetGroup(sheet, const [], error.message);
          } catch (_) {
            return _FqcSheetGroup(sheet, const [], '检查单加载失败');
          }
        },
    ];
    // One shared bound for IQC and FQC. Preserve selection order while avoiding
    // both unbounded receipt requests and serial FQC round trips.
    final results = List<Object?>.filled(tasks.length, null);
    var next = 0;
    Future<void> worker() async {
      while (mounted && !_leaving && next < tasks.length) {
        final index = next++;
        results[index] = await tasks[index]();
      }
    }

    await Future.wait([
      for (var i = 0; i < 4 && i < tasks.length; i++) worker(),
    ]);
    final groups = results.whereType<_IqcReceiptGroup>().toList();
    final sheetGroups = results.whereType<_FqcSheetGroup>().toList();
    final flat = [for (final group in groups) ...group.rows];
    if (!mounted || _leaving) {
      // Retained rows were already disposed by State.dispose; dispose only
      // controllers created by a late successful response.
      for (final row in flat) {
        if (!(_flatRows?.contains(row) ?? false)) row.dispose();
      }
      return;
    }
    final retained = flat.toSet();
    for (final row in _flatRows ?? const <_EditableIqcRow>[]) {
      if (!retained.contains(row)) row.dispose();
    }
    setState(() {
      _groups = groups;
      _sheetGroups = sheetGroups;
      _flatRows = flat;
      for (final group in sheetGroups) {
        if (!retryFailuresOnly || !identical(oldFqc[group.sheet.id], group)) {
          _selectedFqcIds.addAll(group.inspections.map((item) => item.id));
        }
      }
      _loading = false;
    });
    await initializeFormDraft();
  }

  List<_EditableIqcRow> get _selectedIqcRows => (_flatRows ?? const [])
      .where((row) => row.selected && !row.completed)
      .toList();

  /// 全部 FQC 行：检查单内仍待检的实物批 + 无检查单的历史任务(已在某个批里的不重复列)。
  List<ProductionFqcInspection> get _allFqc {
    final byId = <String, ProductionFqcInspection>{};
    for (final group in _sheetGroups ?? const <_FqcSheetGroup>[]) {
      for (final inspection in group.inspections) {
        byId.putIfAbsent(inspection.id, () => inspection);
      }
    }
    final grouped = _groupedFqcIds;
    for (final inspection in _selection.inspections) {
      if (grouped.contains(inspection.id)) continue;
      byId.putIfAbsent(inspection.id, () => inspection);
    }
    return byId.values.toList(growable: false);
  }

  /// 检查单批行覆盖的全部 id: 批号 + 批内各份的检查任务。
  Set<String> get _groupedFqcIds => {
    for (final group in _sheetGroups ?? const <_FqcSheetGroup>[])
      for (final inspection in group.inspections) ..._fqcMemberIds(inspection),
  };

  /// 一行要提交的检查任务: 批行 = 批内仍待判的各份(服务端仍按整批展开); 单份 = 它自己。
  static List<String> _fqcSubmitIds(ProductionFqcInspection row) {
    final lot = row.lot;
    if (lot == null) return [row.id];
    final active = [
      for (final member in lot.members)
        if (member.status == 'PENDING' || member.status == 'PARTIAL')
          member.inspectionId,
    ];
    return active.isEmpty
        ? [for (final member in lot.members) member.inspectionId]
        : active;
  }

  static Set<String> _fqcMemberIds(ProductionFqcInspection row) => {
    row.id,
    for (final member
        in row.lot?.members ?? const <ProductionFqcInspectionLotMember>[])
      member.inspectionId,
  };

  /// 列表里已勾选的任务进入本页默认保持选中（可再取消）；IQC 行同理
  ///（_EditableIqcRow 构造即 selected = true）。
  late final Set<String> _selectedFqcIds = {
    for (final inspection in _selection.inspections) inspection.id,
  };

  int get _selectedCount =>
      _selectedIqcRows.length +
      _selectedFqcIds.intersection(_allFqc.map((e) => e.id).toSet()).length;

  /// 胶囊 ✕：一键取消全部勾选（IQC 行 + FQC 任务），提交按钮随之进入空选提示态。
  void _clearSelection() {
    if (_submitting || _submission != null) return;
    setState(() {
      for (final row in _flatRows ?? const <_EditableIqcRow>[]) {
        row.selected = false;
      }
      _selectedFqcIds.clear();
    });
  }

  Future<void> _submitReport() async {
    if (_submitting || _confirming) return;
    if (_submission != null) {
      await _sendSubmission();
      return;
    }
    final iqcRows = _selectedIqcRows;
    final fqcSelected = [
      for (final inspection in _allFqc)
        if (_selectedFqcIds.contains(inspection.id)) inspection,
    ];
    if (iqcRows.isEmpty && fqcSelected.isEmpty) {
      context.appWarning('请先选择要提交的明细');
      return;
    }
    final fqcIds = [for (final row in fqcSelected) ..._fqcSubmitIds(row)];
    if (fqcIds.toSet().length > 100) {
      context.appWarning('自制产成品每批最多100项，请减少本次勾选');
      return;
    }
    final selected = iqcRows.toSet();
    for (final group in _groups ?? const <_IqcReceiptGroup>[]) {
      if (group.rows.where(selected.contains).length > 100) {
        context.appWarning(
          '${group.receipt.billNo ?? group.receipt.receiptId}每单报告最多100行，请减少本次勾选',
        );
        return;
      }
    }
    for (final row in iqcRows) {
      final problem = row.validate();
      if (problem != null) {
        context.appWarning(
          '${row.item.goodsName ?? row.item.goodsCode ?? '明细'}：$problem',
        );
        return;
      }
    }
    final hasFail = iqcRows.any(
      (row) => (double.tryParse(row.fail.text.trim()) ?? 0) > 0,
    );
    setState(() => _confirming = true);
    String? reason;
    try {
      reason = await showInspectionReportConfirmDialog(
        context,
        initialReason: _draftReason,
        onReasonChanged: (value) {
          _draftReason = value;
          markFormDraftChanged();
        },
        lineCount: iqcRows.length,
        passTotalText: iqcRows.isEmpty
            ? '0'
            : inspectionQuantityTotalText(
                context,
                iqcRows.map(
                  (row) =>
                      (row.item, double.tryParse(row.pass.text.trim()) ?? 0),
                ),
              ),
        failTotalText: iqcRows.isEmpty
            ? '0'
            : inspectionQuantityTotalText(
                context,
                iqcRows.map(
                  (row) =>
                      (row.item, double.tryParse(row.fail.text.trim()) ?? 0),
                ),
              ),
        fqcTaskCount: fqcSelected.length,
        requireReason: hasFail,
        lines: [
          for (final row in iqcRows)
            InspectionReportConfirmLine(
              label: [
                row.item.goodsName,
                row.item.goodsCode,
                row.item.colorName,
              ].where((text) => text?.isNotEmpty == true).join(' · '),
              passText: _fmt(double.tryParse(row.pass.text.trim()) ?? 0),
              failText: _fmt(double.tryParse(row.fail.text.trim()) ?? 0),
              dim: inspectionQuantityUnit(context, row.item),
            ),
          for (final inspection in fqcSelected)
            InspectionReportConfirmLine(
              label: [
                '自制产成品 ${inspection.reportNo ?? inspection.id}',
                if (inspection.lot?.splitText?.isNotEmpty == true)
                  inspection.lot!.splitText!,
              ].join(' · '),
              passText: '',
              failText: '0',
            ),
        ],
      );
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
    if (reason == null || !mounted) return;
    _submission = QualityBatchSubmission(
      reason: reason.isEmpty ? null : reason,
      fqcInspectionIds: fqcIds,
      fqcLotCount: fqcSelected.length,
      receipts: [
        for (final group in _groups ?? const <_IqcReceiptGroup>[])
          if (group.rows.any(selected.contains))
            QualityReceiptSubmission(
              receiptType: group.receipt.receiptType,
              receiptId: group.receipt.receiptId,
              label: group.receipt.billNo ?? group.receipt.receiptId,
              items: [
                for (final row in group.rows.where(selected.contains))
                  ProcurementInspectionDecideItem(
                    inspectionItemId: row.item.id,
                    expectedRemainingBaseQty: row.item.remainingBaseQty ?? 0,
                    passBaseQty: row._pass,
                    failBaseQty: row._fail,
                    idempotencyKey: row.idempotencyKey,
                  ),
              ],
            ),
      ],
    );
    FocusScope.of(context).unfocus();
    await _sendSubmission();
  }

  /// 提交期间忙碌浮层的进度文案：逐单确认，已确认的单不重发。
  String _submitOverlayDescription() {
    final submission = _submission;
    if (submission == null || submission.receipts.isEmpty) {
      return submission != null && submission.fqcInspectionIds.isNotEmpty
          ? '自制产成品整批提交中，响应丢失重试不会重复判定。'
          : '逐单提交中，已确认部分不会重复发送。';
    }
    final buffer = StringBuffer(
      '已确认 ${submission.completedReceiptCount}/${submission.receipts.length} 单'
      '(按报告顺序逐单提交，每单一事务)',
    );
    if (submission.fqcInspectionIds.isNotEmpty) {
      buffer.write('，另含自制产成品 ${submission.fqcInspectionIds.length} 项');
    }
    buffer.write('；已确认部分不会重复发送。');
    return buffer.toString();
  }

  Future<void> _sendSubmission() async {
    final submission = _submission!;
    var countsInvalidated = false;
    void invalidateCounts() {
      if (!mounted || countsInvalidated) return;
      refreshBadges(ref);
      // 仓库侧品质结果的红黄两个数字都从 type-counts 这一支派生, 失效只能打在
      // 源头上: 对派生 provider 调 invalidate 不会重新发请求, 徽章要等 60s 才动。
      refreshBadges(ref);
      countsInvalidated = true;
    }

    setState(() => _submitting = true);
    try {
      await runFormDraftSubmission(
        () => submission.send(
          iqc: ref.read(procurementInspectionRepositoryProvider),
          fqc: ref.read(productionFqcRepositoryProvider),
          onProgress: () {
            if (!mounted) return;
            final completed = submission.acknowledgedIqcIds.toSet();
            setState(() {
              for (final row in _flatRows ?? const <_EditableIqcRow>[]) {
                if (completed.contains(row.item.id)) {
                  row.completed = true;
                  row.selected = false;
                }
              }
            });
          },
        ),
      );
      await completeFormDraft();
      if (!mounted) return;
      invalidateCounts();
      setState(() => _submitting = false);
      context.appSuccess(
        AppLocalizations.of(context).qualityBatchSubmitDone(
          submission.iqcLineCount,
          submission.fqcLotCount,
        ),
      );
      if (context.canPop()) {
        context.pop(true);
      } else {
        context.go(RouteName.warehouseInspections);
      }
    } on ApiException catch (error) {
      if (mounted) {
        context.appError(
          '${submission.currentLabel}：${error.message}。重试将核对原报告，已确认成功的单据不会重发',
        );
      }
    } catch (error) {
      // 本机检查点或回执校验的原因如实给人看(ADR-151 §2); 真正未知才提示核对原报告。
      final reason = describeFormSaveError(error);
      if (mounted) {
        context.appError(
          reason == null
              ? '${submission.currentLabel}提交未确认，请重试原报告'
              : '${submission.currentLabel}：$reason',
        );
      }
    } finally {
      invalidateCounts();
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return withFormDraft(_buildEditor(context));
  }

  Widget _buildEditor(BuildContext context) {
    if (_draftLoadError != null) {
      return Scaffold(
        appBar: const UtenAppBar(title: '恢复检验草稿', showBackButton: true),
        body: UtenEmpty.error(
          message: _draftLoadError,
          actionLabel: '重试',
          onAction: _initializeAndLoad,
        ),
      );
    }
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_submitting,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) _leaving = true;
      },
      child: Scaffold(
        appBar: UtenAppBar(
          title:
              '批量审批 · ${_selection.receipts.length} 单 IQC'
              '${_selection.sheets.isNotEmpty ? ' + ${_selection.sheets.length} 张产成品检查单' : ''}'
              '${_selection.inspections.isNotEmpty ? ' + ${_selection.inspections.length} 项产成品' : ''}',
          leading: UtenBackButton(
            color: _submitting ? theme.disabledColor : null,
            onPressed: () {
              if (!_submitting) {
                _leaving = true;
                popOrBackTo(
                  context,
                  defaultPath: RouteName.warehouseInspections,
                );
              }
            },
          ),
        ),
        body: SafeArea(
          child: _loading
              ? const UtenSkeletonList()
              : Stack(
                  children: [
                    AbsorbPointer(
                      absorbing: _submitting,
                      child: UtenGridPageScrollbar(
                        pinned: _anyPinned,
                        controller: _pageScroll,
                        child: UtenContentContainer.wide(
                          child: AbsorbPointer(
                            absorbing: _submission != null,
                            child: ExcludeFocus(
                              excluding: _submission != null,
                              child: _buildBody(theme),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 2026-09-12 用户口径「点了像卡住」：提交报告执行期间屏幕
                    // 中间给加载动画（跟随网络调用本身，失败/完成后撤下）。
                    // 2026-09-18 并行提交 + 实时进度（X/Y 单已确认），长批次不再
                    // 像卡死：每确认一张单 onProgress 就刷新这里。
                    if (_submitting)
                      Positioned.fill(
                        child: UtenBusyOverlay(
                          title: '正在提交检验报告',
                          description: _submitOverlayDescription(),
                        ),
                      ),
                  ],
                ),
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
        floatingActionButton: _loading ? null : _buildBottomBar(theme),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    final groups = _groups ?? const <_IqcReceiptGroup>[];
    final sheetGroups = _sheetGroups ?? const <_FqcSheetGroup>[];
    final groupedFqcIds = _groupedFqcIds;
    final looseFqc = _selection.inspections
        .where((inspection) => !groupedFqcIds.contains(inspection.id))
        .toList(growable: false);
    final rows = <_ApprovalRow>[
      // 2026-10-02 用户口径：批量审批合一张表——每行一条待检明细，单据类型/单号
      // 成列区分，不再按单分组各画一张表；加载失败的单据行不进表，上方给出重试。
      for (final group in groups)
        if (group.loadError == null)
          for (final row in group.rows) _ApprovalRow.iqc(group.receipt, row),
      for (final group in sheetGroups)
        if (group.loadError == null)
          for (final inspection in group.inspections)
            _ApprovalRow.fqc(inspection, sheetNo: group.sheet.sheetNo),
      for (final inspection in looseFqc) _ApprovalRow.fqc(inspection),
    ];
    if (rows.isEmpty) {
      return UtenEmpty(
        icon: Icons.fact_check_outlined,
        message: '所选任务都已处理',
        description: '请返回待检处置重新选择。',
        actionLabel: '返回待检处置',
        onAction: () =>
            popOrBackTo(context, defaultPath: RouteName.warehouseInspections),
      );
    }
    final failures = <String>[
      for (final group in groups)
        if (group.loadError != null) '${group.label} 明细加载失败：${group.loadError}',
      for (final group in sheetGroups)
        if (group.loadError != null) '${group.label} 明细加载失败：${group.loadError}',
    ];
    return ListView(
      controller: _pageScroll,
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s12,
        UtenSpacing.s12,
        UtenSpacing.s12,
        UtenFloatingActionGroup.scrollClearance,
      ),
      children: [
        for (final failure in failures)
          Padding(
            padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
            child: Text(
              failure,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        if (failures.isNotEmpty)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const Key('batch-approval-reload-failed'),
              onPressed: () => _load(retryFailuresOnly: true),
              icon: const Icon(Icons.refresh),
              label: const Text('重试加载失败的单据'),
            ),
          ),
        _unifiedTable(theme, rows),
      ],
    );
  }

  Widget _iqcQuantityField(_EditableIqcRow row, {required bool passed}) =>
      ListenableBuilder(
        listenable: Listenable.merge([row.pass, row.fail]),
        builder: (context, _) => Semantics(
          textField: true,
          label: '${row.item.goodsName ?? '明细'} ${passed ? '合格数量' : '不合格数量'}',
          child: TextField(
            key: Key(
              'batch-approval-${passed ? 'pass' : 'fail'}-${row.item.id}',
            ),
            controller: passed ? row.pass : row.fail,
            enabled: row.selected && !row.completed && _submission == null,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textAlign: TextAlign.right,
            decoration: UtenInputDecoration(
              InputDecoration(
                isDense: true,
                error: row.validate() == null
                    ? null
                    : UtenFieldMessage.error(row.validate()!),
              ),
            ),
          ),
        ),
      );

  /// 合一后的批量审批表：IQC 收货明细与 FQC 检查任务同表逐行核对。
  /// 类型/单号列区分来源；FQC 是「勾选即全部合格」语义，合格/不合格两列只属于
  /// IQC 行（FQC 行显示 —），本次合格数量看「待检/本次合格」列。
  Widget _unifiedTable(
    ThemeData theme,
    List<_ApprovalRow> rows,
  ) => MasterDataTableView<_ApprovalRow>(
    tableKey:
        'features.quality.pages.quality_batch_approval_page.QualityBatchApprovalPageState._unifiedTable.1',
    key: const Key('batch-approval-unified-table'),
    embedded: true,
    stickyHeaderPinned: _pinOf('unified'),
    showSelectionSummary: false,
    columns: [
      MasterColumnDef(
        key: 'kind',
        label: '类型',
        width: 96,
        value: (row) => row.kindLabel,
      ),
      MasterColumnDef(
        key: 'docNo',
        label: '单号',
        width: 170,
        value: (row) => row.docNo,
      ),
      MasterColumnDef(
        key: 'goods',
        label: '货品名称',
        width: 200,
        value: (row) => row.goodsName ?? '—',
        cellBuilderHandlesSemantics: true,
        cellBuilder: (_, row) => UtenGoodsIdentityCell(name: row.goodsName),
      ),
      MasterColumnDef(
        key: 'goodsCode',
        label: '编号',
        width: 130,
        value: (row) => UtenGoodsAttributeCell.text(row.goodsCode),
        cellBuilder: (_, row) => UtenGoodsAttributeCell(row.goodsCode),
      ),
      MasterColumnDef(
        key: 'color',
        label: '颜色',
        width: 100,
        value: (row) => row.colorName ?? '—',
      ),
      MasterColumnDef(
        key: 'pass',
        label: '合格数量',
        width: 150,
        type: 'number',
        info: inspectionQuantityColumnHint(context, passed: true),
        value: (row) => row.iqc?.pass.text ?? '—',
        exactValueOf: (row) => row.iqc?.pass.text,
        exactListenableOf: (row) => row.iqc?.pass,
        cellBuilder: (context, row) => row.iqc == null
            ? const Text('—')
            : _iqcQuantityField(row.iqc!, passed: true),
      ),
      MasterColumnDef(
        key: 'fail',
        label: '不合格数量',
        width: 150,
        type: 'number',
        info: inspectionQuantityColumnHint(context, passed: false),
        value: (row) => row.iqc?.fail.text ?? '—',
        exactValueOf: (row) => row.iqc?.fail.text,
        exactListenableOf: (row) => row.iqc?.fail,
        cellBuilder: (context, row) => row.iqc == null
            ? const Text('—')
            : _iqcQuantityField(row.iqc!, passed: false),
      ),
      MasterColumnDef(
        key: 'remaining',
        label: '待检/本次合格',
        width: 120,
        type: 'number',
        value: (row) => row.iqc != null
            ? _fmt(row.iqc!.item.remainingBaseQty ?? 0)
            : fqcQtyText(row.fqc!.remainingQty),
        exactValueOf: (row) => row.iqc?.item.remainingBaseQty?.toString(),
      ),
      MasterColumnDef(
        key: 'split',
        label: AppLocalizations.of(context).qualityBatchColumnSplit,
        width: 200,
        value: (row) =>
            row.splitText ??
            (row.wholeLot
                ? AppLocalizations.of(
                    context,
                  ).qualityBatchWholeLot(row.fqc!.lotSliceCount)
                : '—'),
      ),
      MasterColumnDef(
        key: 'unit',
        label: '单位',
        width: 190,
        value: (row) => row.iqc != null
            ? inspectionQuantityUnitCell(context, row.iqc!.item)
            : row.fqc?.unitName ?? '—',
      ),
      MasterColumnDef(
        key: 'source',
        label: '来源单据',
        width: 170,
        value: (row) => row.iqc?.item.sourceOrderNo ?? row.fqc?.reportNo ?? '—',
      ),
      MasterColumnDef(
        key: 'plan',
        label: '生产计划',
        width: 150,
        value: (row) => row.fqc?.planNo ?? '—',
      ),
      MasterColumnDef(
        key: 'warehouse',
        label: '实际成品仓',
        width: 150,
        value: (row) => row.fqc?.warehouseName ?? '—',
      ),
      MasterColumnDef(
        key: 'preStocked',
        label: '储放位置',
        width: 200,
        value: (row) => row.preStockedLabel,
        cellBuilder: (context, row) {
          if (!row.preStocked) return Text(row.preStockedLabel);
          return Text(
            row.preStockedLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: UtenColors.error,
              fontWeight: FontWeight.w700,
            ),
          );
        },
      ),
      MasterColumnDef(
        key: 'status',
        label: '本次报告',
        width: 190,
        value: (row) => row.isFqc
            ? (row.wholeLot
                  ? AppLocalizations.of(context).qualityBatchWholeLotPass
                  : '勾选即全部合格')
            : row.iqc!.completed
            ? '本次报告已确认提交'
            : '待提交',
      ),
    ],
    items: rows,
    facets: const {},
    nullCounts: const {},
    filters: const {},
    onFilterChanged: (_, _) {},
    selectable: true,
    idOf: (row) => row.selectable ? row.selectId : null,
    selectedIds: {
      for (final row in rows)
        if (row.isFqc
            ? _selectedFqcIds.contains(row.fqc!.id)
            : row.iqc!.selected && !row.iqc!.completed)
          row.selectId,
    },
    onSelectedIdsChanged: (next) => setState(() {
      for (final row in rows) {
        final checked = next.contains(row.selectId);
        if (row.iqc != null) {
          if (!row.iqc!.completed) row.iqc!.selected = checked;
        } else if (row.fqc != null) {
          if (checked) {
            _selectedFqcIds.add(row.fqc!.id);
          } else {
            _selectedFqcIds.remove(row.fqc!.id);
          }
        }
      }
    }),
    emptyMessage: '所选单据已无待检明细',
  );

  Widget _buildBottomBar(ThemeData theme) {
    final selectedCount = _selectedCount;
    return UtenFloatingActionGroup(
      children: [
        UtenSelectionSummaryPill(
          key: const Key('batch-approval-selected-count'),
          clearKey: const Key('batch-approval-clear-selection'),
          count: selectedCount,
          onClear: selectedCount == 0 || _submission != null || _submitting
              ? null
              : _clearSelection,
        ),
        UtenButton(
          key: const Key('batch-approval-submit-report'),
          type: UtenButtonType.danger,
          size: UtenButtonSize.large,
          isLoading: _submitting,
          icon: Icons.fact_check_outlined,
          onPressed: _submitting || _confirming ? null : _submitReport,
          child: Text(_submission == null ? '提交报告' : '重试原报告'),
        ),
      ],
    );
  }
}

String _fmt(double value) {
  final fixed = value.toStringAsFixed(4);
  final trimmed = fixed.replaceFirst(RegExp(r'0+$'), '');
  return trimmed.endsWith('.')
      ? trimmed.substring(0, trimmed.length - 1)
      : trimmed;
}
