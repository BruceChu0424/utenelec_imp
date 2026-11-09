/// 顶部加载进度通知的进度阶段。
enum CompleteReadProgressPhase { started, batch, succeeded, failed }

/// 一次完整渐进读取对外发布的进度事件。
///
/// [loaded] 是本查询内已通过校验的累计行数（去重后），[total] 是服务端首批
/// 带回的精确总量；读取方允许未知总量（[total] 为 null）时界面按不定进度
/// 展示，绝不编造百分比。
class CompleteReadProgressEvent {
  const CompleteReadProgressEvent({
    required this.taskId,
    required this.phase,
    required this.loaded,
    this.total,
    this.owner,
  });

  final int taskId;
  final CompleteReadProgressPhase phase;
  final int loaded;
  final int? total;

  /// 读取归属（通常是一个 [ScopedPagedRead] 实例）；该归属被显式退休时，
  /// 其名下未结束的任务立即以 failed 收尾，不等迟到的网络返回。
  final Object? owner;
}

typedef CompleteReadProgressListener =
    void Function(CompleteReadProgressEvent event);

/// 完整渐进读取 → 顶部进度通知的唯一桥。
///
/// 纯 Dart 单例（无 Flutter/Riverpod 依赖）：`loadCompletePagedResult` 在
/// 发布渐进批次的读取里上报事件；UI 侧的控制器注册监听并驱动通知卡片。
/// 没有任何监听者时上报本身零开销（读取链路不多创建句柄）。
abstract final class CompleteReadProgressReporter {
  static final List<CompleteReadProgressListener> _listeners = [];
  static int _seq = 0;

  static bool get hasListeners => _listeners.isNotEmpty;

  static void addListener(CompleteReadProgressListener listener) {
    _listeners.add(listener);
  }

  static void removeListener(CompleteReadProgressListener listener) {
    _listeners.remove(listener);
  }

  /// 开启一个进度任务；仅在确有读取需要上报时由调用方创建。
  static CompleteReadProgressHandle start({Object? owner}) {
    final handle = CompleteReadProgressHandle._(_seq += 1, owner);
    _emit(
      CompleteReadProgressEvent(
        taskId: handle._taskId,
        phase: CompleteReadProgressPhase.started,
        loaded: 0,
        owner: owner,
      ),
    );
    return handle;
  }

  /// 把某归属名下所有未结束的任务立即按 failed 收尾（退休/销毁路径）。
  /// 经句柄的幂等 finish 走，保证每任务恰好一次收尾事件。
  static void cancelOwner(Object owner) {
    for (final task in _ownerLive[owner]?.toList() ?? const <int>[]) {
      _handles[task]?.finish(succeeded: false);
    }
  }

  // ---- 句柄侧登记（owner → 活跃任务） ----
  static final Map<Object, Set<int>> _ownerLive = {};
  static final Map<int, ({int loaded, int? total, Object? owner})> _live = {};
  static final Map<int, CompleteReadProgressHandle> _handles = {};

  static void _emit(CompleteReadProgressEvent event) {
    if (_listeners.isEmpty) return;
    for (final listener in _listeners.toList(growable: false)) {
      listener(event);
    }
  }
}

/// 一个进行中的进度任务句柄；finish 恰好生效一次。
class CompleteReadProgressHandle {
  CompleteReadProgressHandle._(this._taskId, this._owner) {
    CompleteReadProgressReporter._live[_taskId] = (
      loaded: 0,
      total: null,
      owner: _owner,
    );
    CompleteReadProgressReporter._handles[_taskId] = this;
    if (_owner != null) {
      CompleteReadProgressReporter._ownerLive
          .putIfAbsent(_owner, () => <int>{})
          .add(_taskId);
    }
  }

  final int _taskId;
  final Object? _owner;
  bool _finished = false;

  /// 每个通过校验的批次后更新累计行数；[total] 传 null 表示总量未知。
  void update({required int loaded, int? total}) {
    if (_finished) return;
    CompleteReadProgressReporter._live[_taskId] = (
      loaded: loaded,
      total: total,
      owner: _owner,
    );
    CompleteReadProgressReporter._emit(
      CompleteReadProgressEvent(
        taskId: _taskId,
        phase: CompleteReadProgressPhase.batch,
        loaded: loaded,
        total: total,
        owner: _owner,
      ),
    );
  }

  /// 结束任务；[succeeded] 为 true 仅当完整结果已成功返回（取消、退休、
  /// 失败与 [UiWorkCancelled] 一律 false）。
  void finish({required bool succeeded}) {
    if (_finished) return;
    _finished = true;
    final live = CompleteReadProgressReporter._live.remove(_taskId);
    CompleteReadProgressReporter._handles.remove(_taskId);
    if (_owner != null) _dropFromOwner(_owner, _taskId);
    CompleteReadProgressReporter._emit(
      CompleteReadProgressEvent(
        taskId: _taskId,
        phase: succeeded
            ? CompleteReadProgressPhase.succeeded
            : CompleteReadProgressPhase.failed,
        loaded: live?.loaded ?? 0,
        total: live?.total,
        owner: _owner,
      ),
    );
  }
}

void _dropFromOwner(Object owner, int taskId) {
  final tasks = CompleteReadProgressReporter._ownerLive[owner];
  if (tasks == null) return;
  tasks.remove(taskId);
  if (tasks.isEmpty) CompleteReadProgressReporter._ownerLive.remove(owner);
}
