// 登录庆典弹窗触发器：挂在 dashboard（登录后落地页），首帧后按「每日一次」守卫
// 弹出当前用户今日庆典弹窗。失败静默（不影响使用）。渲染自身不可见。
// 文档：docs/00-项目准则/06-动画规范.md。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/shared_providers.dart';
import '../models/notice.dart';
import '../providers/notice_providers.dart';
import 'celebration_login_dialog.dart';

/// 庆典弹窗每日一次守卫键（SharedPreferences）：值为 yyyy-MM-dd。
const String kCelebrationPopupLastShown = 'celebration_popup_last_shown';

class CelebrationPopupGate extends ConsumerStatefulWidget {
  const CelebrationPopupGate({super.key});

  @override
  ConsumerState<CelebrationPopupGate> createState() =>
      _CelebrationPopupGateState();
}

class _CelebrationPopupGateState extends ConsumerState<CelebrationPopupGate> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShow());
  }

  Future<void> _maybeShow() async {
    if (!mounted || _busy) return;
    _busy = true;
    try {
      final cached = ref.read(myCelebrationTodayProvider).valueOrNull;
      final List<MyCelebrationToday> list;
      if (cached != null) {
        list = cached;
      } else {
        list = await ref.read(myCelebrationTodayProvider.future);
      }
      if (!mounted || list.isEmpty) return;
      await _showIfDue(list.first);
    } catch (_) {
      // 庆典弹窗失败不影响主流程。
    } finally {
      if (mounted) _busy = false;
    }
  }

  Future<void> _showIfDue(MyCelebrationToday celebration) async {
    final prefs = ref.read(sharedPreferencesProvider);
    final today = _todayKey();
    // 今天已弹过 → 跳过（一天多次登录只显一次）。
    if (prefs.getString(kCelebrationPopupLastShown) == today) return;
    await prefs.setString(kCelebrationPopupLastShown, today);
    if (!mounted) return;
    await showCelebrationLoginDialog(context, ref, celebration);
  }

  String _todayKey() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)}';
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
