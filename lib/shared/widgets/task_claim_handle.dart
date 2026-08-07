// 任务认领会话句柄：进入页面/打开待办时认领，每 30s 心跳续租，离开时释放。
// 纯 UX/防碰撞层：任何失败都不影响业务动作（后端 requireNoActiveClaimByOther 是安全网）。
// 用 ConsumerStatefulWidget 在 initState 认领、dispose 释放；builder 据 heldByMe/他人认领渲染。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/task_claim_view.dart';
import '../repositories/task_claim_repository.dart';

class TaskClaimHandle extends ConsumerStatefulWidget {
  const TaskClaimHandle({
    super.key,
    required this.targetType,
    required this.targetKey,
    required this.builder,
  });

  final String targetType;
  final String targetKey;

  /// builder(heldByMe, claim)：heldByMe=本人持有可操作；claim!=null 且非本人=他人处理中。
  final Widget Function(bool heldByMe, TaskClaimView? claim) builder;

  @override
  ConsumerState<TaskClaimHandle> createState() => _TaskClaimHandleState();
}

class _TaskClaimHandleState extends ConsumerState<TaskClaimHandle> {
  TaskClaimView? _claim;
  bool _heldByMe = true; // 默认允许操作，直到查明被他人占用（fail-open 仅 UX；后端守卫兜底）
  Timer? _heartbeat;

  @override
  void initState() {
    super.initState();
    // 认领（异步，不阻塞首帧）
    Future.microtask(_acquire);
  }

  Future<void> _acquire() async {
    final repo = ref.read(taskClaimRepositoryProvider);
    final view = await repo.claim(widget.targetType, widget.targetKey);
    if (!mounted) return;
    setState(() {
      _claim = view;
      _heldByMe = view?.claimedByMe ?? true;
    });
    if (view != null && view.claimedByMe) {
      _heartbeat?.cancel();
      _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
        ref.read(taskClaimRepositoryProvider).heartbeat(widget.targetType, widget.targetKey);
      });
    }
  }

  @override
  void dispose() {
    _heartbeat?.cancel();
    // 释放用 unawaited；实例可能已被框架回收 ref，包 try 防止抛出。
    try {
      ref.read(taskClaimRepositoryProvider).release(widget.targetType, widget.targetKey);
    } on Object {
      // 忽略：租约会自然过期。
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_heldByMe, _claim);
}
