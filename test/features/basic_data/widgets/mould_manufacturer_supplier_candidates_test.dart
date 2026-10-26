import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/supplier_node.dart';
import 'package:uten_imp/features/basic_data/repositories/mould_manufacturer_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/supplier_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/mould_manufacturer_field.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

class _History extends MouldManufacturerRepository {
  _History() : super(ApiClient(Dio()));
  final queries = <String>[];
  bool fail = false;
  @override
  Future<List<String>> suggestions(String keyword) async {
    queries.add(keyword);
    if (fail) throw StateError('history failed');
    return ['历史模具厂'];
  }
}

class _Suppliers extends Fake implements SupplierRepository {
  final requests = <(String, int, bool)>[];
  Completer<PagedResult<SupplierListItem>>? pending;
  bool fail = false;
  @override
  Future<PagedResult<SupplierListItem>> search(
    String keyword, {
    int page = 1,
    int size = 20,
    bool selectableOnly = false,
  }) async {
    requests.add((keyword, size, selectableOnly));
    if (fail) throw StateError('suppliers failed');
    return pending?.future ?? _page();
  }
}

PagedResult<SupplierListItem> _page() => const PagedResult(
  items: [
    SupplierListItem(id: 'supplier-uuid', name: '精密供应商', linkman: '不显示联系人'),
  ],
  page: 1,
  size: 8,
  total: 1,
  totalPages: 1,
);

final _permissions = StateProvider<Set<String>>(
  (ref) => {Perm.mouldEdit, Perm.supplierView},
);

Future<ProviderContainer> _host(
  WidgetTester tester,
  _Suppliers suppliers,
  _History history,
  List<String> changes, {
  Set<String> permissions = const {Perm.mouldEdit, Perm.supplierView},
  bool enabled = true,
  Locale locale = const Locale('zh'),
}) async {
  final container = ProviderContainer(
    overrides: [
      _permissions.overrideWith((ref) => permissions),
      currentPermissionsProvider.overrideWith((ref) => ref.watch(_permissions)),
      mouldManufacturerRepositoryProvider.overrideWithValue(history),
      supplierRepositoryProvider.overrideWithValue(suppliers),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            width: 480,
            child: Column(
              children: [
                MouldManufacturerField(
                  value: '未保存制造商',
                  enabled: enabled,
                  writePermission: Perm.mouldEdit,
                  onChanged: changes.add,
                ),
                const TextField(key: ValueKey('other-field')),
                const MouldManufacturerValue(),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  return container;
}

Finder get _input => find.descendant(
  of: find.byType(MouldManufacturerField),
  matching: find.byType(TextField),
);

void main() {
  testWidgets(
    'supplier names require supplier view and selecting only emits text',
    (tester) async {
      final suppliers = _Suppliers();
      final changes = <String>[];
      await _host(tester, suppliers, _History(), changes);
      await tester.enterText(_input, '精密');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(suppliers.requests.last, ('精密', 8, true));
      expect(find.text('不显示联系人'), findsNothing);
      await tester.tap(find.text('精密供应商'));
      await tester.pumpAndSettle();
      expect(changes.last, '精密供应商');
      expect(tester.widget<TextField>(_input).controller!.text, '精密供应商');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'without supplier view no supplier request or supplier section appears',
    (tester) async {
      final suppliers = _Suppliers();
      await _host(
        tester,
        suppliers,
        _History(),
        [],
        permissions: {Perm.mouldEdit},
      );
      await tester.tap(_input);
      await tester.pumpAndSettle();
      expect(suppliers.requests, isEmpty);
      expect(find.text('供应商名称（供核实选用）'), findsNothing);
      expect(find.text('历史模具厂'), findsOneWidget);
    },
  );

  testWidgets(
    'cancelling candidates keeps the original draft without committing an option',
    (tester) async {
      final changes = <String>[];
      await _host(tester, _Suppliers(), _History(), changes);
      await tester.tap(_input);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('other-field')));
      await tester.pumpAndSettle();
      expect(changes, isEmpty);
      expect(tester.widget<TextField>(_input).controller!.text, '未保存制造商');
      expect(find.text('精密供应商'), findsNothing);
    },
  );

  testWidgets(
    'revocation discards late supplier results while retaining input',
    (tester) async {
      final suppliers = _Suppliers()
        ..pending = Completer<PagedResult<SupplierListItem>>();
      final changes = <String>[];
      final container = await _host(tester, suppliers, _History(), changes);
      await tester.tap(_input);
      await tester.pump();
      container.read(_permissions.notifier).state = {Perm.mouldEdit};
      container.read(currentPermissionsProvider);
      suppliers.pending!.complete(_page());
      await tester.pumpAndSettle();
      expect(find.text('精密供应商'), findsNothing);
      expect(changes, isEmpty);
      expect(tester.widget<TextField>(_input).controller!.text, '未保存制造商');
    },
  );

  testWidgets(
    'old callbacks cannot commit after revoke and restore in the same frame',
    (tester) async {
      final changes = <String>[];
      final container = await _host(tester, _Suppliers(), _History(), changes);
      await tester.tap(_input);
      await tester.pumpAndSettle();
      final option = find.ancestor(
        of: find.text('精密供应商'),
        matching: find.byType(MenuItemButton),
      );
      final oldSelection = tester.widget<MenuItemButton>(option).onPressed!;
      container.read(_permissions.notifier).state = {Perm.mouldEdit};
      container.read(currentPermissionsProvider);
      container.read(_permissions.notifier).state = {
        Perm.mouldEdit,
        Perm.supplierView,
      };
      container.read(currentPermissionsProvider);
      oldSelection();
      await tester.pumpAndSettle();
      expect(changes, isEmpty);
      expect(find.text('精密供应商'), findsNothing);
    },
  );

  testWidgets(
    'disabled or revoked mould edit prevents writing and loading candidates',
    (tester) async {
      final history = _History();
      final suppliers = _Suppliers();
      final container = await _host(
        tester,
        suppliers,
        history,
        [],
        permissions: {Perm.supplierView},
      );
      expect(tester.widget<TextField>(_input).enabled, isFalse);
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) => widget is IconButton && widget.tooltip == '选择历史制造商',
              ),
            )
            .onPressed,
        isNull,
      );
      expect(history.queries, isEmpty);
      expect(suppliers.requests, isEmpty);
      container.read(_permissions.notifier).state = {
        Perm.mouldEdit,
        Perm.supplierView,
      };
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(_input).enabled, isTrue);
    },
  );

  testWidgets(
    'one candidate source failing does not block the other or free text',
    (tester) async {
      final changes = <String>[];
      final history = _History()..fail = true;
      final suppliers = _Suppliers();
      await _host(tester, suppliers, history, changes);
      await tester.tap(_input);
      await tester.pumpAndSettle();
      expect(find.text('候选加载失败，仍可直接输入'), findsOneWidget);
      expect(find.text('精密供应商'), findsOneWidget);
      history.fail = false;
      suppliers.fail = true;
      await tester.enterText(_input, '仍可自由输入');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('历史模具厂'), findsOneWidget);
      expect(find.text('供应商候选加载失败，仍可直接输入'), findsOneWidget);
      expect(changes.last, '仍可自由输入');
    },
  );

  testWidgets(
    'missing manufacturer has an explicit placeholder and edit hint without a fabricated value',
    (tester) async {
      final changes = <String>[];
      await _host(tester, _Suppliers(), _History(), changes);
      expect(find.text('待补充'), findsOneWidget);
      expect(find.byTooltip('制造商尚未登记，可在编辑模具或编辑模式中补充'), findsOneWidget);
      expect(changes, isEmpty);
      expect(
        mouldManufacturerDisplayText('  已确认厂家  ', missingLabel: '待补充'),
        '已确认厂家',
      );
    },
  );
  for (final locale in const [Locale('zh'), Locale('en'), Locale('ko')]) {
    testWidgets('manufacturer new copy follows ${locale.languageCode} locale', (
      tester,
    ) async {
      final l10n = lookupAppLocalizations(locale);
      await _host(
        tester,
        _Suppliers()..fail = true,
        _History()..fail = true,
        [],
        locale: locale,
      );
      expect(find.text(l10n.mouldManufacturerMissing), findsOneWidget);
      expect(
        find.byTooltip(l10n.mouldManufacturerMissingEditableHint),
        findsOneWidget,
      );
      expect(
        find.byTooltip(l10n.mouldManufacturerChooseHistoryTooltip),
        findsOneWidget,
      );
      await tester.tap(_input);
      await tester.pumpAndSettle();
      expect(
        find.text(l10n.mouldManufacturerHistoryUnavailable),
        findsOneWidget,
      );
      expect(
        find.text(l10n.mouldManufacturerSupplierUnavailable),
        findsOneWidget,
      );
      expect(
        find.text(l10n.mouldManufacturerSupplierCandidates),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
