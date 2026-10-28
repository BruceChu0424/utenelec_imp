import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_field_placeholder.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/l10n/gen/app_localizations_zh.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../department/models/department_node.dart';
import '../../department/widgets/uten_department_picker.dart';
import '../../employee/repositories/employee_repository.dart';
import '../models/material_priority_replenishment.dart';
import '../models/production_material_analysis.dart';
import '../models/material_transfer_quantity.dart';
import '../models/production_exact_quantity.dart';
import '../providers/production_department_provider.dart';
import '../repositories/production_repository.dart';
import '../../employee/repositories/employee_picker_candidates.dart';

Future<ProductionMaterialAnalysisView?>
showMaterialPriorityReplenishmentDialog({
  required BuildContext context,
  required String sourceAnalysisId,
  required String sourceMaterialLineId,
  String? reallocationId,
  String? idempotencyKey,
  bool futureTransfer = false,
  required String sourceLabel,
  Future<void> Function(ProductionMaterialAnalysisView)? onOpenSource,
  bool Function()? commandIsCurrent,
}) {
  final body = MaterialPriorityReplenishmentDialog(
    sourceAnalysisId: sourceAnalysisId,
    sourceMaterialLineId: sourceMaterialLineId,
    reallocationId: reallocationId,
    idempotencyKey: idempotencyKey,
    futureTransfer: futureTransfer,
    sourceLabel: sourceLabel,
    onOpenSource: onOpenSource,
    commandIsCurrent: commandIsCurrent,
  );
  if (context.breakpoint.isCompact) {
    return showModalBottomSheet<ProductionMaterialAnalysisView>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      builder: (_) => FractionallySizedBox(heightFactor: .92, child: body),
    );
  }
  return showDialog<ProductionMaterialAnalysisView>(
    context: context,
    barrierDismissible: false,
    builder: (context) => UtenDialogFrame(
      child: SizedBox(
        width: 680,
        height: (MediaQuery.sizeOf(context).height - 64)
            .clamp(440, 800)
            .toDouble(),
        child: body,
      ),
    ),
  );
}

/// Follow-up work only. The stock transfer has already committed before entry.
class MaterialPriorityReplenishmentDialog extends ConsumerStatefulWidget {
  const MaterialPriorityReplenishmentDialog({
    super.key,
    required this.sourceAnalysisId,
    required this.sourceMaterialLineId,
    this.reallocationId,
    this.idempotencyKey,
    this.futureTransfer = false,
    required this.sourceLabel,
    this.onOpenSource,
    this.commandIsCurrent,
  });
  final String sourceAnalysisId;
  final String sourceMaterialLineId;
  final String? reallocationId;
  final String? idempotencyKey;
  final bool futureTransfer;
  final String sourceLabel;
  final Future<void> Function(ProductionMaterialAnalysisView)? onOpenSource;
  final bool Function()? commandIsCurrent;

  @override
  ConsumerState<MaterialPriorityReplenishmentDialog> createState() =>
      _MaterialPriorityReplenishmentDialogState();
}

class _MaterialPriorityReplenishmentDialogState
    extends ConsumerState<MaterialPriorityReplenishmentDialog> {
  final _quantity = TextEditingController();
  final _billDate = ChinaDateTime.formatDate(ChinaDateTime.today());
  MaterialPriorityReplenishmentPreview? _preview;
  MaterialSupplyRoute? _route;
  String _key = const Uuid().v4();
  String? _error;
  String? _quantityError;
  bool _loading = true;
  bool _saving = false;
  bool _uncertain = false;
  bool _needsReview = false;
  bool _allowExtra = false;
  String? _departmentId;
  String? _departmentName;
  UtenEmployeePickerItem? _worker;

  bool get _locked => _saving || _uncertain;
  BigInt? _units(String key, double legacy) =>
      materialTransferUnits(_preview?.quantityFactsExact[key] ?? legacy);
  String _fact(String key, double legacy) {
    final value = _units(key, legacy);
    return value == null ? '待核对' : materialTransferText(value);
  }

  bool _has(String permission) =>
      ref.read(isSuperAdminProvider) ||
      ref.read(currentPermissionsProvider).contains(permission);
  bool get _canExtra =>
      _preview?.canOverSupply == true &&
      _has(Perm.productionMaterialAnalysisOverSupply);
  bool get _canSubmit =>
      _preview != null &&
      const {
        'NOTIFY_SUPPLY',
        'ISSUE_WORKSHOP_PLANS',
      }.contains(_preview!.operation) &&
      _preview!.allowedRoutes.contains(_route) &&
      (_preview!.createsProductionPlan
          ? _has(Perm.productionMaterialAnalysisGenerate)
          : _has(Perm.productionMaterialAnalysisNotify));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _quantity.dispose();
    super.dispose();
  }

  Future<void> _load({bool preserveQuantity = false}) async {
    if (_locked || !mounted) return;
    if (!_validateOwner()) return;
    setState(() {
      _loading = true;
      _needsReview = true;
      _error = null;
    });
    try {
      final preview = await ref
          .read(productionPlanRepositoryProvider)
          .materialPriorityReplenishmentPreview(
            sourceAnalysisId: widget.sourceAnalysisId,
            reallocationId: widget.reallocationId,
            idempotencyKey: widget.idempotencyKey,
            futureTransfer: widget.futureTransfer,
          );
      if (!mounted) return;
      if (preview.sourceAnalysis.analysisId != widget.sourceAnalysisId ||
          preview.sourceMaterialLineId != widget.sourceMaterialLineId) {
        throw const FormatException('原计划补供引用已变化，请返回原计划核对');
      }
      setState(() {
        _preview = preview;
        _route = preview.route;
        if (!preserveQuantity) {
          final units = materialTransferUnits(
            preview.quantityFactsExact['defaultQty'] ?? preview.defaultQty,
          );
          _quantity.text = units == null ? '' : materialTransferText(units);
        }
        _quantityError = null;
        _needsReview = false;
        _key = const Uuid().v4();
      });
      if (preview.createsProductionPlan &&
          _departmentId == null &&
          preview.material?.goodsId != null) {
        try {
          final defaults = await ref
              .read(productionPlanRepositoryProvider)
              .defaultWorkshops({preview.material!.goodsId!});
          if (!mounted) return;
          final value = defaults[preview.material!.goodsId];
          if (value != null) {
            setState(() {
              _departmentId = value.departmentId;
              _departmentName = value.departmentName;
              if (value.workerId != null) {
                _worker = UtenEmployeePickerItem(
                  id: value.workerId!,
                  name: value.workerName ?? '已安排负责人',
                );
              }
            });
          }
        } catch (_) {
          /* The standard workshop picker remains available. */
        }
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is FormatException
              ? error.message
              : productionErrorMessage(error, fallback: '补供信息加载失败，请重新核对'),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String? _validateQuantity() {
    final value = materialTransferUnits(_quantity.text, positive: true);
    if (value == null) {
      return '请输入大于0、最多14位整数和4位小数的数量';
    }
    final preview = _preview!;
    final remaining = _units(
      'remainingSupplementQty',
      preview.remainingSupplementQty,
    );
    if (remaining == null ||
        _units('safetyReplenishmentQty', preview.safetyReplenishmentQty) ==
            null) {
      return '缺少精确补供数量，请重新读取';
    }
    if (value > remaining && (!_canExtra || !_allowExtra)) {
      return _canExtra
          ? '超出待补量的部分须勾选公共备货'
          : '当前补供最多 ${materialTransferText(remaining)}，额外备货请另建完整任务';
    }
    return null;
  }

  Future<void> _submit() async {
    if (!_validateOwner()) return;
    final preview = _preview;
    if (_saving ||
        _loading ||
        _needsReview ||
        preview == null ||
        (!_canSubmit && !_uncertain) ||
        preview.blockedReason != null ||
        !preview.allowedRoutes.contains(_route)) {
      return;
    }
    final error = _validateQuantity();
    if (error != null) {
      setState(() => _quantityError = error);
      return;
    }
    if (preview.createsProductionPlan &&
        (_departmentId == null || _worker == null)) {
      setState(() => _error = '请核对补自制的生产车间和负责人');
      return;
    }
    final totalText = materialTransferText(
      materialTransferUnits(_quantity.text, positive: true)!,
    );
    final total = double.parse(totalText);
    final wire = productionQuantityWire(totalText);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final repository = ref.read(productionPlanRepositoryProvider);
      final ProductionMaterialAnalysisView source;
      if (preview.createsProductionPlan) {
        final warehouse = preview.sourceAnalysis.warehouseId;
        if (warehouse == null) {
          throw const FormatException('原计划缺少生产仓范围，请返回原计划核对');
        }
        final result = await repository.issueWorkshopPlans(
          analysis: preview.sourceAnalysis,
          warehouseId: warehouse,
          idempotencyKey: _key,
          billDate: _billDate,
          approveNow: _has(Perm.productionPlanApprove),
          lines: [
            MaterialAnalysisIssueLine(
              materialLineId: preview.existingChildAnalysisLineId == null
                  ? preview.sourceMaterialLineId
                  : null,
              analysisLineId: preview.existingChildAnalysisLineId,
              qty: total,
              qtyExact: wire is String ? wire : null,
              departmentId: _departmentId,
              workshopName: _departmentName,
              workerId: _worker!.id,
            ),
          ],
        );
        source = result.analysis;
      } else {
        final safetyText = materialTransferText(
          _units('safetyReplenishmentQty', preview.safetyReplenishmentQty)!,
        );
        final safetyWire = productionQuantityWire(safetyText);
        source = await repository.notifyMaterialAnalysis(
          analysis: preview.sourceAnalysis,
          idempotencyKey: _key,
          target: _route!,
          materialLineIds: [preview.sourceMaterialLineId],
          quantities: [
            MaterialSupplyQuantityInput(
              materialLineId: preview.sourceMaterialLineId,
              qty: total,
              qtyExact: wire is String ? wire : null,
              safetyReplenishmentQty: double.parse(safetyText),
              safetyQtyExact: safetyWire is String ? safetyWire : null,
            ),
          ],
        );
      }
      if (mounted && _validateOwner()) {
        Navigator.of(context, rootNavigator: true).pop(source);
      }
    } on ApiException catch (error) {
      if (!mounted || !_validateOwner()) return;
      final uncertain =
          error is NetworkException ||
          error is NetworkTimeoutException ||
          error.code == 'INTERNAL' ||
          (error.httpStatus != null && error.httpStatus! >= 500);
      setState(() {
        _uncertain = uncertain;
        _needsReview = !uncertain;
        _error = uncertain
            ? '暂未确认补单结果。原计划、数量和填写内容已保留，请用同样内容重试确认；已完成的调拨不受影响。'
            : '${error.message}。请重新核对补供信息；已完成的调拨不受影响。';
      });
    } catch (error) {
      if (!mounted || !_validateOwner()) return;
      setState(() {
        _uncertain = error is! FormatException;
        _needsReview = !_uncertain;
        _error = error is FormatException
            ? error.message
            : '暂未确认补单结果，请用同样内容重试确认；调拨已经生效。';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  bool _validateOwner() {
    if (widget.commandIsCurrent?.call() ?? true) return true;
    if (mounted) {
      setState(() {
        _saving = false;
        _loading = false;
        _uncertain = false;
        _needsReview = true;
        _error =
            (Localizations.of<AppLocalizations>(context, AppLocalizations) ??
                    AppLocalizationsZh())
                .materialTransferContextChanged;
      });
    }
    return false;
  }

  Future<void> _pickWorkshop() async {
    if (_locked) return;
    try {
      final tree = await ref.read(productionWorkshopTreeProvider.future);
      if (!mounted) return;
      final ids = tree.map((node) => node.id).toSet();
      final picked = await showUtenDepartmentPickerPanel(
        context,
        tree: tree,
        selectablePredicate: (node) => ids.contains(node.id),
      );
      if (!mounted || picked == null || picked.isEmpty) return;
      final selected = picked.first;
      DepartmentNode? node;
      for (final item in tree) {
        if (item.id == selected.id) node = item;
      }
      setState(() {
        _departmentId = selected.id;
        _departmentName = selected.name;
        _worker = node?.managerId == null
            ? null
            : UtenEmployeePickerItem(
                id: node!.managerId!,
                name: node.managerName ?? '车间负责人',
              );
      });
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = productionErrorMessage(error, fallback: '车间加载失败'),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    ref.watch(isSuperAdminProvider);
    final preview = _preview;
    final theme = Theme.of(context);
    final total = materialTransferUnits(_quantity.text) ?? BigInt.zero;
    final capacity = preview == null
        ? BigInt.zero
        : _units('remainingSupplementQty', preview.remainingSupplementQty) ??
              BigInt.zero;
    final assigned = preview == null
        ? BigInt.zero
        : total < capacity
        ? total
        : capacity;
    final extra = preview == null ? BigInt.zero : total - assigned;
    final blocked =
        preview?.blockedReason ??
        (!_canSubmit && preview != null ? '当前账号无权为原计划提交补供，可稍后由原计划负责人办理' : null);
    return PopScope(
      canPop: !_locked,
      child: Material(
        key: const Key('material-priority-replenishment-dialog'),
        color: Colors.transparent,
        child: UtenDialogSurface(
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 提交网络段的全屏加载遮罩（root Overlay 传送门，不占布局）。
                if (_saving)
                  const UtenBusyOverlay(
                    title: '正在提交补供',
                    description: '正在下达补自制计划或调拨，请勿重复提交或关闭弹窗。',
                  ),
                UtenDialogHeader(
                  title: const Text('为原计划补供'),
                  icon: Icons.playlist_add_check_rounded,
                  showCloseButton: true,
                  closeTooltip: '稍后补供',
                  onClose: _locked
                      ? null
                      : () => Navigator.of(context, rootNavigator: true).pop(),
                ),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : SingleChildScrollView(
                          padding: const EdgeInsets.all(UtenSpacing.s16),
                          child: AbsorbPointer(
                            absorbing: _locked,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  widget.futureTransfer
                                      ? '专属在途份额已调整，实际入库前不计现货。现在可以补原计划；稍后办理不会撤销本次调整。'
                                      : '调拨已生效。现在可以补原计划；选择稍后办理不会撤销这次调拨。',
                                  style: theme.textTheme.bodyMedium,
                                ),
                                const SizedBox(height: UtenSpacing.s12),
                                Text('原供料计划：${widget.sourceLabel}'),
                                if (preview != null) ...[
                                  Text(
                                    '物料：${preview.material?.goodsName ?? preview.material?.goodsCode ?? '原计划物料'}',
                                  ),
                                  Text(
                                    '本次调用 ${_fact('transferredQty', preview.transferredQty)} · 原计划待补 ${_fact('priorityPendingQty', preview.priorityPendingQty)} · 当前可补 ${_fact('remainingSupplementQty', preview.remainingSupplementQty)}',
                                  ),
                                  const SizedBox(height: UtenSpacing.s12),
                                  UtenDropdownField(
                                    label: '补供方式',
                                    info: '沿原计划已经确认的供货路线办理，不改写历史任务。',
                                    value:
                                        preview.allowedRoutes.contains(_route)
                                        ? _route?.name
                                        : null,
                                    allowClear: false,
                                    searchable: false,
                                    enabled:
                                        !_locked &&
                                        preview.allowedRoutes.length > 1,
                                    items: [
                                      for (final route in preview.allowedRoutes)
                                        UtenDropdownItem(
                                          value: route.name,
                                          label: route.label,
                                        ),
                                    ],
                                    onChanged: (value) {
                                      final route = preview.allowedRoutes
                                          .where((r) => r.name == value)
                                          .firstOrNull;
                                      if (route != null) {
                                        setState(() => _route = route);
                                      }
                                    },
                                  ),
                                  const SizedBox(height: UtenSpacing.s12),
                                  TextField(
                                    key: const Key(
                                      'priority-replenishment-quantity',
                                    ),
                                    controller: _quantity,
                                    enabled: !_locked && blocked == null,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                    decoration: UtenInputDecoration(
                                      InputDecoration(
                                        labelText: '本次补供数量',
                                        suffixText: preview.material?.unitName,
                                        error: _quantityError == null
                                            ? null
                                            : UtenFieldMessage.error(
                                                _quantityError!,
                                              ),
                                      ),
                                      info: _canExtra
                                          ? '先补原计划，超出当前待补量的部分单独进入公共余量。'
                                          : '最多 ${_fact('remainingSupplementQty', preview.remainingSupplementQty)}；额外备货请另建完整任务。',
                                    ),
                                    onChanged: (_) => setState(() {
                                      _quantityError = _validateQuantity();
                                    }),
                                  ),
                                  if (_canExtra)
                                    CheckboxListTile(
                                      key: const Key(
                                        'priority-replenishment-public-extra',
                                      ),
                                      contentPadding: EdgeInsets.zero,
                                      title: const Text('超出部分作为公共备货'),
                                      value: _allowExtra,
                                      onChanged: _locked
                                          ? null
                                          : (value) => setState(() {
                                              _allowExtra = value ?? false;
                                              _quantityError =
                                                  _validateQuantity();
                                            }),
                                    ),
                                  const SizedBox(height: UtenSpacing.s8),
                                  Text(
                                    '补原计划 ${materialTransferText(assigned)} · 公共余量 ${materialTransferText(extra)}${preview.safetyReplenishmentQty > 0 ? ' · 另加安全补库 ${_fact('safetyReplenishmentQty', preview.safetyReplenishmentQty)}' : ''}',
                                  ),
                                  if (preview.createsProductionPlan) ...[
                                    const SizedBox(height: UtenSpacing.s12),
                                    InkWell(
                                      key: const Key(
                                        'priority-replenishment-workshop',
                                      ),
                                      onTap: _locked ? null : _pickWorkshop,
                                      child: InputDecorator(
                                        decoration: const UtenInputDecoration(
                                          InputDecoration(labelText: '生产车间'),
                                        ),
                                        child: Text(
                                          _departmentName ??
                                              utenFieldPlaceholder(
                                                label: '生产车间',
                                              )!,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: UtenSpacing.s12),
                                    UtenEmployeePicker(
                                      candidateScopeKey: (
                                        'replenishment-owner',
                                        _departmentId,
                                      ),
                                      key: ValueKey(_worker?.id),
                                      label: '负责人',
                                      initial: _worker,
                                      enabled: !_locked,
                                      loader: (keyword) async {
                                        final result = await ref
                                            .read(employeeRepositoryProvider)
                                            .listPickerCandidates(
                                              size: 30,
                                              search: keyword,
                                              statuses: const {
                                                'active',
                                                'probation',
                                              },
                                              departmentId: _departmentId,
                                              includeSubtree: true,
                                            );
                                        return [
                                          for (final person in result)
                                            UtenEmployeePickerItem(
                                              id: person.id,
                                              name: person.fullName,
                                              employeeCode: person.code,
                                              accountStatus:
                                                  person.accountStatus,
                                              employmentStatus: person.status,
                                              departmentId: person.departmentId,
                                              departmentName:
                                                  person.departmentName,
                                            ),
                                        ];
                                      },
                                      onChanged: (worker) =>
                                          setState(() => _worker = worker),
                                    ),
                                  ],
                                ],
                                if (blocked != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 12),
                                    child: Text(
                                      blocked,
                                      style: TextStyle(
                                        color: theme.colorScheme.error,
                                      ),
                                    ),
                                  ),
                                if (_error != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 12),
                                    child: Text(
                                      _error!,
                                      key: const Key(
                                        'priority-replenishment-error',
                                      ),
                                      style: TextStyle(
                                        color: theme.colorScheme.error,
                                      ),
                                    ),
                                  ),
                                if (!_uncertain)
                                  TextButton.icon(
                                    onPressed: () =>
                                        _load(preserveQuantity: true),
                                    icon: const Icon(Icons.refresh),
                                    label: const Text('重新核对补供'),
                                  ),
                              ],
                            ),
                          ),
                        ),
                ),
                UtenDialogActions(
                  children: [
                    UtenButton(
                      type: UtenButtonType.secondary,
                      onPressed: _locked
                          ? null
                          : () => Navigator.of(
                              context,
                              rootNavigator: true,
                            ).pop(),
                      child: const Text('稍后补供'),
                    ),
                    if (preview != null &&
                        widget.onOpenSource != null &&
                        !_locked)
                      UtenButton(
                        type: UtenButtonType.secondary,
                        onPressed: () {
                          Navigator.of(context, rootNavigator: true).pop();
                          widget.onOpenSource!(preview.sourceAnalysis);
                        },
                        child: const Text('查看原计划'),
                      ),
                    if (preview != null)
                      UtenButton(
                        key: const Key('priority-replenishment-submit'),
                        type: UtenButtonType.danger,
                        isLoading: _saving,
                        onPressed:
                            _loading ||
                                _needsReview ||
                                (blocked != null && !_uncertain)
                            ? null
                            : _submit,
                        child: Text(
                          _uncertain ? '重试确认补供' : '确认${_route?.label ?? ''}补供',
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
