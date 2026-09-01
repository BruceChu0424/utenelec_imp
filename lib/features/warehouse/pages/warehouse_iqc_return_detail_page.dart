import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../models/warehouse_iqc_return.dart';
import '../repositories/warehouse_iqc_return_repository.dart';

class WarehouseIqcReturnDetailPage extends ConsumerStatefulWidget {
  const WarehouseIqcReturnDetailPage({
    super.key,
    required this.id,
    this.repository,
  });

  final String id;
  final WarehouseIqcReturnGateway? repository;

  @override
  ConsumerState<WarehouseIqcReturnDetailPage> createState() =>
      _WarehouseIqcReturnDetailPageState();
}

class _WarehouseIqcReturnDetailPageState
    extends ConsumerState<WarehouseIqcReturnDetailPage> {
  WarehouseIqcReturnTask? _task;
  bool _loading = false;
  bool _saving = false;
  String? _error;
  int _requestVersion = 0;

  WarehouseIqcReturnGateway get _repository =>
      widget.repository ?? ref.read(warehouseIqcReturnRepositoryProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final version = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final task = await _repository.detail(widget.id);
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _task = task;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = 'IQC 实物退回详情加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  bool get _canRecordReturn {
    final task = _task;
    return task != null &&
        task.canRecordReturn &&
        ref
            .read(currentPermissionsProvider)
            .contains(Perm.procurementIqcRejectionRecordReturn);
  }

  Future<void> _recordReturn() async {
    final task = _task;
    if (task == null || !_canRecordReturn || _saving) return;
    final command = await showDialog<WarehouseIqcRecordReturnCommand>(
      context: context,
      builder: (_) => _RecordPhysicalReturnDialog(task: task),
    );
    if (command == null || !mounted) return;
    setState(() => _saving = true);
    try {
      final updated = await _repository.recordReturn(task.id, command);
      if (!mounted) return;
      setState(() => _task = updated);
      context.appSuccess('实物退回凭证已登记');
    } on ApiException catch (error) {
      if (!mounted) return;
      context.appError(error.message);
      if (error.code == 'CONFLICT') await _load();
    } catch (_) {
      if (mounted) context.appError('实物退回登记失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final task = _task;
    return Scaffold(
      appBar: UtenAppBar(
        title: 'IQC 实物退回详情',
        subtitle: '仓库退回凭证视图',
        leading: UtenBackButton(
          onPressed: () =>
              popOrBackTo(context, defaultPath: '/warehouse/iqc-returns'),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: UtenSpacing.s8),
            child: UtenButton(
              key: const Key('warehouse-iqc-return-detail-refresh'),
              size: UtenButtonSize.large,
              type: UtenButtonType.tonal,
              icon: Icons.refresh_rounded,
              isLoading: _loading && task != null,
              onPressed: _loading || _saving ? null : _load,
              child: const Text('刷新'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading && task == null
            ? const UtenSkeletonList(itemCount: 6)
            : _error != null && task == null
            ? UtenEmpty.error(
                message: _error,
                actionLabel: '重新加载',
                onAction: _load,
              )
            : task == null
            ? UtenEmpty.error(message: '任务不存在或已不在仓库实物退回范围')
            : UtenContentContainer.wide(
                child: ListView(
                  padding: const EdgeInsets.symmetric(
                    vertical: UtenSpacing.s16,
                  ),
                  children: [
                    _IqcPhysicalStatusBanner(task: task),
                    if (_error != null) ...[
                      const SizedBox(height: UtenSpacing.s8),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: UtenSpacing.s12),
                    _factsCard(task),
                    const SizedBox(height: UtenSpacing.s24),
                  ],
                ),
              ),
      ),
      bottomNavigationBar: !_canRecordReturn
          ? null
          : SafeArea(
              child: Container(
                padding: const EdgeInsets.all(UtenSpacing.s12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  border: Border(
                    top: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                ),
                child: Center(
                  child: UtenButton(
                    key: const Key('warehouse-iqc-return-record'),
                    size: UtenButtonSize.large,
                    icon: Icons.assignment_return_outlined,
                    isLoading: _saving,
                    onPressed: _saving ? null : _recordReturn,
                    child: const Text('登记实物退回'),
                  ),
                ),
              ),
            ),
    );
  }

  Widget _factsCard(WarehouseIqcReturnTask task) {
    final facts = <(String, String?)>[
      ('实物状态', task.statusLabel),
      ('来源类型', task.receiptType?.label),
      ('收货单号', task.receiptBillNo),
      ('订货单号', task.orderBillNo),
      ('供应商 / 委外商', task.supplierName),
      ('仓库', task.warehouseName),
      ('货品', task.goodsLabel),
      ('颜色', task.colorName),
      ('拒收数量', _quantityText(task.failedQuantity, task.unitName)),
      ('拒收基础量', task.failedBaseQuantity),
      ('IQC 状态', task.inspectionStatus),
      ('退回凭证', task.returnReference),
      ('退回日期', task.returnDate),
      ('退回说明', task.returnNote),
      ('登记人员', task.returnRecordedByName),
      ('登记时间', task.returnRecordedAt),
      ('任务版本', task.version.toString()),
    ].where((fact) => _present(fact.$2)).toList(growable: false);
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: 'IQC 不合格实物与退回凭证',
      child: Card(
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
                      child: _IqcFact(label: fact.$1, value: fact.$2!),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _IqcPhysicalStatusBanner extends StatelessWidget {
  const _IqcPhysicalStatusBanner({required this.task});

  final WarehouseIqcReturnTask task;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      liveRegion: true,
      label: '实物退回状态 ${task.statusLabel}',
      child: Container(
        key: const Key('warehouse-iqc-return-detail-boundary'),
        padding: const EdgeInsets.all(UtenSpacing.s16),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
          borderRadius: UtenRadius.lgAll,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              task.statusLabel,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              task.canRecordReturn
                  ? '核对拒收实物后，登记真实退回凭证、日期和说明。'
                  : '当前只读展示实物退回凭证。',
              style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
            ),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              '本页不包含商业或财务处理信息，也不提供跨部门结案操作。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecordPhysicalReturnDialog extends StatefulWidget {
  const _RecordPhysicalReturnDialog({required this.task});

  final WarehouseIqcReturnTask task;

  @override
  State<_RecordPhysicalReturnDialog> createState() =>
      _RecordPhysicalReturnDialogState();
}

class _RecordPhysicalReturnDialogState
    extends State<_RecordPhysicalReturnDialog> {
  final _formKey = GlobalKey<FormState>();
  final _reference = TextEditingController();
  final _note = TextEditingController();
  late final String _commandId = const Uuid().v4();
  late DateTime _date = DateTime.now();

  @override
  void dispose() {
    _reference.dispose();
    _note.dispose();
    super.dispose();
  }

  String _dateText(DateTime value) {
    return '${value.year}-${value.month.toString().padLeft(2, '0')}-'
        '${value.day.toString().padLeft(2, '0')}';
  }

  Future<void> _pickDate() async {
    final today = DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(today.year, today.month, today.day),
    );
    if (selected != null && mounted) setState(() => _date = selected);
  }

  void _submit() {
    if (_formKey.currentState?.validate() != true) return;
    Navigator.of(context).pop(
      WarehouseIqcRecordReturnCommand(
        expectedVersion: widget.task.version,
        commandId: _commandId,
        returnReference: _reference.text,
        returnDate: _dateText(_date),
        returnNote: _note.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('登记实物退回'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('货品：${widget.task.goodsLabel}'),
                Text(
                  '拒收数量：${_quantityText(widget.task.failedQuantity, widget.task.unitName)}',
                ),
                const SizedBox(height: UtenSpacing.s12),
                TextFormField(
                  key: const Key('warehouse-iqc-return-reference'),
                  controller: _reference,
                  maxLength: 200,
                  decoration: const InputDecoration(labelText: '退回凭证号'),
                  validator: (value) => _required(value, 200, '退回凭证号'),
                ),
                const SizedBox(height: UtenSpacing.s8),
                Semantics(
                  button: true,
                  label: '选择退回日期 ${_dateText(_date)}',
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    onPressed: _pickDate,
                    icon: const Icon(Icons.event_outlined),
                    label: Text('退回日期 ${_dateText(_date)}'),
                  ),
                ),
                const SizedBox(height: UtenSpacing.s8),
                TextFormField(
                  key: const Key('warehouse-iqc-return-note'),
                  controller: _note,
                  minLines: 3,
                  maxLines: 6,
                  maxLength: 2000,
                  decoration: const InputDecoration(labelText: '退回说明'),
                  validator: (value) => _required(value, 2000, '退回说明'),
                ),
              ],
            ),
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          style: TextButton.styleFrom(minimumSize: const Size(88, 48)),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          key: const Key('warehouse-iqc-return-submit'),
          style: FilledButton.styleFrom(minimumSize: const Size(112, 48)),
          onPressed: _submit,
          icon: const Icon(Icons.assignment_turned_in_outlined),
          label: const Text('确认登记'),
        ),
      ],
    );
  }
}

class _IqcFact extends StatelessWidget {
  const _IqcFact({required this.label, required this.value});

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

String? _required(String? value, int maxLength, String label) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return '请填写$label';
  if (text.length > maxLength) return '$label不能超过 $maxLength 个字符';
  return null;
}

String _quantityText(String? quantity, String? unit) {
  final parts = [
    quantity,
    unit,
  ].where((value) => value?.trim().isNotEmpty == true).join(' ');
  return parts.isEmpty ? '—' : parts;
}

bool _present(String? value) => value?.trim().isNotEmpty == true;
