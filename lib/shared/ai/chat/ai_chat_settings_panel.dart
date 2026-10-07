import 'package:flutter/material.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_segmented_filter.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_tokens.dart';
import '../page_context/ai_page_context.dart';
import 'ai_chat_models.dart';

/// ADR-152 chat settings, shown inside the chat panel in place of the
/// messages. Every change is saved at once ([onChange] gets the wire field
/// and value); the row being saved shows a spinner and a failed save is
/// reported in [error] after the caller rolled the choice back.
///
/// "Confirm before actions" is shown as always on: every AI action is a
/// confirmation card first, and that is not a setting. The two destructive
/// buttons ([onClearHistory], [onClearMemory]) ask the caller for
/// confirmation before anything is deleted.
class AiChatSettingsPanel extends StatelessWidget {
  const AiChatSettingsPanel({
    super.key,
    required this.settings,
    required this.reasoningSupported,
    required this.onChange,
    required this.onClearHistory,
    required this.onClearMemory,
    this.savingField,
    this.error,
    this.clearing = false,
    this.canClear = true,
    this.clearingMemory = false,
    this.canClearMemory = true,
  });

  final AiChatSettings settings;
  final bool reasoningSupported;
  final void Function(String field, Object value) onChange;
  final VoidCallback onClearHistory;

  /// ADR-163: clears the caller's own operation memory.
  final VoidCallback onClearMemory;

  /// Wire name of the field being saved, if any.
  final String? savingField;
  final String? error;
  final bool clearing;
  final bool canClear;

  /// Whether the operation memory is being cleared right now.
  final bool clearingMemory;
  final bool canClearMemory;

  @override
  Widget build(BuildContext context) {
    final l10n = aiPageL10n(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      height: 1.4,
    );
    final busy = savingField != null;
    // A short, fixed list: built at once (not lazily) so every row is
    // reachable by keyboard, screen reader and scrolling alike.
    return SingleChildScrollView(
      key: const ValueKey('ai-chat-settings-panel'),
      // Never the page's primary scroll view; at large text sizes the chat
      // panel scrolls everything in its own outer view.
      primary: false,
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s16,
        UtenSpacing.s12,
        UtenSpacing.s16,
        UtenSpacing.s24,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.aiChatSettingsSynced, style: muted),
          if (error != null) ...[
            const SizedBox(height: UtenSpacing.s8),
            Semantics(
              liveRegion: true,
              child: Container(
                key: const ValueKey('ai-settings-error'),
                padding: const EdgeInsets.all(UtenSpacing.s8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: UtenRadius.controlAll,
                ),
                child: Text(
                  error!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ),
          ],
          _Choice<AiChatDetail>(
            field: 'detail',
            title: l10n.aiChatSettingsDetail,
            hint: l10n.aiChatSettingsDetailHint,
            saving: savingField == 'detail',
            enabled: !busy,
            selected: settings.detail,
            segments: [
              UtenSegment(
                value: AiChatDetail.comprehensive,
                label: l10n.aiChatSettingsDetailComprehensive,
              ),
              UtenSegment(
                value: AiChatDetail.standard,
                label: l10n.aiChatSettingsDetailStandard,
              ),
              UtenSegment(
                value: AiChatDetail.concise,
                label: l10n.aiChatSettingsDetailConcise,
              ),
            ],
            onChanged: (value) => onChange('detail', value.wire),
          ),
          _Choice<AiChatReasoning>(
            field: 'reasoning',
            title: l10n.aiChatSettingsReasoning,
            hint: reasoningSupported
                ? l10n.aiChatSettingsReasoningHint
                : l10n.aiChatSettingsReasoningUnsupported,
            hintKey: reasoningSupported
                ? null
                : const ValueKey('ai-settings-reasoning-unsupported'),
            saving: savingField == 'reasoning',
            enabled: !busy && reasoningSupported,
            selected: settings.reasoning,
            segments: [
              UtenSegment(
                value: AiChatReasoning.fast,
                label: l10n.aiChatSettingsReasoningFast,
              ),
              UtenSegment(
                value: AiChatReasoning.standard,
                label: l10n.aiChatSettingsReasoningStandard,
              ),
              UtenSegment(
                value: AiChatReasoning.deep,
                label: l10n.aiChatSettingsReasoningDeep,
              ),
            ],
            onChanged: (value) => onChange('reasoning', value.wire),
          ),
          _Choice<int>(
            field: 'memoryTurns',
            title: l10n.aiChatSettingsMemory,
            hint: l10n.aiChatSettingsMemoryHint,
            saving: savingField == 'memoryTurns',
            enabled: !busy,
            selected: settings.memoryTurns,
            segments: [
              for (final turns in AiChatSettings.memoryChoices)
                UtenSegment(
                  value: turns,
                  label: turns == 0
                      ? l10n.aiChatSettingsMemoryOff
                      : l10n.aiChatSettingsMemoryTurns(turns),
                ),
            ],
            onChanged: (value) => onChange('memoryTurns', value),
          ),
          _Choice<AiChatReplyLanguage>(
            field: 'replyLanguage',
            title: l10n.aiChatSettingsLanguage,
            saving: savingField == 'replyLanguage',
            enabled: !busy,
            selected: settings.replyLanguage,
            segments: [
              UtenSegment(
                value: AiChatReplyLanguage.auto,
                label: l10n.aiChatSettingsLanguageAuto,
              ),
              UtenSegment(
                value: AiChatReplyLanguage.zh,
                label: l10n.aiChatSettingsLanguageZh,
              ),
              UtenSegment(
                value: AiChatReplyLanguage.en,
                label: l10n.aiChatSettingsLanguageEn,
              ),
              UtenSegment(
                value: AiChatReplyLanguage.ko,
                label: l10n.aiChatSettingsLanguageKo,
              ),
            ],
            onChanged: (value) => onChange('replyLanguage', value.wire),
          ),
          _Choice<AiChatExplanationStyle>(
            field: 'explanationStyle',
            title: l10n.aiChatSettingsStyle,
            hint: l10n.aiChatSettingsStyleHint,
            saving: savingField == 'explanationStyle',
            enabled: !busy,
            selected: settings.explanationStyle,
            segments: [
              UtenSegment(
                value: AiChatExplanationStyle.plain,
                label: l10n.aiChatSettingsStylePlain,
              ),
              UtenSegment(
                value: AiChatExplanationStyle.professional,
                label: l10n.aiChatSettingsStyleProfessional,
              ),
            ],
            onChanged: (value) => onChange('explanationStyle', value.wire),
          ),
          _Choice<AiChatSendKey>(
            field: 'sendKey',
            title: l10n.aiChatSettingsSendKey,
            hint: settings.sendKey == AiChatSendKey.enter
                ? l10n.aiChatSettingsSendEnterHint
                : l10n.aiChatSettingsSendCtrlEnterHint,
            saving: savingField == 'sendKey',
            enabled: !busy,
            selected: settings.sendKey,
            segments: [
              UtenSegment(
                value: AiChatSendKey.enter,
                label: l10n.aiChatSettingsSendEnter,
              ),
              UtenSegment(
                value: AiChatSendKey.ctrlEnter,
                label: l10n.aiChatSettingsSendCtrlEnter,
              ),
            ],
            onChanged: (value) => onChange('sendKey', value.wire),
          ),
          const SizedBox(height: UtenSpacing.s8),
          _Toggle(
            field: 'pageAware',
            title: l10n.aiChatSettingsPageAware,
            hint: l10n.aiChatPageHint,
            value: settings.pageAware,
            saving: savingField == 'pageAware',
            enabled: !busy,
            onChanged: (value) => onChange('pageAware', value),
          ),
          _Toggle(
            field: 'showSources',
            title: l10n.aiChatSettingsShowSources,
            hint: l10n.aiChatSettingsShowSourcesHint,
            value: settings.showSources,
            saving: savingField == 'showSources',
            enabled: !busy,
            onChanged: (value) => onChange('showSources', value),
          ),
          _Toggle(
            field: 'showSuggestions',
            title: l10n.aiChatSettingsSuggestions,
            hint: l10n.aiChatSettingsSuggestionsHint,
            value: settings.showSuggestions,
            saving: savingField == 'showSuggestions',
            enabled: !busy,
            onChanged: (value) => onChange('showSuggestions', value),
          ),
          _Toggle(
            field: 'operationMemory',
            title: l10n.aiChatMemorySettingLabel,
            hint: l10n.aiChatMemorySettingHint,
            value: settings.operationMemory,
            saving: savingField == 'operationMemory',
            enabled: !busy,
            onChanged: (value) => onChange('operationMemory', value),
          ),
          ListTile(
            key: const ValueKey('ai-settings-confirm-always'),
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.verified_user_outlined,
              color: theme.colorScheme.primary,
            ),
            title: Text(l10n.aiChatSettingsConfirm),
            subtitle: Text(l10n.aiChatSettingsConfirmHint, style: muted),
            trailing: Text(
              l10n.aiChatSettingsConfirmAlways,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          const Divider(height: UtenSpacing.s24),
          Text(l10n.aiChatSettingsClearHint, style: muted),
          const SizedBox(height: UtenSpacing.s8),
          Align(
            alignment: Alignment.centerLeft,
            child: UtenButton(
              key: const ValueKey('ai-settings-clear'),
              type: UtenButtonType.danger,
              isLoading: clearing,
              onPressed: clearing || busy || !canClear ? null : onClearHistory,
              // Wraps at large text sizes instead of overflowing the panel.
              child: Flexible(child: Text(l10n.aiChatSettingsClear)),
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
          Align(
            alignment: Alignment.centerLeft,
            child: UtenButton(
              key: const ValueKey('ai-settings-clear-memory'),
              type: UtenButtonType.danger,
              isLoading: clearingMemory,
              onPressed: clearingMemory || busy || !canClearMemory
                  ? null
                  : onClearMemory,
              // Wraps at large text sizes instead of overflowing the panel.
              child: Flexible(child: Text(l10n.aiChatMemoryClear)),
            ),
          ),
        ],
      ),
    );
  }
}

class _Choice<T> extends StatelessWidget {
  const _Choice({
    required this.field,
    required this.title,
    required this.selected,
    required this.segments,
    required this.onChanged,
    required this.saving,
    required this.enabled,
    this.hint,
    this.hintKey,
  });

  final String field;
  final String title;
  final String? hint;
  final Key? hintKey;
  final T selected;
  final List<UtenSegment<T>> segments;
  final ValueChanged<T> onChanged;
  final bool saving;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      key: ValueKey('ai-settings-$field'),
      padding: const EdgeInsets.only(top: UtenSpacing.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Title(text: title, saving: saving),
          const SizedBox(height: UtenSpacing.s6),
          Opacity(
            opacity: enabled || saving ? 1 : 0.5,
            child: IgnorePointer(
              ignoring: !enabled,
              child: UtenSegmentedFilter<T>(
                segments: segments,
                selected: selected,
                onChanged: (value) {
                  if (value != selected) onChanged(value);
                },
              ),
            ),
          ),
          if (hint != null) ...[
            const SizedBox(height: UtenSpacing.s4),
            Text(
              hint!,
              key: hintKey,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.field,
    required this.title,
    required this.hint,
    required this.value,
    required this.onChanged,
    required this.saving,
    required this.enabled,
  });

  final String field;
  final String title;
  final String hint;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool saving;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SwitchListTile(
      key: ValueKey('ai-settings-$field'),
      value: value,
      onChanged: enabled ? onChanged : null,
      contentPadding: EdgeInsets.zero,
      title: _Title(text: title, saving: saving),
      subtitle: Text(
        hint,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          height: 1.4,
        ),
      ),
    );
  }
}

class _Title extends StatelessWidget {
  const _Title({required this.text, required this.saving});
  final String text;
  final bool saving;

  @override
  Widget build(BuildContext context) {
    final l10n = Localizations.of<AppLocalizations>(context, AppLocalizations);
    return Row(
      children: [
        Flexible(
          child: Text(text, style: Theme.of(context).textTheme.titleSmall),
        ),
        if (saving) ...[
          const SizedBox(width: UtenSpacing.s8),
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              semanticsLabel: l10n?.aiChatSettingsSaving,
            ),
          ),
        ],
      ],
    );
  }
}
