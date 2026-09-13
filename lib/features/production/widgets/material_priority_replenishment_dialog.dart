import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../department/models/department_node.dart';
import '../../department/widgets/uten_department_picker.dart';
import '../../employee/repositories/employee_repository.dart';
import '../models/material_priority_replenishment.dart';
import '../models/production_material_analysis.dart';
import '../providers/production_department_provider.dart';
import '../repositories/production_repository.dart';
import 'material_supply_submit_confirm.dart';

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
}) {
  final body = MaterialPriorityReplenishmentDialog(
    sourceAnalysisId: sourceAnalysisId,
    sourceMaterialLineId: sourceMaterialLineId,
    reallocationId: reallocationId,
    idempotencyKey: idempotencyKey,
    futureTransfer: futureTransfer,
    sourceLabel: sourceLabel,
    onOpenSource: onOpenSource,
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
    builder: (context) => Dialog(
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
  });
  final String sourceAnalysisId;
  final String sourceMaterialLineId;
  final String? reallocationId;
  final String? idempotencyKey;
  final bool futureTransfer;
  final String sourceLabel;
  final Future<void> Function(ProductionMaterialAnalysisView)? onOpenSource;

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
        if (!preserveQuantity) _quantity.text = _number(preview.defaultQty);
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
    final value = double.tryParse(_quantity.text.trim());
    if (value == null ||
        !value.isFinite ||
        value <= 0 ||
        !RegExp(r'^\d+(\.\d{1,4})?$').hasMatch(_quantity.text.trim())) {
      return '请输入大于 0、最多 4 位小数的数量';
    }
    final preview = _preview!;
    if (value > preview.remainingSupplementQty + .000001 &&
        (!_canExtra || !_allowExtra)) {
      return _canExtra
          ? '超出待补量的部分须勾选公共备货'
          : '当前补供最多 ${_number(preview.remainingSupplementQty)}，额外备货请另建完整任务';
    }
    if (preview.requiresPreparation &&
        (value - preview.remainingSupplementQty).abs() > .000001) {
      return '前置自制须承接全部待补量，建立后可分批安排车间';
    }
    return null;
  }

  Future<void> _submit() async {
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
    final total = double.parse(_quantity.text.trim());
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
              departmentId: _departmentId,
              workshopName: _departmentName,
              workerId: _worker!.id,
            ),
          ],
        );
        source = result.analysis;
      } else {
        final material = preview.material;
        final entry = MaterialSupplyQuantityEntry(
          actionGroupKey: null,
          materialLineId: preview.sourceMaterialLineId,
          label: material?.goodsName ?? '原计划物料',
          dimensionKey: preview.sourceMaterialLineId,
          openQty: 0,
          maxQty: preview.remainingSupplementQty,
          safetyStockQty: 0,
          publicAvailableQty: 0,
          openSafetySupplyQty: 0,
          safetyReplenishmentGapQty: 0,
          safetyReplenishmentQty: preview.safetyReplenishmentQty,
          allowPublicExtra: _canExtra,
        );
        final split = entry.toInput(total, allowOverDemand: _allowExtra);
        source = await repository.notifyMaterialAnalysis(
          analysis: preview.sourceAnalysis,
          idempotencyKey: _key,
          target: _route!,
          materialLineIds: [preview.sourceMaterialLineId],
          quantities: [
            MaterialSupplyQuantityInput(
              materialLineId: preview.sourceMaterialLineId,
              qty: _round(split.qty),
              safetyReplenishmentQty: _round(split.safetyReplenishmentQty),
              publicExtraQty: _round(split.publicExtraQty),
            ),
          ],
        );
      }
      if (mounted) Navigator.of(context, rootNavigator: true).pop(source);
    } on ApiException catch (error) {
      if (!mounted) return;
      final uncertain =
          error is NetworkException ||
          error is NetworkTimeoutException ||
          error.code == 'INTERNAL' ||
          (error.httpStatus != null && error.httpStatus! >= 500);
      setState(() {
        _uncertain = uncertain;
        _needsReview = !uncertain;
        _error = uncertain
            ? '暂未确认补单结果。原计划、数量和请求已保留，请同键重试确认；已完成的调料不受影响。'
            : '${error.message}。请重新核对补供信息；已完成的调料不受影响。';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _uncertain = error is! FormatException;
        _needsReview = !_uncertain;
        _error = error is FormatException
            ? error.message
            : '暂未确认补单结果，请同键重试确认；调料已经生效。';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
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
    final parsed = double.tryParse(_quantity.text.trim());
    final total = parsed?.isFinite == true ? parsed! : 0.0;
    final assigned = preview == null
        ? 0.0
        : total.clamp(0, preview.remainingSupplementQty).toDouble();
    final extra = preview == null
        ? 0.0
        : (total - assigned).clamp(0, double.infinity).toDouble();
    final blocked =
        preview?.blockedReason ??
        (!_canSubmit && preview != null ? '当前账号无权为原计划提交补供，可稍后由原计划负责人办理' : null);
    return PopScope(
      canPop: !_locked,
      child: Material(
        key: const Key('material-priority-replenishment-dialog'),
        color: theme.colorScheme.surface,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(UtenSpacing.s16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('为原计划补供', style: theme.textTheme.titleLarge),
                    ),
                    IconButton(
                      tooltip: '稍后补供',
                      onPressed: _locked
                          ? null
                          : () => Navigator.of(
                              context,
                              rootNavigator: true,
                            ).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
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
                                    : '调料已生效。现在可以补原计划；选择稍后办理不会撤销调料。',
                                style: theme.textTheme.bodyMedium,
                              ),
                              const SizedBox(height: UtenSpacing.s12),
                              Text('原供料计划：${widget.sourceLabel}'),
                              if (preview != null) ...[
                                Text(
                                  '物料：${preview.material?.goodsName ?? preview.material?.goodsCode ?? '原计划物料'}',
                                ),
                                Text(
                                  '本次调用 ${_number(preview.transferredQty)} · 原计划待补 ${_number(preview.priorityPendingQty)} · 当前可补 ${_number(preview.remainingSupplementQty)}',
                                ),
                                const SizedBox(height: UtenSpacing.s12),
                                DropdownButtonFormField<MaterialSupplyRoute>(
                                  initialValue:
                                      preview.allowedRoutes.contains(_route)
                                      ? _route
                                      : null,
                                  isExpanded: true,
                                  decoration: const UtenInputDecoration(
                                    InputDecoration(labelText: '补供方式'),
                                    info: '沿原计划已经确认的供货路线办理，不改写历史任务。',
                                  ),
                                  items: [
                                    for (final route in preview.allowedRoutes)
                                      DropdownMenuItem(
                                        value: route,
                                        child: Text(route.label),
                                      ),
                                  ],
                                  onChanged:
                                      _locked ||
                                          preview.allowedRoutes.length <= 1
                                      ? null
                                      : (route) =>
                                            setState(() => _route = route),
                                ),
                                const SizedBox(height: UtenSpacing.s12),
                                TextField(
                                  key: const Key(
                                    'priority-replenishment-quantity',
                                  ),
                                  controller: _quantity,
                                  enabled: !_locked && blocked == null,
                                  readOnly: preview.requiresPreparation,
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
                                    info: preview.requiresPreparation
                                        ? '先完整建立前置自制责任，之后可以分批安排车间。'
                                        : _canExtra
                                        ? '先补原计划，超出当前待补量的部分单独进入公共余量。'
                                        : '最多 ${_number(preview.remainingSupplementQty)}；额外备货请另建完整任务。',
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
                                  '补原计划 ${_number(assigned)} · 公共余量 ${_number(extra)}${preview.safetyReplenishmentQty > 0 ? ' · 另加安全补库 ${_number(preview.safetyReplenishmentQty)}' : ''}',
                                ),
                                if (preview.createsProductionPlan) ...[
                                  const SizedBox(height: UtenSpacing.s12),
                                  InkWell(
                                    onTap: _locked ? null : _pickWorkshop,
                                    child: InputDecorator(
                                      decoration: const UtenInputDecoration(
                                        InputDecoration(labelText: '生产车间'),
                                      ),
                                      child: Text(_departmentName ?? '选择生产车间'),
                                    ),
                                  ),
                                  const SizedBox(height: UtenSpacing.s12),
                                  UtenEmployeePicker(
                                    key: ValueKey(_worker?.id),
                                    label: '负责人',
                                    initial: _worker,
                                    enabled: !_locked,
                                    loader: (keyword) async {
                                      final result = await ref
                                          .read(employeeRepositoryProvider)
                                          .list(
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
                                        for (final person in result.items)
                                          UtenEmployeePickerItem(
                                            id: person.id,
                                            name: person.fullName,
                                            employeeCode: person.code,
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
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(UtenSpacing.s12),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
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
              ),
            ],
          ),
        ),
      ),
    );
  }
}

double _round(double value) => double.parse(value.toStringAsFixed(4));
String _number(double value) =>
    value.toStringAsFixed(4).replaceFirst(RegExp(r'\.?0+$'), '');
