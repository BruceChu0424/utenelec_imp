import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/data_display/uten_status_badge.dart';
import '../../components/layout/uten_app_bar.dart';
import '../../components/layout/uten_content_container.dart';
import '../../core/network/server_config.dart';
import '../../core/theme/uten_tokens.dart';
import '../../core/utils/china_datetime.dart';
import '../auth/permissions.dart';
import '../providers/authenticated_scope_provider.dart';
import 'form_draft_category.dart';
import 'form_draft_history.dart';
import 'form_draft_history_projection.dart';
import 'form_draft_store.dart';

final _historyPageProvider = FutureProvider.autoDispose
    .family<FormDraftHistoryPage, String?>((ref, cursor) {
      ref.watch(authenticatedScopeProvider);
      ref.watch(apiBaseUrlProvider);
      ref.watch(currentPermissionsProvider);
      ref.watch(formDraftsProvider);
      return ref.read(formDraftsProvider.notifier).historyPage(before: cursor);
    });

final _historyRecordProvider = FutureProvider.autoDispose
    .family<FormDraftHistoryRecord?, String>((ref, id) {
      ref.watch(authenticatedScopeProvider);
      ref.watch(apiBaseUrlProvider);
      ref.watch(currentPermissionsProvider);
      ref.watch(formDraftsProvider);
      return ref.read(formDraftsProvider.notifier).readHistory(id);
    });

FormDraft _metadata(FormDraftHistoryEntry entry) => FormDraft(
  id: entry.draftId,
  title: '',
  module: entry.module,
  route: entry.route,
  permission: entry.permission,
  draftKind: entry.draftKind,
  revision: entry.revision,
  updatedAt: entry.recordedAt,
  data: const {},
);

String _actionLabel(FormDraftHistoryAction action) => switch (action) {
  FormDraftHistoryAction.saved => '已保存',
  FormDraftHistoryAction.deleted => '已删除',
  FormDraftHistoryAction.completed => '已完成',
  FormDraftHistoryAction.imported => '原草稿',
};

/// Every host uses the same scope as its draft table. History is read-only and
/// never navigates to a create route or restores a completed/deleted snapshot.
class FormDraftHistoryButton extends StatelessWidget {
  const FormDraftHistoryButton({super.key, required this.scope});
  final FormDraftCategoryScope scope;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    icon: const Icon(Icons.history),
    label: const Text('本机草稿历史'),
    onPressed: () => Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => _FormDraftHistoryPage(scope: scope)),
    ),
  );
}

class _FormDraftHistoryPage extends ConsumerStatefulWidget {
  const _FormDraftHistoryPage({required this.scope});
  final FormDraftCategoryScope scope;

  @override
  ConsumerState<_FormDraftHistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends ConsumerState<_FormDraftHistoryPage> {
  final _cursors = <String?>[null];
  Object? _identity;

  @override
  Widget build(BuildContext context) {
    final identity = (
      ref.watch(authenticatedScopeProvider),
      ref.watch(apiBaseUrlProvider),
    );
    if (_identity != identity) {
      _identity = identity;
      _cursors
        ..clear()
        ..add(null);
    }
    final permissions = ref.watch(currentPermissionsProvider);
    final page = ref.watch(_historyPageProvider(_cursors.last));
    return Scaffold(
      appBar: UtenAppBar(
        title: '本机草稿历史',
        leading: BackButton(onPressed: () => Navigator.of(context).pop()),
        actions: [
          IconButton(
            tooltip: '刷新历史',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              setState(
                () => _cursors
                  ..clear()
                  ..add(null),
              );
              ref.invalidate(_historyPageProvider);
            },
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: page.when(
            skipLoadingOnRefresh: false,
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => Center(
              child: TextButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('历史读取失败，重试'),
                onPressed: () =>
                    ref.invalidate(_historyPageProvider(_cursors.last)),
              ),
            ),
            data: (value) {
              final entries = value.entries.where((entry) {
                final draft = _metadata(entry);
                return widget.scope.matches(draft) &&
                    canReadFormDraftHistory(draft, permissions);
              }).toList();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Padding(
                    padding: EdgeInsets.all(UtenSpacing.s12),
                    child: Text('保存、完成和删除的内容保留在当前设备。历史仅供查看。'),
                  ),
                  Expanded(
                    child: entries.isEmpty
                        ? const Center(child: Text('此页没有当前类别可查看的历史'))
                        : ListView.builder(
                            itemCount: entries.length,
                            itemBuilder: (context, index) {
                              final entry = entries[index];
                              return ListTile(
                                title: Text(
                                  formDraftHistoryTitle(
                                    _metadata(entry),
                                    permissions,
                                  )!,
                                ),
                                subtitle: Text(
                                  ChinaDateTime.formatInstant(entry.recordedAt),
                                ),
                                leading: UtenStatusBadge(
                                  label: _actionLabel(entry.action),
                                  type:
                                      entry.action ==
                                          FormDraftHistoryAction.completed
                                      ? UtenStatusBadgeType.success
                                      : UtenStatusBadgeType.neutral,
                                ),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () => Navigator.of(context).push<void>(
                                  MaterialPageRoute(
                                    builder: (_) => _HistoryDetail(
                                      id: entry.id,
                                      owner: identity,
                                      scope: widget.scope,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(UtenSpacing.s12),
                    child: Wrap(
                      spacing: UtenSpacing.s12,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        TextButton(
                          onPressed: _cursors.length == 1
                              ? null
                              : () => setState(() => _cursors.removeLast()),
                          child: const Text('上一页'),
                        ),
                        Text('第 ${_cursors.length} 页'),
                        TextButton(
                          onPressed: value.nextCursor == null
                              ? null
                              : () => setState(
                                  () => _cursors.add(value.nextCursor),
                                ),
                          child: const Text('下一页'),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _HistoryDetail extends ConsumerWidget {
  const _HistoryDetail({
    required this.id,
    required this.owner,
    required this.scope,
  });
  final String id;
  final Object owner;
  final FormDraftCategoryScope scope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final identity = (
      ref.watch(authenticatedScopeProvider),
      ref.watch(apiBaseUrlProvider),
    );
    final permissions = ref.watch(currentPermissionsProvider);
    final history = ref.watch(_historyRecordProvider(id));
    return Scaffold(
      appBar: UtenAppBar(
        title: '草稿历史内容',
        leading: BackButton(onPressed: () => Navigator.of(context).pop()),
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: identity != owner
              ? const Center(child: Text('登录身份已变化，请返回重新查看'))
              : history.when(
                  skipLoadingOnRefresh: false,
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (_, _) =>
                      const Center(child: Text('历史内容暂时无法读取，原件仍保留')),
                  data: (record) {
                    final projection =
                        record == null || !scope.matches(record.draft)
                        ? null
                        : projectFormDraftHistory(record.draft, permissions);
                    if (projection == null) {
                      return const Center(child: Text('当前权限不可查看，或历史内容不可用'));
                    }
                    return ListView.builder(
                      itemCount: projection.sections.length + 1,
                      itemBuilder: (context, index) {
                        if (index == 0) {
                          return Padding(
                            padding: const EdgeInsets.all(UtenSpacing.s12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  projection.title,
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                                const SizedBox(height: UtenSpacing.s12),
                                const Text(
                                  '按当前权限展示已接通的字段。未展示字段与附件原件仍保留；未填写的值不补零。',
                                ),
                                if (projection.sections.isEmpty)
                                  const Text('此表单的内容投影尚未接通。'),
                              ],
                            ),
                          );
                        }
                        final section = projection.sections[index - 1];
                        return Padding(
                          padding: const EdgeInsets.all(UtenSpacing.s12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                section.label,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              for (final field in section.fields)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 6,
                                  ),
                                  child: SelectableText(
                                    '${field.label}：${field.value}',
                                  ),
                                ),
                              if (section.fields.isEmpty) const Text('无可展示字段'),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
        ),
      ),
    );
  }
}
