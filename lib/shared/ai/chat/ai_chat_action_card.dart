// AiChatActionCard - AI 助手的通用确认卡(ADR-150)。
// 文档：docs/02-组件库/AiPageContext.md「确认卡」一节。
//
// 卡片正文是服务端渲染的摘要行(模型文字不会出现在卡上)。卡片只负责展示与按钮:
// 确认 / 取消 / 到期倒计时 / 执行中 / 成功或失败回执 / 结果不明时「查看结果」。
// 真正的执行(先一次性核销, 再调用页面登记的 handler, 最后回执)由对话框会话完成。
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../components/buttons/click_guard.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../page_context/ai_page_context.dart';
import 'ai_chat_models.dart';

/// Local UI state of one card; [card] is always the latest server view.
class AiChatCardUi {
  AiChatCardUi(this.card);
  AiChatAction card;

  /// Confirm/execute/receipt in flight (the confirm button is disabled).
  bool running = false;

  /// The last request's result is unknown (network); offer "check result".
  bool unknown = false;

  /// The page handler ran but its receipt did not reach the server.
  bool? localSucceeded;

  /// Short local explanation (wrong page, missing action, failure reason).
  String? note;
  bool noteIsError = false;

  /// Restored after a page refresh: the page instance and rows the card was
  /// proposed for are gone, so it can only be cancelled, never confirmed.
  bool detached = false;
}

class AiChatActionCard extends StatefulWidget {
  const AiChatActionCard({
    super.key,
    required this.ui,
    required this.onConfirm,
    required this.onCancel,
    required this.onCheck,
    this.enabled = true,
    this.clock = DateTime.now,
  });

  final AiChatCardUi ui;
  final Future<void> Function() onConfirm;
  final Future<void> Function() onCancel;
  final Future<void> Function() onCheck;

  /// False while another card is executing.
  final bool enabled;
  final DateTime Function() clock;

  @override
  State<AiChatActionCard> createState() => _AiChatActionCardState();
}

class _AiChatActionCardState extends State<AiChatActionCard> {
  Timer? _ticker;

  bool get _open => widget.ui.card.openAt(widget.clock());

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant AiChatActionCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  /// The countdown ticks only while the card can still be confirmed.
  void _syncTicker() {
    if (_open && !widget.ui.running) {
      _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {});
        if (!_open) _stopTicker();
      });
    } else {
      _stopTicker();
    }
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  @override
  void dispose() {
    _stopTicker();
    super.dispose();
  }

  String _remaining() {
    final left = widget.ui.card.expiresAt.difference(widget.clock());
    final seconds = left.inSeconds.clamp(0, 3600);
    final mm = (seconds ~/ 60).toString().padLeft(2, '0');
    final ss = (seconds % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = aiPageL10n(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final ui = widget.ui;
    final card = ui.card;
    final id = card.proposalId;
    final risky = card.risk == 'MEDIUM' || card.risk == 'HIGH';
    final icon = switch (card.actionType) {
      AiChatAction.permissionGrant => Icons.admin_panel_settings_outlined,
      AiChatAction.openGuidedForm => Icons.description_outlined,
      _ => Icons.touch_app_outlined,
    };
    return Container(
      key: ValueKey('ai-action-card-$id'),
      margin: const EdgeInsets.only(top: UtenSpacing.s8),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        border: Border.all(
          color: risky && _open ? UtenColors.warning : colors.outlineVariant,
        ),
        borderRadius: UtenRadius.lgAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: colors.primary),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(card.title, style: theme.textTheme.titleSmall),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          for (final line in card.summaryLines)
            Padding(
              padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
              child: Text(line, style: theme.textTheme.bodyMedium),
            ),
          if (risky && _open) ...[
            const SizedBox(height: UtenSpacing.s4),
            Container(
              key: ValueKey('ai-action-risk-$id'),
              width: double.infinity,
              padding: const EdgeInsets.all(UtenSpacing.s8),
              decoration: BoxDecoration(
                color: UtenColors.warning.withValues(alpha: 0.12),
                borderRadius: UtenRadius.controlAll,
              ),
              child: Text(
                '${l10n.aiChatCardRisk}: ${card.riskNote ?? ''}'.trim(),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.brightness == Brightness.dark
                      ? UtenColors.warningOnDark
                      : UtenColors.warningText,
                ),
              ),
            ),
          ],
          if (card.requiresStepUp && _open) ...[
            const SizedBox(height: UtenSpacing.s4),
            Text(l10n.aiChatCardStepUp, style: theme.textTheme.bodySmall),
          ],
          const SizedBox(height: UtenSpacing.s8),
          _status(context, l10n),
        ],
      ),
    );
  }

  Widget _status(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final ui = widget.ui;
    final card = ui.card;
    final id = card.proposalId;
    Widget line(IconData icon, Color color, String text, {String? detail}) =>
        Semantics(
          liveRegion: true,
          child: Column(
            key: ValueKey('ai-action-status-$id'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 16, color: color),
                  const SizedBox(width: UtenSpacing.s6),
                  Flexible(
                    child: Text(
                      text,
                      style: theme.textTheme.bodySmall?.copyWith(color: color),
                    ),
                  ),
                ],
              ),
              if (detail != null && detail.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: UtenSpacing.s4),
                  child: Text(detail, style: theme.textTheme.bodySmall),
                ),
            ],
          ),
        );
    Widget withNote(Widget child) {
      final note = ui.note;
      if (note == null || note.isEmpty) return child;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          child,
          const SizedBox(height: UtenSpacing.s6),
          Text(
            note,
            key: ValueKey('ai-action-note-$id'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: ui.noteIsError ? colors.error : colors.onSurfaceVariant,
            ),
          ),
        ],
      );
    }

    if (ui.running) {
      return Row(
        key: ValueKey('ai-action-running-$id'),
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: UtenSpacing.s8),
          Text(l10n.aiChatCardRunning, style: theme.textTheme.bodySmall),
        ],
      );
    }
    final check = TextButton(
      key: ValueKey('ai-action-check-$id'),
      onPressed: widget.onCheck,
      child: Text(l10n.aiChatCardCheck),
    );
    final success = theme.brightness == Brightness.dark
        ? UtenColors.successOnDark
        : UtenColors.successText;
    if (card.outcome == 'SUCCEEDED' ||
        (card.outcome == null && ui.localSucceeded == true)) {
      return withNote(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            line(
              Icons.check_circle_outline,
              success,
              l10n.aiChatCardSucceeded,
              detail: card.outcomeMessage,
            ),
            if (card.outcome == null) check,
          ],
        ),
      );
    }
    if (card.outcome == 'AUTH_CHANGED') {
      return line(Icons.block, colors.error, l10n.aiChatCardAuthChanged);
    }
    if (card.status == AiChatActionStatus.failed ||
        card.outcome == 'FAILED' ||
        ui.localSucceeded == false) {
      final detail = card.outcomeMessage ?? ui.note;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          line(
            Icons.error_outline,
            colors.error,
            l10n.aiChatCardFailed,
            detail: detail,
          ),
          if (card.outcome == null && card.status != AiChatActionStatus.failed)
            check,
        ],
      );
    }
    if (card.status == AiChatActionStatus.cancelled) {
      return withNote(
        line(
          Icons.cancel_outlined,
          colors.onSurfaceVariant,
          l10n.aiChatCardCancelled,
        ),
      );
    }
    if (card.status == AiChatActionStatus.expired ||
        (!_open && card.status == AiChatActionStatus.proposed)) {
      return withNote(
        line(
          Icons.timer_off_outlined,
          colors.onSurfaceVariant,
          l10n.aiChatCardExpired,
        ),
      );
    }
    if (card.status == AiChatActionStatus.confirmed) {
      return withNote(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            line(
              Icons.hourglass_bottom,
              colors.onSurfaceVariant,
              l10n.aiChatCardConfirmed,
            ),
            check,
          ],
        ),
      );
    }
    // Restored page card: the page it was bound to was reloaded. Confirming
    // would only use up the one-time proposal, so only cancel is offered.
    if (ui.detached) {
      return withNote(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.aiChatCardDetached,
              key: ValueKey('ai-action-detached-$id'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            if (widget.enabled) ...[
              const SizedBox(height: UtenSpacing.s8),
              Align(
                alignment: Alignment.centerRight,
                child: UtenActionButton(
                  key: ValueKey('ai-action-cancel-$id'),
                  type: UtenActionButtonType.ghost,
                  size: UtenActionButtonSize.small,
                  label: Text(l10n.aiChatCancel),
                  onAction: widget.onCancel,
                ),
              ),
            ],
          ],
        ),
      );
    }
    // Open card: countdown + cancel/confirm (guarded against double clicks).
    return withNote(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.aiChatCardExpiresIn(_remaining()),
            key: ValueKey('ai-action-countdown-$id'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          if (ui.unknown) check,
          if (widget.enabled && !ui.unknown) ...[
            const SizedBox(height: UtenSpacing.s8),
            Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              alignment: WrapAlignment.end,
              children: [
                UtenActionButton(
                  key: ValueKey('ai-action-cancel-$id'),
                  type: UtenActionButtonType.ghost,
                  size: UtenActionButtonSize.small,
                  label: Text(l10n.aiChatCancel),
                  onAction: widget.onCancel,
                ),
                UtenActionButton(
                  key: ValueKey('ai-action-confirm-$id'),
                  size: UtenActionButtonSize.small,
                  label: Text(l10n.aiChatCardConfirm),
                  onAction: widget.onConfirm,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
