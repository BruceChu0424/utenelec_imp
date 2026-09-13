import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../components/layout/uten_collapsible_section.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/l10n/gen/app_localizations_zh.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/widgets/warehouse_selection.dart';
import '../../department/repositories/department_repository.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../subcontract/models/subcontract_doc.dart';
import '../../subcontract/repositories/subcontract_repository.dart';
import '../models/subcontract_outbound.dart';
import '../models/subcontract_outbound_execution.dart';
import '../providers/warehouse_count_refresh.dart';
import '../repositories/warehouse_subcontract_outbound_repository.dart';
import '../repositories/subcontract_outbound_detail_loader.dart';
import '../navigation/warehouse_subcontract_outbound_navigation.dart';
import '../widgets/subcontract_outbound_detail_table.dart';

class WarehouseSubcontractOutboundBatchPage extends ConsumerStatefulWidget {
  const WarehouseSubcontractOutboundBatchPage({
    super.key,
    required this.planIds,
    this.initialBundles,
    this.onCompleted,
  });
  final List<String> planIds;
  final List<SubcontractOutboundReadBundle>? initialBundles;
  final VoidCallback? onCompleted;

  @override
  ConsumerState<WarehouseSubcontractOutboundBatchPage> createState() =>
      _WarehouseSubcontractOutboundBatchPageState();
}

class _BatchDraft {
  _BatchDraft({
    required this.detail,
    required this.lines,
    this.document,
    this.workerId,
  }) : warehouseId = document?.warehouseId,
       date =
           DateTime.tryParse(document?.billDate ?? '') ?? ChinaDateTime.today(),
       deliveryDate = DateTime.tryParse(
         document?.deliverDate ?? detail.deliverDate ?? '',
       ),
       remark = TextEditingController(text: document?.remark ?? '');

  final OutboundTaskDetail detail;
  final List<SubcontractOutboundLineDraft> lines;
  SubcontractDocDetail? document;
  String? warehouseId;
  String? workerId;
  DateTime date;
  DateTime? deliveryDate;
  final TextEditingController remark;
  SubcontractOutboundExecutionState state =
      SubcontractOutboundExecutionState.pending;
  String? error;

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
/// original plan's own EC draft, preserving supplier, plan UUIDs and quantities.
class _WarehouseSubcontractOutboundBatchPageState
    extends ConsumerState<WarehouseSubcontractOutboundBatchPage> {
  final _drafts = <_BatchDraft>[];
  final _employees = <String, UtenEmployeePickerItem>{};
  bool _loading = true;
  bool _saving = false;
  bool _confirming = false;
  bool _changed = false;
  String? _error;
  bool _usedInitialBundles = false;
  int _loadGeneration = 0;
  Set<String> _submittedDraftIds = {};

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
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    for (final draft in _drafts) {
      draft.dispose();
    }
    super.dispose();
  }

  Future<void> _load({bool preserveEdits = false}) async {
    if (_saving) return;
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _error = null;
    });
    final lockedDocuments = {
      for (final draft in _drafts)
        if (!draft.pending && draft.document != null) draft.document!.id: draft,
    };
    final lockedPlans = {
      for (final draft in _drafts)
        if (!draft.pending && draft.document == null)
          draft.detail.planId: draft,
    };
    final previous = preserveEdits
        ? {
            for (final draft in _drafts)
              if (draft.document != null && draft.pending)
                draft.document!.id: draft,
          }
        : <String, _BatchDraft>{};
    final loaded = <_BatchDraft>[];
    try {
      final ids = widget.planIds.where((id) => id.isNotEmpty).toSet().toList();
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
      final initial = _usedInitialBundles ? null : widget.initialBundles;
      _usedInitialBundles = true;
      final results = await Future.wait([
        ref.read(masterNameServiceProvider).ensureWarehousesLoaded(),
        initial == null
            ? loadSubcontractOutboundDetails(
                planIds: ids,
                taskDetail: taskRepo.taskDetail,
                documentDetail: docRepo.detail,
              )
            : Future.value(initial),
      ]);
      if (!mounted || generation != _loadGeneration) return;
      final bundles = results[1] as List<SubcontractOutboundReadBundle>;
      for (final bundle in bundles) {
        final detail = bundle.task;
        if (detail.status != 'OPEN') {
          throw FormatException(l10n.warehouseSubcontractOutboundChanged);
        }
        final List<SubcontractDocDetail?> documents = bundle.documents.isEmpty
            ? [null]
            : bundle.documents;
        // Prepared output can be split across real warehouses. Each existing
        // draft stays separate, even when two drafts reference the same plan.
        for (final document in documents) {
          if (document != null && document.status != 0) {
            throw FormatException(l10n.warehouseSubcontractOutboundChanged);
          }
          final byPlan = {
            for (final item in document?.items ?? <SubcontractDocItem>[])
              if (item.planItemId != null) item.planItemId!: item,
          };
          final lines = <SubcontractOutboundLineDraft>[];
          for (final line in detail.lines) {
            final existing = byPlan[line.planItemId];
            if (document != null && existing == null) continue;
            if (document == null && line.readyOutboundQty <= 0) continue;
            lines.add(
              SubcontractOutboundLineDraft(
                line,
                existing?.id,
                subcontractOutboundQuantity(
                  existing?.qty ?? line.readyOutboundQty,
                ),
                existing?.weight?.toString() ?? '',
                remark: existing?.remark,
                unitRate: existing?.unitRate,
              ),
            );
          }
          if (document != null && lines.length != document.items.length) {
            for (final line in lines) {
              line.dispose();
            }
            throw FormatException(l10n.warehouseSubcontractOutboundChanged);
          }
          final draft = _BatchDraft(
            detail: detail,
            document: document,
            lines: lines,
            workerId:
                document?.workerId ??
                ref.read(sessionProvider).user?.employeeId,
          );
          if (lines.isEmpty || lines.any((line) => line.maxEditableQty <= 0)) {
            draft.state = SubcontractOutboundExecutionState.blocked;
            draft.error = l10n.warehouseSubcontractOutboundNoLines;
          }
          final old = previous[document?.id];
          if (old != null &&
              document != null &&
              subcontractOutboundDraftFingerprint(old.document!) ==
                  subcontractOutboundDraftFingerprint(document)) {
            draft.warehouseId = old.warehouseId;
            draft.workerId = old.workerId;
            draft.date = old.date;
            draft.deliveryDate = old.deliveryDate;
            draft.remark.text = old.remark.text;
            final byItem = {
              for (final line in old.lines) line.draftItemId: line,
            };
            for (final line in draft.lines) {
              final oldLine = byItem[line.draftItemId];
              if (oldLine != null) {
                line.qty.text = oldLine.qty.text;
                line.weight.text = oldLine.weight.text;
                line.remarkController.text = oldLine.remarkController.text;
                line.selected = oldLine.selected;
              }
            }
          }
          final locked =
              lockedDocuments[document?.id] ?? lockedPlans[detail.planId];
          if (locked != null) {
            draft.state = locked.state;
            draft.error = locked.error;
          }
          loaded.add(draft);
        }
      }
      final user = ref.read(sessionProvider).user;
      if (user?.employeeId != null && user!.name.isNotEmpty) {
        _employees[user.employeeId!] = UtenEmployeePickerItem(
          id: user.employeeId!,
          name: user.name,
          departmentName: user.department,
        );
      }
      if (!mounted) {
        for (final draft in loaded) {
          draft.dispose();
        }
        return;
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
    } catch (error) {
      for (final draft in loaded) {
        draft.dispose();
      }
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
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
        if (!mounted || generation != _loadGeneration) return;
        setState(
          () => _employees[id] = UtenEmployeePickerItem(
            id: employee.id,
            name: employee.fullName ?? '',
            employeeCode: employee.code,
            departmentName: employee.departmentName,
          ),
        );
      } catch (_) {
        // Display lookup cannot block task review or discard the original UUID.
      }
    });
  }

  void _finishCompletedSubmission() {
    setState(() {
      _saving = false;
      _confirming = false;
    });
    if (widget.onCompleted != null) {
      widget.onCompleted!();
    } else if (GoRouter.maybeOf(context) != null) {
      returnToSubcontractOutboundTasks(context);
    } else {
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

  String? _validate(_BatchDraft draft) {
    if (draft.warehouseId == null ||
        (draft.warehouseId != draft.document?.warehouseId &&
            !WarehouseSelection(
              ref.read(masterNameServiceProvider).warehouseHierarchy,
            ).selectableIds.contains(draft.warehouseId))) {
      return l10n.warehouseSubcontractOutboundWarehouseRequired;
    }
    for (final line in draft.lines) {
      final error = line.validate(l10n);
      if (error != null) {
        return '${line.line.goodsName ?? line.line.goodsCode ?? ''}: $error';
      }
    }
    return null;
  }

  Future<void> _submit() async {
    if (_saving || _confirming || !_canExecute) return;
    final targets = _drafts
        .where((draft) => draft.pending && draft.selected)
        .toList();
    if (targets.isEmpty) {
      context.appWarning(l10n.warehouseSubcontractOutboundSelectRequired);
      return;
    }
    if (targets.any((draft) => draft.document == null)) {
      await _prepareDrafts(targets);
      return;
    }
    for (final target in targets) {
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
            '${l10n.warehouseSubcontractOutboundSubcontractEffects}\n\n${l10n.warehouseSubcontractOutboundBatchHint}',
      );
      if (!confirmed || !mounted || !_canExecute) return;
      setState(() {
        _confirming = false;
        _saving = true;
      });
      final repo = ref.read(
        subcontractRepositoryProvider(SubcontractDocType.materialIssue),
      );
      _submittedDraftIds = targets.map((draft) => draft.document!.id).toSet();
      for (final draft in targets) {
        var writeStarted = false;
        try {
          // Re-read the exact EC draft. Never choose the next auto-generated
          // draft after another employee has already executed this one.
          final document = draft.document!;
          final fresh = await repo.detail(document.id);
          if (subcontractOutboundDraftFingerprint(fresh) !=
              subcontractOutboundDraftFingerprint(document)) {
            throw FormatException(l10n.warehouseSubcontractOutboundChanged);
          }
          writeStarted = true;
          setState(
            () => draft.state = SubcontractOutboundExecutionState.saving,
          );
          draft.document = await repo.update(document.id, {
            'billDate': _date(draft.date),
            'supplierId': draft.detail.supplierId,
            'warehouseId': draft.warehouseId,
            'workerId': draft.workerId,
            'deliverDate': draft.deliveryDate == null
                ? null
                : _date(draft.deliveryDate!),
            'remark': draft.remark.text.trim().isEmpty
                ? null
                : draft.remark.text.trim(),
            'items': [for (final line in draft.lines) line.toPayload()],
          });
          _changed = true;
          final beforeApproval = await repo.detail(draft.document!.id);
          if (subcontractOutboundDraftFingerprint(beforeApproval) !=
              subcontractOutboundDraftFingerprint(draft.document!)) {
            throw FormatException(l10n.warehouseSubcontractOutboundChanged);
          }
          setState(
            () => draft.state = SubcontractOutboundExecutionState.approving,
          );
          final approved = await repo.approve(draft.document!.id);
          if (approved.status != 1) {
            throw FormatException(l10n.warehouseSubcontractOutboundUncertain);
          }
          draft.document = approved;
          setState(() {
            draft.state = SubcontractOutboundExecutionState.completed;
            draft.error = null;
          });
        } catch (error) {
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
        _finishCompletedSubmission();
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

  Future<void> _prepareDrafts(List<_BatchDraft> targets) async {
    setState(() => _saving = true);
    final repo = ref.read(warehouseSubcontractOutboundRepositoryProvider);
    try {
      for (final draft in targets.where((draft) => draft.document == null)) {
        var writeStarted = false;
        try {
          final fresh = await repo.taskDetail(draft.detail.planId);
          if (fresh.status != 'OPEN') {
            throw FormatException(l10n.warehouseSubcontractOutboundChanged);
          }
          if (!fresh.drafts.any((item) => item.status == 0)) {
            setState(
              () => draft.state = SubcontractOutboundExecutionState.saving,
            );
            writeStarted = true;
            _changed = true;
            await repo.regenerateDraft(draft.detail.planId);
          }
          draft.state = SubcontractOutboundExecutionState.pending;
        } catch (error) {
          if (mounted) {
            setState(() {
              draft.state = writeStarted
                  ? SubcontractOutboundExecutionState.needsVerification
                  : SubcontractOutboundExecutionState.blocked;
              draft.error = writeStarted
                  ? l10n.warehouseSubcontractOutboundUncertain
                  : _message(error);
            });
          }
          return;
        }
      }
      if (!mounted) return;
      setState(() => _saving = false);
      await _load(preserveEdits: true);
      if (mounted) {
        context.appInfo(l10n.warehouseSubcontractOutboundDraftsGenerated);
      }
      invalidateWarehouseTaskCounts(ref);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _verify() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final repo = ref.read(
        subcontractRepositoryProvider(SubcontractDocType.materialIssue),
      );
      for (final draft in _drafts.where(
        (draft) =>
            draft.state == SubcontractOutboundExecutionState.needsVerification,
      )) {
        final document = draft.document;
        if (document == null) continue;
        try {
          final fresh = await repo.detail(document.id);
          // A draft still visible after a timeout is not proof that an earlier
          // mutation cannot commit later. Keep it blocked; verification is GET only.
          if (fresh.status == 1) {
            setState(() {
              draft.document = fresh;
              draft.state = SubcontractOutboundExecutionState.completed;
              draft.error = null;
            });
          }
        } catch (error) {
          if (mounted) context.appError(_message(error));
        }
      }
      invalidateWarehouseTaskCounts(ref);
      if (mounted &&
          _submittedDraftIds.isNotEmpty &&
          _submittedDraftIds.every(
            (id) => _drafts.any(
              (draft) =>
                  draft.document?.id == id &&
                  draft.state == SubcontractOutboundExecutionState.completed,
            ),
          )) {
        context.appSuccess(l10n.warehouseSubcontractOutboundDone);
        _finishCompletedSubmission();
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
      l10n.warehouseSubcontractOutboundDone,
    _ => l10n.warehouseSubcontractOutboundPaused,
  };

  @override
  Widget build(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    final names = ref.watch(masterNameServiceProvider);
    final pending = _drafts.any((draft) => draft.pending && draft.selected);
    return PopScope(
      canPop: !_saving && !_confirming,
      child: Scaffold(
        appBar: UtenAppBar(
          title: l10n.warehouseSubcontractOutboundBatchTitle,
          leading: UtenBackButton(
            onPressed: _saving || _confirming
                ? null
                : () => Navigator.of(context).pop(_changed),
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
                          child: ListView(
                            padding: const EdgeInsets.fromLTRB(
                              UtenSpacing.s12,
                              UtenSpacing.s16,
                              UtenSpacing.s12,
                              UtenFloatingActionGroup.scrollClearance,
                            ),
                            children: [
                              _headers(),
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
                              const SizedBox(height: UtenSpacing.s16),
                              Text(
                                l10n.warehouseSubcontractOutboundLines,
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              SubcontractOutboundDetailTable(
                                rows: [
                                  for (final draft in _drafts)
                                    for (final line in draft.lines)
                                      SubcontractOutboundTableRow(
                                        draft: line,
                                        warehouse: names.warehouse(
                                          draft.warehouseId,
                                        ),
                                        orderBillNo: draft.detail.orderBillNo,
                                        supplierName: draft.detail.supplierName,
                                        documentNo: draft.document?.billNo,
                                        documentRemark: draft.remark,
                                        warehouseId: draft.warehouseId,
                                        warehouses: names.warehouseHierarchy,
                                        onWarehouseChanged: (value) => setState(
                                          () => draft.warehouseId = value,
                                        ),
                                        status: _status(draft),
                                        editable: draft.pending,
                                      ),
                                ],
                                editable: _canExecute,
                                selectable: true,
                                onRowSelected: (row, selected) {
                                  final document = _drafts.firstWhere(
                                    (draft) => draft.lines.contains(row.draft),
                                  );
                                  for (final line in document.lines) {
                                    line.selected = selected;
                                  }
                                },
                                showOrder: true,
                                onChanged: () => setState(() {}),
                              ),
                            ],
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
        floatingActionButton: _loading || _error != null
            ? null
            : UtenFloatingActionGroup(
                children: [
                  UtenButton(
                    type: UtenButtonType.secondary,
                    onPressed: _saving || _confirming
                        ? null
                        : () => Navigator.of(context).pop(_changed),
                    child: Text(l10n.commonBack),
                  ),
                  if (_drafts.any(
                    (draft) =>
                        draft.state ==
                        SubcontractOutboundExecutionState.needsVerification,
                  ))
                    UtenButton(
                      type: UtenButtonType.secondary,
                      isLoading: _saving,
                      onPressed: _saving ? null : _verify,
                      child: Text(l10n.warehouseSubcontractOutboundVerify),
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
                        _drafts.any(
                              (draft) =>
                                  draft.pending &&
                                  draft.selected &&
                                  draft.document == null,
                            )
                            ? l10n.warehouseSubcontractOutboundPrepareDrafts
                            : _changed
                            ? l10n.warehouseSubcontractOutboundContinue
                            : l10n.warehouseSubcontractOutboundBatchConfirm,
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  Widget _headers() => UtenCollapsibleSection(
    key: const Key('subcontract-outbound-document-cards'),
    title: l10n.warehouseSubcontractOutboundDocuments,
    titleTrailing: Text('(${_drafts.length})'),
    child: UtenResponsiveGrid(
      columns: const UtenResponsiveColumns(medium: 1, expanded: 2),
      spacing: UtenSpacing.s12,
      itemCount: _drafts.length,
      itemBuilder: (context, index, width) =>
          _documentCard(_drafts[index], width),
    ),
  );

  Widget _documentCard(_BatchDraft draft, double width) {
    final theme = Theme.of(context);
    final editable = draft.pending && _canExecute;
    return UtenCard(
      key: ValueKey(
        'subcontract-outbound-card-${draft.document?.id ?? draft.detail.planId}',
      ),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: UtenSpacing.s12,
            runSpacing: UtenSpacing.s4,
            children: [
              Text(
                '${l10n.warehouseStockOutboundBillNo}: ${draft.document?.billNo ?? '—'}',
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
          UtenFormGrid(
            columns: width >= 500 ? 2 : 1,
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
                  key: ValueKey(
                    '${draft.document?.id ?? draft.detail.planId}:${draft.workerId}',
                  ),
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
                  value: draft.deliveryDate,
                  onChanged: (value) =>
                      setState(() => draft.deliveryDate = value),
                ),
              ),
              if (draft.document?.createdAt != null)
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
                        draft.document?.createdAt,
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
        ? (ref.read(departmentCodeIdMapProvider).valueOrNull ??
              const {})['SUB_WH']
        : null;
    final result = await ref
        .read(employeeRepositoryProvider)
        .list(
          size: 30,
          search: keyword,
          departmentId: departmentId,
          includeSubtree: true,
        );
    return [
      for (final employee in result.items)
        UtenEmployeePickerItem(
          id: employee.id,
          name: employee.fullName,
          employeeCode: employee.code,
          departmentName: employee.departmentName,
        ),
    ];
  }
}
