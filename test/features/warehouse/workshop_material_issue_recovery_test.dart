import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/warehouse/materialbin/models/workshop_material_models.dart';
import 'package:uten_imp/features/warehouse/materialbin/pages/workshop_material_issue_page.dart';
import 'package:uten_imp/features/warehouse/materialbin/widgets/workshop_material_line_grid.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

import '../../shared/drafts/memory_form_draft_storage.dart';
import 'workshop_material_test_support.dart';

final _identity = StateProvider<AuthenticatedScope?>(
  (ref) => const AuthenticatedScope(userId: 'workshop-test-user'),
);
const _permissions = {Perm.workshopMaterialView, Perm.workshopMaterialIssue};

FakeWorkshopMaterialRepository _direct() => FakeWorkshopMaterialRepository()
  ..settingsResult = const [wmTestWorkshop]
  ..materialsByWorkshop = const {
    'w1': [wmTestPp],
  }
  ..defaultsByWorkshop = const {
    'w1': WmDirectIssueDefaults(
      receiverEmployeeId: 'e1',
      receiverName: '测试领料人',
    ),
  };

WmIssueLineRow _row(WidgetTester tester) => tester
    .widget<UtenEditableGrid<WmIssueLineRow>>(
      find.byKey(const Key('wm-issue-grid')),
    )
    .controller
    .rows
    .single;

ProviderContainer _container(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(WorkshopMaterialIssuePage)),
);

Future<void> _submit(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const Key('wm-issue-submit')));
  await tester.tap(find.byKey(const Key('wm-issue-submit')));
  await tester.pumpAndSettle();
}

class _DelayedRequest extends FakeWorkshopMaterialRepository {
  final source = Completer<WmRequisition>();
  @override
  Future<WmRequisition> requisition(String id) => source.future;
}

void main() {
  testWidgets('网络未知结果锁定原发料内容，重开草稿仍用原键和原数量', (tester) async {
    final storage = MemoryFormDraftStorage();
    final repo = _direct()
      ..directIssueFailure = NetworkTimeoutException()
      ..directIssueFailuresLeft = 1;
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialIssuePage(mode: 'direct'),
      repo: repo,
      permissions: _permissions,
      draftStorage: storage,
    );
    _row(tester)
      ..applyMaterial(wmTestPp)
      ..qty.text = '75';
    await tester.pumpAndSettle();
    await _submit(tester);
    expect(repo.directIssues, hasLength(1));
    final first = repo.directIssues.single;
    expect(find.text('原样重试核对结果'), findsOneWidget);
    final draft = _container(tester).read(formDraftsProvider).single;
    expect(draft.hasUnknownSubmission, isTrue);
    expect(draft.data['command'], isA<Map<String, dynamic>>());
    final qtyInput = tester.widget<TextField>(
      find.byKey(const ValueKey('wm-line-qty-r1')),
    );
    expect(qtyInput.enabled, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await pumpWorkshopMaterialPage(
      tester,
      WorkshopMaterialIssuePage(mode: 'direct', resumeDraftId: draft.id),
      repo: repo,
      permissions: _permissions,
      draftStorage: storage,
    );
    expect(_row(tester).qty.text, '75');
    expect(find.text('原样重试核对结果'), findsOneWidget);
    await _submit(tester);
    expect(repo.directIssues, hasLength(2));
    expect(repo.directIssues.last.key, first.key);
    expect(repo.directIssues.last.lines, first.lines);
    expect(_container(tester).read(formDraftsProvider), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('普通输入自动保存，未提交草稿恢复保留数量和原请求身份', (tester) async {
    final storage = MemoryFormDraftStorage();
    final repo = _direct();
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialIssuePage(mode: 'direct'),
      repo: repo,
      permissions: _permissions,
      draftStorage: storage,
    );
    _row(tester)
      ..applyMaterial(wmTestPp)
      ..qty.text = '31.5';
    await tester.pumpAndSettle();
    final draft = _container(tester).read(formDraftsProvider).single;
    expect(draft.hasUnknownSubmission, isFalse);
    expect(repo.directIssues, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await pumpWorkshopMaterialPage(
      tester,
      WorkshopMaterialIssuePage(mode: 'direct', resumeDraftId: draft.id),
      repo: repo,
      permissions: _permissions,
      draftStorage: storage,
    );
    expect(_row(tester).qty.text, '31.5');
    await _submit(tester);
    expect(repo.directIssues.single.lines.single['qty'], 31.5);
  });

  for (final next in [
    const AuthenticatedScope(userId: 'other-user'),
    const AuthenticatedScope(userId: 'workshop-test-user', readOnly: true),
    const AuthenticatedScope(userId: 'workshop-test-user', actorId: 'operator'),
  ]) {
    testWidgets('已有发料输入不能跨身份或只读边界提交 $next', (tester) async {
      final repo = _direct();
      await pumpWorkshopMaterialPage(
        tester,
        const WorkshopMaterialIssuePage(mode: 'direct'),
        repo: repo,
        permissions: _permissions,
        identityState: _identity,
      );
      _row(tester)
        ..applyMaterial(wmTestPp)
        ..qty.text = '25';
      await tester.pumpAndSettle();
      final container = _container(tester);
      container.read(_identity.notifier).state = next;
      await tester.pumpAndSettle();
      container.read(_identity.notifier).state = const AuthenticatedScope(
        userId: 'workshop-test-user',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('wm-issue-submit')), findsNothing);
      expect(find.byKey(const Key('wm-issue-grid')), findsNothing);
      expect(repo.directIssues, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('迟到申请GET不能在切换后回到原账号时重新填入旧明细', (tester) async {
    final repo = _DelayedRequest();
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialIssuePage(
        requisitionId: 'old-request',
        selectedLineIds: {'old-line'},
      ),
      repo: repo,
      permissions: _permissions,
      identityState: _identity,
      settle: false,
    );
    await tester.pump();
    final container = _container(tester);
    container.read(_identity.notifier).state = const AuthenticatedScope(
      userId: 'new-user',
    );
    await tester.pump();
    container.read(_identity.notifier).state = const AuthenticatedScope(
      userId: 'workshop-test-user',
    );
    repo.source.complete(
      const WmRequisition(
        id: 'old-request',
        requestNo: 'OLD',
        kind: 'ISSUE',
        status: 'PENDING',
        workshopDepartmentId: 'w1',
        lines: [
          WmRequisitionLine(
            id: 'old-line',
            goodsId: 'pp',
            goodsName: '旧账号机密材料',
            requestedQty: 25,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('旧账号机密材料'), findsNothing);
    expect(find.byKey(const Key('wm-issue-submit')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
