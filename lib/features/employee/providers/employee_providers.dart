// 员工 Provider（Phase 2）
// 文档：docs/05-架构/状态管理.md

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/employee.dart';
import '../repositories/mock_employee_repository.dart';

final employeeRepositoryProvider = Provider<MockEmployeeRepository>((ref) {
  return MockEmployeeRepository();
});

/// 搜索关键字
final employeeSearchProvider = StateProvider<String>((ref) => '');

/// 状态筛选（多选；空集合 = 全部）
final employeeStatusFilterProvider =
    StateProvider<Set<EmployeeStatus>>((ref) => const {});

final employeeListProvider = AsyncNotifierProvider.autoDispose<
    EmployeeListNotifier, List<Employee>>(
  EmployeeListNotifier.new,
);

class EmployeeListNotifier extends AutoDisposeAsyncNotifier<List<Employee>> {
  @override
  Future<List<Employee>> build() async {
    final search = ref.watch(employeeSearchProvider);
    final statuses = ref.watch(employeeStatusFilterProvider);
    final repo = ref.watch(employeeRepositoryProvider);
    return repo.list(search: search, statuses: statuses);
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final search = ref.read(employeeSearchProvider);
      final statuses = ref.read(employeeStatusFilterProvider);
      return ref.read(employeeRepositoryProvider).list(
            search: search,
            statuses: statuses,
          );
    });
  }
}

/// 详情
final employeeDetailProvider =
    FutureProvider.autoDispose.family<Employee?, String>((ref, id) async {
  return ref.watch(employeeRepositoryProvider).getById(id);
});

/// 部门列表（筛选用）
final employeeDepartmentListProvider =
    FutureProvider.autoDispose<List<String>>((ref) async {
  return ref.watch(employeeRepositoryProvider).departments();
});
