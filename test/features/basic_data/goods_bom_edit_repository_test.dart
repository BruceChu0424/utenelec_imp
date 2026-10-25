import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_edit_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_repository.dart';

void main() {
  test(
    'component master edits merge one optimistic command and share snapshots',
    () async {
      final api = _DraftApi();
      final draft = _draft(api);
      await draft.list('frame');
      await draft.updateGoods('screw', {'model': '新型号'});
      await draft.updateGoods('screw', {'spec': '新规格', 'material': 'PC'});
      expect(draft.operationCount, 1);
      final updated = (await draft.list('frame')).single;
      expect(updated.componentModel, '新型号');
      expect(updated.componentSpec, '新规格');
      expect(updated.componentMaterial, 'PC');
      expect(api.commands, isEmpty);
      await draft.preview();
      final operation =
          (api.commands.single.$2['operations'] as List).single as Map;
      expect(operation['type'], 'UPDATE_GOODS');
      expect(operation['goodsId'], 'screw');
      expect(operation['goodsVersion'], 4);
      expect(operation['goodsChanges'], {
        'model': '新型号',
        'spec': '新规格',
        'material': 'PC',
      });
      expect(
        (api.commands.single.$2['snapshots'] as List).map(
          (snapshot) => (snapshot as Map<String, dynamic>)['goodsId'],
        ),
        contains('screw'),
      );
    },
  );

  test(
    'reverting component master input removes its pending operation',
    () async {
      final draft = _draft(_DraftApi());
      await draft.updateGoods('screw', {'model': '新型号'});
      await draft.updateGoods('screw', {'model': '旧型号'});
      expect(draft.hasChanges, isFalse);
    },
  );

  test(
    'master edits reject missing authority and unsupported fields',
    () async {
      final draft = _draft(_DraftApi()..masterWritable = false);
      await expectLater(
        draft.updateGoods('screw', {'model': '新型号'}),
        throwsA(isA<ApiException>()),
      );
      await expectLater(
        draft.updateGoods('screw', {'code': 'OVERRIDE'}),
        throwsA(isA<ApiException>()),
      );
      expect(draft.hasChanges, isFalse);
    },
  );

  test(
    'component replacement keeps the relation and stages no canonical writes',
    () async {
      final api = _DraftApi()..richEvidence = true;
      final draft = _draft(api);
      final original = (await draft.list('frame')).single;
      final replaced = await draft.update('frame', original.id, {
        'componentGoodsId': 'nut',
        'qty': original.qty,
        'summary': '保留装配用量',
      });
      expect(replaced.id, original.id);
      expect(replaced.componentGoodsId, 'nut');
      expect(replaced.componentName, '名称 nut');
      expect(replaced.qty, original.qty);
      expect(replaced.actual.qty, isNull);
      expect(replaced.actual.sampleCount, 0);
      expect(replaced.audited, isFalse);
      expect(replaced.systemLearned, isFalse);
      expect(
        replaced.price,
        isNull,
        reason: 'the old component price must not carry forward',
      );
      expect(api.commands, isEmpty);
      final preview = await draft.preview();
      final operation =
          (api.commands.single.$2['operations'] as List).single as Map;
      expect(operation['type'], 'UPDATE');
      expect(operation['goodsId'], 'frame');
      expect(operation['itemId'], original.id);
      await draft.commit(preview.previewToken, confirmSharedChanges: true);
      expect(api.commands.last.$1, endsWith('/commit'));
    },
  );

  test(
    'discarded replacement leaves the canonical snapshot and identity intact',
    () async {
      final api = _DraftApi();
      final draft = _draft(api);
      await draft.update('frame', 'screw-edge', {
        'componentGoodsId': 'nut',
        'qty': 2,
      });
      draft.close();
      final reopened = _draft(api);
      final row = (await reopened.list('frame')).single;
      expect(row.id, 'screw-edge');
      expect(row.componentGoodsId, 'screw');
      expect(api.commands, isEmpty);
    },
  );

  test(
    'duplicate or self-referencing replacements roll back the whole draft mutation',
    () async {
      final draft = _draft(_DraftApi());
      await draft.paste(
        mode: BomPasteMode.append,
        targets: [const BomPasteTarget('frame')],
        items: [
          {'componentGoodsId': 'nut', 'qty': 1},
        ],
      );
      await expectLater(
        draft.update('frame', 'screw-edge', {
          'componentGoodsId': 'nut',
          'qty': 2,
        }),
        throwsA(isA<ApiException>()),
      );
      await expectLater(
        draft.update('frame', 'screw-edge', {
          'componentGoodsId': 'frame',
          'qty': 2,
        }),
        throwsA(isA<ApiException>()),
      );
      expect((await draft.list('frame')).first.componentGoodsId, 'screw');
      expect(draft.operationCount, 1);
    },
  );

  test(
    'a periodic replacement recomputes grams and fixes the periodic shape',
    () async {
      final api = _DraftApi()..richEvidence = true;
      api.componentDetails['resin'] = {
        'unitName': '千克',
        'issueMethod': 'PERIODIC',
      };
      final draft = _draft(api);
      final row = await draft.update('frame', 'screw-edge', {
        'componentGoodsId': 'resin',
        'unitWeightGrams': 2.5,
      });
      expect(row.componentGoodsId, 'resin');
      expect(row.isPeriodicEdge, isTrue);
      expect(row.qty, closeTo(0.0025, 0.00000001));
      expect(row.unitWeightGrams, 2.5);
      expect(row.consumptionBasis, BomConsumptionBasis.perUnit);
      expect(row.basisOutputQty, 1);
      expect(row.hardGate, isFalse);
      expect(row.actual.qty, isNull);
      expect(api.commands, isEmpty);
    },
  );

  test(
    'multi-picker append rejects a later duplicate without retaining earlier rows',
    () async {
      final draft = _draft(_DraftApi());
      await draft.list('frame');
      await expectLater(
        draft.paste(
          mode: BomPasteMode.append,
          targets: [const BomPasteTarget('frame')],
          items: [
            {'componentGoodsId': 'nut', 'qty': 1},
            {'componentGoodsId': 'screw', 'qty': 1},
          ],
        ),
        throwsA(isA<ApiException>()),
      );
      expect((await draft.list('frame')).map((row) => row.componentGoodsId), [
        'screw',
      ]);
      expect(draft.hasChanges, isFalse);
    },
  );

  test('concurrent occurrences share one snapshot request per goods', () async {
    final api = _DraftApi()
      ..pendingSnapshot = Completer<Map<String, dynamic>>();
    final draft = _draft(api);
    final reads = [
      draft.list('frame'),
      draft.list('frame'),
      draft.list('frame'),
    ];
    await Future<void>.delayed(Duration.zero);
    expect(api.snapshotCalls, ['frame']);
    api.pendingSnapshot!.complete({
      'items': [_row('same-edge', 'screw')],
      'fingerprint': 'same',
    });
    final results = await Future.wait(reads);
    expect(results.map((rows) => rows.single.id), everyElement('same-edge'));
    expect(api.snapshotCalls, ['frame']);
  });

  test(
    'large snapshot conversions yield event turns and reject revoked state',
    () async {
      final api = _DraftApi()
        ..pendingSnapshot = Completer<Map<String, dynamic>>();
      var current = true;
      final draft = _draft(api, isCurrent: () => current);
      final read = draft.list('root');
      await Future<void>.delayed(Duration.zero);
      var inputHandled = false;
      Timer.run(() {
        inputHandled = true;
        current = false;
      });
      final failed = expectLater(read, throwsA(isA<ApiException>()));
      api.pendingSnapshot!.complete({
        'items': [for (var i = 0; i < 2048; i++) _row('edge-$i', 'item-$i')],
        'fingerprint': 'large',
      });
      await failed;
      expect(inputHandled, isTrue);
      expect(draft.operationCount, 0);
      expect(api.commands, isEmpty);
    },
  );

  test('nested edits remain a draft until the reviewed commit', () async {
    final api = _DraftApi();
    final draft = _draft(api);
    await draft.list('root');
    await draft.list('frame');
    await draft.update('frame', 'screw-edge', {'qty': 4});
    expect((await draft.list('frame')).single.qty, 4);
    expect(api.commands, isEmpty);
    final preview = await draft.preview();
    expect(preview.otherUsageCount, 3);
    expect(api.commands.single.$1, endsWith('/root/bom/edit/preview'));
    final body = api.commands.single.$2;
    expect(
      (body['operations'] as List).cast<Map<String, dynamic>>().single['body'],
      containsPair('componentGoodsId', 'screw'),
    );
    expect(
      (body['operations'] as List)
          .cast<Map<String, dynamic>>()
          .single['goodsId'],
      'frame',
    );
    expect(
      (body['snapshots'] as List).cast<Map<String, dynamic>>().map(
        (r) => r['goodsId'],
      ),
      containsAll(['root', 'frame']),
    );
    await draft.commit(preview.previewToken, confirmSharedChanges: true);
    expect(api.commands.last.$1, endsWith('/commit'));
    expect(api.commands.last.$2['confirmSharedChanges'], isTrue);
    expect(draft.hasChanges, isFalse);
    await expectLater(draft.list('root'), throwsA(isA<ApiException>()));
  });

  test(
    'multiple pasted components create unique identities for later moves and edits',
    () async {
      final api = _DraftApi();
      final draft = _draft(api);
      await draft.list('root');
      final result = await draft.paste(
        mode: BomPasteMode.append,
        targets: [const BomPasteTarget('frame')],
        items: [
          {'componentGoodsId': 'nut', 'qty': 2, 'summary': '紧固'},
          {'componentGoodsId': 'washer', 'qty': 3},
        ],
      );
      expect(result.added, 2);
      final rows = await draft.list('frame');
      expect(rows, hasLength(3));
      final nut = rows.firstWhere((r) => r.componentGoodsId == 'nut');
      final washer = rows.firstWhere((r) => r.componentGoodsId == 'washer');
      expect(nut.id, isNot(washer.id));
      expect(nut.componentName, '名称 nut');
      await draft.update('frame', nut.id, {'qty': 6});
      await draft.move('root', [
        GoodsBomMove(itemId: nut.id, targetParentGoodsId: 'root'),
      ]);
      expect((await draft.list('frame')).any((r) => r.id == nut.id), isFalse);
      expect((await draft.list('root')).last.qty, 6);
      expect(api.commands, isEmpty);
      await draft.preview();
      final operations = (api.commands.single.$2['operations'] as List)
          .cast<Map<String, dynamic>>();
      expect(operations[0]['clientItemId'], nut.id);
      expect(operations[2]['itemId'], nut.id);
      expect(
        (operations[3]['moves'] as List)
            .cast<Map<String, dynamic>>()
            .single['itemId'],
        nut.id,
      );
    },
  );

  test(
    'a failed batch paste leaves the entire local draft unchanged',
    () async {
      final draft = _draft(_DraftApi());
      await draft.list('root');
      await expectLater(
        draft.paste(
          mode: BomPasteMode.append,
          targets: [const BomPasteTarget('frame')],
          items: [
            {'componentGoodsId': 'nut', 'qty': 2},
            {'componentGoodsId': 'screw', 'qty': 1},
          ],
        ),
        throwsA(isA<ApiException>()),
      );
      expect((await draft.list('frame')).map((r) => r.componentGoodsId), [
        'screw',
      ]);
      expect(draft.operationCount, 0);
    },
  );

  test('changed draft invalidates its previous confirmation', () async {
    final api = _DraftApi();
    final draft = _draft(api);
    await draft.update('frame', 'screw-edge', {'qty': 2});
    final preview = await draft.preview();
    await draft.update('frame', 'screw-edge', {'qty': 3});
    await expectLater(
      draft.commit(preview.previewToken, confirmSharedChanges: true),
      throwsA(isA<ApiException>()),
    );
    expect(api.commands, hasLength(1));
    expect(draft.hasChanges, isTrue);
  });

  test(
    'server rejection retains pending edits and permits another preview',
    () async {
      final api = _DraftApi()..rejectCommit = true;
      final draft = _draft(api);
      await draft.update('frame', 'screw-edge', {'qty': 2});
      final preview = await draft.preview();
      await expectLater(
        draft.commit(preview.previewToken, confirmSharedChanges: true),
        throwsA(isA<ApiException>()),
      );
      expect(draft.hasChanges, isTrue);
      expect((await draft.list('frame')).single.qty, 2);
      await draft.preview();
      expect(api.commands.last.$1, endsWith('/preview'));
    },
  );

  test(
    'identity change during a read cannot adopt the returned snapshot',
    () async {
      var current = true;
      final api = _DraftApi()
        ..pendingSnapshot = Completer<Map<String, dynamic>>();
      final draft = _draft(api, isCurrent: () => current);
      final read = draft.list('root');
      await Future<void>.delayed(Duration.zero);
      current = false;
      final result = expectLater(read, throwsA(isA<ApiException>()));
      api.pendingSnapshot!.complete({
        'items': [_row('frame-edge', 'frame')],
        'fingerprint': 'before',
      });
      await result;
      expect(api.commands, isEmpty);
    },
  );

  test(
    'periodic weight draft uses the component base unit and clears the audit mark',
    () async {
      final api = _DraftApi();
      api.periodic = true;
      final draft = _draft(api);
      final row = await draft.update('frame', 'screw-edge', {
        'unitWeightGrams': 40,
      });
      expect(row.qty, .04);
      expect(row.periodicUnitWeightGrams, 40);
      expect(row.audited, isFalse);
    },
  );

  test(
    'copied assembly does not inherit another parent actual usage or audit',
    () async {
      final api = _DraftApi();
      final draft = _draft(api);
      draft.rememberItems([
        GoodsBomItem(
          id: 'source-relation',
          componentGoodsId: 'nut',
          componentName: '螺母',
          qty: 3,
          auditedAt: DateTime.utc(2026),
          systemLearned: true,
          actual: const BomActualUsage(qty: 7, usesActual: true),
        ),
      ]);
      await draft.paste(
        mode: BomPasteMode.append,
        targets: [const BomPasteTarget('root')],
        items: [
          {'componentGoodsId': 'nut', 'qty': 3},
        ],
      );
      final row = (await draft.list('root')).last;
      expect(row.componentName, '螺母');
      expect(row.systemLearned, isFalse);
      expect(row.audited, isFalse);
      expect(row.actual.qty, isNull);
      expect(row.actual.usesActual, isFalse);
    },
  );
  test('lost commit response retries the identical reviewed token', () async {
    final api = _DraftApi()..loseCommitResponse = true;
    final draft = _draft(api);
    await draft.update('frame', 'screw-edge', {'qty': 2});
    final preview = await draft.preview();
    await expectLater(
      draft.commit(preview.previewToken, confirmSharedChanges: true),
      throwsA(isA<NetworkTimeoutException>()),
    );
    await expectLater(
      draft.update('frame', 'screw-edge', {'qty': 3}),
      throwsA(isA<ApiException>()),
    );
    final retry = await draft.preview();
    // Expanding another assembly while recovering must not alter the request
    // that the successful server receipt was bound to.
    await draft.list('washer');
    expect(retry.previewToken, preview.previewToken);
    expect(api.commands.where((r) => r.$1.endsWith('/preview')), hasLength(1));
    await draft.commit(retry.previewToken, confirmSharedChanges: true);
    final commits = api.commands
        .where((r) => r.$1.endsWith('/commit'))
        .toList();
    expect(commits, hasLength(2));
    expect(commits[0].$2['previewToken'], commits[1].$2['previewToken']);
    expect(commits[0].$2, commits[1].$2);
  });

  test(
    'moving between parents clears old actual, audit and learning evidence',
    () async {
      final api = _DraftApi()..richEvidence = true;
      final draft = _draft(api);
      await draft.list('root');
      final before = (await draft.list('frame')).single;
      expect(before.audited, isTrue);
      expect(before.systemLearned, isTrue);
      expect(before.actual.qty, 7);
      await draft.move('root', [
        const GoodsBomMove(itemId: 'screw-edge', targetParentGoodsId: 'root'),
      ]);
      final moved = (await draft.list('root')).last;
      expect(moved.audited, isFalse);
      expect(moved.systemLearned, isFalse);
      expect(moved.actual.qty, isNull);
      expect(moved.actual.sampleCount, 0);
      expect(moved.actual.usesActual, isFalse);
    },
  );

  test(
    'same-parent ordering retains evidence and notes retain learning ownership',
    () async {
      final api = _DraftApi()..richEvidence = true;
      final draft = _draft(api);
      await draft.move('frame', [
        const GoodsBomMove(itemId: 'screw-edge', targetParentGoodsId: 'frame'),
      ]);
      final ordered = (await draft.list('frame')).single;
      expect(ordered.audited, isTrue);
      expect(ordered.actual.qty, 7);
      expect(ordered.systemLearned, isTrue);
      final note = await draft.update('frame', 'screw-edge', {'summary': '备注'});
      expect(note.systemLearned, isTrue);
      final color = await draft.update('frame', 'screw-edge', {
        'colorId': 'new-color',
      });
      expect(color.systemLearned, isFalse);
    },
  );

  test(
    'known descendant cycle is rejected before hiding a moved row',
    () async {
      final draft = _draft(_DraftApi());
      await draft.list('root');
      await draft.list('frame');
      await expectLater(
        draft.move('root', [
          const GoodsBomMove(
            itemId: 'frame-edge',
            targetParentGoodsId: 'screw',
          ),
        ]),
        throwsA(isA<ApiException>()),
      );
      expect((await draft.list('root')).single.id, 'frame-edge');
      expect(await draft.list('screw'), isEmpty);
      expect(draft.hasChanges, isFalse);
    },
  );
}

GoodsBomEditDraft _draft(_DraftApi api, {bool Function()? isCurrent}) =>
    GoodsBomEditDraft(
      base: _UnusedBase(),
      api: api,
      rootGoodsId: 'root',
      isCurrent: isCurrent,
    );

Map<String, dynamic> _row(String id, String component) => {
  'id': id,
  'componentGoodsId': component,
  'componentName': '名称 $component',
  'qty': 1,
  'price': 2,
  'controlStage': 'START',
  'consumptionBasis': 'PER_UNIT',
  'hasChildren': component == 'frame',
};

class _DraftApi extends ApiClient {
  _DraftApi() : super(Dio());

  final commands = <(String, Map<String, dynamic>)>[];
  final snapshotCalls = <String>[];
  final componentDetails = <String, Map<String, dynamic>>{};
  bool rejectCommit = false;
  bool loseCommitResponse = false;
  bool periodic = false;
  bool richEvidence = false;
  bool masterWritable = true;
  Completer<Map<String, dynamic>>? pendingSnapshot;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/snapshot')) {
      final goodsId = path.split('/').reversed.elementAt(3);
      snapshotCalls.add(goodsId);
      if (pendingSnapshot != null) return pendingSnapshot!.future;
      return {
        'items': switch (goodsId) {
          'root' => [_row('frame-edge', 'frame')],
          'frame' => [
            {
              ..._row('screw-edge', 'screw'),
              if (richEvidence) ...{
                'systemLearned': true,
                'auditedAt': '2026-01-01T00:00:00Z',
                'actualQty': 7,
                'actualSampleCount': 3,
                'usageBasis': 'ACTUAL',
                'actualOutputQty': 100,
                'actualNetQty': 700,
              },
              if (periodic) ...{
                'componentIssueMethod': 'PERIODIC',
                'componentUnitName': '千克',
              },
            },
          ],
          _ => <Map<String, dynamic>>[],
        },
        'fingerprint': 'snapshot-$goodsId',
        'goods': {
          'id': goodsId,
          'version': 4,
          'model': '旧型号',
          'spec': null,
          'material': null,
          'sourceType': '采购',
          'componentGoodsWritable': masterWritable,
        },
      };
    }
    final id = path.split('/').last;
    return {
      'id': id,
      'name': '名称 $id',
      'unitName': '个',
      'issueMethod': 'ORDER',
      ...?componentDetails[id],
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    commands.add((path, Map<String, dynamic>.from(body! as Map)));
    if (path.endsWith('/preview')) {
      return {
        'previewToken': 'review-${commands.length}',
        'operationCount': 1,
        'affectedParents': [
          {'goodsId': 'frame', 'goodsName': '铁架', 'otherUsageCount': 3},
        ],
        'otherUsageCount': 3,
        'expiresAt': '2099-01-01T00:00:00Z',
      };
    }
    if (rejectCommit) throw ApiException('BOM_EDIT_CONFLICT', '组装信息已变化');
    if (loseCommitResponse) {
      loseCommitResponse = false;
      throw NetworkTimeoutException();
    }
    return {
      'operationCount': 1,
      'affectedGoodsIds': ['frame'],
      'itemIds': <String, String>{},
    };
  }
}

class _UnusedBase implements GoodsBomRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
