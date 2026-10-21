import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/shared/business_columns/business_column.dart';
import 'package:uten_imp/shared/business_columns/business_column_picker.dart';
import 'package:uten_imp/shared/business_columns/business_columns_repository.dart';

const _own = BusinessColumn(
  id: 'own',
  name: '包装说明',
  scope: 'sales_order',
  canDelete: true,
  value: '保留此单历史值',
);
const _other = BusinessColumn(id: 'other', name: '他人的列');

class _Repository extends BusinessColumnsRepository {
  _Repository() : super(ApiClient(Dio()));
  List<BusinessColumn> columns = [_own, _other];
  int deletes = 0;
  Object? deleteError;
  Completer<void>? deleteBarrier;

  @override
  Future<bool> supportsArithmetic(String scope) async => true;
  @override
  Future<List<BusinessColumn>> search(String scope, String query) async =>
      columns;
  @override
  Future<void> delete(String scope, String id) async {
    deletes++;
    expect(scope, 'sales_order');
    expect(id, 'own');
    if (deleteError case final error?) throw error;
    await deleteBarrier?.future;
    columns = columns.where((column) => column.id != id).toList();
  }
}

void main() {
  test('deletion authority comes only from explicit server metadata', () {
    expect(BusinessColumn.fromJson({'id': 'a'}).canDelete, isFalse);
    expect(
      BusinessColumn.fromJson({'id': 'a', 'canDelete': 'true'}).canDelete,
      isFalse,
    );
    expect(
      BusinessColumn.fromJson({'id': 'a', 'canDelete': true}).canDelete,
      isTrue,
    );
    expect(_own.toSnapshot().containsKey('canDelete'), isFalse);
    expect(BusinessColumn.fromJson(_own.toSnapshot()).canDelete, isFalse);
  });

  Future<ProviderContainer> open(
    WidgetTester tester,
    _Repository repository, {
    List<BusinessColumn> existing = const [],
    ValueChanged<BusinessColumnChoice?>? onChoice,
    bool Function()? isEditingEnabled,
    bool compact = false,
  }) async {
    if (compact) {
      await tester.binding.setSurfaceSize(const Size(390, 780));
      addTearDown(() => tester.binding.setSurfaceSize(null));
    }
    final container = ProviderContainer(
      overrides: [
        businessColumnsRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(
            brightness: compact ? Brightness.dark : Brightness.light,
          ),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(compact ? 2 : 1)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                final choice = await showBusinessColumnPicker(
                  context,
                  scope: 'sales_order',
                  systemColumns: const [BusinessSystemColumn('system', '系统列')],
                  existingIds: existing.map((column) => column.id).toSet(),
                  existingColumns: existing,
                  isEditingEnabled: isEditingEnabled,
                );
                onChoice?.call(choice);
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.ensureVisible(
      find.byKey(const Key('business-column-delete-own')),
    );
    await tester.tap(find.byKey(const Key('business-column-delete-own')));
    await tester.pumpAndSettle();
    expect(find.textContaining('包装说明'), findsWidgets);
    expect(
      find.byKey(const Key('business-column-confirm-delete')),
      findsOneWidget,
    );
  }

  testWidgets('only creator entries have delete; cancel keeps the catalog', (
    tester,
  ) async {
    final repository = _Repository();
    await open(tester, repository);
    expect(find.byKey(const Key('business-column-delete-other')), findsNothing);
    expect(find.text('系统列'), findsOneWidget);
    await confirm(tester);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(repository.deletes, 0);
    expect(find.byKey(const Key('business-column-delete-own')), findsOneWidget);
  });

  testWidgets(
    'deleting selected definition keeps current document values and removal action',
    (tester) async {
      final repository = _Repository();
      BusinessColumnChoice? choice;
      await open(
        tester,
        repository,
        existing: [_own],
        onChoice: (value) => choice = value,
      );
      await confirm(tester);
      await tester.tap(find.byKey(const Key('business-column-confirm-delete')));
      await tester.pumpAndSettle();
      expect(repository.deletes, 1);
      expect(find.byKey(const Key('business-column-delete-own')), findsNothing);
      expect(choice, isNull);
      expect(_own.value, '保留此单历史值');
      await tester.tap(find.byKey(const Key('business-column-view-manage')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('business-column-remove-own')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'delete failure stays in confirmation and allows an explicit retry',
    (tester) async {
      final repository = _Repository()
        ..deleteError = ApiException('FORBIDDEN', 'no');
      await open(tester, repository);
      await confirm(tester);
      await tester.tap(find.byKey(const Key('business-column-confirm-delete')));
      await tester.pumpAndSettle();
      expect(repository.deletes, 1);
      final text = AppLocalizations.of(
        tester.element(find.byKey(const Key('business-column-confirm-delete'))),
      );
      expect(find.text(text.platformColumnDeleteForbidden), findsOneWidget);
      repository.deleteError = null;
      await tester.tap(find.byKey(const Key('business-column-confirm-delete')));
      await tester.pumpAndSettle();
      expect(repository.deletes, 2);
      expect(find.byKey(const Key('business-column-delete-own')), findsNothing);
    },
  );

  testWidgets('pending deletion blocks duplicate requests', (tester) async {
    final repository = _Repository()..deleteBarrier = Completer<void>();
    await open(tester, repository);
    await confirm(tester);
    final button = find.byKey(const Key('business-column-confirm-delete'));
    await tester.tap(button);
    await tester.pump();
    expect(tester.widget<UtenButton>(button).onPressed, isNull);
    expect(repository.deletes, 1);
    repository.deleteBarrier!.complete();
    await tester.pumpAndSettle();
    expect(repository.deletes, 1);
  });

  testWidgets(
    'account change while confirming cannot send the previous accounts delete',
    (tester) async {
      final repository = _Repository();
      final container = await open(tester, repository);
      await confirm(tester);
      container.updateOverrides([
        businessColumnsRepositoryProvider.overrideWithValue(_Repository()),
      ]);
      await tester.pumpAndSettle();
      final button = tester.widget<UtenButton>(
        find.byKey(const Key('business-column-confirm-delete')),
      );
      expect(button.onPressed, isNull);
      expect(repository.deletes, 0);
    },
  );

  testWidgets(
    'page locking after confirmation opens prevents the stale delete callback',
    (tester) async {
      var editing = true;
      final repository = _Repository();
      await open(tester, repository, isEditingEnabled: () => editing);
      await confirm(tester);
      final action = tester
          .widget<UtenButton>(
            find.byKey(const Key('business-column-confirm-delete')),
          )
          .onPressed!;
      editing = false;
      action();
      await tester.pumpAndSettle();
      expect(repository.deletes, 0);
    },
  );

  testWidgets('delete confirmation fits compact dark screens with large text', (
    tester,
  ) async {
    await open(tester, _Repository(), compact: true);
    await confirm(tester);
    await tester.ensureVisible(
      find.byKey(const Key('business-column-confirm-delete')),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const Key('business-column-confirm-delete')).hitTestable(),
      findsOneWidget,
    );
  });
}
