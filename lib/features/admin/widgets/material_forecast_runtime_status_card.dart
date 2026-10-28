import 'dart:async';
import 'package:flutter/material.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../components/buttons/uten_refresh_button.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/utils/display_datetime.dart';
import '../../../shared/auth/native_read_view_scope_mixin.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/pricing/material_market_models.dart';
import '../../../shared/pricing/price_analysis_models.dart';
import '../models/material_forecast_runtime_status.dart';
import '../repositories/material_forecast_runtime_repository.dart';

/// Read-only process acknowledgement; changing settings stays in the existing
/// batch/CAS/step-up flow. Status refresh never starts a collector.
class MaterialForecastRuntimeStatusCard extends ConsumerStatefulWidget {
  const MaterialForecastRuntimeStatusCard({
    super.key,
    this.savedSettings = const {},
  });
  final Map<String, String> savedSettings;
  @override
  ConsumerState<MaterialForecastRuntimeStatusCard> createState() =>
      _MaterialForecastRuntimeStatusCardState();
}

class _MaterialForecastRuntimeStatusCardState
    extends ConsumerState<MaterialForecastRuntimeStatusCard>
    with
        NativeReadViewScopeMixin<MaterialForecastRuntimeStatusCard>,
        WidgetsBindingObserver {
  MaterialForecastRuntimeStatus? _status;
  bool _loading = false, _failed = false, _denied = false;
  Timer? _pollTimer, _deadlineTimer;
  ModalRoute<dynamic>? _route;
  bool _pendingRefresh = false;
  int _request = 0;
  bool get _allowed =>
      ref.read(isSuperAdminProvider) &&
      ref.read(currentPermissionsProvider).contains(Perm.authorizationManage);
  bool get _active =>
      mounted &&
      _allowed &&
      !_denied &&
      (_route?.isCurrent ?? true) &&
      (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed);
  DateTime get _now => ref.read(materialForecastRuntimeClockProvider)();
  String get _identity {
    final entries = widget.savedSettings.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return entries.map((entry) => '${entry.key}=${entry.value}').join('|');
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    initializeNativeReadScope();
    ref.listenManual(currentPermissionsProvider, (_, _) {
      invalidateNativeReadAccess();
      _clear();
      _queueRead();
    });
    ref.listenManual(isSuperAdminProvider, (_, _) {
      invalidateNativeReadAccess();
      _clear();
      _queueRead();
    });
    _queueRead();
  }

  void _queueRead() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_active) _load();
  });
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_active && (_status == null && !_failed || _pendingRefresh)) {
        _load(background: true);
      }
    });
  }

  @override
  void didUpdateWidget(covariant MaterialForecastRuntimeStatusCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameSettings(oldWidget.savedSettings, widget.savedSettings)) {
      _clear();
      _queueRead();
    }
  }

  static bool _sameSettings(Map<String, String> a, Map<String, String> b) =>
      a.length == b.length &&
      a.entries.every((entry) => b[entry.key] == entry.value);
  void _clear() {
    _request++;
    _pollTimer?.cancel();
    _deadlineTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _status = null;
      _loading = false;
      _failed = false;
      _denied = false;
      _pendingRefresh = false;
    });
  }

  @override
  void nativeReadOwnerChanged() => _clear();
  @override
  void nativeReadPermissionChanged() => _clear();
  @override
  Future<void> nativeReadReload() => _load();
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _active && !_loading) {
      _load(background: true);
    }
  }

  Future<void> _load({bool background = false}) async {
    if (!_active || _loading) return;
    final preserve = background && nativeReadAccessConfirmed && _status != null;
    final identity = _identity, request = ++_request;
    final owns = captureNativeOwnership();
    final accepts = preserve
        ? () => owns() && nativeReadAccessConfirmed && identity == _identity
        : captureNativeRead(identity, () => _identity);
    if (!accepts()) return;
    _pollTimer?.cancel();
    if (!preserve) _deadlineTimer?.cancel();
    setState(() {
      if (!preserve) _status = null;
      _loading = true;
      _pendingRefresh = false;
    });
    try {
      final status = await ref
          .read(materialForecastRuntimeRepositoryProvider)
          .status();
      if (!accepts() || !_allowed || request != _request) return;
      acceptNativeRead();
      setState(() {
        _status = status;
        _failed = false;
      });
      _armDeadline(status);
    } catch (error) {
      if (!accepts() || request != _request) return;
      if (error is ApiException &&
          (error.code == 'FORBIDDEN' || error.code == 'UNAUTHORIZED')) {
        _deadlineTimer?.cancel();
        invalidateNativeReadAccess();
        setState(() {
          _status = null;
          _loading = false;
          _denied = true;
          _failed = true;
        });
      } else {
        setState(() => _failed = true);
      }
    } finally {
      if (mounted && owns() && request == _request && identity == _identity) {
        setState(() => _loading = false);
        _schedulePoll();
      }
    }
  }

  void _schedulePoll() {
    _pollTimer?.cancel();
    final request = _request, identity = _identity;
    _pollTimer = Timer(
      Duration(seconds: _status?.refreshAfterSeconds ?? 15),
      () {
        if (!mounted || request != _request || identity != _identity) return;
        _pendingRefresh = true;
        if (_active) _load(background: true);
      },
    );
  }

  void _armDeadline(MaterialForecastRuntimeStatus status) {
    _deadlineTimer?.cancel();
    final deadline = status.firstDeadlineAfter(_now);
    if (deadline == null) return;
    final identity = _identity, owns = captureNativeOwnership();
    _deadlineTimer = Timer(deadline.difference(_now), () {
      if (!owns() || identity != _identity || !identical(_status, status)) {
        return;
      }
      setState(() {});
      _armDeadline(status);
    });
  }

  @override
  void dispose() {
    _request++;
    _pollTimer?.cancel();
    _deadlineTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    ref.watch(isSuperAdminProvider);
    if (!_allowed) return const SizedBox.shrink();
    final status = nativeReadAccessConfirmed ? _status : null;
    final verified = !_failed && status?.freshAt(_now) == true;
    final matches = status?.matchesSaved(widget.savedSettings) == true;
    final acknowledged =
        verified && status!.acknowledgedAt(_now, widget.savedSettings);
    final title = _denied
        ? '当前身份无权读取采集状态'
        : _failed
        ? status == null
              ? '采集状态读取失败，暂未确认服务器应用'
              : '暂无法核对采集状态，保留上次状态记录'
        : status == null
        ? '尚未获取采集服务状态'
        : !verified
        ? '采集状态已过期，暂无法确认是否运行'
        : !matches
        ? '服务器设置已变化，请刷新系统设置'
        : acknowledged
        ? status.enabled
              ? '服务器已确认自动采集运行'
              : '自动采集已关闭'
        : switch (status.state) {
            'PREPARING' => '正在准备采集环境',
            'STARTING' => '正在启动采集服务，等待确认',
            'STOPPING' => '正在停止采集服务，等待确认',
            'ERROR' => '采集服务运行异常',
            'NOT_LOCAL' => '当前服务不运行公司行情采集',
            'UNAVAILABLE' => '采集环境暂不可用',
            _ => '设置已保存，等待采集服务确认',
          };
    return Padding(
      key: const Key('material-forecast-runtime-status'),
      padding: const EdgeInsets.only(top: UtenSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  title,
                  key: const Key('material-forecast-runtime-title'),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: acknowledged
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const UtenFieldHintIcon(
                key: Key('material-forecast-portable-policy'),
                info: '设置和货品关联随数据库保留，标准服务器部署会自动准备采集环境。',
                dense: true,
              ),
              UtenRefreshButton(
                key: const Key('material-forecast-runtime-refresh'),
                busy: _loading,
                enabled: !_denied,
                onRefresh: _load,
                tooltip: '刷新采集状态',
              ),
            ],
          ),
          if (status != null) ...[
            const SizedBox(height: UtenSpacing.s8),
            Text(
              '服务器已保存：${status.enabled ? '开启' : '关闭'}；每 ${status.configuration['intervalMinutes']} 分钟检查；回填 ${status.configuration['historyDays']} 天；每轮最多 ${status.configuration['backfillBudget']} 份历史日报',
            ),
            Text(
              '状态截至：${DisplayDateTime.beijing(status.data['dataAsOf']?.toString(), fallback: '尚未确认')}',
            ),
            Text(
              acknowledged ? '当前保存设置已由服务器确认' : '当前保存设置尚未确认应用',
              key: const Key('material-forecast-runtime-applied'),
            ),
            if (verified && status.runtime['lastErrorCode'] != null)
              Text(
                _error(status.runtime['lastErrorCode'].toString()),
                key: const Key('material-forecast-runtime-error'),
              ),
            if (status.runtime['startedAt'] != null)
              Text(
                '上次启动：${DisplayDateTime.beijing(status.runtime['startedAt'].toString(), fallback: '—')}',
              ),
            for (final feed in status.feeds)
              _FeedStatus(
                feed: feed,
                live: acknowledged && status.enabled,
                now: _now,
              ),
          ],
        ],
      ),
    );
  }

  static String _error(String code) => switch (code) {
    'BASE_PYTHON_UNAVAILABLE' => '采集基础环境未就绪，请由服务器维护人员检查标准部署',
    'RUNTIME_MISSING' => '采集环境尚未准备完成',
    'PREPARATION_FAILED' => '采集环境准备失败，请检查服务器部署状态',
    'START_FAILED' => '采集服务启动失败，等待服务器重试',
    'PROCESS_EXITED' => '采集服务意外退出，等待服务器恢复',
    'WORKER_UNRESPONSIVE' => '未收到有效采集心跳，暂不能确认运行',
    'CONFIGURATION_PENDING' => '新设置等待采集服务应用',
    'COLLECTOR_BUSY' => '已有采集服务占用运行资格，等待服务器协调',
    _ => '采集状态需要服务器维护人员核对',
  };
}

class _FeedStatus extends StatelessWidget {
  const _FeedStatus({
    required this.feed,
    required this.live,
    required this.now,
  });
  final Map<String, dynamic> feed;
  final bool live;
  final DateTime now;
  @override
  Widget build(BuildContext context) {
    final sync = priceMap(feed['sync']);
    final phase = switch (sync['status']) {
      'FETCHING' => '读取最新行情',
      'BACKFILLING' => '补充历史行情',
      'MODEL' => '更新研究预测',
      'IDLE' => '等待下次检查',
      'ERROR' => '同步异常',
      _ => '采集未连接',
    };
    final quoteJson = priceMap(feed['latestQuote']);
    final quote = quoteJson.isEmpty ? null : MaterialMarketQuote(quoteJson);
    return Padding(
      padding: const EdgeInsets.only(top: UtenSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            feed['name']?.toString() ?? '行情品种',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          Text('${live ? '当前阶段' : '上次阶段'}：$phase'),
          Text('最近日终交易日：${feed['dataAsOf'] ?? '尚未获取'}'),
          if (feed['historyRecordCount'] != null)
            Text('已取得历史记录：${feed['historyRecordCount']} 条'),
          if (sync['lastSuccessAt'] != null)
            Text(
              '最近成功：${DisplayDateTime.beijing(sync['lastSuccessAt'].toString(), fallback: '—')}',
            ),
          if (quote != null)
            Text(
              '${quote.currentAt(now) && live ? '最新延迟行情' : '上次延迟行情'}：${DisplayDateTime.beijing(quote.text('marketTime'), fallback: '—')}${quote.currentAt(now) ? '' : '（已过期）'}',
            ),
          Text(
            '${live ? '预测状态' : '上次预测状态'}：${switch (feed['snapshotStatus']) {
              'RESEARCH_ONLY' => '历史回放研究预测，尚未验证实时预测效果',
              'BASELINE_ONLY' => '仅基线估计，模型回测尚未通过',
              'READY' => '历史回测通过，仍需结合采购条件核对',
              'STALE' => '预测依据已过期',
              _ => '预测依据尚未就绪',
            }}',
          ),
          if (sync['errorCode'] != null)
            Text(switch (sync['errorCode']) {
              'NETWORK_ERROR' => '最近错误：行情来源连接失败',
              'RATE_LIMITED' => '最近错误：来源暂时限流，等待重试',
              'MODEL_FAILED' => '最近错误：预测计算失败',
              _ => '最近错误：来源数据需要核对',
            }),
        ],
      ),
    );
  }
}
