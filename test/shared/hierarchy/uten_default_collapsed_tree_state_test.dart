import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/hierarchy/uten_default_collapsed_tree_state.dart';

void main() {
  test('新分支默认收起，刷新保留手动状态，移除身份后不复活', () {
    final state = UtenDefaultCollapsedTreeState();
    state.reconcile(['root', 'branch']);
    expect(state.collapsedIds, {'root', 'branch'});
    state.collapsedIds.remove('root');
    state.reconcile(['root', 'branch', 'new-branch']);
    expect(state.collapsedIds, {'branch', 'new-branch'});
    state.collapsedIds.add('root');
    state.reconcile(['root', 'branch', 'new-branch']);
    expect(state.collapsedIds, {'root', 'branch', 'new-branch'});
    state.reconcile(['branch']);
    state.reconcile(['root', 'branch']);
    expect(state.collapsedIds, {'root', 'branch'});
  });

  test('切换所属单据后重新默认收起，展开全部仅影响当前分支', () {
    final state = UtenDefaultCollapsedTreeState();
    state.reconcile(['a', 'b']);
    state.collapsedIds.clear();
    state.reconcile(['a', 'b']);
    expect(state.collapsedIds, isEmpty);
    state.reset();
    state.reconcile(['a', 'b']);
    expect(state.collapsedIds, {'a', 'b'});
  });
}
