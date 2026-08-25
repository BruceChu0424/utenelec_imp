import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/client_access_models.dart';
import 'package:uten_imp/features/basic_data/widgets/client_access_panel.dart';

void main() {
  testWidgets('375px dark mode with large text keeps actions reachable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const settings = ClientAccessSettings(
      clientId: 'client-1',
      ownerEmployeeId: 'owner-1',
      ownerEmployeeName: '负责人甲',
      accessVersion: 2,
      viewers: [ClientAccessViewer(employeeId: 'viewer-1', name: '协同人乙')],
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          themeMode: ThemeMode.dark,
          darkTheme: ThemeData.dark(),
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
              child: ClientAccessPanel(
                clientId: 'client-1',
                clientName: '一个名称较长的内销与外贸统一客户',
                loader: (_) async => settings,
                saver: (_, _) async => settings,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('负责人和可见人'), findsOneWidget);
    expect(find.textContaining('原负责人仍在职'), findsOneWidget);
    expect(find.byKey(const ValueKey('client-access-save')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
