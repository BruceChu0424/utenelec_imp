import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/components/inputs/uten_employee_picker.dart';
import 'package:uten_imp/components/layout/uten_split_view.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/admin/models/audit_log_entry.dart';
import 'package:uten_imp/features/admin/repositories/audit_log_repository.dart';
import 'package:uten_imp/features/admin/widgets/audit_query_scope.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets(
    'actor picker loads every page, groups departments and confirms identity',
    (tester) async {
      final repository = _ActorRepository();
      AuditActorOption? selected;
      await _pump(tester, repository, onSelected: (actor) => selected = actor);
      expect(find.byType(UtenSplitView), findsOneWidget);
      expect(repository.calls.map((call) => call.$1), [1, 2, 3]);
      await tester.tap(find.text('财务部').first);
      await tester.pumpAndSettle();
      expect(find.text('人员1'), findsNothing);
      expect(find.text('人员2'), findsOneWidget);
      await tester.tap(find.text('人员2'));
      await tester.pumpAndSettle();
      expect(selected, isNull);
      await tester.tap(find.widgetWithText(FilledButton, '确定'));
      await tester.pumpAndSettle();
      expect(selected?.actorId, 'actor-2');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('actor search discards an older pending directory page', (
    tester,
  ) async {
    final pending = Completer<AuditActorPage>();
    final repository = _ActorRepository(pending: pending);
    await _pump(tester, repository, settle: false);
    await tester.pump(const Duration(milliseconds: 300));
    final search = find.descendant(
      of: find.byType(UtenSearchBar),
      matching: find.byType(TextField),
    );
    await tester.enterText(search, 'new');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();
    expect(find.text('new人员1'), findsOneWidget);
    pending.complete(_ActorRepository.page(2));
    await tester.pumpAndSettle();
    expect(find.text('new人员1'), findsOneWidget);
    expect(find.text('人员1'), findsNothing);
    expect(find.text('人员2'), findsNothing);
    expect(find.byType(UtenEmployeeSelectionPanel), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pump(
  WidgetTester tester,
  _ActorRepository repository, {
  ValueChanged<AuditActorOption?>? onSelected,
  bool settle = true,
}) async {
  tester.view.physicalSize = const Size(1000, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        auditLogRepositoryProvider.overrideWithValue(repository),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                final actor = await showDialog<AuditActorOption>(
                  context: context,
                  builder: (_) => const Dialog(
                    child: SizedBox(
                      width: 560,
                      height: 650,
                      child: AuditActorPicker(),
                    ),
                  ),
                );
                onSelected?.call(actor);
              },
              child: const Text('打开人员'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开人员'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

class _ActorRepository extends Fake implements AuditLogRepository {
  _ActorRepository({this.pending});
  final Completer<AuditActorPage>? pending;
  final calls = <(int, String?)>[];

  static AuditActorPage page(int page, [String? keyword]) => AuditActorPage(
    items: [
      AuditActorOption(
        actorId: '${keyword?.isNotEmpty == true ? keyword : 'actor'}-$page',
        name: '${keyword?.isNotEmpty == true ? keyword : ''}人员$page',
        departmentId: page == 1 ? 'sales' : 'finance',
        department: page == 1 ? '销售部' : '财务部',
      ),
    ],
    page: page,
    size: 1,
    total: keyword?.isNotEmpty == true ? 1 : 3,
    totalPages: keyword?.isNotEmpty == true ? 1 : 3,
  );

  @override
  Future<AuditActorPage> actors({
    int page = 1,
    int size = 20,
    String? keyword,
  }) async {
    calls.add((page, keyword));
    if (page == 2 && (keyword?.isEmpty ?? true) && pending != null) {
      return pending!.future;
    }
    return _ActorRepository.page(page, keyword);
  }
}
