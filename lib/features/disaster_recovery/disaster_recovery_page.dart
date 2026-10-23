import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../components/buttons/uten_button.dart';
import '../../components/cards/uten_card.dart';
import '../../components/layout/uten_app_bar.dart';
import '../../components/layout/uten_content_container.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/server_config.dart';
import '../../core/router/route_names.dart';
import '../../core/theme/uten_tokens.dart';
import '../../shared/providers/session_provider.dart';
import '../../shared/widgets/server_switch_dialog.dart';
import 'disaster_recovery_text.dart';

const _configuredRescueUrl = String.fromEnvironment(
  'DR_CONTROL_PLANE_URL',
  defaultValue: 'https://admin.justplayit.cn',
);

/// A trusted build-time address. Never read it from an unavailable business API,
/// local preferences, URL parameters or an error response.
Uri? trustedRescueUri(String value, {required bool releaseMode}) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !uri.hasAuthority ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    return null;
  }
  if (uri.scheme == 'https') {
    return uri;
  }
  if (!releaseMode && uri.scheme == 'http' && uri.host == '127.0.0.1') {
    return uri;
  }
  return null;
}

final disasterRecoveryUriProvider = Provider<Uri?>(
  (ref) => trustedRescueUri(_configuredRescueUrl, releaseMode: kReleaseMode),
);

typedef RescueLauncher = Future<bool> Function(Uri uri);
final rescueLauncherProvider = Provider<RescueLauncher>(
  (ref) =>
      (uri) => launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
        webOnlyWindowName: '_blank',
      ),
);

class DisasterRecoveryPage extends ConsumerStatefulWidget {
  const DisasterRecoveryPage({super.key});

  @override
  ConsumerState<DisasterRecoveryPage> createState() =>
      _DisasterRecoveryPageState();
}

class _DisasterRecoveryPageState extends ConsumerState<DisasterRecoveryPage> {
  bool _busy = false;
  Uri? _enrollmentUri;
  String? _message;

  Future<void> _open(Uri uri) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (!await ref.read(rescueLauncherProvider)(uri) && mounted) {
        setState(() => _message = '无法打开独立救援入口，请使用已登记的救援地址。');
      }
    } catch (_) {
      if (mounted) setState(() => _message = '独立救援入口暂不可用，请检查这台设备的网络。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _enroll(Uri base) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      // Existing step-up interceptor requires the super-admin's fresh password.
      // Only enrollment uses ERP; opening rescue never makes this request.
      final response = await ref
          .read(apiClientProvider)
          .post(
            '/admin/disaster-recovery/enrollment',
            body: const <String, dynamic>{},
          );
      final token = response['enrollmentToken'];
      if (token is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{48,128}$').hasMatch(token)) {
        throw const FormatException();
      }
      if (mounted) {
        setState(() {
          _enrollmentUri = base.replace(
            path: '/enroll',
            fragment: 'enrollment=$token',
          );
          _message = '一次性绑定已准备，请立即继续。绑定将在五分钟内过期，不要分享页面地址。';
        });
      }
    } on ApiException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } catch (_) {
      if (mounted) setState(() => _message = '无法准备救援身份绑定，请核验公司内网连接和短期绑定窗口。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rescue = ref.watch(disasterRecoveryUriProvider);
    final connection = ref.watch(apiBaseUrlProvider);
    final superAdmin =
        ref.exists(sessionProvider) &&
        ref.watch(
          sessionProvider.select((state) => state.user?.superAdmin == true),
        );
    return Scaffold(
      appBar: UtenAppBar(
        title: recoveryText(context, '运行与灾备'),
        showBackButton: true,
        showPagePermissionAction: false,
      ),
      body: UtenContentContainer.narrow(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              UtenCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      recoveryText(context, '本机连接'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: UtenSpacing.s8),
                    Text(connection),
                    Text(recoveryText(context, '这里只调整这台设备的连接，不改变公司业务运行位置。')),
                    UtenButton(
                      type: UtenButtonType.secondary,
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => const ServerSwitchDialog(),
                      ),
                      child: Text(recoveryText(context, '调整连接')),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: UtenSpacing.s16),
              UtenCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      recoveryText(context, '独立救援入口'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: UtenSpacing.s8),
                    Text(
                      recoveryText(
                        context,
                        '公司业务服务不可达时，仍可在独立入口查询备份、管理已登记目标和恢复演练。需要另行绑定的救援口令与动态验证码。',
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s8),
                    Text(
                      rescue == null
                          ? recoveryText(context, '尚未登记可信救援地址，请联系管理员完成入口验收。')
                          : '${recoveryText(context, '已登记入口')}: ${rescue.host}${rescue.hasPort ? ':${rescue.port}' : ''}',
                    ),
                    Text(
                      recoveryText(
                        context,
                        '现场先关机并隔离旧主，核验独立恢复证据后，由超级管理员人工启用备用服务；网络断开不会自动切换。',
                      ),
                    ),
                    UtenButton(
                      key: const Key('open-independent-rescue'),
                      isLoading: _busy,
                      onPressed: rescue == null || _busy
                          ? null
                          : () => _open(rescue),
                      child: Text(recoveryText(context, '打开独立救援入口')),
                    ),
                    if (superAdmin && rescue != null) ...[
                      const SizedBox(height: UtenSpacing.s12),
                      Text(
                        recoveryText(
                          context,
                          '出差时按人开通远程访问，回来后关闭；同时最多授权5人，不是固定名单。',
                        ),
                      ),
                      UtenButton(
                        type: UtenButtonType.secondary,
                        onPressed: () =>
                            context.push(RouteName.adminPermissions),
                        child: Text(recoveryText(context, '管理出差远程授权')),
                      ),
                      const SizedBox(height: UtenSpacing.s12),
                      Text(
                        recoveryText(
                          context,
                          '首次绑定须在公司内网，由超级管理员本人重新验证，并由运维开放短期绑定窗口。',
                        ),
                      ),
                      UtenButton(
                        type: UtenButtonType.secondary,
                        isLoading: _busy,
                        onPressed: _busy
                            ? null
                            : _enrollmentUri == null
                            ? () => _enroll(rescue)
                            : () => _open(_enrollmentUri!),
                        child: Text(
                          recoveryText(
                            context,
                            _enrollmentUri == null ? '绑定独立救援身份' : '继续绑定独立救援身份',
                          ),
                        ),
                      ),
                    ],
                    if (_message != null)
                      Padding(
                        padding: const EdgeInsets.only(top: UtenSpacing.s12),
                        child: Text(
                          recoveryText(context, _message!),
                          key: const Key('rescue-notice'),
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
