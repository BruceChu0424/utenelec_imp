import 'package:flutter/material.dart';

import '../../../components/layout/uten_form_grid.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/theme/uten_tokens.dart';
import 'master_edit_dialog.dart';

/// Uses the editor's field definitions so view mode cannot reorder a master.
class MasterReadOnlyFields extends StatelessWidget {
  const MasterReadOnlyFields({
    super.key,
    required this.fields,
    required this.valueOf,
    this.showGroupHeaders = true,
  });
  final List<MasterFieldDef> fields;
  final String? Function(MasterFieldDef field) valueOf;
  final bool showGroupHeaders;

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<MasterFieldDef>>{};
    for (final field in fields) {
      (groups[field.group ?? ''] ??= []).add(field);
    }
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (index, group) in groups.entries.indexed) ...[
          if (index > 0) const SizedBox(height: UtenSpacing.s20),
          if (showGroupHeaders && group.key.isNotEmpty) ...[
            UtenSectionHeader(title: group.key, subdued: true),
            const SizedBox(height: UtenSpacing.s12),
          ],
          UtenFormGrid(
            columns: 4,
            maxColumns: 4,
            minFieldWidth: 260,
            children: [
              for (final field in group.value)
                Container(
                  padding: const EdgeInsets.all(UtenSpacing.s12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHigh,
                    borderRadius: UtenRadius.mdAll,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        field.label,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s4),
                      Text(
                        valueOf(field)?.trim().isNotEmpty == true
                            ? valueOf(field)!
                            : '—',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
