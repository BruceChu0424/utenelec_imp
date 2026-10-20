import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_content_container.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_master_picker.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../support/audit_screenshot_support.dart';

typedef _Client = ({
  String id,
  String name,
  String code,
  String linkman,
  String phone,
});

const _clients = <_Client>[
  (id: '1', name: '迈硕智能', code: 'GD0002', linkman: '李先生', phone: '13800000001'),
  (
    id: '2',
    name: '工程客户（轨道）',
    code: 'GD0003',
    linkman: '林女士',
    phone: '13800000002',
  ),
  (
    id: '3',
    name: '志邦家居',
    code: 'KH00212',
    linkman: '王先生',
    phone: '13800000003',
  ),
  (
    id: '4',
    name: '越南（1号）',
    code: 'WM001',
    linkman: '刘汉栋',
    phone: '13800000004',
  ),
  (
    id: '5',
    name: '孟加拉 TOTAL TECHNOLOGY',
    code: 'WM018',
    linkman: 'SAYEED',
    phone: '13800000005',
  ),
  (
    id: '6',
    name: 'Leviton',
    code: 'WM030',
    linkman: 'Alex',
    phone: '13800000006',
  ),
];

List<MasterColumnDef<_Client>> get _columns => [
  MasterColumnDef(
    key: 'name',
    label: '客户名称',
    width: 230,
    value: (row) => row.name,
    columnSearchEnabled: false,
  ),
  MasterColumnDef(
    key: 'code',
    label: '编号',
    width: 130,
    value: (row) => row.code,
    columnSearchEnabled: false,
  ),
  MasterColumnDef(
    key: 'linkman',
    label: '联系人',
    width: 140,
    value: (row) => row.linkman,
    columnSearchEnabled: false,
  ),
  MasterColumnDef(
    key: 'phone',
    label: '联系电话',
    width: 180,
    value: (row) => row.phone,
    columnSearchEnabled: false,
  ),
];

PagedResult<_Client> _page() => const PagedResult(
  items: _clients,
  page: 1,
  size: 20,
  total: 6,
  totalPages: 1,
);

Future<void> _open(BuildContext context) => showUtenMasterPicker<_Client>(
  context,
  UtenMasterPickerSpec(
    title: '选择客户',
    noun: '客户',
    loadTree: () async => [
      for (final (index, name) in [
        '外贸（钟）',
        '外贸（苏）',
        '外贸（刘）',
        '北区（芳）',
        '南区（芳）',
        'OEM（苏）',
        '零售',
      ].indexed)
        ProductCategoryNode(
          id: 'category-$index',
          code: '$index',
          name: name,
          level: 0,
          children: const [],
        ),
    ],
    loadCategoryPage: (_, _, _) async => _page(),
    search: (_, _) async => _page(),
    idOf: (row) => row.id,
    categoryIdOf: (_) => 'category-0',
    labelOf: (row) => row.name,
    tableColumns: _columns,
  ),
);

Widget _table() => MasterDataTableView<_Client>(
  embedded: true,
  showColumnChooser: false,
  showFullscreenToggle: false,
  columns: _columns,
  items: _clients,
  facets: const {},
  nullCounts: const {},
  filters: const {},
  onFilterChanged: (_, _) {},
);

class _ReviewPage extends StatelessWidget {
  const _ReviewPage();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: UtenContentContainer(
      selectable: false,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '共享界面视觉复核 · 演示数据',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                FilledButton(
                  onPressed: () => _open(context),
                  child: const Text('选择客户'),
                ),
              ],
            ),
            const SizedBox(height: 24),
            const Text('工作台正文边缘', key: Key('dashboard-edge')),
            const SizedBox(height: 8),
            _table(),
            const SizedBox(height: 32),
            UtenContentContainer(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('业务页面正文边缘', key: Key('business-edge')),
                  const SizedBox(height: 8),
                  _table(),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  for (final dark in [false, true]) {
    testWidgets(
      'surface visual review ${dark ? 'dark' : 'light'}',
      (tester) async {
        tester.view.physicalSize = const Size(1680, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        await loadAuditScreenshotFonts(tester);
        final capture = GlobalKey();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
            child: RepaintBoundary(
              key: capture,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                locale: const Locale('zh'),
                supportedLocales: AppLocalizations.supportedLocales,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                theme: auditScreenshotTheme(
                  dark ? buildDarkTheme() : buildLightTheme(),
                ),
                home: const _ReviewPage(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.getTopLeft(find.byKey(const Key('dashboard-edge'))).dx,
          32,
        );
        expect(
          tester.getTopLeft(find.byKey(const Key('business-edge'))).dx,
          32,
        );
        expect(tester.takeException(), isNull);
        await saveAuditScreenshot(
          tester,
          capture,
          'platform-gutter-${dark ? 'dark' : 'light'}',
        );
        await tester.tap(find.text('选择客户'));
        await tester.pumpAndSettle();
        expect(find.text('外贸（钟）'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await saveAuditScreenshot(
          tester,
          capture,
          'platform-picker-${dark ? 'dark' : 'light'}',
        );
      },
      skip: !const bool.fromEnvironment('UTEN_CAPTURE_UI'),
    );
  }
}
