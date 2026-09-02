import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/handover/data_handover_models.dart';
import '../../../shared/handover/data_handover_preview_card.dart';
import '../../../shared/handover/data_handover_repository.dart';

Future<DataHandoverResult?> showAdminDataHandoverPanel({
  required BuildContext context,
  required WidgetRef ref,
  required String targetEmployeeId,
  required String targetName,
}) => showUtenAdaptivePanel<DataHandoverResult>(
  context: context,
  drawerWidth: 520,
  barrierDismissible: false,
  showDragHandle: true,
  builder: (_) => AdminDataHandoverPanel(
    targetEmployeeId: targetEmployeeId,
    targetName: targetName,
  ),
);

class AdminDataHandoverPanel extends ConsumerStatefulWidget {
  const AdminDataHandoverPanel({
    super.key,
    required this.targetEmployeeId,
    required this.targetName,
  });

  final String targetEmployeeId;
  final String targetName;

  @override
  ConsumerState<AdminDataHandoverPanel> createState() =>
      _AdminDataHandoverPanelState();
}

class _AdminDataHandoverPanelState
    extends ConsumerState<AdminDataHandoverPanel> {
  static final _allScopes = dataHandoverScopeLabels.keys
      .where(isSelectableDataHandoverScope)
      .toSet();

  final _requestId = const Uuid().v4();
  final _reasonFormKey = GlobalKey<FormState>();
  final _reasonController = TextEditingController();
  DateTime _effectiveDate = ChinaDateTime.today();
  int _step = 0;
  bool _loading = false;
  bool _submitting = false;
  int _previewRequestSerial = 0;
  String? _previewError;
  UtenEmployeePickerItem? _source;
  final Set<String> _scopes = {..._allScopes};
  DataHandoverPreview? _preview;
  DataHandoverResult? _result;

  bool get _dirty =>
      _source != null ||
      _scopes.length != _allScopes.length ||
      _reasonController.text.trim().isNotEmpty;

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  Future<List<UtenEmployeePickerItem>> _sourceCandidates(
    String? keyword,
  ) async {
    final repository = ref.read(dataHandoverRepositoryProvider);
    final rows = <DataHandoverCandidate>[];
    var page = 1;
    var total = 1;
    do {
      final result = await repository.candidates(
        role: DataHandoverCandidateRole.source,
        page: page,
        query: keyword,
      );
      rows.addAll(result.items);
      total = result.total;
      page++;
    } while (rows.length < total && page <= 25);
    return rows
        .where((employee) => employee.employeeId != widget.targetEmployeeId)
        .map(
          (employee) => UtenEmployeePickerItem(
            id: employee.employeeId,
            name: employee.name,
            employeeCode: employee.code,
            departmentName: [
              if (employee.departmentName?.isNotEmpty == true)
                employee.departmentName!,
              _statusLabel(employee.status),
            ].join(' · '),
          ),
        )
        .toList(growable: false);
  }

  Future<void> _previewHandover() async {
    final source = _source;
    if (source == null) {
      context.appError('请选择需要交出数据的员工');
      return;
    }
    if (_scopes.isEmpty) {
      context.appError('请至少选择一个交接模块');
      return;
    }
    final selectedScopes = {..._scopes};
    final request = ++_previewRequestSerial;
    setState(() {
      _loading = true;
      _previewError = null;
    });
    try {
      final preview = await ref
          .read(dataHandoverRepositoryProvider)
          .adminPreview(
            sourceEmployeeId: source.id,
            targetEmployeeId: widget.targetEmployeeId,
            scopes: selectedScopes,
          );
      if (!mounted ||
          request != _previewRequestSerial ||
          _source?.id != source.id ||
          !_sameStringSet(_scopes, selectedScopes)) {
        return;
      }
      setState(() {
        _preview = preview;
        _step = 1;
      });
    } on ApiException catch (error) {
      if (mounted && request == _previewRequestSerial) {
        setState(() => _previewError = error.message);
      }
    } catch (_) {
      if (mounted && request == _previewRequestSerial) {
        setState(() => _previewError = '交接盘点失败，请重试');
      }
    } finally {
      if (mounted && request == _previewRequestSerial) {
        setState(() => _loading = false);
      }
    }
  }

  void _invalidatePreview() {
    _previewRequestSerial++;
    _loading = false;
    _preview = null;
    _previewError = null;
  }

  Future<void> _next() async {
    if (_step == 0) {
      await _previewHandover();
      return;
    }
    if (_step == 1) {
      if (_preview?.hasBlockers == true) {
        context.appError('请先处理红色阻塞项，再重新预览');
        return;
      }
      setState(() => _step = 2);
      return;
    }
    if (_step == 3) {
      Navigator.of(context).pop(_result);
      return;
    }
    await _execute();
  }

  Future<void> _execute() async {
    if (!(_reasonFormKey.currentState?.validate() ?? false)) return;
    final confirmed = await UtenDialog.show(
      context,
      title: '确认执行人员数据交接？',
      content: Text(
        '交出人：${_source!.name}\n'
        '接收人：${widget.targetName}\n'
        '模块：${_scopes.map(dataHandoverScopeLabel).join('、')}\n'
        '影响项次(分类合计)：${_preview?.total ?? 0}\n\n'
        '当前责任会转给接收人，历史操作记录保持原员工。',
      ),
      confirmLabel: '确认执行',
    );
    if (!mounted || confirmed != true) return;

    setState(() => _submitting = true);
    try {
      final result = await ref
          .read(dataHandoverRepositoryProvider)
          .execute(
            DataHandoverRequest(
              requestId: _requestId,
              sourceEmployeeId: _source!.id,
              targetEmployeeId: widget.targetEmployeeId,
              scopes: _scopes,
              reason: _reasonController.text.trim(),
              effectiveDate: DateFormat('yyyy-MM-dd').format(_effectiveDate),
            ),
          );
      if (!mounted) return;
      setState(() {
        _result = result;
        _step = 3;
      });
      context.appSuccess(result.replayed ? '交接已执行，本次返回原回执' : '人员数据交接已完成');
    } on ApiException catch (error) {
      if (!mounted) return;
      if (error.code == 'CONFLICT') {
        context.appError('${error.message}；正在重新盘点');
        setState(() => _step = 1);
        await _previewHandover();
      } else {
        context.appApiError(error, fallback: '数据交接失败，未改变责任数据');
      }
    } catch (_) {
      if (mounted) context.appError('数据交接失败，未改变责任数据');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _close() async {
    if (_submitting) return;
    if (_result != null) {
      Navigator.of(context).pop(_result);
      return;
    }
    if (_dirty) {
      final discard = await UtenDialog.show(
        context,
        title: '放弃人工交接设置？',
        content: const Text('当前选择和预览尚未执行。'),
        confirmLabel: '放弃',
        danger: true,
      );
      if (!mounted || discard != true) return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope<void>(
      canPop: !_dirty && !_submitting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_close());
      },
      child: Column(
        key: const ValueKey('admin-data-handover-panel'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              UtenSpacing.s16,
              UtenSpacing.s16,
              UtenSpacing.s8,
              UtenSpacing.s12,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '人员数据交接',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        '接收人：${widget.targetName}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: _submitting ? null : _close,
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(UtenSpacing.s16),
              children: [
                _progress(theme),
                const SizedBox(height: UtenSpacing.s16),
                if (_step == 0) _selectionStep(),
                if (_step == 1) _previewStep(),
                if (_step == 2) _confirmStep(),
                if (_step == 3) _completionStep(),
              ],
            ),
          ),
          UtenBottomActionBar(
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              children: [
                if (_step > 0 && _step < 3)
                  UtenButton(
                    type: UtenButtonType.secondary,
                    onPressed: _submitting
                        ? null
                        : () => setState(() => _step--),
                    child: const Text('上一步'),
                  ),
                UtenButton(
                  key: const ValueKey('admin-data-handover-next'),
                  icon: _step == 3
                      ? Icons.done_rounded
                      : _step == 2
                      ? Icons.swap_horiz_rounded
                      : Icons.navigate_next,
                  isLoading: _loading || _submitting,
                  onPressed: _loading || _submitting ? null : _next,
                  child: Text(
                    _step == 3
                        ? '完成'
                        : _step == 2
                        ? '确认执行交接'
                        : '下一步',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _progress(ThemeData theme) {
    const labels = ['选择交接范围', '核对影响项次', '确认并执行', '完成回执'];
    return Semantics(
      label: '人员数据交接，第 ${_step + 1} 步，共 4 步，${labels[_step]}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '第 ${_step + 1}/4 步 · ${labels[_step]}',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text('${((_step + 1) * 25)}%'),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          LinearProgressIndicator(value: (_step + 1) / 4),
        ],
      ),
    );
  }

  Widget _selectionStep() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text('选择交出数据的员工；已离职员工也可用于补做历史交接。'),
      const SizedBox(height: UtenSpacing.s12),
      UtenEmployeePicker(
        key: ValueKey('handover-source-${_source?.id ?? 'none'}'),
        label: '交出人',
        sheetTitle: '选择交出数据的员工',
        initial: _source,
        required: true,
        loader: _sourceCandidates,
        onChanged: (value) => setState(() {
          _source = value;
          _invalidatePreview();
        }),
      ),
      const SizedBox(height: UtenSpacing.s16),
      Row(
        children: [
          const Expanded(child: Text('交接模块(默认全选)')),
          TextButton(
            onPressed: _scopes.length == _allScopes.length
                ? null
                : () => setState(() {
                    _scopes.addAll(_allScopes);
                    _invalidatePreview();
                  }),
            child: const Text('全选'),
          ),
          TextButton(
            onPressed: _scopes.isEmpty
                ? null
                : () => setState(() {
                    _scopes.clear();
                    _invalidatePreview();
                  }),
            child: const Text('清空'),
          ),
        ],
      ),
      const SizedBox(height: UtenSpacing.s4),
      for (final entry in dataHandoverScopeLabels.entries)
        if (_allScopes.contains(entry.key))
          CheckboxListTile(
            value: _scopes.contains(entry.key),
            title: Text(entry.value),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            onChanged: (selected) => setState(() {
              if (selected == true) {
                _scopes.add(entry.key);
              } else {
                _scopes.remove(entry.key);
              }
              _invalidatePreview();
            }),
          ),
      Text(
        '全选业务模块时，系统还会检查并转移直属下级关系、释放临时任务认领；'
        '这两类系统责任不能单独选择。',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          height: 1.5,
        ),
      ),
      if (_previewError != null)
        UtenEmpty.error(
          message: _previewError,
          actionLabel: '重试',
          onAction: _next,
        ),
    ],
  );

  Widget _previewStep() {
    if (_previewError != null || _preview == null) {
      return UtenEmpty.error(
        message: _previewError ?? '尚未完成交接盘点',
        actionLabel: '重新盘点',
        onAction: _previewHandover,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: UtenButton(
            type: UtenButtonType.secondary,
            icon: Icons.refresh_rounded,
            onPressed: _previewHandover,
            child: const Text('重新预览'),
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        DataHandoverPreviewCard(preview: _preview!),
      ],
    );
  }

  Widget _confirmStep() => Form(
    key: _reasonFormKey,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('交出人：${_source!.name}'),
        Text('接收人：${widget.targetName}'),
        Text('影响项次(分类合计)：${_preview?.total ?? 0}'),
        const SizedBox(height: UtenSpacing.s16),
        UtenInput(
          controller: _reasonController,
          label: '人工交接原因',
          hint: '例如：离职补交接、岗位调整或临时责任转移',
          required: true,
          maxLines: 3,
          inputFormatters: [LengthLimitingTextInputFormatter(2000)],
          validator: (value) =>
              value?.trim().isEmpty != false ? '请填写人工交接原因' : null,
        ),
        const SizedBox(height: UtenSpacing.s12),
        Semantics(
          button: true,
          label: '选择交接生效日期',
          child: InkWell(
            onTap: () async {
              final selected = await showDatePicker(
                context: context,
                initialDate: _effectiveDate,
                firstDate: DateTime(2020),
                lastDate: ChinaDateTime.today(),
              );
              if (selected != null) setState(() => _effectiveDate = selected);
            },
            borderRadius: UtenRadius.mdAll,
            child: InputDecorator(
              decoration: const InputDecoration(
                labelText: '生效日期',
                border: OutlineInputBorder(),
              ),
              child: Text(DateFormat('yyyy-MM-dd').format(_effectiveDate)),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _completionStep() {
    final result = _result!;
    final previewByKey = {
      for (final item in _preview?.items ?? const <DataHandoverPreviewItem>[])
        item.key: item,
    };
    final details = result.resultSummary.entries
        .where((entry) => entry.key != 'total' && entry.value > 0)
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(
          Icons.task_alt_rounded,
          size: 48,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(height: UtenSpacing.s8),
        Text(
          '人员数据交接已完成',
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: UtenSpacing.s12),
        Text('交接批次：${result.sequenceNo}'),
        Text('执行回执项次(分类合计)：${result.processedTotal}'),
        if (result.replayed) const Text('本次为幂等重放，系统未重复执行交接。'),
        const SizedBox(height: UtenSpacing.s8),
        Text(
          '同一业务记录可能因“责任转移”和“历史查阅”分别计入不同项次。',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        if (details.isNotEmpty) ...[
          const SizedBox(height: UtenSpacing.s12),
          for (final entry in details)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.check_circle_outline_rounded),
              title: Text(previewByKey[entry.key]?.label ?? entry.key),
              trailing: Text('${entry.value} 项次'),
            ),
        ],
      ],
    );
  }
}

bool _sameStringSet(Set<String> left, Set<String> right) =>
    left.length == right.length && left.every(right.contains);

String _statusLabel(String? status) => switch (status) {
  'active' => '在职',
  'probation' => '试用',
  'onLeave' => '休假',
  'resigned' => '离职',
  _ => status ?? '状态未知',
};
