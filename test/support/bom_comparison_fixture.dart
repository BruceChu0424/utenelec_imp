import 'dart:convert';
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
        final original = rows.values
            .expand((items) => items)
            .where((row) => row.componentGoodsId == component)
            .firstOrNull;
        final presentation = original == null
            ? <String, dynamic>{}
            : bomItemTestJson(original);
        into.add(
          GoodsBomItem.fromJson({
            'id': '${target.goodsId}-$component',
            'componentName': component,
            for (final key in const [
              'componentCode',
              'componentName',
              'componentModel',
              'componentSpec',
              'componentMaterial',
              'componentUnitName',
              'componentColorName',
              'componentSourceType',
              'componentIssueMethod',
            ])
              if (presentation.containsKey(key)) key: presentation[key],
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
  bool enforceSnapshots = false;
  String _fingerprint(String id) => jsonEncode(
    (repository as ComparisonFixtureBom).rows[id]
            ?.map(bomItemTestJson)
            .toList() ??
        [],
  );
  Map<String, dynamic>? _saved;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/snapshot')) {
      snapshots.add(path.split('/').reversed.elementAt(3));
    }
    final response = await super.get(path, query: query);
    if (path.endsWith('/snapshot') && repository is ComparisonFixtureBom) {
      final bom = repository as ComparisonFixtureBom;
      final id = path.split('/').reversed.elementAt(3);
      final all = bom.rows.values.expand((items) => items);
      Map<String, dynamic> master(String id) {
        final item = all.where((row) => row.componentGoodsId == id).firstOrNull;
        return {
          'id': id,
          'version': 1,
          'model': item?.componentModel,
          'spec': item?.componentSpec,
          'material': item?.componentMaterial,
          'sourceType': item?.componentSourceType,
          'componentGoodsWritable': true,
        };
      }

      return {
        ...response,
        if (enforceSnapshots) 'fingerprint': _fingerprint(id),
        'goods': master(id),
        'componentGoods': [
          for (final item in await bom.list(id)) master(item.componentGoodsId),
        ],
      };
    }
    return response;
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    requests.add(Map<String, dynamic>.from(body! as Map));
    if (enforceSnapshots) {
      for (final raw in (body as Map)['snapshots'] as List) {
        final snapshot = raw as Map;
        if (snapshot['fingerprint'] !=
            _fingerprint(snapshot['goodsId'] as String)) {
          throw ApiException('BOM_EDIT_CONFLICT', '快照已变化');
        }
      }
    }
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
    if (path.endsWith('/commit') && repository is ComparisonFixtureBom) {
      final bom = repository as ComparisonFixtureBom;
      final operations = (body as Map)['operations'] as List;
      for (final raw in operations) {
        final operation = Map<String, dynamic>.from(raw as Map);
        if (operation['type'] != 'UPDATE_GOODS') continue;
        final changes = Map<String, dynamic>.from(
          operation['goodsChanges'] as Map,
        );
        for (final parent in bom.rows.keys) {
          bom.rows[parent] = [
            for (final row in bom.rows[parent]!)
              row.componentGoodsId != operation['goodsId']
                  ? row
                  : GoodsBomItem.fromJson({
                      ...bomItemTestJson(row),
                      for (final entry in changes.entries)
                        'component${entry.key[0].toUpperCase()}${entry.key.substring(1)}':
                            entry.value,
                    }),
          ];
        }
        bom.writes++;
      }
    }
    if (path.endsWith('/commit') && loseCommitReply) {
      _saved = response;
      throw ApiException('NETWORK_TIMEOUT', '保存回执中断');
    }
    return response;
  }
}
