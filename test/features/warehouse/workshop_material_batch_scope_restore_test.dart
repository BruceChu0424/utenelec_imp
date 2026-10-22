import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/warehouse/materialbin/models/workshop_material_models.dart';
import 'package:uten_imp/features/warehouse/materialbin/pages/workshop_material_issue_batch_page.dart';
import 'package:uten_imp/features/warehouse/materialbin/repositories/workshop_material_repository.dart';
import 'package:uten_imp/features/warehouse/materialbin/widgets/workshop_material_line_grid.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';

import '../../shared/drafts/memory_form_draft_storage.dart';
import 'workshop_material_test_support.dart';

const _selection = {
  'request': ['a', 'b'],
};
const _permissions = {Perm.workshopMaterialView, Perm.workshopMaterialIssue};

WmRequisition _request({double aHandled = 0, double bHandled = 0}) =>
    WmRequisition(
      id: 'request',
      requestNo: 'WM-SCOPE',
      kind: 'ISSUE',
      status: 'PENDING',
      workshopDepartmentId: 'w1',
      binWarehouseId: 'bin1',
      rowVersion: 1,
      allowedActions: const ['FULFIL'],
      lines: [
        WmRequisitionLine(
          id: 'a',
          goodsId: 'pp',
          goodsName: '所选A',
          requestedQty: 25,
          fulfilledQty: aHandled,
          suggestedLeafWarehouseId: 'leafA',
          unitName: '公斤',
        ),
        WmRequisitionLine(
          id: 'b',
          goodsId: 'pp',
          goodsName: '所选B',
          requestedQty: 50,
          fulfilledQty: bHandled,
          suggestedLeafWarehouseId: 'leafA',
          unitName: '公斤',
        ),
        const WmRequisitionLine(
          id: 'foreign',
          goodsId: 'pp',
          goodsName: '未选C',
          requestedQty: 10,
          suggestedLeafWarehouseId: 'leafA',
          unitName: '公斤',
        ),
      ],
    );

class _Repository extends FakeWorkshopMaterialRepository {
  _Repository({double bHandled = 0}) {
    requisitionById = {'request': _request(bHandled: bHandled)};
    materialsByWorkshop = const {
      'w1': [wmTestPp],
    };
  }
  final calls = <Map<String, dynamic>>[];
  bool loseResponse = true;
  @override
  Future<WmIssueResult> fulfil(
    String id, {
    required int expectedVersion,
    required List<Map<String, dynamic>> lines,
    WmSupplement? supplement,
    List<Map<String, dynamic>> materialSetup = const [],
    required String idempotencyKey,
  }) async {
    calls.add({
      'id': id,
      'v': expectedVersion,
      'lines': jsonDecode(jsonEncode(lines)),
      'key': idempotencyKey,
    });
    if (loseResponse) {
      loseResponse = false;
      throw NetworkTimeoutException();
    }
    return WmIssueResult(requisitionId: id, requestNo: 'WM-SCOPE');
  }
}

Future<void> _confirm(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('wm-issue-submit')));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(UtenButton, '确认出库').last);
  await tester.pumpAndSettle();
}

bool _blocked(WidgetTester tester) =>
    (tester.state(find.byType(WorkshopMaterialIssueBatchPage))
            as FormDraftMixin<WorkshopMaterialIssueBatchPage>)
        .formDraftRestorationBlocked;

Future<({FormDraft draft, MemoryFormDraftStorage storage})> _freezeUnknown(
  WidgetTester tester,
  _Repository repo, {
  void Function(UtenEditableGrid<WmIssueLineRow>)? prepare,
}) async {
  final storage = MemoryFormDraftStorage();
  await pumpWorkshopMaterialPage(
    tester,
    const WorkshopMaterialIssueBatchPage(selections: _selection),
    repo: repo,
    draftStorage: storage,
    permissions: _permissions,
  );
  prepare?.call(
    tester.widget<UtenEditableGrid<WmIssueLineRow>>(
      find.byKey(const Key('wm-issue-grid')),
    ),
  );
  await tester.pump();
  await _confirm(tester);
  expect(repo.calls, hasLength(1));
  final container = ProviderScope.containerOf(
    tester.element(find.byType(WorkshopMaterialIssueBatchPage)),
  );
  final draft = container.read(formDraftsProvider).single;
  expect(draft.hasUnknownSubmission, isTrue);
  await tester.pumpWidget(const SizedBox());
  await tester.pumpAndSettle();
  return (draft: draft, storage: storage);
}

Map<String, dynamic> _reviseFrozen(
  FormDraft draft,
  MemoryFormDraftStorage storage,
  void Function(Map<String, dynamic>, Map<String, dynamic>) revise,
) {
  final entry = storage.records.entries.singleWhere((entry) {
    final raw = jsonDecode(entry.value);
    return raw is Map &&
        raw['id'] == draft.id &&
        raw['revision'] == draft.revision;
  });
  final envelope = Map<String, dynamic>.from(jsonDecode(entry.value) as Map);
  final data = Map<String, dynamic>.from(envelope['data'] as Map);
  final command = Map<String, dynamic>.from(
    (data['commands'] as Map)['request'] as Map,
  );
  final body = Map<String, dynamic>.from(command['body'] as Map);
  revise(command, body);
  command['body'] = body;
  command['key'] = wmIdempotencyKey('fulfil', data['nonce'] as String, body);
  (data['commands'] as Map)['request'] = command;
  data[formDraftUnknownSubmissionKey] = command['state'] == 'unknown';
  envelope['data'] = data;
  storage.records[entry.key] = jsonEncode(envelope);
  return command;
}

Future<void> _resume(
  WidgetTester tester,
  _Repository repo,
  FormDraft draft,
  MemoryFormDraftStorage storage,
) => pumpWorkshopMaterialPage(
  tester,
  WorkshopMaterialIssueBatchPage(
    selections: _selection,
    resumeDraftId: draft.id,
  ),
  repo: repo,
  draftStorage: storage,
  permissions: _permissions,
);

void main() {
  for (final scenario in [
    'missing-selected',
    'foreign-line',
    'overlap-prior',
    'false-prior',
    'legacy-subset',
  ]) {
    testWidgets('frozen batch rejects scope corruption: $scenario', (
      tester,
    ) async {
      final repo = _Repository();
      final saved = await _freezeUnknown(tester, repo);
      _reviseFrozen(saved.draft, saved.storage, (command, body) {
        final lines = (body['lines'] as List)
            .map((row) => Map<String, dynamic>.from(row as Map))
            .toList();
        if (scenario == 'foreign-line') {
          lines.last['lineId'] = 'foreign';
          body['lines'] = lines;
          body['priorHandledLineIds'] = <String>[];
        } else if (scenario == 'overlap-prior') {
          body['priorHandledLineIds'] = ['a'];
          repo.requisitionById['request'] = _request(aHandled: 25);
        } else {
          body['lines'] = [lines.first];
          if (scenario == 'legacy-subset') {
            body.remove('priorHandledLineIds');
            repo.requisitionById['request'] = _request(bHandled: 50);
          } else {
            body['priorHandledLineIds'] = scenario == 'false-prior'
                ? ['b']
                : <String>[];
          }
        }
      });
      await _resume(tester, repo, saved.draft, saved.storage);
      expect(
        _blocked(tester),
        isTrue,
        reason:
            'a local command hash cannot replace the original exact selection',
      );
      expect(find.byKey(const Key('wm-issue-submit')), findsNothing);
      expect(repo.calls, hasLength(1));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'legacy exact scope stays recoverable with its original frozen key',
    (tester) async {
      final repo = _Repository();
      final saved = await _freezeUnknown(tester, repo);
      final frozen = _reviseFrozen(
        saved.draft,
        saved.storage,
        (command, body) => body.remove('priorHandledLineIds'),
      );
      await _resume(tester, repo, saved.draft, saved.storage);
      expect(_blocked(tester), isFalse);
      await _confirm(tester);
      expect(repo.calls.last['key'], frozen['key']);
      expect(repo.calls.last['lines'], (frozen['body'] as Map)['lines']);
    },
  );

  testWidgets(
    'split warehouse rows share an original ID without losing the other selected original',
    (tester) async {
      final repo = _Repository();
      final saved = await _freezeUnknown(
        tester,
        repo,
        prepare: (grid) {
          final original = grid.controller.rows.first;
          original.qty.text = '10';
          grid.controller.insertAt(
            1,
            WmIssueLineRow(
              id: 'split-a',
              requisitionLine: original.requisitionLine,
              material: original.material.value,
              leafWarehouseId: 'leafB',
            )..qty.text = '15',
          );
        },
      );
      final frozen = Map<String, dynamic>.from(
        (saved.draft.data['commands'] as Map)['request'] as Map,
      );
      await _resume(tester, repo, saved.draft, saved.storage);
      expect(_blocked(tester), isFalse);
      await _confirm(tester);
      expect(repo.calls.last['key'], frozen['key']);
      expect(repo.calls.last['lines'], (frozen['body'] as Map)['lines']);
    },
  );

  testWidgets(
    'a real previously handled selected row explains the exact frozen remainder',
    (tester) async {
      final repo = _Repository(bHandled: 50);
      final saved = await _freezeUnknown(tester, repo);
      final frozen = _reviseFrozen(saved.draft, saved.storage, (command, body) {
        body['priorHandledLineIds'] = ['b'];
      });
      await _resume(tester, repo, saved.draft, saved.storage);
      expect(_blocked(tester), isFalse);
      await _confirm(tester);
      expect(repo.calls.last['key'], frozen['key']);
      expect(
        (repo.calls.last['lines'] as List).map((row) => (row as Map)['lineId']),
        ['a'],
      );
    },
  );

  testWidgets(
    'local confirmed state without live handled facts becomes unknown and does not finish the batch',
    (tester) async {
      final repo = _Repository();
      final saved = await _freezeUnknown(tester, repo);
      final frozen = _reviseFrozen(
        saved.draft,
        saved.storage,
        (command, body) => command['state'] = 'confirmed',
      );
      await _resume(tester, repo, saved.draft, saved.storage);
      expect(_blocked(tester), isFalse);
      expect(find.text('原样重试核对结果'), findsOneWidget);
      expect(
        repo.calls,
        hasLength(1),
        reason: 'restoration itself never sends the old command',
      );
      await _confirm(tester);
      expect(repo.calls.last['key'], frozen['key']);
    },
  );

  testWidgets(
    'confirmed local state backed by all current selected handled facts never sends again',
    (tester) async {
      final repo = _Repository();
      final saved = await _freezeUnknown(tester, repo);
      _reviseFrozen(
        saved.draft,
        saved.storage,
        (command, body) => command['state'] = 'confirmed',
      );
      repo.requisitionById['request'] = _request(aHandled: 25, bHandled: 50);
      await _resume(tester, repo, saved.draft, saved.storage);
      expect(_blocked(tester), isFalse);
      expect(find.byKey(const Key('wm-issue-submit')), findsNothing);
      expect(repo.calls, hasLength(1));
      expect(find.text('已出库'), findsNWidgets(2));
    },
  );
}
