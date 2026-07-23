// 部门 Mock 仓库（Phase 2）

import '../models/department.dart';

class MockDepartmentRepository {
  List<Department>? _data;

  Future<T> _delay<T>(T Function() cb) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return cb();
  }

  /// 返回整棵部门树（根节点列表，含 children）
  Future<List<Department>> tree() async {
    return _delay(() => [..._ensure()]);
  }

  List<Department> _ensure() {
    if (_data != null) return _data!;
    _data = _seed();
    return _data!;
  }

  List<Department> _seed() {
    return [
      const Department(
        id: 'dept-prod',
        code: 'DEPT-PROD',
        name: '生产部',
        managerName: '张优腾',
        sortOrder: 1,
        headcount: 6,
        children: [
          Department(
            id: 'dept-prod-1',
            code: 'DEPT-PROD-1',
            name: '一车间',
            parentId: 'dept-prod',
            sortOrder: 1,
            headcount: 3,
          ),
          Department(
            id: 'dept-prod-2',
            code: 'DEPT-PROD-2',
            name: '二车间',
            parentId: 'dept-prod',
            sortOrder: 2,
            headcount: 3,
          ),
        ],
      ),
      const Department(
        id: 'dept-qc',
        code: 'DEPT-QC',
        name: '质量部',
        managerName: '孙伟',
        sortOrder: 2,
        headcount: 2,
      ),
      const Department(
        id: 'dept-hr',
        code: 'DEPT-HR',
        name: '人事部',
        managerName: '吴经理',
        sortOrder: 3,
        headcount: 2,
      ),
      const Department(
        id: 'dept-fin',
        code: 'DEPT-FIN',
        name: '财务部',
        managerName: '冯总监',
        sortOrder: 4,
        headcount: 1,
      ),
    ];
  }
}
