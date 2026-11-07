part of 'material_analysis_one_table_test.dart';

Map<String, dynamic> _canonicalSupplyFixture(Map<String, dynamic> data) {
  _threeSharedBuySources(data);
  (data['allowedActions'] as List).add('CANCEL_ACTION');
  final next =
      _sharedAggregateSubmit({
            'groups': [
              {'clientGroupKey': 'g-m-2|本色|unit-1'},
            ],
          }, data)['analysis']
          as Map<String, dynamic>;
  (next['products'] as List).add({
    'analysisLineId': 'canonical-anchor',
    'sourceType': 'AGGREGATE_MAKE',
    'goodsName': '共享制造责任',
    'requestedQty': 3000,
    'remainingQty': 0,
  });
  for (var i = 0; i < 3; i++) {
    final original = _fixtureMaterial(next, 'shared-$i');
    final canonical = <String, dynamic>{
      ...original,
      'materialLineId': 'canonical-$i',
      'actionGroupKey': 'a-canonical-$i',
      'analysisLineId': 'canonical-anchor',
      'aggregatePreparation': null,
    };
    (next['flatMaterials'] as List).add(canonical);
    original['downstreamReferences'] = <Object>[];
    original['requiredQty'] = 0;
    original['sourceRequiredQty'] = 1000;
    original['requirementState'] = 'DELEGATED_TO_MAKE_CHILD';
    original['aggregatePreparation'] = {
      ...(original['aggregatePreparation'] as Map),
      'orderedQtyExact': true,
      'targetMaterialLineIds': ['canonical-$i'],
      'actionable': true,
    };
  }
  return next;
}

Future<void> _showMaterialSummary(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('material-bom-layout-material')));
  await tester.pumpAndSettle();
}

String _materialDraftOwner(WidgetTester tester) {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(ProductionMaterialAnalysisPage)),
  );
  final owner = container.read(formDraftsProvider.notifier).ownerKey;
  expect(owner, isNotNull);
  return owner!;
}

Future<Map<String, Map<String, dynamic>>> _storedPreparationDrafts(
  MemoryFormDraftStorage storage,
  String owner,
) async {
  final records = await storage.readAll(owner);
  return {
    for (final entry in records.entries)
      if (jsonDecode(entry.value) case final Map<String, dynamic> record)
        if (record['draftKind'] == 'material_preparation') entry.key: record,
  };
}

Future<List<Map<String, dynamic>>> _ownedMaterialPayloads(
  MemoryFormDraftStorage storage,
  String owner,
) async => [
  for (final record in (await _storedPreparationDrafts(storage, owner)).values)
    if (record['data'] case final Map<String, dynamic> data)
      Map<String, dynamic>.from(data),
];

Future<void> _expectMaterialOwnerRetired(
  WidgetTester tester,
  MemoryFormDraftStorage storage,
  String owner,
) async {
  expect(find.text('登录身份或权限已变化，请重新打开分析。原输入和原请求保留在原账号下。'), findsOneWidget);
  expect(
    find.byKey(const Key('material-analysis-material-table')),
    findsNothing,
  );
  expect(
    find.byKey(const Key('material-analysis-submit-orders')),
    findsNothing,
  );
  final payloads = await _ownedMaterialPayloads(storage, owner);
  if (const bool.fromEnvironment('UTEN_MATERIAL_DIAGNOSTICS')) {
    // Synthetic memory-store metadata only; preserve the original owner's
    // actual record as evidence rather than inspecting a private page State.
    // ignore: avoid_print
    print(
      'material-owned-draft-observation ${jsonEncode({
        'owner': owner,
        'payloads': [
          for (final payload in payloads) {'selected': payload['selected'], 'uncertain': payload['uncertain'], 'hasSubmittedBody': payload['submittedBodyJson'] is String, 'keys': payload.keys.toList()},
        ],
      })}',
    );
  }
  expect(payloads, isNotEmpty, reason: '界面退休不应删除原账号的私有草稿');
  expect(
    payloads.any(
      (payload) => (payload['selected'] as Map?)?[_groupKey('m-2')] == true,
    ),
    isTrue,
    reason: '原账号的已选来源仍保留在原owner草稿中，不交给新账号展示',
  );
}

Future<Map<String, dynamic>> _expectOriginalPreparationRetained(
  WidgetTester tester,
  _OrderAuthoritySession session, {
  required MemoryFormDraftStorage storage,
  required String owner,
  Map<String, dynamic>? submitted,
  String? submittedBodyJson,
}) async {
  await _expectMaterialOwnerRetired(tester, storage, owner);
  expect(
    find.byKey(const Key('material-analysis-material-table')),
    findsNothing,
  );
  expect(
    find.byKey(const Key('material-analysis-submit-orders')),
    findsNothing,
  );
  expect(find.textContaining('原输入和原请求保留在原账号下'), findsOneWidget);
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpAndSettle();
  final original = await _storedPreparationDrafts(storage, owner);
  expect(original, hasLength(1), reason: '退休编辑器必须在原账号命名空间保留可恢复草稿');
  final data = Map<String, dynamic>.from(original.values.single['data'] as Map);
  expect((data['selected'] as Map)[_groupKey('m-2')], isTrue);
  expect(_records(data['groups']).single['totalText'], '500');
  expect((data['currentOrder'] as Map)[_groupKey('m-2')], '500');
  expect(
    ((_records(data['groups']).single['paths'] as Map)['m-2']
        as Map)['orderText'],
    '500',
    reason: '保留用户原文，不能只留下可重算的浮点估算缓存',
  );
  if (submitted != null) {
    expect(jsonDecode(data['submittedBodyJson'] as String), submitted);
    if (submittedBodyJson != null) {
      expect(data['submittedBodyJson'], submittedBodyJson);
    }
    expect(data['_formDraftHasUnknownSubmission'], isTrue);
  }
  requests.clear();
  session.switchAccount('first-account');
  await tester.pumpAndSettle();
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpAndSettle();
  // A-B-A 的 epoch 仍退休旧编辑器；不能靠回到相同 userId 重新采用迟到回包。
  expect(
    find.byKey(const Key('material-analysis-material-table')),
    findsNothing,
  );
  expect(
    find.byKey(const Key('material-analysis-submit-orders')),
    findsNothing,
  );
  expect(_aggregateSubmits(), isEmpty);
  final container = ProviderScope.containerOf(
    tester.element(find.byType(ProductionMaterialAnalysisPage)),
  );
  await tester.runAsync(
    () => container.read(formDraftsProvider.notifier).ready,
  );
  await tester.pumpAndSettle();
  final restoredOwner = container.read(formDraftsProvider);
  expect(
    restoredOwner.where((draft) => draft.draftKind == 'material_preparation'),
    hasLength(1),
    reason: '回到原账号可从草稿恢复，原数据不能只留在已隐藏的Widget内存中',
  );
  expect((await _storedPreparationDrafts(storage, owner)).keys, original.keys);
  return data;
}

void materialOrderAuthorityCases() {
  testWidgets('整批撤回409保留真实单据并显示失败，不误报成功或自动重试', (tester) async {
    await _pump(
      tester,
      permissions: _unifiedHandlingPermissions,
      mutate: _unifiedHandlingFixture,
      failOn: const {'/cancel': 409},
    );
    await _showUnifiedMaterialLayout(tester);
    requests.clear();
    final button = find.byKey(
      const ValueKey('material-aggregate-cancel-make-batch-1'),
    );
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('确认整批撤回'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    expect(
      requests.where((request) => request.path.endsWith('/cancel')),
      hasLength(1),
    );
    expect(button, findsOneWidget, reason: '服务端回滚后原批次仍可核对，不能从本地隐藏');
    final notices = ProviderScope.containerOf(
      tester.element(find.byType(ProductionMaterialAnalysisPage)),
    ).read(appNotificationProvider);
    expect(
      notices.where((notice) => notice.kind == AppNotificationKind.warning),
      isNotEmpty,
    );
    expect(
      notices.where((notice) => notice.kind == AppNotificationKind.success),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('来源办理权限：转交后两视图供应方式锁定，原来源仍能独立追加', (tester) async {
    await _pump(
      tester,
      mutate: _canonicalSupplyFixture,
      permissions: _overSupplyPermissions,
      overSupply: true,
    );
    for (var i = 0; i < 3; i++) {
      expect(
        find.byKey(ValueKey('material-route-dropdown-shared-$i')),
        findsNothing,
      );
      expect(
        tester.widget<Checkbox>(_rowCheckbox('shared-$i')).onChanged,
        isNotNull,
      );
      expect(_appendQty('shared-$i'), findsOneWidget);
    }
    await _showMaterialSummary(tester);
    expect(
      find.byKey(
        const ValueKey('material-route-dropdown-AGGREGATE|g-m-2|本色|unit-1'),
      ),
      findsNothing,
    );
    expect(find.text('已并入既有单据'), findsNothing);
    expect(
      find.byKey(const ValueKey('material-aggregate-cancel-aggregate-action')),
      findsOneWidget,
    );
    expect(requests.where((r) => r.path.endsWith('/routes')), isEmpty);
  });

  testWidgets('来源办理权限：汇总行一部分已下单时不得仅修改未下单的隐含来源', (tester) async {
    await _pump(
      tester,
      mutate: (data) {
        _threeSharedBuySources(data);
        _fixtureMaterial(data, 'shared-0')['downstreamReferences'] = [
          {
            'actionId': 'already-issued',
            'route': 'BUY',
            'status': 'REQUESTED',
            'allocatedQty': 1000,
          },
        ];
        return data;
      },
    );
    expect(
      find.byKey(const ValueKey('material-route-dropdown-shared-1')),
      findsNothing,
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('material-route-readonly-shared-1')),
          )
          .data,
      MaterialSupplyRoute.buy.label,
    );
    await _showMaterialSummary(tester);
    final row = find.byKey(
      const ValueKey('material-aggregate-g-m-2|本色|unit-1'),
    );
    expect(row, findsOneWidget);
    expect(
      find.descendant(
        of: row,
        matching: find.byWidgetPredicate(
          (widget) => widget.key.toString().contains('material-route-dropdown'),
        ),
      ),
      findsNothing,
    );
    expect(
      requests.where((request) => request.path.endsWith('/routes')),
      isEmpty,
    );
  });

  testWidgets('来源办理权限：已下单0.0001即使无原行引用也必须锁住路线', (tester) async {
    await _pump(
      tester,
      mutate: (data) {
        final material = _fixtureMaterial(data, 'm-2');
        material['downstreamReferences'] = <Object>[];
        material['aggregatePreparation'] = {
          'requiredQty': 1000,
          'orderedQty': 0.0001,
          'totalOrderedQty': 0.0001,
          'targetMaterialLineIds': <String>[],
          'actionable': true,
        };
        return data;
      },
    );
    expect(
      find.byKey(const ValueKey('material-route-dropdown-m-2')),
      findsNothing,
    );
  });

  testWidgets('来源办理权限：缺失精确目标时路线锁住，不能猜同货品单据', (tester) async {
    await _pump(
      tester,
      mutate: (data) {
        final material = _fixtureMaterial(data, 'm-2');
        material['aggregatePreparation'] = {
          'targetMaterialLineIds': ['missing-canonical'],
          'actionable': true,
        };
        return data;
      },
    );
    expect(
      find.byKey(const ValueKey('material-route-dropdown-m-2')),
      findsNothing,
    );
    expect(tester.widget<Checkbox>(_rowCheckbox('m-2')).onChanged, isNull);
  });

  testWidgets('来源办理权限：目标撤回确认仅统计真实分配，不重复三条别名', (tester) async {
    await _pump(
      tester,
      mutate: _canonicalSupplyFixture,
      aggregateCancel: (body, data) => data,
    );
    await _showMaterialSummary(tester);
    await tester.tap(
      find.byKey(const ValueKey('material-aggregate-cancel-aggregate-action')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('总量 3100'), findsOneWidget);
    expect(find.textContaining('其中公共备货 100'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('确认整批撤回'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      requests.where(
        (r) =>
            r.path.contains('/aggregate-orders/actions/') &&
            r.path.endsWith('/cancel'),
      ),
      hasLength(1),
    );
  });

  testWidgets('来源办理权限：撤回弹窗等待期间权限失效不发送旧授权请求', (tester) async {
    final permissions = {..._permissions};
    await _pump(
      tester,
      permissions: permissions,
      mutate: _canonicalSupplyFixture,
    );
    await _showMaterialSummary(tester);
    await tester.tap(
      find.byKey(const ValueKey('material-aggregate-cancel-aggregate-action')),
    );
    await tester.pumpAndSettle();
    permissions.remove(Perm.productionMaterialAnalysisNotify);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('确认整批撤回'),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests.where((r) => r.path.endsWith('/cancel')), isEmpty);
    expect(_notices(tester), contains('撤回权限已变化'));
  });

  testWidgets('来源办理权限：万分位撤回守恒，不能用浮点容差放过少一个单位', (tester) async {
    await _pump(
      tester,
      mutate: (data) {
        final next = _canonicalSupplyFixture(data);
        final action = _records(next['supplyActions']).single;
        action['requestedQty'] = 0.0002;
        action['publicSurplusQty'] = 0;
        for (var i = 0; i < 3; i++) {
          final ref = _records(
            _fixtureMaterial(next, 'canonical-$i')['downstreamReferences'],
          ).single;
          ref['allocatedQty'] = 0.0001;
        }
        return next;
      },
    );
    await _showMaterialSummary(tester);
    await tester.tap(
      find.byKey(const ValueKey('material-aggregate-cancel-aggregate-action')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(requests.where((r) => r.path.endsWith('/cancel')), isEmpty);
    expect(_notices(tester), contains('来源资料不完整'));
  });
  testWidgets('来源办理权限：同版本动态投影在撤回弹窗期间改变也必须重新确认', (tester) async {
    final pending = Completer<Map<String, dynamic>>();
    Map<String, dynamic>? snapshot;
    await _pump(
      tester,
      mutate: _canonicalSupplyFixture,
      detailResponse: (data, count) {
        if (count == 1) return data;
        snapshot = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
        return pending.future;
      },
    );
    await _showMaterialSummary(tester);
    await _returnToMaterialAnalysis(tester);
    await tester.pump();
    expect(snapshot, isNotNull);
    await tester.tap(
      find.byKey(const ValueKey('material-aggregate-cancel-aggregate-action')),
    );
    await tester.pumpAndSettle();
    _fixtureMaterial(snapshot!, 'shared-0')['availableQty'] = 777;
    pending.complete(snapshot!);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('确认整批撤回'),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests.where((r) => r.path.endsWith('/cancel')), isEmpty);
    expect(_notices(tester), contains('分析状态或撤回权限已变化'));
  });

  testWidgets('来源办理权限：同权限账号在撤回确认前切换也不沿用前账号确认', (tester) async {
    final session = _OrderAuthoritySession();
    await _pump(tester, session: session, mutate: _canonicalSupplyFixture);
    await _showMaterialSummary(tester);
    await tester.tap(
      find.byKey(const ValueKey('material-aggregate-cancel-aggregate-action')),
    );
    await tester.pumpAndSettle();
    session.switchAccount('second-account');
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('确认整批撤回'),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests.where((r) => r.path.endsWith('/cancel')), isEmpty);
    expect(_notices(tester), contains('分析状态或撤回权限已变化'));
  });

  testWidgets('来源办理权限：撤回网络段切换账号后旧回包不得覆盖当前页面', (tester) async {
    final session = _OrderAuthoritySession();
    await _pump(
      tester,
      session: session,
      mutate: _canonicalSupplyFixture,
      requestObserver: (request) {
        if (request.path.endsWith('/cancel')) {
          session.switchAccount('second-account');
        }
      },
      aggregateCancel: (body, data) {
        final next = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
        next['version'] = (data['version'] as int) + 1;
        for (var i = 0; i < 3; i++) {
          _fixtureMaterial(next, 'shared-$i')['goodsName'] = '旧账号回包不得显示';
        }
        return next;
      },
    );
    await _showMaterialSummary(tester);
    await tester.tap(
      find.byKey(const ValueKey('material-aggregate-cancel-aggregate-action')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('确认整批撤回'),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests.where((r) => r.path.endsWith('/cancel')), hasLength(1));
    expect(find.textContaining('旧账号回包不得显示'), findsNothing);
    expect(_notices(tester), isNot(contains('整批任务已撤回')));
  });

  testWidgets('来源办理权限：普通供给待核对撤回在汇总入口仍可办理', (tester) async {
    await _pump(
      tester,
      mutate: (data) {
        final next = _canonicalSupplyFixture(data);
        final action = _records(next['supplyActions']).single;
        action['operationType'] = 'NOTIFY_SUPPLY';
        action['status'] = 'CANCELLED';
        for (var i = 0; i < 3; i++) {
          final ref = _records(
            _fixtureMaterial(next, 'canonical-$i')['downstreamReferences'],
          ).single;
          ref['status'] = 'CANCELLED';
          ref['notificationReversalPending'] = true;
        }
        return next;
      },
    );
    await _showMaterialSummary(tester);
    final button = find.byKey(
      const ValueKey('material-aggregate-cancel-aggregate-action'),
    );
    expect(button, findsOneWidget);
    expect(tester.widget<TextButton>(button).onPressed, isNotNull);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('撤回供给任务'), findsOneWidget);
  });

  testWidgets('来源办理权限：最大合法数量整批撤回保留精确万分位与公共份', (tester) async {
    await _pump(
      tester,
      mutate: (data) {
        final next = _canonicalSupplyFixture(data);
        final action = _records(next['supplyActions']).single;
        action['quantityFactsExact'] = {
          'requestedQty': '999999999999.9998',
          'publicSurplusQty': '0.0001',
          'safetyReplenishmentQty': '0',
        };
        for (var i = 0; i < 3; i++) {
          final ref = _records(
            _fixtureMaterial(next, 'canonical-$i')['downstreamReferences'],
          ).single;
          ref['quantityFactsExact'] = {
            'allocatedQty': i == 0 ? '999999999999.9998' : '0',
          };
        }
        return next;
      },
    );
    await _showMaterialSummary(tester);
    await tester.tap(
      find.byKey(const ValueKey('material-aggregate-cancel-aggregate-action')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('总量 999999999999.9999'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('公共备货 0.0001'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('来源办理权限：相同汇总物料的不同目标批次逐一显示且不重复', (tester) async {
    await _pump(
      tester,
      mutate: (data) {
        final next = _canonicalSupplyFixture(data);
        final original = _fixtureMaterial(next, 'shared-0');
        (original['aggregatePreparation'] as Map)['targetMaterialLineIds'] = [
          'canonical-0',
          'canonical-1',
        ];
        _records(
          _fixtureMaterial(next, 'canonical-0')['downstreamReferences'],
        ).single['actionId'] = 'another-action';
        (next['supplyActions'] as List).add({
          'actionId': 'another-action',
          'route': 'BUY',
          'operationType': 'AGGREGATE_SUPPLY',
          'requestedQty': 1000,
          'documentNo': 'CS-SECOND',
        });
        _records(next['supplyActions']).first['requestedQty'] = 2000;
        return next;
      },
    );
    await _showMaterialSummary(tester);
    expect(
      find.byKey(const ValueKey('material-aggregate-cancel-aggregate-action')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('material-aggregate-cancel-another-action')),
      findsOneWidget,
    );
  });
  testWidgets('来源办理权限：汇总预览途中换账号时旧预览不能继续提交', (tester) async {
    final session = _OrderAuthoritySession();
    final storage = MemoryFormDraftStorage();
    await _pump(
      tester,
      session: session,
      draftStorage: storage,
      requestObserver: (request) {
        if (request.path.endsWith('/aggregate-orders/preview')) {
          session.switchAccount('preview-changed');
        }
      },
    );
    final originalOwner = _materialDraftOwner(tester);
    await tester.enterText(_orderQty('m-2'), '500');
    await _settleRebuild(tester);
    await _check(tester, _rowCheckbox('m-2'));
    await tester.pumpAndSettle();
    await _submitSelected(tester);
    expect(
      requests.where((r) => r.path.endsWith('/aggregate-orders/preview')),
      isNotEmpty,
    );
    expect(_aggregateSubmits(), isEmpty);
    await _expectOriginalPreparationRetained(
      tester,
      session,
      storage: storage,
      owner: originalOwner,
    );
  });

  testWidgets('来源办理权限：汇总提交回包途中换账号不套用旧结果或报告假成功', (tester) async {
    final session = _OrderAuthoritySession();
    final storage = MemoryFormDraftStorage();
    await _pump(
      tester,
      session: session,
      draftStorage: storage,
      requestObserver: (request) {
        if (request.path.endsWith('/aggregate-orders/submit')) {
          session.switchAccount('submit-changed');
        }
      },
    );
    final originalOwner = _materialDraftOwner(tester);
    await tester.enterText(_orderQty('m-2'), '500');
    await _settleRebuild(tester);
    await _check(tester, _rowCheckbox('m-2'));
    await tester.pumpAndSettle();
    await _submitSelected(tester);
    expect(_aggregateSubmits(), hasLength(1));
    expect(_notices(tester), isNot(contains('已下达 1 笔')));
    final submitted = Map<String, dynamic>.from(
      _aggregateSubmits().single.body!,
    );
    await _expectOriginalPreparationRetained(
      tester,
      session,
      storage: storage,
      owner: originalOwner,
      submitted: submitted,
    );
    expect(_notices(tester), isNot(contains('已下达 1 笔')));
  });

  testWidgets('来源办理权限：网络不确定的原幂等请求不得换账号重放', (tester) async {
    final session = _OrderAuthoritySession();
    final storage = MemoryFormDraftStorage();
    await _pump(
      tester,
      session: session,
      draftStorage: storage,
      failOn: const {'/aggregate-orders/submit': 500},
    );
    final originalOwner = _materialDraftOwner(tester);
    await tester.enterText(_orderQty('m-2'), '500');
    await _settleRebuild(tester);
    await _check(tester, _rowCheckbox('m-2'));
    await tester.pumpAndSettle();
    await _submitSelected(tester);
    expect(_aggregateSubmits(), hasLength(1));
    final submitted = Map<String, dynamic>.from(
      _aggregateSubmits().single.body!,
    );
    final originalPayloads = await _ownedMaterialPayloads(
      storage,
      originalOwner,
    );
    final pendingBody = originalPayloads
        .where((payload) => payload['submittedBodyJson'] is String)
        .last['submittedBodyJson'];
    expect(
      originalPayloads.any((payload) => payload['uncertain'] == true),
      isTrue,
    );
    final queuedOldAction = tester
        .widget<UtenButton>(
          find.byKey(const Key('material-analysis-submit-orders')),
        )
        .onPressed;
    expect(queuedOldAction, isNotNull);
    session.switchAccount('retry-changed');
    await tester.pumpAndSettle();
    await _expectMaterialOwnerRetired(tester, storage, originalOwner);
    requests.clear();
    // An input event queued by the former visible button still cannot replay
    // its original business request under a different actor.
    await Future<void>.sync(queuedOldAction!);
    await tester.pumpAndSettle();
    expect(_aggregateSubmits(), isEmpty);
    expect(_notices(tester), isNot(contains('已下达 1 笔')));
    expect(find.text('登录身份或权限已变化，请重新打开分析。原输入和原请求保留在原账号下。'), findsOneWidget);
    final retained = await _ownedMaterialPayloads(storage, originalOwner);
    expect(
      retained.any(
        (payload) =>
            payload['uncertain'] == true &&
            payload['submittedBodyJson'] == pendingBody,
      ),
      isTrue,
    );
    await _expectOriginalPreparationRetained(
      tester,
      session,
      storage: storage,
      owner: originalOwner,
      submitted: submitted,
      submittedBodyJson: pendingBody as String,
    );
    expect(_aggregateSubmits(), isEmpty);
  });
  testWidgets('来源办理权限：已采用成功回执不会把下次新账号的新下单永久锁死', (tester) async {
    final session = _OrderAuthoritySession();
    final storage = MemoryFormDraftStorage();
    late Map<String, dynamic> accepted;
    await _pump(
      tester,
      session: session,
      draftStorage: storage,
      permissions: _overSupplyPermissions,
      overSupply: true,
      aggregateSubmit: (body, data) {
        final result = _defaultAggregateSubmit(body, data);
        accepted = result['analysis'] as Map<String, dynamic>;
        return result;
      },
    );
    await _check(tester, _rowCheckbox('m-2'));
    await tester.pumpAndSettle();
    final originalOwner = _materialDraftOwner(tester);
    await _submitSelected(tester);
    expect(_aggregateSubmits(), hasLength(1));
    session.switchAccount('next-order-account');
    await tester.pumpAndSettle();
    expect(find.textContaining('登录身份或权限已变化'), findsOneWidget);
    expect(_appendQty('m-2'), findsNothing);
    await _pump(
      tester,
      session: _OrderAuthoritySession(initialId: 'next-order-account'),
      draftStorage: storage,
      permissions: _overSupplyPermissions,
      overSupply: true,
      mutate: (_) => accepted,
    );
    expect(_materialDraftOwner(tester), isNot(originalOwner));
    await tester.enterText(_appendQty('m-2'), '25');
    await tester.pumpAndSettle();
    await _check(tester, _rowCheckbox('m-2'));
    await tester.pumpAndSettle();
    await _submitSelected(tester);
    expect(_aggregateSubmits(), hasLength(1));
    expect(
      _records(_aggregateSubmits().single.body!['groups']).single['qty'],
      '25',
    );
  });
  testWidgets('来源办理权限：纯安全补库批次用零分配来源完整撤回且不丢安全数量', (tester) async {
    await _pump(
      tester,
      mutate: (data) {
        final next = _canonicalSupplyFixture(data);
        final action = _records(next['supplyActions']).single;
        action['requestedQty'] = 0;
        action['publicSurplusQty'] = 0;
        action['safetyReplenishmentQty'] = 6;
        for (var i = 0; i < 3; i++) {
          _records(
            _fixtureMaterial(next, 'canonical-$i')['downstreamReferences'],
          ).single['allocatedQty'] = 0;
        }
        return next;
      },
    );
    await _showMaterialSummary(tester);
    await tester.tap(
      find.byKey(const ValueKey('material-aggregate-cancel-aggregate-action')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('总量 6，其中公共备货 0，安全补库 6'), findsOneWidget);
  });
}

class _OrderAuthoritySession extends SessionNotifier {
  _OrderAuthoritySession({this.initialId = 'first-account'});

  final String initialId;

  @override
  SessionState build() => SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: initialId, code: initialId, name: '计划员'),
  );

  void switchAccount(String id) {
    state = SessionState(
      status: AuthStatus.authenticated,
      user: AppUser(id: id, code: id, name: '计划乙'),
    );
  }
}
