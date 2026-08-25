import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/uten_tokens.dart';
import 'document_scope_capability.dart';

/// Explains why ordinary document mutations are temporarily or permanently
/// unavailable. This is presentation only; server authorization remains final.
class DocumentScopeWriteNotice extends StatelessWidget {
  const DocumentScopeWriteNotice({
    super.key,
    required this.capability,
    required this.ownerEmployeeId,
    required this.onRetry,
  });

  final AsyncValue<DocumentScopeCapability> capability;
  final String? ownerEmployeeId;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final state = _state();
    if (state == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final background = switch (state.kind) {
      _NoticeKind.loading => colors.surfaceContainerHighest,
      _NoticeKind.error => colors.errorContainer,
      _NoticeKind.readOnly => colors.secondaryContainer,
    };
    final foreground = switch (state.kind) {
      _NoticeKind.loading => colors.onSurfaceVariant,
      _NoticeKind.error => colors.onErrorContainer,
      _NoticeKind.readOnly => colors.onSecondaryContainer,
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
      child: Semantics(
        container: true,
        liveRegion: state.kind != _NoticeKind.readOnly,
        label: '${state.title}。${state.description}',
        child: Material(
          key: ValueKey('document-scope-write-notice-${state.keyName}'),
          color: background,
          shape: RoundedRectangleBorder(
            borderRadius: UtenRadius.mdAll,
            side: BorderSide(color: foreground.withValues(alpha: 0.28)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            child: Row(
              children: [
                if (state.kind == _NoticeKind.loading)
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: foreground,
                      semanticsLabel: '正在确认操作范围',
                    ),
                  )
                else
                  Icon(state.icon, color: foreground, size: 22),
                const SizedBox(width: UtenSpacing.s12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        state.title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: foreground,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s4),
                      Text(
                        state.description,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: foreground,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                ),
                if (state.kind == _NoticeKind.error) ...[
                  const SizedBox(width: UtenSpacing.s8),
                  TextButton.icon(
                    key: const ValueKey('document-scope-write-notice-retry'),
                    onPressed: onRetry,
                    style: TextButton.styleFrom(
                      foregroundColor: foreground,
                      minimumSize: const Size(48, 48),
                    ),
                    icon: const Icon(Icons.refresh_rounded, size: 20),
                    label: const Text('重试'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  _NoticeState? _state() => capability.when(
    loading: () => const _NoticeState(
      kind: _NoticeKind.loading,
      keyName: 'loading',
      icon: Icons.hourglass_top_rounded,
      title: '正在确认操作范围',
      description: '确认完成前，本页保持只读。',
    ),
    error: (_, _) => const _NoticeState(
      kind: _NoticeKind.error,
      keyName: 'error',
      icon: Icons.cloud_off_outlined,
      title: '无法确认操作范围，当前仅查看',
      description: '请检查网络后重试；服务端仍会阻止越权操作。',
    ),
    data: (value) {
      final owner = ownerEmployeeId?.trim();
      if (owner == null || owner.isEmpty) {
        return const _NoticeState(
          kind: _NoticeKind.readOnly,
          keyName: 'legacy',
          icon: Icons.history_toggle_off_rounded,
          title: '历史单据未维护负责人，当前只读',
          description: '请联系管理员先补充负责人，再进行修改。',
        );
      }
      if (value.canWrite(owner)) return null;
      return const _NoticeState(
        kind: _NoticeKind.readOnly,
        keyName: 'readonly',
        icon: Icons.visibility_outlined,
        title: '此单据通过额外查看范围显示，仅可查看',
        description: '如需修改，请先完成正式数据交接或联系管理员。单独获授的审核或执行动作仍按页面按钮处理。',
      );
    },
  );
}

enum _NoticeKind { loading, error, readOnly }

class _NoticeState {
  const _NoticeState({
    required this.kind,
    required this.keyName,
    required this.icon,
    required this.title,
    required this.description,
  });

  final _NoticeKind kind;
  final String keyName;
  final IconData icon;
  final String title;
  final String description;
}
