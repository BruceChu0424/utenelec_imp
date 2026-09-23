// 徽章汇总里某个来源持续出错(staleEntries / staleSources)时的回归(ADR-108 修复轮):
// 没算出的入口保留上一次的数, 容器与导航总数按差额修正——健康入口的变化照常反映,
// 不能整体冻结在第一次的值上; 没算出的来源的页内分段事实数也保留上一次的数。
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';

/// 一份汇总: 研发待认领 [rdTodo]; 仓库出库中心由两个来源组成, 销售待出库来源
/// [salesOutboundOk] 为 false 时服务端没算出(该来源的数缺席, 入口只剩委外那部分)。
Map<String, dynamic> _json({
  required int rdTodo,
  required bool salesOutboundOk,
  int salesOutbound = 4,
  int subcontractOutbound = 2,
}) {
  final outbound = (salesOutboundOk ? salesOutbound : 0) + subcontractOutbound;
  return {
    'entries': {
      'rdTaskCenter': {'todo': rdTodo, 'inProgress': 1},
      'warehouseOutboundCenter': {'todo': outbound, 'inProgress': 0},
      'warehouseDrafts': {'todo': 3, 'inProgress': 0},
    },
    'modules': {
      'rd': {'todo': rdTodo, 'inProgress': 1},
      'warehouse': {'todo': outbound + 3, 'inProgress': 0},
    },
    'total': {'todo': rdTodo + outbound + 3, 'inProgress': 1},
    'facts': {
      'rdTask.open': rdTodo,
      'rdTask.inProgress': 1,
      if (salesOutboundOk) 'warehouseSalesOutbound.PENDING_PICK': salesOutbound,
      if (salesOutboundOk) 'warehouseSalesOutbound.SHIPPED': 7,
      'subcontractOutbound.count': subcontractOutbound,
      'drafts.stockDocument': 3,
    },
    'staleEntries': [if (!salesOutboundOk) 'warehouseOutboundCenter'],
    'staleSources': [if (!salesOutboundOk) 'warehouseSalesOutbound'],
  };
}

BadgeSummary _next(BadgeSummary previous, Map<String, dynamic> json) =>
    BadgeSummary.fromJson(json).keepStaleFrom(previous);

void main() {
  test('服务器状态来源一直出错: 导航总数仍跟着健康入口变化', () {
    Map<String, dynamic> json(int rd) => {
      'entries': {
        'rdTaskCenter': {'todo': rd, 'inProgress': 0},
        'serverStatusAlert': {'todo': 0, 'inProgress': 0},
      },
      'modules': {
        'rd': {'todo': rd, 'inProgress': 0},
        'system': {'todo': 0, 'inProgress': 0},
      },
      'total': {'todo': rd, 'inProgress': 0},
      'facts': {'rdTask.open': rd},
      'staleEntries': ['serverStatusAlert'],
      'staleSources': ['serverStatus'],
    };
    var state = BadgeSummary.empty;
    for (final rd in [1, 5, 9]) {
      state = _next(state, json(rd));
      expect(state.entryTodo(BadgeEntry.rdTaskCenter), rd);
      expect(state.moduleTodo(BadgeModule.rd), rd);
      expect(state.total.todo, rd, reason: '导航总数不能冻结');
    }
  });

  test('没算出的入口保留上一次的数, 容器与总数按差额修正, 健康入口照常变化', () {
    var state = _next(
      BadgeSummary.empty,
      _json(rdTodo: 1, salesOutboundOk: true),
    );
    expect(state.entryTodo(BadgeEntry.warehouseOutboundCenter), 6);
    expect(state.moduleTodo(BadgeModule.warehouse), 9);
    expect(state.total.todo, 10);

    // 销售待出库来源出错, 同时研发数变了。
    state = _next(state, _json(rdTodo: 5, salesOutboundOk: false));
    expect(state.isStale(BadgeEntry.warehouseOutboundCenter), isTrue);
    expect(state.entryTodo(BadgeEntry.warehouseOutboundCenter), 6);
    expect(state.moduleTodo(BadgeModule.warehouse), 9);
    expect(state.moduleTodo(BadgeModule.rd), 5);
    expect(state.total.todo, 14, reason: '5 + 6 + 3');
    expect(state.total.inProgress, 1);
    // 页内分段事实数沿用上一份, 不闪 0。
    expect(state.fact('warehouseSalesOutbound.PENDING_PICK'), 4);
    expect(state.fact('warehouseSalesOutbound.SHIPPED'), 7);
    expect(state.fact('rdTask.open'), 5);

    // 持续出错且健康部分也变了: 仍只替换出错入口, 仓库草稿等照常。
    state = _next(state, _json(rdTodo: 2, salesOutboundOk: false));
    expect(state.entryTodo(BadgeEntry.warehouseOutboundCenter), 6);
    expect(state.total.todo, 11, reason: '2 + 6 + 3');

    // 来源恢复: 回到服务端算出的真实数。
    state = _next(
      state,
      _json(rdTodo: 2, salesOutboundOk: true, salesOutbound: 1),
    );
    expect(state.isStale(BadgeEntry.warehouseOutboundCenter), isFalse);
    expect(state.entryTodo(BadgeEntry.warehouseOutboundCenter), 3);
    expect(state.moduleTodo(BadgeModule.warehouse), 6);
    expect(state.total.todo, 8);
    expect(state.fact('warehouseSalesOutbound.PENDING_PICK'), 1);
  });

  test('还没成功拉到过时出错: 只能用本次的数', () {
    final state = _next(
      BadgeSummary.empty,
      _json(rdTodo: 1, salesOutboundOk: false),
    );
    expect(state.entryTodo(BadgeEntry.warehouseOutboundCenter), 2);
    expect(state.total.todo, 6);
  });
}
