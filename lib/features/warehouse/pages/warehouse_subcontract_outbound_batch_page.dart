// 委外领料批量出库页(ADR-143 §4.3): 一次核对并审核多张委外领料单。
//
// 打开只读不写; 明确所选明细的任务入口一次原子出仓，未选行与预留留在原草稿。
// 原请求体和编号先持久化; 回执不明时先读原回执，再按原内容重试。
// 未传明细身份的旧整单入口保留原保存/审核兼容路径。
// 每行数量只能改少，不能改多、不能加行；原子出仓只发送所选正数行，0行继续留原单待发。
// 一张单至少要发一行；整单不发仍可在单张拣货页「退回委外(不发)」。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_grid_page_scrollbar.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/l10n/gen/app_localizations_zh.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/drafts/form_draft_store.dart';
import '../../../shared/drafts/form_draft_values.dart';
import '../../../shared/measurement/weight_prefs.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/widgets/warehouse_selection.dart';
import '../../department/repositories/department_repository.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../subcontract/models/subcontract_doc.dart';
import '../../subcontract/repositories/subcontract_repository.dart';
import '../models/subcontract_outbound.dart';
import '../models/subcontract_outbound_execution.dart';
import '../models/warehouse_task_item_selection.dart';
import '../providers/warehouse_count_refresh.dart';
import '../repositories/warehouse_subcontract_outbound_repository.dart';
import '../repositories/subcontract_outbound_detail_loader.dart';
import '../navigation/warehouse_subcontract_outbound_navigation.dart';
import '../widgets/subcontract_outbound_detail_table.dart';
import '../models/warehouse_form_draft_codec.dart';
import '../../employee/repositories/employee_picker_candidates.dart';
import 'package:uten_imp/components/layout/uten_page_layout.dart';

class WarehouseSubcontractOutboundBatchPage extends ConsumerStatefulWidget {
  const WarehouseSubcontractOutboundBatchPage({
    super.key,
    required this.issueIds,
    this.onCompleted,
    this.selectedItemIds,
  });

  /// 勾选的委外领料单(出仓单草稿) id。
  final List<String> issueIds;
  final VoidCallback? onCompleted;
  final List<String>? selectedItemIds;

  @override
  ConsumerState<WarehouseSubcontractOutboundBatchPage> createState() =>
      _WarehouseSubcontractOutboundBatchPageState();
}

class _BatchDraft {
  _BatchDraft({
    required this.detail,
    required this.document,
    required this.lines,
    this.workerId,
    this.reviewFingerprint,
  }) : warehouseId = document.warehouseId ?? detail.warehouseId,
       date =
           DateTime.tryParse(document.billDate ?? '') ?? ChinaDateTime.today(),
       deliveryDate = DateTime.tryParse(document.deliverDate ?? ''),
       remark = TextEditingController(text: document.remark ?? '');

  final OutboundTaskDetail detail;
  final List<SubcontractOutboundLineDraft> lines;
  SubcontractDocDetail document;
  String? warehouseId;
  String? workerId;
  DateTime date;
  DateTime? deliveryDate;
  bool warehouseAutofilled = true;
  final TextEditingController remark;
  SubcontractOutboundExecutionState state =
      SubcontractOutboundExecutionState.pending;
  String? error;
  final String? reviewFingerprint;

  bool get pending => subcontractOutboundMaySubmit(state);
  bool get selected => lines.any((line) => line.selected);

  void dispose() {
    for (final line in lines) {
      line.dispose();
    }
    remark.dispose();
  }
}

/// Opening this page performs reads only. Confirmation saves and approves each
/// draw document's own EC draft, preserving supplier, plan UUIDs and quantities.
class _WarehouseSubcontractOutboundBatchPageState
    extends ConsumerState<WarehouseSubcontractOutboundBatchPage>
    with FormDraftMixin<WarehouseSubcontractOutboundBatchPage> {
  final _drafts = <_BatchDraft>[];
  final _employees = <String, UtenEmployeePickerItem>{};
  bool _loading = true;
  bool _saving = false;
  bool _confirming = false;
  bool _changed = false;
  String? _error;
  int _loadGeneration = 0;
  Set<String> _submittedDraftIds = {};
  final Set<String> _completedIssueIds = {};
  final Map<String, Map<String, dynamic>> _retainedUncertainInputs = {};
  final Map<String, Map<String, dynamic>> _atomicCommands = {};
  final Map<String, List<String>> _atomicSourceScopes = {};
  final Set<String> _atomicUnknownIds = {};
  final Set<String> _atomicReadableSources = {};
  final Map<String, String> _atomicReadProblems = {};
  final Map<String, Map<String, dynamic>> _opaqueSourceInputs = {};
  bool _recoveryOnly = false;
  bool _savedExitReady = false;

  bool get _atomicEntry => widget.selectedItemIds != null;
  bool get _canRetryAtomic =>
      !formDraftRestorationBlocked &&
      _canExecute &&
      _atomicUnknownIds.any(_atomicReadableSources.contains);
  bool get _allOriginalSourcesCompleted =>
      widget.issueIds.every(_completedIssueIds.contains);

  @override
  bool get formDraftBusy => _loading || _saving || _confirming;
  // Every command targets a confirmed existing issue UUID. Unknown rows stay
  // outside the pending queue; only untouched rows may start a new operation.
  @override
  bool get formDraftCanReplaySubmission => true;
  @override
  bool get formDraftHasConfirmedExternalRecovery => _savedExitReady;
  @override
  bool get formDraftHasUnknownSubmission =>
      _atomicUnknownIds.isNotEmpty ||
      _drafts.any(
        (draft) => const {
          SubcontractOutboundExecutionState.saving,
          SubcontractOutboundExecutionState.approving,
          SubcontractOutboundExecutionState.needsVerification,
        }.contains(draft.state),
      );
  @override
  Widget? get formDraftSubmissionRecoveryAction => Wrap(
    spacing: UtenSpacing.s8,
    children: [
      UtenButton(
        type: UtenButtonType.secondary,
        onPressed: _saving || _loading ? null : _verify,
        child: const Text('核对出仓结果'),
      ),
      if (_canRetryAtomic)
        UtenButton(
          type: UtenButtonType.secondary,
          onPressed: _saving || _loading ? null : _retryAtomic,
          child: const Text('按原内容重试'),
        ),
    ],
  );
  @override
  FormDraftSpec get formDraftSpec =>
      FormDraftCatalog.subcontractOutboundBatch.spec(
        route: Uri(
          path: '/warehouse/subcontract-outbound/batch',
          queryParameters: {
            'issueIds': widget.issueIds.join(','),
            ...WarehouseTaskItemSelection(
              widget.selectedItemIds,
            ).queryParameters,
          },
        ).toString(),
      );
  @override
  Iterable<Listenable> get formDraftListenables => [
    for (final draft in _drafts) ...[
      draft.remark,
      for (final row in draft.lines) ...[
        row.qty,
        row.remarkController,
        row.weight.weight,
      ],
    ],
  ];

  Map<String, dynamic> _sourceIdentity(SubcontractOutboundLineDraft row) => {
    'goodsId': row.item.goodsId ?? row.line.goodsId,
    'colorId': row.item.colorId,
    'unitId': row.item.unitId,
    'unitRate': row.item.unitRateText,
    'orderItemId': row.item.orderItemId,
    'planItemId': row.line.planItemId,
    'requestedQty': row.line.requestedQtyText,
  };

  Map<String, dynamic> _captureInput(_BatchDraft draft) => {
    'issueId': draft.document.id,
    'serverFingerprint': subcontractOutboundDraftFingerprint(draft.document),
    'state': draft.state.name,
    'warehouseId': draft.warehouseId,
    'warehouseAutofilled': draft.warehouseAutofilled,
    'workerId': draft.workerId,
    'billDate': draft.date.toIso8601String(),
    'deliverDate': draft.deliveryDate?.toIso8601String(),
    'remark': draft.remark.text,
    'rows': [
      for (final row in draft.lines)
        {
          'planItemId': row.line.planItemId,
          'itemId': row.draftItemId,
          'sourceIdentity': _sourceIdentity(row),
          'qty': row.qty.text,
          'qtyAutofilled': row.qty.autofilled,
          'weight': weightEntryDraft(row.weight.weight, qty: row.qty),
          'remark': row.remarkController.text,
          'selected': row.selected,
        },
    ],
  };

  @override
  Map<String, dynamic> captureFormDraft() => {
    'issueIds': widget.issueIds,
    'selectedItemIds': widget.selectedItemIds,
    'completed': _completedIssueIds.toList(),
    'submittedIssueIds': _submittedDraftIds.toList(),
    'changed': _changed,
    'atomicCommands': _atomicCommands,
    'atomicSourceScopes': _atomicSourceScopes,
    'atomicUnknownIds': _atomicUnknownIds.toList(),
    'documents': [
      for (final draft in _drafts)
        _retainedUncertainInputs[draft.document.id] ?? _captureInput(draft),
      for (final entry in _retainedUncertainInputs.entries)
        if (!_drafts.any((draft) => draft.document.id == entry.key))
          entry.value,
      for (final entry in _opaqueSourceInputs.entries)
        if (!_drafts.any((draft) => draft.document.id == entry.key) &&
            !_retainedUncertainInputs.containsKey(entry.key))
          entry.value,
    ],
  };

  void _restoreAtomicCommands(Map<String, dynamic> data, Set<String> sources) {
    final raw = data['atomicCommands'];
    if (raw == null) return;
    if (raw is! Map) throw const FormatException('原出仓命令不完整，请保留草稿');
    final scope = WarehouseTaskItemSelection(widget.selectedItemIds);
    for (final entry in raw.entries) {
      if (entry.key is! String ||
          !sources.contains(entry.key) ||
          entry.value is! Map) {
        throw const FormatException('原出仓命令与当前来源不一致，请保留草稿');
      }
      final command = Map<String, dynamic>.from(entry.value as Map);
      final ids = draftStrings(command['itemIds']);
      if (command['idempotencyKey'] is! String ||
          !RegExp(
            r'^[A-Za-z0-9._:-]{8,128}$',
          ).hasMatch(command['idempotencyKey'] as String) ||
          command['fingerprint'] is! String ||
          !RegExp(
            r'^[a-f0-9]{64}$',
          ).hasMatch(command['fingerprint'] as String) ||
          command['document'] is! Map ||
          command['itemIds'] is! List ||
          (command['itemIds'] as List).length != ids.length ||
          ids.isEmpty ||
          ids.length > 500 ||
          ids.length != ids.toSet().length ||
          !ids.every(scope.contains)) {
        throw const FormatException('原出仓内容或所选明细不完整，请保留草稿');
      }
      final document = command['document'] as Map;
      final rawItems = document['items'];
      final postedIds = rawItems is List
          ? [
              for (final item in rawItems)
                if (item is Map) item['id'],
            ]
          : const <Object?>[];
      if (rawItems is! List ||
          rawItems.length != ids.length ||
          postedIds.length != ids.length ||
          !setEquals(postedIds.toSet(), ids.toSet())) {
        throw const FormatException('原出仓请求的明细身份不完整，请保留草稿');
      }
      _atomicCommands[entry.key as String] = command;
      final scopes = data['atomicSourceScopes'];
      final rawScope = scopes is Map ? scopes[entry.key] : null;
      final sourceIds = rawScope == null ? ids : draftStrings(rawScope);
      if ((rawScope != null &&
              (rawScope is! List || rawScope.length != sourceIds.length)) ||
          sourceIds.isEmpty ||
          sourceIds.length != sourceIds.toSet().length ||
          !sourceIds.every(scope.contains) ||
          !ids.every(sourceIds.contains)) {
        throw const FormatException('原出仓来源与所选范围映射不完整，请保留草稿');
      }
      _atomicSourceScopes[entry.key as String] = sourceIds;
    }
    for (final saved in draftMaps(data['documents'])) {
      final id = saved['issueId'];
      if (id is String && _atomicCommands.containsKey(id)) {
        _retainedUncertainInputs[id] = {...saved};
      }
    }
  }

  void _requireAtomicResult(String sourceId, Map<String, dynamic> result) {
    final command = _atomicCommands[sourceId];
    final expected = draftStrings(command?['itemIds']).toSet();
    final actual = draftStrings(result['itemIds']);
    if (command == null ||
        result['sourceIssueId'] != sourceId ||
        result['status'] != 1 ||
        result['executionIssueId'] is! String ||
        (result['executionIssueId'] as String).isEmpty ||
        actual.length != expected.length ||
        result['itemIds'] is! List ||
        (result['itemIds'] as List).length != actual.length ||
        !setEquals(actual.toSet(), expected)) {
      throw const FormatException('服务器回执未完整确认原出仓明细，请保留原操作并核对');
    }
  }

  void _confirmAtomicResult(String sourceId, Map<String, dynamic> result) {
    _requireAtomicResult(sourceId, result);
    _completedIssueIds.add(sourceId);
    _atomicUnknownIds.remove(sourceId);
    _atomicReadableSources.remove(sourceId);
    _atomicReadProblems.remove(sourceId);
    _opaqueSourceInputs.remove(sourceId);
    _retainedUncertainInputs.remove(sourceId);
    for (final draft in _drafts.where(
      (draft) => draft.document.id == sourceId,
    )) {
      draft.state = SubcontractOutboundExecutionState.completed;
      draft.error = null;
    }
    _changed = true;
  }

  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    if ((draftStrings(data['selectedItemIds'])..sort()).join(',') !=
        ((widget.selectedItemIds ?? []).toList()..sort()).join(',')) {
      throw const FormatException('原出仓草稿的所选明细与当前不一致，请返回任务中心核对');
    }
    _submittedDraftIds = draftStrings(data['submittedIssueIds']).toSet();
    _changed = _changed || data['changed'] == true;
    final byId = {for (final draft in _drafts) draft.document.id: draft};
    for (final saved in draftMaps(data['documents'])) {
      final id = saved['issueId'];
      if (_completedIssueIds.contains(id)) continue;
      final draft = byId[id];
      if (draft == null && _atomicUnknownIds.contains(id)) {
        _retainedUncertainInputs[id as String] = {...saved};
        continue;
      }
      if (draft == null &&
          _recoveryOnly &&
          _opaqueSourceInputs.containsKey(id)) {
        // Unavailable neighbours retain their opaque input and original scope.
        // They never become rows or new commands using a local snapshot.
        continue;
      }
      if (draft == null) throw const FormatException('领料单来源已变化，原填写草稿继续保留');
      final unknown = const [
        'saving',
        'approving',
        'needsVerification',
      ].contains(saved['state']);
      if (unknown) {
        draft.state = SubcontractOutboundExecutionState.needsVerification;
        draft.error = '上次提交结果待核对，请先核对出仓结果，不能重新发送';
        _retainedUncertainInputs[draft.document.id] = {
          ...saved,
          'state': SubcontractOutboundExecutionState.needsVerification.name,
        };
      } else if (!subcontractOutboundSnapshotMatches(
        saved['serverFingerprint'],
        subcontractOutboundDraftFingerprint(draft.document),
      )) {
        throw const FormatException('领料单被其他人修改过，原填写草稿继续保留；请核对最新领料单');
      }
      final savedRows = draftMaps(saved['rows']);
      final rows = {for (final row in draft.lines) row.line.planItemId: row};
      final matches =
          rows.length == draft.lines.length &&
          savedRows.length == draft.lines.length &&
          savedRows.map((row) => row['planItemId']).toSet().length ==
              savedRows.length &&
          savedRows.every((value) {
            final row = rows[value['planItemId']];
            return row != null &&
                value['sourceIdentity'] is Map &&
                subcontractOutboundSnapshotMatches(
                  (value['sourceIdentity'] as Map).cast<String, dynamic>(),
                  _sourceIdentity(row),
                );
          });
      if (!matches) {
        if (unknown) continue;
        throw const FormatException('领料明细来源已变化，原填写草稿继续保留；禁止按货品猜测恢复');
      }
      draft.warehouseId = saved['warehouseId'] as String?;
      draft.warehouseAutofilled = saved['warehouseAutofilled'] != false;
      draft.workerId = saved['workerId'] as String?;
      draft.date =
          DateTime.tryParse(draftText(saved, 'billDate')) ?? draft.date;
      draft.deliveryDate = DateTime.tryParse(draftText(saved, 'deliverDate'));
      draft.remark.text = draftText(saved, 'remark');
      for (final value in savedRows) {
        final row = rows[value['planItemId']]!;
        if (value['qtyAutofilled'] == true) {
          row.qty.setAutomaticText(draftText(value, 'qty'));
        } else {
          row.qty.text = draftText(value, 'qty');
        }
        restoreWeightEntryDraft(
          row.weight.weight,
          value['weight'],
          qty: row.qty,
        );
        row.remarkController.text = draftText(value, 'remark');
        row.selected = value['selected'] != false;
      }
    }
  }

  // 2026-09-22 全站表格滚动口径：出仓明细表表头吸顶 + 置顶后才显示页面滚动条。
  final ScrollController _pageScroll = ScrollController();
  final _gridPinned = ValueNotifier<bool>(false);

  AppLocalizations get l10n =>
      (Localizations.of<AppLocalizations>(context, AppLocalizations) ??
      AppLocalizationsZh());

  bool get _canExecute {
    final permissions = ref.read(currentPermissionsProvider);
    return [
      Perm.subcontractOutboundView,
      Perm.subcontractOutboundExecute,
      Perm.subcontractMaterialIssueView,
      Perm.subcontractMaterialIssueEdit,
      Perm.subcontractMaterialIssueApprove,
    ].every(permissions.contains);
  }

  @override
  void initState() {
    super.initState();
    startFormDraftIdentityGuard();
    ref.listenManual(currentPermissionsProvider, (old, next) {
      if (old != null && !setEquals(old, next)) invalidateFormDraftIdentity();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    for (final draft in _drafts) {
      draft.dispose();
    }
    _pageScroll.dispose();
    _gridPinned.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_saving) return;
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _error = null;
    });
    final loaded = <_BatchDraft>[];
    Map<String, dynamic>? atomicRecoveryData;
    final atomicReadbacks = <String, Map<String, dynamic>?>{};
    try {
      final ids = widget.issueIds.where((id) => id.isNotEmpty).toSet().toList();
      if (ids.isEmpty) {
        throw FormatException(l10n.warehouseSubcontractOutboundSelectRequired);
      }
      if (ids.length > 50) {
        throw FormatException(l10n.warehouseSubcontractOutboundSelectionLimit);
      }
      final taskRepo = ref.read(warehouseSubcontractOutboundRepositoryProvider);
      final docRepo = ref.read(
        subcontractRepositoryProvider(SubcontractDocType.materialIssue),
      );
      final requestScope = await captureFormDraftRequestScope();
      await ref.read(formDraftsProvider.notifier).ready;
      if (!mounted || !formDraftIdentityIsCurrent) return;
      final resumeId = goRouterPageStateOrNull(
        context,
      )?.uri.queryParameters['draftId'];
      final resume = ref
          .read(formDraftsProvider)
          .where((draft) => draft.id == resumeId)
          .firstOrNull;
      final savedCompleted = resume == null
          ? <String>{}
          : draftStrings(resume.data['completed']).toSet();
      final savedIds = resume == null
          ? <String>{}
          : draftStrings(resume.data['issueIds']).toSet();
      if (resume != null &&
          (!setEquals(savedIds, ids.toSet()) ||
              !formDraftSpec.canRestore(
                resume,
                currentRoute: formDraftSpec.route,
              ))) {
        throw const FormatException('本机草稿不是这批领料单，不能跨任务恢复');
      }
      if (resume != null) _restoreAtomicCommands(resume.data, ids.toSet());
      if (resume != null && _atomicEntry && _atomicCommands.isNotEmpty) {
        atomicRecoveryData = resume.data;
        _completedIssueIds
          ..clear()
          ..addAll(savedCompleted.where(_atomicCommands.containsKey));
        _atomicUnknownIds
          ..clear()
          ..addAll(
            _atomicCommands.keys.where((id) => !savedCompleted.contains(id)),
          );
      }
      _atomicReadableSources.clear();
      _atomicReadProblems.clear();
      // A moved selected item no longer belongs to the source draft. Its own
      // command receipt must be resolved before reading or validating source remainder.
      for (final entry in _atomicCommands.entries) {
        try {
          atomicReadbacks[entry.key] = await requestScope.run(
            () => _readAtomicReceipt(docRepo, entry.key),
          );
        } catch (_) {
          if (atomicRecoveryData == null) rethrow;
          atomicReadbacks[entry.key] = null;
        }
        if (!mounted ||
            !formDraftIdentityIsCurrent ||
            generation != _loadGeneration) {
          return;
        }
      }
      if (_atomicReadProblems.isNotEmpty) {
        throw const FormatException('原提交当前无法读取，请保留原操作后重新核对');
      }
      final readableIds = ids
          .where(
            (id) =>
                !_completedIssueIds.contains(id) &&
                !_atomicCommands.containsKey(id),
          )
          .toList();
      final fingerprints = <String, String>{};
      final documents = await requestScope.run(
        () => readOutboundInBatches(readableIds, (id) async {
          if (!_atomicEntry) return docRepo.detail(id);
          final review = await docRepo.selectedOutboundReview(id);
          fingerprints[id] = review.fingerprint;
          return review.document;
        }),
      );
      if (!mounted ||
          generation != _loadGeneration ||
          !formDraftIdentityIsCurrent) {
        return;
      }
      final remainingIds = <String>[];
      for (final document in documents) {
        if (document.status == 1 && resume != null) {
          _completedIssueIds.add(document.id);
        } else if (savedCompleted.contains(document.id) ||
            document.status != 0) {
          throw FormatException(l10n.warehouseSubcontractOutboundChanged);
        } else {
          remainingIds.add(document.id);
        }
      }
      final results = await requestScope.run(
        () => Future.wait([
          ref.read(masterNameServiceProvider).ensureWarehousesLoaded(),
          readOutboundInBatches(remainingIds, taskRepo.taskDetail),
        ]),
      );
      if (!mounted ||
          generation != _loadGeneration ||
          !formDraftIdentityIsCurrent) {
        return;
      }
      final documentById = {
        for (final document in documents) document.id: document,
      };
      final bundles = [
        for (final task in results[1] as List<OutboundTaskDetail>)
          SubcontractOutboundReadBundle(
            task: task,
            document: documentById[task.issueId]!,
          ),
      ];
      final weightUnit = ref.read(warehouseWeightUnitsPrefsProvider).entry;
      final frozenIds = _atomicSourceScopes.values.expand((ids) => ids).toSet();
      final remainingSelection = widget.selectedItemIds
          ?.where((id) => !frozenIds.contains(id))
          .toList();
      final selection = WarehouseTaskItemSelection(remainingSelection);
      if (remainingSelection?.isNotEmpty != false) {
        selection.validate(
          bundles
              .expand((bundle) => bundle.document.items)
              .map((item) => item.id),
        );
      } else if (bundles.isNotEmpty) {
        throw const FormatException('原出仓范围与剩余单据不一致，请先核对原回执');
      }
      final defaultWorker = ref.read(sessionProvider).user?.employeeId;
      for (final bundle in bundles) {
        final document = bundle.document;
        if (document.status != 0) {
          throw FormatException(l10n.warehouseSubcontractOutboundChanged);
        }
        // 拣货行与草稿明细按草稿明细 id 一一对上; 对不上即单据已变, 不按货品猜行。
        final lines = subcontractOutboundLinesOf(
          bundle.task,
          document,
          weightUnit: weightUnit,
        );
        if (lines == null) {
          throw FormatException(l10n.warehouseSubcontractOutboundChanged);
        }
        for (final line in lines) {
          line.selected = selection.contains(line.draftItemId);
        }
        loaded.add(
          _BatchDraft(
            detail: bundle.task,
            document: document,
            lines: lines,
            workerId: document.workerId ?? defaultWorker,
            reviewFingerprint: fingerprints[document.id],
          ),
        );
      }
      final user = ref.read(sessionProvider).user;
      if (user?.employeeId != null && user!.name.isNotEmpty) {
        _employees[user.employeeId!] = UtenEmployeePickerItem(
          id: user.employeeId!,
          name: user.name,
          departmentName: user.department,
        );
      }
      setState(() {
        for (final draft in _drafts) {
          draft.dispose();
        }
        _drafts
          ..clear()
          ..addAll(loaded);
      });
      unawaited(
        _preloadEmployees(loaded.map((draft) => draft.workerId), generation),
      );
      await initializeFormDraft();
      if (formDraftRestorationBlocked || !formDraftIdentityIsCurrent) return;
      _applyAtomicReadbacks(atomicReadbacks);
      if (atomicReadbacks.isNotEmpty) await checkpointFormDraftAfterCreation();
      if (_allOriginalSourcesCompleted &&
          _atomicUnknownIds.isEmpty &&
          mounted) {
        await _finishCompletedSubmission();
      }
    } catch (error) {
      for (final draft in loaded) {
        if (!_drafts.contains(draft)) draft.dispose();
      }
      if (mounted &&
          generation == _loadGeneration &&
          formDraftIdentityIsCurrent) {
        if (atomicRecoveryData != null) {
          _activateAtomicRecovery(atomicRecoveryData);
          await initializeFormDraft();
          if (formDraftRestorationBlocked || !formDraftIdentityIsCurrent) {
            return;
          }
          _applyAtomicReadbacks(atomicReadbacks);
          await checkpointFormDraftAfterCreation();
          if (mounted && formDraftIdentityIsCurrent) setState(() {});
        } else {
          setState(() => _error = _message(error));
        }
      }
    } finally {
      if (mounted &&
          generation == _loadGeneration &&
          formDraftIdentityIsCurrent) {
        setState(() => _loading = false);
      }
    }
  }

  Future<Map<String, dynamic>?> _readAtomicReceipt(
    SubcontractRepository repo,
    String sourceId,
  ) async {
    try {
      final receipt = await repo.selectedOutboundReceipt(
        sourceId,
        _atomicCommands[sourceId]!['idempotencyKey'] as String,
      );
      if (receipt == null) {
        // An absent receipt proves neither an unsent command nor current object
        // visibility. Read the original object without requiring pending state.
        final current = await repo.detail(sourceId);
        if (current.id != sourceId) throw const FormatException('原来源身份不一致');
      } else {
        _requireAtomicResult(sourceId, receipt);
      }
      if (!formDraftIdentityIsCurrent) throw StateError('登录身份已变化');
      _atomicReadableSources.add(sourceId);
      _atomicReadProblems.remove(sourceId);
      return receipt;
    } catch (_) {
      _atomicReadableSources.remove(sourceId);
      _atomicReadProblems[sourceId] = '当前无法读取此来源，原内容仍保留，暂停重试';
      rethrow;
    }
  }

  void _applyAtomicReadbacks(Map<String, Map<String, dynamic>?> readbacks) {
    for (final entry in readbacks.entries) {
      if (entry.value case final result?) {
        _confirmAtomicResult(entry.key, result);
      } else {
        _completedIssueIds.remove(entry.key);
        _atomicUnknownIds.add(entry.key);
      }
    }
  }

  void _activateAtomicRecovery(Map<String, dynamic> original) {
    _recoveryOnly = true;
    _error = null;
    for (final saved in draftMaps(original['documents'])) {
      final id = saved['issueId'];
      if (id is String &&
          widget.issueIds.contains(id) &&
          !_atomicCommands.containsKey(id) &&
          !_completedIssueIds.contains(id)) {
        _opaqueSourceInputs[id] = {...saved};
      }
    }
    for (final draft in _drafts) {
      draft.dispose();
    }
    _drafts.clear();
  }

  Future<void> _preloadEmployees(
    Iterable<String?> workerIds,
    int generation,
  ) async {
    final ids = workerIds
        .whereType<String>()
        .where((id) => id.isNotEmpty && !_employees.containsKey(id))
        .toSet()
        .toList();
    final repo = ref.read(employeeRepositoryProvider);
    await readOutboundInBatches(ids, (id) async {
      try {
        final employee = await repo.getById(id);
        if (!mounted ||
            generation != _loadGeneration ||
            !formDraftIdentityIsCurrent) {
          return;
        }
        setState(
          () => _employees[id] = UtenEmployeePickerItem(
            id: employee.id,
            name: employee.fullName ?? '',
            employeeCode: employee.code,
            accountStatus: employee.accountDeleted
                ? 'notProvisioned'
                : employee.accountStatus ?? 'notProvisioned',
            employmentStatus: employee.status,
            departmentId: employee.departmentId,
            departmentName: employee.departmentName,
          ),
        );
      } catch (_) {
        // Display lookup cannot block task review or discard the original UUID.
      }
    });
  }

  Future<void> _finishCompletedSubmission() async {
    if (_atomicUnknownIds.isNotEmpty ||
        (_recoveryOnly && !_allOriginalSourcesCompleted)) {
      await saveFormDraftNow();
      return;
    }
    if (_allOriginalSourcesCompleted) {
      await completeFormDraft();
    } else {
      await saveFormDraftNow();
      if (!mounted || !formDraftIdentityIsCurrent) return;
      _savedExitReady =
          widget.onCompleted != null ||
          GoRouter.maybeOf(context) != null ||
          Navigator.of(context).canPop();
    }
    if (!mounted || !formDraftIdentityIsCurrent) return;
    setState(() {
      _saving = false;
      _confirming = false;
    });
    if (widget.onCompleted != null) {
      widget.onCompleted!();
    } else if (GoRouter.maybeOf(context) != null) {
      returnToSubcontractOutboundTasks(context);
    } else if (Navigator.of(context).canPop()) {
      unawaited(Navigator.of(context).maybePop(true));
    }
  }

  String _message(Object error) => switch (error) {
    ApiException() => error.message,
    FormatException() => error.message,
    _ => l10n.warehouseSubcontractOutboundLoadFailed,
  };

  String _date(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  String? _validate(_BatchDraft draft, {bool selectedOnly = false}) {
    if (draft.warehouseId == null ||
        (draft.warehouseId != draft.document.warehouseId &&
            !WarehouseSelection(
              ref.read(masterNameServiceProvider).warehouseHierarchy,
              use: WarehouseUse.goodOut,
            ).selectableIds.contains(draft.warehouseId))) {
      return l10n.warehouseSubcontractOutboundWarehouseRequired;
    }
    final lines = draft.lines
        .where((line) => !selectedOnly || line.selected)
        .toList();
    for (final line in lines) {
      final error = line.validate();
      if (error != null) {
        return '${line.line.goodsName ?? line.line.goodsCode ?? ''}: $error';
      }
    }
    if (lines.every((line) => line.skipped)) {
      if (selectedOnly) return '所选明细数量均为0，本次没有可出库明细；这些行继续保留在原单待发';
      return '每行都填了 0。$subcontractOutboundNothingToIssue(先取消勾选这张单，再打开它的拣货页办理)';
    }
    return null;
  }

  Future<void> _submit() async {
    if (_atomicEntry) return _submitSelected();
    try {
      final scope = await captureFormDraftRequestScope();
      await scope.run(_submitLegacy);
    } catch (error) {
      if (mounted && formDraftIdentityIsCurrent) {
        context.appError(_message(error));
      }
    }
  }

  Map<String, dynamic> _selectedDocument(_BatchDraft draft) => {
    'billDate': _date(draft.date),
    'supplierId': draft.document.supplierId,
    'warehouseId': draft.warehouseId,
    'workerId': draft.workerId,
    'deliverDate': draft.deliveryDate == null
        ? null
        : _date(draft.deliveryDate!),
    'remark': draft.remark.text.trim().isEmpty
        ? null
        : draft.remark.text.trim(),
    'items': subcontractOutboundPayloadItems(
      draft.lines.where((line) => line.selected).toList(),
    ),
  };

  Future<void> _submitSelected() async {
    if (_saving ||
        _confirming ||
        _recoveryOnly ||
        formDraftRestorationBlocked ||
        !_canExecute ||
        !formDraftIdentityIsCurrent) {
      return;
    }
    final targets = _drafts
        .where((draft) => draft.pending && draft.selected)
        .toList();
    if (targets.isEmpty) return;
    for (final draft in targets) {
      if (draft.lines.where((line) => line.selected && !line.skipped).length >
          500) {
        context.appError('每张领料单一次最多出库500条明细');
        return;
      }
      final error = _validate(draft, selectedOnly: true);
      if (error != null) {
        context.appError(error);
        return;
      }
    }
    setState(() => _confirming = true);
    try {
      final scope = await captureFormDraftRequestScope();
      await scope.run(() async {
        final positiveCount = targets.fold<int>(
          0,
          (count, draft) =>
              count +
              draft.lines
                  .where((line) => line.selected && !line.skipped)
                  .length,
        );
        final confirmed = await showUtenReviewerConfirmDialog(
          context,
          title: l10n.warehouseSubcontractOutboundBatchConfirm,
          confirmLabel: l10n.warehouseSubcontractOutboundBatchConfirm,
          actionLabel: l10n.warehouseSubcontractOutboundBatchAction,
          responsibilityDescription:
              l10n.warehouseSubcontractOutboundConfirmResponsibility,
          message:
              '本次出库$positiveCount项正数明细，交委外商加工。填0和未选行及其预留继续保留在原领料单待发。\n\n委外商加工完成后交回委外件，仍需登记和品质检查，合格后正式入仓。',
        );
        if (!confirmed || !mounted || !_canExecute) return;
        await scope.verify();
        setState(() {
          _confirming = false;
          _saving = true;
        });
        final repo = ref.read(
          subcontractRepositoryProvider(SubcontractDocType.materialIssue),
        );
        _submittedDraftIds = targets.map((draft) => draft.document.id).toSet();
        for (final draft in targets) {
          if (!mounted || !formDraftIdentityIsCurrent || !_canExecute) break;
          final id = draft.document.id;
          var dispatched = false;
          try {
            final fresh = await repo.selectedOutboundReview(id);
            if (!mounted || !formDraftIdentityIsCurrent) break;
            if (fresh.fingerprint != draft.reviewFingerprint) {
              throw FormatException(l10n.warehouseSubcontractOutboundChanged);
            }
            _atomicReadableSources.add(id);
            final command =
                jsonDecode(
                      jsonEncode({
                        'idempotencyKey': const Uuid().v4(),
                        'fingerprint': fresh.fingerprint,
                        'itemIds': draft.lines
                            .where((line) => line.selected && !line.skipped)
                            .map((line) => line.draftItemId)
                            .toList(),
                        'document': _selectedDocument(draft),
                      }),
                    )
                    as Map<String, dynamic>;
            _atomicCommands[id] = command;
            final routeScope = WarehouseTaskItemSelection(
              widget.selectedItemIds,
            );
            _atomicSourceScopes[id] = draft.lines
                .where((line) => routeScope.contains(line.draftItemId))
                .map((line) => line.draftItemId)
                .toList();
            _atomicUnknownIds.add(id);
            draft.state = SubcontractOutboundExecutionState.saving;
            _retainedUncertainInputs[id] = _captureInput(draft);
            await saveFormDraftNow();
            if (formDraftRecoveryRevision == null) {
              throw const FormatException('原出仓内容尚未持久保存，本次未发送，请稍后重试');
            }
            await scope.verify();
            if (!mounted || !_canExecute) break;
            dispatched = true;
            final result = await repo.submitSelectedOutbound(id, command);
            if (!mounted || !formDraftIdentityIsCurrent) break;
            _confirmAtomicResult(id, result);
            await checkpointFormDraftAfterCreation();
          } catch (error) {
            if (!mounted || !formDraftIdentityIsCurrent) break;
            _changed = _changed || dispatched;
            final rejected =
                error is ApiException &&
                error.httpStatus != null &&
                error.httpStatus! >= 400 &&
                error.httpStatus! < 500 &&
                error.httpStatus != 408;
            if (!dispatched || rejected) {
              _atomicCommands.remove(id);
              _atomicSourceScopes.remove(id);
              _atomicUnknownIds.remove(id);
              _atomicReadableSources.remove(id);
              _retainedUncertainInputs.remove(id);
              draft.state = SubcontractOutboundExecutionState.blocked;
            } else {
              draft.state = SubcontractOutboundExecutionState.needsVerification;
              _retainedUncertainInputs[id] = {
                ..._retainedUncertainInputs[id]!,
                'state': draft.state.name,
              };
            }
            draft.error = _atomicUnknownIds.contains(id)
                ? '原出仓结果待核对；原请求内容和编号已保留，不会办理未选明细'
                : _message(error);
            await checkpointFormDraftAfterCreation();
            break;
          }
        }
        if (!mounted || !formDraftIdentityIsCurrent) return;
        setState(() {});
        invalidateWarehouseTaskCounts(ref);
        if (_atomicUnknownIds.isEmpty &&
            targets.every(
              (draft) => _completedIssueIds.contains(draft.document.id),
            )) {
          await _finishCompletedSubmission();
        }
      });
    } catch (error) {
      if (mounted && formDraftIdentityIsCurrent) {
        context.appError(_message(error));
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _confirming = false;
        });
      }
    }
  }

  Future<void> _retryAtomic() async {
    if (_saving ||
        _confirming ||
        formDraftRestorationBlocked ||
        !_canExecute ||
        !formDraftIdentityIsCurrent) {
      return;
    }
    setState(() => _saving = true);
    try {
      final scope = await captureFormDraftRequestScope();
      await scope.run(() async {
        final repo = ref.read(
          subcontractRepositoryProvider(SubcontractDocType.materialIssue),
        );
        for (final id in _atomicUnknownIds.toList()) {
          var readable = false;
          try {
            final receipt = await _readAtomicReceipt(repo, id);
            await scope.verify();
            readable = true;
            _changed = true;
            final result =
                receipt ??
                await repo.submitSelectedOutbound(id, _atomicCommands[id]!);
            if (!mounted || !formDraftIdentityIsCurrent) return;
            _confirmAtomicResult(id, result);
          } catch (error) {
            if (!mounted || !formDraftIdentityIsCurrent) return;
            if (!readable) _activateAtomicRecovery(captureFormDraft());
            context.appError(
              readable ? _message(error) : '原来源当前不可读取，原操作和范围继续保留',
            );
          }
          await checkpointFormDraftAfterCreation();
        }
        invalidateWarehouseTaskCounts(ref);
        if (_atomicUnknownIds.isEmpty &&
            widget.issueIds.every(_completedIssueIds.contains)) {
          await _finishCompletedSubmission();
        }
      });
    } catch (error) {
      if (mounted && formDraftIdentityIsCurrent) {
        context.appError(_message(error));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _submitLegacy() async {
    if (_saving || _confirming || !_canExecute) return;
    final targets = _drafts
        .where((draft) => draft.pending && draft.selected)
        .toList();
    if (targets.isEmpty) {
      context.appWarning(l10n.warehouseSubcontractOutboundSelectRequired);
      return;
    }
    for (final target in targets) {
      if (target.lines.any((line) => !line.selected)) {
        context.appWarning('该领料单需整单确认，请返回任务中心选齐同单明细；本次未保存或出库');
        return;
      }
      final error = _validate(target);
      if (error != null) {
        context.appError('${target.detail.orderBillNo ?? ''}: $error');
        return;
      }
    }
    setState(() => _confirming = true);
    try {
      final confirmed = await showUtenReviewerConfirmDialog(
        context,
        title: l10n.warehouseSubcontractOutboundBatchConfirm,
        confirmLabel: l10n.warehouseSubcontractOutboundBatchConfirm,
        actionLabel: l10n.warehouseSubcontractOutboundBatchAction,
        responsibilityDescription:
            l10n.warehouseSubcontractOutboundConfirmResponsibility,
        message:
            '$subcontractOutboundApproveEffects\n\n${l10n.warehouseSubcontractOutboundBatchHint}',
      );
      if (!confirmed || !mounted || !_canExecute) return;
      setState(() {
        _confirming = false;
        _saving = true;
      });
      final repo = ref.read(
        subcontractRepositoryProvider(SubcontractDocType.materialIssue),
      );
      _submittedDraftIds = targets.map((draft) => draft.document.id).toSet();
      for (final draft in targets) {
        if (!mounted || !formDraftIdentityIsCurrent) break;
        var writeStarted = false;
        try {
          // Re-read the exact EC draft. Never overwrite a draft that another
          // employee (or the subcontract side) has changed since it was read.
          final document = draft.document;
          final fresh = await repo.detail(document.id);
          if (!mounted || !formDraftIdentityIsCurrent) break;
          if (subcontractOutboundDraftFingerprint(fresh) !=
              subcontractOutboundDraftFingerprint(document)) {
            throw FormatException(l10n.warehouseSubcontractOutboundChanged);
          }
          setState(
            () => draft.state = SubcontractOutboundExecutionState.saving,
          );
          await saveFormDraftNow();
          if (!mounted || !formDraftIdentityIsCurrent) break;
          writeStarted = true;
          draft.document = await repo.update(document.id, {
            'billDate': _date(draft.date),
            'supplierId': document.supplierId,
            'warehouseId': draft.warehouseId,
            'workerId': draft.workerId,
            // Automatic dates freeze only when the server commits approval.
            'deliverDate': draft.deliveryDate == null
                ? null
                : _date(draft.deliveryDate!),
            'remark': draft.remark.text.trim().isEmpty
                ? null
                : draft.remark.text.trim(),
            // 填 0 的行不回传: 服务端删行并退回它占用的库存。
            'items': subcontractOutboundPayloadItems(draft.lines),
            if (widget.selectedItemIds != null)
              'itemIds': draft.lines.map((line) => line.draftItemId).toList(),
          });
          _changed = true;
          if (!mounted || !formDraftIdentityIsCurrent) break;
          final beforeApproval = await repo.detail(draft.document.id);
          if (!mounted || !formDraftIdentityIsCurrent) break;
          if (subcontractOutboundDraftFingerprint(beforeApproval) !=
              subcontractOutboundDraftFingerprint(draft.document)) {
            throw FormatException(l10n.warehouseSubcontractOutboundChanged);
          }
          setState(
            () => draft.state = SubcontractOutboundExecutionState.approving,
          );
          await saveFormDraftNow();
          if (!mounted || !formDraftIdentityIsCurrent) break;
          final approved = widget.selectedItemIds == null
              ? await repo.approve(draft.document.id)
              : await repo.approveSelected(
                  draft.document.id,
                  draft.document.items
                      .map((item) => item.id)
                      .whereType<String>()
                      .toList(),
                );
          if (!mounted || !formDraftIdentityIsCurrent) break;
          if (approved.status != 1) {
            throw StateError(l10n.warehouseSubcontractOutboundUncertain);
          }
          draft.document = approved;
          setState(() {
            draft.state = SubcontractOutboundExecutionState.completed;
            draft.error = null;
            _completedIssueIds.add(draft.document.id);
            _retainedUncertainInputs.remove(draft.document.id);
          });
          await saveFormDraftNow();
        } catch (error) {
          if (!mounted || !formDraftIdentityIsCurrent) break;
          final uncertain =
              writeStarted &&
              error is! FormatException &&
              !(error is ApiException &&
                  error.httpStatus != null &&
                  error.httpStatus! >= 400 &&
                  error.httpStatus! < 500);
          setState(() {
            draft.state = uncertain
                ? SubcontractOutboundExecutionState.needsVerification
                : SubcontractOutboundExecutionState.blocked;
            draft.error = uncertain
                ? l10n.warehouseSubcontractOutboundUncertain
                : _message(error);
          });
          _changed = _changed || writeStarted;
          await checkpointFormDraftAfterCreation();
          break;
        }
      }
      if (!mounted) return;
      invalidateWarehouseTaskCounts(ref);
      final completed = _drafts
          .where(
            (draft) =>
                draft.state == SubcontractOutboundExecutionState.completed,
          )
          .length;
      context.appInfo(
        l10n.warehouseSubcontractOutboundBatchResult(completed, _drafts.length),
      );
      if (targets.every(
        (draft) => draft.state == SubcontractOutboundExecutionState.completed,
      )) {
        await _finishCompletedSubmission();
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _confirming = false;
        });
      }
    }
  }

  Future<void> _verify() async {
    if (_saving) return;
    try {
      final scope = await captureFormDraftRequestScope();
      await scope.run(_verifyScoped);
    } catch (error) {
      if (mounted && formDraftIdentityIsCurrent) {
        context.appError(_message(error));
      }
    }
  }

  Future<void> _verifyScoped() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final repo = ref.read(
        subcontractRepositoryProvider(SubcontractDocType.materialIssue),
      );
      for (final id in _atomicUnknownIds.toList()) {
        try {
          final receipt = await _readAtomicReceipt(repo, id);
          if (!mounted || !formDraftIdentityIsCurrent) return;
          if (receipt != null) _confirmAtomicResult(id, receipt);
        } catch (error) {
          if (mounted && formDraftIdentityIsCurrent) {
            _activateAtomicRecovery(captureFormDraft());
            context.appError('原来源当前不可读取，原操作和范围继续保留');
          }
        }
      }
      for (final draft in _drafts.where(
        (draft) =>
            draft.state ==
                SubcontractOutboundExecutionState.needsVerification &&
            !_atomicCommands.containsKey(draft.document.id),
      )) {
        try {
          final fresh = await repo.detail(draft.document.id);
          if (!mounted || !formDraftIdentityIsCurrent) return;
          // A draft still visible after a timeout is not proof that an earlier
          // mutation cannot commit later. Keep it blocked; verification is GET only.
          if (fresh.status == 1) {
            setState(() {
              draft.document = fresh;
              draft.state = SubcontractOutboundExecutionState.completed;
              draft.error = null;
              _completedIssueIds.add(draft.document.id);
              _retainedUncertainInputs.remove(draft.document.id);
            });
          }
        } catch (error) {
          if (mounted) context.appError(_message(error));
        }
      }
      invalidateWarehouseTaskCounts(ref);
      await checkpointFormDraftAfterCreation();
      if (mounted &&
          _submittedDraftIds.isNotEmpty &&
          _submittedDraftIds.every(
            (id) =>
                _drafts.any(
                  (draft) =>
                      draft.document.id == id &&
                      draft.state ==
                          SubcontractOutboundExecutionState.completed,
                ) ||
                _completedIssueIds.contains(id),
          )) {
        context.appSuccess(l10n.warehouseSubcontractOutboundDone);
        await _finishCompletedSubmission();
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _confirming = false;
        });
      }
    }
  }

  String _status(_BatchDraft draft) => switch (draft.state) {
    SubcontractOutboundExecutionState.pending =>
      l10n.warehouseSubcontractOutboundPending,
    SubcontractOutboundExecutionState.saving ||
    SubcontractOutboundExecutionState.approving => l10n.commonLoading,
    SubcontractOutboundExecutionState.completed =>
      _atomicEntry
          ? '本次已出库${draftStrings(_atomicCommands[draft.document.id]?['itemIds']).length}项'
          : l10n.warehouseSubcontractOutboundDone,
    _ => l10n.warehouseSubcontractOutboundPaused,
  };

  String _rowStatus(_BatchDraft draft, SubcontractOutboundLineDraft line) {
    if (_atomicEntry) {
      final command = _atomicCommands[draft.document.id];
      if ((command != null &&
              !draftStrings(command['itemIds']).contains(line.draftItemId)) ||
          (command == null && (!line.selected || line.skipped))) {
        return '继续待发';
      }
      if (draft.state == SubcontractOutboundExecutionState.completed) {
        return l10n.warehouseSubcontractOutboundDone;
      }
    }
    return _status(draft);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    final names = ref.watch(masterNameServiceProvider);
    final pending =
        !_recoveryOnly &&
        !formDraftRestorationBlocked &&
        _drafts.any((draft) => draft.pending && draft.selected);
    return withFormDraft(
      PopScope(
        canPop: !_saving && !_confirming,
        child: Scaffold(
          appBar: UtenAppBar(
            title: l10n.warehouseSubcontractOutboundBatchTitle,
            leading: UtenBackButton(
              enabled: !(_saving || _confirming),
              onPressed: () => Navigator.of(context).pop(_changed),
            ),
          ),
          body: Stack(
            children: [
              Positioned.fill(
                child: SafeArea(
                  child: UtenContentContainer.wide(
                    child: _loading
                        ? const Center(child: CircularProgressIndicator())
                        : _error != null
                        ? UtenEmpty.error(
                            message: _error,
                            actionLabel: l10n.commonRetry,
                            onAction: _load,
                          )
                        : AbsorbPointer(
                            absorbing: _saving || _confirming,
                            child: UtenGridPageScrollbar(
                              pinned: _gridPinned,
                              controller: _pageScroll,
                              child: UtenPageEdgePadding.scroll(
                                padding: const EdgeInsets.fromLTRB(
                                  UtenSpacing.s12,
                                  UtenSpacing.s16,
                                  UtenSpacing.s12,
                                  UtenFloatingActionGroup.scrollClearance,
                                ),
                                builder: (context, resolvedPagePadding) => ListView(
                                  controller: _pageScroll,
                                  padding: resolvedPagePadding,
                                  children: [
                                    if (_recoveryOnly)
                                      _atomicRecoverySummary()
                                    else
                                      _headers(),
                                    if (_atomicUnknownIds.isNotEmpty)
                                      const Text(
                                        '原出仓结果待核对，原内容和操作编号继续保留；未查到回执不能视为未提交',
                                      ),
                                    if (!_atomicEntry &&
                                        _drafts.any(
                                          (draft) => draft.lines.any(
                                            (line) =>
                                                !WarehouseTaskItemSelection(
                                                  widget.selectedItemIds,
                                                ).contains(line.draftItemId),
                                          ),
                                        ))
                                      Text(
                                        '该领料单需整单确认，请返回任务中心选齐同单明细',
                                        style: TextStyle(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.error,
                                        ),
                                      ),
                                    for (final draft in _drafts)
                                      if (draft.error != null)
                                        Padding(
                                          padding: const EdgeInsets.symmetric(
                                            vertical: UtenSpacing.s8,
                                          ),
                                          child: Text(
                                            '${draft.detail.orderBillNo ?? '—'}: ${draft.error}',
                                            style: TextStyle(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.error,
                                            ),
                                          ),
                                        ),
                                    // 明细表紧接单据卡，不再写「出库明细」标题:
                                    // 页面本身就叫批量出库详情，表头已说明每列是什么。
                                    if (!_recoveryOnly) ...[
                                      const SizedBox(height: UtenSpacing.s16),
                                      SubcontractOutboundDetailTable(
                                        quantityHint: _atomicEntry
                                            ? '只能改少，不能超过原领料数量。填0和未选行继续保留在原单待发，本次只出库勾选的正数行。'
                                            : subcontractOutboundQuantityHint,
                                        stickyHeaderPinned: _gridPinned,
                                        rows: [
                                          for (final draft in _drafts)
                                            for (final line in draft.lines)
                                              if (WarehouseTaskItemSelection(
                                                widget.selectedItemIds,
                                              ).contains(line.draftItemId))
                                                SubcontractOutboundTableRow(
                                                  draft: line,
                                                  warehouse: names.warehouse(
                                                    draft.warehouseId,
                                                  ),
                                                  orderBillNo:
                                                      draft.detail.orderBillNo,
                                                  supplierName:
                                                      draft.detail.supplierName,
                                                  documentNo:
                                                      draft
                                                          .detail
                                                          .issueBillNo ??
                                                      draft.document.billNo,
                                                  documentRemark: draft.remark,
                                                  warehouseId:
                                                      draft.warehouseId,
                                                  warehouseAutofilled:
                                                      draft.warehouseAutofilled,
                                                  warehouses:
                                                      names.warehouseHierarchy,
                                                  onWarehouseChanged: (value) =>
                                                      setState(() {
                                                        draft.warehouseId =
                                                            value;
                                                        draft.warehouseAutofilled =
                                                            false;
                                                      }),
                                                  status: _rowStatus(
                                                    draft,
                                                    line,
                                                  ),
                                                  editable: draft.pending,
                                                ),
                                        ],
                                        editable: _canExecute,
                                        selectable: true,
                                        onRowSelected: (row, selected) {
                                          row.draft.selected = selected;
                                        },
                                        showOrder: true,
                                        onChanged: () => setState(() {}),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                  ),
                ),
              ),
              if (_saving)
                Positioned.fill(
                  child: UtenBusyOverlay(title: l10n.commonLoading),
                ),
            ],
          ),
          floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
          floatingActionButtonAnimator:
              FloatingActionButtonAnimator.noAnimation,
          floatingActionButton: _loading || _error != null
              ? null
              : UtenFloatingActionGroup(
                  children: [
                    UtenButton(
                      type: UtenButtonType.secondary,
                      size: UtenButtonSize.large,
                      onPressed: _saving || _confirming
                          ? null
                          : () => Navigator.of(context).pop(_changed),
                      child: Text(l10n.commonBack),
                    ),
                    if (_atomicUnknownIds.isNotEmpty ||
                        _drafts.any(
                          (draft) =>
                              draft.state ==
                              SubcontractOutboundExecutionState
                                  .needsVerification,
                        ))
                      UtenButton(
                        type: UtenButtonType.secondary,
                        size: UtenButtonSize.large,
                        isLoading: _saving,
                        onPressed: _saving ? null : _verify,
                        child: Text(l10n.warehouseSubcontractOutboundVerify),
                      ),
                    if (_canRetryAtomic)
                      UtenButton(
                        type: UtenButtonType.secondary,
                        size: UtenButtonSize.large,
                        onPressed: _saving ? null : _retryAtomic,
                        child: const Text('按原内容重试'),
                      ),
                    if (_canExecute)
                      UtenButton(
                        key: const Key('subcontract-outbound-batch-confirm'),
                        type: UtenButtonType.danger,
                        size: UtenButtonSize.large,
                        icon: Icons.outbound_outlined,
                        isLoading: _saving,
                        onPressed: pending && !_saving && !_confirming
                            ? _submit
                            : null,
                        child: Text(
                          _changed
                              ? l10n.warehouseSubcontractOutboundContinue
                              : l10n.warehouseSubcontractOutboundBatchConfirm,
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _atomicRecoverySummary() {
    final theme = Theme.of(context);
    return UtenCard(
      key: const Key('subcontract-outbound-atomic-recovery'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('继续核对原提交', style: theme.textTheme.titleMedium),
          const SizedBox(height: UtenSpacing.s8),
          Text(
            '部分来源已变化或当前无法读取。本页保留原来${widget.issueIds.length}张来源及填写，只能核对已提交的原操作；其余来源不会发送，请返回任务中心处理。',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: UtenSpacing.s12),
          for (final id in widget.issueIds)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
              child: Text(
                '来源 $id：${_completedIssueIds.contains(id)
                    ? '原提交已确认'
                    : _atomicUnknownIds.contains(id)
                    ? _atomicReadProblems[id] ?? '原提交待核对，可按原内容重试'
                    : '未提交，暂停办理'}',
                key: ValueKey('subcontract-outbound-recovery-source-$id'),
                style: theme.textTheme.bodyMedium,
              ),
            ),
        ],
      ),
    );
  }

  // 2026-10-10 用户口径：不再套「单据信息(N)」折叠标题，单据卡直接渲染(失去整段折叠)。
  // 列数既按容器宽度算，也不超过卡片张数：只有一张单据时整张卡横铺满屏。
  Widget _headers() => UtenResponsiveGrid(
    key: const Key('subcontract-outbound-document-cards'),
    columns: const UtenResponsiveColumns(medium: 1, expanded: 2),
    maxColumns: _drafts.isEmpty ? 1 : _drafts.length,
    spacing: UtenSpacing.s12,
    itemCount: _drafts.length,
    itemBuilder: (context, index, _) => _documentCard(_drafts[index]),
  );

  Widget _documentCard(_BatchDraft draft) {
    final theme = Theme.of(context);
    final editable = draft.pending && _canExecute;
    return UtenCard(
      key: ValueKey('subcontract-outbound-card-${draft.document.id}'),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: UtenSpacing.s12,
            runSpacing: UtenSpacing.s4,
            children: [
              Text(
                '${l10n.warehouseStockOutboundBillNo}: ${draft.detail.issueBillNo ?? draft.document.billNo ?? '—'}',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                _status(draft),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          Text(
            '${l10n.warehouseSubcontractOutboundOrder}: ${draft.detail.orderBillNo ?? '—'} · ${draft.detail.supplierName ?? '—'}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: UtenSpacing.s12),
          // 卡片铺满屏后字段列数跟着容器宽度走, 不再硬编 2 列 ——
          // 否则出仓日期/经办人会被拉成近千像素的长条。
          UtenFormGrid(
            children: [
              AbsorbPointer(
                absorbing: !editable,
                child: UtenDateField(
                  label: l10n.warehouseSubcontractOutboundDate,
                  value: draft.date,
                  onChanged: (value) => setState(() => draft.date = value),
                ),
              ),
              AbsorbPointer(
                absorbing: !editable,
                child: UtenEmployeePicker(
                  key: ValueKey('${draft.document.id}:${draft.workerId}'),
                  label: l10n.warehouseSubcontractOutboundWorker,
                  initial: _employees[draft.workerId],
                  loader: _loadEmployees,
                  onChanged: (value) => setState(() {
                    draft.workerId = value?.id;
                    if (value != null) _employees[value.id] = value;
                  }),
                ),
              ),
              AbsorbPointer(
                absorbing: !editable,
                child: UtenDateField(
                  label: l10n.warehouseSubcontractOutboundDeliveryDate,
                  value: draft.deliveryDate ?? ChinaDateTime.today(),
                  autofilled: draft.deliveryDate == null,
                  onChanged: (value) =>
                      setState(() => draft.deliveryDate = value),
                ),
              ),
              if (draft.document.createdAt != null)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.warehouseOutboundBatchCreatedAt,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      ChinaDateTime.formatIsoInstant(
                        draft.document.createdAt,
                        fallback: '—',
                      ),
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<List<UtenEmployeePickerItem>> _loadEmployees(String? keyword) async {
    final departmentId = keyword == null || keyword.isEmpty
        ? (ref.read(departmentCodeIdMapProvider).value ?? const {})['SUB_WH']
        : null;
    final result = await ref
        .read(employeeRepositoryProvider)
        .listPickerCandidates(
          size: 30,
          search: keyword,
          departmentId: departmentId,
          includeSubtree: true,
        );
    return [
      for (final employee in result)
        UtenEmployeePickerItem(
          id: employee.id,
          name: employee.fullName,
          employeeCode: employee.code,
          accountStatus: employee.accountStatus,
          employmentStatus: employee.status,
          departmentId: employee.departmentId,
          departmentName: employee.departmentName,
        ),
    ];
  }
}
