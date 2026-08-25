import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/handover/data_handover_models.dart';
import 'package:uten_imp/shared/handover/data_handover_preview_card.dart';

void main() {
  testWidgets('blocker remains readable on narrow screen with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(2)),
            child: SingleChildScrollView(
              child: DataHandoverPreviewCard(
                preview: DataHandoverPreview(
                  sourceEmployeeId: 'source-1',
                  scopes: {'sales'},
                  items: [
                    DataHandoverPreviewItem(
                      key: 'sales.blocker',
                      label: '仍有待审核销售单据',
                      scope: 'sales',
                      count: 3,
                      action: DataHandoverAction.blocking,
                    ),
                  ],
                  hasBlockers: true,
                  requiresTarget: true,
                  total: 3,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('仍有待审核销售单据'), findsOneWidget);
    expect(find.text('必须先处理'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
