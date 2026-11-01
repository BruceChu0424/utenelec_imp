import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_comparison.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import '../../support/bom_comparison_fixture.dart';

GoodsBomItem _item(
  String id,
  String component, {
  String qty = '1',
  String? color,
  String? supplier,
  String? summary,
}) => GoodsBomItem(
  id: id,
  componentGoodsId: component,
  componentName: '同名组件',
  qty: double.parse(qty),
  qtyExactText: qty,
  colorId: color,
  defaultSupplierId: supplier,
  summary: summary,
);

Future<GoodsBomComparison> _compare(ComparisonFixtureBom bom) async =>
    GoodsBomComparison.build(
      leftId: 'left',
      rightId: 'right',
      left: await bom.list('left'),
      right: await bom.list('right'),
      isCurrent: () => true,
    );

void main() {
  test(
    'unresolved source legacy reference cannot silently clear target association',
    () async {
      final bom = ComparisonFixtureBom({
        'left': [_item('l', 'same', color: 'target-color')],
        'right': [
          const GoodsBomItem(
            id: 'r',
            componentGoodsId: 'same',
            qty: 1,
            colorLegacyId: 31,
          ),
        ],
      });
      final comparison = await _compare(bom);
      expect(comparison.rows.single.fields, contains('颜色'));
      final api = ComparisonFixtureApi(bom);
      await expectLater(
        comparison.prepare(
          toLeft: true,
          selected: {'same'},
          repository: bom,
          api: api,
          isCurrent: () => true,
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'BOM_COMPARE_REFERENCE_UNRESOLVED',
          ),
        ),
      );
      expect(bom.writes, 0);
      expect(api.previewCalls, 0);
    },
  );
  test(
    'UUID pairing, equivalent exact decimals and contextual facts',
    () async {
      final bom = ComparisonFixtureBom({
        'left': [_item('l1', 'same', qty: '0.100000'), _item('l2', 'x')],
        'right': [_item('r1', 'same', qty: '0.1'), _item('r2', 'y')],
      });
      final comparison = await _compare(bom);
      expect(comparison.count(BomDifference.same), 1);
      expect(comparison.count(BomDifference.leftOnly), 1);
      expect(comparison.count(BomDifference.rightOnly), 1);
      expect(comparison.count(BomDifference.changed), 0);
    },
  );

  test(
    'precise values, null color and supplier differences are explicit',
    () async {
      final bom = ComparisonFixtureBom({
        'left': [
          _item(
            'l',
            'same',
            qty: '1234567890123.12345',
            color: 'red',
            supplier: 'vendor',
          ),
        ],
        'right': [_item('r', 'same', qty: '1234567890123.12346')],
      });
      final row = (await _compare(bom)).rows.single;
      expect(row.fields, containsAll(['设计使用数量', '颜色', '默认供应商']));
    },
  );

  for (final toLeft in [true, false]) {
    test(
      'full replacement ${toLeft ? 'right to left' : 'left to right'} is previewed before atomic commit',
      () async {
        final bom = ComparisonFixtureBom({
          'left': [
            _item('l1', 'same', qty: '2', color: 'old', supplier: 'old-vendor'),
            _item('l2', 'left-only'),
          ],
          'right': [
            _item('r1', 'same', qty: '3.12345678901234567890'),
            _item('r2', 'right-only'),
          ],
        });
        final comparison = await _compare(bom);
        final api = ComparisonFixtureApi(bom);
        final replacement = await comparison.prepare(
          toLeft: toLeft,
          selected: null,
          repository: bom,
          api: api,
          isCurrent: () => true,
        );
        expect(replacement.added, 1);
        expect(replacement.removed, 1);
        expect(replacement.updated, 1);
        expect(api.snapshots, containsAll(['left', 'right']));
        expect(bom.writes, 0);
        final preview = await replacement.draft.preview();
        final request = api.requests.single;
        expect(
          (request['snapshots'] as List).map((e) => (e as Map)['goodsId']),
          containsAll(['left', 'right']),
        );
        expect(bom.writes, 0);
        await replacement.draft.commit(
          preview.previewToken,
          confirmSharedChanges: true,
        );
        final into = await bom.list(toLeft ? 'left' : 'right');
        final source = toLeft ? comparison.right : comparison.left;
        expect(
          into.map((e) => e.componentGoodsId),
          source.map((e) => e.componentGoodsId),
        );
        expect(into.first.qtyExactText, source.first.qtyExactText);
        expect(into.first.colorId, source.first.colorId);
        expect(into.first.defaultSupplierId, source.first.defaultSupplierId);
      },
    );
  }

  test(
    'partial replacement preserves unselected target-only components',
    () async {
      final bom = ComparisonFixtureBom({
        'left': [_item('l1', 'same', qty: '2'), _item('l2', 'keep')],
        'right': [_item('r1', 'same', qty: '3'), _item('r2', 'new')],
      });
      final replacement = await (await _compare(bom)).prepare(
        toLeft: true,
        selected: {'same'},
        repository: bom,
        api: ComparisonFixtureApi(bom),
        isCurrent: () => true,
      );
      expect(replacement.removed, 0);
      expect(replacement.added, 0);
      expect(replacement.updated, 1);
      expect(
        (await replacement.draft.list('left')).map((e) => e.componentGoodsId),
        ['same', 'keep'],
      );
      replacement.draft.close();
    },
  );

  for (final changedSide in ['left', 'right']) {
    test('stale $changedSide recipe is rejected before preview', () async {
      final bom = ComparisonFixtureBom({
        'left': [_item('l', 'same')],
        'right': [_item('r', 'same', qty: '2')],
      });
      final comparison = await _compare(bom);
      bom.rows[changedSide] = [
        _item(changedSide == 'left' ? 'l' : 'r', 'same', qty: '4'),
      ];
      final api = ComparisonFixtureApi(bom);
      await expectLater(
        comparison.prepare(
          toLeft: true,
          selected: null,
          repository: bom,
          api: api,
          isCurrent: () => true,
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'BOM_COMPARE_STALE',
          ),
        ),
      );
      expect(api.previewCalls, 0);
      expect(bom.writes, 0);
    });
  }

  test(
    'insertions do not mark shifted common rows as conflicts; real reorder does',
    () async {
      final bom = ComparisonFixtureBom({
        'left': [_item('la', 'a'), _item('lb', 'b')],
        'right': [_item('rx', 'x'), _item('ra', 'a'), _item('rb', 'b')],
      });
      expect((await _compare(bom)).count(BomDifference.changed), 0);
      bom.rows['right'] = [_item('rb', 'b'), _item('ra', 'a')];
      final comparison = await _compare(bom);
      expect(comparison.count(BomDifference.changed), 2);
      final replacement = await comparison.prepare(
        toLeft: true,
        selected: null,
        repository: bom,
        api: ComparisonFixtureApi(bom),
        isCurrent: () => true,
      );
      expect(
        (await replacement.draft.list('left')).map((e) => e.componentGoodsId),
        ['b', 'a'],
      );
      expect(replacement.moved, greaterThan(0));
      replacement.draft.close();
    },
  );

  test('empty source explicitly deletes all target components', () async {
    final bom = ComparisonFixtureBom({
      'left': [_item('l', 'a')],
      'right': [],
    });
    final replacement = await (await _compare(bom)).prepare(
      toLeft: true,
      selected: null,
      repository: bom,
      api: ComparisonFixtureApi(bom),
      isCurrent: () => true,
    );
    expect(replacement.removed, 1);
    expect(await replacement.draft.list('left'), isEmpty);
    replacement.draft.close();
  });

  test(
    'unknown commit retains original token; explicit recovery does not replay writes',
    () async {
      final bom = ComparisonFixtureBom({
        'left': [_item('l', 'same')],
        'right': [_item('r', 'same', qty: '2')],
      });
      final api = ComparisonFixtureApi(bom)..loseCommitReply = true;
      final replacement = await (await _compare(bom)).prepare(
        toLeft: true,
        selected: null,
        repository: bom,
        api: api,
        isCurrent: () => true,
      );
      final preview = await replacement.draft.preview();
      await expectLater(
        replacement.draft.commit(
          preview.previewToken,
          confirmSharedChanges: true,
        ),
        throwsA(isA<ApiException>()),
      );
      expect(replacement.draft.isCommitRecoveryPending, true);
      final writes = bom.writes;
      await replacement.draft.commit(
        preview.previewToken,
        confirmSharedChanges: true,
      );
      expect(api.previewCalls, 1);
      expect(api.commitCalls, 2);
      expect(bom.writes, writes);
      expect(api.requests[1], api.requests[2]);
    },
  );

  test(
    'large comparison yields and retains all rows; obsolete epoch cannot publish',
    () async {
      final items = List.generate(1200, (i) => _item('e$i', 'c$i'));
      final comparison = await GoodsBomComparison.build(
        leftId: 'l',
        rightId: 'r',
        left: items,
        right: [],
        isCurrent: () => true,
      );
      expect(comparison.rows.length, 1200);
      await expectLater(
        GoodsBomComparison.build(
          leftId: 'l',
          rightId: 'r',
          left: items,
          right: [],
          isCurrent: () => false,
        ),
        throwsA(isA<ApiException>()),
      );
    },
  );
}
