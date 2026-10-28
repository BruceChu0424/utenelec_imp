import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../repositories/permission_template_repository.dart';
import '../models/permission_template.dart';
import 'admin_permission_transfer_actions.dart';

class PermissionTemplateBindingStrip extends ConsumerStatefulWidget {
  const PermissionTemplateBindingStrip({
    super.key,
    required this.kind,
    required this.targetId,
    this.enabled = true,
  });
  final String kind;
  final String targetId;
  final bool enabled;
  @override
  ConsumerState<PermissionTemplateBindingStrip> createState() =>
      _BindingState();
}

class _BindingState extends ConsumerState<PermissionTemplateBindingStrip> {
  bool _busy = false;
  Future<void> _unbind(PermissionTemplateBinding expected) async {
    if (_busy || !widget.enabled) return;
    final target = widget.targetId;
    final kind = widget.kind;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    bool current() =>
        mounted &&
        widget.enabled &&
        target == widget.targetId &&
        kind == widget.kind &&
        boundary == ref.read(sensitiveReadBoundaryProvider) &&
        ref.read(isSuperAdminProvider) &&
        ref.read(currentPermissionsProvider).contains(Perm.authorizationManage);
    if (!mounted || !current()) return;
    final confirmed = await UtenDialog.show(
      context,
      title: '解除模板关联',
      content: const Text('解除后保留当前权限，转为手工设置；之后模板修改不再同步到此对象。'),
      confirmLabel: '解除关联',
    );
    if (!current() || confirmed != true) return;
    setState(() => _busy = true);
    try {
      final scope = await ref
          .read(apiClientProvider)
          .captureRequestScope(isCurrent: current);
      await scope.run(
        () => ref
            .read(permissionTemplateRepositoryProvider)
            .unbind(
              userIds: kind == 'user' ? [target] : const [],
              departmentIds: kind == 'department' ? [target] : const [],
              expectedBindings: [expected],
            ),
      );
      if (!mounted || !current()) return;
      refreshPermissionConfiguration(ref);
      context.appSuccess('已解除关联，当前权限已保留');
    } catch (error) {
      if (mounted && current()) {
        ref.invalidate(permissionTemplateBindingsProvider);
        refreshPermissionConfiguration(ref);
        context.appError(
          error is ApiException ? error.message : '操作结果未确认，请刷新核对关联状态',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ref
      .watch(permissionTemplateBindingsProvider)
      .when(
        loading: () => const SizedBox.shrink(),
        error: (_, _) => TextButton.icon(
          onPressed: () => ref.invalidate(permissionTemplateBindingsProvider),
          icon: const Icon(Icons.refresh, size: 16),
          label: const Text('模板关联加载失败，重试'),
        ),
        data: (items) {
          final binding = items
              .where(
                (item) =>
                    item.kind == widget.kind &&
                    item.targetId == widget.targetId,
              )
              .firstOrNull;
          if (binding == null) return const SizedBox.shrink();
          return Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              const Icon(Icons.link_rounded, size: 16),
              Text('关联模板：${binding.templateName}'),
              Text(
                binding.legacySnapshot ? '旧版快照，重新应用后建立完整联动' : '随模板同步，个人取消优先',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              TextButton(
                onPressed: widget.enabled && !_busy
                    ? () => _unbind(binding)
                    : null,
                child: Text(_busy ? '处理中…' : '解除关联'),
              ),
            ],
          );
        },
      );
}
