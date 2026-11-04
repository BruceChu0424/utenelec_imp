import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_workflow_progress.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/features/applications/models/business_application.dart';
import 'package:uten_imp/features/applications/widgets/business_application_progress.dart';

BusinessApplicationEvent event(String action, String stage, {int round = 2}) =>
    BusinessApplicationEvent(
      action: action,
      actorName: '审核员工',
      stage: stage,
      occurredAt: DateTime.utc(2026, 11, 3),
      round: round,
      remark: '凭证需补充',
    );
BusinessApplication application({
  String status = 'REVIEWING',
  String? stage = 'FINANCE_REVIEW',
  bool routingStale = false,
  List<BusinessApplicationEvent> events = const [],
}) => BusinessApplication(
  id: 'fixture',
  applicationNo: 'SQ20261103-fixture',
  kind: 'PAYMENT',
  title: '申请',
  amount: '123.45',
  status: status,
  approvalStage: stage,
  approvalRoutingStale: routingStale,
  applicantId: 'applicant',
  applicantName: '申请人',
  createdAt: DateTime.utc(2026, 11, 3),
  fields: const {},
  round: 2,
  events: events,
);
Future<List<UtenWorkflowNode>> pump(
  WidgetTester tester,
  BusinessApplication value, {
  double width = 1440,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildDarkTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: const TextScaler.linear(1.4)),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: BusinessApplicationProgress(application: value),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  return tester
      .widget<UtenWorkflowProgress>(find.byType(UtenWorkflowProgress))
      .nodes;
}

void main() {
  test(
    'shared paper fixture preserves all kind routes and contextual stage wording',
    () {
      final contract =
          jsonDecode(
                File(
                  'clients/windows_legacy/progress/contracts/employee-applications-workflow.json',
                ).readAsStringSync(),
              )
              as Map;
      for (final kind in businessApplicationKinds.keys) {
        final stages = (contract['orderedStages'] as Map)[kind] as List;
        expect(businessApplicationWorkflowStages[kind], stages);
        final labels = contract['stageLabels'] as Map;
        final defaults = labels['default'] as Map;
        final overrides = labels[kind] as Map? ?? const {};
        for (final stage in stages) {
          expect(
            businessApplicationStageLabel(stage as String, kind: kind),
            overrides[stage] ?? defaults[stage],
          );
        }
      }
    },
  );
  for (final width in [390.0, 1440.0]) {
    testWidgets(
      'current round authority is preserved at $width with large text',
      (tester) async {
        final nodes = await pump(
          tester,
          application(
            events: [
              event('SUBMITTED', 'DEPARTMENT'),
              event('APPROVED', 'DEPARTMENT'),
              event('APPROVED', 'FINANCE_INITIAL'),
              event('APPROVED', 'EXECUTIVE', round: 1),
            ],
          ),
          width: width,
        );
        expect(nodes.map((n) => n.state), [
          UtenWorkflowNodeState.done,
          UtenWorkflowNodeState.done,
          UtenWorkflowNodeState.done,
          UtenWorkflowNodeState.current,
          UtenWorkflowNodeState.pending,
          UtenWorkflowNodeState.pending,
        ]);
      },
    );
  }
  testWidgets('withdrawn drafts do not show obsolete approvals as complete', (
    tester,
  ) async {
    final nodes = await pump(
      tester,
      application(
        status: 'DRAFT',
        stage: null,
        events: [event('APPROVED', 'DEPARTMENT')],
      ),
    );
    expect(nodes.first.state, UtenWorkflowNodeState.current);
    expect(
      nodes.skip(1).every((n) => n.state == UtenWorkflowNodeState.pending),
      isTrue,
    );
  });
  testWidgets(
    'rejected applications identify the rejecting node and revision entry',
    (tester) async {
      final nodes = await pump(
        tester,
        application(
          status: 'REJECTED',
          stage: null,
          events: [
            event('APPROVED', 'DEPARTMENT'),
            event('REJECTED', 'FINANCE_INITIAL'),
          ],
        ),
      );
      expect(nodes.first.state, UtenWorkflowNodeState.current);
      expect(nodes[2].state, UtenWorkflowNodeState.rejected);
      expect(nodes[2].details, '凭证需补充');
    },
  );
  testWidgets(
    'cancelled payment returns payment node to current despite old paid event',
    (tester) async {
      final nodes = await pump(
        tester,
        application(
          status: 'APPROVED',
          stage: 'PAYMENT',
          events: [
            event('PAID', 'PAYMENT'),
            event('PAYMENT_CANCELLED', 'PAYMENT'),
          ],
        ),
      );
      expect(nodes.last.state, UtenWorkflowNodeState.current);
    },
  );
  testWidgets(
    'routing changes pause the expired route without fabricating a rejection',
    (tester) async {
      final value = application(
        status: 'SUBMITTED',
        stage: 'DEPARTMENT',
        routingStale: true,
        events: [event('SUBMITTED', 'DEPARTMENT')],
      );
      final nodes = await pump(tester, value, width: 390);
      expect(value.status, 'SUBMITTED');
      expect(value.statusLabel, '待重新提交');
      expect(nodes.first.title, '待重新提交');
      expect(nodes.first.state, UtenWorkflowNodeState.current);
      expect(nodes[1].state, UtenWorkflowNodeState.pending);
      expect(
        nodes.any((node) => node.state == UtenWorkflowNodeState.rejected),
        isFalse,
      );
    },
  );
}
