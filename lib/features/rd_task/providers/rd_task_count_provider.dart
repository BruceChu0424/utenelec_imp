// 工程研发部任务中心的跨 Tab 刷新信号。
//
// 任务计数(红 = 待认领, 黄 = 已认领在办)随工作台徽章汇总带回(ADR-108), 页面读
// badgeEntryTodoProvider / badgeEntryInProgressProvider(BadgeEntry.rdTaskCenter)。

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 跨 Tab 刷新信号：在「待完成」完成任务后自增，让「已完成」Tab 重拉（同 B 类 listRefreshTick 思路）。
final rdTaskRefreshTickProvider = StateProvider<int>((ref) => 0);
