import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/business_window_host.dart';
import 'package:uten_imp/components/feedback/uten_floating_window.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/bom_component_picker.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/uten_colors.dart';
import 'package:uten_imp/components/data_display/uten_table_surface.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/models/goods_detail_sequence.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/providers/color_unit_dict.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_bom_comparison_workspace.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/windows/business_windows.dart';
import '../../../support/audit_screenshot_support.dart';
import '../../../support/bom_comparison_fixture.dart';

const _capture = bool.fromEnvironment('UTEN_CAPTURE_UI');
const _permissions = {
  Perm.goodsView,
  Perm.goodsBomCreate,
  Perm.goodsBomEdit,
  Perm.goodsBomDelete,
};

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'comparison-review',
      code: 'TEST',
      name: 'BOM核对员',
      permissions: [
        Perm.goodsView,
        Perm.goodsBomCreate,
        Perm.goodsBomEdit,
        Perm.goodsBomDelete,
      ],
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
    code: switch (id) {
      'a' => '280149001',
      'b' => '280149002',
      _ => '280149003',
    },
    name: id == 'a'
        ? '单联双控开关带二三极插座'
        : id == 'b'
        ? '双联双控开关带二三极插座'
        : 'Q7 二开铁架（喷粉）',
    status: '使用',
    writable: true,
  );
}

GoodsBomItem _item(
  String id,
  String component,
  String name, {
  double qty = 1,
  String? summary,
}) => GoodsBomItem(
  id: id,
  componentGoodsId: component,
  componentCode: switch (component) {
    'same' => 'UT3015',
    'changed' => 'Q70045',
    'box' => 'V63301',
    _ => 'UT3018',
  },
  componentName: name,
  qty: qty,
  componentUnitName: '个',
  componentColorName: switch (component) {
    'changed' => '梦幻金',
    'box' => '白色',
    _ => '透明',
  },
  componentSpec: switch (component) {
    'same' => '45mm×100m',
    'changed' => '一开五孔',
    'box' => '195×186×98mm',
    'bag' => '120×150mm',
    _ => '标准件',
  },
  summary: summary,
);

Future<
  ({
    ProviderContainer container,
    ComparisonFixtureBom bom,
    ComparisonFixtureApi api,
    GlobalKey captureKey,
  })
>
_mount(
  WidgetTester tester, {
  double width = 1600,
  double height = 960,
  bool dark = false,
  double scale = 1,
  Set<String> permissions = _permissions,
  GoodsListItem? replacement,
}) async {
  await tester.binding.setSurfaceSize(Size(width, height));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  if (_capture) await loadAuditScreenshotFonts(tester);
  final bom = ComparisonFixtureBom({
    'a': [
      _item('a1', 'same', '优腾封箱胶'),
      _item('a2', 'changed', 'Q7 一开五孔按键（喷油）', summary: '喷油'),
      _item('a3', 'box', 'V6 中盒', qty: .1),
    ],
    'b': [
      _item('b1', 'same', '优腾封箱胶'),
      _item('b2', 'changed', 'Q7 一开五孔按键（喷油）', qty: 2, summary: '新版喷油'),
      _item('b3', 'bag', '包装袋（优腾通用）'),
    ],
    'c': [_item('c1', 'same', '优腾封箱胶', qty: 3)],
  });
  final api = ComparisonFixtureApi(bom);
  final container = ProviderContainer(
    overrides: [
      sessionProvider.overrideWith(_Session.new),
      sessionSnapshotProvider.overrideWith(_Snapshot.new),
      apiBaseUrlProvider.overrideWithValue('https://comparison.invalid/api'),
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: 'comparison-review'),
      ),
      currentPermissionsProvider.overrideWithValue(permissions),
      isSuperAdminProvider.overrideWithValue(false),
      apiClientProvider.overrideWithValue(api),
      goodsRepositoryProvider.overrideWithValue(_Goods()),
      goodsBomRepositoryProvider.overrideWithValue(bom),
      colorDictProvider.overrideWith((ref) async => const []),
      unitDictProvider.overrideWith((ref) async => const []),
      if (replacement != null)
        bomComponentSinglePickerProvider.overrideWithValue(
          (context, ref) async => replacement,
        ),
    ],
  );
  addTearDown(container.dispose);
  final key = GlobalKey();
  final theme = dark ? buildDarkTheme() : buildLightTheme();
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
            size: Size(width, height),
            textScaler: TextScaler.linear(scale),
          ),
          child: RepaintBoundary(
            key: key,
            child: const Scaffold(
              body: BusinessWindowHost(child: Text('货品资料')),
            ),
          ),
        ),
      ),
    ),
  );
  final windows = container.read(businessWindowsProvider);
  final sequence = GoodsDetailSequence(['a', 'b', 'c']);
  windows.open('/basicinfo/goods/a?tab=bom', '资料对照', extra: sequence);
  windows.open('/basicinfo/goods/b?tab=bom', '资料对照', extra: sequence);
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('并排排列所有窗口').last);
  await tester.pumpAndSettle();
  return (container: container, bom: bom, api: api, captureKey: key);
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byTooltip('点击对比 BOM · 长按或拖动调整左右比例 · 双击均分'));
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
  await tester.tap(find.text('对比左右 BOM'));
  await tester.pumpAndSettle();
  expect(find.byType(GoodsBomComparisonWorkspace), findsOneWidget);
}

Future<Finder> editText(
  WidgetTester tester,
  String side,
  String field,
  String path,
  String value,
) async {
  final activate = find.byKey(
    ValueKey('bom-compare-activate-$side-$field-$path'),
  );
  await tester.ensureVisible(activate);
  await tester.tap(activate);
  await tester.pumpAndSettle();
  final input = find.byKey(ValueKey('bom-compare-input-$side-$field-$path'));
  await tester.enterText(input, value);
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
  return input;
}

void main() {
  testWidgets(
    'an invalid opposite-side input does not block saving this side',
    (tester) async {
      final env = await _mount(tester);
      await _open(tester);
      await editText(tester, 'left', 'qty', 'changed', '4');
      await editText(tester, 'right', 'qty', 'changed', 'abc');
      await tester.tap(find.byKey(const ValueKey('bom-compare-save-a')));
      await tester.pumpAndSettle();
      expect(find.text('确认保存左侧修改'), findsOneWidget);
      await tester.tap(find.byKey(const Key('bom-compare-confirm')));
      await tester.pumpAndSettle();
      expect(env.bom.rows['a']![1].qty, 4);
      expect(env.bom.rows['b']![1].qty, 2);
      expect(find.byKey(const ValueKey('bom-compare-save-b')), findsOneWidget);
      expect(find.textContaining('abc'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('closing comparison owner dismisses its unsaved-input prompt', (
    tester,
  ) async {
    final env = await _mount(tester);
    await _open(tester);
    await editText(tester, 'left', 'qty', 'changed', 'abc');
    await tester.tap(find.text('返回资料窗口'));
    await tester.pumpAndSettle();
    expect(find.text('还有未保存的 BOM 修改'), findsOneWidget);
    env.container.read(businessWindowsProvider).clear();
    await tester.pumpAndSettle();
    expect(find.text('还有未保存的 BOM 修改'), findsNothing);
    expect(env.bom.writes, 0);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'name edits use the existing component picker and clear stale selection',
    (tester) async {
      final env = await _mount(
        tester,
        replacement: const GoodsListItem(
          id: 'new',
          code: 'Q70999',
          name: '新按键',
          status: '使用',
          unitName: '个',
          writable: true,
        ),
      );
      await _open(tester);
      await editText(tester, 'left', 'qty', 'changed', '2');
      final left = find.byKey(const ValueKey('bom-comparison-table-left'));
      await tester.tap(
        find.descendant(of: left, matching: find.byType(Checkbox)).at(1),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(
          const ValueKey('bom-compare-activate-left-componentGoodsId-changed'),
        ),
      );
      await tester.tap(
        find.byKey(
          const ValueKey('bom-compare-activate-left-componentGoodsId-changed'),
        ),
      );
      await tester.pumpAndSettle();
      await editText(tester, 'left', 'qty', 'new', '3');
      expect(
        find.descendant(of: left, matching: find.text('Q70999')),
        findsWidgets,
      );
      expect(find.text('已选 0 项差异'), findsOneWidget);
      expect(find.byKey(const ValueKey('bom-compare-save-a')), findsOneWidget);
      expect(env.bom.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'authorized shared specification edits preview on both sides and save once',
    (tester) async {
      final env = await _mount(
        tester,
        permissions: {..._permissions, Perm.goodsEdit},
      );
      await _open(tester);
      await editText(tester, 'left', 'spec', 'changed', '新规格 2026');
      expect(find.text('规格、型号等属于共用货品属性，保存会同步相同组件'), findsOneWidget);
      final right = find.byKey(const ValueKey('bom-comparison-table-right'));
      expect(
        find.descendant(of: right, matching: find.text('新规格 2026')),
        findsWidgets,
      );
      expect(env.bom.writes, 0);
      await tester.tap(find.byKey(const ValueKey('bom-compare-save-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bom-compare-confirm')));
      await tester.pumpAndSettle();
      expect(env.bom.rows['a']![1].componentSpec, '新规格 2026');
      expect(env.bom.rows['b']![1].componentSpec, '新规格 2026');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'matching draft rows disappear from differences without losing their edits',
    (tester) async {
      final env = await _mount(tester);
      await _open(tester);
      await tester.tap(find.text('只看差异'));
      await tester.pumpAndSettle();
      await editText(tester, 'left', 'qty', 'changed', '2');
      await editText(tester, 'left', 'summary', 'changed', '新版喷油');
      expect(find.text('相同 2'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(GoodsBomComparisonWorkspace),
          matching: find.text('Q7 一开五孔按键（喷油）'),
        ),
        findsNothing,
      );
      expect(env.bom.writes, 0);
      await tester.tap(find.byKey(const ValueKey('bom-compare-save-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bom-compare-confirm')));
      await tester.pumpAndSettle();
      expect(env.bom.rows['a']![1].qty, 2);
      expect(env.bom.rows['a']![1].summary, '新版喷油');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'inline edit recovery reuses the reviewed command without replaying writes',
    (tester) async {
      final env = await _mount(tester);
      await _open(tester);
      await editText(tester, 'left', 'qty', 'changed', '2');
      env.api.loseCommitReply = true;
      await tester.tap(find.byKey(const ValueKey('bom-compare-save-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bom-compare-confirm')));
      await tester.pumpAndSettle();
      final writes = env.bom.writes;
      expect(find.text('核对上次保存结果'), findsOneWidget);
      await tester.tap(find.byKey(const Key('bom-compare-confirm')));
      await tester.pumpAndSettle();
      expect(env.api.commitCalls, 2);
      expect(env.bom.writes, writes);
      expect(env.api.previewCalls, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'auto edit stages locally and rechecks quantity cells before explicit save',
    (tester) async {
      final env = await _mount(tester);
      await _open(tester);
      expect(find.text('编辑模式 · 修改后实时核对'), findsNWidgets(2));
      final field = await editText(tester, 'left', 'qty', 'changed', '2');
      expect(find.byKey(const ValueKey('bom-compare-save-a')), findsOneWidget);
      expect(env.bom.writes, 0);
      expect(env.api.previewCalls, 0);
      expect(env.api.commitCalls, 0);
      final editable = find.descendant(
        of: field,
        matching: find.byType(EditableText),
      );
      final state = tester.state<EditableTextState>(editable);
      await tester.enterText(field, '2.00000');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(tester.state<EditableTextState>(editable), same(state));
      expect(tester.widget<TextField>(field).controller!.text, '2.00000');
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const Key('bom-compare-all-left')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('bom-compare-save-a')));
      await tester.pumpAndSettle();
      expect(env.api.previewCalls, 1);
      expect(env.bom.writes, 0);
      expect(find.text('确认保存左侧修改'), findsOneWidget);
      await tester.tap(find.byKey(const Key('bom-compare-confirm')));
      await tester.pumpAndSettle();
      expect(env.api.commitCalls, 1);
      expect(env.bom.rows['a']![1].qty, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'invalid or filtered input is preserved and switch asks before discarding',
    (tester) async {
      final env = await _mount(tester);
      await _open(tester);
      await editText(tester, 'left', 'qty', 'changed', 'abc');
      expect(env.bom.writes, 0);
      expect(env.api.commitCalls, 0);
      await tester.tap(find.text('只看差异'));
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .descendant(
              of: find.byType(GoodsBomComparisonWorkspace),
              matching: find.byTooltip('下一个 BOM'),
            )
            .last,
      );
      await tester.pumpAndSettle();
      expect(find.text('还有未保存的 BOM 修改'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('bom-compare-input-left-qty-changed')),
            )
            .controller!
            .text,
        'abc',
      );
      await tester.tap(find.text('放弃左侧修改'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('bom-compare-save-a')), findsNothing);
      expect(env.bom.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('saving one side preserves the other sides staged edits', (
    tester,
  ) async {
    final env = await _mount(tester);
    await _open(tester);
    await editText(tester, 'left', 'qty', 'changed', '4');
    await editText(tester, 'right', 'qty', 'changed', '5');
    await tester.tap(find.byKey(const ValueKey('bom-compare-save-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bom-compare-confirm')));
    await tester.pumpAndSettle();
    expect(env.bom.rows['a']![1].qty, 4);
    expect(env.bom.rows['b']![1].qty, 2);
    expect(find.byKey(const ValueKey('bom-compare-save-b')), findsOneWidget);
    expect(find.textContaining('保存右侧修改'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bom-compare-save-b')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bom-compare-confirm')));
    await tester.pumpAndSettle();
    expect(env.bom.rows['b']![1].qty, 5);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'code name color spec quantity lead, and only differing cells are red',
    (tester) async {
      await _mount(tester);
      await _open(tester);
      for (final side in ['left', 'right']) {
        final finder = find.byKey(ValueKey('bom-comparison-table-$side'));
        final table = tester.widget<MasterDataTableView<dynamic>>(finder);
        expect(table.columns.take(5).map((column) => column.key), [
          'code',
          'componentName',
          'color',
          'spec',
          'qty',
        ]);
        expect(table.columns.take(5).map((column) => column.label), [
          '编码',
          '名称',
          '颜色',
          '规格',
          '设计使用数量',
        ]);
        expect(table.requiredLeadingColumnKeys, ['code']);
        expect(table.items, hasLength(4));
        Color? background(String text, {Finder? scope}) {
          final content = find
              .descendant(of: scope ?? finder, matching: find.text(text))
              .first;
          final cell = find
              .ancestor(of: content, matching: find.byType(UtenTableCellFrame))
              .first;
          return tester.widget<UtenTableCellFrame>(cell).backgroundColor;
        }

        final changed = find.byKey(
          ValueKey('bom-compare-$side-changed|component'),
        );
        expect(background('Q70045'), UtenColors.successBg);
        expect(background('Q7 一开五孔按键（喷油）'), UtenColors.successBg);
        expect(background('梦幻金'), UtenColors.successBg);
        expect(background('一开五孔'), UtenColors.successBg);
        expect(
          background(side == 'left' ? '1 个' : '2 个', scope: changed),
          UtenColors.errorBg,
        );
        expect(
          background(side == 'left' ? '喷油' : '新版喷油', scope: changed),
          UtenColors.errorBg,
        );
        final x = ['编码', '名称', '颜色', '规格', '设计使用数量']
            .map(
              (label) => tester
                  .getTopLeft(
                    find
                        .descendant(of: finder, matching: find.text(label))
                        .first,
                  )
                  .dx,
            )
            .toList();
        for (var i = 1; i < x.length; i++) {
          expect(x[i], greaterThan(x[i - 1]));
        }
      }
      expect(find.text('配方字段'), findsNothing);
      expect(find.text('差异详情'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('more than two windows can choose the exact comparison pair', (
    tester,
  ) async {
    final env = await _mount(tester);
    env.container
        .read(businessWindowsProvider)
        .open(
          '/basicinfo/goods/c?tab=bom',
          '资料对照',
          extra: GoodsDetailSequence(['a', 'b', 'c']),
        );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('对比货品 BOM').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('窗口 1 · 资料对照'));
    await tester.pumpAndSettle();
    expect(find.text('左侧 · 280149003'), findsOneWidget);
    expect(find.text('右侧 · 280149001'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'expanded difference reads shared subassembly in the real tree cells',
    (tester) async {
      final env = await _mount(tester);
      env.bom.rows['a']![1] = const GoodsBomItem(
        id: 'a2',
        componentGoodsId: 'changed',
        componentName: 'Q7 功能件',
        qty: 1,
        hasChildren: true,
      );
      env.bom.rows['b']![1] = const GoodsBomItem(
        id: 'b2',
        componentGoodsId: 'changed',
        componentName: 'Q7 功能件',
        qty: 2,
        hasChildren: true,
      );
      env.bom.rows['changed'] = [_item('spring-edge', 'spring', '功能件弹片')];
      await _open(tester);
      final workspace = find.byType(GoodsBomComparisonWorkspace);
      expect(
        find.descendant(of: workspace, matching: find.text('功能件弹片')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey('bom-compare-toggle-left-changed')),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: workspace, matching: find.text('功能件弹片')),
        findsNWidgets(2),
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'shared assembly table, unified window surface and linked scroll/selection',
    (tester) async {
      final env = await _mount(tester);
      final windows = env.container.read(businessWindowsProvider);
      for (final window in windows.windows) {
        final frame = find.byKey(window.windowKey);
        final shell = tester.widget<UtenFloatingWindow>(frame);
        final theme = Theme.of(tester.element(frame));
        expect(shell.backgroundColor, theme.colorScheme.surface);
        expect(theme.scaffoldBackgroundColor, theme.colorScheme.surface);
      }
      for (var i = 0; i < 24; i++) {
        env.bom.rows['a']!.add(_item('a-extra-$i', 'extra-$i', '对比组件 $i'));
        env.bom.rows['b']!.add(
          _item('b-extra-$i', 'extra-$i', '对比组件 $i', qty: 2),
        );
      }
      await _open(tester);
      final left = find.byKey(const ValueKey('bom-comparison-table-left'));
      final right = find.byKey(const ValueKey('bom-comparison-table-right'));
      expect(tester.widget(left), isA<MasterDataTableView<Object?>>());
      expect(tester.widget(right), isA<MasterDataTableView<Object?>>());
      await tester.tap(
        find.descendant(of: left, matching: find.byType(Checkbox)).at(1),
      );
      await tester.pumpAndSettle();
      expect(find.text('已选 1 项差异'), findsOneWidget);
      expect(
        tester
            .widgetList<Checkbox>(
              find.descendant(of: right, matching: find.byType(Checkbox)),
            )
            .where((box) => box.value == true)
            .length,
        1,
      );
      final leftScroll = PrimaryScrollController.of(tester.element(left));
      final rightScroll = PrimaryScrollController.of(tester.element(right));
      final vertical = find.descendant(
        of: left,
        matching: find.byWidgetPredicate(
          (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
        ),
      );
      await tester.drag(vertical.first, const Offset(0, -220));
      await tester.pumpAndSettle();
      expect(leftScroll.offset, greaterThan(0));
      expect(rightScroll.offset, closeTo(leftScroll.offset, 1));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'narrow large text can compare from title bar and scroll both panes',
    (tester) async {
      final env = await _mount(tester, width: 390, height: 844, scale: 1.4);
      await tester.tap(find.byTooltip('对比货品 BOM').last);
      await tester.pumpAndSettle();
      expect(find.byType(GoodsBomComparisonWorkspace), findsOneWidget);
      expect(find.text('相同 1'), findsOneWidget);
      if (_capture) {
        await saveAuditScreenshot(tester, env.captureKey, 'bom-comparison-390');
      }
      expect(tester.takeException(), isNull);
    },
  );
  for (final scenario in [
    (width: 1600.0, dark: false, scale: 1.0),
    (width: 1280.0, dark: true, scale: 1.25),
  ]) {
    testWidgets(
      'real windows resize, compare, preview and replace at ${scenario.width}',
      (tester) async {
        final env = await _mount(
          tester,
          width: scenario.width,
          dark: scenario.dark,
          scale: scenario.scale,
        );
        final windows = env.container.read(businessWindowsProvider);
        final first = windows.windows.first, second = windows.windows.last;
        final before = first.windowKey.currentState!.bounds;
        final handle = find.byTooltip('点击对比 BOM · 长按或拖动调整左右比例 · 双击均分');
        await tester.drag(handle, const Offset(65, 0));
        await tester.pumpAndSettle();
        expect(
          first.windowKey.currentState!.bounds.width,
          greaterThan(before.width),
        );
        expect(
          first.windowKey.currentState!.bounds.overlaps(
            second.windowKey.currentState!.bounds,
          ),
          false,
        );
        expect(first.windowKey.currentState!.bounds.left, 8);
        if (_capture) {
          await saveAuditScreenshot(
            tester,
            env.captureKey,
            'bom-tiled-${scenario.width.toInt()}',
          );
        }
        await _open(tester);
        expect(find.text('相同 1'), findsOneWidget);
        expect(find.text('有差异 1'), findsOneWidget);
        expect(find.text('仅左侧 1'), findsOneWidget);
        expect(find.text('仅右侧 1'), findsOneWidget);
        expect(
          env.api.snapshots,
          containsAll(['a', 'b']),
        ); // authorized comparison automatically opens ordinary edit snapshots
        if (_capture) {
          await saveAuditScreenshot(
            tester,
            env.captureKey,
            'bom-comparison-${scenario.width.toInt()}',
          );
        }
        await tester.tap(find.text('全选差异'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('bom-compare-selected-left')));
        await tester.pumpAndSettle();
        expect(env.api.previewCalls, 1);
        expect(env.api.commitCalls, 0);
        expect(env.bom.writes, 0);
        expect(find.textContaining('删除 1 项'), findsOneWidget);
        if (_capture) {
          await saveAuditScreenshot(
            tester,
            env.captureKey,
            'bom-comparison-preview-${scenario.width.toInt()}',
          );
        }
        await tester.tap(find.byKey(const Key('bom-compare-confirm')));
        await tester.pumpAndSettle();
        expect(env.api.commitCalls, 1);
        expect(
          env.bom.rows['a']!.map((e) => e.componentGoodsId),
          env.bom.rows['b']!.map((e) => e.componentGoodsId),
        );
        expect(find.text('相同 3'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'right navigation invalidates old choices and preserves left window',
    (tester) async {
      final env = await _mount(tester);
      await _open(tester);
      await tester.tap(find.text('全选差异'));
      await tester.pumpAndSettle();
      final workspace = find.byType(GoodsBomComparisonWorkspace);
      await tester.tap(
        find
            .descendant(of: workspace, matching: find.byTooltip('下一个 BOM'))
            .last,
      );
      await tester.pumpAndSettle();
      expect(find.text('已选 0 项差异'), findsOneWidget);
      expect(find.textContaining('右侧 · 280149003'), findsOneWidget);
      expect(find.textContaining('左侧 · 280149001'), findsOneWidget);
      expect(env.api.previewCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('read-only comparison has no mutation or edit-snapshot entry', (
    tester,
  ) async {
    final env = await _mount(tester, permissions: {Perm.goodsView});
    await _open(tester);
    final button = tester.widget<OutlinedButton>(
      find.byKey(const Key('bom-compare-all-left')),
    );
    expect(button.onPressed, isNull);
    expect(env.api.snapshots, isEmpty);
    expect(env.bom.writes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'lost commit response keeps same request and locks navigation until recovery',
    (tester) async {
      final env = await _mount(tester);
      env.api.loseCommitReply = true;
      await _open(tester);
      await tester.tap(find.byKey(const Key('bom-compare-all-left')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bom-compare-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('核对上次保存结果'), findsOneWidget);
      final writes = env.bom.writes;
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '取消替换'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const Key('bom-compare-confirm')));
      await tester.pumpAndSettle();
      expect(env.api.previewCalls, 1);
      expect(env.api.commitCalls, 2);
      expect(env.bom.writes, writes);
      expect(find.text('相同 3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
