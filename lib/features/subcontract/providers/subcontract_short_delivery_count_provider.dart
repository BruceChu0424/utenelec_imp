// ADR-098 委外回厂短交待判定计数（委外 hub「回厂短交判定」卡片徽章 + 判定页分段）。
//
// 口径由 /subcontract/short-deliveries/count 统一返回：pending = 待判定（含分批等待
// 已过预计到齐日）、waiting = 分批等待中。60s 轮询；有委外订货查看权限才拉取。
// 不登记进 todo_badge_registry：任务中心 /count 已把「回厂短交待判定」的订货单计入
// 委外红徽章，这里只是同数展示（准则 14：同一件事只数一次）。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../../../shared/auth/session_epoch_provider.dart';
import '../../../shared/providers/master_name_provider.dart'
    show masterDataSessionKeyProvider;
import '../../../shared/models/subcontract_short_delivery.dart';
import '../repositories/subcontract_short_delivery_repository.dart';

const Duration _kPollInterval = Duration(seconds: 60);

final subcontractShortDeliveryCountProvider =
    StateNotifierProvider<
      SubcontractShortDeliveryCountNotifier,
      SubcontractShortDeliveryCounts
    >((ref) {
      ref.watch(sessionEpochProvider);
      ref.watch(masterDataSessionKeyProvider);
      ref.watch(currentPermissionsProvider);
      ref.watch(isSuperAdminProvider);
      final notifier = SubcontractShortDeliveryCountNotifier(ref);
      notifier.start();
      ref.onDispose(notifier.stop);
      return notifier;
    });

class SubcontractShortDeliveryCountNotifier
    extends StateNotifier<SubcontractShortDeliveryCounts> {
  SubcontractShortDeliveryCountNotifier(this.ref)
    : super(const SubcontractShortDeliveryCounts());

  final Ref ref;
  Timer? _timer;
  bool _stopped = false;
  bool _loading = false;

  void start() {
    _tick();
    _timer = Timer.periodic(_kPollInterval, (_) => _tick());
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }

  /// 判定后立即重拉一次（不等下一轮询）。
  Future<void> refresh() => _tick();

  Future<void> _tick() async {
    if (_stopped || _loading) return;
    final perms = ref.read(currentPermissionsProvider);
    final allowed =
        perms.contains(Perm.subcontractOrderView) ||
        ref.read(isSuperAdminProvider);
    if (!allowed) {
      state = const SubcontractShortDeliveryCounts();
      return;
    }
    _loading = true;
    try {
      final counts = await ref
          .read(subcontractShortDeliveryRepositoryProvider)
          .counts();
      if (!_stopped) state = counts;
    } catch (_) {
      // 计数失败保持上次值（徽章不闪 0）。
    } finally {
      _loading = false;
    }
  }
}
