import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/components/layout/uten_app_bar_action_scope.dart';
import 'package:uten_imp/components/layout/uten_history_time_filter.dart';
import 'package:uten_imp/components/print/uten_print_preview.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/drafts/form_drafts_page.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/platform_tables/table_column_projection.dart';

final _value = Provider<int>((ref) => 7);

void _size(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _openActions(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('uten-app-bar-more-actions')));
  await tester.pumpAndSettle();
}

Widget _app(Widget home) => ProviderScope(
  overrides: [
    authenticatedScopeProvider.overrideWithValue(
      const AuthenticatedScope(userId: 'test'),
    ),
    apiBaseUrlProvider.overrideWithValue('https://test.invalid'),
  ],
  child: MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: home,
  ),
);

List<Widget> _withFillers(Widget action) => [
  action,
  IconButton(onPressed: () {}, icon: const Icon(Icons.refresh)),
  TextButton(onPressed: () {}, child: const Text('其他操作')),
];

void main() {
  testWidgets(
    'more preview keeps original route projection and async consumer mounted',
    (tester) async {
      _size(tester);
      final projection = TableColumnProjectionController();
      addTearDown(projection.dispose);
      final owner = Object();
      var published = false;
      var loadedValue = 0;
      await tester.pumpWidget(
        TableColumnProjectionScope(
          controller: projection,
          child: _app(
            Builder(
              builder: (pageContext) {
                if (!published) {
                  published = true;
                  WidgetsBinding.instance.addPostFrameCallback(
                    (_) => projection.publish(
                      owner,
                      const TableColumnProjection(
                        tableKey: 'items',
                        columns: [
                          TableProjectedColumn(
                            key: 'qty',
                            label: '本次数量',
                            width: 80,
                            type: 'text',
                          ),
                          TableProjectedColumn(
                            key: 'name',
                            label: '货品名称',
                            width: 260,
                            type: 'text',
                          ),
                        ],
                      ),
                      contextOwner: ModalRoute.of(pageContext),
                    ),
                  );
                }
                return Scaffold(
                  appBar: UtenAppBar(
                    title: '投影业务页',
                    showPagePermissionAction: false,
                    actions: _withFillers(
                      Consumer(
                        builder: (context, ref, _) => UtenPrintPreviewButton(
                          title: '当前表头',
                          tableKey: 'items',
                          loader: () async {
                            await Future<void>.delayed(Duration.zero);
                            loadedValue = ref.read(_value);
                            return const UtenPrintTable(
                              headers: ['原品名', '隐藏金额', '原数量'],
                              columnKeys: ['name', 'price', 'qty'],
                              rows: [
                                ['货品A', '999.99', '3'],
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _openActions(tester);
      await tester.tap(find.text('预览打印'));
      await tester.pumpAndSettle();
      expect(loadedValue, 7);
      expect(find.text('预览 · 当前表头'), findsOneWidget);
      expect(find.text('本次数量'), findsOneWidget);
      expect(find.text('货品名称'), findsOneWidget);
      expect(find.text('隐藏金额'), findsNothing);
      expect(find.text('999.99'), findsNothing);
      expect(find.text('原品名'), findsNothing);
      expect(find.text('原数量'), findsNothing);
      await tester.tap(find.widgetWithText(UtenButton, '关闭'));
      await tester.pumpAndSettle();
      expect(find.text('预览 · 当前表头'), findsNothing);
      expect(find.byTooltip('关闭操作面板'), findsNothing);
      expect(
        find.byKey(const Key('uten-app-bar-more-actions')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('native icon navigation closes the menu before its new route', (
    tester,
  ) async {
    _size(tester);
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (pageContext) => Scaffold(
            appBar: UtenAppBar(
              title: '图标操作业务页',
              showPagePermissionAction: false,
              actions: _withFillers(
                IconButton(
                  tooltip: '图标打开业务',
                  icon: const Icon(Icons.add),
                  onPressed: () => Navigator.of(pageContext).push<void>(
                    MaterialPageRoute(
                      builder: (_) => const Scaffold(body: Text('下一业务页')),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await _openActions(tester);
    await tester.tap(find.byTooltip('图标打开业务'));
    await tester.pumpAndSettle();
    expect(find.text('下一业务页'), findsOneWidget);
    expect(find.byTooltip('关闭操作面板'), findsNothing);
    Navigator.of(tester.element(find.text('下一业务页'))).pop();
    await tester.pumpAndSettle();
    expect(find.byTooltip('关闭操作面板'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'history range action closes the panel and cancel preserves the filter',
    (tester) async {
      _size(tester);
      var changed = 0;
      await tester.pumpWidget(
        _app(
          Scaffold(
            appBar: UtenAppBar(
              title: '历史业务页',
              showPagePermissionAction: false,
              actions: _withFillers(
                UtenHistoryTimeFilter(
                  value: const UtenHistoryTimeValue.all(),
                  onChanged: (_) => changed++,
                ),
              ),
            ),
          ),
        ),
      );
      await _openActions(tester);
      await tester.tap(find.text('时间段'));
      await tester.pumpAndSettle();
      expect(find.byType(DateRangePickerDialog), findsOneWidget);
      expect(find.byTooltip('关闭操作面板'), findsNothing);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(changed, 0);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'native action closes only the panel before delayed dialog navigation',
    (tester) async {
      _size(tester);
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (pageContext) => Scaffold(
              appBar: UtenAppBar(
                title: '原业务页',
                showPagePermissionAction: false,
                actions: _withFillers(
                  TextButton(
                    onPressed: () async {
                      await Future<void>.delayed(Duration.zero);
                      if (!pageContext.mounted) return;
                      await showDialog<void>(
                        context: pageContext,
                        builder: (dialogContext) => AlertDialog(
                          title: const Text('异步业务确认'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(dialogContext),
                              child: const Text('完成确认'),
                            ),
                          ],
                        ),
                      );
                    },
                    child: const Text('异步打开'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await _openActions(tester);
      await tester.tap(find.text('异步打开'));
      await tester.pumpAndSettle();
      expect(find.text('异步业务确认'), findsOneWidget);
      expect(find.byTooltip('关闭操作面板'), findsNothing);
      await tester.tap(find.text('完成确认'));
      await tester.pumpAndSettle();
      expect(find.text('异步业务确认'), findsNothing);
      expect(Navigator.of(tester.element(find.text('原业务页'))).canPop(), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'real Consumer draft navigation preserves the original goRouter returnTo',
    (tester) async {
      _size(tester);
      final router = GoRouter(
        initialLocation: '/basicinfo',
        routes: [
          GoRoute(
            path: '/basicinfo',
            builder: (_, _) => Scaffold(
              appBar: UtenAppBar(
                title: '基础资料',
                showPagePermissionAction: false,
                actions: _withFillers(
                  const FormDraftsAppBarButton(categoryId: 'basicinfo'),
                ),
              ),
            ),
          ),
          GoRoute(
            path: '/form-drafts/:categoryId',
            builder: (_, state) => Scaffold(
              body: Text('来源 ${state.uri.queryParameters['returnTo']}'),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            formDraftsPageCountProvider('basicinfo').overrideWithValue(2),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await _openActions(tester);
      await tester.tap(
        find.byKey(const ValueKey('form-drafts-button-basicinfo')),
      );
      await tester.pumpAndSettle();
      expect(find.text('来源 /basicinfo'), findsOneWidget);
      expect(find.byTooltip('关闭操作面板'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'stateful Consumer export stays mounted through preparation and password cancellation',
    (tester) async {
      _size(tester);
      final prepared = Completer<UtenExportSelection?>();
      await tester.pumpWidget(
        _app(
          Scaffold(
            appBar: UtenAppBar(
              title: '导出业务页',
              showPagePermissionAction: false,
              actions: _withFillers(
                UtenExportButton(
                  endpoint: '/unused',
                  report: 'test',
                  queryParams: const {},
                  prepareExport: () => prepared.future,
                ),
              ),
            ),
          ),
        ),
      );
      await _openActions(tester);
      await tester.tap(find.text('下载表格'));
      await tester.pump();
      expect(find.byTooltip('关闭操作面板'), findsOneWidget);
      prepared.complete(const UtenExportSelection());
      await tester.pumpAndSettle();
      expect(find.text('直接下载'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('直接下载'), findsNothing);
      expect(find.byTooltip('关闭操作面板'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'deferred async Consumer can read ref after await and keeps the new dialog alive',
    (tester) async {
      _size(tester);
      final ready = Completer<void>();
      var readValue = 0;
      await tester.pumpWidget(
        _app(
          Scaffold(
            appBar: UtenAppBar(
              title: '异步Consumer业务页',
              showPagePermissionAction: false,
              actions: _withFillers(
                _AsyncConsumerAction(
                  ready: ready.future,
                  onRead: (value) => readValue = value,
                ),
              ),
            ),
          ),
        ),
      );
      await _openActions(tester);
      await tester.tap(find.text('准备异步任务'));
      await tester.pump();
      ready.complete();
      await tester.pumpAndSettle();
      expect(readValue, 7);
      expect(find.text('后续业务弹窗'), findsOneWidget);
      expect(find.byTooltip('关闭操作面板'), findsNothing);
      await tester.tap(find.text('关闭业务弹窗'));
      await tester.pumpAndSettle();
      expect(find.text('后续业务弹窗'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

class _AsyncConsumerAction extends ConsumerWidget {
  const _AsyncConsumerAction({required this.ready, required this.onRead});
  final Future<void> ready;
  final ValueChanged<int> onRead;

  @override
  Widget build(BuildContext context, WidgetRef ref) => UtenButton(
    onPressed: () async {
      final presentation = UtenAppBarActionScope.actionContextOf(context);
      await ready;
      if (!presentation.mounted) return;
      onRead(ref.read(_value));
      // Completion removes just the action panel below this new dialog.
      unawaited(
        showDialog<void>(
          context: presentation,
          builder: (dialogContext) => AlertDialog(
            title: const Text('后续业务弹窗'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('关闭业务弹窗'),
              ),
            ],
          ),
        ),
      );
    },
    child: const Text('准备异步任务'),
  );
}
