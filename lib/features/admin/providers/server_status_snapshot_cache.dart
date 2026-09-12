// 服务器状态快照的进程内共享缓存（状态页与工作台徽章共用同一份读数）。
//
// 2026-09-12 用户反馈：「服务器状态页面最上面的运行总览，动画需要等好一会才出现」。
// 原因是快照只存在页面自己的 State 里：每次进页面都从 null 起步，那圈总览仪表必须
// 等一整趟请求回来才能从虚线占位跳到真实读数——而工作台那张卡的红徽章
// （serverStatusAlertCountProvider）本来就在定期拉同一个端点，读数其实早就在手上。
//
// 于是把「最近一次成功读到的快照」提到这里：徽章拉到就写、页面拉到也写，
// 进页面第一帧先用缓存把总览画出来，自己那趟请求回来再覆盖。
//
// 两条约束：
// 1. **只写成功的快照**。失败不清缓存（页面另有 `_failed` 提示），否则一次网络抖动
//    就把已经看到的读数抹回虚线。
// 2. **过期的缓存不给页面用**。判定交给 `ServerStatusSnapshot.isStale`
//    （sampledAt + pollSeconds×2）；宁可显示占位，也不摆一个会立刻被标成
//    「已过期」的旧读数。也就是说缓存命中是**尽力而为**，不是保证——徽章侧的轮询
//    间隔为此调小过，但做不到必然命中，原因见
//    server_status_alert_count_provider.dart 的 _pollInterval。
//
// 常驻不 autoDispose：它就是一份「最后已知值」，被清掉等于回到原样。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/server_status.dart';

/// 最近一次成功读到的服务器状态快照；null = 本次启动还没读到过。
final serverStatusSnapshotCacheProvider = StateProvider<ServerStatusSnapshot?>(
  (ref) => null,
);
