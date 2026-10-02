import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/components/layout/uten_paged_picker_list.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/admin/models/audit_log_entry.dart';
import 'package:uten_imp/features/admin/repositories/audit_log_repository.dart';
import 'package:uten_imp/features/admin/widgets/audit_query_scope.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets(
    'actor picker keeps both directions and selects an earlier actor',
    (tester) async {
      final repository = _ActorRepository();
      AuditActorOption? selected;
      await _pump(tester, repository, onSelected: (actor) => selected = actor);
      final next = _list(tester).rowsController!.loadNextPage();
      await tester.pumpAndSettle();
      await next;
      expect(_list(tester).rowsController!.items.map((row) => row.actorId), [
        'actor-1',
        'actor-2',
      ]);
      await _list(tester).onPageChange(3);
      await tester.pumpAndSettle();
      final previous = _list(tester).rowsController!.loadPreviousPage();
      await tester.pumpAndSettle();
      await previous;
      expect(_list(tester).rowsController!.items.map((row) => row.actorId), [
        'actor-2',
        'actor-3',
      ]);
      final earlier = find.byKey(const ValueKey('audit-actor-actor-2'));
      await tester.ensureVisible(earlier);
      await tester.pumpAndSettle();
      await tester.tap(earlier);
      await tester.pumpAndSettle();
      expect(selected?.actorId, 'actor-2');
      expect(repository.calls.map((call) => call.$1), [1, 2, 3, 2]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('actor search discards an older pending page response', (
    tester,
  ) async {
    final pending = Completer<AuditActorPage>();
    final repository = _ActorRepository(pending: pending);
    await _pump(tester, repository);
    final next = _list(tester).rowsController!.loadNextPage();
    await tester.pump();
    final search = find.descendant(
      of: find.byType(UtenSearchBar),
      matching: find.byType(TextField),
    );
    await tester.enterText(search, 'new');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();
    pending.complete(_ActorRepository.page(2));
    await tester.pumpAndSettle();
    await next;
    expect(_list(tester).rowsController!.items.map((row) => row.actorId), [
      'new-1',
    ]);
    expect(_list(tester).currentPage, 1);
    expect(tester.takeException(), isNull);
  });
}

UtenPagedPickerList<AuditActorOption> _list(WidgetTester tester) =>
    tester.widget<UtenPagedPickerList<AuditActorOption>>(
      find.byKey(const Key('audit-actor-paged-list')),
    );

Future<void> _pump(
  WidgetTester tester,
  _ActorRepository repository, {
  ValueChanged<AuditActorOption?>? onSelected,
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
  await tester.pumpAndSettle();
}

class _ActorRepository extends Fake implements AuditLogRepository {
  _ActorRepository({this.pending});
  final Completer<AuditActorPage>? pending;
  final calls = <(int, String?)>[];

  static AuditActorPage page(int page, [String? keyword]) => AuditActorPage(
    items: [
      AuditActorOption(
        actorId: '${keyword?.isNotEmpty == true ? keyword : 'actor'}-$page',
        name: '人员$page',
      ),
    ],
    page: page,
    size: 1,
    total: 3,
    totalPages: 3,
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
