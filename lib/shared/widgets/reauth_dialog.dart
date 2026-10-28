// 统一的「重新输入登录密码」弹窗 (ADR-110)。
//
// 所有敏感操作共用这一个弹窗：设/撤超管、授权与数据范围、重置他人密码、进入切换人、
// 保存系统设置、提交改手机号/姓名。页面不自己问密码——服务端回
// 403 REAUTH_REQUIRED 时由网络层 (StepUpInterceptor) 经 StepUpCoordinator 弹出本框，
// 换到会话凭证后自动重发原请求，连续操作复用，空闲五分钟后重新验证。
//
// 输错：留在框里提示「密码不正确」，可重试；连续输错到上限：框里提示暂停多久、不再可输
// (服务端同时让当前登录失效，关掉弹窗后会回到登录页)。
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/buttons/uten_button.dart';
import '../../components/feedback/uten_busy_overlay.dart';
import '../../components/inputs/uten_input.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/api_client.dart';
import '../../core/network/step_up_coordinator.dart';
import '../../core/network/user_activity.dart';
import '../../core/ui/opportunistic_dialog_coordinator.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/uten_colors.dart';
import '../../core/theme/uten_tokens.dart';
import '../../features/auth/repositories/step_up_repository.dart';
import '../providers/authenticated_scope_provider.dart';

/// 弹出再认证框；成功返回会话凭证，取消返回 null。
///
/// 触发再认证的请求往往正挂着整页忙碌遮罩 (保存权限、系统设置…)：弹框期间让遮罩让位，
/// 否则遮罩会被导航器抬到密码框之上，请求等密码、遮罩等请求，整页卡死。
Future<String?> showReauthDialog(
  BuildContext context, {
  required Future<String> Function(String password) verify,
}) {
  DialogPriorityReservation? priority;
  try {
    priority = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(opportunisticDialogCoordinatorProvider).prioritize();
  } on StateError {
    // This public dialog also works in standalone widget hosts without any
    // Riverpod scope; those hosts cannot contain our optional reminder.
  }
  return UtenBusyOverlay.yieldWhile(
    () => showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ReauthDialog(verify: verify),
    ),
  ).whenComplete(() => priority?.release());
}

class ReauthDialog extends StatefulWidget {
  const ReauthDialog({super.key, required this.verify});

  final Future<String> Function(String password) verify;

  @override
  State<ReauthDialog> createState() => _ReauthDialogState();
}

class _ReauthDialogState extends State<ReauthDialog> {
  final _controller = TextEditingController();
  String? _error;
  bool _busy = false;
  bool _locked = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    final password = _controller.text;
    if (password.isEmpty) {
      setState(() => _error = '请输入登录密码');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final token = await widget.verify(password);
      if (mounted) Navigator.of(context).pop(token);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == 'UNAUTHORIZED') {
        // 本次登录已失效：关闭弹窗，由会话层带回登录页。
        Navigator.of(context).pop();
        return;
      }
      if (e.code == 'REAUTH_LOCKED') {
        setState(() {
          _busy = false;
          _locked = true;
          _error = e.message;
        });
        return;
      }
      setState(() {
        _busy = false;
        _error = e.message.isEmpty ? '密码不正确' : e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '验证没有完成，请稍后再试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return UtenAlertDialog(
      key: const Key('reauth-dialog'),
      title: const Row(
        children: [
          Icon(Icons.lock_outline_rounded),
          SizedBox(width: UtenSpacing.s8),
          Text('请确认是你本人'),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '请输入你的登录密码。确认后可连续操作；停止操作 5 分钟后，需要再次确认。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            UtenInput(
              key: const Key('reauth-password'),
              label: '登录密码',
              isPassword: true,
              controller: _controller,
              enabled: !_busy && !_locked,
              errorMessage: _error,
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onFieldSubmitted: (_) => unawaited(_confirm()),
            ),
            // 服务端给的原因 (还能试几次 / 暂停多久) 要让人一眼看到，不只藏在输入框的提示图标里。
            if (_error != null) ...[
              const SizedBox(height: UtenSpacing.s8),
              Text(
                _error!,
                key: const Key('reauth-error'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: UtenColors.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        UtenButton(
          type: UtenButtonType.ghost,
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(_locked ? '关闭' : '取消'),
        ),
        UtenButton(
          key: const Key('reauth-confirm'),
          onPressed: _busy || _locked ? null : () => unawaited(_confirm()),
          child: const Text('确认'),
        ),
      ],
    );
  }
}

/// 应用根部的不渲染宿主：把统一弹窗登记给 [StepUpCoordinator]。
class StepUpPromptHost extends ConsumerStatefulWidget {
  const StepUpPromptHost({super.key, this.navigatorContext});

  /// 取弹窗宿主上下文；默认用应用导航器。
  final BuildContext? Function()? navigatorContext;

  @override
  ConsumerState<StepUpPromptHost> createState() => _StepUpPromptHostState();
}

class _StepUpPromptHostState extends ConsumerState<StepUpPromptHost> {
  void Function()? _unregister;
  Timer? _activityTimer;

  @override
  void initState() {
    super.initState();
    _unregister = StepUpCoordinator.instance.register(_prompt);
    UserActivity.addListener(_recordActivity);
    ref.listenManual(authenticatedScopeProvider, (previous, next) {
      if (previous != next) StepUpCoordinator.instance.clear();
    });
    ref.listenManual(apiClientProvider, (previous, next) {
      if (!identical(previous, next)) StepUpCoordinator.instance.clear();
    });
    _activityTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(_keepAlive()),
    );
  }

  @override
  void dispose() {
    _activityTimer?.cancel();
    UserActivity.removeListener(_recordActivity);
    _unregister?.call();
    super.dispose();
  }

  void _recordActivity() => StepUpCoordinator.instance.recordActivity();

  Future<void> _keepAlive() async {
    final scope = ref.read(authenticatedScopeProvider);
    if (scope == null || scope.actorId != null) return;
    final repository = ref.read(stepUpRepositoryProvider);
    if (repository is! StepUpActivityRepository) return;
    final api = ref.read(apiClientProvider);
    await StepUpCoordinator.instance.keepAliveIfActive((token) async {
      await (repository as StepUpActivityRepository).recordActivity(token);
      if (!mounted ||
          ref.read(authenticatedScopeProvider) != scope ||
          !identical(ref.read(apiClientProvider), api)) {
        throw StateError('Reauthentication identity changed');
      }
    });
  }

  Future<String?> _prompt() async {
    final hostContext =
        (widget.navigatorContext ?? () => appNavigatorKey.currentContext)();
    if (hostContext == null || !hostContext.mounted) return null;
    final scope = ref.read(authenticatedScopeProvider);
    final api = ref.read(apiClientProvider);
    final repository = ref.read(stepUpRepositoryProvider);
    return showReauthDialog(
      hostContext,
      verify: (password) async {
        final token = await repository.verify(password);
        if (!mounted ||
            ref.read(authenticatedScopeProvider) != scope ||
            !identical(ref.read(apiClientProvider), api)) {
          throw ApiException('SESSION_CHANGED', '登录身份或服务器已变化，请重新确认');
        }
        return token;
      },
    );
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
