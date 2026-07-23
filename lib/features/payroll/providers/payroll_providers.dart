// 工资条 Provider
// 文档：docs/05-架构/状态管理.md

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/payroll_slip.dart';
import '../repositories/mock_payroll_repository.dart';

/// Mock 仓库单例
final payrollRepositoryProvider = Provider<MockPayrollRepository>((ref) {
  return MockPayrollRepository();
});

/// 列表筛选状态
enum PayrollFilter { all, published, viewed, downloaded }

extension PayrollFilterValue on PayrollFilter {
  PayrollSlipStatus? get status => switch (this) {
        PayrollFilter.all => null,
        PayrollFilter.published => PayrollSlipStatus.published,
        PayrollFilter.viewed => PayrollSlipStatus.viewed,
        PayrollFilter.downloaded => PayrollSlipStatus.downloaded,
      };

  String get label => switch (this) {
        PayrollFilter.all => '全部',
        PayrollFilter.published => '已发布',
        PayrollFilter.viewed => '已查看',
        PayrollFilter.downloaded => '已下载',
      };
}

/// 当前选中的筛选
final payrollFilterProvider = StateProvider<PayrollFilter>((ref) {
  return PayrollFilter.all;
});

/// 工资条列表（按筛选自动刷新）
final payrollListProvider =
    AsyncNotifierProvider.autoDispose<PayrollListNotifier, List<PayrollSlip>>(
  PayrollListNotifier.new,
);

class PayrollListNotifier
    extends AutoDisposeAsyncNotifier<List<PayrollSlip>> {
  @override
  Future<List<PayrollSlip>> build() async {
    final filter = ref.watch(payrollFilterProvider);
    final repo = ref.watch(payrollRepositoryProvider);
    return repo.list(filter: filter.status);
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() {
      final filter = ref.read(payrollFilterProvider);
      return ref.read(payrollRepositoryProvider).list(filter: filter.status);
    });
  }
}

/// 单条工资条详情
final payrollDetailProvider =
    FutureProvider.autoDispose.family<PayrollSlip?, String>((ref, id) async {
  final repo = ref.watch(payrollRepositoryProvider);
  return repo.getById(id);
});

/// 标记已查看
Future<void> markPayrollViewed(WidgetRef ref, String id) async {
  await ref.read(payrollRepositoryProvider).markViewed(id);
  ref.invalidate(payrollDetailProvider(id));
  ref.invalidate(payrollListProvider);
}

/// 标记已下载
Future<void> markPayrollDownloaded(WidgetRef ref, String id) async {
  await ref.read(payrollRepositoryProvider).markDownloaded(id);
  ref.invalidate(payrollDetailProvider(id));
  ref.invalidate(payrollListProvider);
}
