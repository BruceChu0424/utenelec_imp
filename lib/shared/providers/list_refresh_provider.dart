// B 类列表页（本地 State 直拉）「操作后刷新」信号。
//
// 背景：项目列表页有两套取数架构——
//   A 类：Riverpod provider 驱动（操作后 invalidate 列表 provider 自动刷新）；
//   B 类：本地 State + repository 直拉（无 provider 可 invalidate）。
// B 类列表被 push 进的详情/编辑页修改后，返回时本地 State 仍停在旧数据。
//
// 机制(2026-09-23 ADR-108)：列表页把 key 交给 `ref.onPageResume(..., refreshKeys: [key])`；
// 详情/编辑页在「数据可能变更的操作」成功后（保存/审核/删除/弹窗确认）bump 对应 key。
// 列表页就在栈顶时收到即重拉；被详情页盖着时只记下(本端写修订号已前进)，返回转场
// 结束后再拉一次——此前 tick 与返回各拉一次，一次保存要重拉两遍。
// 纯查看返回不 bump(数据没变，省请求)。
// key 由各模块约定（如 'purchase:order'、'goods'），列表页与其详情/编辑页必须用同一 key。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/data_write_revision.dart';
import '../badges/badge_registry.dart';

/// B 类列表页的刷新信号（按 key family）。值为单调递增的 tick。
///
/// 列表页用法（build 内）：
/// ```
/// ref.onPageResume(_myLocation!, () => _load(_pageNum), refreshKeys: [myKey]);
/// ```
/// 操作方用法（保存/审核/删除成功后）：
/// ```
/// bumpListRefresh(ref, myKey);
/// ```
final listRefreshTickProvider = StateProvider.family<int, String>(
  (ref, key) => 0,
);

/// 操作成功后调用：bump 对应列表 key 的 tick，并推进本端写修订号(返回即刷新据此判断
/// 数据变没变)。
///
/// **同时立刻重拉徽章汇总**(2026-09-11 起草稿计入徽章，用户原话「我没有审核、退出了，
/// 这个草稿就立马记录了，同时有徽章显示」)：本函数是全部单据编辑页保存/审核/删除
/// 成功后的唯一公共钩子，草稿数、财务已退回数与各入口待办都随汇总一次带回；
/// 同一帧里多处调用由汇总单飞合并成一个请求。
void bumpListRefresh(WidgetRef ref, String key) {
  ref.read(listRefreshTickProvider(key).notifier).state++;
  ref.read(dataWriteRevisionProvider.notifier).state++;
  refreshBadges(ref);
}
