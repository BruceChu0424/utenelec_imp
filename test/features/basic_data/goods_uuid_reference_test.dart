import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';

void main() {
  test(
    'GoodsListItem keeps UUID defaults when new masters have no legacy id',
    () {
      final item = GoodsListItem.fromJson({
        'id': 'goods-uuid',
        'colorId': 'color-uuid',
        'colorLegacyId': null,
        'unitId': 'unit-uuid',
        'unitLegacyId': null,
      });

      expect(item.colorId, 'color-uuid');
      expect(item.unitId, 'unit-uuid');
      expect(item.colorLegacyId, isNull);
      expect(item.unitLegacyId, isNull);
    },
  );

  test('GoodsDetail parses UUID relations, legacy fallbacks and version', () {
    final detail = GoodsDetail.fromJson({
      'id': 'goods-1',
      'colorId': 'color-uuid',
      'colorLegacyId': 11,
      'unitId': 'unit-uuid',
      'unitLegacyId': 12,
      'thicknessUnitId': 'thickness-unit-uuid',
      'thicknessUnitLegacyId': 17,
      'mWeightUnitId': 'weight-unit-uuid',
      'mWeightUnitLegacyId': 18,
      'mouldId': 'mould-uuid',
      'mouldLegacyId': 13,
      'clientId': 'client-uuid',
      'clientLegacyId': 14,
      'defaultSupplierId': 'supplier-1-uuid',
      'vendLegacyId': 15,
      'secondarySupplierId': 'supplier-2-uuid',
      'vend2LegacyId': 16,
      'version': 7,
    });

    expect(detail.colorId, 'color-uuid');
    expect(detail.colorLegacyId, 11);
    expect(detail.unitId, 'unit-uuid');
    expect(detail.unitLegacyId, 12);
    expect(detail.thicknessUnitId, 'thickness-unit-uuid');
    expect(detail.thicknessUnitLegacyId, 17);
    expect(detail.mWeightUnitId, 'weight-unit-uuid');
    expect(detail.mWeightUnitLegacyId, 18);
    expect(detail.mouldId, 'mould-uuid');
    expect(detail.mouldLegacyId, 13);
    expect(detail.clientId, 'client-uuid');
    expect(detail.clientLegacyId, 14);
    expect(detail.defaultSupplierId, 'supplier-1-uuid');
    expect(detail.vendLegacyId, 15);
    expect(detail.secondarySupplierId, 'supplier-2-uuid');
    expect(detail.vend2LegacyId, 16);
    expect(detail.version, 7);
  });

  test('relationship body sends UUID only when both identifiers exist', () {
    const detail = GoodsDetail(
      id: 'goods-1',
      colorId: ' color-uuid ',
      colorLegacyId: 11,
      unitId: 'unit-uuid',
      unitLegacyId: 12,
      thicknessUnitId: 'thickness-unit-uuid',
      thicknessUnitLegacyId: 17,
      mWeightUnitId: 'weight-unit-uuid',
      mWeightUnitLegacyId: 18,
      mouldId: 'mould-uuid',
      mouldLegacyId: 13,
      clientId: 'client-uuid',
      clientLegacyId: 14,
      defaultSupplierId: 'supplier-1-uuid',
      vendLegacyId: 15,
      secondarySupplierId: 'supplier-2-uuid',
      vend2LegacyId: 16,
    );

    expect(goodsUuidFirstReferenceBody(detail), {
      'colorId': 'color-uuid',
      'unitId': 'unit-uuid',
      'thicknessUnitId': 'thickness-unit-uuid',
      'mWeightUnitId': 'weight-unit-uuid',
      'mouldId': 'mould-uuid',
      'clientId': 'client-uuid',
      'defaultSupplierId': 'supplier-1-uuid',
      'secondarySupplierId': 'supplier-2-uuid',
    });
  });

  test(
    'legacy-only values are local preservation markers, not API relations',
    () {
      const detail = GoodsDetail(
        id: 'goods-1',
        colorLegacyId: 11,
        unitLegacyId: 12,
        thicknessUnitLegacyId: 17,
        mWeightUnitLegacyId: 18,
        mouldLegacyId: 13,
        clientLegacyId: 14,
        vendLegacyId: 15,
        vend2LegacyId: 16,
      );

      final seed = goodsUuidFirstReferenceBody(detail);
      expect(seed, {
        'colorLegacyId': 11,
        'unitLegacyId': 12,
        'thicknessUnitLegacyId': 17,
        'mWeightUnitLegacyId': 18,
        'mouldLegacyId': 13,
        'clientLegacyId': 14,
        'vendLegacyId': 15,
        'vend2LegacyId': 16,
      });
      expect(normalizeGoodsUuidFirstBody(seed), isEmpty);
    },
  );

  test('form normalization removes only the shadowed legacy identifier', () {
    final body = normalizeGoodsUuidFirstBody({
      'colorId': ' color-uuid ',
      'colorLegacyId': 11,
      'unitId': null,
      'unitLegacyId': 12,
      'thicknessUnitId': ' thickness-unit-uuid ',
      'thicknessUnitLegacyId': 17,
      'mWeightUnitId': null,
      'mWeightUnitLegacyId': 18,
      'mouldId': null,
    });

    expect(body['colorId'], 'color-uuid');
    expect(body, isNot(contains('colorLegacyId')));
    expect(body, isNot(contains('unitId')));
    expect(body, isNot(contains('unitLegacyId')));
    expect(body['thicknessUnitId'], 'thickness-unit-uuid');
    expect(body, isNot(contains('thicknessUnitLegacyId')));
    expect(body, isNot(contains('mWeightUnitId')));
    expect(body, isNot(contains('mWeightUnitLegacyId')));
    expect(body, containsPair('mouldId', null));
  });

  test('cross-category paste always uses the currently selected target', () {
    expect(
      resolveGoodsSaveCategoryId(
        currentCategoryId: 'category-v6',
        sourceCategoryId: 'category-hp',
        copyMode: true,
      ),
      'category-v6',
    );
    expect(
      resolveGoodsSaveCategoryId(
        currentCategoryId: 'category-v6',
        sourceCategoryId: 'category-hp',
        requestedCategoryId: 'category-v7',
        copyMode: true,
      ),
      'category-v7',
    );
    expect(
      resolveGoodsSaveCategoryId(
        currentCategoryId: 'category-v6',
        sourceCategoryId: 'category-hp',
      ),
      'category-hp',
    );
  });
}
