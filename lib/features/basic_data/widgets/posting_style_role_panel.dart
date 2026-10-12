import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/authenticated_request_scope.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../core/network/server_config.dart';
import '../models/payment_style_node.dart';
import '../repositories/payment_style_repository.dart';
import '../repositories/posting_style_role_repository.dart';

class PostingStyleRolePanel extends ConsumerStatefulWidget {
  const PostingStyleRolePanel({super.key});
  @override
  ConsumerState<PostingStyleRolePanel> createState() =>
      _PostingStyleRolePanelState();
}

class _PostingStyleRolePanelState extends ConsumerState<PostingStyleRolePanel> {
  List<PostingStyleRole> _roles = const [];
  final _options = <String, List<PaymentStyleNode>>{};
  final _choices = <String, String>{};
  AuthenticatedRequestScope? _scope;
  int _generation = 0;
  int _operationGeneration = 0;
  bool _loading = true;
  String? _error, _saving;

  bool _readConfirmed = false;

  @override
  void initState() {
    super.initState();
    void readerChanged() {
      ++_generation;
      ++_operationGeneration;
      setState(() {
        _readConfirmed = false;
        _roles = const [];
        _scope = null;
        _options.clear();
        _choices.clear();
        _saving = null;
      });
      _load();
    }

    ref.listenManual(authenticatedScopeProvider, (previous, next) {
      if (previous != next) readerChanged();
    });
    ref.listenManual(apiBaseUrlProvider, (previous, next) {
      if (previous != next) readerChanged();
    });
    ref.listenManual(currentPermissionsProvider, (previous, next) {
      if (previous != next) readerChanged();
    });
    _load();
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _readConfirmed = false;
      _roles = const [];
      _options.clear();
      _error = null;
    });
    try {
      final repo = ref.read(postingStyleRoleRepositoryProvider);
      final scope = await repo.captureScope(
        isCurrent: () => mounted && generation == _generation,
      );
      final roles = await repo.list(scope);
      final options = <String, List<PaymentStyleNode>>{};
      if (roles.any((role) => role.canConfigure)) {
        for (final category
            in roles
                .where((r) => !r.usable)
                .map((r) => r.requiredCategory)
                .toSet()) {
          final tree = await scope.run(
            () => ref
                .read(paymentStyleRepositoryProvider)
                .tree(category: category),
          );
          await scope.verify();
          final nodes = <PaymentStyleNode>[];
          void collect(List<PaymentStyleNode> rows) {
            for (final row in rows) {
              if (row.category == category && row.status == '使用') {
                nodes.add(row);
              }
              collect(row.children);
            }
          }

          collect(tree);
          options[category] = nodes;
        }
      }
      await scope.verify();
      if (!mounted || generation != _generation) return;
      setState(() {
        _readConfirmed = true;
        _roles = roles;
        _options
          ..clear()
          ..addAll(options);
        _scope = scope;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _scope = null;
        _error = error is ApiException ? error.message : '加载科目用途失败，请刷新重试';
      });
    }
  }

  Future<void> _save(PostingStyleRole role) async {
    final style = _choices[role.roleKey];
    final scope = _scope;
    if (!role.canConfigure ||
        _saving != null ||
        style == null ||
        scope == null ||
        role.usable) {
      return;
    }
    final operation = ++_operationGeneration;
    bool current() => mounted && operation == _operationGeneration;
    setState(() {
      _saving = role.roleKey;
      _error = null;
    });
    try {
      await scope.verify();
      final updated = await ref
          .read(postingStyleRoleRepositoryProvider)
          .configure(role, style, scope);
      await scope.verify();
      if (!current()) return;
      setState(() {
        _roles = _roles
            .map((r) => r.roleKey == updated.roleKey ? updated : r)
            .toList();
        _choices.remove(role.roleKey);
      });
    } catch (error) {
      if (!current()) return;
      if (error is ApiException && error.code == 'CONFLICT') {
        await _load();
      }
      if (!current()) return;
      setState(() {
        _error = error is ApiException ? error.message : '保存科目用途失败，请核对后重试';
      });
    } finally {
      if (current()) setState(() => _saving = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '系统科目用途',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: '刷新',
                    onPressed: _saving == null ? _load : null,
                    icon: const Icon(Icons.refresh),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: _saving == null
                        ? () => Navigator.of(context).pop()
                        : null,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (_loading)
              const Expanded(child: Center(child: CircularProgressIndicator()))
            else if (!_readConfirmed)
              const Expanded(child: Center(child: Text('当前账号无权查看科目用途')))
            else
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    const Text('为尚未配置的用途选择对应类别的独立科目。已配置用途保留原科目。'),
                    const SizedBox(height: 16),
                    for (final role in _roles)
                      Padding(
                        key: ValueKey('posting-role-${role.roleKey}'),
                        padding: const EdgeInsets.only(bottom: 20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              role.description,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 6),
                            if (role.usable)
                              Text('已配置：${role.styleName ?? '原科目'}')
                            else if (!role.canConfigure)
                              const Text('尚未配置，请由有科目维护权限的财务人员配置')
                            else ...[
                              UtenDropdownField(
                                label:
                                    '${PaymentStyleCategory.labelOf(role.requiredCategory)}科目',
                                value: _choices[role.roleKey],
                                enabled: _saving == null,
                                required: true,
                                items: [
                                  for (final style
                                      in _options[role.requiredCategory] ??
                                          <PaymentStyleNode>[])
                                    UtenDropdownItem(
                                      value: style.id,
                                      label: '${style.code} · ${style.name}',
                                    ),
                                ],
                                onChanged: (value) => setState(() {
                                  if (value == null) {
                                    _choices.remove(role.roleKey);
                                  } else {
                                    _choices[role.roleKey] = value;
                                  }
                                }),
                              ),
                              const SizedBox(height: 8),
                              Align(
                                alignment: AlignmentDirectional.centerEnd,
                                child: FilledButton(
                                  onPressed:
                                      _saving == null &&
                                          _choices.containsKey(role.roleKey)
                                      ? () => _save(role)
                                      : null,
                                  child: Text(
                                    _saving == role.roleKey ? '正在保存' : '保存用途',
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
