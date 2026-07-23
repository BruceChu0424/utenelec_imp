// 空调控制页（Phase 4）
// 文档：docs/03-页面/空调控制页.md

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/theme/uten_colors.dart';
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
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Hero(device: _device!),
                    const SizedBox(height: 20),
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
                                onChanged: (v) => _update(_device!.copyWith(power: v), v ? '开机' : '关机'),
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
                                      fontSize: 20, fontWeight: FontWeight.w700)),
                            ],
                          ),
                          Slider(
                            min: 16, max: 30, divisions: 14,
                            value: _device!.targetTemp,
                            activeColor: UtenColors.teal600,
                            onChanged: _device!.power
                                ? (v) => setState(() =>
                                    _device = _device!.copyWith(targetTemp: v))
                                : null,
                            onChangeEnd: (v) =>
                                _update(_device!.copyWith(targetTemp: v), '调温 ${v.toStringAsFixed(0)}°C'),
                          ),
                          const Divider(),
                          // 模式
                          const Padding(
                            padding: EdgeInsets.only(top: 4, bottom: 8),
                            child: Text('模式'),
                          ),
                          SegmentedButton<HvacMode>(
                            selected: {_device!.mode},
                            onSelectionChanged: _device!.power
                                ? (s) => _update(
                                    _device!.copyWith(mode: s.first), '切换${s.first.label}')
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
                            onSelectionChanged: _device!.power
                                ? (s) => _update(
                                    _device!.copyWith(fan: s.first), '风速${s.first.label}')
                                : null,
                            segments: [
                              for (final f in HvacFan.values)
                                ButtonSegment(value: f, label: Text(f.label)),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    const UtenSectionHeader(title: '指令历史'),
                    const SizedBox(height: 8),
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
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _update(HvacDevice next, String action) {
    setState(() => _device = next);
    _history.insert(0, _Cmd(action: action, time: DateTime.now()));
    ref.read(hvacRepositoryProvider).update(next);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$action（Mock）')));
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
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [UtenColors.deepGreen, UtenColors.teal600],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(device.mode.icon, color: Colors.white70),
              const SizedBox(width: 6),
              Text(device.name,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: online ? Colors.greenAccent : Colors.redAccent,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(online ? '在线' : '离线',
                    style: const TextStyle(color: Colors.white, fontSize: 11)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            online ? '${device.currentTemp.toStringAsFixed(0)}°' : '--',
            style: const TextStyle(
                color: Colors.white, fontSize: 56, fontWeight: FontWeight.w300),
          ),
          const SizedBox(height: 4),
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
