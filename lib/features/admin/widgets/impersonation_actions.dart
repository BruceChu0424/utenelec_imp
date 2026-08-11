// 模拟身份（admin「切换人」）：密码确认弹窗 + 目标选择器 + 切换流程编排。
// 触发自工作台页头「切换人」与模拟横幅「切换」。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/providers/session_provider.dart';
import '../models/impersonation.dart';
import '../repositories/impersonation_repository.dart';

/// 「切换人」入口编排：
/// 1) 未进模拟模式 → 弹密码框 → enterImpersonationMode；
/// 2) 打开目标选择器（始终以 admin 凭证加载）；
/// 3) 选中 → startImpersonation → 回工作台看目标视角。
Future<void> openSwitchPerson(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context);
  final session = ref.read(sessionProvider);

  if (!session.isImpersonationModeActive) {
    final pwd = await showImpersonationPasswordDialog(context);
    if (pwd == null || pwd.isEmpty) return;
    try {
      await ref
          .read(sessionProvider.notifier)
          .enterImpersonationMode(password: pwd);
    } on ApiException catch (e) {
      if (context.mounted) {
        context.appError(
          e.message.isEmpty ? l10n.impersonationWrongPassword : e.message,
        );
      }
      return;
    } catch (_) {
      if (context.mounted) context.appError(l10n.impersonationStartFailed);
      return;
    }
  }
  if (!context.mounted) return;
  final target = await showImpersonationTargetPicker(context, ref);
  if (target == null) return;
  try {
    await ref
        .read(sessionProvider.notifier)
        .startImpersonation(targetEmployeeId: target.employeeId);
    if (context.mounted) context.go('/dashboard');
  } on ApiException catch (e) {
    if (context.mounted) {
      context.appError(
        e.message.isEmpty ? l10n.impersonationStartFailed : e.message,
      );
    }
  } catch (_) {
    if (context.mounted) context.appError(l10n.impersonationStartFailed);
  }
}

/// 密码确认弹窗（二次密码，ADR-013）。返回明文密码或 null（取消）。
Future<String?> showImpersonationPasswordDialog(BuildContext context) {
  final l10n = AppLocalizations.of(context);
  final controller = TextEditingController();
  String? errorText;
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        void confirm() {
          final pwd = controller.text;
          if (pwd.isEmpty) {
            setState(() => errorText = l10n.impersonationWrongPassword);
            return;
          }
          Navigator.pop(ctx, pwd);
        }

        return AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.swap_horiz_rounded),
              const SizedBox(width: 8),
              Text(l10n.impersonationEnterPasswordTitle),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.impersonationEnterPasswordHint,
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                obscureText: true,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: l10n.impersonationPasswordLabel,
                  errorText: errorText,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) {
                  if (errorText != null) setState(() => errorText = null);
                },
                onSubmitted: (_) => confirm(),
              ),
            ],
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.commonCancel),
            ),
            FilledButton(onPressed: confirm, child: Text(l10n.commonConfirm)),
          ],
        );
      },
    ),
  );
}

/// 目标选择器：搜索 + 列表（姓名 / 部门 · 岗位），高亮「最近」。
Future<ImpersonationTarget?> showImpersonationTargetPicker(
  BuildContext context,
  WidgetRef ref,
) {
  final l10n = AppLocalizations.of(context);
  final recentIds = ref.read(sessionProvider).recentImpersonatedEmployeeIds;
  final sheet = _ImpersonationTargetSheet(
    loader: (kw) => ref.read(impersonationRepositoryProvider).searchTargets(kw),
    title: l10n.impersonationTargetPickerTitle,
    searchHint: l10n.impersonationSearchHint,
    recentIds: recentIds.toSet(),
    noTargetsMessage: l10n.impersonationNoTargets,
    recentLabel: l10n.impersonationRecent,
  );
  if (context.breakpoint.isCompact) {
    return showModalBottomSheet<ImpersonationTarget>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.85,
          child: sheet,
        ),
      ),
    );
  }
  return showGeneralDialog<ImpersonationTarget>(
    context: context,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 250),
    pageBuilder: (ctx, _, _) => Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: Theme.of(ctx).colorScheme.surface,
        child: SizedBox(width: 420, height: double.infinity, child: sheet),
      ),
    ),
    transitionBuilder: (ctx, anim, _, child) => SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );
}

class _ImpersonationTargetSheet extends StatefulWidget {
  const _ImpersonationTargetSheet({
    required this.loader,
    required this.title,
    required this.searchHint,
    required this.recentIds,
    required this.noTargetsMessage,
    required this.recentLabel,
  });

  final Future<List<ImpersonationTarget>> Function(String? keyword) loader;
  final String title;
  final String searchHint;
  final Set<String> recentIds;
  final String noTargetsMessage;
  final String recentLabel;

  @override
  State<_ImpersonationTargetSheet> createState() =>
      _ImpersonationTargetSheetState();
}

class _ImpersonationTargetSheetState extends State<_ImpersonationTargetSheet> {
  String _keyword = '';
  bool _loading = true;
  Object? _error;
  List<ImpersonationTarget> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final kw = _keyword.trim();
      final items = await widget.loader(kw.isEmpty ? null : kw);
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: UtenSearchBar(
            hint: widget.searchHint,
            onChanged: (v) {
              _keyword = v;
              _load();
            },
          ),
        ),
        Expanded(child: _buildBody(theme)),
      ],
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) return const UtenSkeletonList();
    if (_error != null) {
      return UtenEmpty.error(
        message: '$_error',
        actionLabel: AppLocalizations.of(context).commonConfirm,
        onAction: _load,
      );
    }
    if (_items.isEmpty) {
      return UtenEmpty(
        icon: Icons.person_off_outlined,
        message: widget.noTargetsMessage,
      );
    }
    return ListView.separated(
      itemCount: _items.length,
      separatorBuilder: (_, _) =>
          const Divider(height: 1, indent: 16, endIndent: 16),
      itemBuilder: (context, i) {
        final t = _items[i];
        final isRecent = widget.recentIds.contains(t.employeeId);
        final sub = [
          t.departmentName,
          t.positionName,
        ].whereType<String>().where((s) => s.isNotEmpty).join(' · ');
        return ListTile(
          leading: Icon(
            Icons.person_outline_rounded,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          title: Row(
            children: [
              Flexible(child: Text(t.name, overflow: TextOverflow.ellipsis)),
              if (isRecent) ...[
                const SizedBox(width: 6),
                _RecentBadge(label: widget.recentLabel),
              ],
            ],
          ),
          subtitle: sub.isEmpty ? null : Text(sub),
          onTap: () => Navigator.of(context).pop(t),
        );
      },
    );
  }
}

class _RecentBadge extends StatelessWidget {
  const _RecentBadge({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
