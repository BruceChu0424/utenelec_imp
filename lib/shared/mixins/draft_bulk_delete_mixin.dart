import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/buttons/uten_button.dart';
import '../../components/feedback/uten_dialog.dart';
import '../../core/network/api_exception.dart';
import '../../core/ui/app_notification.dart';
import '../badges/badge_registry.dart';
import '../providers/authenticated_scope_provider.dart';

/// 草稿列表批量删除的共用交互。页面只提供可选草稿 ID、复核后删除及列表刷新。
/// 复用 MasterDataTableView 的前置多选和右下角 batchActionsBuilder，不另铺底栏。
/// 删除沿用各单据原接口与权限校验；逐条成功才移除选择，明确失败保留，通信不确定即停。
mixin DraftBulkDeleteMixin<T extends StatefulWidget> on State<T> {
  final Set<String> _draftIds = {};
  bool _draftDeleteBusy = false;
  int _draftSelectionGeneration = 0;
  ProviderSubscription<AuthenticatedScope?>? _draftScopeSubscription;

  void _watchDraftScope() {
    _draftScopeSubscription ??=
        ProviderScope.containerOf(
          context,
          listen: false,
        ).listen<AuthenticatedScope?>(authenticatedScopeProvider, (
          previous,
          next,
        ) {
          if (previous != next) clearDraftSelection();
        });
  }

  @override
  void dispose() {
    _draftScopeSubscription?.close();
    super.dispose();
  }

  Set<String> get selectedDraftIds => Set.unmodifiable(_draftIds);
  bool get draftDeleteBusy => _draftDeleteBusy;

  void selectDraftIds(Set<String> ids) {
    if (!mounted || _draftDeleteBusy) return;
    _watchDraftScope();
    setState(() {
      _draftIds
        ..clear()
        ..addAll(ids);
      _draftSelectionGeneration++;
    });
  }

  void clearDraftSelection() => retainDraftSelection(const []);

  void retainDraftSelection(Iterable<String> availableIds) {
    final kept = _draftIds.intersection(availableIds.toSet());
    if (!mounted || kept.length == _draftIds.length) return;
    setState(() {
      _draftIds
        ..clear()
        ..addAll(kept);
      _draftSelectionGeneration++;
    });
  }

  Widget buildDraftDeleteButton({
    required String documentLabel,
    required Future<void> Function(String) delete,
    required Future<void> Function() reload,
    bool enabled = true,
    Set<String>? selectedIds,
  }) => UtenButton(
    type: UtenButtonType.danger,
    size: UtenButtonSize.large,
    onPressed:
        !enabled || _draftDeleteBusy || (selectedIds ?? _draftIds).isEmpty
        ? null
        : () => _deleteDrafts(documentLabel, delete, reload, selectedIds),
    child: Text(
      _draftDeleteBusy
          ? '正在处理…'
          : '删除所选草稿 (${(selectedIds ?? _draftIds).length})',
    ),
  );

  Future<void> _deleteDrafts(
    String label,
    Future<void> Function(String) delete,
    Future<void> Function() reload,
    Set<String>? selectedIds,
  ) async {
    if (_draftDeleteBusy || _draftIds.isEmpty) return;
    final ids = _draftIds
        .intersection(selectedIds ?? _draftIds)
        .toList(growable: false);
    if (ids.isEmpty) return;
    final generation = _draftSelectionGeneration;
    final container = ProviderScope.containerOf(context, listen: false);
    final scope = container.read(authenticatedScopeProvider);
    if (scope == null || scope.readOnly) {
      clearDraftSelection();
      return;
    }
    bool stillCurrent() =>
        mounted &&
        _draftSelectionGeneration == generation &&
        container.read(authenticatedScopeProvider) == scope;

    setState(() => _draftDeleteBusy = true);
    try {
      final confirmed = await UtenDialog.show(
        context,
        title: '删除所选草稿',
        content: Text('将删除选中的 ${ids.length} 张$label草稿，删除后无法恢复。确认继续？'),
        confirmLabel: '确认删除',
        danger: true,
      );
      if (confirmed != true || !stillCurrent()) return;

      final deleted = <String>{};
      final failures = <String>[];
      var uncertain = false;
      var interrupted = false;
      for (final id in ids) {
        if (!stillCurrent()) {
          interrupted = true;
          break;
        }
        try {
          await delete(id);
          deleted.add(id);
        } on ApiException catch (error) {
          if (error is NetworkException ||
              error is NetworkTimeoutException ||
              (error.httpStatus ?? 0) >= 500) {
            uncertain = true;
            break;
          }
          failures.add(error.message);
        } catch (_) {
          // 未收到可确认的业务拒绝，不能把未知结果宣称为“删除失败且未生效”。
          uncertain = true;
          break;
        }
      }
      if (!mounted || container.read(authenticatedScopeProvider) != scope) {
        return;
      }
      setState(() => _draftIds.removeAll(deleted));
      var refreshed = true;
      try {
        await reload();
      } catch (_) {
        refreshed = false;
      }
      if (!mounted || container.read(authenticatedScopeProvider) != scope) {
        return;
      }
      // 与业务写拦截器共用单飞刷新，草稿分段、任务卡、工作台使用同一份快照。
      await container.read(badgeSummaryProvider.notifier).refresh();
      if (!mounted || container.read(authenticatedScopeProvider) != scope) {
        return;
      }
      final summary = '已删除 ${deleted.length} 张';
      if (uncertain) {
        context.appWarning(
          '$summary；有删除结果尚未确认，已停止后续删除。'
          '${refreshed ? '请核对刷新后的列表再操作。' : '列表刷新未完成，请刷新核对后再操作。'}',
        );
      } else if (failures.isNotEmpty || interrupted || !refreshed) {
        final reasons = failures.toSet().take(2).join('；');
        context.appWarning(
          '$summary${failures.isEmpty ? '' : '，${failures.length} 张未删除：$reasons'}'
          '${interrupted ? '；选择范围已变化，后续删除已停止' : ''}'
          '${refreshed ? '' : '；列表刷新未完成，请手动刷新核对'}',
        );
      } else {
        context.appSuccess('$summary$label草稿');
      }
    } finally {
      if (mounted) setState(() => _draftDeleteBusy = false);
    }
  }
}
