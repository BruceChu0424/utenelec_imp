part of 'material_analysis_one_table_test.dart';

class _ProjectionOwnerPermissions extends Notifier<Set<String>> {
  @override
  Set<String> build() => _permissions;
  void revoke() => state = {};
}

class _ProjectionOwnerServer extends Notifier<String> {
  @override
  String build() => 'https://a.invalid/api';
  void change() => state = 'https://b.invalid/api';
}

class _ProjectionOwnerSession extends _OrderAuthoritySession {
  void replaceDataset({bool reset = false}) {
    state = SessionState(
      status: AuthStatus.authenticated,
      user: AppUser(
        id: 'first-account',
        code: 'FIRST',
        name: '计划甲',
        businessResetGeneration: reset ? 1 : 0,
        businessDatasetId: reset ? null : 'replacement-dataset',
      ),
    );
  }
}

final _projectionOwnerPermissions =
    NotifierProvider<_ProjectionOwnerPermissions, Set<String>>(
      _ProjectionOwnerPermissions.new,
    );
final _projectionOwnerServer = NotifierProvider<_ProjectionOwnerServer, String>(
  _ProjectionOwnerServer.new,
);

MasterDataTableView<dynamic> _presentationTable(WidgetTester tester) =>
    tester.widget<MasterDataTableView<dynamic>>(
      find.byKey(const Key('material-analysis-material-table')),
    );

// The production row type is private to its page library. Read the callbacks
// without narrowing their argument to dynamic, then pass only that table's own
// row objects; a typed MasterDataTableView<dynamic>.idOf getter would cast the
// contravariant callback and fail before exercising the real presentation.
String? _presentationRowId(MasterDataTableView<dynamic> table, Object row) {
  // ignore: avoid_dynamic_calls
  final callback = (table as dynamic).idOf as Function?;
  return callback == null ? null : Function.apply(callback, [row]) as String?;
}

String? _presentationRowKey(MasterDataTableView<dynamic> table, Object row) {
  // ignore: avoid_dynamic_calls
  final callback = (table as dynamic).rowKeyOf as Function?;
  return callback == null ? null : Function.apply(callback, [row]) as String?;
}

bool? _presentationRowState(MasterDataTableView<dynamic> table, Object row) {
  // ignore: avoid_dynamic_calls
  final callback = (table as dynamic).selectionStateOf as Function?;
  return callback == null ? null : Function.apply(callback, [row]) as bool?;
}

Map<String, dynamic> _fiveHundredProductPresentation(
  Map<String, dynamic> data,
) {
  final product = Map<String, dynamic>.from(
    (data['products'] as List).first as Map,
  );
  final root = Map<String, dynamic>.from(_fixtureMaterial(data, 'm-root'));
  final child = Map<String, dynamic>.from(_fixtureMaterial(data, 'm-2'));
  data['products'] = [
    for (var i = 0; i < 500; i++)
      {
        ...product,
        'analysisLineId': 'perf-$i',
        'goodsId': 'perf-product-$i',
        'goodsName': '性能产品$i',
        'rootMaterialLineId': 'perf-root-$i',
      },
  ];
  data['flatMaterials'] = [
    for (var i = 0; i < 500; i++) ...[
      {
        ...root,
        'analysisLineId': 'perf-$i',
        'materialLineId': 'perf-root-$i',
        'actionGroupKey': 'perf-root-$i',
        'nodeKey': 'perf-root-node-$i',
        'goodsId': 'perf-product-$i',
        'goodsName': '性能产品$i',
      },
      for (var j = 0; j < 3; j++)
        {
          ...child,
          'analysisLineId': 'perf-$i',
          'materialLineId': 'perf-$i-$j',
          'actionGroupKey': 'perf-$i-$j',
          'nodeKey': 'perf-node-$i-$j',
          'parentNodeKey': 'perf-root-node-$i',
          'goodsId': 'perf-material-$i-$j',
          'goodsName': '性能物料$i-$j',
        },
    ],
  ];
  return data;
}

void materialAnalysisPresentationWorkCases() {
  for (final transition in [
    'account',
    'A-B-A',
    'permissions',
    'server',
    'reset',
    'dataset',
  ]) {
    testWidgets('presentation owner: $transition stops old checkpoint work', (
      tester,
    ) async {
      final session = _ProjectionOwnerSession();
      final publicationsBefore = debugMaterialProjectionPublications;
      var changed = false;
      int? stepsAtChange;
      int? stepsAtEvent;
      int? publicationsAtEvent;
      debugMaterialProjectionStepObserver = () {
        if (changed) return;
        changed = true;
        stepsAtChange = debugMaterialProjectionSteps;
        final container = ProviderScope.containerOf(
          tester.element(find.byType(ProductionMaterialAnalysisPage)),
        );
        switch (transition) {
          case 'account':
          case 'A-B-A':
            session.switchAccount('second-account');
            container.read(exportContextEpochProvider);
            if (transition == 'A-B-A') {
              session.switchAccount('first-account');
            }
          case 'permissions':
            container.read(_projectionOwnerPermissions.notifier).revoke();
          case 'server':
            container.read(_projectionOwnerServer.notifier).change();
          case 'reset':
            session.replaceDataset(reset: true);
          case 'dataset':
            session.replaceDataset();
        }
        container.read(exportContextEpochProvider);
        Timer.run(() {
          stepsAtEvent = debugMaterialProjectionSteps;
          publicationsAtEvent = debugMaterialProjectionPublications;
        });
      };
      addTearDown(() => debugMaterialProjectionStepObserver = null);
      await _pump(
        tester,
        session: session,
        projectionOwnerControls: true,
        mutate: _fiveHundredProductPresentation,
      );
      expect(changed, isTrue);
      expect(stepsAtEvent, isNotNull);
      expect(stepsAtEvent! - stepsAtChange!, lessThanOrEqualTo(1));
      expect(publicationsAtEvent, publicationsBefore);
      expect(_submits(), isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  for (final aba in [false, true]) {
    for (final decodingFails in [false, true]) {
      testWidgets(
        'command owner: priority DTO ${aba ? 'ABA' : 'account change'} ${decodingFails ? 'late error' : 'late result'} never publishes or retries',
        (tester) async {
          final session = _OrderAuthoritySession();
          var commandResponseStarted = false;
          await _pump(
            tester,
            session: session,
            permissions: {
              ..._permissions,
              Perm.productionMaterialAnalysisReallocate,
            },
            mutate: (data) {
              _threeSharedBuySources(data);
              (data['allowedActions'] as List).add('REALLOCATE');
              return data;
            },
            afterWrite: (data) {
              commandResponseStarted = true;
              return {
                ...data,
                'analysisNo': 'OLD_DTO_RESPONSE',
                'supplyActions': [
                  ...(data['supplyActions'] as List),
                  for (var i = 0; i < 1500; i++)
                    {
                      'actionId': 'dto-$i',
                      'route': 'BUY',
                      'operationType': 'SUPPLY',
                      'requestedQty': i + 1,
                    },
                ],
              };
            },
          );
          final container = ProviderScope.containerOf(
            tester.element(find.byType(ProductionMaterialAnalysisPage)),
          );
          var switchedDuringDecode = false;
          final previousObserver = debugUiWorkSliceObserver;
          debugUiWorkSliceObserver = (label, elapsed) {
            previousObserver?.call(label, elapsed);
            if (!commandResponseStarted ||
                label != 'presentation' ||
                switchedDuringDecode) {
              return;
            }
            switchedDuringDecode = true;
            session.switchAccount('second-account');
            container.read(exportContextEpochProvider);
            if (aba) {
              session.switchAccount('first-account');
              container.read(exportContextEpochProvider);
            }
            // Failure injection is after a successful command response, inside
            // DTO work; it must not be presented as a new owner's failed write.
            if (decodingFails) {
              throw const FormatException('old-private-decode-error');
            }
          };
          addTearDown(() => debugUiWorkSliceObserver = previousObserver);
          await tester.tap(
            find.byKey(const Key('material-analysis-priority-edit')),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('material-priority-down-0')),
          );
          await tester.tap(
            find.byKey(const Key('material-analysis-priority-save')),
          );
          await tester.pumpAndSettle();
          expect(switchedDuringDecode, isTrue);
          expect(
            requests.where(
              (request) => request.path.endsWith('/allocation-priorities'),
            ),
            hasLength(1),
          );
          expect(find.textContaining('OLD_DTO_RESPONSE'), findsNothing);
          expect(_notices(tester), isNot(contains('生产优先级已更新')));
          expect(_notices(tester), isNot(contains('old-private-decode-error')));
          expect(find.textContaining('原操作可能已完成'), findsWidgets);
          final save = tester.widget<UtenButton>(
            find.byKey(const Key('material-analysis-priority-save')),
          );
          expect(
            save.onPressed,
            isNotNull,
            reason: 'the old owner loading marker is retired, not stranded',
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets(
    'presentation work: aggregate history follows exact target identities within one action group',
    (tester) async {
      await _pump(
        tester,
        mutate: (data) {
          final next = _canonicalSupplyFixture(data);
          final template = Map<String, dynamic>.from(
            (next['supplyActions'] as List).first as Map,
          );
          next['supplyActions'] = [
            {
              ...template,
              'actionId': 'exact-a',
              'documentNo': 'EXACT-A',
              'requestedQty': 1000,
              'publicSurplusQty': 100,
            },
            {
              ...template,
              'actionId': 'exact-b',
              'documentNo': 'EXACT-B',
              'requestedQty': 2000,
              'publicSurplusQty': 200,
            },
          ];
          for (var i = 0; i < 3; i++) {
            final material = _fixtureMaterial(next, 'canonical-$i');
            material['actionGroupKey'] = 'shared-canonical-group';
            final references = material['downstreamReferences'] as List;
            (references.single as Map)['actionId'] = i == 0
                ? 'exact-a'
                : 'exact-b';
          }
          // The repeated exact target is intentionally reachable from two paths;
          // both distinct target facts survive, and the shared action counts once.
          (_fixtureMaterial(next, 'shared-0')['aggregatePreparation']
              as Map)['targetMaterialLineIds'] = [
            'canonical-0',
            'canonical-1',
          ];
          return next;
        },
      );
      await _showMaterialSummary(tester);
      expect(
        find.textContaining('已下单 3300 = 需求份 3000 + 公共备货 300'),
        findsWidgets,
      );
      expect(find.textContaining('EXACT-A'), findsWidgets);
      expect(find.textContaining('EXACT-B'), findsWidgets);
      expect(_submits(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'presentation work: an input event supersedes an in-progress large filter',
    (tester) async {
      await _pump(tester, mutate: _fiveHundredProductPresentation);
      final table = _presentationTable(tester);
      final originalRows = table.items;
      final before = debugMaterialProjectionPublications;
      var scheduled = false;
      var inputHandled = false;
      debugMaterialProjectionStepObserver = () {
        if (scheduled) return;
        scheduled = true;
        Timer.run(() {
          expect(_presentationTable(tester).items, same(originalRows));
          _presentationTable(tester).onFilterChanged('colorName', null);
          inputHandled = true;
        });
      };
      addTearDown(() => debugMaterialProjectionStepObserver = null);
      table.onFilterChanged('colorName', '不存在的颜色');
      await tester.pumpAndSettle();
      expect(inputHandled, isTrue);
      expect(_presentationTable(tester).items, same(originalRows));
      expect(
        debugMaterialProjectionPublications - before,
        0,
        reason:
            'the previous complete result stays current; the superseded empty result never publishes',
      );
      expect(_submits(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'presentation work: 500 products yield to event input before atomic publication',
    (tester) async {
      final before = debugMaterialProjectionSteps;
      final published = debugMaterialProjectionPublications;
      int? stepsAtEvent;
      int? publicationsAtEvent;
      var scheduled = false;
      debugMaterialProjectionStepObserver = () {
        if (scheduled) return;
        scheduled = true;
        Timer.run(() {
          stepsAtEvent = debugMaterialProjectionSteps - before;
          publicationsAtEvent = debugMaterialProjectionPublications - published;
        });
      };
      addTearDown(() => debugMaterialProjectionStepObserver = null);
      await _pump(
        tester,
        size: const Size(1800, 945),
        mutate: _fiveHundredProductPresentation,
      );
      expect(
        stepsAtEvent,
        inInclusiveRange(1, 256),
        reason: 'an event turn runs before the complete 2000-node projection',
      );
      expect(
        publicationsAtEvent,
        0,
        reason: 'no partial rows or totals are published between slices',
      );
      expect(debugMaterialProjectionSteps - before, greaterThan(2000));
      expect(_presentationTable(tester).items, hasLength(2000));
      expect(_submits(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'presentation work: repeated complete layout reuses the immutable projection',
    (tester) async {
      final syncBefore = debugMaterialSynchronousAggregateBuilds;
      await _pump(tester, mutate: _fiveHundredProductPresentation);
      final productRows = _presentationTable(tester).items;
      await _showMaterialSummary(tester);
      final summaryRows = _presentationTable(tester).items;
      final before = debugMaterialProjectionSteps;
      await tester.tap(
        find.byKey(const ValueKey('material-bom-layout-product')),
      );
      await tester.pumpAndSettle();
      expect(_presentationTable(tester).items, same(productRows));
      await _showMaterialSummary(tester);
      expect(_presentationTable(tester).items, same(summaryRows));
      expect(
        debugMaterialProjectionSteps,
        before,
        reason: 'unchanged two-layout snapshots do not rescan BOM/facet facts',
      );
      expect(
        debugMaterialSynchronousAggregateBuilds,
        syncBefore,
        reason:
            'build-time expansion controls also reuse the prepared aggregates',
      );
      expect(_submits(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'presentation work: visual switches preserve bucket summary work',
    (tester) async {
      await _pump(tester);
      List<(String, int, int)> summaries() => tester
          .widgetList<MaterialPreparationRouteCard>(
            find.byType(MaterialPreparationRouteCard),
          )
          .map(
            (card) => (card.routeId, card.inProgressCount, card.pendingCount),
          )
          .toList();
      final expected = summaries();
      final before = debugMaterialBucketSummaryEvaluations;
      for (var i = 0; i < 2; i++) {
        await _showMaterialSummary(tester);
        await tester.tap(
          find.byKey(const ValueKey('material-bom-layout-product')),
        );
        await tester.pumpAndSettle();
        expect(summaries(), expected);
      }
      tester
          .widget<UtenButton>(
            find.byKey(const Key('material-analysis-bom-expansion-toggle')),
          )
          .onPressed!();
      await tester.pumpAndSettle();
      expect(summaries(), expected);
      tester
          .widget<UtenButton>(
            find.byKey(const Key('material-analysis-bom-expansion-toggle')),
          )
          .onPressed!();
      await tester.pumpAndSettle();
      expect(summaries(), expected);
      expect(
        debugMaterialBucketSummaryEvaluations - before,
        0,
        reason:
            'layout-only switches do not change any preparation bucket fact',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'presentation work: live permissions and quantity edits invalidate eligibility',
    (tester) async {
      final permissions = {..._permissions};
      await _pump(tester, permissions: permissions);
      final current = _presentationTable(tester);
      final Object row =
          current.items.singleWhere(
                (row) =>
                    _presentationRowKey(current, row as Object) ==
                    'MATERIAL|m-2',
              )
              as Object;
      expect(_presentationRowId(current, row), isNotNull);
      // Even an already captured callback must observe a permission change;
      // no widget rebuild or a new permission Set is needed to retire its memo.
      permissions.remove(Perm.productionMaterialAnalysisNotify);
      expect(_presentationRowId(current, row), isNull);
      expect(_presentationRowState(current, row), isFalse);
      permissions.add(Perm.productionMaterialAnalysisNotify);
      expect(_presentationRowId(current, row), isNotNull);
      final beforeEdit = debugMaterialTableEligibilityEvaluations;
      final bucketBeforeEdit = debugMaterialBucketSummaryEvaluations;
      await tester.enterText(_orderQty('m-2'), '900');
      expect(_presentationRowId(current, row), isNotNull);
      expect(debugMaterialTableEligibilityEvaluations, greaterThan(beforeEdit));
      await _settleRebuild(tester);
      expect(
        debugMaterialBucketSummaryEvaluations,
        greaterThan(bucketBeforeEdit),
      );
      expect(_nodeSelected(tester, 'm-2'), isTrue);
      expect(_qtyText(tester, _orderQty('m-2')), '900');
      expect(
        _submits(),
        isEmpty,
        reason: 'presentation queries never perform writes',
      );
      expect(tester.takeException(), isNull);
    },
  );
  for (final fontFactor in [1.0, 1.6]) {
    testWidgets(
      'presentation work: 500 products bound identity shaping per frame scale=$fontFactor',
      (tester) async {
        var observing = true;
        var previous = debugMaterialIdentityTextMeasures;
        final before = previous;
        final measuresPerFrame = <int>[];
        tester.binding.addPostFrameCallback((_) {});
        tester.binding.addPersistentFrameCallback((_) {
          if (!observing) return;
          measuresPerFrame.add(debugMaterialIdentityTextMeasures - previous);
          previous = debugMaterialIdentityTextMeasures;
        });
        addTearDown(() => observing = false);
        await _pump(
          tester,
          size: const Size(1800, 945),
          fontFactor: fontFactor,
          mutate: _fiveHundredProductPresentation,
        );
        expect(_presentationTable(tester).items, hasLength(2000));
        expect(
          measuresPerFrame.reduce((a, b) => a > b ? a : b),
          lessThanOrEqualTo(256),
          reason:
              'rich tree identity must share the bounded table width budget',
        );
        expect(
          debugMaterialIdentityTextMeasures - before,
          2000,
          reason:
              'every distinct loaded identity is eventually measured, including the final product',
        );
        await _showMaterialSummary(tester);
        expect(_presentationTable(tester).items, hasLength(2000));
        await tester.tap(
          find.byKey(const ValueKey('material-bom-layout-product')),
        );
        await tester.pumpAndSettle();
        expect(_presentationTable(tester).items, hasLength(2000));
        expect(
          measuresPerFrame.reduce((a, b) => a > b ? a : b),
          lessThanOrEqualTo(256),
          reason: 'switching both complete 2000-row projections also yields',
        );
        expect(
          find.byKey(const ValueKey('material-table-row-perf-499-2')),
          findsNothing,
          reason:
              'offscreen material cells remain lazy, while the full row set is retained',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('presentation work: layout reuses eligibility and selection facts', (
    tester,
  ) async {
    await _pump(tester);
    void inspect(MasterDataTableView<dynamic> current) {
      for (final row in current.items.cast<Object>()) {
        _presentationRowId(current, row);
        _presentationRowState(current, row);
      }
    }

    final current = _presentationTable(tester);
    final scopeReads = debugMaterialEligibilityScopeReads;
    current.selectionReadScope!(() {
      inspect(current);
      inspect(current);
    });
    expect(
      debugMaterialEligibilityScopeReads - scopeReads,
      1,
      reason:
          'one synchronous metadata collection shares one owner/access snapshot',
    );
    inspect(current);
    final before = debugMaterialTableEligibilityEvaluations;
    for (var frame = 0; frame < 8; frame++) {
      inspect(current);
    }
    expect(
      debugMaterialTableEligibilityEvaluations - before,
      0,
      reason:
          'width batches/layout must not rescan unchanged business eligibility',
    );
    await _check(tester, _rowCheckbox('m-2'));
    await tester.pumpAndSettle();
    expect(_nodeSelected(tester, 'm-2'), isTrue);
    final selected = _presentationTable(tester);
    final Object row =
        selected.items.singleWhere(
              (row) =>
                  _presentationRowKey(selected, row as Object) ==
                  'MATERIAL|m-2',
            )
            as Object;
    expect(_presentationRowState(selected, row), isTrue);
    expect(_presentationRowId(selected, row), isNotNull);
    expect(
      find.byKey(const Key('material-analysis-submit-orders')),
      findsOneWidget,
    );
    await _showMaterialSummary(tester);
    await tester.tap(find.byKey(const ValueKey('material-bom-layout-product')));
    await tester.pumpAndSettle();
    expect(_nodeSelected(tester, 'm-2'), isTrue);
    inspect(_presentationTable(tester));
    final afterToggle = debugMaterialTableEligibilityEvaluations;
    inspect(_presentationTable(tester));
    expect(debugMaterialTableEligibilityEvaluations, afterToggle);
    expect(tester.takeException(), isNull);
  });
}
