// 部门 Provider（Phase 2）

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/department.dart';
import '../repositories/mock_department_repository.dart';

final departmentRepositoryProvider = Provider<MockDepartmentRepository>((ref) {
  return MockDepartmentRepository();
});

/// 整棵部门树
final departmentTreeProvider =
    FutureProvider.autoDispose<List<Department>>((ref) async {
  return ref.watch(departmentRepositoryProvider).tree();
});

/// 当前选中的部门 id
final selectedDepartmentIdProvider = StateProvider<String?>((ref) => null);
