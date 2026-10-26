import 'package:flutter_test/flutter_test.dart';

import '../../tool/b1_harness/party_read_fixture.dart';

List<Map<String, dynamic>> _items(Map<String, dynamic> response) =>
    (response['items'] as List).cast<Map<String, dynamic>>();

void main() {
  test(
    'browser fixture keeps historical page boundaries and separate category context',
    () async {
      final api = PartyReadFixtureApi(ordinaryDelay: Duration.zero);
      final second = await api.get(
        '/master/clients',
        query: {'page': 2, 'size': 100, 'selectableOnly': false},
      );
      expect(second['total'], 1201);
      expect(_items(second).length, 100);
      expect(_items(second).first['id'], 'party-0101');
      final last = await api.post(
        '/master/clients/search',
        query: {'page': 1, 'size': 100, 'selectableOnly': false},
        body: {'keyword': '末页历史'},
      );
      expect(_items(last).single['id'], PartyReadFixtureApi.restoredId);
      expect(_items(last).single['status'], '禁用');
      final context = await api.post(
        '/master/clients/search-context',
        query: {'page': 1, 'size': 100},
        body: {'keyword': '末页历史'},
      );
      expect(context['totalMatches'], 1);
      expect(context['totalCategories'], 1);
      expect(context.containsKey('items'), isFalse);
      final active = await api.get(
        '/master/suppliers',
        query: {'page': 1, 'size': 100, 'selectableOnly': true},
      );
      expect(active['total'], 1199);
      expect(_items(active).first['status'], '使用');
    },
  );

  test(
    'browser fixture really returns an old reader payload after a scope changes',
    () async {
      final api = PartyReadFixtureApi(
        ordinaryDelay: const Duration(milliseconds: 1),
      );
      final old = api.get('/master/clients', query: {'page': 1, 'size': 100});
      api.actor = 'B';
      api.scope++;
      final response = await old;
      expect(_items(response).first['name'], startsWith('A-'));
      expect(response['readScopeVersion'], 'fixture-1');
      final fresh = await api.get(
        '/master/clients',
        query: {'page': 1, 'size': 100},
      );
      expect(_items(fresh).first['name'], startsWith('B-'));
      expect(fresh['readScopeVersion'], 'fixture-2');
      await expectLater(api.getList('/master/clients/dict'), throwsStateError);
    },
  );
}
