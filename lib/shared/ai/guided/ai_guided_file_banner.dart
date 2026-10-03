import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../core/theme/uten_tokens.dart';
import '../chat/ai_chat_l10n.dart';
import 'ai_guided_file_plan.dart';

/// Reports observed work only. Suggested route steps are never painted as done.
class AiGuidedFileBanner extends ConsumerWidget {
  const AiGuidedFileBanner({
    super.key,
    required this.plan,
    required this.status,
    this.detail,
    this.busy = false,
    this.onRetry,
    this.completedStages = const [],
    this.activeStage,
    this.filledFields = const [],
  });
  final AiGuidedFilePlan plan;
  final String status;
  final String? detail;
  final bool busy;
  final VoidCallback? onRetry;
  final List<String> completedStages;
  final String? activeStage;
  final List<String> filledFields;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(aiGuidedFileIdentityProvider);
    if (current != plan.identity) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('ai-guided-file-progress'),
      margin: const EdgeInsets.only(bottom: UtenSpacing.s12),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: UtenRadius.lgAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  Icons.description_outlined,
                  color: colors.primary,
                  size: 20,
                ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(
                  aiChatText(context, status),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          Text(plan.file.name),
          if (completedStages.isNotEmpty || activeStage != null) ...[
            const SizedBox(height: UtenSpacing.s8),
            Wrap(
              spacing: UtenSpacing.s12,
              runSpacing: UtenSpacing.s8,
              children: [
                for (final key in {...completedStages, ?activeStage})
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        completedStages.contains(key)
                            ? Icons.check_circle_outline
                            : Icons.pending_outlined,
                        size: 16,
                        color: colors.primary,
                      ),
                      const SizedBox(width: UtenSpacing.s4),
                      Text(
                        aiChatText(context, key),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
              ],
            ),
          ],
          if (filledFields.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s8),
            Text(
              aiChatText(context, 'guidedFilledFields'),
              style: Theme.of(context).textTheme.labelLarge,
            ),
            for (final field in filledFields) Text(field),
          ],
          if (detail?.isNotEmpty == true) ...[
            const SizedBox(height: UtenSpacing.s8),
            Text(detail!),
          ],
          const SizedBox(height: UtenSpacing.s8),
          Text(
            aiChatText(context, 'documentManualSave'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (onRetry != null)
            Padding(
              padding: const EdgeInsets.only(top: UtenSpacing.s8),
              child: UtenButton(
                type: UtenButtonType.secondary,
                onPressed: busy ? null : onRetry,
                child: Text(aiChatText(context, 'retry')),
              ),
            ),
        ],
      ),
    );
  }
}
