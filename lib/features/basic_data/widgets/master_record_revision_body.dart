import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/native_read_view_scope_mixin.dart';
import '../../../shared/auth/permissions.dart';
import '../repositories/master_record_history_repository.dart';
import 'master_inline_edit.dart';

class MasterRecordRevisionBody extends ConsumerStatefulWidget {
  const MasterRecordRevisionBody({
    super.key,
    required this.entityType,
    required this.id,
    required this.onChanged,
    this.onBusyChanged,
  });
  final String entityType;
  final String id;
  final VoidCallback onChanged;
  final ValueChanged<bool>? onBusyChanged;
  @override
  ConsumerState<MasterRecordRevisionBody> createState() =>
      MasterRecordRevisionBodyState();
}

class MasterRecordRevisionBodyState
    extends ConsumerState<MasterRecordRevisionBody>
    with NativeReadViewScopeMixin<MasterRecordRevisionBody> {
  MasterRecordRevision? _revision;
  String? _error;
  String? _message;
  bool _loading = false;
  bool _mutating = false;
  bool _confirming = false;
  bool _before = true;
  int _epoch = 0;
  bool get isBusy => _loading || _mutating || _confirming;
  String get _scope => '${widget.entityType}:${widget.id}';
  String _text(String zh, String en, String ko) =>
      masterEditText(context, zh, en, ko);
  void _notifyBusy() {
    final busy = _mutating || _confirming;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onBusyChanged?.call(busy);
    });
  }

  @override
  void initState() {
    super.initState();
    initializeNativeReadScope();
    ref.listenManual(currentPermissionsProvider, (previous, next) {
      if (!setEquals(previous, next)) _capabilitiesChanged();
    });
    ref.listenManual(isSuperAdminProvider, (previous, next) {
      if (previous != next) _capabilitiesChanged();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => reload());
  }

  @override
  void didUpdateWidget(MasterRecordRevisionBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id ||
        oldWidget.entityType != widget.entityType) {
      _clear();
      WidgetsBinding.instance.addPostFrameCallback((_) => reload());
    }
  }

  void _capabilitiesChanged() {
    invalidateNativeReadAccess();
    _clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) reload();
    });
  }

  void _clear() {
    _epoch++;
    if (!mounted) return;
    setState(() {
      _revision = null;
      _error = null;
      _message = null;
      _loading = false;
      _mutating = false;
      _confirming = false;
    });
    _notifyBusy();
  }

  @override
  void nativeReadOwnerChanged() => _clear();
  @override
  void nativeReadPermissionChanged() => _clear();
  @override
  Future<void> nativeReadReload() => reload();

  Future<void> reload() async {
    if (!mounted || isBusy) return;
    final accepts = captureNativeRead(_scope, () => _scope);
    if (!accepts()) return;
    final request = ++_epoch;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final revision = await ref
          .read(masterRecordHistoryRepositoryProvider)
          .detail(entityType: widget.entityType, id: widget.id);
      if (!accepts() || request != _epoch) return;
      acceptNativeRead();
      setState(() {
        _revision = revision;
        _loading = false;
      });
    } catch (error) {
      if (!accepts() || request != _epoch) return;
      setState(() {
        _revision = null;
        _loading = false;
        _error = error is ApiException
            ? error.message
            : _text(
                '版本详情加载失败，请刷新重试。',
                'Could not load the revision. Refresh and try again.',
                '버전을 불러오지 못했습니다. 새로고침 후 다시 시도하세요.',
              );
      });
    }
  }

  Future<void> _restore(MasterRecordRevision revision, bool before) async {
    if (isBusy ||
        !nativeReadCanWrite ||
        !(before ? revision.canRestoreBefore : revision.canRestoreAfter)) {
      return;
    }
    final owns = captureNativeOwnership();
    final title = before
        ? _text('恢复到此次修改前', 'Restore before this change', '이 변경 전으로 복원')
        : _text('恢复到此次修改后', 'Restore after this change', '이 변경 후로 복원');
    final removesCreated = before && revision.action == 'CREATE';
    setState(() => _confirming = true);
    _notifyBusy();
    var decided = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => trackNativeReadDialog(
        dialogContext,
        UtenAlertDialog(
          title: Text(title),
          content: Text(
            '${revision.recordCode} ${revision.recordLabel}\n${revision.actorName}\n${ChinaDateTime.formatIsoInstant(revision.recordedAt)}\n\n'
            '${removesCreated ? '${_text('恢复到新增前会撤销本次新增，资料或关联记录将被删除；历史记录仍完整保留。', 'Restoring before creation removes the records or related rows created by this operation. All history is retained.', '생성 전으로 복원하면 이번에 추가된 자료 또는 관련 행이 삭제됩니다. 기록은 모두 보존됩니다.')}\n\n' : ''}'
            '${_text('涉及 ${revision.affectedCount} 条资料与关联记录。恢复会留下新记录；旧版本未记录的新增字段保留现值。编号按当前规则校验，库存与资金通过原业务流程调整。', '${revision.affectedCount} records and related rows are included. Newer fields retain their current values. Restoration creates history and checks current numbering, inventory and financial rules.', '자료와 관련 행 ${revision.affectedCount}개가 포함됩니다. 이후 추가된 필드는 현재 값을 유지하며 현재 번호, 재고 및 자금 업무 규칙을 따릅니다.')}',
          ),
          actions: [
            TextButton(
              onPressed: () {
                if (!decided) {
                  decided = true;
                  Navigator.pop(dialogContext, false);
                }
              },
              child: Text(_text('取消', 'Cancel', '취소')),
            ),
            FilledButton(
              style: removesCreated
                  ? FilledButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.error,
                      foregroundColor: Theme.of(context).colorScheme.onError,
                    )
                  : null,
              onPressed: () {
                if (!decided) {
                  decided = true;
                  Navigator.pop(dialogContext, owns() && nativeReadCanWrite);
                }
              },
              child: Text(title),
            ),
          ],
        ),
      ),
    );
    if (!owns()) return;
    setState(() => _confirming = false);
    _notifyBusy();
    if (confirmed != true || !nativeReadCanWrite) return;
    ++_epoch;
    setState(() {
      _mutating = true;
      _before = before;
      _error = null;
      _message = null;
    });
    _notifyBusy();
    try {
      await ref
          .read(masterRecordHistoryRepositoryProvider)
          .restore(
            entityType: widget.entityType,
            revision: revision,
            before: before,
          );
      if (!owns()) return;
      setState(() {
        _mutating = false;
        _message = _text(
          '已恢复，原历史完整保留。',
          'Restored. The original history is retained.',
          '복원했습니다. 원래 기록은 보존됩니다.',
        );
      });
      _notifyBusy();
      widget.onChanged();
      await reload();
    } catch (error) {
      if (!owns()) return;
      setState(() {
        _mutating = false;
        _revision = null;
        _error = error is ApiException
            ? error.message
            : _text(
                '恢复失败，请刷新历史后重试。',
                'Restoration failed. Refresh and try again.',
                '복원하지 못했습니다. 새로고침 후 다시 시도하세요.',
              );
      });
      _notifyBusy();
    }
  }

  @override
  Widget build(BuildContext context) {
    final revision = _revision;
    return PopScope(
      canPop: !_mutating && !_confirming,
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_loading || _mutating) const LinearProgressIndicator(),
              Expanded(child: _revisionContent(context, revision)),
            ],
          ),
          if (revision != null)
            Align(
              alignment: Alignment.bottomRight,
              child: UtenFloatingActionGroup(
                children: [
                  UtenButton(
                    type: UtenButtonType.secondary,
                    size: UtenButtonSize.large,
                    isLoading: _mutating && !_before,
                    onPressed:
                        !isBusy &&
                            nativeReadCanWrite &&
                            revision.canRestoreAfter
                        ? () => _restore(revision, false)
                        : null,
                    child: Text(
                      _text(
                        '恢复到此次修改后',
                        'Restore after this change',
                        '이 변경 후로 복원',
                      ),
                    ),
                  ),
                  UtenButton(
                    size: UtenButtonSize.large,
                    isLoading: _mutating && _before,
                    onPressed:
                        !isBusy &&
                            nativeReadCanWrite &&
                            revision.canRestoreBefore
                        ? () => _restore(revision, true)
                        : null,
                    child: Text(
                      _text(
                        '恢复到此次修改前',
                        'Restore before this change',
                        '이 변경 전으로 복원',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (_mutating)
            UtenBusyOverlay(
              title: _text(
                '正在恢复资料版本',
                'Restoring this revision',
                '자료 버전을 복원하는 중',
              ),
            ),
        ],
      ),
    );
  }

  Widget _revisionContent(
    BuildContext context,
    MasterRecordRevision? revision,
  ) => CustomScrollView(
    slivers: [
      SliverPadding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        sliver: SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null) ...[
                UtenInlineNotice(
                  level: UtenInlineNoticeLevel.error,
                  message: _error,
                ),
                const SizedBox(height: UtenSpacing.s12),
              ],
              if (_message != null) ...[
                UtenInlineNotice(message: _message),
                const SizedBox(height: UtenSpacing.s12),
              ],
              if (revision != null) ...[
                Text(
                  revision.recordLabel,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: UtenSpacing.s16),
                UtenFormGrid(
                  columns: 4,
                  maxColumns: 4,
                  minFieldWidth: 260,
                  children: [
                    _metadata(_text('编号', 'Code', '번호'), revision.recordCode),
                    _metadata(
                      _text('操作人', 'Operator', '작업자'),
                      revision.actorName,
                    ),
                    _metadata(
                      _text('操作时间', 'Time', '시간'),
                      ChinaDateTime.formatIsoInstant(revision.recordedAt),
                    ),
                    _metadata(_text('操作摘要', 'Summary', '요약'), revision.summary),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s24),
                if (revision.blockedReason != null) ...[
                  UtenInlineNotice(
                    key: const Key('master-revision-blocked-reason'),
                    message: revision.blockedReason,
                  ),
                  const SizedBox(height: UtenSpacing.s16),
                ],
                Text(
                  _text('变更对照', 'Changes', '변경 비교'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: UtenSpacing.s8),
                Text(
                  _text(
                    '涉及 ${revision.affectedCount} 条资料与关联记录',
                    '${revision.affectedCount} records and related rows',
                    '자료 및 관련 행 ${revision.affectedCount}개',
                  ),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: UtenSpacing.s12),
                if (revision.changes.isEmpty)
                  UtenInlineNotice(
                    message: _text(
                      '此版本没有当前可见的字段差异。',
                      'There are no visible field differences in this revision.',
                      '이 버전에서 볼 수 있는 필드 차이가 없습니다.',
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      if (revision != null)
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s16),
          sliver: SliverList.builder(
            itemCount: revision.changes.length,
            itemBuilder: (_, index) => _change(revision.changes[index]),
          ),
        ),
      const SliverToBoxAdapter(
        child: SizedBox(height: UtenFloatingActionGroup.scrollClearance),
      ),
    ],
  );

  Widget _metadata(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.labelMedium),
      const SizedBox(height: UtenSpacing.s4),
      SelectableText(value.isEmpty ? '—' : value),
    ],
  );
  Widget _change(MasterRecordChange change) {
    final theme = Theme.of(context), empty = _text('未设置', 'Not set', '미설정');
    return Container(
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final label = Text(change.label, style: theme.textTheme.labelLarge);
          final before = SelectableText(
            '${_text('修改前', 'Before', '변경 전')}\n${change.before.isEmpty ? empty : change.before}',
          );
          final after = SelectableText(
            '${_text('修改后', 'After', '변경 후')}\n${change.after.isEmpty ? empty : change.after}',
            style: TextStyle(color: theme.colorScheme.primary),
          );
          if (constraints.maxWidth < 560) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                label,
                const SizedBox(height: UtenSpacing.s8),
                before,
                const SizedBox(height: UtenSpacing.s8),
                after,
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 160, child: label),
              Expanded(child: before),
              const SizedBox(width: UtenSpacing.s16),
              Expanded(child: after),
            ],
          );
        },
      ),
    );
  }
}
