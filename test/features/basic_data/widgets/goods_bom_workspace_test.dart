import 'package:uten_imp/components/layout/uten_floating_action_group.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

import '../../../support/uten_test_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/router/business_window_host.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/models/goods_detail_sequence.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/providers/color_unit_dict.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/windows/business_windows.dart';

import '../../../support/audit_screenshot_support.dart';
import '../../../support/goods_bom_edit_test_api.dart';

const _capture = bool.fromEnvironment('UTEN_CAPTURE_UI');
const _permissions = {Perm.goodsView, Perm.goodsBomCreate, Perm.goodsBomEdit};

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'workspace-review',
      code: 'TEST',
      name: '核对员',
      permissions: [Perm.goodsView, Perm.goodsBomCreate, Perm.goodsBomEdit],
    ),
  );
}

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}

class _Goods extends Fake implements GoodsRepository {
  @override
  Future<GoodsDetail> detail(String id) async => GoodsDetail(
    id: id,
    code: id == 'a' ? '80N001R' : '80N002R',
    name: id == 'a' ? '亚美尼80N单联双控开关' : '亚美尼80N双联双控开关',
    status: '使用',
    writable: true,
  );
}

class _Bom extends Fake implements GoodsBomRepository {
  @override
  Future<List<GoodsBomItem>> list(String id) async => const [
    GoodsBomItem(
      id: '1',
      componentGoodsId: 'shell',
      componentCode: '80N-01',
      componentName: '80N开关按钮',
      qty: 1,
    ),
    GoodsBomItem(
      id: '2',
      componentGoodsId: 'support',
      componentCode: '80N-02',
      componentName: '80N开关支架',
      qty: 1,
    ),
    GoodsBomItem(
      id: '3',
      componentGoodsId: 'box',
      componentCode: 'YMN004',
      componentName: '亚美尼80产品中盒',
      qty: 0.1,
    ),
  ];

  @override
  Future<GoodsBomLearningSummary> learning(String id) async =>
      const GoodsBomLearningSummary();
}

void main() {
  for (final scenario in [
    (width: 1600.0, height: 900.0, dark: false, scale: 1.0),
    (width: 1280.0, height: 900.0, dark: true, scale: 1.0),
    (width: 390.0, height: 844.0, dark: false, scale: 1.4),
  ]) {
    testWidgets(
      'real shared router opens BOM comparison at ${scenario.width} dark=${scenario.dark}',
      (tester) async {
        await setUtenTestSurfaceSize(
          tester,
          Size(scenario.width, scenario.height),
        );
        addTearDown(() => setUtenTestSurfaceSize(tester, null));
        SharedPreferences.setMockInitialValues({});
        if (_capture) await loadAuditScreenshotFonts(tester);
        final bom = _Bom();
        final container = ProviderContainer(
          overrides: [
            sessionProvider.overrideWith(_Session.new),
            sessionSnapshotProvider.overrideWith(_Snapshot.new),
            apiBaseUrlProvider.overrideWithValue(
              'https://workspace.invalid/api',
            ),
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'workspace-review'),
            ),
            currentPermissionsProvider.overrideWithValue(_permissions),
            isSuperAdminProvider.overrideWithValue(false),
            apiClientProvider.overrideWithValue(GoodsBomEditTestApi(bom)),
            goodsRepositoryProvider.overrideWithValue(_Goods()),
            goodsBomRepositoryProvider.overrideWithValue(bom),
            colorDictProvider.overrideWith((ref) async => const []),
            unitDictProvider.overrideWith((ref) async => const []),
          ],
        );
        addTearDown(container.dispose);
        final captureKey = GlobalKey();
        final theme = scenario.dark ? buildDarkTheme() : buildLightTheme();
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: _capture ? auditScreenshotTheme(theme) : theme,
              locale: const Locale('zh'),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              home: MediaQuery(
                data: MediaQueryData(
                  size: Size(scenario.width, scenario.height),
                  textScaler: TextScaler.linear(scenario.scale),
                ),
                child: RepaintBoundary(
                  key: captureKey,
                  child: const Scaffold(
                    body: BusinessWindowHost(
                      child: Center(child: Text('物料反查 · 保留来源结果')),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final windows = container.read(businessWindowsProvider);
        final sequence = GoodsDetailSequence(['a', 'b']);
        windows.open(
          '/basicinfo/goods/a?tab=bom',
          '80N001R · BOM',
          extra: sequence,
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('goods-detail-product-code')),
          findsOneWidget,
        );
        expect(find.text('产品编号：80N001R'), findsOneWidget);
        expect(find.text('80N开关按钮'), findsWidgets);
        final nextAction = find.byKey(const Key('goods-next-bom'));
        final nextWasVisible = nextAction.hitTestable().evaluate().isNotEmpty;
        await showUtenTestAction(
          tester,
          nextAction,
          menuLabel: '其他操作',
          menuScope: find.byKey(windows.windows.first.windowKey),
        );
        expect(
          find.ancestor(
            of: find.byKey(const Key('goods-next-bom')),
            matching: find.byType(UtenFloatingActionGroup),
          ),
          findsOneWidget,
        );
        if (!nextWasVisible) {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
        }
        if (scenario.width >= 1000) {
          windows.open(
            '/basicinfo/goods/b?tab=bom',
            '80N002R · BOM',
            extra: sequence,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('并排排列所有窗口').last);
          await tester.pumpAndSettle();
          expect(find.text('产品编号：80N002R'), findsOneWidget);
          expect(find.text('产品编号：80N001R'), findsOneWidget);
          expect(
            windows.windows.first.windowKey.currentState!.bounds.overlaps(
              windows.windows.last.windowKey.currentState!.bounds,
            ),
            isFalse,
          );
        }
        if (_capture) {
          await saveAuditScreenshot(
            tester,
            captureKey,
            'bom-workspace-${scenario.width.toInt()}-${scenario.dark ? 'dark' : 'light'}',
          );
        }
        expect(tester.takeException(), isNull);
        if (scenario.width == 1600) {
          await tester.tap(
            find.descendant(
              of: find.byKey(windows.windows.first.windowKey),
              matching: find.byKey(
                const ValueKey('master-table-fullscreen-toggle'),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('退出全屏'), findsOneWidget);
        }
        final nextBom = scenario.width == 1600
            ? find.byKey(const Key('goods-next-bom')).last
            : find.descendant(
                of: find.byKey(windows.windows.first.windowKey),
                matching: find.byKey(const Key('goods-next-bom')),
              );
        await showUtenTestAction(
          tester,
          nextBom,
          menuLabel: '其他操作',
          menuScope: scenario.width == 1600
              ? null
              : find.byKey(windows.windows.first.windowKey),
        );
        await tester.tap(nextBom);
        await tester.pumpAndSettle();
        expect(find.text('退出全屏'), findsNothing);
        expect(find.text('产品编号：80N001R'), findsNothing);
        expect(
          find.text('产品编号：80N002R'),
          findsNWidgets(windows.windows.length),
        );
        expect(find.text('物料反查 · 保留来源结果'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        container.dispose();
      },
    );
  }
}
