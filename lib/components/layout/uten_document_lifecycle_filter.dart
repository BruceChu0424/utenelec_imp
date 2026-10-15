import 'package:flutter/material.dart';

import '../feedback/uten_segment_badge_label.dart';
import '../../core/theme/uten_tokens.dart';
import 'uten_filter_toolbar.dart';
import 'uten_history_time_filter.dart';

/// Shared presentation for working documents and their reviewable history.
/// Each page supplies its own server predicates and decides whether an approved
/// document still has work outstanding through [hasOngoing].
class UtenDocumentLifecycleFilter extends StatelessWidget {
  const UtenDocumentLifecycleFilter({
    super.key,
    required this.selected,
    required this.history,
    required this.status,
    required this.onCategoryChanged,
    required this.onHistoryStatusChanged,
    required this.historyTime,
    required this.onHistoryTimeChanged,
    this.hasOngoing = false,
    this.ongoingLabel = '进行中',
    this.historyIncludesDrafts = true,
    this.ongoingCount,
    this.draftCount,
    this.searchHint,
    this.searchValue,
    this.onSearchChanged,
  });

  final bool selected;
  final bool history;
  final int? status;
  final bool hasOngoing;
  final String ongoingLabel;
  final bool historyIncludesDrafts;
  final int? ongoingCount;
  final int? draftCount;
  final ValueChanged<int?> onCategoryChanged;
  final ValueChanged<int?> onHistoryStatusChanged;
  final UtenHistoryTimeValue historyTime;
  final ValueChanged<UtenHistoryTimeValue> onHistoryTimeChanged;
  final String? searchHint;
  final String? searchValue;
  final ValueChanged<String>? onSearchChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      UtenFilterToolbar<int?>(
        autoSelectBadge: false,
        segments: [
          UtenFilterSegment(
            value: 0,
            label: '草稿',
            count: draftCount,
            countForm: UtenSegmentCountForm.actionable,
          ),
          if (hasOngoing)
            UtenFilterSegment(
              value: 1,
              label: ongoingLabel,
              count: ongoingCount,
              countForm: UtenSegmentCountForm.inProgress,
            ),
          const UtenFilterSegment(value: null, label: '历史单据'),
        ],
        selected: selected ? {history ? null : status} : const {},
        onSelectionChanged: onCategoryChanged,
        searchHint: searchHint,
        initialSearchValue: searchValue,
        onSearchChanged: onSearchChanged,
      ),
      if (history) ...[
        const SizedBox(height: UtenSpacing.s8),
        UtenFilterToolbar<int?>(
          autoSelectBadge: false,
          segments: [
            const UtenFilterSegment(value: null, label: '全部'),
            if (historyIncludesDrafts)
              const UtenFilterSegment(value: 0, label: '草稿'),
            const UtenFilterSegment(value: 1, label: '已审'),
            const UtenFilterSegment(value: -1, label: '已反审'),
          ],
          selected: {status},
          onSelectionChanged: onHistoryStatusChanged,
        ),
        const SizedBox(height: UtenSpacing.s8),
        UtenHistoryTimeFilter(
          value: historyTime,
          onChanged: onHistoryTimeChanged,
        ),
      ],
    ],
  );
}
