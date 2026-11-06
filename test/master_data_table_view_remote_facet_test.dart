import 'support/pump_until.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

Widget _page(
  MasterFacetPageLoader? loader, {
  Object scope = 'goods',
  String column = 'name',
  ValueChanged<String?>? selected,
}) => MaterialApp(
  home: Scaffold(
    body: MasterDataTableView<String>(
      columns: [
        MasterColumnDef(
          key: column,
          label: column == 'name' ? '货品名称' : '型号',
          width: 260,
          value: (row) => row,
        ),
      ],
      items: const ['V4一开', 'V4二开'],
      facets: const {
        'name': [MasterFacetBucket(value: '其他高频货品', count: 100)],
        'model': [MasterFacetBucket(value: '其他高频货品', count: 100)],
      },
      loadFacetPage: loader,
      facetSearchScope: scope,
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, value) => selected?.call(value),
    ),
  ),
);

const _initial = MasterFacetPage(
  items: [MasterFacetBucket(value: '其他高频货品', count: 100)],
  hasMore: false,
);

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('货品名称'));
  await tester.pump();
}

void main() {
  testWidgets(
    'party column uses complete paged source while unrelated facets stay local',
    (tester) async {
      final calls = <(String, int)>[];
      String? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MasterDataTableView<String>(
              columns: [
                MasterColumnDef(
                  key: 'party',
                  label: '往来方',
                  width: 200,
                  value: (_) => '当前引用',
                ),
                MasterColumnDef(
                  key: 'status',
                  label: '状态',
                  width: 160,
                  value: (_) => '已审',
                ),
              ],
              items: const ['row'],
              facets: const {
                'status': [MasterFacetBucket(value: '已审', count: 1)],
              },
              facetPageLoaders: {
                'party': (keyword, page) async {
                  calls.add((keyword, page));
                  return MasterFacetPage(
                    items: [
                      MasterFacetBucket(
                        value: 'remote-id',
                        label: keyword.isEmpty ? '完整远端候选' : '远端搜索结果',
                        count: 0,
                      ),
                    ],
                    hasMore: false,
                  );
                },
              },
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (key, value) {
                if (key == 'party') selected = value;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('状态'));
      await tester.pumpAndSettle();
      expect(find.text('已审 (1)'), findsOneWidget);
      expect(calls, isEmpty);
      await tester.tapAt(const Offset(790, 590));
      await tester.pumpAndSettle();
      await tester.tap(find.text('往来方'));
      await tester.pumpAndSettle();
      expect(find.text('完整远端候选'), findsOneWidget);
      expect(calls, [('', 1)]);
      await tester.enterText(find.byType(TextField).last, '编号外的客户');
      await tester.pump(const Duration(milliseconds: 251));
      await tester.pumpAndSettle();
      await tester.tap(find.text('远端搜索结果'));
      await tester.pumpAndSettle();
      expect(selected, 'remote-id');
      expect(calls, [('', 1), ('编号外的客户', 1)]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'frozen and ordinary header copies share the remote candidate caption across horizontal scroll',
    (tester) async {
      const id = 'b76b8d7e-e7ac-4e95-8fc3-1f9f0e878d58';
      const caption = '宁波成品仓库';
      const notes =
          'A very long description for this goods row with notes that requires horizontal scrolling';
      String? selected;
      var revision = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 440,
              height: 300,
              child: StatefulBuilder(
                builder: (context, update) => MasterDataTableView<String>(
                  requiredLeadingColumnKeys: const ['owningWarehouse'],
                  columns: [
                    MasterColumnDef(
                      key: 'owningWarehouse',
                      label: '所属仓库',
                      width: 180,
                      value: (_) => '货品',
                    ),
                    MasterColumnDef(
                      key: 'notes',
                      label: '备注',
                      width: 480,
                      value: (_) => notes,
                    ),
                  ],
                  items: const ['row'],
                  facets: const {
                    'owningWarehouse': [
                      MasterFacetBucket(
                        value: 'other',
                        label: '其他仓库',
                        count: 100,
                      ),
                    ],
                  },
                  nullCounts: const {},
                  filters: {'owningWarehouse': selected},
                  facetSearchScope: ('category', revision),
                  loadFacetPage: (_, search, _) async => search.isEmpty
                      ? const MasterFacetPage(
                          items: [
                            MasterFacetBucket(
                              value: 'other',
                              label: '其他仓库',
                              count: 100,
                            ),
                          ],
                          hasMore: false,
                        )
                      : const MasterFacetPage(
                          items: [
                            MasterFacetBucket(
                              value: id,
                              label: caption,
                              count: 1,
                            ),
                          ],
                          hasMore: false,
                        ),
                  onFilterChanged: (_, value) => update(() {
                    selected = value;
                    revision++;
                  }),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.text(notes), const Offset(-170, 0));
      await tester.pumpAndSettle();
      expect(find.text('所属仓库'), findsNWidgets(2));
      await tester.tap(find.text('所属仓库').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '宁波');
      await tester.pump(const Duration(milliseconds: 251));
      await tester.pumpAndSettle();
      await tester.tap(find.text('$caption (1)'));
      await tester.pumpAndSettle();
      expect(selected, id);
      expect(find.text(caption), findsNWidgets(2));
      expect(find.text(id), findsNothing);
      await tester.drag(find.text(notes), const Offset(170, 0));
      await tester.pumpAndSettle();
      expect(find.text(caption), findsOneWidget);
      await tester.tap(find.text(caption));
      await tester.pumpAndSettle();
      expect(find.text('其他仓库 (100)'), findsOneWidget);
      await tester.tapAt(const Offset(10, 590));
      await tester.pumpAndSettle();
      await tester.drag(find.text(notes), const Offset(-170, 0));
      await tester.pumpAndSettle();
      expect(find.text(caption), findsNWidgets(2));
      expect(find.text(id), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'selected remote label survives host ID/query rebuild and reopening but clears with the filter',
    (tester) async {
      const id = 'b76b8d7e-e7ac-4e95-8fc3-1f9f0e878d58';
      const caption = '宁波成品仓库';
      String? selected;
      var revision = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, update) => Column(
                children: [
                  TextButton(
                    onPressed: () => update(() {
                      selected = null;
                      revision++;
                    }),
                    child: const Text('清筛选'),
                  ),
                  TextButton(
                    onPressed: () => update(() {
                      selected = id;
                      revision++;
                    }),
                    child: const Text('重放旧ID'),
                  ),
                  Expanded(
                    child: MasterDataTableView<String>(
                      columns: [
                        MasterColumnDef(
                          key: 'owningWarehouse',
                          label: '所属仓库',
                          width: 260,
                          value: (row) => row,
                        ),
                      ],
                      items: const ['货品'],
                      facets: const {
                        'owningWarehouse': [
                          MasterFacetBucket(
                            value: 'other',
                            label: '其他仓库',
                            count: 100,
                          ),
                        ],
                      },
                      nullCounts: const {},
                      filters: {'owningWarehouse': selected},
                      facetSearchScope: ('category', revision),
                      loadFacetPage: (_, search, _) async => search.isEmpty
                          ? const MasterFacetPage(
                              items: [
                                MasterFacetBucket(
                                  value: 'other',
                                  label: '其他仓库',
                                  count: 100,
                                ),
                              ],
                              hasMore: false,
                            )
                          : const MasterFacetPage(
                              items: [
                                MasterFacetBucket(
                                  value: id,
                                  label: caption,
                                  count: 1,
                                ),
                              ],
                              hasMore: false,
                            ),
                      onFilterChanged: (_, value) => update(() {
                        selected = value;
                        revision++;
                      }),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('所属仓库'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '宁波');
      await tester.pump(const Duration(milliseconds: 251));
      await tester.pumpAndSettle();
      await tester.tap(find.text('$caption (1)'));
      await tester.pumpAndSettle();
      expect(selected, id);
      expect(find.text(caption), findsOneWidget);
      expect(find.text(id), findsNothing);
      await tester.tap(find.text(caption));
      await tester.pumpAndSettle();
      expect(find.text('其他仓库 (100)'), findsOneWidget);
      await tester.tapAt(const Offset(10, 590));
      await tester.pumpAndSettle();
      expect(find.text(caption), findsOneWidget);
      await tester.tap(find.text('清筛选'));
      await tester.pumpAndSettle();
      expect(find.text(caption), findsNothing);
      expect(find.text('所属仓库'), findsOneWidget);
      await tester.tap(find.text('重放旧ID'));
      await tester.pumpAndSettle();
      expect(find.text(caption), findsNothing);
      expect(find.text(id), findsOneWidget);
    },
  );

  testWidgets(
    'reusing a header position for another column closes old candidates',
    (tester) async {
      final pending = Completer<MasterFacetPage>();
      Future<MasterFacetPage> loader(String _, String _, int _) =>
          pending.future;
      await tester.pumpWidget(_page(loader));
      await tester.pumpAndSettle();
      await _open(tester);
      await tester.pump();
      await tester.pumpWidget(_page(loader, column: 'model'));
      await tester.pump();
      pending.complete(_initial);
      await tester.pumpAndSettle();
      expect(find.text('型号'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('其他高频货品 (100)'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'IME composition waits for commit even when the committed text is unchanged',
    (tester) async {
      final requests = <String>[];
      await tester.pumpWidget(
        _page((_, query, _) async {
          requests.add(query);
          return _initial;
        }),
      );
      await tester.pumpAndSettle();
      await _open(tester);
      await tester.pumpAndSettle();
      await tester.showKeyboard(find.byType(TextField).last);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'v4',
          selection: TextSelection.collapsed(offset: 2),
          composing: TextRange(start: 0, end: 2),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(requests, ['']);
      expect(find.text('无匹配项'), findsNothing);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'v4',
          selection: TextSelection.collapsed(offset: 2),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 251));
      await tester.pumpAndSettle();
      expect(requests, ['', 'v4']);
    },
  );

  testWidgets(
    'local menus retain exact buckets and submit column keywords to the table',
    (tester) async {
      await tester.pumpWidget(_page(null));
      await tester.pumpAndSettle();
      await _open(tester);
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('uten-column-keyword-input'));
      expect(tester.widget<TextField>(input).decoration?.hintText, '货品名称');
      expect(find.text('其他高频货品 (100)'), findsOneWidget);
      expect(find.text('加载更多候选'), findsNothing);
      await tester.enterText(input, 'V4一');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(input, findsNothing);
      expect(find.text('V4一开'), findsOneWidget);
      expect(find.text('V4二开'), findsNothing);
    },
  );

  testWidgets(
    'equal query records retain menu, actor/category/keyword/filter/pending changes close it',
    (tester) async {
      const initialScope = (
        actor: 'u1',
        category: 'a',
        keyword: '开关',
        filter: '80-B',
        pending: false,
      );
      Future<MasterFacetPage> loader(String _, String _, int _) async =>
          _initial;
      for (final changed in [
        (
          actor: 'u2',
          category: 'a',
          keyword: '开关',
          filter: '80-B',
          pending: false,
        ),
        (
          actor: 'u1',
          category: 'b',
          keyword: '开关',
          filter: '80-B',
          pending: false,
        ),
        (
          actor: 'u1',
          category: 'a',
          keyword: '插座',
          filter: '80-B',
          pending: false,
        ),
        (
          actor: 'u1',
          category: 'a',
          keyword: '开关',
          filter: '90-B',
          pending: false,
        ),
        (
          actor: 'u1',
          category: 'a',
          keyword: '开关',
          filter: '80-B',
          pending: true,
        ),
      ]) {
        await tester.pumpWidget(_page(loader, scope: initialScope));
        await tester.pumpAndSettle();
        await _open(tester);
        await tester.pumpAndSettle();
        await tester.pumpWidget(
          _page(
            loader,
            scope: (
              actor: 'u1',
              category: 'a',
              keyword: '开关',
              filter: '80-B',
              pending: false,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsOneWidget);
        await tester.pumpWidget(_page(loader, scope: changed));
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsNothing);
      }
    },
  );

  testWidgets(
    'a failed late facet batch exposes no prefix and retry reaches all1001 local candidates',
    (tester) async {
      final requests = <int>[];
      final gate = Completer<MasterFacetPage>();
      var fail = true;
      String? selected;
      addTearDown(() {
        if (!gate.isCompleted) {
          gate.complete(const MasterFacetPage(items: [], hasMore: false));
        }
      });
      MasterFacetPage batch(int page) => MasterFacetPage(
        items: [
          for (var i = (page - 1) * 100; i < page * 100 && i < 1001; i++)
            MasterFacetBucket(value: 'id-$i', label: '范围中文候选$i', count: 1),
        ],
        hasMore: page < 11,
        page: page,
        size: 100,
      );
      await tester.pumpWidget(
        _page((_, _, page) async {
          requests.add(page);
          if (page == 2 && fail) return gate.future;
          return batch(page);
        }, selected: (value) => selected = value),
      );
      await _open(tester);
      await pumpUntil(
        tester,
        () => requests.contains(2),
        reason: 'The late internal batch must really be pending.',
      );
      await tester.pump();
      expect(
        find.text('范围中文候选0 (1)'),
        findsNothing,
        reason: 'An unchecked first batch cannot be selected.',
      );
      gate.completeError(StateError('late batch offline'));
      await tester.pumpAndSettle();
      expect(find.text('候选加载失败，点击重试'), findsOneWidget);
      expect(find.text('范围中文候选0 (1)'), findsNothing);
      fail = false;
      await tester.tap(find.text('候选加载失败，点击重试'));
      await tester.pumpAndSettle();
      expect(requests, [1, 2, for (var page = 1; page <= 11; page++) page]);
      final first = find.text('范围中文候选0 (1)');
      expect(first, findsOneWidget);
      final scrollElement = find
          .ancestor(of: first, matching: find.byType(Scrollable))
          .evaluate()
          .single;
      final localScroll = find.byElementPredicate(
        (element) => identical(element, scrollElement),
      );
      final before = requests.length;
      await tester.scrollUntilVisible(
        find.text('范围中文候选1000 (1)'),
        1400,
        scrollable: localScroll,
      );
      await tester.pumpAndSettle();
      expect(find.text('范围中文候选1000 (1)').hitTestable(), findsOneWidget);
      expect(requests, hasLength(before));
      await tester.tap(find.text('范围中文候选1000 (1)'));
      await tester.pumpAndSettle();
      expect(selected, 'id-1000');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'an old query held tail cannot publish its prefix or overwrite the new complete candidate scope',
    (tester) async {
      final gate = Completer<MasterFacetPage>();
      final requests = <(String, int)>[];
      addTearDown(() {
        if (!gate.isCompleted) {
          gate.complete(const MasterFacetPage(items: [], hasMore: false));
        }
      });
      await tester.pumpWidget(
        _page((_, query, page) async {
          requests.add((query, page));
          if (query == '旧中文') {
            if (page == 2) return gate.future;
            return const MasterFacetPage(
              items: [
                MasterFacetBucket(value: 'old-prefix', label: '旧前缀', count: 1),
              ],
              hasMore: true,
            );
          }
          if (query == '新中文') {
            return const MasterFacetPage(
              items: [
                MasterFacetBucket(
                  value: 'new-tail',
                  label: '新完整中文末尾',
                  count: 1,
                ),
              ],
              hasMore: false,
            );
          }
          return _initial;
        }),
      );
      await _open(tester);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '旧中文');
      await tester.pump(const Duration(milliseconds: 251));
      await pumpUntil(
        tester,
        () => requests.contains(('旧中文', 2)),
        reason: 'The old tail must actually be outstanding.',
      );
      expect(find.text('旧前缀 (1)'), findsNothing);
      await tester.enterText(find.byType(TextField).last, '新中文');
      await tester.pump(const Duration(milliseconds: 251));
      await tester.pumpAndSettle();
      expect(find.text('新完整中文末尾 (1)'), findsOneWidget);
      gate.complete(
        const MasterFacetPage(
          items: [MasterFacetBucket(value: 'old-tail', label: '旧尾部', count: 1)],
          hasMore: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('新完整中文末尾 (1)'), findsOneWidget);
      expect(find.text('旧前缀 (1)'), findsNothing);
      expect(find.text('旧尾部 (1)'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'same-count facet data-version replacement rejects the entire new scope',
    (tester) async {
      await tester.pumpWidget(
        _page(
          (_, _, page) async => MasterFacetPage(
            items: [MasterFacetBucket(value: 'value-$page', count: 1)],
            hasMore: page == 1,
            page: page,
            size: 100,
            readScopeVersion: 'authorized-owner',
            readSnapshotRevision: 'a' * 64,
            readDataVersion: (page == 1 ? 'c' : 'd') * 64,
          ),
        ),
      );
      await _open(tester);
      await tester.pumpAndSettle();
      expect(find.text('候选加载失败，点击重试'), findsOneWidget);
      expect(find.text('value-1 (1)'), findsNothing);
      expect(find.text('value-2 (1)'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'remote failure offers retry rather than falsely reporting no match',
    (tester) async {
      var attempts = 0;
      await tester.pumpWidget(
        _page((_, _, _) async {
          if (++attempts == 1) throw StateError('offline');
          return _initial;
        }),
      );
      await tester.pumpAndSettle();
      await _open(tester);
      await tester.pumpAndSettle();
      expect(find.text('候选加载失败，点击重试'), findsOneWidget);
      expect(find.text('无匹配项'), findsNothing);
      await tester.tap(find.text('候选加载失败，点击重试'));
      await tester.pumpAndSettle();
      expect(find.text('其他高频货品 (100)'), findsOneWidget);
    },
  );

  testWidgets(
    'search collects the full candidate scope once without a continuation control',
    (tester) async {
      final requests = <(String, String, int)>[];
      String? selected;
      await tester.pumpWidget(
        _page((column, keyword, page) async {
          requests.add((column, keyword, page));
          if (keyword.isEmpty) return _initial;
          return MasterFacetPage(
            items: [
              MasterFacetBucket(value: page == 1 ? 'V4一开' : 'V4二开', count: 1),
            ],
            hasMore: page == 1,
          );
        }, selected: (value) => selected = value),
      );
      await tester.pumpAndSettle();
      await _open(tester);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'V4');
      await tester.pump(const Duration(milliseconds: 251));
      await tester.pumpAndSettle();
      expect(requests.where((request) => request.$2 == 'V4'), [
        ('name', 'V4', 1),
        ('name', 'V4', 2),
      ]);
      expect(find.text('V4一开 (1)'), findsOneWidget);
      expect(find.text('无匹配项'), findsNothing);
      expect(find.text('加载更多候选'), findsNothing);
      expect(requests.last, ('name', 'V4', 2));
      expect(find.text('V4二开 (1)'), findsOneWidget);
      await tester.tap(find.text('V4二开 (1)'));
      await tester.pumpAndSettle();
      expect(selected, isNull);
      expect(find.text('货品名称：V4二开'), findsOneWidget);
      expect(find.textContaining('包含“'), findsNothing);
    },
  );

  testWidgets(
    'debounce suppresses intermediate input and stale responses cannot replace current candidates',
    (tester) async {
      final old = Completer<MasterFacetPage>();
      final requests = <String>[];
      await tester.pumpWidget(
        _page((_, query, page) async {
          requests.add(query);
          if (query == 'V') return old.future;
          if (query == 'V4') {
            return const MasterFacetPage(
              items: [MasterFacetBucket(value: 'V4一开', count: 1)],
              hasMore: false,
            );
          }
          return _initial;
        }),
      );
      await tester.pumpAndSettle();
      await _open(tester);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'V');
      await tester.pump(const Duration(milliseconds: 251));
      await tester.enterText(find.byType(TextField).last, 'V45');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(find.byType(TextField).last, 'V4');
      await tester.pump(const Duration(milliseconds: 251));
      await tester.pumpAndSettle();
      expect(requests, ['', 'V', 'V4']);
      old.complete(
        const MasterFacetPage(
          items: [MasterFacetBucket(value: '旧结果', count: 1)],
          hasMore: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('旧结果 (1)'), findsNothing);
      expect(find.text('V4一开 (1)'), findsOneWidget);
    },
  );

  testWidgets(
    'changing category closes the old candidate menu and ignores its in-flight response',
    (tester) async {
      final pending = Completer<MasterFacetPage>();
      Future<MasterFacetPage> loader(String _, String _, int _) =>
          pending.future;
      await tester.pumpWidget(_page(loader));
      await tester.pumpAndSettle();
      await _open(tester);
      await tester.pump();
      await tester.pumpWidget(_page(loader, scope: 'another-category'));
      await tester.pump();
      pending.complete(_initial);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
