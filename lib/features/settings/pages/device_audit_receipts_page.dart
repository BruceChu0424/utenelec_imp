// 本机设备信息与操作回执：按不可猜测的操作 ID 精确查询，不枚举共享设备上的全部历史。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/audit/device_audit_store.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';

class DeviceAuditReceiptsPage extends ConsumerStatefulWidget {
  const DeviceAuditReceiptsPage({
    super.key,
    required this.backRoute,
    this.initialOperationId,
  });

  final String backRoute;
  final String? initialOperationId;

  @override
  ConsumerState<DeviceAuditReceiptsPage> createState() =>
      _DeviceAuditReceiptsPageState();
}

class _DeviceAuditReceiptsPageState
    extends ConsumerState<DeviceAuditReceiptsPage> {
  final _operationController = TextEditingController();
  LocalAuditReceipt? _receipt;
  String? _error;
  bool _searched = false;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialOperationId?.trim();
    if (initial?.isNotEmpty == true) {
      _operationController.text = initial!;
      WidgetsBinding.instance.addPostFrameCallback((_) => _search());
    }
  }

  @override
  void dispose() {
    _operationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(currentDeviceAuditProfileProvider);
    return Scaffold(
      appBar: UtenAppBar(
        title: '本机信息与操作回执',
        leading: UtenBackButton(onPressed: () => context.go(widget.backRoute)),
      ),
      body: Semantics(
        key: const ValueKey('device-audit-read-only'),
        container: true,
        explicitChildNodes: true,
        readOnly: true,
        label: '本机操作回执只读核查',
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
          child: UtenContentContainer.narrow(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _IntroCard(),
                const SizedBox(height: UtenSpacing.s16),
                profile.when(
                  loading: () => const UtenCard(
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (_, _) => const UtenCard(
                    child: Text('当前设备信息读取失败；仍可按操作 ID 尝试查询已有回执。'),
                  ),
                  data: (value) => _DeviceProfileCard(profile: value),
                ),
                const SizedBox(height: UtenSpacing.s16),
                _SearchCard(
                  controller: _operationController,
                  loading: _loading,
                  error: _error,
                  onSearch: _search,
                ),
                const SizedBox(height: UtenSpacing.s16),
                if (_receipt case final receipt?)
                  _ReceiptResultCard(
                    receipt: receipt,
                    onCopy: () => _copyReceipt(receipt),
                  )
                else if (_searched && _error == null)
                  const UtenCard(
                    child: Text(
                      '这台设备没有找到该操作 ID。可能来自另一台设备、已超过本机保留上限，或已按留存策略自动清理。',
                    ),
                  ),
                const SizedBox(height: UtenSpacing.s32),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _search() async {
    final operationId = _operationController.text.trim();
    if (!_uuidPattern.hasMatch(operationId)) {
      setState(() {
        _error = '请输入审计详情中的完整本地操作 ID(UUID)';
        _receipt = null;
        _searched = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      try {
        await ref
            .read(apiClientProvider)
            .post(ApiEndpoints.adminAuditLocalReceiptVerification(operationId));
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _error = '需联网完成授权核查';
          _receipt = null;
          _searched = false;
        });
        return;
      }

      final value = await ref
          .read(deviceAuditStoreProvider)
          .findReceipt(operationId);
      if (!mounted) return;
      setState(() {
        _receipt = value;
        _searched = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '本机回执读取失败，请稍后重试';
        _receipt = null;
        _searched = false;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _copyReceipt(LocalAuditReceipt receipt) async {
    final value = const JsonEncoder.withIndent('  ').convert({
      ...receipt.toJson(),
      'integrityVerified': receipt.integrityVerified,
    });
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) context.appSuccess('已复制本机回执 JSON');
  }
}

class _IntroCard extends StatelessWidget {
  const _IntroCard();

  @override
  Widget build(BuildContext context) {
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.policy_outlined,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: UtenSpacing.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '原设备核查入口',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s8),
                    const Text(
                      '本机最多保存最近 300 条回执，并按服务器公开的审计总留存月数清理。为保护共享设备上的其他使用者，这里不直接列出全部历史，只按完整操作 ID 精确查询。',
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          const Wrap(
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s8,
            children: [
              UtenStatusBadge(
                label: '只读核查',
                type: UtenStatusBadgeType.info,
                icon: Icons.visibility_outlined,
                size: UtenStatusBadgeSize.small,
              ),
              UtenStatusBadge(
                label: '不保存请求体 / 查询参数 / 令牌',
                type: UtenStatusBadgeType.info,
                icon: Icons.shield_outlined,
                size: UtenStatusBadgeSize.small,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DeviceProfileCard extends StatelessWidget {
  const _DeviceProfileCard({required this.profile});

  final DeviceAuditProfile profile;

  @override
  Widget build(BuildContext context) {
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '当前设备',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: UtenSpacing.s12),
          Wrap(
            spacing: UtenSpacing.s24,
            runSpacing: UtenSpacing.s16,
            children: [
              _Fact(label: '设备名称', value: profile.deviceName ?? '平台未提供'),
              _Fact(label: '设备厂商', value: profile.manufacturer ?? '平台未提供'),
              _Fact(label: '设备型号', value: profile.model ?? '平台未提供'),
              _Fact(label: '平台', value: profile.platform),
              _Fact(label: '系统版本', value: profile.osVersion ?? '平台未提供'),
              _Fact(
                label: '应用版本 / 构建',
                value: '${profile.appVersion} / ${profile.appBuild}',
              ),
              _CopyFact(label: '本机安装标识', value: profile.installationId),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          Text(
            '本机安装标识是随机应用实例 UUID，不是 IMEI、MAC、硬盘序列号或物理设备认证。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchCard extends StatelessWidget {
  const _SearchCard({
    required this.controller,
    required this.loading,
    required this.error,
    required this.onSearch,
  });

  final TextEditingController controller;
  final bool loading;
  final String? error;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '查询本机操作回执',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: UtenSpacing.s8),
          const Text('从审计详情复制“本地操作 ID”，再回到原操作设备粘贴查询。'),
          const SizedBox(height: UtenSpacing.s12),
          TextField(
            controller: controller,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => onSearch(),
            decoration: UtenInputDecoration(
              InputDecoration(
                labelText: '本地操作 ID',
                hintText: 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx',
                error: utenFieldError(error),
                prefixIcon: const Icon(Icons.fingerprint_rounded),
              ),
            ),
          ),
          const SizedBox(height: UtenSpacing.s12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: loading ? null : onSearch,
              icon: loading
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.search_rounded),
              label: Text(loading ? '查询中' : '查询本机回执'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReceiptResultCard extends StatelessWidget {
  const _ReceiptResultCard({required this.receipt, required this.onCopy});

  final LocalAuditReceipt receipt;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '查询结果',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              UtenStatusBadge(
                label: receipt.integrityVerified ? '完整性通过' : '完整性失败',
                type: receipt.integrityVerified
                    ? UtenStatusBadgeType.success
                    : UtenStatusBadgeType.danger,
                icon: receipt.integrityVerified
                    ? Icons.verified_outlined
                    : Icons.gpp_bad_outlined,
                size: UtenStatusBadgeSize.small,
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          Wrap(
            spacing: UtenSpacing.s24,
            runSpacing: UtenSpacing.s16,
            children: [
              _CopyFact(label: '本地操作 ID', value: receipt.clientEventId),
              _CopyFact(label: '本机安装标识', value: receipt.installationId),
              _Fact(label: '设备', value: receipt.device.displayLabel),
              _Fact(label: '请求尝试', value: '${receipt.allAttempts.length} 次'),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          for (final entry in receipt.allAttempts.indexed) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(UtenSpacing.s12),
              margin: const EdgeInsets.only(bottom: UtenSpacing.s8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: UtenRadius.mdAll,
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '尝试 ${entry.$1 + 1} · ${entry.$2.method} ${entry.$2.path}',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: UtenSpacing.s8),
                  SelectableText(
                    '服务器 Request ID：${entry.$2.serverRequestId ?? '—'}\n'
                    '状态：${entry.$2.statusCode ?? '—'} · ${entry.$2.outcome}\n'
                    '开始：${_time(entry.$2.startedAt)}\n'
                    '完成：${_time(entry.$2.completedAt)}',
                  ),
                ],
              ),
            ),
          ],
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              onPressed: onCopy,
              icon: const Icon(Icons.copy_all_outlined),
              label: const Text('复制回执 JSON'),
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
          Text(
            '完整性通过表示内容与本机安全存储密钥计算出的 HMAC 一致；它不是服务器签名，也不能证明某一物理设备或某个人绝对真实。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 240,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: UtenSpacing.s4),
          SelectableText(value),
        ],
      ),
    );
  }
}

class _CopyFact extends StatelessWidget {
  const _CopyFact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 320,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _Fact(label: label, value: value),
          ),
          IconButton(
            tooltip: '复制$label',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: value));
              if (context.mounted) context.appSuccess('已复制$label');
            },
            icon: const Icon(Icons.copy_rounded),
          ),
        ],
      ),
    );
  }
}

String _time(String? value) {
  final parsed = value == null ? null : DateTime.tryParse(value)?.toLocal();
  if (parsed == null) return '—';
  String two(int number) => number.toString().padLeft(2, '0');
  return '${parsed.year}-${two(parsed.month)}-${two(parsed.day)} '
      '${two(parsed.hour)}:${two(parsed.minute)}:${two(parsed.second)}';
}

final _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
);
