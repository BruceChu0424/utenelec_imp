import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/authenticated_request_scope.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../repositories/employee_repository.dart';
import 'employee_credential_dialog.dart';
import 'employee_dialog_error_text.dart';
import 'employee_identity_issue_notice.dart';

class EmployeeAccountProvisionTarget {
  const EmployeeAccountProvisionTarget({
    required this.id,
    required this.name,
    required this.code,
  });
  final String id;
  final String name;
  final String code;
}

/// One confirmation starts the queue; each successful account uses the existing
/// mandatory credential acknowledgement before the next write. No result keeps
/// credentials, and a command with an unknown outcome is never retried.
Future<bool> showProvisionSelectedEmployeeAccountsFlow(
  BuildContext context, {
  required WidgetRef ref,
  required List<EmployeeAccountProvisionTarget> employees,
  bool Function()? isCurrent,
  Listenable? ownerChanges,
}) async {
  final targets = {
    for (final employee in employees) employee.id: employee,
  }.values.toList();
  if (targets.isEmpty ||
      !ref.read(currentPermissionsProvider).contains(Perm.accountSupport)) {
    return false;
  }
  final boundary = ref.read(sensitiveReadBoundaryProvider);
  final identity = boundary.identity;
  if (identity == null || identity.actorId != null || identity.readOnly) {
    return false;
  }
  bool current() =>
      context.mounted &&
      (isCurrent?.call() ?? true) &&
      boundary == ref.read(sensitiveReadBoundaryProvider) &&
      ref.read(currentPermissionsProvider).contains(Perm.accountSupport);
  var attempted = false;
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _BatchProvisionDialog(
      employees: targets,
      isCurrent: current,
      ownerChanges: ownerChanges,
      onAttempt: () => attempted = true,
    ),
  );
  return current() && (result ?? attempted);
}

enum _Outcome { pending, blocked, running, succeeded, failed, uncertain }

class _ProvisionRow {
  _ProvisionRow(this.employee);
  final EmployeeAccountProvisionTarget employee;
  EmployeeAccountReadiness? readiness;
  _Outcome outcome = _Outcome.pending;
  String? message;
}

class _BatchProvisionDialog extends ConsumerStatefulWidget {
  const _BatchProvisionDialog({
    required this.employees,
    required this.isCurrent,
    required this.ownerChanges,
    required this.onAttempt,
  });
  final List<EmployeeAccountProvisionTarget> employees;
  final bool Function() isCurrent;
  final Listenable? ownerChanges;
  final VoidCallback onAttempt;

  @override
  ConsumerState<_BatchProvisionDialog> createState() => _BatchProvisionState();
}

class _BatchProvisionState extends ConsumerState<_BatchProvisionDialog> {
  late final List<_ProvisionRow> _rows;
  late final Future<AuthenticatedRequestScope> _scope;
  bool _checking = true;
  bool _running = false;
  bool _showingCredentials = false;
  bool _completed = false;
  bool _attempted = false;
  bool _invalidated = false;
  ModalRoute<bool>? _route;

  bool get _current => mounted && !_invalidated && widget.isCurrent();

  @override
  void initState() {
    super.initState();
    _rows = widget.employees.map(_ProvisionRow.new).toList();
    ref.listenManual(sensitiveReadBoundaryProvider, (_, _) => _checkOwner());
    widget.ownerChanges?.addListener(_checkOwner);
    _scope = ref
        .read(apiClientProvider)
        .captureRequestScope(isCurrent: () => _current);
    _loadReadiness();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route ??= ModalRoute.of<bool>(context);
    _checkOwner();
  }

  void _checkOwner() {
    if (!mounted || _invalidated || widget.isCurrent()) return;
    _invalidated = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final route = _route;
      if (mounted && route != null && route.isActive) {
        route.navigator?.removeRoute(route, false);
      }
    });
  }

  @override
  void dispose() {
    widget.ownerChanges?.removeListener(_checkOwner);
    super.dispose();
  }

  Future<void> _loadReadiness() async {
    final repository = ref.read(employeeRepositoryProvider);
    var next = 0;
    try {
      final scope = await _scope;
      await Future.wait(
        List.generate(_rows.length.clamp(1, 4), (_) async {
          while (_current && next < _rows.length) {
            final row = _rows[next++];
            try {
              row.readiness = await scope.run(
                () => repository.accountReadiness(row.employee.id),
              );
              if (row.readiness?.hasPhone == false) {
                row.outcome = _Outcome.blocked;
                row.message = '缺少手机号，请先在员工档案补全';
              }
            } catch (_) {
              // As in single provisioning, a readiness read is advisory. The
              // authoritative command validates phone and current lifecycle.
              row.message = '未能提前检查，开通时由服务器核对';
            }
          }
        }),
      );
    } catch (_) {
      if (_current) {
        for (final row in _rows) {
          row.outcome = _Outcome.blocked;
          row.message = '登录状态无法核对，请关闭后重新打开';
        }
      }
    } finally {
      if (_current) setState(() => _checking = false);
    }
  }

  Future<void> _run() async {
    if (!_current || _checking || _running || _completed) return;
    setState(() => _running = true);
    final repository = ref.read(employeeRepositoryProvider);
    try {
      final scope = await _scope;
      for (final row in _rows) {
        if (!_current) return;
        if (row.outcome != _Outcome.pending) continue;
        setState(() {
          row.outcome = _Outcome.running;
          row.message = null;
        });
        try {
          _attempted = true;
          widget.onAttempt();
          final result = await scope.run(
            () => repository.provisionAccount(row.employee.id),
          );
          if (!mounted || !_current) return;
          setState(() => _showingCredentials = true);
          await showEmployeeCredentialDialog(
            context,
            result,
            isCurrent: () => _current,
            ownerChanges: widget.ownerChanges,
          );
          if (!_current) return;
          setState(() {
            _showingCredentials = false;
            row.outcome = _Outcome.succeeded;
            row.message = '已开通，凭据已确认保存';
          });
        } catch (error) {
          if (!_current) return;
          final uncertain =
              error is! ApiException ||
              error.httpStatus == null ||
              error.httpStatus! >= 500;
          setState(() {
            _showingCredentials = false;
            row.outcome = uncertain ? _Outcome.uncertain : _Outcome.failed;
            row.message = uncertain
                ? '开通结果待核对，请刷新账号列表确认，暂勿重复开通'
                : employeeDialogErrorText(error, '开通失败');
          });
          if (uncertain) break;
        }
      }
    } finally {
      if (_current) {
        setState(() {
          _running = false;
          _completed = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = _rows
        .where((row) => row.outcome == _Outcome.pending)
        .length;
    final succeeded = _rows
        .where((row) => row.outcome == _Outcome.succeeded)
        .length;
    final failed = _rows
        .where(
          (row) =>
              row.outcome == _Outcome.failed || row.outcome == _Outcome.blocked,
        )
        .length;
    final uncertain = _rows
        .where((row) => row.outcome == _Outcome.uncertain)
        .length;
    return PopScope(
      canPop: !_running,
      child: UtenAlertDialog(
        key: const ValueKey('batch-provision-accounts-dialog'),
        maxWidth: 720,
        icon: const Icon(Icons.group_add_outlined),
        title: const Text('批量开通账号'),
        content: SizedBox(
          width: 640,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _completed
                    ? '已开通 $succeeded 人 · 未开通 $failed 人 · 待核对 $uncertain 人 · 未处理 $pending 人'
                    : '已选择 ${_rows.length} 位员工，开通后逐位展示一次性账号凭据。',
              ),
              const SizedBox(height: UtenSpacing.s8),
              const Text('登录账号为手机号，首次登录需修改密码。证件信息有问题可先开通，再由人事核对。'),
              if (_checking || _running) ...[
                const SizedBox(height: UtenSpacing.s12),
                LinearProgressIndicator(
                  value: _checking
                      ? null
                      : (_rows.length - pending) / _rows.length,
                ),
              ],
              const SizedBox(height: UtenSpacing.s12),
              for (final row in _rows) _buildRow(context, row),
            ],
          ),
        ),
        actions: [
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: _running
                ? null
                : () => Navigator.pop(context, _attempted),
            child: Text(_completed ? '完成' : '取消'),
          ),
          if (!_completed)
            UtenButton(
              key: const ValueKey('confirm-batch-provision-accounts'),
              icon: Icons.person_add_alt_1_outlined,
              isLoading: _checking || (_running && !_showingCredentials),
              onPressed: _checking || _running || pending == 0 ? null : _run,
              child: Text('开通 $pending 个账号'),
            ),
        ],
      ),
    );
  }

  Widget _buildRow(BuildContext context, _ProvisionRow row) {
    final colors = Theme.of(context).colorScheme;
    final label = switch (row.outcome) {
      _Outcome.pending => _completed ? '未处理' : '待开通',
      _Outcome.blocked => '暂不能开通',
      _Outcome.running => '正在开通',
      _Outcome.succeeded => '已开通',
      _Outcome.failed => '未开通',
      _Outcome.uncertain => '待核对',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('${row.employee.name}（${row.employee.code}）'),
              ),
              Text(
                label,
                style: TextStyle(
                  color:
                      row.outcome == _Outcome.failed ||
                          row.outcome == _Outcome.uncertain
                      ? colors.error
                      : colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
          if (row.message != null) ...[
            const SizedBox(height: UtenSpacing.s4),
            Text(row.message!, style: Theme.of(context).textTheme.bodySmall),
          ],
          if (row.readiness?.idNumberIssue != null) ...[
            const SizedBox(height: UtenSpacing.s8),
            EmployeeIdentityIssueNotice(
              issue: row.readiness!.idNumberIssue!,
              where: EmployeeIdentityNoticeContext.provision,
            ),
          ],
        ],
      ),
    );
  }
}
