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
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

final _server = StateProvider<String>((_) => 'https://audit-a.test');
final _identity = StateProvider<AuthenticatedScope?>(
  (_) => const AuthenticatedScope(userId: 'auditor-a', epoch: 1),
);
final _permissions = StateProvider<Set<String>>((_) => {'audit:view'});
final _repository = StateProvider<AuditLogRepository?>((_) => null);

void main() {
  testWidgets('one directory load uses one repository for every page', (
    tester,
  ) async {
    final pending = Completer<AuditActorPage>();
    final original = _ActorRepository(pending: pending);
    final replacement = _ActorRepository();
    final container = await _pump(tester, original, settle: false);
    await tester.pump(const Duration(milliseconds: 300));
    expect(original.calls.map((call) => call.$1), [1, 2]);
    container.read(_repository.notifier).state = replacement;
    pending.complete(_ActorRepository.page(2));
    await tester.pumpAndSettle();
    expect(original.calls.map((call) => call.$1), [1, 2, 3]);
    expect(replacement.calls, isEmpty);
    expect(find.text('人员3'), findsOneWidget);
  });

  for (final boundary in ['server', 'identity', 'permissions']) {
    testWidgets(
      'audit $boundary change invalidates pending pages without mixing repositories',
      (tester) async {
        final pending = Completer<AuditActorPage>();
        final original = _ActorRepository(pending: pending);
        final replacement = _ActorRepository();
        AuditActorOption? selected;
        final container = await _pump(
          tester,
          original,
          settle: false,
          onSelected: (value) => selected = value,
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(original.calls.map((call) => call.$1), [1, 2]);
        container.read(_repository.notifier).state = replacement;
        switch (boundary) {
          case 'server':
            container.read(_server.notifier).state = 'https://audit-b.test';
          case 'identity':
            container.read(_identity.notifier).state = const AuthenticatedScope(
              userId: 'auditor-b',
              epoch: 2,
            );
          case 'permissions':
            container.read(_permissions.notifier).state = {};
        }
        await tester.pump();
        pending.complete(_ActorRepository.page(2));
        await tester.pumpAndSettle();
        expect(original.calls.map((call) => call.$1), [1, 2]);
        expect(replacement.calls, isEmpty);
        expect(find.byType(AuditActorPicker), findsNothing);
        expect(selected, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }

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

Future<ProviderContainer> _pump(
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
        auditLogRepositoryProvider.overrideWith(
          (ref) => ref.watch(_repository) ?? repository,
        ),
        sharedPreferencesProvider.overrideWithValue(preferences),
        apiBaseUrlProvider.overrideWith((ref) => ref.watch(_server)),
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_identity)),
        currentPermissionsProvider.overrideWith(
          (ref) => ref.watch(_permissions),
        ),
        isSuperAdminProvider.overrideWithValue(false),
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
  return ProviderScope.containerOf(
    tester.element(find.byType(AuditActorPicker)),
    listen: false,
  );
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
