import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/features/basic_data/pages/party_detail_page.dart';
import 'package:uten_imp/features/basic_data/repositories/supplier_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_read_only_fields.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/repositories/subcontract_loss_summary_loader.dart';

final _grants = StateProvider<Set<String>>(
  (_) => {Perm.supplierView, Perm.subcontractOrderView},
);

class _Wire {
  int summaries = 0;
  bool failSummary = false;
  late final api = () {
    final dio = Dio(BaseOptions(baseUrl: 'https://supplier.invalid/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          Object body;
          if (request.path == subcontractSupplierLossSummaryPath) {
            summaries++;
            expect(request.queryParameters['supplierId'], 'supplier-1');
            if (failSummary) {
              handler.reject(
                DioException(
                  requestOptions: request,
                  type: DioExceptionType.badResponse,
                  response: Response<dynamic>(
                    requestOptions: request,
                    statusCode: 503,
                  ),
                ),
              );
              return;
            }
            // An empty summary still provides the supplier-scoped cases entry.
            body = {'supplierId': 'supplier-1', 'settledLineCount': 0};
          } else if (request.path == '/master/suppliers/supplier-1') {
            body = {
              'id': 'supplier-1',
              'code': 'GY0001',
              'name': '测试委外商',
              'description': '测试供应商全称',
              'status': '使用',
              'categoryId': 'supplier-category',
              'categoryName': '委外商',
              'defaultSettlementMethodName': '月结30天',
              'defaultCurrencyName': '人民币',
            };
          } else {
            body = <Map<String, dynamic>>[];
          }
          handler.resolve(
            Response<dynamic>(
              requestOptions: request,
              data: body,
              statusCode: 200,
            ),
          );
        },
      ),
    );
    return ApiClient(dio);
  }();
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

Future<({ProviderContainer container, GoRouter router})> _pump(
  WidgetTester tester,
  _Wire wire, {
  bool allowed = true,
  bool admin = false,
  double width = 1280,
  double scale = 1,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    initialLocation: RoutePath.basicinfoSupplierDetail('supplier-1'),
    routes: [
      GoRoute(
        path: RouteName.basicinfoSupplierDetail,
        builder: (_, state) => PartyDetailPage(
          partyType: 'supplier',
          id: state.pathParameters['id']!,
        ),
      ),
      GoRoute(
        path: RouteName.subcontractShortDeliveries,
        builder: (_, state) => Scaffold(
          body: Text(
            '供应商短交:${state.uri.queryParameters['supplierId']}:'
            '${state.uri.queryParameters['returnTo']}',
          ),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWith(_Session.new),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'supplier-test'),
        ),
        apiClientProvider.overrideWithValue(wire.api),
        supplierRepositoryProvider.overrideWithValue(
          DioSupplierRepository(wire.api),
        ),
        _grants.overrideWith(
          (_) => {Perm.supplierView, if (allowed) Perm.subcontractOrderView},
        ),
        currentPermissionsProvider.overrideWith((ref) => ref.watch(_grants)),
        isSuperAdminProvider.overrideWithValue(admin),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        theme: buildDarkTheme(),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (
    container: ProviderScope.containerOf(
      tester.element(find.byType(PartyDetailPage)),
    ),
    router: router,
  );
}

Finder get _entry => find.byKey(const Key('supplier-subcontract-loss-open'));

Future<void> _revealEntry(WidgetTester tester) async {
  final scrollable = find
      .descendant(
        of: find.byType(RefreshIndicator).first,
        matching: find.byType(Scrollable),
      )
      .first;
  await tester.scrollUntilVisible(_entry, 450, scrollable: scrollable);
  await tester.pumpAndSettle();
}

void main() {
  for (final size in [(1280.0, 1.0), (390.0, 1.5)]) {
    testWidgets(
      'supplier loss entry preserves shared cards and exact scoped route ${size.$1}/${size.$2}',
      (tester) async {
        final wire = _Wire();
        await _pump(tester, wire, width: size.$1, scale: size.$2);
        expect(wire.summaries, 1);
        expect(find.byType(MasterReadOnlyFields), findsOneWidget);
        final identity = tester.getRect(
          find.byKey(const Key('party-identity-card')),
        );
        final overview = tester.getRect(
          find.byKey(const Key('party-overview-card')),
        );
        expect(overview.left, closeTo(identity.left, 0.1));
        expect(overview.right, closeTo(identity.right, 0.1));
        await _revealEntry(tester);
        expect(_entry.hitTestable(), findsOneWidget);
        await tester.tap(_entry);
        await tester.pumpAndSettle();
        expect(
          find.text('供应商短交:supplier-1:/basicinfo/supplier/supplier-1'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'supplier view without subcontract read permission neither reads summary nor offers entry',
    (tester) async {
      final wire = _Wire();
      await _pump(tester, wire, allowed: false);
      expect(wire.summaries, 0);
      expect(_entry, findsNothing);
      expect(find.byKey(const Key('party-overview-card')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'summary read failure keeps the supplier master usable and has no orphan entry',
    (tester) async {
      final wire = _Wire()..failSummary = true;
      await _pump(tester, wire);
      expect(wire.summaries, 1);
      expect(_entry, findsNothing);
      expect(find.byKey(const Key('party-overview-card')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'revoking subcontract read removes the entry and rejects its captured callback',
    (tester) async {
      final app = await _pump(tester, _Wire());
      await _revealEntry(tester);
      final callback = tester.widget<TextButton>(_entry).onPressed!;
      app.container.read(_grants.notifier).state = {Perm.supplierView};
      await tester.pumpAndSettle();
      expect(_entry, findsNothing);
      callback();
      await tester.pumpAndSettle();
      expect(find.byType(PartyDetailPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'super admin retains the original loss entry without an explicit permission row',
    (tester) async {
      final wire = _Wire();
      await _pump(tester, wire, allowed: false, admin: true);
      expect(wire.summaries, 1);
      await _revealEntry(tester);
      expect(_entry.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
