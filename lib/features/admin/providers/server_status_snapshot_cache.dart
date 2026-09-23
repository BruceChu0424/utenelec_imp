// 服务器状态快照的进程内缓存(状态页自己拉到就写，下次进页面第一帧先用)。
//
// 2026-09-12 用户反馈：「服务器状态页面最上面的运行总览，动画需要等好一会才出现」。
// 原因是快照只存在页面自己的 State 里：每次进页面都从 null 起步，那圈总览仪表必须
// 等一整趟请求回来才能从虚线占位跳到真实读数——而工作台那张卡的红徽章
// （serverStatusAlertCountProvider）本来就在定期拉同一个端点，读数其实早就在手上。
//
// 于是把「最近一次成功读到的快照」提到这里：页面拉到就写，
// 进页面第一帧先用缓存把总览画出来，自己那趟请求回来再覆盖。
//
// 2026-09-23(ADR-108)起工作台角标改由徽章汇总一次带回，只带告警条数、不带整份快照，
// 原告警计数 provider 已删除，缓存只剩页面自己写：本次启动**第一次**进页面没有缓存可用，
// 要等这一趟请求(此前的等待主要来自约 40 个计数请求占满 HTTP/1.1 连接，现已不再排队)。
//
// 两条约束：
// 1. **只写成功的快照**。失败不清缓存（页面另有 `_failed` 提示），否则一次网络抖动
//    就把已经看到的读数抹回虚线。
// 2. **过期的缓存不给页面用**。判定交给 `ServerStatusSnapshot.isStale`
//    （sampledAt + pollSeconds×2）；宁可显示占位，也不摆一个会立刻被标成
//    「已过期」的旧读数。也就是说缓存命中是**尽力而为**，不是保证。
//
// 常驻不 autoDispose：它就是一份「最后已知值」，被清掉等于回到原样。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/server_status.dart';

/// 最近一次成功读到的服务器状态快照；null = 本次启动还没读到过。
final serverStatusSnapshotCacheProvider = StateProvider<ServerStatusSnapshot?>(
  (ref) => null,
);
