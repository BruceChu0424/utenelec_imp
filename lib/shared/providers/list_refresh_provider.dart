// B 类列表页（本地 State 直拉）「操作后刷新」信号。
//
// 背景：项目列表页有两套取数架构——
//   A 类：Riverpod provider 驱动（操作后 invalidate 列表 provider 自动刷新）；
//   B 类：本地 State + repository 直拉（无 provider 可 invalidate）。
// B 类列表被 push 进的详情/编辑页修改后，返回时本地 State 仍停在旧数据。
//
// 机制：列表页 ref.listen(listRefreshTickProvider(key)) 收到 tick 变化就 _load()；
// 详情/编辑页在「数据可能变更的操作」成功后（保存/审核/删除/弹窗确认）bump 对应 key。
// 纯查看返回不 bump（数据没变，省请求）——满足「不留老数据」又不做多余请求。
// key 由各模块约定（如 'purchase:order'、'goods'），列表页与其详情/编辑页必须用同一 key。

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// B 类列表页的刷新信号（按 key family）。值为单调递增的 tick。
///
/// 列表页用法（build 内）：
/// ```
/// ref.listen(listRefreshTickProvider(myKey), (_, __) => _load(_pageNum));
/// ```
/// 操作方用法（保存/审核/删除成功后）：
/// ```
/// bumpListRefresh(ref, myKey);
/// ```
final listRefreshTickProvider = StateProvider.family<int, String>(
  (ref, key) => 0,
);

/// 操作成功后调用：bump 对应列表 key 的 tick，触发监听该 key 的列表页重拉。
void bumpListRefresh(WidgetRef ref, String key) {
  ref.read(listRefreshTickProvider(key).notifier).state++;
}
