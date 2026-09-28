// ADR-134 master English / foreign names: DTO parsing contract
// (SPEC v2 section 5.8 goods list/detail nameEn, nameEnSource, canEditNameEn;
// client list/detail nameEn).
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/client_node.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';

void main() {
  test('goods list item carries the English name and its source', () {
    final item = GoodsListItem.fromJson({
      'id': 'goods-1',
      'name': '两开多功能三极插座',
      'nameEn': 'DOUBLE 3 PIN SOCKET',
      'nameEnSource': 'LEARNED',
    });

    expect(item.nameEn, 'DOUBLE 3 PIN SOCKET');
    expect(item.nameEnSource, GoodsNameEnSource.learned);
  });

  test('goods detail exposes the name-only edit capability fail-closed', () {
    final learned = GoodsDetail.fromJson({
      'id': 'goods-1',
      'nameEn': 'DOUBLE 3 PIN SOCKET',
      'nameEnSource': 'LEARNED',
      'canEditNameEn': true,
    });
    expect(learned.nameEn, 'DOUBLE 3 PIN SOCKET');
    expect(learned.nameEnLearned, isTrue);
    expect(learned.canEditNameEn, isTrue);

    final manual = GoodsDetail.fromJson({
      'id': 'goods-2',
      'nameEn': 'SOCKET',
      'nameEnSource': 'MANUAL',
      'canEditNameEn': 'true',
    });
    expect(manual.nameEnLearned, isFalse);
    // Anything but JSON true keeps the action hidden.
    expect(manual.canEditNameEn, isFalse);

    final older = GoodsDetail.fromJson({'id': 'goods-3'});
    expect(older.nameEn, isNull);
    expect(older.nameEnLearned, isFalse);
    expect(older.canEditNameEn, isFalse);
  });

  test('a learned source without a value is not shown as learned', () {
    final detail = GoodsDetail.fromJson({
      'id': 'goods-4',
      'nameEn': '  ',
      'nameEnSource': 'LEARNED',
    });
    expect(detail.nameEnLearned, isFalse);
  });

  test('client list item and detail carry the foreign name', () {
    final item = ClientListItem.fromJson({
      'id': 'client-1',
      'name': '尼日利亚SUNAS',
      'nameEn': 'SUNAS TRADING LIMITED',
    });
    final detail = ClientDetail.fromJson({
      'id': 'client-1',
      'name': '尼日利亚SUNAS',
      'nameEn': 'SUNAS TRADING LIMITED',
    });

    expect(item.nameEn, 'SUNAS TRADING LIMITED');
    expect(detail.nameEn, 'SUNAS TRADING LIMITED');
  });
}
