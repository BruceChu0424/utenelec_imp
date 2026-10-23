import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/features/basic_data/models/goods_issue_method.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_issue_method_repository.dart';
import 'package:uten_imp/features/warehouse/materialbin/widgets/workshop_material_first_use_card.dart';

class _Repository implements GoodsIssueMethodRepository {
  final calls = <({String goodsId, String target, String? basis})>[];
  final pending = <int, Completer<GoodsIssueMethodPreview>>{};
  GoodsIssueMethodPreview Function(String, String?)? response;
  int applyCalls = 0;

  @override
  Future<GoodsIssueMethodPreview> preview(
    String goodsId, {
    required String target,
    String? costBasis,
  }) async {
    final index = calls.length;
    calls.add((goodsId: goodsId, target: target, basis: costBasis));
    if (pending[index] case final completion?) return completion.future;
    return response?.call(goodsId, costBasis) ?? _preview(goodsId, costBasis);
  }

  @override
  Future<void> apply(List<GoodsIssueMethodChange> items) async {
    applyCalls++;
    throw StateError('First-use cards may only preview and acknowledge');
  }
}

GoodsIssueMethodPreview _preview(
  String goodsId,
  String? basis, {
  int? version = 17,
  bool canSwitch = true,
  bool massUnit = true,
  List<GoodsIssueMethodBomRow> bomRows = const [],
  List<String> blockers = const [],
  String target = 'PERIODIC',
}) => GoodsIssueMethodPreview(
  goodsId: goodsId,
  targetIssueMethod: target,
  targetCostBasis: basis,
  version: version,
  canSwitch: canSwitch,
  massUnit: massUnit,
  bomRows: bomRows,
  blockers: blockers,
);

Map<String, dynamic> _setup(String basis, {int version = 17}) => {
  'goodsId': 'goods',
  'expectedVersion': version,
  'periodicCostBasis': basis,
};

class _Host {
  Map<String, dynamic>? initialSetup;
  int? expectedVersion;
  String? fixedBasis;
  String goodsId = 'goods';
  bool enabled = true;
  bool canConfigure = true;
  bool approvalContext = false;
  late VoidCallback rebuild;
  final changes = <Map<String, dynamic>?>[];
}

Future<_Host> _mount(
  WidgetTester tester,
  _Repository repository, {
  Map<String, dynamic>? initialSetup,
  int? expectedVersion,
  String? fixedBasis,
  bool approvalContext = false,
  bool settle = true,
}) async {
  tester.view.physicalSize = const Size(1100, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final host = _Host()
    ..initialSetup = initialSetup
    ..expectedVersion = expectedVersion
    ..fixedBasis = fixedBasis
    ..approvalContext = approvalContext;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        goodsIssueMethodRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: StatefulBuilder(
              builder: (context, setHostState) {
                host.rebuild = () => setHostState(() {});
                return WorkshopMaterialFirstUseCard(
                  goodsId: host.goodsId,
                  goodsName: '材料',
                  enabled: host.enabled,
                  canConfigure: host.canConfigure,
                  expectedVersion: host.expectedVersion,
                  fixedBasis: host.fixedBasis,
                  initialSetup: host.initialSetup,
                  approvalContext: host.approvalContext,
                  onChanged: (value) => host.changes.add(
                    value == null ? null : Map<String, dynamic>.from(value),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  expect(tester.takeException(), isNull);
  return host;
}

CheckboxListTile _checkbox(WidgetTester tester, [String goodsId = 'goods']) =>
    tester.widget<CheckboxListTile>(
      find.byKey(ValueKey('wm-first-use-confirm-$goodsId')),
    );

String? _basis(WidgetTester tester, [String goodsId = 'goods']) => tester
    .widget<UtenDropdownField>(
      find.byKey(ValueKey('wm-first-use-basis-$goodsId')),
    )
    .value;

Future<void> _confirm(WidgetTester tester) async {
  final checkbox = find.byKey(const ValueKey('wm-first-use-confirm-goods'));
  await tester.ensureVisible(checkbox);
  await tester.tap(checkbox);
  await tester.pumpAndSettle();
}

void main() {
  for (final basis in ['SHARED', 'EXPENSE']) {
    testWidgets(
      'restored $basis is displayed and previewed without adopting old acknowledgement',
      (tester) async {
        final repository = _Repository();
        final host = await _mount(
          tester,
          repository,
          initialSetup: _setup(basis),
        );
        expect(_basis(tester), basis);
        expect(repository.calls.single, (
          goodsId: 'goods',
          target: 'PERIODIC',
          basis: basis,
        ));
        expect(_checkbox(tester).value, isFalse);
        expect(_checkbox(tester).onChanged, isNotNull);
        expect(host.changes, everyElement(isNull));
        await _confirm(tester);
        expect(host.changes.last, _setup(basis));
        expect(repository.applyCalls, 0);
      },
    );
  }

  testWidgets(
    'changed saved version requires a new acknowledgement of the latest preview',
    (tester) async {
      final repository = _Repository();
      final host = await _mount(
        tester,
        repository,
        initialSetup: _setup('SHARED', version: 9),
      );
      expect(
        find.byKey(const ValueKey('wm-first-use-restored-version-goods')),
        findsOneWidget,
      );
      expect(_checkbox(tester).value, isFalse);
      expect(host.changes, everyElement(isNull));
      await _confirm(tester);
      expect(host.changes.last, _setup('SHARED'));
    },
  );

  testWidgets(
    'stock-count approval keeps its fixed expected version hard boundary',
    (tester) async {
      final repository = _Repository();
      final host = await _mount(
        tester,
        repository,
        initialSetup: _setup('EXPENSE', version: 9),
        expectedVersion: 9,
        fixedBasis: 'EXPENSE',
        approvalContext: true,
      );
      expect(_basis(tester), 'EXPENSE');
      expect(_checkbox(tester).onChanged, isNull);
      expect(find.textContaining('申请后货品版本已变化'), findsOneWidget);
      expect(host.changes, everyElement(isNull));
    },
  );

  final malformed = <String, Map<String, dynamic>>{
    'foreign goods': {..._setup('SHARED'), 'goodsId': 'other'},
    'foreign target': {..._setup('SHARED'), 'target': 'ORDER'},
    'foreign target method': {
      ..._setup('SHARED'),
      'targetIssueMethod': 'ORDER',
    },
    'unknown basis': {..._setup('SHARED'), 'periodicCostBasis': 'OTHER'},
    'missing version': {'goodsId': 'goods', 'periodicCostBasis': 'SHARED'},
    'negative version': _setup('SHARED', version: -1),
  };
  for (final entry in malformed.entries) {
    testWidgets('${entry.key} cannot silently supply a recovered purpose', (
      tester,
    ) async {
      final repository = _Repository();
      final host = await _mount(tester, repository, initialSetup: entry.value);
      expect(_basis(tester), 'OWN');
      expect(
        find.byKey(const ValueKey('wm-first-use-restore-invalid-goods')),
        findsOneWidget,
      );
      expect(_checkbox(tester).value, isFalse);
      expect(_checkbox(tester).onChanged, isNull);
      expect(host.changes, everyElement(isNull));
      await tester.tap(
        find.byKey(const ValueKey('wm-first-use-refresh-goods')),
      );
      await tester.pumpAndSettle();
      expect(_checkbox(tester).onChanged, isNotNull);
      await _confirm(tester);
      expect(host.changes.last, _setup('OWN'));
    });
  }

  final invalidPreviews = <String, GoodsIssueMethodPreview>{
    'foreign goods': _preview('foreign', 'SHARED'),
    'foreign target': _preview('goods', 'SHARED', target: 'ORDER'),
    'foreign basis': _preview('goods', 'OWN'),
    'missing version': _preview('goods', 'SHARED', version: null),
    'cannot switch': _preview('goods', 'SHARED', canSwitch: false),
    'not a mass unit': _preview('goods', 'SHARED', massUnit: false),
    'service blocker': _preview('goods', 'SHARED', blockers: const ['未清账']),
    'blocked BOM row': _preview(
      'goods',
      'SHARED',
      bomRows: const [GoodsIssueMethodBomRow(action: 'BLOCKED')],
    ),
  };
  for (final entry in invalidPreviews.entries) {
    testWidgets(
      'fresh ${entry.key} preview cannot authorize a restored purpose',
      (tester) async {
        final repository = _Repository()..response = (_, basis) => entry.value;
        final host = await _mount(
          tester,
          repository,
          initialSetup: _setup('SHARED'),
        );
        expect(_checkbox(tester).value, isFalse);
        expect(_checkbox(tester).onChanged, isNull);
        expect(host.changes, everyElement(isNull));
      },
    );
  }

  testWidgets(
    'late initialSetup arrival resets an existing acknowledgement and re-previews',
    (tester) async {
      final repository = _Repository();
      final host = await _mount(tester, repository);
      await _confirm(tester);
      expect(host.changes.last, _setup('OWN'));
      host.initialSetup = _setup('EXPENSE');
      host.rebuild();
      await tester.pumpAndSettle();
      expect(repository.calls.last.basis, 'EXPENSE');
      expect(_basis(tester), 'EXPENSE');
      expect(_checkbox(tester).value, isFalse);
      expect(host.changes.last, isNull);
      await _confirm(tester);
      expect(host.changes.last, _setup('EXPENSE'));
    },
  );

  testWidgets(
    'equal parent rebuilds preserve a new user acknowledgement without extra reads',
    (tester) async {
      final repository = _Repository();
      final host = await _mount(
        tester,
        repository,
        initialSetup: _setup('SHARED'),
      );
      await _confirm(tester);
      host.initialSetup = _setup('SHARED');
      host.rebuild();
      await tester.pumpAndSettle();
      expect(repository.calls, hasLength(1));
      expect(_checkbox(tester).value, isTrue);
      expect(host.changes.last, _setup('SHARED'));
    },
  );

  testWidgets(
    'late preview from a former restored purpose cannot overwrite the new preview',
    (tester) async {
      final old = Completer<GoodsIssueMethodPreview>();
      final latest = Completer<GoodsIssueMethodPreview>();
      final repository = _Repository()..pending.addAll({0: old, 1: latest});
      final host = await _mount(
        tester,
        repository,
        initialSetup: _setup('SHARED'),
        settle: false,
      );
      expect(repository.calls, hasLength(1));
      host.initialSetup = _setup('EXPENSE', version: 22);
      host.rebuild();
      await tester.pump();
      expect(repository.calls, hasLength(2));
      latest.complete(_preview('goods', 'EXPENSE', version: 22));
      await tester.pumpAndSettle();
      old.complete(_preview('goods', 'SHARED', version: 9));
      await tester.pumpAndSettle();
      expect(_basis(tester), 'EXPENSE');
      expect(_checkbox(tester).value, isFalse);
      expect(host.changes, everyElement(isNull));
      await _confirm(tester);
      expect(host.changes.last, _setup('EXPENSE', version: 22));
    },
  );
}
