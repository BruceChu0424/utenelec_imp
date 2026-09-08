import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../concurrency/task_claim_session.dart';
import '../providers/session_provider.dart';
import '../repositories/task_claim_repository.dart';

TaskClaimSession financeReviewClaim(ProviderContainer container) {
  final identity = container.read(sessionProvider);
  return TaskClaimSession(
    container.read(taskClaimRepositoryProvider),
    strict: true,
    isCurrentSession: () =>
        identical(container.read(sessionProvider), identity),
  );
}

class FinanceReviewClaimNotice extends StatelessWidget {
  const FinanceReviewClaimNotice({
    super.key,
    required this.claim,
    required this.onRetry,
  });
  final TaskClaimSession? claim;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Card(
    color: Theme.of(context).colorScheme.errorContainer,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          const Icon(Icons.lock_outline),
          const SizedBox(width: 12),
          Expanded(child: Text(claim?.failureMessage ?? '尚未取得有效审核占用，当前仅可查看')),
          TextButton(onPressed: onRetry, child: const Text('重新认领并刷新')),
        ],
      ),
    ),
  );
}

/// Dialog decisions also pause immediately when their underlying lease fails.
class FinanceReviewClaimButton extends ConsumerWidget {
  const FinanceReviewClaimButton({
    super.key,
    required this.claim,
    required this.onPressed,
    required this.child,
    this.style,
  });
  final TaskClaimSession claim;
  final VoidCallback? onPressed;
  final Widget child;
  final ButtonStyle? style;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(sessionProvider);
    return ListenableBuilder(
      listenable: claim,
      builder: (_, _) => FilledButton(
        onPressed: claim.isReady ? onPressed : null,
        style: style,
        child: child,
      ),
    );
  }
}
