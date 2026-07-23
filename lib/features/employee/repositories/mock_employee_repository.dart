// 员工 Mock 仓库（Phase 2）
// 文档：docs/05-架构/网络层与Mock.md

import '../models/employee.dart';

class MockEmployeeRepository {
  MockEmployeeRepository();

  List<Employee>? _data;

  Future<T> _delay<T>(T Function() cb) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return cb();
  }

  List<Employee> _ensureData() {
    if (_data != null) return _data!;
    _data = _seed();
    return _data!;
  }

  /// 列表（带搜索 / 状态筛选 / 部门筛选）
  Future<List<Employee>> list({
    String? search,
    Set<EmployeeStatus>? statuses,
    String? department,
  }) async {
    return _delay(() {
      var result = [..._ensureData()];

      if (department != null && department.isNotEmpty) {
        result = result.where((e) => e.department == department).toList();
      }
      if (statuses != null && statuses.isNotEmpty) {
        result = result.where((e) => statuses.contains(e.status)).toList();
      }
      if (search != null && search.trim().isNotEmpty) {
        final q = search.trim().toLowerCase();
        result = result.where((e) {
          return e.fullName.toLowerCase().contains(q) ||
              e.code.toLowerCase().contains(q);
        }).toList();
      }

      result.sort((a, b) => a.code.compareTo(b.code));
      return result;
    });
  }

  Future<Employee?> getById(String id) async {
    return _delay(() => _ensureData().firstWhere((e) => e.id == id));
  }

  /// 所有部门（用于筛选）
  Future<List<String>> departments() async {
    return _delay(() {
      final set = _ensureData().map((e) => e.department).toSet();
      return set.toList()..sort();
    });
  }

  List<Employee> _seed() {
    final now = DateTime.now();
    DateTime c(int y, int m, int d) => DateTime(y, m, d);
    return [
      Employee(
        id: 'emp-001',
        code: 'E0001',
        fullName: '张优腾',
        gender: Gender.male,
        birthDate: c(1988, 3, 12),
        idCard: '320106198803120015',
        phone: '13812345678',
        email: 'zhang@uten.com',
        department: '生产部',
        position: '生产经理',
        supervisorName: '王总',
        hireDate: c(2018, 5, 8),
        status: EmployeeStatus.active,
        employmentType: EmploymentType.regular,
        contractStart: c(2022, 5, 8),
        contractEnd: c(2026, 5, 8),
        baseSalary: 18000,
        bankAccount: '6222021234567890123',
        history: [
          EmploymentHistoryRecord(
            type: HistoryEventType.onboard,
            title: '入职 · 生产部 · 操作工',
            date: c(2018, 5, 8),
          ),
          EmploymentHistoryRecord(
            type: HistoryEventType.transfer,
            title: '调岗 · 班长',
            date: c(2020, 6, 1),
            remark: '一车间表现优秀，晋升班长',
          ),
          EmploymentHistoryRecord(
            type: HistoryEventType.transfer,
            title: '晋升 · 生产经理',
            date: c(2022, 5, 8),
          ),
        ],
      ),
      Employee(
        id: 'emp-002',
        code: 'E0002',
        fullName: '李秀英',
        gender: Gender.female,
        birthDate: c(1992, 7, 22),
        idCard: '320105199207220028',
        phone: '13900001111',
        email: 'li@uten.com',
        department: '生产部',
        position: '一线操作工',
        supervisorName: '张优腾',
        hireDate: c(2021, 3, 1),
        status: EmployeeStatus.active,
        employmentType: EmploymentType.regular,
        contractStart: c(2021, 3, 1),
        contractEnd: c(2025, 3, 1),
        baseSalary: 7500,
        bankAccount: '6222020987654321098',
        history: [
          EmploymentHistoryRecord(
            type: HistoryEventType.onboard,
            title: '入职 · 生产部 · 操作工',
            date: c(2021, 3, 1),
          ),
        ],
      ),
      Employee(
        id: 'emp-003',
        code: 'E0003',
        fullName: '王强',
        gender: Gender.male,
        birthDate: c(1990, 1, 5),
        idCard: '320104199001050031',
        phone: '13700002222',
        department: '生产部',
        position: '一线操作工',
        supervisorName: '张优腾',
        hireDate: c(2022, 9, 1),
        status: EmployeeStatus.probation,
        employmentType: EmploymentType.regular,
        history: [
          EmploymentHistoryRecord(
            type: HistoryEventType.onboard,
            title: '入职 · 生产部 · 操作工（试用期）',
            date: c(2022, 9, 1),
          ),
        ],
      ),
      Employee(
        id: 'emp-004',
        code: 'E0004',
        fullName: '赵敏',
        gender: Gender.female,
        birthDate: c(1995, 11, 18),
        idCard: '320103199511180044',
        phone: '13600003333',
        email: 'zhao@uten.com',
        department: '质量部',
        position: '质检员',
        supervisorName: '钱主管',
        hireDate: c(2020, 4, 15),
        status: EmployeeStatus.active,
        employmentType: EmploymentType.regular,
        baseSalary: 8200,
        history: [
          EmploymentHistoryRecord(
            type: HistoryEventType.onboard,
            title: '入职 · 质量部 · 质检员',
            date: c(2020, 4, 15),
          ),
        ],
      ),
      Employee(
        id: 'emp-005',
        code: 'E0005',
        fullName: '孙伟',
        gender: Gender.male,
        birthDate: c(1989, 6, 30),
        idCard: '320102198906300057',
        phone: '13500004444',
        department: '质量部',
        position: '质量主管',
        hireDate: c(2017, 2, 10),
        status: EmployeeStatus.onLeave,
        employmentType: EmploymentType.regular,
        baseSalary: 15000,
        history: [
          EmploymentHistoryRecord(
            type: HistoryEventType.onboard,
            title: '入职 · 质量部',
            date: c(2017, 2, 10),
          ),
          EmploymentHistoryRecord(
            type: HistoryEventType.transfer,
            title: '晋升 · 质量主管',
            date: c(2019, 8, 1),
          ),
        ],
      ),
      Employee(
        id: 'emp-006',
        code: 'E0006',
        fullName: '周婷',
        gender: Gender.female,
        birthDate: c(1998, 2, 14),
        idCard: '320101199802140063',
        phone: '13400005555',
        email: 'zhou@uten.com',
        department: '人事部',
        position: '人事专员',
        supervisorName: '吴经理',
        hireDate: c(2023, 7, 1),
        status: EmployeeStatus.probation,
        employmentType: EmploymentType.regular,
        baseSalary: 7000,
        history: [
          EmploymentHistoryRecord(
            type: HistoryEventType.onboard,
            title: '入职 · 人事部 · 人事专员',
            date: c(2023, 7, 1),
          ),
        ],
      ),
      Employee(
        id: 'emp-007',
        code: 'E0007',
        fullName: '吴经理',
        gender: Gender.male,
        birthDate: c(1985, 9, 9),
        idCard: '320106198509090078',
        phone: '13300006666',
        email: 'wu@uten.com',
        department: '人事部',
        position: '人事经理',
        hireDate: c(2016, 1, 5),
        status: EmployeeStatus.active,
        employmentType: EmploymentType.regular,
        baseSalary: 20000,
        history: [
          EmploymentHistoryRecord(
            type: HistoryEventType.onboard,
            title: '入职 · 人事部',
            date: c(2016, 1, 5),
          ),
        ],
      ),
      Employee(
        id: 'emp-008',
        code: 'E0008',
        fullName: '郑飞',
        gender: Gender.male,
        birthDate: c(1993, 4, 25),
        idCard: '320105199304250082',
        phone: '13200007777',
        department: '财务部',
        position: '会计',
        supervisorName: '冯总监',
        hireDate: c(2019, 8, 20),
        status: EmployeeStatus.active,
        employmentType: EmploymentType.regular,
        baseSalary: 11000,
        history: [
          EmploymentHistoryRecord(
            type: HistoryEventType.onboard,
            title: '入职 · 财务部 · 会计',
            date: c(2019, 8, 20),
          ),
        ],
      ),
      Employee(
        id: 'emp-009',
        code: 'E0009',
        fullName: '陈晨',
        gender: Gender.female,
        birthDate: c(2000, 12, 3),
        idCard: '320104200012030099',
        phone: '13100008888',
        department: '生产部',
        position: '实习生',
        supervisorName: '张优腾',
        hireDate: c(now.year, now.month, 1),
        status: EmployeeStatus.probation,
        employmentType: EmploymentType.intern,
        baseSalary: 3000,
        history: [
          EmploymentHistoryRecord(
            type: HistoryEventType.onboard,
            title: '入职 · 生产部 · 实习生',
            date: c(now.year, now.month, 1),
          ),
        ],
      ),
      Employee(
        id: 'emp-010',
        code: 'E0010',
        fullName: '黄涛',
        gender: Gender.male,
        birthDate: c(1987, 10, 17),
        idCard: '320103198710170105',
        phone: '13000009999',
        department: '生产部',
        position: '设备工程师',
        supervisorName: '张优腾',
        hireDate: c(2015, 6, 1),
        status: EmployeeStatus.resigned,
        employmentType: EmploymentType.regular,
        history: [
          EmploymentHistoryRecord(
            type: HistoryEventType.onboard,
            title: '入职 · 生产部 · 设备工程师',
            date: c(2015, 6, 1),
          ),
          EmploymentHistoryRecord(
            type: HistoryEventType.resign,
            title: '离职 · 个人原因',
            date: c(2024, 3, 31),
            remark: '正常离职，已交接',
          ),
        ],
      ),
      Employee(
        id: 'emp-011',
        code: 'E0011',
        fullName: '林芳',
        gender: Gender.female,
        birthDate: c(1996, 8, 8),
        idCard: '320102199608080113',
        phone: '15900000001',
        email: 'lin@uten.com',
        department: '生产部',
        position: '一线操作工',
        supervisorName: '张优腾',
        hireDate: c(2022, 2, 14),
        status: EmployeeStatus.active,
        employmentType: EmploymentType.dispatch,
        baseSalary: 6800,
        history: [
          EmploymentHistoryRecord(
            type: HistoryEventType.onboard,
            title: '入职 · 生产部 · 操作工（劳务派遣）',
            date: c(2022, 2, 14),
          ),
        ],
      ),
      Employee(
        id: 'emp-012',
        code: 'E0012',
        fullName: '徐磊',
        gender: Gender.male,
        birthDate: c(1991, 5, 20),
        idCard: '320101199105200127',
        phone: '15900000002',
        department: '生产部',
        position: '班长',
        supervisorName: '张优腾',
        hireDate: c(2019, 10, 8),
        status: EmployeeStatus.active,
        employmentType: EmploymentType.regular,
        baseSalary: 9500,
        history: [
          EmploymentHistoryRecord(
            type: HistoryEventType.onboard,
            title: '入职 · 生产部 · 操作工',
            date: c(2019, 10, 8),
          ),
          EmploymentHistoryRecord(
            type: HistoryEventType.transfer,
            title: '调岗 · 班长',
            date: c(2023, 1, 15),
          ),
        ],
      ),
    ];
  }
}
