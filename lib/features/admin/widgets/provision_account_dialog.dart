// 开通账号对话框（权限设置页 · 按员工）。
//
// 与人事-员工详情页的「开通账号」同后端端点（POST /org/employees/{id}/account，
// account:support）：登录账号=手机号，初始密码=证件号后 6 位，首登强制改密。
// 候选列表走 /admin/users/provision-candidates（在册未开户员工，最小信息集、
// 不含 PII 明文、限 20 条）；缺手机号/证件号的员工置灰并提示原因。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/inputs/uten_search_bar.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/formatters/employee_display.dart';
import '../../employee/widgets/employee_account_provision_flow.dart';
import '../models/admin_models.dart';
import '../repositories/admin_repository.dart';

/// 弹出「开通账号」选择器；成功开通后回调 [onProvisioned]（外层刷新账号列表）。
Future<void> showProvisionAccountDialog(
  BuildContext context, {
  required VoidCallback onProvisioned,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => _ProvisionAccountDialog(
      // 凭据弹窗要在选择器关闭之后展示，必须用仍存活的外层上下文。
      parentContext: context,
      onProvisioned: onProvisioned,
    ),
  );
}

class _ProvisionAccountDialog extends ConsumerStatefulWidget {
  const _ProvisionAccountDialog({
    required this.parentContext,
    required this.onProvisioned,
  });

  /// 发起页面的上下文：选择器 pop 后展示一次性凭据弹窗用。
  final BuildContext parentContext;
  final VoidCallback onProvisioned;

  @override
  ConsumerState<_ProvisionAccountDialog> createState() =>
      _ProvisionAccountDialogState();
}

class _ProvisionAccountDialogState
    extends ConsumerState<_ProvisionAccountDialog> {
  String _search = '';
  List<AccountProvisionCandidate> _items = const [];
  bool _loading = true;
  String? _error;
  int _requestEpoch = 0;
  bool _provisioning = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final epoch = ++_requestEpoch;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await ref
          .read(adminRepositoryProvider)
          .provisionCandidates(search: _search.isEmpty ? null : _search);
      if (!mounted || epoch != _requestEpoch) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || epoch != _requestEpoch) return;
      setState(() {
        _error = e.message.isNotEmpty ? e.message : '加载失败，请稍后重试';
        _loading = false;
      });
    } catch (_) {
      if (!mounted || epoch != _requestEpoch) return;
      setState(() {
        _error = '加载失败，请稍后重试';
        _loading = false;
      });
    }
  }

  Future<void> _provision(AccountProvisionCandidate candidate) async {
    if (_provisioning) return;
    setState(() => _provisioning = true);
    try {
      final result = await showProvisionSelectedEmployeeAccountFlow(
        widget.parentContext,
        ref: ref,
        employeeId: candidate.employeeId,
        employeeName: candidate.name,
        employeeCode: candidate.code,
        hasAccount: false,
      );
      if (!mounted || result == null) return;
      Navigator.pop(context);
      widget.onProvisioned();
    } finally {
      if (mounted) setState(() => _provisioning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.person_add_alt_1_rounded),
          SizedBox(width: UtenSpacing.s8),
          Text('开通账号'),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '为还没有登录账号的在册员工补开账号。'
                '缺少手机号或证件号的员工无法开通，请先在员工档案中补全资料。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: UtenSpacing.s12),
              UtenSearchBar(
                hint: '搜索姓名或工号',
                autofocus: true,
                onChanged: (v) {
                  final next = v.trim();
                  if (next != _search) {
                    _search = next;
                    unawaited(_load());
                  }
                },
              ),
              const SizedBox(height: UtenSpacing.s8),
              SizedBox(height: 320, child: _listBody(theme)),
            ],
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.end,
      actions: [
        TextButton(
          onPressed: _provisioning ? null : () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _listBody(ThemeData theme) {
    final l10n = AppLocalizations.of(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 36,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: UtenSpacing.s8),
            Text(_error!, style: theme.textTheme.bodySmall),
            const SizedBox(height: UtenSpacing.s8),
            TextButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.how_to_reg_outlined,
              size: 36,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: UtenSpacing.s8),
            Text(
              _search.isEmpty ? '在册员工都已开通账号' : '没有匹配的待开通员工',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      itemCount: _items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final c = _items[i];
        final enabled = c.provisionable && !_provisioning;
        return Opacity(
          opacity: c.provisionable ? 1 : 0.55,
          child: ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: UtenSpacing.s4,
            ),
            leading: CircleAvatar(
              radius: 16,
              child: Text(
                c.name.isEmpty ? '?' : c.name.substring(0, 1).toUpperCase(),
                style: const TextStyle(fontSize: 13),
              ),
            ),
            title: Text(
              formatEmployeeDisplayName(c.name, c.code),
              style: theme.textTheme.bodyMedium,
            ),
            subtitle: c.departmentName?.trim().isNotEmpty == true
                ? Text(
                    c.departmentName!.trim(),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                : null,
            trailing: c.provisionable
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        l10n.accountStatusNotProvisioned,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: UtenSpacing.s4),
                      Icon(
                        Icons.chevron_right_rounded,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ],
                  )
                : Tooltip(
                    message: '请先在员工档案中补全${c.missingHint}',
                    child: Text(
                      c.missingHint,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
            onTap: enabled ? () => _provision(c) : null,
          ),
        );
      },
    );
  }
}
