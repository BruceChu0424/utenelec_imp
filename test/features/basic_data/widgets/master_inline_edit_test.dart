import 'dart:async';
import 'package:dio/dio.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/widgets/master_edit_dialog.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/master_inline_edit.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';

typedef _Row = ({String id, String name, int? days});
final _name = MasterInlineField<_Row>(
  key: 'name',
  read: (row) => row.name,
  required: true,
);
final _days = MasterInlineField<_Row>(
  key: 'days',
  read: (row) => row.days,
  type: MasterFieldType.integer,
);

void main() {
  testWidgets(
    'imperative editor route keeps local dirty confirmation without parent registration',
    (tester) async {
      final controller = MasterInlineEditController<_Row>()..begin();
      addTearDown(controller.dispose);
      controller.setValue('1', _name, 'After', originalValue: 'Before');
      final navigatorKey = GlobalKey<NavigatorState>();
      final router = GoRouter(
        navigatorKey: navigatorKey,
        initialLocation: '/home',
        routes: [
          DraftAwareGoRoute(
            path: '/home',
            builder: (context, _) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => MasterInlineEditGuard<_Row>(
                      controller: controller,
                      authorityKey: 'editor',
                      child: const Scaffold(body: Text('Imperative editor')),
                    ),
                  ),
                ),
                child: const Text('Open editor'),
              ),
            ),
          ),
          DraftAwareGoRoute(
            path: '/next',
            builder: (_, _) => const Scaffold(body: Text('Next page')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open editor'));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 15),
      );
      expect(find.text('Imperative editor'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // A MaterialPageRoute owns its own leave decision; it must neither
      // inherit the underlying GoRouter page identity nor bypass dirty edits.
      unawaited(navigatorKey.currentState!.maybePop());
      await tester.pumpAndSettle();
      expect(find.text('Discard unsaved changes?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(controller.dirty, isTrue);
      expect(find.text('Imperative editor'), findsOneWidget);

      unawaited(navigatorKey.currentState!.maybePop());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard changes'));
      await tester.pumpAndSettle();
      expect(controller.dirty, isFalse);
      expect(controller.active, isFalse);
      expect(find.text('Open editor'), findsOneWidget);
      router.go('/next');
      await tester.pumpAndSettle();
      expect(find.text('Next page'), findsOneWidget);
      expect(find.byType(UtenAlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('declarative editor keeps its route exit confirmation', (
    tester,
  ) async {
    final controller = MasterInlineEditController<_Row>()..begin();
    addTearDown(controller.dispose);
    controller.setValue('1', _name, 'After', originalValue: 'Before');
    final router = GoRouter(
      initialLocation: '/editor',
      routes: [
        DraftAwareGoRoute(
          path: '/editor',
          builder: (_, _) => MasterInlineEditGuard<_Row>(
            controller: controller,
            authorityKey: 'editor',
            child: const Scaffold(body: Text('Declarative editor')),
          ),
        ),
        DraftAwareGoRoute(
          path: '/next',
          builder: (_, _) => const Scaffold(body: Text('Next page')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    router.go('/next');
    await tester.pumpAndSettle();
    expect(find.text('Discard unsaved changes?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.text('Declarative editor'), findsOneWidget);
    expect(controller.dirty, isTrue);
    router.go('/next');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard changes'));
    await tester.pumpAndSettle();
    expect(find.text('Next page'), findsOneWidget);
    expect(controller.dirty, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'inline rich geometry and scope changes resize real table columns',
    (tester) async {
      final controller = MasterInlineEditController<_Row>()..begin();
      addTearDown(controller.dispose);
      const row = (id: '1', name: 'Original', days: 1);
      const rows = [row];
      var geometry = 260.0;
      var measured = 0;
      double richWidth(BuildContext context, _Row row, TextScaler scaler) {
        measured++;
        return geometry;
      }

      late MasterColumnDef<_Row> projected;
      Widget app() {
        final source = MasterColumnDef<_Row>(
          key: 'name',
          label: '名称',
          width: 140,
          value: (row) => row.name,
          exactValueOf: (_) => '0.0001',
          measureValueOf: (row) => 'measurement-key-${row.id}',
          measureWidthOf: richWidth,
          measureWidthScope: geometry,
          cellBuilder: (_, row) => Row(
            children: [
              const Icon(Icons.inventory_2_outlined),
              const SizedBox(width: 12),
              Expanded(child: Text(row.name, overflow: TextOverflow.ellipsis)),
            ],
          ),
        );
        projected = controller
            .columns(
              columns: [source],
              idOf: (row) => row.id,
              fields: {'name': _name},
            )
            .single;
        return MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 400,
              child: MasterDataTableView<_Row>(
                columns: [projected],
                items: rows,
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
                showFullscreenToggle: false,
              ),
            ),
          ),
        );
      }

      double width() =>
          tester.getSize(find.byKey(const ValueKey('inline-1-name'))).width;

      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(
        width(),
        greaterThanOrEqualTo(260),
        reason: 'entering inline mode must preserve rich cell geometry',
      );
      expect(measured, 1);
      final narrow = width();
      geometry = 380;
      // Same rows, same callback and same measurement text: only the scope
      // retires the previous width. Field assertions would miss this stale cache.
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(measured, 2);
      expect(width(), greaterThanOrEqualTo(380));
      expect(width(), greaterThan(narrow));
      expect(projected.value(row), 'Original');
      expect(projected.exactValueOf!(row), '0.0001');
      expect(find.textContaining('measurement-key-'), findsNothing);
      controller.setValue('1', _name, 'Edited', originalValue: row.name);
      final writes = <Map<String, dynamic>>[];
      expect(
        await controller.save((id, patch) async {
          expect(id, '1');
          writes.add(patch);
        }),
        isTrue,
      );
      expect(writes, [
        {'name': 'Edited'},
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'read shell opt-in rejects unknown grants and every reader boundary change',
    () {
      final api = ApiClient(Dio());
      const identity = AuthenticatedScope(userId: 'column-editor', epoch: 1);
      SensitiveReadBoundary boundary({
        AuthenticatedScope? owner = identity,
        ApiClient? client,
        bool admin = false,
        Set<String> permissions = const {'goods:view', 'goods:view:all'},
      }) => SensitiveReadBoundary(
        identity: owner,
        api: client ?? api,
        permissions: permissions,
        superAdmin: admin,
      );
      final before = boundary(
        permissions: const {'goods:view', 'goods:view:all', 'goods:edit'},
      );
      final after = boundary();
      bool retain(
        SensitiveReadBoundary? old,
        SensitiveReadBoundary next, {
        String? permission = 'goods:edit',
      }) =>
          canRetainMasterReadShell(old, next, writeOnlyPermission: permission);
      expect(retain(before, after), isTrue);
      expect(retain(after, before), isTrue);
      expect(retain(null, after), isFalse);
      expect(retain(before, after, permission: null), isFalse);
      expect(retain(before, before), isFalse);
      expect(
        retain(
          boundary(owner: null, permissions: before.permissions),
          boundary(owner: null),
        ),
        isFalse,
      );
      for (final next in [
        boundary(owner: const AuthenticatedScope(userId: 'other', epoch: 1)),
        boundary(
          owner: const AuthenticatedScope(
            userId: 'column-editor',
            actorId: 'actor',
            epoch: 1,
          ),
        ),
        boundary(
          owner: const AuthenticatedScope(
            userId: 'column-editor',
            readOnly: true,
            epoch: 1,
          ),
        ),
        boundary(
          owner: const AuthenticatedScope(userId: 'column-editor', epoch: 2),
        ),
        boundary(
          owner: const AuthenticatedScope(
            userId: 'column-editor',
            epoch: 1,
            businessResetGeneration: 1,
          ),
        ),
        boundary(client: ApiClient(Dio())),
        boundary(admin: true),
        boundary(permissions: const {'goods:view:all'}),
        boundary(permissions: const {'goods:view'}),
        boundary(
          permissions: const {'goods:view', 'goods:view:all', 'unknown:grant'},
        ),
      ]) {
        expect(retain(before, next), isFalse);
      }
    },
  );

  test(
    'inline columns preserve presentation measurement without changing the business value',
    () {
      final controller = MasterInlineEditController<_Row>()..begin();
      addTearDown(controller.dispose);
      final source = MasterColumnDef<_Row>(
        key: 'name',
        label: '名称',
        width: 180,
        value: (row) => row.name,
        measureValueOf: (row) => '${row.name} [presentation controls]',
      );
      final wrapped = controller
          .columns(
            columns: [source],
            idOf: (row) => row.id,
            fields: {'name': _name},
          )
          .single;
      const _Row row = (id: '1', name: 'Original', days: null);
      expect(wrapped.value(row), 'Original');
      expect(wrapped.measureValueOf!(row), 'Original [presentation controls]');
      expect(identical(wrapped.measureValueOf, source.measureValueOf), isTrue);
      controller.cancel();
      expect(
        identical(
          controller
              .columns(
                columns: [source],
                idOf: (row) => row.id,
                fields: {'name': _name},
              )
              .single,
          source,
        ),
        isTrue,
      );
    },
  );

  test('authority invalidation cancels pending mode preparation', () async {
    final controller = MasterInlineEditController<_Row>();
    addTearDown(controller.dispose);
    final pending = Completer<void>();
    final prepared = controller.prepareToBegin(() => pending.future);
    expect(controller.preparing, isTrue);
    expect(controller.active, isFalse);
    controller.cancel();
    pending.complete();
    await prepared;
    expect(controller.preparing, isFalse);
    expect(controller.active, isFalse);
  });

  test(
    'decimal input reaches the server without a floating point round trip',
    () async {
      final controller = MasterInlineEditController<_Row>()..begin();
      addTearDown(controller.dispose);
      final money = MasterInlineField<_Row>(
        key: 'amount',
        read: (_) => null,
        type: MasterFieldType.money,
      );
      controller.setValue(
        '1',
        money,
        '99999999999999.123456789012345678901234',
        originalValue: null,
      );
      expect(
        await controller.save((_, patch) async {
          expect(patch['amount'], '99999999999999.123456789012345678901234');
        }),
        isTrue,
      );
    },
  );
  testWidgets(
    'repeated leave attempts allow one decision and a double click cannot pop the editor',
    (tester) async {
      final controller = MasterInlineEditController<_Row>()..begin();
      addTearDown(controller.dispose);
      controller.setValue('1', _name, 'After', originalValue: 'Before');
      final decisions = <Future<bool>>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    decisions.add(controller.confirmLeave(context)),
                child: const Text('Leave editor'),
              ),
            ),
          ),
        ),
      );
      final leave = tester.widget<TextButton>(find.byType(TextButton));
      leave.onPressed!();
      leave.onPressed!();
      await tester.pumpAndSettle();
      expect(find.byType(UtenAlertDialog, skipOffstage: false), findsOneWidget);
      final decide = tester.widget<FilledButton>(find.byType(FilledButton));
      decide.onPressed!();
      decide.onPressed!();
      await tester.pumpAndSettle();
      expect(find.text('Leave editor'), findsOneWidget);
      expect(find.byType(UtenAlertDialog), findsNothing);
      expect(controller.dirty, isFalse);
      expect(await Future.wait(decisions), [true, false]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a stale discard confirmation cannot erase a new authority draft',
    (tester) async {
      final controller = MasterInlineEditController<_Row>()..begin();
      addTearDown(controller.dispose);
      controller.setValue('1', _name, 'Old draft', originalValue: 'Before');
      Future<bool>? decision;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => decision = controller.confirmLeave(context),
                child: const Text('Leave editor'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Leave editor'));
      await tester.pumpAndSettle();
      controller.cancel();
      controller.begin();
      controller.setValue(
        '1',
        _name,
        'New authority draft',
        originalValue: 'Before',
      );
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(await decision!, isFalse);
      expect(controller.patchFor('1'), {'name': 'New authority draft'});
      expect(controller.active, isTrue);
    },
  );

  test(
    'draft only keeps changed fields and excludes a manually reverted value',
    () {
      final controller = MasterInlineEditController<_Row>()..begin();
      addTearDown(controller.dispose);
      controller.setValue('1', _name, 'After', originalValue: 'Before');
      expect(controller.patchFor('1'), {'name': 'After'});
      controller.setValue('1', _name, 'Before', originalValue: 'Before');
      expect(controller.dirty, isFalse);
    },
  );

  test(
    'partial success keeps only unsuccessful rows and retry cannot repeat saved rows',
    () async {
      final controller = MasterInlineEditController<_Row>()..begin();
      addTearDown(controller.dispose);
      controller.setValue('1', _name, 'One', originalValue: 'Before');
      controller.setValue('2', _name, 'Two', originalValue: 'Before');
      final saved = <String>[];
      expect(
        await controller.save((id, patch) async {
          if (id == '2') throw StateError('conflict');
          saved.add(id);
        }),
        isFalse,
      );
      expect(saved, ['1']);
      expect(controller.patchFor('1'), isEmpty);
      expect(controller.patchFor('2'), {'name': 'Two'});
      expect(
        await controller.save((id, patch) async {
          saved.add(id);
        }),
        isTrue,
      );
      expect(saved, ['1', '2']);
      expect(controller.active, isTrue);
      expect(controller.dirty, isFalse);
    },
  );

  test(
    'invalid integer blocks all writes and empty optional number clears with null',
    () async {
      final controller = MasterInlineEditController<_Row>()..begin();
      addTearDown(controller.dispose);
      controller.setValue('1', _days, '1.25', originalValue: 4);
      var calls = 0;
      expect(
        await controller.save((id, patch) async {
          calls++;
        }),
        isFalse,
      );
      expect(calls, 0);
      controller.setValue('1', _days, '', originalValue: 4);
      expect(
        await controller.save((id, patch) async {
          calls++;
          expect(patch, {'days': null});
        }),
        isTrue,
      );
      expect(calls, 1);
    },
  );

  test(
    'authority invalidation prevents the next row after an in-flight write',
    () async {
      final controller = MasterInlineEditController<_Row>()..begin();
      addTearDown(controller.dispose);
      controller.setValue('1', _name, 'One', originalValue: 'Before');
      controller.setValue('2', _name, 'Two', originalValue: 'Before');
      final pending = Completer<void>();
      final calls = <String>[];
      final result = controller.save((id, patch) {
        calls.add(id);
        return pending.future;
      });
      controller.invalidateAuthority();
      pending.complete();
      expect(await result, isFalse);
      expect(calls, ['1']);
      expect(controller.dirty, isFalse);
      expect(controller.active, isFalse);
    },
  );

  testWidgets('cancel editing confirms unsaved changes and sends no save', (
    tester,
  ) async {
    final controller = MasterInlineEditController<_Row>()..begin();
    addTearDown(controller.dispose);
    controller.setValue('1', _name, 'After', originalValue: 'Before');
    var writes = 0;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: MasterInlineEditActions(
            controller: controller,
            canEdit: true,
            onSave: (id, patch) async {
              writes++;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('取消编辑'));
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的修改？'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(controller.dirty, isTrue);
    await tester.tap(find.text('取消编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(controller.dirty, isFalse);
    expect(writes, 0);
  });
}
