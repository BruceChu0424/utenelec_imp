import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/handover/data_handover_models.dart';
import 'package:uten_imp/shared/handover/data_handover_preview_card.dart';

void main() {
  testWidgets('shows authoritative occurrence counts and effective targets', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        themeMode: ThemeMode.dark,
        darkTheme: ThemeData.dark(),
        home: const Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(1.6)),
            child: SingleChildScrollView(
              child: DataHandoverPreviewCard(
                preview: DataHandoverPreview(
                  sourceEmployeeId: 'source-1',
                  targetEmployeeId: 'default-1',
                  scopes: {'client', 'finance'},
                  transferCount: 2,
                  historyAccessCount: 5,
                  releaseCount: 1,
                  blockingCount: 0,
                  total: 8,
                  scopeTargetEmployeeIds: {
                    'client': 'default-1',
                    'finance': 'existing-1',
                  },
                  scopeTargetEmployeeNames: {
                    'client': '默认接手人丁',
                    'finance': '既有接手人丙',
                  },
                  items: [
                    DataHandoverPreviewItem(
                      key: 'client.owner',
                      label: '负责客户',
                      scope: 'client',
                      count: 2,
                      action: DataHandoverAction.transfer,
                    ),
                    DataHandoverPreviewItem(
                      key: 'history.finance',
                      label: '财务历史',
                      scope: 'finance',
                      count: 5,
                      action: DataHandoverAction.historyAccess,
                    ),
                    DataHandoverPreviewItem(
                      key: 'workflow.claims',
                      label: '临时认领',
                      scope: 'finance',
                      count: 1,
                      action: DataHandoverAction.release,
                    ),
                  ],
                  hasBlockers: false,
                  requiresTarget: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('影响 8 项次'), findsOneWidget);
    expect(find.text('转移 2'), findsOneWidget);
    expect(find.text('历史查阅 5'), findsOneWidget);
    expect(find.text('释放 1'), findsOneWidget);
    expect(find.text('阻塞 0'), findsOneWidget);
    expect(find.textContaining('已有 1 个业务范围'), findsOneWidget);
    expect(find.textContaining('默认接手剩余范围 · 默认接手人丁'), findsOneWidget);
    expect(find.textContaining('沿用既有交接 · 既有接手人丙'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
