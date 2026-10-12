import '../../../shared/drafts/form_draft.dart';

/// Only the editor's source execution segments bind a checkpoint to a task.
/// Receiving tasks, goods IDs and material issue IDs are never source identity.
bool workshopTaskDraftMatches(FormDraft draft, String segmentId) {
  final uri = Uri.tryParse(draft.route);
  if (uri == null || segmentId.isEmpty) return false;
  bool queryMatches(String key) =>
      uri.queryParameters[key]?.split(',').contains(segmentId) ?? false;
  bool rowsMatch(Object? rows, String key) =>
      rows is List && rows.any((row) => row is Map && row[key] == segmentId);

  switch (uri.path) {
    case '/production/daily-reports/new':
      // An independently created daily report keeps its document draft entry.
      if (uri.queryParameters['from'] != 'workshop-tasks' &&
          !uri.queryParameters.containsKey('executionSegmentId') &&
          !uri.queryParameters.containsKey('executionSegmentIds')) {
        return false;
      }
      return queryMatches('executionSegmentId') ||
          queryMatches('executionSegmentIds') ||
          rowsMatch(draft.data['rows'], 'executionSegmentId');
    case '/production/workshop-tasks/draw-request':
      final preview = draft.data['preview'];
      return queryMatches('segmentIds') ||
          (preview is Map && rowsMatch(preview['tasks'], 'segmentId'));
    case '/production/material-discovery-request':
      return queryMatches('segmentIds') ||
          rowsMatch(draft.data['tasks'], 'segmentId');
    case '/production/material-return/new':
      return queryMatches('executionSegmentId');
    case '/production/overproduction-rate-requests/new':
    case '/production/material-increment-requests/new':
      return queryMatches('segmentId');
    default:
      return false;
  }
}
