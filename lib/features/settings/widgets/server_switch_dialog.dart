// 服务器切换对话框：原生 Release 只能在两个构建期可信端点间切换；Debug
// 可显式覆盖云端地址。Web 始终走同源 /api，由访问入口 / split-horizon DNS 路由。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/layout/uten_segmented_filter.dart';
import '../../../core/network/server_config.dart';
import '../../../core/network/server_selection.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/providers/shared_providers.dart';

class ServerSwitchDialog extends ConsumerStatefulWidget {
  const ServerSwitchDialog({super.key});

  @override
  ConsumerState<ServerSwitchDialog> createState() => _ServerSwitchDialogState();
}

class _ServerSwitchDialogState extends ConsumerState<ServerSwitchDialog> {
  late final TextEditingController _ctrl;
  late ServerMode _mode;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final prefs = ref.read(sharedPreferencesProvider);
    _mode = readServerMode(prefs);
    _ctrl = TextEditingController(text: readCloudUrl(prefs) ?? '');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final effective = ref.watch(apiBaseUrlProvider);
    final webSameOrigin = kIsWeb && effective.startsWith('/');
    final prefs = ref.watch(sharedPreferencesProvider);
    final cloud = readCloudUrl(prefs);
    final localReachable = ref.watch(localServerReachableProvider);
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('服务器'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _EndpointStatus(
                label: webSameOrigin ? '当前同源接口' : '当前生效地址',
                value: effective,
                healthy: kIsWeb ? null : localReachable,
              ),
              const SizedBox(height: 12),
              if (kIsWeb)
                Text(
                  webSameOrigin
                      ? '生产 Web 版始终请求当前页面同源的 /api。公司内网与云端请使用管理员提供的对应入口；'
                            '同源接口可达不代表设备位于公司局域网。'
                      : '当前为 Debug Web 开发端点。生产 Web 构建会强制使用同源 /api，且不会用同源探针推断局域网位置。',
                  style: theme.textTheme.bodySmall,
                )
              else ...[
                UtenSegmentedFilter<ServerMode>(
                  segments: const [
                    UtenSegment(value: ServerMode.auto, label: '自动'),
                    UtenSegment(value: ServerMode.local, label: '仅本地'),
                    UtenSegment(value: ServerMode.cloud, label: '仅云端'),
                  ],
                  selected: _mode,
                  onChanged: (mode) {
                    if (mode == ServerMode.cloud && cloud == null) {
                      context.appError('此版本未配置云端服务，暂时只能使用公司内网服务');
                      return;
                    }
                    setState(() => _mode = mode);
                  },
                ),
                const SizedBox(height: 8),
                Text(
                  _modeHint(cloudConfigured: cloud != null),
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                if (kDebugMode)
                  TextField(
                    controller: _ctrl,
                    decoration: const InputDecoration(
                      labelText: 'Debug 云端地址覆盖',
                      hintText: 'https://cloud.example.com/api',
                      helperText: '仅调试构建保存；生产构建会忽略并清除此值',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    enabled: _mode != ServerMode.local,
                  )
                else
                  InputDecorator(
                    decoration: const InputDecoration(
                      labelText: '云端地址（构建托管）',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    child: SelectableText(cloud ?? '此版本未配置云端服务'),
                  ),
              ],
            ],
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: kIsWeb
          ? [
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('知道了'),
              ),
            ]
          : [
              TextButton(
                onPressed: _busy ? null : _resetToDefault,
                child: const Text('恢复自动'),
              ),
              FilledButton(
                onPressed: _busy ? null : _apply,
                child: const Text('应用'),
              ),
            ],
    );
  }

  String _modeHint({required bool cloudConfigured}) {
    switch (_mode) {
      case ServerMode.auto:
        return cloudConfigured
            ? '优先公司内网服务；不可达时切换到托管云端。云端登录仍须管理员授予远程访问权限。'
            : '优先公司内网服务；此版本未配置云端地址，内网不可达时不会连接其他主机。';
      case ServerMode.local:
        return '强制只用公司内网本地后端（排障用）。';
      case ServerMode.cloud:
        return '强制只用构建期可信云端后端（排障用）；账号须有远程访问权限。';
    }
  }

  Future<void> _resetToDefault() async {
    setState(() => _busy = true);
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      await writeServerMode(prefs, ServerMode.auto);
      await writeCloudUrl(prefs, null);
      ref.invalidate(apiBaseUrlProvider);
      if (mounted) {
        context.appSuccess('已恢复默认（自动）');
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) context.appError('恢复失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _apply() async {
    final prefs = ref.read(sharedPreferencesProvider);
    final trustedCloud = readCloudUrl(prefs);
    final raw = kDebugMode ? _ctrl.text.trim() : '';
    String? resolved;
    if (kDebugMode && raw.isNotEmpty) {
      try {
        resolveCloudUrl(raw); // 校验，非法抛 StateError
      } on StateError catch (e) {
        context.appError('云端地址无效：${e.message}');
        return;
      }
      resolved = raw;
    }
    final cloudAfterSave = kDebugMode ? resolved : trustedCloud;
    if (_mode == ServerMode.cloud && cloudAfterSave == null) {
      context.appError('此版本未配置可信云端地址，无法启用仅云端模式');
      return;
    }
    setState(() => _busy = true);
    try {
      await writeServerMode(prefs, _mode);
      await writeCloudUrl(prefs, resolved);
      // 触发所有 watch apiBaseUrlProvider 的 Dio 重建指向新地址。
      ref.invalidate(apiBaseUrlProvider);
      if (mounted) {
        context.appSuccess('已保存，客户端将使用所选可信服务器重新连接');
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) context.appError('保存失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _EndpointStatus extends StatelessWidget {
  const _EndpointStatus({
    required this.label,
    required this.value,
    required this.healthy,
  });

  final String label;
  final String value;
  final bool? healthy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: '$label：$value',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: theme.textTheme.labelMedium),
              const SizedBox(height: 4),
              SelectableText(value, style: theme.textTheme.bodySmall),
              if (healthy != null) ...[
                const SizedBox(height: 6),
                Text(
                  healthy! ? '公司内网服务探针：可达' : '公司内网服务探针：不可达',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: healthy!
                        ? theme.colorScheme.primary
                        : theme.colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
