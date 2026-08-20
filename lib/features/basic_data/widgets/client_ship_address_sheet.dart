// 客户收货地址簿弹窗（V300）：出货开单时选择/新增/删除该客户的收货地址。
//
// 交互（简而易懂）：
//  - 列表按最近使用降序；点某行 = 选用该地址（连同记住的联系电话回填表单）并关闭；
//  - 「新增地址」展开内联表单，提交即入库并自动选中回填；
//  - 删除按钮仅持 client_address:delete 者可见，删除前二次确认（后端仍独立鉴权）；
//  - 空态说明学习规则：保存出货单后会自动记住本次填写的地址。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../models/client_ship_address.dart';
import '../repositories/client_ship_address_repository.dart';

/// 弹客户收货地址簿；返回用户选用的地址（点返回/空白处关闭 = null）。
Future<ClientShipAddress?> showClientShipAddressSheet(
  BuildContext context,
  WidgetRef ref, {
  required String clientId,
  required String clientName,
}) {
  return showModalBottomSheet<ClientShipAddress?>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (ctx) =>
        _ClientShipAddressSheet(clientId: clientId, clientName: clientName),
  );
}

class _ClientShipAddressSheet extends ConsumerStatefulWidget {
  const _ClientShipAddressSheet({
    required this.clientId,
    required this.clientName,
  });

  final String clientId;
  final String clientName;

  @override
  ConsumerState<_ClientShipAddressSheet> createState() =>
      _ClientShipAddressSheetState();
}

class _ClientShipAddressSheetState
    extends ConsumerState<_ClientShipAddressSheet> {
  List<ClientShipAddress>? _items;
  String? _error;
  bool _adding = false;
  bool _busy = false;

  final _newAddr = TextEditingController();
  final _newPhone = TextEditingController();

  bool get _canDelete =>
      ref.read(isSuperAdminProvider) ||
      ref.read(currentPermissionsProvider).contains(Perm.clientAddressDelete);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _newAddr.dispose();
    _newPhone.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
    });
    try {
      final items = await ref
          .read(clientShipAddressRepositoryProvider)
          .list(widget.clientId);
      if (!mounted) return;
      setState(() => _items = items);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _items = const [];
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _items = const [];
        _error = '地址簿加载失败，请稍后重试';
      });
    }
  }

  Future<void> _add() async {
    final addr = _newAddr.text.trim();
    if (addr.length < 2) {
      context.appWarning('请填写收货地址（至少 2 个字符）');
      return;
    }
    setState(() => _busy = true);
    try {
      final saved = await ref
          .read(clientShipAddressRepositoryProvider)
          .add(widget.clientId, address: addr, linkPhone: _newPhone.text);
      if (!mounted) return;
      // 新增即选用：直接回填表单并关闭弹窗，少一步操作。
      Navigator.of(context).pop(saved);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('新增地址失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(ClientShipAddress item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('删除收货地址'),
        content: Text('确定删除地址「${item.address}」吗？删除后开单不再自动带出该地址。'),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogCtx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(clientShipAddressRepositoryProvider)
          .delete(widget.clientId, item.id);
      if (!mounted) return;
      context.appSuccess('已删除地址');
      await _load();
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('删除失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = _items;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        UtenSpacing.s16,
        UtenSpacing.s8,
        UtenSpacing.s16,
        MediaQuery.of(context).viewInsets.bottom + UtenSpacing.s16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '收货地址 · ${widget.clientName}',
              style: theme.textTheme.titleMedium,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              '保存出货单后会自动记住本次填写的地址与电话，下次开单默认带出最近使用的一条。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            if (items == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: UtenSpacing.s24),
                child: Center(
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              )
            else ...[
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
                  child: Text(
                    _error!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              if (items.isEmpty && _error == null)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: UtenSpacing.s16,
                  ),
                  child: Text(
                    '暂无已保存的收货地址。本次直接在表单填写并保存后，系统会记住它。',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              for (final item in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
                  child: _AddressTile(
                    item: item,
                    enabled: !_busy,
                    canDelete: _canDelete,
                    onTap: () => Navigator.of(context).pop(item),
                    onDelete: () => _delete(item),
                  ),
                ),
            ],
            const Divider(height: UtenSpacing.s24),
            if (!_adding)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('client-ship-address-add-toggle'),
                  icon: const Icon(Icons.add_location_alt_outlined, size: 18),
                  onPressed: _busy
                      ? null
                      : () => setState(() => _adding = true),
                  label: const Text('新增地址'),
                ),
              )
            else ...[
              TextField(
                key: const ValueKey('client-ship-address-new-address'),
                controller: _newAddr,
                autofocus: true,
                maxLength: 500,
                decoration: const InputDecoration(
                  labelText: '收货地址',
                  hintText: '省市区 + 详细地址',
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
              TextField(
                key: const ValueKey('client-ship-address-new-phone'),
                controller: _newPhone,
                maxLength: 64,
                decoration: const InputDecoration(
                  labelText: '联系电话（随地址一起记住，可空）',
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() => _adding = false),
                    child: const Text('收起'),
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  FilledButton.icon(
                    key: const ValueKey('client-ship-address-add-submit'),
                    onPressed: _busy ? null : _add,
                    icon: _busy
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check, size: 18),
                    label: const Text('保存并选用'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AddressTile extends StatelessWidget {
  const _AddressTile({
    required this.item,
    required this.enabled,
    required this.canDelete,
    required this.onTap,
    required this.onDelete,
  });

  final ClientShipAddress item;
  final bool enabled;
  final bool canDelete;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(UtenRadius.md),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: UtenSpacing.s12,
            vertical: UtenSpacing.s8,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.address,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (item.linkPhone != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          item.linkPhone!,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '已使用 ${item.usageCount} 次',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (canDelete)
                IconButton(
                  key: ValueKey('client-ship-address-delete-${item.id}'),
                  tooltip: '删除该地址',
                  icon: Icon(
                    Icons.delete_outline,
                    size: 20,
                    color: theme.colorScheme.error,
                  ),
                  onPressed: enabled ? onDelete : null,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
