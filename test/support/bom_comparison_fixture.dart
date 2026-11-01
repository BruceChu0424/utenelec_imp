import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_repository.dart';
import 'goods_bom_edit_test_api.dart';

class ComparisonFixtureBom extends Fake implements GoodsBomRepository {
  ComparisonFixtureBom(this.rows);
  final Map<String, List<GoodsBomItem>> rows;
  int writes = 0;

  @override
  Future<List<GoodsBomItem>> list(String id) async => List.of(rows[id] ?? []);

  @override
  Future<GoodsBomLearningSummary> learning(String id) async =>
      const GoodsBomLearningSummary();

  @override
  Future<GoodsBomItem> update(
    String goodsId,
    String itemId,
    Map<String, dynamic> body,
  ) async {
    writes++;
    final index = rows[goodsId]!.indexWhere((e) => e.id == itemId);
    final old = bomItemTestJson(rows[goodsId]![index]);
    for (final key in ['qty', 'price', 'total', 'basisOutputQty']) {
      if (body.containsKey(key)) old['${key}Text'] = body[key]?.toString();
    }
    final item = GoodsBomItem.fromJson({...old, ...body});
    rows[goodsId]![index] = item;
    return item;
  }

  @override
  Future<int> deleteMany(String goodsId, List<String> itemIds) async {
    writes++;
    rows[goodsId]!.removeWhere((e) => itemIds.contains(e.id));
    return itemIds.length;
  }

  @override
  Future<BomPasteResult> paste({
    required BomPasteMode mode,
    required List<BomPasteTarget> targets,
    required List<Map<String, dynamic>> items,
  }) async {
    writes++;
    for (final target in targets) {
      final into = rows.putIfAbsent(target.goodsId, () => []);
      if (mode == BomPasteMode.replace) into.clear();
      for (final item in items) {
        final component = item['componentGoodsId'] as String;
        into.add(
          GoodsBomItem.fromJson({
            'id': '${target.goodsId}-$component',
            'componentName': component,
            ...item,
          }),
        );
      }
    }
    return BomPasteResult(
      targets: targets.length,
      added: items.length,
      removed: 0,
    );
  }

  @override
  Future<int> move(String goodsId, List<GoodsBomMove> moves) async {
    writes++;
    for (final move in moves) {
      final into = rows[goodsId]!;
      final item = into.firstWhere(
        (e) => e.id == move.itemId || e.componentGoodsId == move.itemId,
      );
      into.remove(item);
      final anchor = move.anchorItemId == null
          ? into.length
          : into.indexWhere(
              (e) =>
                  e.id == move.anchorItemId ||
                  e.componentGoodsId == move.anchorItemId,
            );
      into.insert(anchor, item);
    }
    return moves.length;
  }
}

class ComparisonFixtureApi extends GoodsBomEditTestApi {
  ComparisonFixtureApi(super.repository);
  final requests = <Map<String, dynamic>>[];
  final snapshots = <String>[];
  bool loseCommitReply = false;
  Map<String, dynamic>? _saved;

  @override
  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query}) {
    if (path.endsWith('/snapshot')) {
      snapshots.add(path.split('/').reversed.elementAt(3));
    }
    return super.get(path, query: query);
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    requests.add(Map<String, dynamic>.from(body! as Map));
    if (path.endsWith('/commit') && _saved != null) {
      commitCalls++;
      return _saved!;
    }
    final response = await super.post(
      path,
      body: body,
      headers: headers,
      query: query,
    );
    if (path.endsWith('/commit') && loseCommitReply) {
      _saved = response;
      throw ApiException('NETWORK_TIMEOUT', '保存回执中断');
    }
    return response;
  }
}
