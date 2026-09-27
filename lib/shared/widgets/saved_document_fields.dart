import 'package:flutter/material.dart';

/// A confirmed create result owns the displayed values. Keep attachments and
/// completion actions outside this wrapper so retries cannot edit fields that
/// have already been committed to a business document.
class SavedDocumentFields extends StatelessWidget {
  const SavedDocumentFields({
    super.key,
    required this.locked,
    required this.child,
  });

  final bool locked;
  final Widget child;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: locked,
    child: ExcludeFocus(excluding: locked, child: child),
  );
}
