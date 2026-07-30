// 空调控制页（Phase 4）
// 文档：docs/03-页面/空调控制页.md
//
// 响应式：详情/控制页走窄收敛——compact 自套 UtenContentContainer.narrow；
// medium+ 外壳已收敛，内容再限宽 560 居中。Hero 为圆角面板（不做全幅色块）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../components/buttons/click_guard.dart';
import '../models/hvac_device.dart';
import '../providers/hvac_providers.dart';

class HvacControlPage extends ConsumerStatefulWidget {
  const HvacControlPage({super.key, required this.deviceId});
  final String deviceId;

  @override
  ConsumerState<HvacControlPage> createState() => _HvacControlPageState();
}

class _HvacControlPageState extends ConsumerState<HvacControlPage> {
  HvacDevice? _device;
  final _history = <_Cmd>[];
  // 防止用户连续拨动开关/滑杆/模式导致请求并发。
  final _guard = ClickGuard();

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(hvacDetailProvider(widget.deviceId));

    return Scaffold(
      appBar: const UtenAppBar(title: '空调控制', showBackButton: true),
      body: detail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败：$e')),
        data: (d) {
          if (d == null) return const Center(child: Text('设备不存在'));
          _device ??= d;
          final isCompact = context.breakpoint.isCompact;
          Widget content = SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: isCompact ? 0 : UtenSpacing.s16,
              vertical: UtenSpacing.s16,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Hero(device: _device!),
                const SizedBox(height: UtenSpacing.s20),
                    UtenCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // 开关
                          Row(
                            children: [
                              const Expanded(child: Text('电源',
                                  style: TextStyle(fontWeight: FontWeight.w600))),
                              Switch(
                                value: _device!.power,
                                onChanged: _guard.isBusy
                                    ? null
                                    : (v) => _update(
                                        _device!.copyWith(power: v),
                                        v ? '开机' : '关机',
                                      ),
                              ),
                            ],
                          ),
                          const Divider(),
                          // 温度
                          Row(
                            children: [
                              const Text('目标温度'),
                              const Spacer(),
                              Text('${_device!.targetTemp.toStringAsFixed(0)}°C',
                                  style: const TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w700,
                                      fontFeatures: [
                                        FontFeature.tabularFigures()
                                      ])),
                            ],
                          ),
                          Slider(
                            min: 16, max: 30, divisions: 14,
                            value: _device!.targetTemp,
                            activeColor: UtenColors.teal600,
                            onChanged: (_device!.power && !_guard.isBusy)
                                ? (v) => setState(() =>
                                    _device = _device!.copyWith(targetTemp: v))
                                : null,
                            onChangeEnd: _guard.isBusy
                                ? null
                                : (v) => _update(
                                    _device!.copyWith(targetTemp: v),
                                    '调温 ${v.toStringAsFixed(0)}°C',
                                  ),
                          ),
                          const Divider(),
                          // 模式
                          const Padding(
                            padding: EdgeInsets.only(top: 4, bottom: 8),
                            child: Text('模式'),
                          ),
                          SegmentedButton<HvacMode>(
                            selected: {_device!.mode},
                            onSelectionChanged: (_device!.power && !_guard.isBusy)
                                ? (s) => _update(
                                    _device!.copyWith(mode: s.first),
                                    '切换${s.first.label}',
                                  )
                                : null,
                            segments: [
                              for (final m in HvacMode.values)
                                ButtonSegment(
                                    value: m,
                                    icon: Icon(m.icon),
                                    label: Text(m.label)),
                            ],
                          ),
                          const SizedBox(height: 12),
                          // 风速
                          const Padding(
                            padding: EdgeInsets.only(bottom: 8),
                            child: Text('风速'),
                          ),
                          SegmentedButton<HvacFan>(
                            selected: {_device!.fan},
                            onSelectionChanged: (_device!.power && !_guard.isBusy)
                                ? (s) => _update(
                                    _device!.copyWith(fan: s.first),
                                    '风速${s.first.label}',
                                  )
                                : null,
                            segments: [
                              for (final f in HvacFan.values)
                                ButtonSegment(value: f, label: Text(f.label)),
                            ],
                          ),
                        ],
                      ),
                    ),
                const SizedBox(height: UtenSpacing.s20),
                const UtenSectionHeader(title: '指令历史'),
                const SizedBox(height: UtenSpacing.s8),
                UtenCard(
                  child: _history.isEmpty
                      ? const Text('暂无指令',
                          style: TextStyle(color: UtenColors.slate400))
                      : Column(
                          children: [
                            for (var i = 0; i < _history.length; i++) ...[
                              _HistoryItem(cmd: _history[i]),
                              if (i != _history.length - 1)
                                const Divider(height: 16),
                            ],
                          ],
                        ),
                ),
                const SizedBox(height: UtenSpacing.s32),
              ],
            ),
          );
          if (isCompact) content = UtenContentContainer.narrow(child: content);
          // medium+：外壳已收敛到 1600，内容再限宽 560 居中（控制页宜窄）
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: content,
            ),
          );
        },
      ),
    );
  }

  void _update(HvacDevice next, String action) {
    // 联动控件（Switch/Slider/SegmentedButton）一被拖动就会回调，
    // 没守住就会一次发多个 PUT。本页用 _guard 让上一个请求回来之前不再触发。
    final f = _guard.run(() async {
      setState(() => _device = next);
      _history.insert(0, _Cmd(action: action, time: DateTime.now()));
      await ref.read(hvacRepositoryProvider).update(next);
      if (mounted) context.appInfo('$action（Mock）');
    });
    if (f != null) setState(() {}); // 进入置忙，重建以禁用以下控件
  }
}

class _Cmd {
  const _Cmd({required this.action, required this.time});
  final String action;
  final DateTime time;
}

class _HistoryItem extends StatelessWidget {
  const _HistoryItem({required this.cmd});
  final _Cmd cmd;
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.chevron_right_rounded, color: UtenColors.teal600, size: 18),
        const SizedBox(width: 4),
        Expanded(child: Text(cmd.action)),
        Text(
          '${cmd.time.hour.toString().padLeft(2, '0')}:${cmd.time.minute.toString().padLeft(2, '0')}',
          style: const TextStyle(color: UtenColors.slate500, fontSize: 12),
        ),
      ],
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.device});
  final HvacDevice device;
  @override
  Widget build(BuildContext context) {
    final online = device.online;
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [UtenColors.teal500, UtenColors.teal600],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        // 与卡片同档圆角（宽度收敛布局内不做全幅色块）
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(device.mode.icon, color: Colors.white70),
              const SizedBox(width: 6),
              Expanded(
                child: Text(device.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: UtenSpacing.s8),
              UtenStatusBadge(
                label: online ? '在线' : '离线',
                type: online
                    ? UtenStatusBadgeType.success
                    : UtenStatusBadgeType.danger,
                size: UtenStatusBadgeSize.small,
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          Text(
            online ? '${device.currentTemp.toStringAsFixed(0)}°' : '--',
            style: const TextStyle(
                color: Colors.white,
                fontSize: 56,
                fontWeight: FontWeight.w300,
                fontFeatures: [FontFeature.tabularFigures()]),
          ),
          const SizedBox(height: UtenSpacing.s4),
          Text(
            device.power
                ? '${device.mode.label} · 目标 ${device.targetTemp.toStringAsFixed(0)}°'
                : '已关闭',
            style: const TextStyle(color: Colors.white70),
          ),
        ],
      ),
    );
  }
}
