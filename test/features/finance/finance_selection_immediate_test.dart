import 'dart:async';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import '../../support/audit_screenshot_support.dart';
import 'package:uten_imp/features/finance/config/finance_doc_config.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/providers/finance_name_provider.dart';
import 'package:uten_imp/features/finance/widgets/finance_grid_columns.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/accounting_expense_purpose.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/payment_style_node.dart';
import 'package:uten_imp/features/basic_data/repositories/payment_style_repository.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';
import '../../support/native_detail_reader_overrides.dart';

class _Names extends ChangeNotifier implements FinanceNameService {
  final expensePurposeReads = <AccountingExpensePurpose>[];
  @override
  List<FinanceStyleOption> stylesFor(String category) => const [
    FinanceStyleOption(id: 'first', name: '办公费用'),
    FinanceStyleOption(id: 'second', name: '运输费用'),
  ];
  @override
  String styleName(String? id, String category) => '—';
  @override
  List<FinanceStyleOption> expenseStylesFor(AccountingExpensePurpose purpose) {
    expensePurposeReads.add(purpose);
    return purpose == AccountingExpensePurpose.ordinaryExpense
        ? stylesFor('EXPENSE')
        : const [];
  }

  @override
  String expenseStyleName(String? id, AccountingExpensePurpose purpose) =>
      purpose == AccountingExpensePurpose.ordinaryExpense
      ? styleName(id, 'EXPENSE')
      : '—';
  @override
  Map<String, String> get accountEntries => const {
    'first': '基本户',
    'second': '备用账户',
  };
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _app(WidgetBuilder builder, {Set<String> permissions = const {}}) =>
    ProviderScope(
      overrides: [currentPermissionsProvider.overrideWithValue(permissions)],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: SizedBox(width: 240, child: Builder(builder: builder)),
          ),
        ),
      ),
    );

class _CreateRepository extends Fake implements PaymentStyleRepository {
  final pending = Completer<PaymentStyleDetail>();
  final refresh = Completer<List<PaymentStyleNode>>();
  int creates = 0;
  int treeReads = 0;
  PaymentStyleSaveInput? submitted;
  @override
  Future<List<PaymentStyleNode>> tree({String? category}) async {
    treeReads++;
    if (treeReads > 1) return refresh.future;
    return const [];
  }

  @override
  Future<PaymentStyleDetail> create(PaymentStyleSaveInput input) {
    creates++;
    submitted = input;
    return pending.future;
  }
}

void main() {
  const captureScreens = bool.fromEnvironment('UTEN_CAPTURE_FINANCE_STYLE');
  for (final type in [
    FinanceDocType.expense,
    FinanceDocType.otherIncome,
    FinanceDocType.bankTransfer,
  ]) {
    testWidgets(
      '$type selected label updates in the next frame without rebuilding its host',
      (tester) async {
        final names = _Names();
        final mode = type == FinanceDocType.bankTransfer
            ? ItemMode.transfer
            : ItemMode.allocate;
        final row = FinanceGridRow(mode: mode);
        addTearDown(names.dispose);
        addTearDown(row.dispose);
        var hostBuilds = 0;
        await tester.pumpWidget(
          _app((context) {
            hostBuilds++;
            return financeGridColumns(
                  mode,
                  context: context,
                  names: names,
                  type: type,
                )
                .singleWhere(
                  (column) =>
                      column.key ==
                      (mode == ItemMode.transfer ? 'inAccount' : 'style'),
                )
                .cellBuilder(context, row);
          }),
        );
        final initialBuilds = hostBuilds;
        for (var count = 0; count < 6; count++) {
          final selected = count.isEven ? 'first' : 'second';
          final label = mode == ItemMode.transfer
              ? names.accountEntries[selected]!
              : names
                    .stylesFor('EXPENSE')
                    .firstWhere((option) => option.id == selected)
                    .name!;
          await tester.tap(find.byType(UtenDropdownField));
          await tester.pumpAndSettle();
          await tester.tap(find.text(label).last);
          await tester.pump();
          expect(
            tester
                .widget<UtenDropdownField>(find.byType(UtenDropdownField))
                .value,
            selected,
          );
          expect(find.text(label), findsOneWidget);
          expect(hostBuilds, initialBuilds);
        }
        expect(
          names.expensePurposeReads,
          type == FinanceDocType.expense ? isNotEmpty : isEmpty,
        );
        expect(
          names.expensePurposeReads,
          everyElement(AccountingExpensePurpose.ordinaryExpense),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'inline creation keeps one write and immediately selects authoritative UUID before refresh',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final capture = GlobalKey();
      if (captureScreens) await loadAuditScreenshotFonts(tester);
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final repository = _CreateRepository();
      final names = FinanceNameService(ApiClient(Dio()), repository);
      final row = FinanceGridRow(mode: ItemMode.allocate);
      addTearDown(names.dispose);
      addTearDown(row.dispose);
      await names.loadStyleCategory('EXPENSE');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...nativeDetailReaderOverrides(),
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'fixture'),
            ),
            sharedPreferencesProvider.overrideWithValue(preferences),
            formDraftStorageProvider.overrideWithValue(
              MemoryFormDraftStorage(),
            ),
            currentPermissionsProvider.overrideWithValue({
              Perm.paymentStyleCreate,
              Perm.paymentStyleView,
            }),
            paymentStyleRepositoryProvider.overrideWithValue(repository),
          ],
          child: MaterialApp(
            theme: auditScreenshotTheme(buildLightTheme()),
            builder: (_, child) => RepaintBoundary(key: capture, child: child!),
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 240,
                  child: Builder(
                    builder: (context) =>
                        financeGridColumns(
                              ItemMode.allocate,
                              context: context,
                              names: names,
                              type: FinanceDocType.expense,
                            )
                            .singleWhere((column) => column.key == 'style')
                            .cellBuilder(context, row),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(UtenDropdownField));
      await tester.pumpAndSettle();
      if (captureScreens) {
        await saveAuditScreenshot(tester, capture, 'finance-style-picker-menu');
      }
      await tester.tap(find.text('添加费用项目'));
      await tester.pumpAndSettle();
      final name = find.byWidgetPredicate(
        (widget) => widget is TextField && widget.maxLength == 120,
      );
      expect(name, findsOneWidget);
      await tester.enterText(name, '会务费用');
      if (captureScreens) {
        await tester.pumpAndSettle();
        await saveAuditScreenshot(
          tester,
          capture,
          'finance-style-create-dialog',
        );
      }
      await tester.tap(find.text('创建'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      for (var frame = 0; frame < 100 && repository.creates == 0; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1)),
        );
      }
      expect(repository.creates, 1);
      expect(repository.submitted?.category, 'EXPENSE');
      expect(repository.submitted?.name, '会务费用');
      expect(repository.submitted?.status, '使用');
      repository.pending.complete(
        const PaymentStyleDetail(
          id: 'authoritative-created-uuid',
          code: 'E005',
          name: '会务费用',
          category: 'EXPENSE',
          status: '使用',
          level: 0,
          path: '/E005/',
          childCount: 0,
        ),
      );
      await tester.pumpAndSettle();
      expect(row.styleId, 'authoritative-created-uuid');
      expect(find.text('会务费用'), findsOneWidget);
      expect(find.byType(UtenBusyOverlayCard), findsNothing);
      expect(repository.refresh.isCompleted, isFalse);
      if (captureScreens) {
        await saveAuditScreenshot(
          tester,
          capture,
          'finance-style-created-selected',
        );
      }
      expect(repository.creates, 1);
      repository.refresh.complete(const []);
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  for (final canCreate in [false, true]) {
    testWidgets('project add action follows create permission=$canCreate', (
      tester,
    ) async {
      final names = _Names();
      final row = FinanceGridRow(mode: ItemMode.allocate);
      addTearDown(names.dispose);
      addTearDown(row.dispose);
      await tester.pumpWidget(
        _app(
          (context) =>
              financeGridColumns(
                    ItemMode.allocate,
                    context: context,
                    names: names,
                    type: FinanceDocType.expense,
                  )
                  .singleWhere((column) => column.key == 'style')
                  .cellBuilder(context, row),
          permissions: {
            if (canCreate) ...{Perm.paymentStyleCreate, Perm.paymentStyleView},
          },
        ),
      );
      await tester.tap(find.byType(UtenDropdownField));
      await tester.pumpAndSettle();
      expect(find.text('添加费用项目'), canCreate ? findsOneWidget : findsNothing);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(row.styleId, isNull);
      expect(tester.takeException(), isNull);
    });
  }
}
