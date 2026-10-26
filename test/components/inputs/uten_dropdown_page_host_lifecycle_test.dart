import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_geometry.dart';
import 'package:uten_imp/components/layout/uten_content_scrollbar.dart';
import 'package:uten_imp/components/layout/uten_page_scrollbar_host.dart';
import 'package:uten_imp/components/layout/uten_table_column_kit.dart';
import 'package:uten_imp/components/layout/uten_vertical_scroll_area.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/uten_scroll_behavior.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

const _fieldKey = ValueKey('page-settlement-method');
const _chooserKey = ValueKey('page-column-chooser-button');
const _menuKey = ValueKey('uten-column-chooser');

class _InMemoryGeometry extends DropdownGeometryPrefsNotifier {
  @override
  Map<String, UtenDropdownMenuGeometry> build() => const {};
}

class _FormPage extends StatefulWidget {
  const _FormPage({super.key, required this.automatic});

  final bool automatic;

  @override
  State<_FormPage> createState() => _FormPageState();
}

class _FormPageState extends State<_FormPage> {
  final main = ScrollController();
  final secondary = ScrollController();
  bool preferSecondary = false;
  String? settlement;
  final hidden = <String>{};
  int revisions = 0;

  void refreshForm({bool switchSource = false}) => setState(() {
    revisions++;
    preferSecondary = switchSource;
  });

  @override
  void dispose() {
    main.dispose();
    secondary.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final list = ListView(
      controller: main,
      children: [
        Text('新建销售订单 · $revisions'),
        const SizedBox(height: 72),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: UtenDropdownField(
                key: _fieldKey,
                label: '结账方式',
                value: settlement,
                items: [
                  for (var i = 0; i < 6; i++)
                    UtenDropdownItem(value: '$i', label: '结账方式 $i'),
                ],
                searchable: true,
                onChanged: (value) => setState(() => settlement = value),
              ),
            ),
            const SizedBox(width: 24),
            UtenColumnChooserButton(
              key: _chooserKey,
              entries: const [
                UtenColumnChooserEntry(key: 'name', label: '货品名称'),
                UtenColumnChooserEntry(key: 'customer', label: '客户货品名称'),
                UtenColumnChooserEntry(key: 'quantity', label: '数量'),
              ],
              hiddenKeys: hidden,
              onToggle: (key) => setState(() {
                if (!hidden.add(key)) hidden.remove(key);
              }),
              onToggleAll: (visible) => setState(() {
                hidden.clear();
                if (!visible) hidden.addAll(['customer', 'quantity']);
              }),
            ),
          ],
        ),
        const SizedBox(height: 2200),
      ],
    );
    return UtenPageScrollbarHost(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Expanded(
              child: widget.automatic
                  ? list
                  : UtenVerticalScrollArea(
                      controller: main,
                      pageScrollbar: true,
                      child: list,
                    ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 120,
              child: UtenVerticalScrollArea(
                controller: secondary,
                pageScrollbar: preferSecondary,
                pageScrollbarPriority: UtenPageScrollbarPriority.table,
                child: ListView(
                  controller: secondary,
                  children: const [SizedBox(height: 1000)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<GlobalKey<_FormPageState>> _pumpPage(
  WidgetTester tester, {
  required Size size,
  required bool automatic,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final page = GlobalKey<_FormPageState>();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        dropdownGeometryPrefsProvider.overrideWith(_InMemoryGeometry.new),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'page-menu-fixture', epoch: 1),
        ),
        apiBaseUrlProvider.overrideWithValue('http://example.invalid/api'),
      ],
      child: MaterialApp(
        scrollBehavior: const UtenScrollBehavior(),
        theme: ThemeData(platform: TargetPlatform.windows),
        home: Scaffold(
          body: _FormPage(key: page, automatic: automatic),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(find.byKey(UtenPageScrollbarHost.railKey), findsOneWidget);
  expect(
    tester
        .widget<UtenContentScrollbar>(find.byKey(UtenPageScrollbarHost.railKey))
        .controller
        .position,
    same(page.currentState!.main.position),
  );
  return page;
}

void main() {
  for (final size in [const Size(1366, 650), const Size(1920, 950)]) {
    for (final automatic in [false, true]) {
      final mode = automatic ? 'automatic viewport' : 'explicit page viewport';
      testWidgets(
        '$mode $size keeps searchable dropdown open through 700ms and host source changes',
        (tester) async {
          final page = await _pumpPage(
            tester,
            size: size,
            automatic: automatic,
          );
          final fieldState = tester.state(find.byKey(_fieldKey));
          final position = page.currentState!.main.position;
          final option = find.byKey(
            const ValueKey<(String, Key?, String?)>((
              'uten-dropdown-option',
              _fieldKey,
              '3',
            )),
          );
          await tester.tap(find.byKey(_fieldKey));
          await tester.pump();
          expect(option, findsOneWidget);
          expect(find.byType(EditableText), findsOneWidget);
          await tester.pump(const Duration(milliseconds: 250));
          page.currentState!.refreshForm(switchSource: true);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 450));
          expect(option, findsOneWidget);
          expect(tester.state(find.byKey(_fieldKey)), same(fieldState));
          expect(page.currentState!.main.position, same(position));
          expect(
            tester
                .widget<UtenContentScrollbar>(
                  find.byKey(UtenPageScrollbarHost.railKey),
                )
                .controller,
            same(page.currentState!.secondary),
          );
          await tester.tap(option);
          await tester.pumpAndSettle();
          expect(page.currentState!.settlement, '3');
          expect(option, findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
      testWidgets(
        '$mode $size keeps column chooser open through 700ms and can toggle columns',
        (tester) async {
          final page = await _pumpPage(
            tester,
            size: size,
            automatic: automatic,
          );
          await tester.tap(find.byKey(_chooserKey));
          await tester.pump();
          expect(find.byKey(_menuKey), findsOneWidget);
          await tester.pump(const Duration(milliseconds: 250));
          page.currentState!.refreshForm(switchSource: true);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 450));
          expect(find.byKey(_menuKey), findsOneWidget);
          await tester.tap(find.text('客户货品名称'));
          await tester.pumpAndSettle();
          expect(page.currentState!.hidden, contains('customer'));
          expect(find.byKey(_menuKey), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        },
      );
    }
  }
}
