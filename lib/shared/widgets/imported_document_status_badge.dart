import 'package:flutter/material.dart';

import '../../components/data_display/uten_status_badge.dart';
import '../documents/imported_document_policy.dart';

/// Archive disposition is separate from original approval/closed fields.
class ImportedDocumentStatusBadge extends StatelessWidget {
  const ImportedDocumentStatusBadge({super.key});

  @override
  Widget build(BuildContext context) => const UtenStatusBadge(
    label: importedBusinessHistoryLabel,
    type: UtenStatusBadgeType.neutral,
    icon: Icons.lock_outline,
  );
}
