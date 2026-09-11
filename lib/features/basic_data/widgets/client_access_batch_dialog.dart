// 多选客户「批量设负责人 / 批量设可见人」弹窗。
//
// 与单客户的 ClientAccessPanel 分开的理由：单客户面板同时呈现两维、带版本 CAS 与
// 前负责人保留提示；批量只做**一维**（负责人或可见人），另一维由服务端保持各客户
// 原值——否则「给 50 个客户换负责人」会顺手把各自维护好的可见人清空。
//
// 变更原因必填（与单客户同口径）：负责人变更会改写整批客户的单据归属，审计事件
// 里必须留下为什么。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_employee_multi_picker.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/client_access_models.dart';
import '../repositories/client_repository.dart';

/// 弹窗结果：选中的人 + 变更原因。
class ClientAccessBatchChoice {
  const ClientAccessBatchChoice({
    required this.employeeIds,
    required this.reason,
  });

  /// 设负责人时恰好一人；设可见人时 0..N 人（空 = 清空整批的可见人）。
  final List<String> employeeIds;
  final String reason;
}

Future<ClientAccessBatchChoice?> showClientAccessBatchDialog({
  required BuildContext context,
  required WidgetRef ref,
  required int clientCount,
  required bool assignOwner,
}) => showDialog<ClientAccessBatchChoice>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _ClientAccessBatchDialog(
    clientCount: clientCount,
    assignOwner: assignOwner,
  ),
);

class _ClientAccessBatchDialog extends ConsumerStatefulWidget {
  const _ClientAccessBatchDialog({
    required this.clientCount,
    required this.assignOwner,
  });

  final int clientCount;
  final bool assignOwner;

  @override
  ConsumerState<_ClientAccessBatchDialog> createState() =>
      _ClientAccessBatchDialogState();
}

class _ClientAccessBatchDialogState
    extends ConsumerState<_ClientAccessBatchDialog> {
  final TextEditingController _reason = TextEditingController();
  UtenEmployeePickerItem? _owner;
  List<UtenEmployeePickerItem> _viewers = const [];

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  /// 候选口径与单客户面板一致：只列在职且有启用账号的员工（服务端同款过滤）。
  Future<List<UtenEmployeePickerItem>> _loadEmployees(String? keyword) async {
    final repository = ref.read(clientRepositoryProvider);
    final rows = <ClientAccessCandidate>[];
    var page = 1;
    var total = 1;
    do {
      final result = await repository.accessCandidates(
        page: page,
        search: keyword,
      );
      rows.addAll(result.items);
      total = result.total;
      page++;
    } while (rows.length < total && page <= 25);
    return rows
        .where((employee) => employee.activeAccount)
        .map(
          (employee) => UtenEmployeePickerItem(
            id: employee.employeeId,
            name: employee.name,
            employeeCode: employee.code,
            departmentName: employee.departmentName,
          ),
        )
        .toList(growable: false);
  }

  bool get _canSubmit {
    if (_reason.text.trim().isEmpty) return false;
    // 设负责人必须选到人；设可见人允许空集（= 把整批的额外可见人清空）。
    return !widget.assignOwner || _owner != null;
  }

  void _submit() {
    if (!_canSubmit) return;
    Navigator.of(context).pop(
      ClientAccessBatchChoice(
        employeeIds: widget.assignOwner
            ? [_owner!.id]
            : [for (final viewer in _viewers) viewer.id],
        reason: _reason.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = widget.assignOwner ? '批量设置负责人' : '批量设置可见人';
    return AlertDialog(
      title: Text('$title（${widget.clientCount} 个客户）'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.assignOwner
                    ? '选中客户的负责人会全部改成同一个人；各客户原有的可见人不受影响。'
                          '原负责人若仍在职，会自动保留为可见人以便处理在途单据。'
                    : '选中客户的可见人会全部替换成下面这组人；各客户的负责人不受影响。'
                          '留空 = 清空这些客户的额外可见人。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: UtenSpacing.s12),
              if (widget.assignOwner)
                UtenEmployeePicker(
                  key: const ValueKey('client-batch-owner-picker'),
                  label: '负责人',
                  required: true,
                  loader: _loadEmployees,
                  initial: _owner,
                  onChanged: (item) => setState(() => _owner = item),
                )
              else
                UtenEmployeeMultiPicker(
                  key: const ValueKey('client-batch-viewers-picker'),
                  label: '可见人',
                  loader: _loadEmployees,
                  initialSelection: _viewers,
                  onChanged: (selection) =>
                      setState(() => _viewers = selection),
                ),
              const SizedBox(height: UtenSpacing.s12),
              UtenInput(
                key: const ValueKey('client-batch-access-reason'),
                controller: _reason,
                label: '变更原因',
                required: true,
                hint: '例如：销售一部交接给张三',
                maxLines: 2,
                onChanged: (_) => setState(() {}),
              ),
            ],
          ),
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
          key: const ValueKey('client-batch-access-submit'),
          onPressed: _canSubmit ? _submit : null,
          onDisabledTap: () {},
          child: Text(title),
        ),
      ],
    );
  }
}
