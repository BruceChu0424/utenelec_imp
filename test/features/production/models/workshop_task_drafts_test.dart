import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/models/workshop_task_drafts.dart';
import 'package:uten_imp/shared/drafts/form_draft.dart';

FormDraft _draft(String route, [Map<String, dynamic> data = const {}]) =>
    FormDraft(
      id: 'draft',
      title: '填写',
      module: BadgeModule.workshop,
      route: route,
      permission: 'production_execution:view',
      updatedAt: DateTime(2026, 10, 11),
      data: data,
    );

void main() {
  test(
    'material selection preserves unsent ranges and prioritizes unknown commands',
    () {
      const route = '/production/workshop-tasks/draw-request?segmentIds=a';
      final scoped = _draft('$route&drawItemIds=line-b,line-a');
      expect(
        workshopDrawDraftMatchesSelection(scoped, {'line-a', 'line-b'}),
        isTrue,
      );
      expect(workshopDrawDraftMatchesSelection(scoped, {'line-a'}), isFalse);
      expect(workshopDrawDraftMatchesSelection(scoped, {'line-c'}), isFalse);
      expect(
        workshopDrawDraftMatchesSelection(_draft(route), {'line-a'}),
        isFalse,
      );
      expect(workshopDrawDraftMatchesSelection(scoped, null), isTrue);
      final unknown = _draft(route, {formDraftUnknownSubmissionKey: true});
      expect(workshopDrawDraftMatchesSelection(unknown, {'line-c'}), isTrue);
    },
  );

  test(
    'batch report resumes on each source task without matching destinations',
    () {
      final draft = _draft(
        '/production/daily-reports/new?from=workshop-tasks',
        {
          'rows': [
            {'executionSegmentId': 'source-a', 'goodsId': 'other-task'},
            {
              'executionSegmentId': 'source-b',
              'allocations': [
                {'executionSegmentId': 'receiving-task'},
              ],
            },
          ],
        },
      );
      expect(workshopTaskDraftMatches(draft, 'source-a'), isTrue);
      expect(workshopTaskDraftMatches(draft, 'source-b'), isTrue);
      expect(workshopTaskDraftMatches(draft, 'receiving-task'), isFalse);
      expect(workshopTaskDraftMatches(draft, 'other-task'), isFalse);
    },
  );

  test('independent daily report keeps its document draft classification', () {
    final draft = _draft('/production/daily-reports/new', {
      'rows': [
        {'executionSegmentId': 'source-a'},
      ],
    });
    expect(workshopTaskDraftMatches(draft, 'source-a'), isFalse);
  });

  test('draw and discovery snapshots bind all batch source task UUIDs', () {
    for (final draft in [
      _draft('/production/workshop-tasks/draw-request?segmentIds=a,b'),
      _draft('/production/workshop-tasks/draw-request', {
        'preview': {
          'tasks': [
            {'segmentId': 'a'},
            {'segmentId': 'b'},
          ],
        },
      }),
      _draft('/production/material-discovery-request', {
        'tasks': [
          {'segmentId': 'a'},
          {'segmentId': 'b'},
        ],
      }),
    ]) {
      expect(workshopTaskDraftMatches(draft, 'a'), isTrue);
      expect(workshopTaskDraftMatches(draft, 'b'), isTrue);
      expect(workshopTaskDraftMatches(draft, 'ab'), isFalse);
    }
  });

  test('return and adjustment bind only the explicit segment, never plan', () {
    for (final route in [
      '/production/material-return/new?planId=plan&executionSegmentId=a',
      '/production/overproduction-rate-requests/new?segmentId=a',
      '/production/material-increment-requests/new?segmentId=a',
    ]) {
      final draft = _draft(route);
      expect(workshopTaskDraftMatches(draft, 'a'), isTrue);
      expect(workshopTaskDraftMatches(draft, 'plan'), isFalse);
    }
    expect(
      workshopTaskDraftMatches(
        _draft('/production/material-return/new?planId=plan'),
        'a',
      ),
      isFalse,
    );
  });
}
