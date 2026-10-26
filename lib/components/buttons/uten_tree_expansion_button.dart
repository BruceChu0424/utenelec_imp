import 'dart:async';

import 'package:flutter/material.dart';

import 'uten_button.dart';

/// Shared tree action; hosts own loading, occurrence identity and read scope.
class UtenTreeExpansionButton extends StatelessWidget {
  const UtenTreeExpansionButton({
    super.key,
    required this.expanded,
    required this.onExpand,
    required this.onCollapse,
    this.isLoading = false,
    this.height,
  });

  final bool expanded;
  final FutureOr<void> Function()? onExpand;
  final VoidCallback? onCollapse;
  final bool isLoading;
  final double? height;

  @override
  Widget build(BuildContext context) => UtenButton(
    type: UtenButtonType.ghost,
    height: height,
    isLoading: isLoading,
    onPressed: isLoading ? null : (expanded ? onCollapse : onExpand),
    child: Text(expanded ? '全部收起' : '全部展开'),
  );
}
