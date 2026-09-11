// 工作台布局 Provider 单测：组内卡片排序（reorderItem）+ itemOrders 编解码兼容。
//
// 覆盖：
// - 悬停换位语义（向后拖 = 落到目标之后 / 向前拖 = 占目标原位 / 相邻换位）；
// - 回填：不可见卡片保持原位、prev 里没有的新可见卡片补末尾；
// - decode 兼容旧缓存（无 itemOrders）与 Map/String 两种形态，脏数据丢弃；
// - encode roundtrip。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/dashboard/providers/workbench_layout_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

class _StubSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

ProviderContainer _container() => ProviderContainer(
  overrides: [sessionProvider.overrideWith(() => _StubSession())],
);

void main() {
  group('reorderItem 悬停换位语义', () {
    test('向后拖 = 落到目标之后（目标原索引插入）', () {
      final c = _container();
      addTearDown(c.dispose);
      final n = c.read(workbenchLayoutProvider.notifier);
      n.reorderItem('fin', ['a', 'b', 'c'], 'a', 'c');
      expect(c.read(workbenchLayoutProvider).itemOrders['fin'], [
        'b',
        'c',
        'a',
      ]);
    });

    test('向前拖 = 占目标原位', () {
      final c = _container();
      addTearDown(c.dispose);
      final n = c.read(workbenchLayoutProvider.notifier);
      n.reorderItem('fin', ['a', 'b', 'c'], 'c', 'a');
      expect(c.read(workbenchLayoutProvider).itemOrders['fin'], [
        'c',
        'a',
        'b',
      ]);
    });

    test('相邻换位（向下）', () {
      final c = _container();
      addTearDown(c.dispose);
      final n = c.read(workbenchLayoutProvider.notifier);
      n.reorderItem('fin', ['a', 'b', 'c'], 'a', 'b');
      expect(c.read(workbenchLayoutProvider).itemOrders['fin'], [
        'b',
        'a',
        'c',
      ]);
    });

    test('dragged == target 或未知 location：不变更', () {
      final c = _container();
      addTearDown(c.dispose);
      final n = c.read(workbenchLayoutProvider.notifier);
      n.reorderItem('fin', ['a', 'b', 'c'], 'a', 'a');
      n.reorderItem('fin', ['a', 'b', 'c'], 'x', 'b');
      n.reorderItem('fin', ['a', 'b', 'c'], 'a', 'x');
      expect(c.read(workbenchLayoutProvider).itemOrders, isEmpty);
    });
  });

  group('reorderItem 回填（不可见卡片不丢位）', () {
    test('prev 中的不可见卡片保持原位，新可见卡片补末尾', () {
      final c = _container();
      addTearDown(c.dispose);
      final n = c.read(workbenchLayoutProvider.notifier);
      // 先排一次：可见 [a,b,c]，得 prev
      n.reorderItem('fin', ['a', 'b', 'c'], 'a', 'c');
      // 模拟权限变化：x 新可见、a 暂不可见，visible = [x,b,c]
      n.reorderItem('fin', ['x', 'b', 'c'], 'x', 'c');
      final order = c.read(workbenchLayoutProvider).itemOrders['fin']!;
      // 第一轮结果 prev=[b,c,a]；a 不可见保持原位，新可见的 x 补末尾
      // 渲染端按可见项过滤 saved=[b,c,a,x] → [b,c,x]，与拖动时的实时视图一致
      expect(order, ['b', 'c', 'a', 'x']);
    });

    test('只重排当前组，不影响其他组的已存顺序', () {
      final c = _container();
      addTearDown(c.dispose);
      final n = c.read(workbenchLayoutProvider.notifier);
      n.reorderItem('fin', ['a', 'b'], 'a', 'b');
      n.reorderItem('hr', ['p', 'q', 'r'], 'r', 'p');
      final state = c.read(workbenchLayoutProvider);
      expect(state.itemOrders['fin'], ['b', 'a']);
      expect(state.itemOrders['hr'], ['r', 'p', 'q']);
    });
  });

  group('itemOrders 编解码', () {
    test('旧缓存（无 itemOrders 字段）仍可解码', () {
      final c = _container();
      addTearDown(c.dispose);
      final n = c.read(workbenchLayoutProvider.notifier);
      final decoded = n.decode({
        'order': ['hr', 'common', 'fin'],
        'collapsed': ['fin'],
      });
      expect(decoded, isNotNull);
      expect(decoded!.itemOrders, isEmpty);
      expect(decoded.order.first, 'hr');
      expect(decoded.collapsed, {'fin'});
    });

    test('Map 形态解码：未知分组丢弃、脏列表丢弃、正常组保留', () {
      final c = _container();
      addTearDown(c.dispose);
      final n = c.read(workbenchLayoutProvider.notifier);
      final decoded = n.decode({
        'order': ['common'],
        'itemOrders': {
          'fin': ['/payroll/review', '/finance'],
          'ghost-group': ['x'], // 未知分组 → 丢弃
          'hr': [1, 2, 'ok'], // 非全 String 列表 → 整组丢弃
        },
      });
      expect(decoded, isNotNull);
      expect(decoded!.itemOrders.keys, {'fin'});
      expect(decoded.itemOrders['fin'], ['/payroll/review', '/finance']);
    });

    test('服务端 String（JSON）形态解码', () {
      final c = _container();
      addTearDown(c.dispose);
      final n = c.read(workbenchLayoutProvider.notifier);
      final decoded = n.decode(
        '{"order":["fin"],"collapsed":[],"itemOrders":{"fin":["/finance"]}}',
      );
      expect(decoded, isNotNull);
      expect(decoded!.itemOrders['fin'], ['/finance']);
    });

    test('encode 含 itemOrders，且 decode(encode) roundtrip', () {
      final c = _container();
      addTearDown(c.dispose);
      final n = c.read(workbenchLayoutProvider.notifier);
      n.reorderItem('fin', ['a', 'b', 'c'], 'a', 'c');
      final state = c.read(workbenchLayoutProvider);
      final encoded = n.encode(state)!;
      expect(encoded, isA<Map<String, dynamic>>());
      final round = n.decode(encoded);
      expect(round!.itemOrders, state.itemOrders);
      expect(round.order, state.order);
    });

    test('构造兼容：仅 order/collapsed（旧调用/测试桩）itemOrders 默认空', () {
      const state = WorkbenchLayoutState(order: ['system'], collapsed: {});
      expect(state.itemOrders, isEmpty);
    });
  });
}
