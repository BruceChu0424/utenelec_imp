import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/features/basic_data/models/client_access_models.dart';
import 'package:uten_imp/features/basic_data/widgets/client_access_panel.dart';

void main() {
  const original = ClientAccessSettings(
    clientId: 'client-1',
    ownerEmployeeId: 'owner-1',
    ownerEmployeeName: '负责人甲',
    accessVersion: 7,
    viewers: [
      ClientAccessViewer(
        employeeId: 'viewer-1',
        name: '协同人乙',
        code: 'E002',
        departmentName: '销售二组',
      ),
    ],
  );

  testWidgets('panel explains unified customer scope and historical boundary', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: ClientAccessPanel(
              clientId: 'client-1',
              clientName: '客户一号',
              loader: (_) async => original,
              saver: (_, _) async => original,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('负责人和可见人'), findsOneWidget);
    expect(find.text('客户一号'), findsOneWidget);
    expect(find.textContaining('内销、外贸客户使用同一套规则'), findsOneWidget);
    expect(find.textContaining('历史制单、审批和审计记录不会被改写'), findsOneWidget);
    expect(find.text('负责人甲'), findsOneWidget);
    expect(find.text('协同人乙'), findsOneWidget);
  });

  testWidgets('load failure stays recoverable with an inline retry', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: ClientAccessPanel(
              clientId: 'client-1',
              clientName: '客户一号',
              loader: (_) async {
                calls++;
                if (calls == 1) throw StateError('offline');
                return original;
              },
              saver: (_, _) async => original,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('客户访问设置加载失败，请重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text('负责人甲'), findsOneWidget);
  });

  testWidgets('saving is explicit and carries CAS version plus audit reason', (
    tester,
  ) async {
    ClientAccessUpdate? captured;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => showClientAccessPanel(
                    context: context,
                    ref: ref,
                    clientId: 'client-1',
                    clientName: '客户一号',
                    loader: (_) async => original,
                    saver: (_, update) async {
                      captured = update;
                      return const ClientAccessSettings(
                        clientId: 'client-1',
                        ownerEmployeeId: 'owner-1',
                        ownerEmployeeName: '负责人甲',
                        accessVersion: 8,
                        viewers: [],
                      );
                    },
                  ),
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    final chip = tester.widget<InputChip>(
      find.widgetWithText(InputChip, '协同人乙'),
    );
    chip.onDeleted!();
    await tester.pump();
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('client-access-reason')),
        matching: find.byType(TextField),
      ),
      '客户交接',
    );
    await tester.tap(find.byKey(const ValueKey('client-access-save')));
    await tester.pumpAndSettle();

    expect(find.text('确认保存客户访问设置？'), findsOneWidget);
    await tester.tap(find.text('确认保存'));
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    expect(captured!.ownerEmployeeId, 'owner-1');
    expect(captured!.viewerEmployeeIds, isEmpty);
    expect(captured!.expectedAccessVersion, 7);
    expect(captured!.reason, '客户交接');
    expect(find.byType(UtenInput), findsNothing);
  });
}
