// 报销 Mock 仓库
// 文档：docs/05-架构/网络层与Mock.md

import 'dart:async';

import '../models/expense_claim.dart';
import '../models/expense_item.dart';

class MockExpenseRepository {
  MockExpenseRepository({this._currentEmployeeId = 'mock-user-001'});

  final String _currentEmployeeId;
  List<ExpenseClaim>? _data;

  Future<T> _delay<T>(T Function() cb) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return cb();
  }

  List<ExpenseClaim> _ensureData() {
    if (_data != null) return _data!;
    _data = _seed();
    return _data!;
  }

  /// 获取当前用户的报销单
  Future<List<ExpenseClaim>> list({ExpenseClaimStatus? filter}) async {
    return _delay(() {
      var result = _ensureData()
          .where((c) => c.applicantId == _currentEmployeeId)
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      if (filter != null) {
        result = result.where((c) => c.status == filter).toList();
      }
      return result;
    });
  }

  Future<ExpenseClaim?> getById(String id) async {
    return _delay(() => _ensureData().firstWhere((c) => c.id == id));
  }

  /// 新建报销单（草稿）
  Future<ExpenseClaim> create({
    required String title,
    required List<ExpenseItem> items,
    String? remark,
  }) async {
    return _delay(() {
      final total = items.fold<double>(0, (s, i) => s + i.amount);
      final claim = ExpenseClaim(
        id: 'claim-${DateTime.now().millisecondsSinceEpoch}',
        applicantId: _currentEmployeeId,
        applicantName: '张优腾',
        title: title,
        items: items,
        totalAmount: total,
        status: ExpenseClaimStatus.draft,
        createdAt: DateTime.now(),
        remark: remark,
      );
      _ensureData().insert(0, claim);
      return claim;
    });
  }

  /// 提交报销单
  Future<ExpenseClaim> submit(String id) async {
    return _delay(() {
      final list = _ensureData();
      final idx = list.indexWhere((c) => c.id == id);
      if (idx < 0) throw Exception('报销单不存在');
      final updated = list[idx].copyWith(
        status: ExpenseClaimStatus.submitted,
        submittedAt: DateTime.now(),
      );
      list[idx] = updated;
      return updated;
    });
  }

  /// 删除报销单（仅草稿可删）
  Future<void> delete(String id) async {
    return _delay(() {
      _ensureData().removeWhere((c) => c.id == id);
    });
  }

  /// 撤回报销单（已提交 → 草稿）
  Future<ExpenseClaim> withdraw(String id) async {
    return _delay(() {
      final list = _ensureData();
      final idx = list.indexWhere((c) => c.id == id);
      if (idx < 0) throw Exception('报销单不存在');
      final updated = list[idx].copyWith(
        status: ExpenseClaimStatus.draft,
      );
      list[idx] = updated;
      return updated;
    });
  }

  List<ExpenseClaim> _seed() {
    final now = DateTime.now();
    return [
      ExpenseClaim(
        id: 'claim-001',
        applicantId: _currentEmployeeId,
        applicantName: '张优腾',
        title: '上海客户拜访差旅',
        items: [
          ExpenseItem(
            id: 'i1',
            category: ExpenseCategory.transport,
            amount: 580,
            date: now.subtract(const Duration(days: 5)),
            description: '高铁往返',
          ),
          ExpenseItem(
            id: 'i2',
            category: ExpenseCategory.travel,
            amount: 880,
            date: now.subtract(const Duration(days: 5)),
            description: '酒店 1 晚',
          ),
          ExpenseItem(
            id: 'i3',
            category: ExpenseCategory.meal,
            amount: 156,
            date: now.subtract(const Duration(days: 4)),
          ),
        ],
        totalAmount: 1616,
        status: ExpenseClaimStatus.reviewing,
        createdAt: now.subtract(const Duration(days: 3)),
        submittedAt: now.subtract(const Duration(days: 3)),
        remark: '客户：上海优速电子',
      ),
      ExpenseClaim(
        id: 'claim-002',
        applicantId: _currentEmployeeId,
        applicantName: '张优腾',
        title: '6 月办公用品采购',
        items: [
          ExpenseItem(
            id: 'i1',
            category: ExpenseCategory.office,
            amount: 326,
            date: DateTime(now.year, now.month - 1, 15),
            description: 'A4 纸 + 笔',
          ),
        ],
        totalAmount: 326,
        status: ExpenseClaimStatus.paid,
        createdAt: DateTime(now.year, now.month - 1, 16),
        submittedAt: DateTime(now.year, now.month - 1, 16),
        approvedAt: DateTime(now.year, now.month - 1, 17),
        paidAt: DateTime(now.year, now.month - 1, 20),
      ),
      ExpenseClaim(
        id: 'claim-003',
        applicantId: _currentEmployeeId,
        applicantName: '张优腾',
        title: '北京行业展会差旅',
        items: [
          ExpenseItem(
            id: 'i1',
            category: ExpenseCategory.transport,
            amount: 1200,
            date: now.subtract(const Duration(days: 18)),
          ),
          ExpenseItem(
            id: 'i2',
            category: ExpenseCategory.travel,
            amount: 1760,
            date: now.subtract(const Duration(days: 18)),
            description: '酒店 2 晚',
          ),
        ],
        totalAmount: 2960,
        status: ExpenseClaimStatus.rejected,
        createdAt: now.subtract(const Duration(days: 15)),
        submittedAt: now.subtract(const Duration(days: 15)),
        rejectReason: '差旅住宿超过公司标准（800/晚），请调整后重新提交',
      ),
      ExpenseClaim(
        id: 'claim-004',
        applicantId: _currentEmployeeId,
        applicantName: '张优腾',
        title: '部门聚餐',
        items: [
          ExpenseItem(
            id: 'i1',
            category: ExpenseCategory.meal,
            amount: 880,
            date: now.subtract(const Duration(days: 1)),
            description: '部门月度聚餐',
          ),
        ],
        totalAmount: 880,
        status: ExpenseClaimStatus.draft,
        createdAt: now.subtract(const Duration(days: 1)),
      ),
    ];
  }
}
