// 委外领料拣货出仓页(/warehouse/subcontract-outbound/:issueId, ADR-143 §4.3)。
//
// 一页 = 委外人员在委外任务中心提交、仓库还没发出的一张委外领料单(出仓单草稿):
//   - 全页无价格/金额/币种字段；
//   - 明细就是领料单原行(每行是某个委外件的直属物料)：本次出库数量只能改少
//     (0 ≤ 数量 ≤ 委外提交的领料数量)，不能改多、不能加行；某条物料这次不发就填 0，
//     保存时不回传这一行，服务端删行并退回它占用的库存；改少保存后服务端立即释放多占
//     的库存，少发、不发的部分委外下次领料时系统自动补齐；
//   - 整单都不发：「退回委外(不发)」(必填原因)，领料单作废、占用的库存退回，并通知
//     提交领料的委外人员——仓库改过的领料单委外那边撤不回，由仓库在这里退回；
//   - 发出仓默认 = 领料单的仓，仓库核对实际仓与库位后可改；经办人默认当前登录人；
//   - 「审核出仓」确认弹窗明示效果：直属物料出库 → 委外商加工 → 回厂登记委外件、品质检查；
//   - 领料单已被委外撤回 / 已处理(服务端 404)：友好提示「无需拣货」并给「返回待发料」。
// 保存拣货与审核出仓走既有 /api/subcontract/material-issues 的编辑/审核端点；
// 退回委外走 POST /api/warehouse/subcontract-outbound/tasks/{issueId}/return-to-draw。
//
// 页面骨架与「销售出库详情」统一(仓库作业页同一长相): 顶栏 title + 刷新;
// 正文 = 折叠头(状态横幅 / 事实卡 / 可编辑时的出仓表单卡) + 明细表内滚;
// 动作全部收进右下悬浮动作组(保存拣货 / 审核出仓), 跑批遮罩 UtenBusyOverlay。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_field_codec.dart';

import '../../../components/buttons/uten_app_bar_action_button.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/l10n/gen/app_localizations_zh.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/measurement/weight_prefs.dart';
import '../../../shared/providers/master_name_provider.dart' as mn;
import '../../../shared/widgets/warehouse_hierarchy_dropdown.dart';
import '../../../shared/widgets/warehouse_selection.dart';
import '../../../shared/providers/session_provider.dart';
import '../../department/repositories/department_repository.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../subcontract/models/subcontract_doc.dart';
import '../../subcontract/repositories/subcontract_repository.dart';
import '../models/subcontract_outbound.dart';
import '../models/warehouse_form_draft_codec.dart';
import '../models/subcontract_outbound_execution.dart';
import '../widgets/subcontract_outbound_detail_table.dart';
import '../repositories/warehouse_subcontract_outbound_repository.dart';
import '../repositories/subcontract_outbound_detail_loader.dart';
import '../navigation/warehouse_subcontract_outbound_navigation.dart';
import '../providers/warehouse_count_refresh.dart';

/// 批量校验提示：把同一类违规的**全部**行汇总成一句话。
///
/// 条目多时只列前 8 条再折成「等 N 行」——刷屏的提示和只报第一行一样没法用。
/// [issue] 可直接传整句，故先去掉句末句号再接后半句。
String _rowIssueMessage(
  List<String> rowLabels,
  String issue, {
  required String action,
}) {
  const shownMax = 8;
  final shown = rowLabels.take(shownMax).join('、');
  final more = rowLabels.length > shownMax ? '等 ${rowLabels.length} 行' : '';
  final text = issue.replaceFirst(RegExp(r'[。.]$'), '');
  return '以下 ${rowLabels.length} 行$text，$action：$shown$more';
}

/// 领料单已不在待发料状态(已出仓 / 已被委外撤回 / 他人改过)。
const _documentChangedMessage = '这张领料单已出仓、已被委外撤回或已被他人修改，请返回列表刷新后再处理';

/// 打开时领料单已不存在(委外撤回 / 已退回委外 / 已处理)：服务端 404。
const _documentGoneMessage = '这张领料单已被委外撤回或已处理，无需拣货';

class WarehouseSubcontractOutboundEditPage extends ConsumerStatefulWidget {
  const WarehouseSubcontractOutboundEditPage({
    super.key,
    required this.issueId,
  });

  /// 委外领料单(出仓单草稿) id。
  final String issueId;

  @override
  ConsumerState<WarehouseSubcontractOutboundEditPage> createState() =>
      _WarehouseSubcontractOutboundEditPageState();
}

class _WarehouseSubcontractOutboundEditPageState
    extends ConsumerState<WarehouseSubcontractOutboundEditPage>
    with FormDraftMixin<WarehouseSubcontractOutboundEditPage> {
  final _remark = TextEditingController();
  final Map<String, UtenEmployeePickerItem> _empCache = {};

  OutboundTaskDetail? _detail;
  SubcontractDocDetail? _document;
  DateTime _billDate = ChinaDateTime.today();
  DateTime? _deliverDate;
  String? _warehouseId;
  String? _workerId;
  bool _loading = true;
  bool _saving = false;
  bool _confirming = false;
  bool _requiresReload = false;
  bool _requestUncertain = false;
  bool _writeStarted = false;
  int _loadGeneration = 0;
  String? _error;

  /// 领料单已不存在(服务端 404)：整页换成「无需拣货」的提示。
  bool _gone = false;
  List<SubcontractOutboundLineDraft> _lines = const [];

  @override
  bool get formDraftBusy => _saving || _confirming || _requestUncertain;
  @override
  Future<void> Function()? get formDraftReloadSource => () async {
    await _load();
    if (_error != null) throw StateError(_error!);
  };
  @override
  FormDraftSpec get formDraftSpec => FormDraftCatalog.subcontractOutbound.spec(
    title: '委外领料拣货出仓填写',
    route: RouteName.warehouseSubcontractOutboundDetail(widget.issueId),
  );
  @override
  Iterable<Listenable> get formDraftListenables => [
    _remark,
    for (final row in _lines) ...[
      row.qty,
      row.remarkController,
      row.weight.weight,
    ],
  ];
  @override
  Map<String, dynamic> captureFormDraft() => {
    'remark': _remark.text,
    'warehouseId': _warehouseId,
    'workerId': _workerId,
    'billDate': _billDate.toIso8601String(),
    'deliverDate': _deliverDate?.toIso8601String(),
    'draftId': _document?.id,
    if (_document != null)
      'serverFingerprint': subcontractOutboundDraftFingerprint(_document!),
    'employees': _empCache.values.map(draftEmployee).toList(),
    'rows': [
      for (final row in _lines)
        {
          'planItemId': row.line.planItemId,
          'draftItemId': row.draftItemId,
          'sourceIdentity': _draftSourceIdentity(row),
          'qty': row.qty.text,
          'qtyAutofilled': row.qty.autofilled,
          'weightKg': row.weight.kg,
          'weightEntry': weightEntryDraft(row.weight.weight, qty: row.qty),
          'qtyFromWeight': row.weight.qtyFromWeight,
          'remark': row.remarkController.text,
        },
    ],
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    final saved = draftMaps(data['rows']);
    final bySource = {for (final row in _lines) row.line.planItemId: row};
    final savedSourceIds = saved.map((item) => item['planItemId']).toSet();
    // 计划行 UUID 是一行明细不变的身份; 提交时用服务器最新的草稿明细 id。
    // 绝不按货品/名称套行, 也不跨单据、跨来源集合恢复。
    if (data['draftId'] != _document?.id ||
        (data['serverFingerprint'] != null &&
            (_document == null ||
                data['serverFingerprint'] !=
                    subcontractOutboundDraftFingerprint(_document!))) ||
        bySource.length != _lines.length ||
        savedSourceIds.length != saved.length ||
        saved.length != _lines.length ||
        saved.any((item) {
          final row = bySource[item['planItemId']];
          return row == null ||
              (item['sourceIdentity'] != null &&
                  item['sourceIdentity'] != _draftSourceIdentity(row));
        })) {
      throw const FormatException('领料单来源或服务器单据已变化，填写草稿保留；请先核对最新领料单');
    }
    _remark.text = draftText(data, 'remark');
    _warehouseId = data['warehouseId'] as String?;
    _workerId = data['workerId'] as String?;
    _billDate = DateTime.tryParse(draftText(data, 'billDate')) ?? _billDate;
    _deliverDate = DateTime.tryParse(draftText(data, 'deliverDate'));
    for (final value in draftMaps(data['employees'])) {
      final employee = restoreDraftEmployee(value);
      _empCache[employee.id] = employee;
    }
    for (final item in saved) {
      final row = bySource[item['planItemId']]!;
      if (item['qtyAutofilled'] == true) {
        row.qty.setAutomaticText(draftText(item, 'qty'));
      } else {
        row.qty.text = draftText(item, 'qty');
      }
      restoreWeightEntryDraft(
        row.weight.weight,
        item['weightEntry'] ??
            {'kg': item['weightKg'], 'qtyFromWeight': item['qtyFromWeight']},
        qty: row.qty,
      );
      row.remarkController.text = draftText(item, 'remark');
    }
    if (mounted) setState(() {});
  }

  String _draftSourceIdentity(SubcontractOutboundLineDraft row) => [
    row.item.orderItemId,
    row.item.goodsId,
    row.item.colorId,
    row.item.unitId,
    row.item.unitRate,
    row.item.parentGoodsId,
    row.item.parentColorId,
    row.line.requestedQty,
  ].join('|');

  AppLocalizations get _l10n =>
      Localizations.of<AppLocalizations>(context, AppLocalizations) ??
      AppLocalizationsZh();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _remark.dispose();
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    if (_requestUncertain) {
      await _verifyExecution();
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _gone = false;
    });
    final generation = ++_loadGeneration;
    try {
      final repo = ref.read(warehouseSubcontractOutboundRepositoryProvider);
      final docRepo = ref.read(
        subcontractRepositoryProvider(SubcontractDocType.materialIssue),
      );
      final results = await Future.wait([
        ref.read(mn.masterNameServiceProvider).ensureWarehousesLoaded(),
        loadSubcontractOutboundDetails(
          issueIds: [widget.issueId],
          taskDetail: repo.taskDetail,
          documentDetail: docRepo.detail,
        ),
      ]);
      if (!mounted || generation != _loadGeneration) return;
      final bundle = (results[1] as List<SubcontractOutboundReadBundle>).single;
      final detail = bundle.task;
      final document = bundle.document;
      if (document.status != 0) {
        throw ApiException(
          'CONFLICT',
          _documentChangedMessage,
          httpStatus: 409,
        );
      }
      final lines = subcontractOutboundLinesOf(
        detail,
        document,
        weightUnit: ref.read(warehouseWeightUnitsPrefsProvider).entry,
      );
      if (lines == null) {
        throw ApiException(
          'CONFLICT',
          _documentChangedMessage,
          httpStatus: 409,
        );
      }
      // 经办人默认当前登录人。
      final user = ref.read(sessionProvider).user;
      final workerId = document.workerId ?? user?.employeeId;
      if (workerId != null &&
          workerId == user?.employeeId &&
          user!.name.isNotEmpty) {
        _empCache[workerId] = UtenEmployeePickerItem(
          id: workerId,
          name: user.name,
          departmentName: user.department,
        );
      }
      _remark.text = document.remark ?? '';
      setState(() {
        _detail = detail;
        _document = document;
        _warehouseId = document.warehouseId ?? detail.warehouseId;
        _billDate = _parseDate(document.billDate) ?? ChinaDateTime.today();
        _workerId = workerId;
        _deliverDate = _parseDate(document.deliverDate);
        for (final old in _lines) {
          old.dispose();
        }
        _lines = lines;
        _loading = false;
        _requiresReload = false;
      });
      unawaited(_preloadEmployees([workerId], generation));
      await initializeFormDraft();
    } on ApiException catch (error) {
      if (!mounted) return;
      final gone = error.httpStatus == 404 || error.code == 'NOT_FOUND';
      setState(() {
        _gone = gone;
        _error = gone ? null : error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '领料单加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  DateTime? _parseDate(String? s) =>
      (s == null || s.isEmpty) ? null : DateTime.tryParse(s);

  static String _date(DateTime value) =>
      '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

  Future<void> _preloadEmployees(Iterable<String?> ids, int generation) async {
    final uniq = ids
        .whereType<String>()
        .where((id) => id.isNotEmpty && !_empCache.containsKey(id))
        .toSet();
    if (uniq.isEmpty) return;
    final repo = ref.read(employeeRepositoryProvider);
    await Future.wait(
      uniq.map((id) async {
        try {
          final p = await repo.getById(id);
          if (!mounted || generation != _loadGeneration) return;
          setState(
            () => _empCache[id] = UtenEmployeePickerItem(
              id: p.id,
              name: p.fullName ?? '',
              employeeCode: p.code,
              departmentName: p.departmentName,
            ),
          );
        } catch (_) {
          // 静默：picker 的 initial 为 null 时不显示名字，不阻塞流程。
        }
      }),
    );
  }

  /// 保存拣货修改(只改数量/重量/备注与表头)；返回是否已写入。
  /// 数量校验：0 ≤ 数量 ≤ 委外提交的领料数量；填 0 的行不回传(服务端删行退库存)，
  /// 至少要有一行大于 0——整单不发走「退回委外(不发)」。
  Future<bool> _saveDraft() async {
    final document = _document;
    if (document == null) return false;
    if (_warehouseId == null ||
        (_warehouseId != document.warehouseId &&
            !WarehouseSelection(
              ref.read(mn.masterNameServiceProvider).warehouseHierarchy,
            ).selectableIds.contains(_warehouseId))) {
      context.appError(_l10n.warehouseSubcontractOutboundWarehouseRequired);
      return false;
    }
    // 明细整表扫完再报：多行时一次列全，不必改一行存一次才看到下一行。
    final items = <Map<String, dynamic>>[];
    final badQty = <String>[];
    final overMaxQty = <String>[];
    final badWeight = <String>[];
    for (var index = 0; index < _lines.length; index++) {
      final e = _lines[index];
      final qty = double.tryParse(e.qty.text.trim()) ?? -1;
      final name = e.line.goodsName ?? e.line.goodsCode ?? '该物料';
      final label = '第 ${index + 1} 行（$name）';
      if (!qty.isFinite || qty < 0) {
        badQty.add(label);
        continue;
      }
      if (qty - e.maxEditableQty > 0.0000001) {
        overMaxQty.add(label);
        continue;
      }
      // 填 0 = 这条物料本次不发：不回传这一行。
      if (qty == 0) continue;
      if (e.weight.weight.hasError) {
        badWeight.add(label);
        continue;
      }
      items.add(e.toPayload());
    }
    final rowIssues = <String>[
      if (badQty.isNotEmpty)
        _rowIssueMessage(
          badQty,
          '的本次出库数量不是 0 或正数',
          action: '请改正后再提交(填 0 表示本次不发)',
        ),
      if (overMaxQty.isNotEmpty)
        _rowIssueMessage(
          overMaxQty,
          '的本次出库数量超过了委外提交的领料数量',
          action: '只能改少，请改小后再提交',
        ),
      if (badWeight.isNotEmpty)
        _rowIssueMessage(badWeight, '的实称重量看不懂', action: '请改成如 12.5 或 850g'),
    ];
    if (rowIssues.isNotEmpty) {
      // 不同类别分行列出，混成一句会让人看不清到底要改哪几处。
      context.appError(rowIssues.join('\n'));
      return false;
    }
    if (items.isEmpty) {
      context.appError(subcontractOutboundNothingToIssue);
      return false;
    }
    final body = <String, dynamic>{
      'billDate': _date(_billDate),
      // 委外商随领料单来源(订货单)固定，防改坏来源关联。
      'supplierId': document.supplierId,
      'warehouseId': _warehouseId,
      if (_workerId != null) 'workerId': _workerId,
      if (_deliverDate != null) 'deliverDate': _date(_deliverDate!),
      'remark': _remark.text.trim().isEmpty ? null : _remark.text.trim(),
      'items': items,
    };
    final repo = ref.read(
      subcontractRepositoryProvider(SubcontractDocType.materialIssue),
    );
    final fresh = await repo.detail(document.id);
    if (subcontractOutboundDraftFingerprint(fresh) !=
        subcontractOutboundDraftFingerprint(document)) {
      _requiresReload = true;
      throw ApiException('CONFLICT', _documentChangedMessage, httpStatus: 409);
    }
    _writeStarted = true;
    _document = await repo.update(document.id, body);
    return true;
  }

  Future<void> _onSave() async {
    if (_saving || _confirming || _requiresReload) return;
    _writeStarted = false;
    setState(() => _saving = true);
    try {
      final saved = await _saveDraft();
      if (!mounted || !saved) return;
      invalidateWarehouseTaskCounts(ref);
      await completeFormDraft();
      if (!mounted) return;
      context.appSuccess('拣货修改已保存');
      context.pop(true);
    } on ApiException catch (error) {
      if (mounted) {
        _requiresReload = true;
        _requestUncertain =
            _writeStarted &&
            (error.httpStatus == null || error.httpStatus! >= 500);
        context.appError(error.message);
      }
    } catch (_) {
      if (mounted) {
        _requiresReload = true;
        _requestUncertain = _writeStarted;
        context.appError(_l10n.warehouseSubcontractOutboundUncertain);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _onApprove() async {
    if (_saving || _confirming || _requiresReload) return;
    _writeStarted = false;
    setState(() => _confirming = true);
    final confirmed = await showUtenReviewerConfirmDialog(
      context,
      title: '审核出仓确认',
      confirmLabel: '确认出仓',
      actionLabel: '委外领料出仓审核',
      responsibilityDescription: '确认后，系统将以此登录员工记录本次委外出仓审核责任。',
      message: subcontractOutboundApproveEffects,
    );
    if (!confirmed || !mounted) {
      if (mounted) setState(() => _confirming = false);
      return;
    }
    setState(() {
      _confirming = false;
      _saving = true;
    });
    try {
      final saved = await _saveDraft();
      if (!saved) {
        if (mounted) setState(() => _saving = false);
        return;
      }
      final repo = ref.read(
        subcontractRepositoryProvider(SubcontractDocType.materialIssue),
      );
      final document = _document!;
      final fresh = await repo.detail(document.id);
      if (subcontractOutboundDraftFingerprint(fresh) !=
          subcontractOutboundDraftFingerprint(document)) {
        throw ApiException(
          'CONFLICT',
          _documentChangedMessage,
          httpStatus: 409,
        );
      }
      _writeStarted = true;
      final approved = await repo.approve(document.id);
      if (approved.status != 1) {
        throw ApiException(
          'UNKNOWN_RECEIPT',
          _l10n.warehouseSubcontractOutboundUncertain,
        );
      }
      if (!mounted) return;
      invalidateWarehouseTaskCounts(ref);
      await completeFormDraft();
      if (!mounted) return;
      context.appSuccess('委外领料已出仓，可通知委外商加工');
      returnToSubcontractOutboundTasks(context);
    } on ApiException catch (error) {
      if (mounted) {
        _requiresReload = true;
        _requestUncertain =
            _writeStarted &&
            (error.httpStatus == null || error.httpStatus! >= 500);
        context.appError(error.message);
      }
    } catch (_) {
      if (mounted) {
        _requiresReload = true;
        _requestUncertain = _writeStarted;
        context.appError(_l10n.warehouseSubcontractOutboundUncertain);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 整单不发：填原因后把这张领料单退回委外(服务端作废领料单、退回占用的库存并
  /// 通知提交领料的委外人员)。原因弹窗在跑批遮罩亮起之前弹，遮罩不会盖住它。
  Future<void> _onReturnToDraw() async {
    if (_saving || _confirming || _requiresReload) return;
    final detail = _detail;
    if (detail == null) return;
    setState(() => _confirming = true);
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => _ReturnToDrawReasonDialog(
        billNo: detail.issueBillNo ?? _document?.billNo ?? '',
      ),
    );
    if (!mounted) return;
    if (reason == null) {
      setState(() => _confirming = false);
      return;
    }
    setState(() {
      _confirming = false;
      _saving = true;
    });
    try {
      await ref
          .read(warehouseSubcontractOutboundRepositoryProvider)
          .returnToDraw(widget.issueId, reason: reason);
      if (!mounted) return;
      invalidateWarehouseTaskCounts(ref);
      await completeFormDraft();
      if (!mounted) return;
      setState(() => _saving = false);
      context.appSuccess('已退回委外：这张领料单不发了，占用的库存已退回，并通知了委外人员');
      returnToSubcontractOutboundTasks(context);
    } on ApiException catch (error) {
      if (!mounted) return;
      final status = error.httpStatus;
      setState(() {
        _saving = false;
        // 领料单已被撤回 / 已出仓 / 被改过，或回执没收到：先刷新核对再处理。
        if (status == null || status == 404 || status == 409 || status >= 500) {
          _requiresReload = true;
        }
      });
      context.appError(error.message);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _requiresReload = true;
      });
      context.appError('暂未确认是否已退回委外，请点「刷新」核对这张领料单');
    }
  }

  Future<void> _verifyExecution() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final document = _document;
      if (document != null) {
        final fresh = await ref
            .read(
              subcontractRepositoryProvider(SubcontractDocType.materialIssue),
            )
            .detail(document.id);
        if (fresh.status == 1 && mounted) {
          invalidateWarehouseTaskCounts(ref);
          await completeFormDraft();
          if (!mounted) return;
          context.appSuccess(_l10n.warehouseSubcontractOutboundDone);
          returnToSubcontractOutboundTasks(context);
          return;
        }
      }
      if (mounted) {
        context.appWarning(_l10n.warehouseSubcontractOutboundUncertain);
      }
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message);
    } catch (_) {
      if (mounted) {
        context.appError(_l10n.warehouseSubcontractOutboundUncertain);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    final busy = _saving || _confirming;
    final gate = detail == null
        ? null
        : _PickGate.of(_lines, ref.watch(currentPermissionsProvider));
    // 首屏骨架 / 出错 / 不存在时不挂悬浮动作组; 刷新中也收起(刷新期间不能动)。
    final ready = detail != null && !_loading && _error == null && !_gone;
    return withFormDraft(
      PopScope(
        canPop: !busy,
        child: Scaffold(
          appBar: UtenAppBar(
            title: '委外领料拣货出仓',
            leading: UtenBackButton(
              onPressed: busy
                  ? null
                  : () => backTo(
                      context,
                      defaultPath: RouteName.warehouseSubcontractOutbound,
                    ),
            ),
            actions: [
              UtenAppBarActionButton(
                key: const Key('warehouse-subcontract-outbound-detail-refresh'),
                label: '刷新',
                icon: Icons.refresh_rounded,
                isLoading: _loading && detail != null,
                onPressed: _loading || busy ? null : _load,
              ),
            ],
          ),
          body: Stack(
            children: [
              Positioned.fill(
                child: SafeArea(
                  child: _gone
                      ? UtenEmpty(
                          key: const Key(
                            'warehouse-subcontract-outbound-detail-gone',
                          ),
                          icon: Icons.task_alt_rounded,
                          message: _documentGoneMessage,
                          description: '委外人员已撤回这张领料单，或仓库已发出 / 已退回委外。',
                          actionLabel: '返回待发料',
                          onAction: () =>
                              returnToSubcontractOutboundTasks(context),
                        )
                      : _loading && detail == null
                      ? const UtenSkeletonList(itemCount: 6)
                      : _error != null
                      ? UtenEmpty.error(
                          message: _error,
                          actionLabel: '重新加载',
                          onAction: _load,
                        )
                      : detail == null
                      ? const UtenEmpty(message: '领料单不存在')
                      : AbsorbPointer(
                          absorbing: busy || _loading,
                          child: _buildBody(detail, gate!),
                        ),
                ),
              ),
              if (_saving)
                Positioned.fill(
                  child: UtenBusyOverlay(title: _l10n.commonLoading),
                ),
            ],
          ),
          floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
          floatingActionButtonAnimator:
              FloatingActionButtonAnimator.noAnimation,
          floatingActionButton:
              !ready || gate == null || (!gate.canEdit && !gate.canReturn)
              ? null
              : UtenFloatingActionGroup(
                  children: [
                    if (gate.canReturn)
                      UtenButton(
                        key: const Key(
                          'warehouse-subcontract-outbound-action-return',
                        ),
                        type: UtenButtonType.secondary,
                        size: UtenButtonSize.large,
                        icon: Icons.undo_rounded,
                        onPressed: _saving || _requiresReload
                            ? null
                            : _onReturnToDraw,
                        child: const Text('退回委外(不发)'),
                      ),
                    if (gate.canEdit)
                      UtenButton(
                        key: const Key(
                          'warehouse-subcontract-outbound-action-save',
                        ),
                        type: UtenButtonType.tonal,
                        size: UtenButtonSize.large,
                        icon: Icons.save_outlined,
                        isLoading: _saving,
                        onPressed: _saving || _requiresReload ? null : _onSave,
                        child: const Text('保存拣货'),
                      ),
                    if (gate.canApprove)
                      UtenButton(
                        key: const Key(
                          'warehouse-subcontract-outbound-action-approve',
                        ),
                        type: UtenButtonType.danger,
                        size: UtenButtonSize.large,
                        icon: Icons.outbound_rounded,
                        isLoading: _saving,
                        onPressed: _saving || _requiresReload
                            ? null
                            : _onApprove,
                        child: Text(_l10n.warehouseSubcontractOutboundApprove),
                      ),
                  ],
                ),
        ),
      ),
    );
  }

  /// 折叠头(状态横幅 / 事实卡 / 表单卡) + 明细表内滚——与销售出库详情同骨架。
  Widget _buildBody(OutboundTaskDetail detail, _PickGate gate) {
    final names = ref.watch(mn.masterNameServiceProvider);
    return UtenContentContainer.wide(
      child: UtenCollapsingHeaderScrollView(
        collapsingHeader: Padding(
          padding: const EdgeInsets.only(top: UtenSpacing.s16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _statusBanner(),
              const SizedBox(height: UtenSpacing.s12),
              _factsCard(detail),
              if (gate.canEdit) ...[
                const SizedBox(height: UtenSpacing.s12),
                _formCard(names),
              ],
              const SizedBox(height: UtenSpacing.s16),
            ],
          ),
        ),
        // body：直属物料明细表占满内滚(primary 拾取联动控制器)。
        body: SubcontractOutboundDetailTable(
          primary: true,
          bottomContentPadding: UtenFloatingActionGroup.scrollClearance,
          rows: [
            for (final line in _lines)
              SubcontractOutboundTableRow(
                draft: line,
                warehouse: names.warehouse(_warehouseId),
                warehouseId: _warehouseId,
              ),
          ],
          editable: gate.canEdit && !_saving,
          onChanged: () => setState(() {}),
        ),
      ),
    );
  }

  /// 状态横幅: 待发料 + 物料种数 + 「只能改少」口径 + 回执待核实提示。
  Widget _statusBanner() {
    final theme = Theme.of(context);
    final l10n = _l10n;
    final kinds = {
      for (final row in _lines) '${row.line.goodsId}|${row.item.colorId}',
    }.length;
    const status = '委外领料待发料';
    final notes = <String>[
      '共 $kinds 种物料、${_lines.length} 行。请核对实际仓与库位后审核出仓。',
      '本次出库数量只能改少，不能改多；某条物料这次不发就填 0。少发、不发的部分委外下次领料时系统会自动补齐。',
      '整张领料单都不发：点「退回委外(不发)」并写明原因，占用的库存会退回并通知委外人员。',
    ];
    return Semantics(
      container: true,
      liveRegion: true,
      label: '$status。${notes.join(' ')}',
      child: Container(
        key: const Key('warehouse-subcontract-outbound-detail-boundary'),
        padding: const EdgeInsets.all(UtenSpacing.s16),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
          borderRadius: UtenRadius.lgAll,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              status,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            for (final note in notes) ...[
              const SizedBox(height: UtenSpacing.s4),
              Text(
                note,
                style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
              ),
            ],
            if (_requiresReload) ...[
              const SizedBox(height: UtenSpacing.s8),
              Wrap(
                spacing: UtenSpacing.s12,
                runSpacing: UtenSpacing.s8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      l10n.warehouseSubcontractOutboundUncertain,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  UtenButton(
                    type: UtenButtonType.secondary,
                    size: UtenButtonSize.small,
                    isLoading: _loading,
                    onPressed: _saving || _loading ? null : _load,
                    child: Text(l10n.warehouseSubcontractOutboundVerify),
                  ),
                ],
              ),
            ],
            const SizedBox(height: UtenSpacing.s4),
            Text(
              l10n.warehouseSubcontractOutboundBannerScope,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 事实卡(三列 Wrap): 订货单/委外商/领料单只读, 防改坏来源关联。
  Widget _factsCard(OutboundTaskDetail detail) {
    final document = _document;
    final facts = <(String, String?)>[
      ('委外订货单', detail.orderBillNo),
      ('委外商', detail.supplierName),
      ('领料单号', detail.issueBillNo ?? document?.billNo),
      ('领料仓', detail.warehouseName),
      ('提交人', document?.makerName),
      ('提交时间', ChinaDateTime.formatIsoInstant(document?.createdAt)),
    ].where((fact) => fact.$2?.trim().isNotEmpty == true).toList();
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: UtenRadius.lgAll,
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 1080
                ? 3
                : constraints.maxWidth >= 640
                ? 2
                : 1;
            final width =
                (constraints.maxWidth - UtenSpacing.s12 * (columns - 1)) /
                columns;
            return Wrap(
              spacing: UtenSpacing.s12,
              runSpacing: UtenSpacing.s12,
              children: [
                for (final fact in facts)
                  SizedBox(
                    width: width,
                    child: _PickFact(label: fact.$1, value: fact.$2!),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 出仓表单卡(仅可编辑时): 出仓日期 / 发出仓 / 经办人 / 交货日期 / 备注。
  Widget _formCard(mn.MasterNameService names) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: UtenRadius.lgAll,
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: UtenFormGrid(
          children: [
            UtenDateField(
              label: '出仓日期',
              required: true,
              value: _billDate,
              onChanged: (d) => setState(() => _billDate = d),
            ),
            // V476: 主/子层级(父仓置灰分组, 出仓落具体仓)。
            WarehouseHierarchyDropdown(
              key: ValueKey('warehouse_$_warehouseId'),
              entries: names.warehouseHierarchy,
              value: _warehouseId,
              labelText: '发出仓(必选)',
              onChanged: (v) {
                if (v != null) setState(() => _warehouseId = v);
              },
            ),
            UtenEmployeePicker(
              key: ValueKey('worker_$_workerId'),
              label: '经办人',
              hint: '请选择经办人',
              sheetTitle: '选择经办人',
              initial: _workerId == null ? null : _empCache[_workerId],
              loader: (kw) async {
                final deptId = (kw == null || kw.isEmpty)
                    ? (ref.read(departmentCodeIdMapProvider).valueOrNull ??
                          const {})['SUB_WH']
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
                setState(() => _workerId = item?.id);
              },
            ),
            UtenDateField(
              label: '交货日期',
              value: _deliverDate ?? ChinaDateTime.today(),
              onChanged: (d) => setState(() => _deliverDate = d),
            ),
            TextField(
              key: const Key('warehouse-subcontract-outbound-remark'),
              controller: _remark,
              maxLength: 200,
              decoration: const UtenInputDecoration(
                InputDecoration(labelText: '备注'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 本页动作的权限闸。退回委外只要委外出库执行权(服务端同一权限点 + 仓库范围)。
class _PickGate {
  const _PickGate({
    required this.canEdit,
    required this.canApprove,
    required this.canReturn,
  });

  factory _PickGate.of(
    List<SubcontractOutboundLineDraft> lines,
    Set<String> permissions,
  ) {
    final canExecute =
        lines.isNotEmpty &&
        permissions.contains(Perm.subcontractOutboundExecute);
    final canEdit =
        canExecute && permissions.contains(Perm.subcontractMaterialIssueEdit);
    return _PickGate(
      canEdit: canEdit,
      canApprove:
          canEdit && permissions.contains(Perm.subcontractMaterialIssueApprove),
      canReturn: canExecute,
    );
  }

  final bool canEdit;
  final bool canApprove;
  final bool canReturn;
}

/// 「退回委外(不发)」原因(必填，最多 200 字)。
class _ReturnToDrawReasonDialog extends StatefulWidget {
  const _ReturnToDrawReasonDialog({required this.billNo});

  final String billNo;

  @override
  State<_ReturnToDrawReasonDialog> createState() =>
      _ReturnToDrawReasonDialogState();
}

class _ReturnToDrawReasonDialogState extends State<_ReturnToDrawReasonDialog> {
  static const _maxLength = 200;
  final _reason = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _reason.text.trim();
    if (text.isEmpty) {
      setState(() => _error = '请填写不发的原因');
      return;
    }
    if (text.length > _maxLength) {
      setState(() => _error = '原因最多 $_maxLength 字');
      return;
    }
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    final billNo = widget.billNo.trim();
    return AlertDialog(
      title: const Text('退回委外(不发)'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${billNo.isEmpty ? '这张领料单' : '领料单 $billNo'}整单不发：'
              '退回后领料单作废，占用的库存退回，并通知提交领料的委外人员。'
              '物料到齐后委外可以重新领料。此操作不能撤销。',
            ),
            const SizedBox(height: UtenSpacing.s12),
            TextField(
              key: const Key('warehouse-subcontract-outbound-return-reason'),
              controller: _reason,
              autofocus: true,
              maxLength: _maxLength,
              maxLines: 3,
              decoration: UtenInputDecoration(
                InputDecoration(
                  labelText: '不发原因(必填)',
                  hintText: '如：物料破损，本批不能发',
                  error: _error == null
                      ? null
                      : UtenFieldMessage.error(_error!),
                ),
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        UtenButton(
          type: UtenButtonType.ghost,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        UtenButton(
          key: const Key('warehouse-subcontract-outbound-return-confirm'),
          type: UtenButtonType.danger,
          onPressed: _submit,
          child: const Text('退回委外'),
        ),
      ],
    );
  }
}

class _PickFact extends StatelessWidget {
  const _PickFact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: '$label：$value',
      child: Container(
        constraints: const BoxConstraints(minHeight: 64),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLowest,
          borderRadius: UtenRadius.mdAll,
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s4),
            SelectableText(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
