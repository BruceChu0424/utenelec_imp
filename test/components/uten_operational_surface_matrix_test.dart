import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_app_bar_action_button.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/components/layout/uten_segment_row.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_control_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_detail_tab_bar.dart';
import 'package:uten_imp/features/warehouse/widgets/outbound_weight_columns.dart';
import 'package:uten_imp/shared/auth/page_permission_action.dart';
import 'package:uten_imp/shared/auth/page_permission_scope.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/formatters/quantity_display.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

final _delegation = StateProvider<bool>((_) => true);
const _permissionScope = PagePermissionScope(
  surfaceKey: 'production.material-analysis',
  title: '物料分析准备',
);

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot(
    delegableSurfaceKeys: ref.watch(_delegation)
        ? {_permissionScope.surfaceKey}
        : {},
  );
}

class _NoNetwork extends ApiClient {
  _NoNetwork() : super(Dio());
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => {};
}

enum _Phase { short, loading, empty, error, long }

class _Line {
  const _Line(this.index, this.quantity);
  final int index;
  final String? quantity;
  String get name => '物料行-$index';
}

class _Surface extends StatefulWidget {
  const _Surface();
  @override
  State<_Surface> createState() => _SurfaceState();
}

class _SurfaceState extends State<_Surface> {
  var phase = _Phase.short;
  var calls = 0;
  void show(_Phase value) => setState(() => phase = value);
  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 6,
    initialIndex: 4,
    child: Builder(
      builder: (context) => Scaffold(
        appBar: UtenAppBar(
          title: '物料分析与仓库财务核对',
          showBackButton: true,
          showPagePermissionAction: false,
          actions: [
            UtenAppBarActionButton(
              label: '生成单据',
              key: const Key('matrix-command'),
              onPressed: phase == _Phase.loading ? null : () => calls++,
            ),
            UtenAppBarActionButton(label: '物料分析记录', onPressed: () {}),
            UtenAppBarActionButton(label: '生产计划历史', onPressed: () {}),
            UtenAppBarActionButton(label: '刷新', onPressed: () {}),
            const PagePermissionAction(scope: _permissionScope),
          ],
          bottom: buildUtenDetailTabBar(
            context,
            tabs: const [
              Tab(text: '基本信息'),
              Tab(text: '组装信息'),
              Tab(text: '成本预算'),
              Tab(text: '图片和文件'),
              Tab(text: '库存与出入库'),
              Tab(text: '报价记录'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            for (var index = 0; index < 6; index++)
              index == 4 ? _table() : Center(child: Text('分类内容-$index')),
          ],
        ),
      ),
    ),
  );
  Widget _table() {
    final rows = phase == _Phase.short || phase == _Phase.long
        ? List.generate(
            phase == _Phase.long ? 60 : 3,
            (i) => _Line(i, switch (i % 3) {
              0 => '0',
              1 => null,
              _ => '99999999999999.9999',
            }),
          )
        : <_Line>[];
    return Padding(
      padding: const EdgeInsets.all(12),
      child: MasterDataTableView<_Line>(
        tableKey: 'ui-audit.operational-state-matrix',
        columns: [
          MasterColumnDef(
            key: 'status',
            label: '进度 / 待办',
            width: 220,
            value: (line) => switch (line.index % 3) {
              0 => '等待计划下单',
              1 => '可领 4000 个',
              _ => '已完成',
            },
          ),
          MasterColumnDef(
            key: 'goods',
            label: '货品名称',
            width: 220,
            value: (line) => line.name,
          ),
          MasterColumnDef(
            key: 'qty',
            label: '数量',
            width: 190,
            value: (line) => formatExactQtyWithUnit(line.quantity, '个'),
          ),
        ],
        items: rows,
        facets: const {},
        nullCounts: const {},
        filters: const {},
        onFilterChanged: (_, _) {},
        isLoading: phase == _Phase.loading,
        error: phase == _Phase.error ? '矩阵读取失败' : null,
        onRetry: () => show(_Phase.short),
        emptyMessage: '矩阵没有待办',
        summaryBar: rows.isEmpty
            ? null
            : OutboundWeightSummaryBar(
                key: const Key('matrix-summary'),
                entries: const [],
                productsOf: () => [
                  for (final row in rows)
                    OutboundProductQuantity(
                      goodsId: 'g${row.index}',
                      quantity: row.quantity,
                      unitId: 'piece',
                      unitName: '个',
                    ),
                ],
              ),
      ),
    );
  }
}

Future<void> _mount(
  WidgetTester tester,
  double width,
  double scale,
  Brightness brightness,
) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        apiClientProvider.overrideWithValue(_NoNetwork()),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'ui-audit'),
        ),
        currentPermissionsProvider.overrideWithValue(const {}),
        isSuperAdminProvider.overrideWithValue(false),
        sessionSnapshotProvider.overrideWith(_Snapshot.new),
      ],
      child: MaterialApp(
        theme:
            (brightness == Brightness.dark
                    ? buildDarkTheme()
                    : buildLightTheme())
                .copyWith(platform: TargetPlatform.windows),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: UtenControlTheme(child: child!),
        ),
        home: const _Surface(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final width in [375.0, 390.0, 600.0, 900.0]) {
    for (final scale in [1.5, 2.0]) {
      for (final brightness in Brightness.values) {
        testWidgets(
          '$width $scale $brightness header categories and short-table totals remain operable',
          (tester) async {
            await _mount(tester, width, scale, brightness);
            expect(tester.takeException(), isNull);
            expect(find.text('更多操作'), findsOneWidget);
            final actionBounds = tester.getRect(
              find.byKey(const Key('uten-app-bar-more-actions')),
            );
            final categoryBounds = tester.getRect(
              find.byType(UtenSegmentRow<int>),
            );
            expect(
              actionBounds.bottom,
              lessThanOrEqualTo(categoryBounds.top + 0.1),
              reason: 'header actions must not overlap the detail categories',
            );
            expect(
              categoryBounds.bottom,
              lessThanOrEqualTo(
                tester.getRect(find.byType(AppBar)).bottom + 0.1,
              ),
              reason:
                  'preferred category height must contain its painted outline',
            );
            await tester.tap(find.text('更多操作'));
            await tester.pumpAndSettle();
            expect(find.text('权限设置'), findsOneWidget);
            final container = ProviderScope.containerOf(
              tester.element(find.byType(_Surface)),
            );
            container.read(_delegation.notifier).state = false;
            await tester.pumpAndSettle();
            expect(find.text('权限设置'), findsNothing);
            await tester.tap(find.byTooltip('关闭操作面板'));
            await tester.pumpAndSettle();
            expect(find.byKey(const Key('matrix-summary')), findsOneWidget);
            final gap =
                tester.getTopLeft(find.byKey(const Key('matrix-summary'))).dy -
                tester.getBottomLeft(find.text('物料行-2')).dy;
            expect(gap, inInclusiveRange(0, 80));
            final arrow = find.byIcon(Icons.keyboard_arrow_down_rounded);
            if (arrow.evaluate().isNotEmpty) {
              await tester.tap(arrow.first);
              await tester.pumpAndSettle();
            }
            await tester.tap(find.text('报价记录').last);
            await tester.pumpAndSettle();
            expect(find.text('分类内容-5'), findsOneWidget);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  for (final width in [375.0, 390.0, 600.0, 900.0]) {
    testWidgets(
      '$width large-text table loading empty error long-list and fullscreen keep one usable surface',
      (tester) async {
        await _mount(tester, width, 2, Brightness.dark);
        final state = tester.state<_SurfaceState>(find.byType(_Surface));
        for (final phase in [
          _Phase.empty,
          _Phase.loading,
          _Phase.error,
          _Phase.short,
        ]) {
          state.show(phase);
          await tester.pump(const Duration(milliseconds: 200));
          if (phase != _Phase.loading) await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('master-table-fullscreen-toggle')),
            findsOneWidget,
          );
          if (phase == _Phase.empty) {
            expect(find.text('矩阵没有待办'), findsOneWidget);
          }
          if (phase == _Phase.loading) {
            expect(find.byType(CircularProgressIndicator), findsWidgets);
          }
          if (phase == _Phase.error) {
            expect(find.text('矩阵读取失败'), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
        }
        await tester.tap(find.text('全屏'));
        await tester.pumpAndSettle();
        expect(find.text('退出全屏'), findsOneWidget);
        for (final phase in [
          _Phase.empty,
          _Phase.loading,
          _Phase.error,
          _Phase.short,
        ]) {
          state.show(phase);
          await tester.pump(const Duration(milliseconds: 200));
          if (phase != _Phase.loading) await tester.pumpAndSettle();
          expect(find.text('退出全屏'), findsOneWidget);
          if (phase == _Phase.short) {
            expect(find.text('0 个'), findsOneWidget);
            expect(find.text('数量未留存 个'), findsOneWidget);
            expect(find.text('99999999999999.9999 个'), findsOneWidget);
          } else {
            expect(find.text('物料行-0'), findsNothing);
          }
          expect(tester.takeException(), isNull);
        }
        state.show(_Phase.long);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('matrix-summary')), findsNothing);
        for (
          var i = 0;
          i < 16 && find.text('数量未留存 个').hitTestable().evaluate().isEmpty;
          i++
        ) {
          await tester.drag(
            find.text('等待计划下单').hitTestable().first,
            const Offset(0, -480),
          );
          await tester.pumpAndSettle();
        }
        expect(find.text('物料行-59'), findsOneWidget);
        expect(find.byKey(const Key('matrix-summary')), findsOneWidget);
        expect(find.text('数量未留存 个').hitTestable(), findsOneWidget);
        final totalBounds = tester.getRect(find.text('数量未留存 个'));
        expect(totalBounds.left, greaterThanOrEqualTo(0));
        expect(totalBounds.right, lessThanOrEqualTo(width));
        await tester.tap(find.text('退出全屏'));
        await tester.pumpAndSettle();
        expect(find.text('全屏'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
