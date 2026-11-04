import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';

enum UtenWorkflowNodeState { done, current, pending, rejected, skipped }

@immutable
class UtenWorkflowNode {
  const UtenWorkflowNode({
    required this.title,
    this.state = UtenWorkflowNodeState.pending,
    this.details,
    this.key,
  });
  final String title;
  final UtenWorkflowNodeState state;
  final String? details;
  final Key? key;
}

/// A forward sequence of business stages, using the subcontract progress style.
/// Event history remains a separate concern (UtenProgressTimeline).
class UtenWorkflowProgress extends StatelessWidget {
  const UtenWorkflowProgress({
    super.key,
    required this.nodes,
    this.horizontalScroll = false,
    this.emptyText = '暂无流程进度',
  });
  final List<UtenWorkflowNode> nodes;
  final bool horizontalScroll;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (nodes.isEmpty) return Text(emptyText, style: theme.textTheme.bodySmall);
    Widget arrow() => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Icon(
        Icons.chevron_right_rounded,
        size: 14,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
    if (horizontalScroll) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var i = 0; i < nodes.length; i++) ...[
              _WorkflowNode(node: nodes[i]),
              if (i + 1 < nodes.length) arrow(),
            ],
          ],
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) => Wrap(
        spacing: UtenSpacing.s4,
        runSpacing: UtenSpacing.s8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (var i = 0; i < nodes.length; i++)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: math.max(
                      0,
                      math.min(
                        240,
                        constraints.maxWidth - (i + 1 < nodes.length ? 18 : 0),
                      ),
                    ),
                  ),
                  child: _WorkflowNode(node: nodes[i]),
                ),
                if (i + 1 < nodes.length) arrow(),
              ],
            ),
        ],
      ),
    );
  }
}

class _WorkflowNode extends StatelessWidget {
  const _WorkflowNode({required this.node});
  final UtenWorkflowNode node;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (color, icon, stateLabel) = switch (node.state) {
      UtenWorkflowNodeState.done => (
        theme.colorScheme.primary,
        Icons.check_circle_rounded,
        '已完成',
      ),
      UtenWorkflowNodeState.current => (
        theme.colorScheme.tertiary,
        Icons.timelapse_rounded,
        '当前环节',
      ),
      UtenWorkflowNodeState.pending => (
        theme.colorScheme.onSurfaceVariant,
        Icons.radio_button_unchecked,
        '未完成',
      ),
      UtenWorkflowNodeState.rejected => (
        theme.colorScheme.error,
        Icons.cancel_outlined,
        '已驳回',
      ),
      UtenWorkflowNodeState.skipped => (
        theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
        Icons.remove_circle_outline,
        '已跳过',
      ),
    };
    final emphasized =
        node.state == UtenWorkflowNodeState.done ||
        node.state == UtenWorkflowNodeState.current ||
        node.state == UtenWorkflowNodeState.rejected;
    final details = node.details?.trim();
    return Semantics(
      label:
          '${node.title}，$stateLabel${details == null || details.isEmpty ? '' : '，$details'}',
      excludeSemantics: true,
      child: Container(
        key: node.key,
        constraints: const BoxConstraints(maxWidth: 240),
        padding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s8,
          vertical: UtenSpacing.s4,
        ),
        decoration: BoxDecoration(
          color: color.withValues(alpha: emphasized ? 0.12 : 0.06),
          borderRadius: UtenRadius.mdAll,
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 13, color: color),
                const SizedBox(width: UtenSpacing.s4),
                Flexible(
                  child: Text(
                    node.title,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: color,
                      fontWeight: emphasized ? FontWeight.w700 : null,
                      decoration: node.state == UtenWorkflowNodeState.skipped
                          ? TextDecoration.lineThrough
                          : null,
                    ),
                  ),
                ),
              ],
            ),
            if (details != null && details.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  details,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: node.state == UtenWorkflowNodeState.rejected
                        ? color
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
