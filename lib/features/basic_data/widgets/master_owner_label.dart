import 'package:flutter/material.dart';

String masterOwnerLabel(String? label) =>
    label?.trim().isNotEmpty == true ? label!.trim() : '未分配';

Color? masterOwnerLabelColor(
  BuildContext context,
  String? label, {
  Color? assignedColor,
}) => masterOwnerLabel(label) == '未分配'
    ? Theme.of(context).colorScheme.error
    : assignedColor;

/// Shared customer/supplier owner presentation, including read-only rows.
class MasterOwnerLabel extends StatelessWidget {
  const MasterOwnerLabel({super.key, required this.label, this.assignedColor});

  final String? label;
  final Color? assignedColor;

  @override
  Widget build(BuildContext context) => Text(
    masterOwnerLabel(label),
    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: masterOwnerLabelColor(
        context,
        label,
        assignedColor: assignedColor,
      ),
    ),
    maxLines: 1,
    softWrap: false,
    overflow: TextOverflow.ellipsis,
  );
}
