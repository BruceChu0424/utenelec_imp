import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_app_bar_action_button.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsible_section.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/l10n/gen/app_localizations_zh.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/async/bounded_read_map.dart';
import '../../../core/network/authenticated_request_scope.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/measurement/weight_params.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_field_codec.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/drafts/form_draft_store.dart';
import '../../../shared/measurement/widgets/weight_params_load_notice.dart';
import '../../../shared/measurement/weight_prefs.dart';
import '../../../shared/measurement/widgets/weight_grid_column.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/outbound_weight_entry.dart';
import '../models/warehouse_sales_outbound.dart';
import '../models/warehouse_task_item_selection.dart';
import '../providers/warehouse_count_refresh.dart';
import '../repositories/warehouse_sales_outbound_repository.dart';
import '../widgets/outbound_weight_columns.dart';
import '../widgets/warehouse_sales_outbound_table_columns.dart';
import '../widgets/warehouse_sales_picking_fields.dart';

/// Review multiple documents, then explicitly perform one warehouse stage.
/// Each command retains its own existing server transaction and result.
class WarehouseSalesOutboundBatchPage extends ConsumerStatefulWidget {
  const WarehouseSalesOutboundBatchPage({
    super.key,
    this.targets = const [],
    this.shipmentIds = const [],
    required this.action,
    this.selectedItemIds,
  });

  final List<WarehouseSalesOutboundSummary> targets;
  final List<String> shipmentIds;
  final WarehouseSalesOutboundAction action;
  final List<String>? selectedItemIds;

  @override
  ConsumerState<WarehouseSalesOutboundBatchPage> createState() =>
      _WarehouseSalesOutboundBatchPageState();
}

class _WarehouseSalesOutboundBatchPageState
    extends ConsumerState<WarehouseSalesOutboundBatchPage>
    with FormDraftMixin<WarehouseSalesOutboundBatchPage> {
  List<String> get _targetIds => {
    ...widget.shipmentIds,
    for (final item in widget.targets) item.id,
  }.toList()..sort();
  String? _unknownShipment;
  final Set<String> _blockedSources = {};
  final Map<String, Map<String, dynamic>> _recoveryInputs = {};
  bool _restoredTerminal = false;
  @override
  bool get formDraftBusy => _saving || _confirming || _loading;
  @override
  Future<void> Function()? get formDraftReloadSource => () async {
    _attempted = false;
    await _load(preserveInputs: false);
    if (_error != null) throw StateError(_error!);
  };
  @override
  bool get formDraftUseCurrentRoute => false;
  @override
  bool get formDraftUsesRouterGuard => widget.targets.isEmpty;
  @override
  bool get formDraftHasUnknownSubmission => _unknownShipment != null;
  @override
  FormDraftSpec get formDraftSpec =>
      FormDraftCatalog.warehouseSalesOutboundBatch.spec(
        route: Uri(
          path: '/warehouse/sales-outbound/batch',
          queryParameters: {
            'shipmentIds': _targetIds.join(','),
            'action': widget.action.name,
            ...WarehouseTaskItemSelection(
              widget.selectedItemIds,
            ).queryParameters,
          },
        ).toString(),
      );
  @override
  Iterable<Listenable> get formDraftListenables => [
    _reason,
    for (final picking in _picking.values) ...picking.inputListenables,
  ];
  @override
  Map<String, dynamic> captureFormDraft() => {
    'shipmentIds': _targetIds,
    'selectedItemIds': widget.selectedItemIds,
    'reason': _reason.text,
    'completed': _completed.toList()..sort(),
    'unknownShipment': _unknownShipment,
    'inputs': {
      ..._recoveryInputs,
      for (final entry in _picking.entries)
        entry.key: entry.value.captureInput(),
    },
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    if (((data['selectedItemIds'] as List? ?? []).whereType<String>().toList()
              ..sort())
            .join(',') !=
        ((widget.selectedItemIds ?? []).toList()..sort()).join(',')) {
      throw const FormatException('原出库草稿的所选明细与当前不一致，请返回任务中心核对');
    }
    final ids = (data['shipmentIds'] as List?)?.whereType<String>().toSet();
    if (ids == null ||
        ids.length != _targetIds.length ||
        !ids.containsAll(_targetIds)) {
      throw const FormatException('批量出库草稿与当前任务不一致');
    }
    _reason.text = data['reason'] as String? ?? '';
    _unknownShipment = data['unknownShipment'] as String?;
    if (_unknownShipment != null && !_targetIds.contains(_unknownShipment)) {
      throw const FormatException('原待核对出货单不属于本批来源');
    }
    final inputs = data['inputs'];
    for (final detail in _details ?? <WarehouseSalesOutboundDetail>[]) {
      final id = detail.header.id;
      final input = inputs is Map ? inputs[id] : null;
      if (detail.header.warehouseWorkStatus ==
          WarehouseSalesOutboundStatus.shipped) {
        if (_unknownShipment == id && !_matchesRecoveryRange(detail)) {
          throw const FormatException('原出库明细范围已变化，不能确认原结果');
        }
        _completed.add(id);
        if (_unknownShipment == id) _unknownShipment = null;
        continue;
      }
      if (input is! Map) throw const FormatException('批量出库草稿缺少任务明细');
      _picking[id]!.restoreInput(Map<String, dynamic>.from(input));
    }
    if (_completed.length == _targetIds.length) _restoredTerminal = true;
  }

  @override
  Widget? get formDraftSubmissionRecoveryAction => UtenButton(
    onPressed: _saving || _loading ? null : _verifySubmission,
    icon: Icons.refresh_rounded,
    child: const Text('核对出库结果'),
  );
  Future<void> _verifySubmission() async {
    final id = _unknownShipment;
    if (id == null) return;
    try {
      final input = _picking[id]?.captureInput();
      if (input != null) _recoveryInputs.putIfAbsent(id, () => input);
      final scope = await captureFormDraftRequestScope();
      final latest = await scope.run(
        () => ref.read(warehouseSalesOutboundRepositoryProvider).detail(id),
      );
      scope.checkCurrent();
      if (!mounted || !formDraftIdentityIsCurrent) return;
      if (latest.header.id != id || !_matchesRecoveryRange(latest)) {
        context.appWarning('原出库明细范围已变化，原结果继续待核对');
        return;
      }
      if (latest.header.warehouseWorkStatus !=
          WarehouseSalesOutboundStatus.shipped) {
        context.appWarning('尚未查到已出库结果，原输入继续保留，请稍后再次核对');
        return;
      }
      _completed.add(id);
      _unknownShipment = null;
      _attempted = false;
      _failedId = null;
      _error = null;
      if (_completed.length == _targetIds.length) {
        await completeFormDraft();
        if (mounted) _leaveBatch(true);
        return;
      } else {
        await saveFormDraftNow();
        final checkpoint = ref
            .read(formDraftsProvider)
            .where((draft) => draft.id == formDraftRecoveryId)
            .firstOrNull;
        if (checkpoint != null) adoptFormDraftRecoveryCheckpoint(checkpoint);
      }
      if (mounted) setState(() {});
      invalidateWarehouseTaskCounts(ref);
    } catch (error) {
      if (mounted) {
        if (error is ApiException &&
            const [403, 404].contains(error.httpStatus)) {
          setState(() {
            _blockedSources.add(id);
            _details?.removeWhere((detail) => detail.header.id == id);
            _picking.remove(id)?.dispose();
          });
        }
        context.appError(describeSubmitError(error, fallback: '核对出库结果失败'));
      }
    }
  }

  bool _matchesRecoveryRange(WarehouseSalesOutboundDetail detail) {
    final input =
        _recoveryInputs[detail.header.id] ??
        _picking[detail.header.id]?.captureInput();
    final rows = input?['rows'];
    if (input?['shipmentId'] != detail.header.id ||
        rows is! List ||
        rows.length != detail.lines.length) {
      return false;
    }
    final byId = {
      for (final row in rows.whereType<Map<Object?, Object?>>()) row['id']: row,
    };
    if (byId.length != rows.length) return false;
    final selection = WarehouseTaskItemSelection(widget.selectedItemIds);
    return detail.lines.every(
      (line) =>
          selection.contains(line.id) &&
          byId[line.id]?['goodsId'] == line.goodsId &&
          byId[line.id]?['quantity'] == line.quantity,
    );
  }

  void _leaveBatch(bool result) {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop(result);
      return;
    }
    final router = GoRouter.maybeOf(context);
    if (router != null) goFrom(context, '/warehouse/sales-outbound');
  }

  /// 选填统一出库备注，随每张单的出库事件留证。
  final _reason = TextEditingController();
  List<WarehouseSalesOutboundDetail>? _details;
  final Set<String> _completed = {};
  String? _failedId;
  String? _error;
  bool _loading = true;
  bool _saving = false;
  bool _confirming = false;
  bool _attempted = false;
  int _loadVersion = 0;
  final Map<String, WarehouseSalesPickingDraft> _picking = {};
  bool _selectionComplete = true;

  /// 本次 build 盯住的页内单重参数缓存 (有待称重且带货品的行时才建)。
  WeightParamsCache? _weightCache;

  List<OutboundWeightEntry> get _weightEntries => [
    for (final draft in _picking.values) ...draft.weights.values,
  ];

  AppLocalizations get _l10n =>
      Localizations.of<AppLocalizations>(context, AppLocalizations) ??
      AppLocalizationsZh();

  @override
  void initState() {
    super.initState();
    startFormDraftIdentityGuard();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _reason.dispose();
    for (final draft in _picking.values) {
      draft.dispose();
    }
    super.dispose();
  }

  Future<void> _load({bool preserveInputs = true}) async {
    if (!mounted || _saving || _confirming || _attempted) return;
    final version = ++_loadVersion;
    bool current() =>
        mounted && formDraftIdentityIsCurrent && version == _loadVersion;
    final l10n = _l10n;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (_unknownShipment case final id?) {
        final input = _picking[id]?.captureInput();
        if (input != null) _recoveryInputs.putIfAbsent(id, () => input);
      }
      await ref.read(formDraftsProvider.notifier).ready;
      if (!mounted || !formDraftIdentityIsCurrent || version != _loadVersion) {
        return;
      }
      final resumeId = goRouterPageStateOrNull(
        context,
      )?.uri.queryParameters['draftId'];
      final checkpoint = ref
          .read(formDraftsProvider)
          .where((draft) => draft.id == resumeId)
          .firstOrNull;
      if (checkpoint != null) {
        if (!formDraftSpec.canRestore(
          checkpoint,
          currentRoute: formDraftSpec.route,
        )) {
          throw const FormatException('原批次身份不一致');
        }
        final unknown = checkpoint.data['unknownShipment'];
        if (unknown != null &&
            (unknown is! String || !_targetIds.contains(unknown))) {
          throw const FormatException('原待核对来源不正确');
        }
        _unknownShipment = unknown as String?;
        if (checkpoint.data['inputs'] case final Map<Object?, Object?> inputs) {
          for (final entry in inputs.entries) {
            if (entry.key is String &&
                _targetIds.contains(entry.key) &&
                entry.value is Map) {
              _recoveryInputs[entry.key as String] = Map<String, dynamic>.from(
                entry.value as Map,
              );
            }
          }
        }
      }
      final recovering =
          _unknownShipment != null ||
          _completed.isNotEmpty ||
          (checkpoint != null &&
              draftStrings(checkpoint.data['completed']).isNotEmpty);
      final targets = {for (final item in widget.targets) item.id: item};
      if (_targetIds.isEmpty) {
        throw FormatException(l10n.warehouseOutboundBatchEmpty);
      }
      final repository = ref.read(warehouseSalesOutboundRepositoryProvider);
      final blocked = <String>{};
      final reads = await boundedReadMap(_targetIds, (id) async {
        try {
          final detail = await repository.detail(id);
          if (detail.header.id != id) throw const FormatException('出货来源不一致');
          if (recovering &&
              _recoveryInputs.containsKey(id) &&
              !_matchesRecoveryRange(detail)) {
            blocked.add(id);
            return null;
          }
          if (recovering &&
              id != _unknownShipment &&
              detail.header.warehouseWorkStatus !=
                  WarehouseSalesOutboundStatus.shipped &&
              warehouseSalesOutboundPrimaryAction(detail.header) !=
                  widget.action) {
            blocked.add(id);
            return null;
          }
          return detail;
        } catch (_) {
          if (!recovering) rethrow;
          blocked.add(id);
          return null;
        }
      }, isCurrent: current);
      if (!current()) return;
      final details = reads.whereType<WarehouseSalesOutboundDetail>().toList();
      for (final id in blocked) {
        if (id == _unknownShipment) continue;
        final input = _recoveryInputs[id] ?? _picking[id]?.captureInput();
        _recoveryInputs[id] = {
          'shipmentId': id,
          'blocked': true,
          'rows': [
            for (final row in draftMaps(input?['rows'])) {'id': row['id']},
          ],
        };
      }
      final selection = WarehouseTaskItemSelection(widget.selectedItemIds);
      selection.validate([
        ...details.expand((detail) => detail.lines).map((line) => line.id),
        if (recovering)
          for (final id in blocked)
            for (final row in draftMaps(_recoveryInputs[id]?['rows']))
              row['id'] as String?,
      ]);
      _selectionComplete = details.every(
        (detail) => detail.lines.every((line) => selection.contains(line.id)),
      );
      for (var index = 0; index < details.length; index++) {
        final detail = details[index];
        details[index] = WarehouseSalesOutboundDetail(
          header: detail.header,
          lines: detail.lines
              .where((line) => selection.contains(line.id))
              .toList(),
          shipAddress: detail.shipAddress,
          contactPhone: detail.contactPhone,
          logisticsNo: detail.logisticsNo,
          parcelCount: detail.parcelCount,
          warehouseWorkUpdatedAt: detail.warehouseWorkUpdatedAt,
          handedOverAt: detail.handedOverAt,
        );
      }
      if (!mounted || !formDraftIdentityIsCurrent || version != _loadVersion) {
        return;
      }
      if (details.any(
        (detail) =>
            detail.lines.isEmpty ||
            (!recovering &&
                targets.containsKey(detail.header.id) &&
                detail.header.warehouseWorkStatus !=
                    targets[detail.header.id]?.warehouseWorkStatus) ||
            (!recovering &&
                warehouseSalesOutboundPrimaryAction(detail.header) !=
                    widget.action &&
                detail.header.warehouseWorkStatus !=
                    WarehouseSalesOutboundStatus.shipped),
      )) {
        throw FormatException(l10n.warehouseOutboundBatchStale);
      }
      final previous = {
        for (final entry in _picking.entries)
          if (preserveInputs) entry.key: entry.value.captureInput(),
      };
      final weightUnit = ref.read(warehouseWeightUnitsPrefsProvider).entry;
      final nextPicking = {
        for (final detail in details)
          detail.header.id: WarehouseSalesPickingDraft(
            detail,
            weightUnit: weightUnit,
          ),
      };
      try {
        for (final entry in nextPicking.entries) {
          final input = previous[entry.key];
          if (input != null && entry.value.selectable) {
            entry.value.restoreInput(input);
          }
        }
      } catch (_) {
        for (final picking in nextPicking.values) {
          picking.dispose();
        }
        rethrow;
      }
      setState(() {
        for (final picking in _picking.values) {
          picking.dispose();
        }
        _picking
          ..clear()
          ..addAll(nextPicking);
        _details = details;
        _blockedSources
          ..clear()
          ..addAll(blocked);
        _completed.addAll(
          details
              .where(
                (detail) =>
                    detail.header.warehouseWorkStatus ==
                    WarehouseSalesOutboundStatus.shipped,
              )
              .map((detail) => detail.header.id),
        );
      });
      await initializeFormDraft();
      if (_restoredTerminal) {
        _restoredTerminal = false;
        _attempted = true;
        await resetFormDraftAfterSubmission();
      } else if (_unknownShipment == null &&
          _completed.isNotEmpty &&
          formDraftRecoveryId != null) {
        final saved = ref
            .read(formDraftsProvider)
            .where((draft) => draft.id == formDraftRecoveryId)
            .firstOrNull;
        if (saved != null && saved.hasUnknownSubmission) {
          final acknowledged = await ref
              .read(formDraftsProvider.notifier)
              .save(
                FormDraft(
                  id: saved.id,
                  title: saved.title,
                  module: saved.module,
                  route: saved.route,
                  permission: saved.permission,
                  draftKind: saved.draftKind,
                  updatedAt: DateTime.now(),
                  data: {
                    ...captureFormDraft(),
                    formDraftUnknownSubmissionKey: false,
                  },
                ),
                expectedRevision: saved.revision,
              );
          adoptFormDraftRecoveryCheckpoint(acknowledged);
        }
      }
      // 缓存在 build 里按需盯住: 下一帧再按行批量取单重参数。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ensureOutboundWeightParams(_weightCache, _weightEntries);
      });
    } on ApiException catch (error) {
      if (current()) {
        setState(() => _error = error.message);
      }
    } on FormatException catch (error) {
      if (current()) {
        setState(() => _error = error.message);
        holdFormDraftForSourceReload(error);
      }
    } catch (_) {
      if (current()) {
        setState(() => _error = l10n.commonError);
      }
    } finally {
      if (current()) setState(() => _loading = false);
    }
  }

  Future<void> _submit() async {
    if (!_selectionComplete) {
      context.appWarning('该出货单需整单确认，请返回任务中心选齐同单明细；本次未出库');
      return;
    }
    final details = _details;
    if (_saving ||
        _confirming ||
        _loading ||
        _attempted ||
        details == null ||
        details.isEmpty) {
      return;
    }
    final l10n = _l10n;
    final valid = _picking.values
        .map((draft) => draft.validate())
        .toList()
        .every((value) => value);
    if (!valid) {
      setState(() {});
      final firstError = _picking.values
          .map((draft) => draft.error)
          .firstWhere((message) => message != null, orElse: () => null);
      context.appWarning(firstError ?? '请逐行核对实际发出仓');
      return;
    }
    // 称重明显偏离应发数量的行: 确认弹窗里请复核拣货 (只提醒, 不拦截)。
    final weightAlerts = [
      for (final draft in _picking.values)
        for (final alert in draft.weightAlerts(_weightCache))
          '${draft.detail.header.billNo ?? ''} '
              '${warehouseSalesWeightAlertText(alert.line, alert.check)}',
    ];
    // Busy before the dialog also prevents two confirmations from rapid taps.
    final requestScopeFuture = captureFormDraftRequestScope();
    setState(() => _confirming = true);
    final AuthenticatedRequestScope requestScope;
    try {
      requestScope = await requestScopeFuture;
    } catch (error) {
      if (mounted) {
        setState(() => _confirming = false);
        context.appError(describeSubmitError(error, fallback: '身份状态暂时无法确认'));
      }
      return;
    }
    if (!mounted || !formDraftIdentityIsCurrent) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => UtenAlertDialog(
        title: Text(
          l10n.warehouseOutboundBatchAction(
            warehouseSalesOutboundActionLabel(l10n, widget.action),
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.warehouseOutboundBatchConfirm(
                warehouseSalesOutboundActionLabel(l10n, widget.action),
                details.length,
              ),
            ),
            if (warehouseSalesWeightAlertNotice(dialogContext, weightAlerts)
                case final notice?) ...[
              const SizedBox(height: UtenSpacing.s12),
              notice,
            ],
          ],
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          UtenButton(
            type: UtenButtonType.secondary,
            size: UtenButtonSize.large,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.commonCancel),
          ),
          UtenButton(
            key: const Key('warehouse-sales-outbound-batch-confirm'),
            type: UtenButtonType.danger,
            size: UtenButtonSize.large,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.commonConfirm),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (confirmed != true) {
      setState(() => _confirming = false);
      return;
    }

    setState(() {
      _confirming = false;
      _saving = true;
      _attempted = true;
    });
    final repository = ref.read(warehouseSalesOutboundRepositoryProvider);
    try {
      requestScope.checkCurrent();
      await runFormDraftSubmission(
        () => requestScope.run(() async {
          for (var i = 0; i < details.length; i++) {
            final reviewed = details[i];
            if (_completed.contains(reviewed.header.id)) continue;
            try {
              final latest = await repository.detail(reviewed.header.id);
              requestScope.checkCurrent();
              if (warehouseSalesOutboundReviewSnapshot(latest) !=
                      warehouseSalesOutboundReviewSnapshot(reviewed) ||
                  warehouseSalesOutboundPrimaryAction(latest.header) !=
                      widget.action) {
                throw FormatException(l10n.warehouseOutboundBatchStale);
              }
              _unknownShipment = reviewed.header.id;
              await saveFormDraftNow();
              requestScope.checkCurrent();
              if (!formDraftIdentityIsCurrent) {
                throw ApiException('SESSION_CHANGED', '登录身份已变化，请重新进入任务中心');
              }
              final updated = await repository.transition(
                reviewed.header.id,
                targetStatus: widget.action.targetStatus,
                reason: _reason.text.trim(),
                stockPlaces: _picking[reviewed.header.id]?.stockPlaces,
                lineWarehouses: _picking[reviewed.header.id]?.lineWarehouses,
                lineWeights: _picking[reviewed.header.id]?.lineWeights,
                itemIds: widget.selectedItemIds == null
                    ? null
                    : reviewed.lines.map((line) => line.id).toList(),
              );
              requestScope.checkCurrent();
              if (updated.header.id != reviewed.header.id ||
                  updated.header.warehouseWorkStatus !=
                      widget.action.targetStatus) {
                throw FormatException(l10n.warehouseOutboundBatchUnknown);
              }
              _completed.add(reviewed.header.id);
              _unknownShipment = null;
              details[i] = updated;
              await checkpointFormDraftAfterCreation();
              if (mounted) setState(() {});
            } catch (error) {
              if (error is ApiException &&
                  (error.httpStatus == 400 ||
                      error.httpStatus == 422 ||
                      (error.httpStatus == 409 && error.code == 'CONFLICT'))) {
                _unknownShipment = null;
              }
              _failedId = reviewed.header.id;
              _error = describeSubmitError(
                error,
                fallback: l10n.warehouseOutboundBatchUnknown,
              );
              await checkpointFormDraftAfterCreation();
              break;
            }
          }
        }),
      );
    } catch (error) {
      _failedId ??= _targetIds.firstOrNull;
      _error = describeSubmitError(
        error,
        fallback: l10n.warehouseOutboundBatchUnknown,
      );
    } finally {
      if (mounted) {
        invalidateWarehouseTaskCounts(ref);
        setState(() => _saving = false);
      }
    }
    if (!mounted || !formDraftIdentityIsCurrent) return;
    if (_failedId == null &&
        _blockedSources.isEmpty &&
        _completed.length == _targetIds.length) {
      await completeFormDraft();
      if (!mounted) return;
      context.appSuccess(l10n.commonSuccess);
      _leaveBatch(true);
    } else if (_failedId != null) {
      context.appError(_error!);
    } else {
      await saveFormDraftNow();
      if (mounted) {
        context.appWarning('可办理来源已处理，其余来源仍未派发，原批次继续保留');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n;
    final rows = [
      for (final detail in _details ?? const <WarehouseSalesOutboundDetail>[])
        for (final line in detail.lines)
          WarehouseSalesOutboundTableRow(detail, line),
    ];
    final actionLabel = warehouseSalesOutboundActionLabel(l10n, widget.action);
    final weightUnits = ref.watch(warehouseWeightUnitsPrefsProvider);
    final weightEntries = _weightEntries;
    // 有待称重且带货品的行时才盯住页内单重参数缓存 (离开页面随之释放)。
    _weightCache = weightEntries.any((entry) => entry.paramsLine != null)
        ? ref.watch(weightParamsCacheProvider)
        : null;
    return withFormDraft(
      PopScope(
        canPop: !_saving,
        child: Scaffold(
          appBar: UtenAppBar(
            title: l10n.warehouseOutboundBatchReview,
            leading: UtenBackButton(
              onPressed: _saving ? null : () => _leaveBatch(_attempted),
            ),
            actions: [
              if (!_attempted)
                UtenAppBarActionButton(
                  label: l10n.commonRefresh,
                  icon: Icons.refresh_rounded,
                  isLoading: _loading,
                  onPressed: _loading || _saving || _confirming ? null : _load,
                ),
            ],
          ),
          floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
          floatingActionButtonAnimator:
              FloatingActionButtonAnimator.noAnimation,
          floatingActionButton: UtenFloatingActionGroup(
            children: [
              if (_unknownShipment != null) formDraftSubmissionRecoveryAction!,
              if (_failedId != null)
                UtenButton(
                  type: UtenButtonType.secondary,
                  size: UtenButtonSize.large,
                  onPressed: () => _leaveBatch(true),
                  child: Text(l10n.commonBack),
                )
              else if (_details != null)
                UtenButton(
                  key: const Key('warehouse-sales-outbound-batch-submit'),
                  type: UtenButtonType.danger,
                  size: UtenButtonSize.large,
                  icon: Icons.fact_check_outlined,
                  isLoading: _saving,
                  onPressed: _loading || _saving || _confirming || _attempted
                      ? null
                      : _submit,
                  child: Text(l10n.warehouseOutboundBatchAction(actionLabel)),
                ),
            ],
          ),
          body: SafeArea(
            child: Stack(
              children: [
                AbsorbPointer(
                  absorbing: _saving || _confirming,
                  child: _loading
                      ? const UtenSkeletonList()
                      : _details == null
                      ? UtenEmpty.error(
                          message: _error ?? l10n.warehouseOutboundBatchEmpty,
                          actionLabel: l10n.commonRetry,
                          onAction: _load,
                        )
                      : UtenContentContainer.wide(
                          child: Padding(
                            padding: const EdgeInsets.only(
                              top: UtenSpacing.s12,
                            ),
                            child: UtenCollapsingHeaderScrollView(
                              collapsingHeader: Column(
                                key: const Key(
                                  'warehouse-sales-outbound-batch-header',
                                ),
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                    l10n.warehouseOutboundBatchSelection(
                                      _targetIds.length,
                                    ),
                                  ),
                                  const SizedBox(height: UtenSpacing.s8),
                                  for (final id in _blockedSources)
                                    Text(
                                      '来源 $id 当前不可办理，原范围保留；${id == _unknownShipment ? '原结果继续待核对，不能重新派发' : '本次未派发'}',
                                    ),
                                  UtenCollapsibleSection(
                                    title: l10n.warehouseOutboundBatchDocuments,
                                    // 列数既按容器宽度算，也不超过单据张数：只有一张单
                                    // 据时卡片横铺满屏，不再固定占三分之一屏。
                                    child: UtenFormGrid(
                                      maxColumns: _details!.isEmpty
                                          ? 1
                                          : _details!.length,
                                      children: [
                                        for (final detail in _details!)
                                          _documentCard(detail),
                                      ],
                                    ),
                                  ),
                                  if (_failedId != null) ...[
                                    const SizedBox(height: UtenSpacing.s8),
                                    Semantics(
                                      liveRegion: true,
                                      child: Text(
                                        '${l10n.warehouseOutboundBatchStopped}\n$_error',
                                        style: TextStyle(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.error,
                                        ),
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: UtenSpacing.s12),
                                ],
                              ),
                              // 明细区直接从处理说明开始：不再写「出库明细」标题，
                              // 页面标题与表头已说明这里是什么。
                              body: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (!_selectionComplete)
                                    Text(
                                      '该出货单需整单确认，请返回任务中心选齐同单明细',
                                      style: TextStyle(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.error,
                                      ),
                                    ),
                                  TextField(
                                    controller: _reason,
                                    readOnly:
                                        _attempted || _saving || _confirming,
                                    maxLength: 500,
                                    decoration: UtenInputDecoration(
                                      InputDecoration(
                                        labelText:
                                            l10n.warehouseOutboundBatchReason,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: UtenSpacing.s12),
                                  WeightParamsLoadNotice(cache: _weightCache),
                                  Expanded(
                                    child:
                                        MasterDataTableView<
                                          WarehouseSalesOutboundTableRow
                                        >(
                                          tableKey:
                                              'features.warehouse.pages.warehouse_sales_outbound_batch_page.WarehouseSalesOutboundBatchPageState.build.1',
                                          key: const Key(
                                            'warehouse-sales-outbound-batch-table',
                                          ),
                                          primary: true,
                                          columns:
                                              warehouseSalesOutboundTableColumns(
                                                context: context,
                                                l10n: l10n,
                                                rows: rows,
                                                // V631：发出仓按行在表格里选，批量核对不再逐单选仓。
                                                draftOf: (row) =>
                                                    _picking[row
                                                        .detail
                                                        .header
                                                        .id],
                                                onDraftChanged: () {
                                                  setState(() {});
                                                  ensureOutboundWeightParams(
                                                    _weightCache,
                                                    _weightEntries,
                                                  );
                                                },
                                                stockPlaceControllerOf: (row) =>
                                                    _picking[row
                                                            .detail
                                                            .header
                                                            .id]
                                                        ?.places[row.line.id],
                                                editingEnabled:
                                                    !_attempted &&
                                                    !_saving &&
                                                    !_confirming,
                                                includeShipment: true,
                                                weightParams: _weightCache,
                                                weightEntryUnit:
                                                    weightUnits.entry,
                                                resultOf: (row) =>
                                                    _unknownShipment ==
                                                        row.detail.header.id
                                                    ? '结果待核对'
                                                    : _completed.contains(
                                                        row.detail.header.id,
                                                      )
                                                    ? row
                                                          .detail
                                                          .header
                                                          .statusLabel
                                                    : _failedId ==
                                                          row.detail.header.id
                                                    ? '办理受阻'
                                                    : row
                                                          .detail
                                                          .header
                                                          .statusLabel,
                                              ),
                                          toolbarActions: weightEntries.isEmpty
                                              ? null
                                              : const [WeightEntryUnitButton()],
                                          summaryBar: rows.isEmpty
                                              ? null
                                              : OutboundWeightSummaryBar(
                                                  entries: weightEntries,
                                                  params: _weightCache,
                                                  productsOf: () => [
                                                    for (final row in rows)
                                                      OutboundProductQuantity(
                                                        goodsId:
                                                            row.line.goodsId,
                                                        quantity:
                                                            row.line.quantity,
                                                        unitId: row.line.unitId,
                                                        unitName:
                                                            row.line.unitName,
                                                      ),
                                                  ],
                                                ),
                                          items: rows,
                                          bottomContentPadding:
                                              UtenFloatingActionGroup
                                                  .scrollClearance,
                                          rowKeyOf: (row) => row.key,
                                          facets: const {},
                                          nullCounts: const {},
                                          filters: const {},
                                          onFilterChanged: (_, _) {},
                                          emptyMessage: l10n.commonNoData,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                ),
                if (_saving)
                  Positioned.fill(
                    child: UtenBusyOverlay(
                      title: l10n.warehouseOutboundBatchAction(actionLabel),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _documentCard(WarehouseSalesOutboundDetail detail) {
    final l10n = _l10n;
    final theme = Theme.of(context);
    final facts = <(String, String?)>[
      (l10n.warehouseOutboundBatchBillDate, detail.header.billDate),
      (l10n.warehouseOutboundClient, detail.header.clientName),
      (l10n.warehouseOutboundStatus, detail.header.statusLabel),
      if (detail.warehouseWorkUpdatedAt != null)
        (
          l10n.warehouseOutboundBatchUpdatedAt,
          ChinaDateTime.formatIsoInstant(
            detail.warehouseWorkUpdatedAt,
            fallback: '—',
          ),
        ),
    ];
    return UtenCard(
      key: Key('warehouse-sales-outbound-document-${detail.header.id}'),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.warehouseOutboundBillNo,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: UtenSpacing.s4),
          Text(
            detail.header.billNo ?? '—',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: UtenSpacing.s12),
          for (final fact in facts)
            Padding(
              padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '${fact.$1}: ',
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    TextSpan(text: fact.$2 ?? '—'),
                  ],
                ),
                style: theme.textTheme.bodyMedium,
              ),
            ),
        ],
      ),
    );
  }
}
