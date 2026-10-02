import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/shared/business_columns/business_column.dart';
import 'package:uten_imp/shared/business_columns/business_column_picker.dart';
import 'package:uten_imp/shared/business_columns/business_columns_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

class _Repository extends BusinessColumnsRepository {
  _Repository() : super(ApiClient(Dio()));
  bool failCreate = false;
  bool arithmetic = true;
  int creates = 0;
  Completer<BusinessColumn>? pendingCreate;
  List<BusinessColumn> results = [];
  @override
  Future<bool> supportsArithmetic(String scope) async => arithmetic;
  @override
  Future<List<BusinessColumn>> search(String scope, String query) async =>
      results;
  @override
  Future<BusinessColumn> create({
    required String scope,
    required String name,
    required String type,
    required String operation,
  }) async {
    creates++;
    if (pendingCreate != null) return pendingCreate!.future;
    if (failCreate) throw StateError('retry');
    return BusinessColumn(
      id: 'new',
      scope: scope,
      name: name,
      type: type,
      operation: operation,
    );
  }
}

Future<void> _open(
  WidgetTester tester,
  _Repository repository,
  ValueChanged<BusinessColumnChoice?> selected, {
  Size size = const Size(1000, 1000),
  Brightness brightness = Brightness.light,
  double scale = 1,
  double keyboard = 0,
  bool masked = false,
  List<BusinessColumn> existing = const [],
  ValueChanged<ProviderContainer>? onContainer,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        businessColumnsRepositoryProvider.overrideWithValue(repository),
      ],
      child: RepaintBoundary(
        key: const Key('editor-capture'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: brightness == Brightness.dark
              ? buildDarkTheme()
              : buildLightTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              size: size,
              textScaler: TextScaler.linear(scale),
              viewInsets: EdgeInsets.only(bottom: keyboard),
            ),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) {
                onContainer?.call(ProviderScope.containerOf(context));
                return TextButton(
                  onPressed: () async => selected(
                    await showBusinessColumnPicker(
                      context,
                      scope: 'sales_order',
                      systemColumns: const [],
                      existingIds: existing.map((c) => c.id).toSet(),
                      existingColumns: existing,
                      priceMasked: masked,
                    ),
                  ),
                  child: const Text('Open'),
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

Future<void> _new(WidgetTester tester, {String name = '包装费'}) async {
  await tester.tap(find.byKey(const Key('business-column-view-create')));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('business-column-type')), findsNothing);
  await tester.enterText(find.byKey(const Key('business-column-name')), name);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

Future<void> _select(WidgetTester tester, String key, String label) async {
  final field = find.byKey(Key(key));
  await tester.ensureVisible(field);
  await tester.tap(field);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'permission and actor changes invalidate capabilities with the same API client',
    () {
      final permissions = StateProvider<Set<String>>(
        (ref) => {'sales_order:view', 'sales_order:price:view'},
      );
      final scope = StateProvider<AuthenticatedScope?>(
        (ref) => const AuthenticatedScope(userId: 'user'),
      );
      final api = ApiClient(Dio());
      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          currentPermissionsProvider.overrideWith(
            (ref) => ref.watch(permissions),
          ),
          authenticatedScopeProvider.overrideWith((ref) => ref.watch(scope)),
        ],
      );
      addTearDown(container.dispose);
      final original = container.read(businessColumnsRepositoryProvider);
      container.read(permissions.notifier).state = {'sales_order:view'};
      final restricted = container.read(businessColumnsRepositoryProvider);
      expect(identical(original, restricted), isFalse);
      expect(identical(restricted.api, api), isTrue);
      container.read(scope.notifier).state = const AuthenticatedScope(
        userId: 'user',
        actorId: 'actor',
      );
      expect(
        identical(
          restricted,
          container.read(businessColumnsRepositoryProvider),
        ),
        isFalse,
      );
    },
  );
  setUpAll(() async {
    if (const bool.fromEnvironment('COLUMN_EDITOR_SCREENSHOTS')) {
      await (FontLoader(
        'NotoSansSC',
      )..addFont(rootBundle.load('assets/fonts/NotoSansSCFull.ttf'))).load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });
  testWidgets(
    'official amount creation reveals target and exact preview without copying example values',
    (tester) async {
      final repository = _Repository();
      BusinessColumnChoice? selected;
      await _open(tester, repository, (value) => selected = value);
      await _new(tester);
      expect(find.byKey(const Key('business-column-operation')), findsNothing);
      await _select(tester, 'business-column-type', '参与正式金额');
      expect(find.text('本行金额'), findsOneWidget);
      expect(find.text('100 + 20 = 120'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const Key('business-column-example-value')),
      );
      await tester.enterText(
        find.byKey(const Key('business-column-example-value')),
        '30',
      );
      await tester.pump();
      expect(find.text('100 + 30 = 130'), findsOneWidget);
      await tester.tap(find.byKey(const Key('business-column-create')));
      await tester.pumpAndSettle();
      expect(repository.creates, 1);
      expect(selected!.column!.operation, 'ADD');
      expect(selected!.column!.type, 'AMOUNT');
      expect(selected!.column!.value, isNull);
    },
  );

  testWidgets('save error keeps entered rule and permits direct retry', (
    tester,
  ) async {
    final repository = _Repository()..failCreate = true;
    BusinessColumnChoice? selected;
    await _open(tester, repository, (value) => selected = value);
    await _new(tester);
    await _select(tester, 'business-column-type', '参与正式金额');
    await _select(tester, 'business-column-operation', '减 (−)');
    await tester.tap(find.byKey(const Key('business-column-create')));
    await tester.pumpAndSettle();
    expect(selected, isNull);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('business-column-name')))
          .controller!
          .text,
      '包装费',
    );
    expect(
      tester
          .widget<UtenDropdownField>(
            find.byKey(const Key('business-column-operation')),
          )
          .value,
      'SUBTRACT',
    );
    repository.failCreate = false;
    await tester.tap(find.byKey(const Key('business-column-create')));
    await tester.pumpAndSettle();
    expect(repository.creates, 2);
    expect(selected!.column!.operation, 'SUBTRACT');
  });

  testWidgets(
    'same definition reuses identity and existing definition cannot be readded',
    (tester) async {
      const column = BusinessColumn(
        id: 'fee',
        name: '包装费',
        type: 'AMOUNT',
        operation: 'ADD',
      );
      final repository = _Repository()..results = [column];
      BusinessColumnChoice? selected;
      await _open(tester, repository, (value) => selected = value);
      await _new(tester);
      await _select(tester, 'business-column-type', '参与正式金额');
      await tester.tap(find.byKey(const Key('business-column-create')));
      await tester.pumpAndSettle();
      expect(selected!.column!.id, 'fee');
      expect(repository.creates, 0);
      await _open(
        tester,
        repository,
        (value) => selected = value,
        existing: [column],
      );
      await _new(tester);
      await _select(tester, 'business-column-type', '参与正式金额');
      expect(
        tester
            .widget<UtenButton>(find.byKey(const Key('business-column-create')))
            .onPressed,
        isNull,
      );
      expect(repository.creates, 0);
    },
  );

  testWidgets(
    'full document rejects creation before writing the shared catalog',
    (tester) async {
      final repository = _Repository();
      await _open(
        tester,
        repository,
        (_) {},
        existing: [
          for (var i = 0; i < 32; i++)
            BusinessColumn(id: 'column-$i', name: '已有列$i'),
        ],
      );
      await _new(tester, name: '新费用');
      expect(
        tester
            .widget<UtenButton>(find.byKey(const Key('business-column-create')))
            .onPressed,
        isNull,
      );
      expect(repository.creates, 0);
      expect(
        find.byKey(const Key('business-column-view-manage')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'removing a column needs an explicit action and cancel changes nothing',
    (tester) async {
      const column = BusinessColumn(
        id: 'fee',
        name: '包装费',
        type: 'AMOUNT',
        operation: 'ADD',
      );
      BusinessColumnChoice? selected;
      await _open(
        tester,
        _Repository(),
        (value) => selected = value,
        existing: [column],
      );
      await tester.tap(find.byKey(const Key('business-column-view-manage')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('business-column-remove-fee')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('business-column-confirm-remove')),
        findsOneWidget,
      );
      expect(selected, isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(selected, isNull);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('business-column-view-manage')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('business-column-remove-fee')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('business-column-confirm-remove')));
      await tester.pumpAndSettle();
      expect(selected!.removeColumnId, 'fee');
    },
  );

  testWidgets(
    'masked users can record numbers but cannot create or remove a fee',
    (tester) async {
      const column = BusinessColumn(
        id: 'fee',
        name: '包装费',
        type: 'AMOUNT',
        operation: 'ADD',
      );
      await _open(
        tester,
        _Repository(),
        (_) {},
        existing: [column],
        masked: true,
      );
      await _new(tester);
      final field = tester.widget<UtenDropdownField>(
        find.byKey(const Key('business-column-type')),
      );
      expect(field.items.map((item) => item.value), ['TEXT', 'NUMBER']);
      await tester.tap(find.byKey(const Key('business-column-view-manage')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const Key('business-column-remove-fee')),
            )
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets('failure from an old session cannot release a new session save', (
    tester,
  ) async {
    final first = _Repository()..pendingCreate = Completer<BusinessColumn>();
    final next = _Repository()..pendingCreate = Completer<BusinessColumn>();
    late ProviderContainer container;
    BusinessColumnChoice? selected;
    await _open(
      tester,
      first,
      (value) => selected = value,
      onContainer: (value) => container = value,
    );
    await _new(tester, name: '补充信息');
    await tester.tap(find.byKey(const Key('business-column-create')));
    await tester.pump();
    expect(first.creates, 1);
    container.updateOverrides([
      businessColumnsRepositoryProvider.overrideWithValue(next),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('business-column-create')));
    await tester.pump();
    expect(next.creates, 1);
    first.pendingCreate!.completeError(StateError('old request failed'));
    await tester.pump();
    expect(
      tester
          .widget<UtenButton>(find.byKey(const Key('business-column-create')))
          .isLoading,
      isTrue,
    );
    next.pendingCreate!.complete(
      const BusinessColumn(id: 'next', name: '补充信息'),
    );
    await tester.pumpAndSettle();
    expect(selected!.column!.id, 'next');
    expect(next.creates, 1);
  });

  testWidgets(
    'lost amount access blocks the chosen rule without silently changing its purpose',
    (tester) async {
      final first = _Repository();
      final restricted = _Repository()..arithmetic = false;
      late ProviderContainer container;
      await _open(
        tester,
        first,
        (_) {},
        onContainer: (value) => container = value,
      );
      await _new(tester);
      await _select(tester, 'business-column-type', '参与正式金额');
      container.updateOverrides([
        businessColumnsRepositoryProvider.overrideWithValue(restricted),
      ]);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<UtenDropdownField>(
              find.byKey(const Key('business-column-type')),
            )
            .value,
        'AMOUNT',
      );
      expect(
        tester
            .widget<UtenButton>(find.byKey(const Key('business-column-create')))
            .onPressed,
        isNull,
      );
      expect(restricted.creates, 0);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'desktop ${brightness.name} amount editor exposes configuration and fixed action area',
      (tester) async {
        await _open(
          tester,
          _Repository(),
          (_) {},
          size: const Size(1100, 1200),
          brightness: brightness,
        );
        await _new(tester);
        await _select(tester, 'business-column-type', '参与正式金额');
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const Key('business-column-create')).hitTestable(),
          findsOneWidget,
        );
        if (const bool.fromEnvironment('COLUMN_EDITOR_SCREENSHOTS')) {
          await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const Key('editor-capture')),
            );
            final image = await boundary.toImage();
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            await File(
              'build/column-editor-desktop-${brightness.name}.png',
            ).writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }
      },
    );
    testWidgets(
      'narrow ${brightness.name} amount editor remains usable with keyboard and large text',
      (tester) async {
        await _open(
          tester,
          _Repository(),
          (_) {},
          size: const Size(390, 780),
          brightness: brightness,
          scale: 1.4,
          keyboard: 260,
        );
        await _new(tester);
        await _select(tester, 'business-column-type', '参与正式金额');
        await tester.ensureVisible(
          find.byKey(const Key('business-column-example-value')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('business-column-create')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        if (const bool.fromEnvironment('COLUMN_EDITOR_SCREENSHOTS')) {
          await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const Key('editor-capture')),
            );
            final image = await boundary.toImage();
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            await File(
              'build/column-editor-${brightness.name}.png',
            ).writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }
      },
    );
  }
}
