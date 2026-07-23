// 工资条 Mock 仓库
// 文档：docs/05-架构/网络层与Mock.md

import 'dart:async';

import '../models/payroll_item.dart';
import '../models/payroll_slip.dart';

class MockPayrollRepository {
  MockPayrollRepository({this._currentEmployeeId = 'mock-user-001'});

  final String _currentEmployeeId;
  List<PayrollSlip>? _data;

  /// 模拟网络延迟
  Future<T> _delay<T>(T Function() cb) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return cb();
  }

  List<PayrollSlip> _ensureData() {
    if (_data != null) return _data!;
    _data = _seed();
    return _data!;
  }

  /// 获取当前用户的工资条列表（最新在前）
  Future<List<PayrollSlip>> list({PayrollSlipStatus? filter}) async {
    return _delay(() {
      var result = _ensureData().where((s) => s.employeeId == _currentEmployeeId).toList()
        ..sort((a, b) {
          final cmp = b.year.compareTo(a.year);
          return cmp != 0 ? cmp : b.month.compareTo(a.month);
        });
      if (filter != null) {
        result = result.where((s) => s.status == filter).toList();
      }
      return result;
    });
  }

  /// 获取单条工资条
  Future<PayrollSlip?> getById(String id) async {
    return _delay(() => _ensureData().firstWhere((s) => s.id == id));
  }

  /// 标记为已查看
  Future<PayrollSlip> markViewed(String id) async {
    return _delay(() {
      final list = _ensureData();
      final idx = list.indexWhere((s) => s.id == id);
      if (idx < 0) throw Exception('工资条不存在');
      final slip = list[idx];
      final updated = slip.copyWith(
        status: slip.status == PayrollSlipStatus.published
            ? PayrollSlipStatus.viewed
            : slip.status,
        viewedAt: slip.viewedAt ?? DateTime.now(),
      );
      list[idx] = updated;
      return updated;
    });
  }

  /// 标记为已下载
  Future<PayrollSlip> markDownloaded(String id) async {
    return _delay(() {
      final list = _ensureData();
      final idx = list.indexWhere((s) => s.id == id);
      if (idx < 0) throw Exception('工资条不存在');
      final slip = list[idx];
      final updated = slip.copyWith(
        status: PayrollSlipStatus.downloaded,
        downloadedAt: slip.downloadedAt ?? DateTime.now(),
      );
      list[idx] = updated;
      return updated;
    });
  }

  List<PayrollSlip> _seed() {
    // 生成最近 12 个月的假工资条
    final now = DateTime.now();
    final slips = <PayrollSlip>[];
    for (var i = 0; i < 12; i++) {
      final date = DateTime(now.year, now.month - i);
      final slip = _generateSlip(date);
      slips.add(slip);
    }
    return slips;
  }

  PayrollSlip _generateSlip(DateTime date) {
    const baseSalary = 12000.0;
    final overtime = (date.month % 3 == 0) ? 1800.0 : 800.0;
    final bonus = (date.month % 6 == 0) ? 3000.0 : 500.0;
    const allowance = 800.0;

    const social = baseSalary * 0.105; // 10.5% 社保
    const housing = baseSalary * 0.07; // 7% 公积金
    final taxable = baseSalary + overtime + bonus + allowance - social - housing - 5000;
    final tax = taxable > 0 ? _calcTax(taxable) : 0.0;

    final items = [
      const PayrollItem(name: '基本工资', amount: baseSalary, type: PayrollItemType.earning),
      PayrollItem(name: '加班费', amount: overtime, type: PayrollItemType.earning, description: '${(overtime / 100).round()} 小时'),
      PayrollItem(name: '绩效奖金', amount: bonus, type: PayrollItemType.earning),
      const PayrollItem(name: '岗位津贴', amount: allowance, type: PayrollItemType.earning),
      const PayrollItem(name: '社保', amount: social, type: PayrollItemType.deduction, description: '养老+医疗+失业'),
      const PayrollItem(name: '公积金', amount: housing, type: PayrollItemType.deduction),
      PayrollItem(name: '个人所得税', amount: tax, type: PayrollItemType.deduction),
    ];

    final gross = items
        .where((i) => i.type == PayrollItemType.earning)
        .fold<double>(0, (s, i) => s + i.amount);
    final deduction = items
        .where((i) => i.type == PayrollItemType.deduction)
        .fold<double>(0, (s, i) => s + i.amount);

    // 当月已发布，前几个月已查看/已下载，最旧的几条待发布
    PayrollSlipStatus status;
    DateTime? publishedAt;
    DateTime? viewedAt;
    DateTime? downloadedAt;

    final now = DateTime.now();
    final monthsAgo = (now.year - date.year) * 12 + (now.month - date.month);

    if (monthsAgo == 0) {
      status = PayrollSlipStatus.published;
      publishedAt = DateTime(date.year, date.month, 8);
    } else if (monthsAgo <= 2) {
      status = PayrollSlipStatus.downloaded;
      publishedAt = DateTime(date.year, date.month, 8);
      viewedAt = publishedAt.add(const Duration(days: 1));
      downloadedAt = viewedAt.add(const Duration(days: 2));
    } else if (monthsAgo <= 6) {
      status = PayrollSlipStatus.viewed;
      publishedAt = DateTime(date.year, date.month, 8);
      viewedAt = publishedAt.add(const Duration(days: 1));
    } else {
      status = PayrollSlipStatus.pending;
    }

    return PayrollSlip(
      id: 'slip-${date.year}-${date.toString().padLeft(2, '0')}-$_currentEmployeeId',
      employeeId: _currentEmployeeId,
      employeeName: '张优腾',
      employeeCode: 'E0001',
      year: date.year,
      month: date.month,
      items: items,
      grossIncome: gross,
      totalDeduction: deduction,
      netIncome: gross - deduction,
      status: status,
      publishedAt: publishedAt,
      viewedAt: viewedAt,
      downloadedAt: downloadedAt,
    );
  }

  /// 个税简易计算（累进）
  double _calcTax(double taxable) {
    if (taxable <= 3000) return taxable * 0.03;
    if (taxable <= 12000) return 3000 * 0.03 + (taxable - 3000) * 0.10;
    if (taxable <= 25000) return 3000 * 0.03 + 9000 * 0.10 + (taxable - 12000) * 0.20;
    return 3000 * 0.03 + 9000 * 0.10 + 13000 * 0.20 + (taxable - 25000) * 0.25;
  }
}
