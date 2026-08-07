// 「XXX 处理中」徽标（show-as-locked）。他人认领时显示；本人/无人认领不显示。
import 'package:flutter/material.dart';

import '../models/task_claim_view.dart';

class TaskClaimBadge extends StatelessWidget {
  const TaskClaimBadge({super.key, required this.claim});
  final TaskClaimView? claim;

  @override
  Widget build(BuildContext context) {
    final c = claim;
    if (c == null || c.claimedByMe) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_outline, size: 14, color: scheme.onTertiaryContainer),
          const SizedBox(width: 4),
          Text(
            '${c.claimedByName} 处理中',
            style: TextStyle(fontSize: 12, color: scheme.onTertiaryContainer),
          ),
        ],
      ),
    );
  }
}
