import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'warehouse_task_scope.dart';

/// 窗口重新获得焦点时，把仍停在错误态的仓库数据范围自动重拉一次。
///
/// `myWarehouseScopeProvider` 只在身份建立和读取范围版本变化时取数；服务重启或
/// 断网窗口里失败后，provider 停在「仓库筛选加载失败」等手动重试，用户切不了
/// 「全部仓库」(2026-11-09)。恢复前台是回到应用的明确信号，此时重试一次；
/// 成功与否都沿用选择器原有表现，不额外弹窗，也不动身份与授权。
class WarehouseScopeRecoveryHost extends ConsumerStatefulWidget {
  const WarehouseScopeRecoveryHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<WarehouseScopeRecoveryHost> createState() =>
      _WarehouseScopeRecoveryHostState();
}

class _WarehouseScopeRecoveryHostState
    extends ConsumerState<WarehouseScopeRecoveryHost>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // 只救错误态：加载中/已有值都不碰，避免每次切窗口都白发一次请求。
    if (ref.read(myWarehouseScopeProvider).hasError) {
      ref.invalidate(myWarehouseScopeProvider);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
