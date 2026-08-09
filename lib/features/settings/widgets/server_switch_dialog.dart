// 服务器切换对话框：选择「自动 / 仅本地 / 仅云端」并配置云端地址。
// 自动（默认）：在公司内网自动用本地后端；在外网用云端后端（仅 remote_access 授权账号可登录云端）。
// 应用后 invalidate(apiBaseUrlProvider) 让 Dio 重建指向新地址。
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
              Text('当前地址：$effective', style: theme.textTheme.bodySmall),
              const SizedBox(height: 12),
              UtenSegmentedFilter<ServerMode>(
                segments: const [
                  UtenSegment(value: ServerMode.auto, label: '自动'),
                  UtenSegment(value: ServerMode.local, label: '仅本地'),
                  UtenSegment(value: ServerMode.cloud, label: '仅云端'),
                ],
                selected: _mode,
                onChanged: (m) => setState(() => _mode = m),
              ),
              const SizedBox(height: 8),
              Text(_modeHint(), style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 12),
              TextField(
                controller: _ctrl,
                decoration: const InputDecoration(
                  labelText: '云端地址',
                  hintText: 'https://cloud.example.com/api',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                keyboardType: TextInputType.url,
                autocorrect: false,
                enabled: _mode != ServerMode.local,
              ),
            ],
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: _busy ? null : _resetToDefault,
          child: const Text('恢复默认'),
        ),
        FilledButton(
          onPressed: _busy ? null : _apply,
          child: const Text('应用'),
        ),
      ],
    );
  }

  String _modeHint() {
    switch (_mode) {
      case ServerMode.auto:
        return '在公司内网自动用本地后端；在外网用上方云端地址（仅被授权 remote_access 的账号可登录云端）。';
      case ServerMode.local:
        return '强制只用公司内网本地后端（排障用）。';
      case ServerMode.cloud:
        return '强制只用云端后端（排障用）；须填上方云端地址。';
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
    final raw = _ctrl.text.trim();
    if (_mode == ServerMode.cloud && raw.isEmpty) {
      context.appError('仅云端模式需要填写云端地址');
      return;
    }
    String? resolved;
    if (raw.isNotEmpty) {
      try {
        resolveCloudUrl(raw); // 校验，非法抛 StateError
      } on StateError catch (e) {
        context.appError('云端地址无效：${e.message}');
        return;
      }
      resolved = raw;
    }
    setState(() => _busy = true);
    try {
      await writeServerMode(prefs, _mode);
      await writeCloudUrl(prefs, resolved);
      // 触发所有 watch apiBaseUrlProvider 的 Dio 重建指向新地址。
      ref.invalidate(apiBaseUrlProvider);
      if (mounted) {
        context.appSuccess('已保存，切换服务器后请重新登录');
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) context.appError('保存失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
