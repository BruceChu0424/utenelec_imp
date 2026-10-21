import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../../components/buttons/uten_button.dart';
import '../../../../components/feedback/uten_dialog.dart';
import '../../../../components/inputs/uten_field_message.dart';
import '../../../../components/inputs/uten_input_decoration.dart';
import '../../../../components/inputs/uten_table_cell_spec.dart';
import '../../../../components/layout/uten_floating_action_group.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../../core/ui/app_notification.dart';
import '../../../basic_data/widgets/master_data_table_view.dart';
import '../models/workshop_material_models.dart';
import '../repositories/workshop_material_repository.dart';
import 'workshop_material_line_grid.dart';
import 'workshop_request_material_picker.dart';

/// Page-owned request buffer. Inventory stays authoritative and unchanged until
/// the warehouse processes the requisition; a submitted buffer is a receipt.
class WorkshopMaterialRequestInlineController extends ChangeNotifier {
  WorkshopMaterialRequestInlineController(this._repository);
  final WorkshopMaterialRepository Function() _repository;
  final rows = <String, WmIssueLineRow>{};
  final remark = TextEditingController();
  final _structure = ValueNotifier<int>(0);
  Listenable get structureSignal => _structure;
  String? workshopId;
  String workshopName = '';
  String? error;
  bool busy = false;
  bool _disposed = false;
  int _session = 0;
  String _nonce = '';
  bool Function()? _isCurrent;
  WmRequisition? lastSubmitted;

  bool get active => workshopId != null;
  bool get reviewing => lastSubmitted != null;
  int get session => _session;
  bool get isCurrent => !_disposed && active && _isCurrent?.call() == true;
  bool get editable => isCurrent && !busy && !reviewing;

  void _notifyStructure() {
    if (_disposed) return;
    _structure.value++;
    notifyListeners();
  }

  void _notifyEdits() {
    if (!_disposed) notifyListeners();
  }

  void begin({
    required String workshopId,
    required String workshopName,
    required bool Function() isCurrent,
  }) {
    clear();
    this.workshopId = workshopId;
    this.workshopName = workshopName;
    _isCurrent = isCurrent;
    _nonce = const Uuid().v4();
    _notifyStructure();
  }

  void clear() {
    _session++;
    for (final row in rows.values) {
      row.dispose();
    }
    rows.clear();
    workshopId = null;
    workshopName = '';
    _isCurrent = null;
    lastSubmitted = null;
    busy = false;
    error = null;
    remark.clear();
    _notifyStructure();
  }

  void addAll(Iterable<WmMaterialOption> materials, {required int session}) {
    if (!editable || session != _session) return;
    for (final material in materials) {
      if (material.goodsId.isEmpty || rows.containsKey(material.key)) continue;
      final row = WmIssueLineRow(id: material.key, material: material);
      row.bags.addListener(_notifyEdits);
      row.qty.addListener(_notifyEdits);
      rows[material.key] = row;
    }
    error = null;
    _notifyStructure();
  }

  void remove(String key) {
    if (!editable) return;
    rows.remove(key)?.dispose();
    error = null;
    _notifyStructure();
  }

  String? get validation {
    if (rows.isEmpty) return '请先添加要申请的物料';
    for (final row in rows.values) {
      final qty = row.qtyValue;
      if (qty == null || !qty.isFinite || qty <= 0) {
        return '「${row.material.value!.displayName}」请填写大于 0 的申请重量';
      }
      final bags = row.bagsValue;
      if (row.bags.text.trim().isNotEmpty &&
          (bags == null || !bags.isFinite || bags <= 0)) {
        return '「${row.material.value!.displayName}」请核对申请袋数';
      }
    }
    return null;
  }

  Future<WmRequisition?> submit() async {
    if (!editable) throw StateError('申请对象或权限已变化，请重新进入申请');
    final problem = validation;
    if (problem != null) throw FormatException(problem);
    final currentSession = _session;
    final target = workshopId!;
    final lines = [
      for (final row in rows.values)
        <String, dynamic>{
          'goodsId': row.material.value!.goodsId,
          'colorId': row.material.value!.colorId,
          'qty': row.qtyValue,
          'bags': row.bagsValue,
        },
    ];
    final explanation = remark.text.trim();
    final key = wmIdempotencyKey('request', _nonce, {
      'workshop': target,
      'lines': lines,
      'remark': explanation,
    });
    busy = true;
    error = null;
    _notifyStructure();
    try {
      final request = await _repository().createRequisition(
        kind: 'ISSUE',
        workshopDepartmentId: target,
        lines: lines,
        remark: explanation,
        idempotencyKey: key,
      );
      if (!isCurrent || currentSession != _session) return null;
      lastSubmitted = request;
      return request;
    } catch (failure) {
      if (isCurrent && currentSession == _session) {
        error = failure is ApiException
            ? failure.fieldErrors?.firstOrNull?.message ?? failure.message
            : '提交结果尚未确认，输入已保留，可原样重试';
      }
      rethrow;
    } finally {
      if (!_disposed && currentSession == _session) {
        busy = false;
        _notifyStructure();
      }
    }
  }

  List<MasterColumnDef<T>> columns<T>(String Function(T) keyOf) => [
    for (final bags in [true, false])
      MasterColumnDef<T>(
        key: bags ? 'requestBags' : 'requestQty',
        label: bags ? '申请数量' : '申请重量',
        width: bags ? 155 : 175,
        value: (item) =>
            bags ? rows[keyOf(item)]?.bags.text : rows[keyOf(item)]?.qty.text,
        exactValueOf: (item) =>
            bags ? rows[keyOf(item)]?.bags.text : rows[keyOf(item)]?.qty.text,
        exactListenableOf: (item) =>
            bags ? rows[keyOf(item)]?.bags : rows[keyOf(item)]?.qty,
        cellBuilderHandlesSemantics: true,
        cellBuilder: (_, item) => _RequestQuantityCell(
          controller: this,
          rowKey: keyOf(item),
          bags: bags,
        ),
      ),
  ];

  @override
  void dispose() {
    _disposed = true;
    _session++;
    for (final row in rows.values) {
      row.dispose();
    }
    remark.dispose();
    _structure.dispose();
    super.dispose();
  }
}

class _RequestQuantityCell extends StatelessWidget {
  const _RequestQuantityCell({
    required this.controller,
    required this.rowKey,
    required this.bags,
  });
  final WorkshopMaterialRequestInlineController controller;
  final String rowKey;
  final bool bags;

  @override
  Widget build(BuildContext context) {
    final row = controller.rows[rowKey];
    if (row == null) return const Text('—');
    return ListenableBuilder(
      listenable: Listenable.merge([
        controller.structureSignal,
        row.bags,
        row.qty,
      ]),
      builder: (context, _) {
        final text = bags ? row.bags : row.qty;
        final unit = bags ? '袋' : row.material.value?.unitName ?? '';
        if (controller.reviewing) {
          return Text(text.text.isEmpty ? '—' : '${text.text} $unit');
        }
        final value = bags ? row.bagsValue : row.qtyValue;
        return TextField(
          key: ValueKey('wm-request-${bags ? 'bags' : 'qty'}-$rowKey'),
          controller: text,
          enabled: controller.editable,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: UtenInputDecoration(
            InputDecoration(
              isDense: true,
              contentPadding: UtenEditableGridCellSpec.contentPaddingOf(
                context,
              ),
              hintText: bags ? '袋数' : '申请重量',
              suffixText: unit,
              error:
                  text.text.trim().isNotEmpty &&
                      (value == null || !value.isFinite || value <= 0)
                  ? const UtenFieldMessage.error('请核对')
                  : null,
            ),
          ),
          onChanged: (_) => bags ? row.bagsEdited() : row.qtyEdited(),
        );
      },
    );
  }
}

class WorkshopMaterialRequestModeToolbar extends ConsumerStatefulWidget {
  const WorkshopMaterialRequestModeToolbar({
    super.key,
    required this.controller,
    required this.onSubmitted,
  });
  final WorkshopMaterialRequestInlineController controller;
  final Future<void> Function() onSubmitted;
  @override
  ConsumerState<WorkshopMaterialRequestModeToolbar> createState() =>
      _WorkshopMaterialRequestModeToolbarState();
}

class _WorkshopMaterialRequestModeToolbarState
    extends ConsumerState<WorkshopMaterialRequestModeToolbar> {
  bool _confirming = false;

  Future<void> _exit() async {
    final controller = widget.controller;
    if (controller.busy || _confirming) return;
    final session = controller.session;
    if (!controller.reviewing && controller.rows.isNotEmpty) {
      final leave = await UtenDialog.show(
        context,
        title: '退出申请领料',
        content: const Text('当前申请尚未提交，退出会清空本次填写的内容。'),
        confirmLabel: '清空并退出',
        cancelLabel: '继续填写',
      );
      if (leave != true || !mounted || session != controller.session) return;
    }
    controller.clear();
  }

  Future<void> _add() async {
    final controller = widget.controller;
    if (!controller.editable || _confirming) return;
    final session = controller.session;
    final materials = await showWorkshopRequestMaterialPickerMulti(
      context,
      ref,
      workshopId: controller.workshopId!,
      workshopName: controller.workshopName,
    );
    if (!mounted || materials.isEmpty) return;
    controller.addAll(materials, session: session);
  }

  Future<void> _submit() async {
    final controller = widget.controller;
    if (!controller.editable || _confirming) return;
    final problem = controller.validation;
    if (problem != null) {
      context.appError(problem);
      return;
    }
    final session = controller.session;
    setState(() => _confirming = true);
    try {
      final confirmed = await UtenDialog.show(
        context,
        title: '提交申请领料',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('本次申请 ${controller.rows.length} 项物料，提交后等待仓库审批处理，正式库存不变。'),
            const SizedBox(height: UtenSpacing.s12),
            TextField(
              key: const Key('wm-request-inline-remark'),
              controller: controller.remark,
              maxLength: 500,
              maxLines: 2,
              decoration: const UtenInputDecoration(
                InputDecoration(labelText: '申请备注 (选填)'),
              ),
            ),
          ],
        ),
        confirmLabel: '确认提交',
        cancelLabel: '取消',
      );
      if (confirmed != true ||
          !mounted ||
          !controller.editable ||
          session != controller.session) {
        return;
      }
      final request = await controller.submit();
      if (!mounted || request == null || !controller.isCurrent) return;
      context.appSuccess('申请 ${request.requestNo} 已提交，待审批');
      await widget.onSubmitted();
    } catch (error) {
      if (mounted && controller.isCurrent && session == controller.session) {
        context.appError(
          error is ApiException
              ? error.message
              : error is FormatException
              ? error.message
              : '提交结果尚未确认，输入已保留，可原样重试',
        );
      }
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      return UtenFloatingActionGroup(
        children: [
          UtenButton(
            key: const Key('wm-request-inline-exit'),
            size: UtenButtonSize.large,
            type: UtenButtonType.secondary,
            onPressed: controller.busy || _confirming ? null : _exit,
            child: const Text('退出申请'),
          ),
          if (!controller.reviewing) ...[
            UtenButton(
              key: const Key('wm-request-inline-add'),
              size: UtenButtonSize.large,
              type: UtenButtonType.secondary,
              icon: Icons.add,
              onPressed: controller.editable && !_confirming ? _add : null,
              child: const Text('添加物料'),
            ),
            UtenButton(
              key: const Key('wm-request-inline-submit'),
              size: UtenButtonSize.large,
              isLoading: controller.busy,
              onPressed:
                  controller.editable &&
                      !_confirming &&
                      controller.rows.isNotEmpty
                  ? _submit
                  : null,
              child: const Text('提交申请'),
            ),
          ],
        ],
      );
    },
  );
}
