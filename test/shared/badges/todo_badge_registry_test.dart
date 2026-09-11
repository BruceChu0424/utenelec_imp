// 待办徽章聚合契约（shared/badges/todo_badge_registry.dart）：
//
//  1. 容器徽章 = 其内部入口徽章之和（不许外层写 1、内层合计 5）；
//  2. 导航总数 = 各容器之和 = 全部登记入口之和（没有入口漏在容器外）；
//  3. 每个入口都必须恰好读一个计数源（新增入口忘接源 / 多读一个源导致同一件活
//     被数两遍，都会在这里炸）。普通入口原样返回；**草稿入口是一个源里切若干类
//     求和**，期望值 = 桩值 × 该模块的草稿类数（本文件独立重述这张映射表）；
//  4. 草稿 2026-09-11 起**登记在册并参与累加**（用户口径反转，见
//     docs/00-项目准则/14-徽章与计数口径.md §草稿）；report / history / record
//     这类浏览型语义仍然不得登记。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/providers/production_pending_provider.dart';
import 'package:uten_imp/features/production/repositories/production_execution_workbench_repository.dart';
import 'package:uten_imp/shared/badges/todo_badge_registry.dart';
import 'package:uten_imp/shared/providers/draft_counts_provider.dart';

/// `ref.watch` 替身：所有「计数型」provider 一律返回 [count]，
/// 权限门（`bool` / `Set<String>`）返回放行值。
///
/// 因为它不看 provider 是谁，只看返回类型，所以「入口算出来 == count」
/// 等价于断言「该入口恰好读了一个计数源、且原样返回」。
T Function<T>(ProviderListenable<T>) _watchReturning(int count) {
  return <T>(ProviderListenable<T> provider) => _stubValue<T>(count) as T;
}

Object _stubValue<T>(int count) {
  if (T == int) return count;
  // 超管放行：让带权限门的入口（如 IQC 驳回）走到真正的计数源。
  if (T == bool) return true;
  if (T == AsyncValue<int>) return AsyncValue<int>.data(count);
  if (T == ProductionPendingCount) return ProductionPendingCount(count, 0);
  if (T == WorkshopTaskCountBreakdown) {
    return WorkshopTaskCountBreakdown(count: count);
  }
  if (T == Set<String>) return <String>{};
  // 草稿入口读的是整份快照：每一类都桩成 count，好让「切了几类」显形。
  if (T == AsyncValue<DraftCounts>) {
    return AsyncValue<DraftCounts>.data(_uniformDraftCounts(count));
  }
  throw UnsupportedError('计数源返回了未知类型 $T，请同步更新本测试的桩');
}

/// 每一类草稿都等于 [count] 的快照（含两个仓库切片，用来验证它们没被重复加）。
DraftCounts _uniformDraftCounts(int count) => DraftCounts(
  salesOrder: count,
  salesShipment: count,
  salesReturn: count,
  salesQuote: count,
  purchaseOrder: count,
  subcontractOrder: count,
  stockDocument: count,
  productionPlan: count,
  productionDailyReport: count,
  financeReceipt: count,
  financePayment: count,
  financeExpense: count,
  financeOtherIncome: count,
  financeBankTransfer: count,
  purchaseReceipt: count,
  purchaseReturn: count,
  subcontractReturn: count,
  subcontractMaterialReturn: count,
  subcontractWaste: count,
  stockTransfer: count,
  stockCheck: count,
);

/// 各草稿入口切了几类单据——本文件**独立重述**注册表里的那张映射，
/// 两边不一致就说明有人改了切片却没更新契约。
const Map<TodoEntry, int> _draftKinds = {
  TodoEntry.salesDrafts: 4, // 订货 / 发货 / 退货 / 报价
  TodoEntry.purchaseDrafts: 3, // 订货 / 收货 / 退货
  TodoEntry.subcontractDrafts: 4, // 订货 / 成品退 / 余料退 / 废品
  TodoEntry.financeDrafts: 5, // 收 / 付 / 费用 / 其它收入 / 银行转账
  TodoEntry.warehouseDrafts: 1, // 只取 stockDocument 整表合计，切片不加（会双计）
  TodoEntry.productionDrafts: 2, // 计划 / 日报
};

/// 该入口在桩值 [count] 下应得的数字。
int _expected(TodoEntry entry, int count) => count * (_draftKinds[entry] ?? 1);

void main() {
  test('每个入口都归属且仅归属一个容器', () {
    final byModule = <TodoEntry>[
      for (final module in TodoModule.values) ...entriesOfModule(module),
    ];
    expect(
      byModule.toSet().length,
      TodoEntry.values.length,
      reason: '有入口重复登记在多个容器，会被父层数两遍',
    );
    expect(
      byModule.length,
      TodoEntry.values.length,
      reason: '有入口没被任何容器收走，父层就会漏数',
    );
  });

  test('每个入口恰好读一个计数源（草稿入口按其切片类数求和）', () {
    final watch = _watchReturning(7);
    for (final entry in TodoEntry.values) {
      expect(
        todoEntryCount(entry, watch),
        _expected(entry, 7),
        reason:
            '入口 $entry 的计数不等于其唯一计数源——要么没接源，'
            '要么读了两个源把同一件活数了两遍；草稿入口则是切片类数对不上',
      );
    }
  });

  test('仓库草稿只取整表合计，不把 doc_type 切片再加一遍', () {
    // stockDocument 是 8 类仓库单据的合计，stockTransfer/stockCheck 是其中两类的
    // 切片。三者相加 = 同一张单数两遍，这正是 2026-09-11 接草稿累加时最容易踩的坑。
    const snapshot = DraftCounts(
      stockDocument: 10,
      stockTransfer: 3,
      stockCheck: 4,
    );
    expect(
      todoEntryCount(
        TodoEntry.warehouseDrafts,
        <T>(ProviderListenable<T> provider) =>
            const AsyncValue<DraftCounts>.data(snapshot) as T,
      ),
      10,
      reason: '仓库草稿必须等于 stockDocument 合计，加上切片就是 17（双计）',
    );
  });

  test('容器徽章 = 其内部入口之和；导航总数 = 各容器之和', () {
    final watch = _watchReturning(1);

    var moduleTotal = 0;
    for (final module in TodoModule.values) {
      final expected = entriesOfModule(
        module,
      ).fold<int>(0, (sum, entry) => sum + todoEntryCount(entry, watch));
      final actual = todoModuleCount(module, watch);
      expect(actual, expected, reason: '容器 $module 的徽章数必须等于其内部入口之和');
      // 桩值 1 → 容器数 == 各入口期望值之和（草稿入口按切片类数计），
      // 顺带盯住分组本身。
      expect(
        actual,
        entriesOfModule(
          module,
        ).fold<int>(0, (sum, entry) => sum + _expected(entry, 1)),
      );
      moduleTotal += actual;
    }

    expect(
      sumTodoEntries(TodoEntry.values, watch),
      moduleTotal,
      reason: '导航总数必须等于各容器之和',
    );
    expect(
      moduleTotal,
      TodoEntry.values.fold<int>(0, (sum, e) => sum + _expected(e, 1)),
    );
  });

  test('采购/委外容器各含两个入口——修复「外层 1、内层 5」的历史口径', () {
    // 历史上工作台「采购管理」卡只数任务中心，hub 里的「待退回供应商」被漏掉。
    expect(entriesOfModule(TodoModule.purchase), <TodoEntry>[
      TodoEntry.purchaseTaskCenter,
      TodoEntry.purchaseSupplierReturn,
      TodoEntry.purchaseDrafts,
    ]);
    expect(entriesOfModule(TodoModule.subcontract), <TodoEntry>[
      TodoEntry.subcontractTaskCenter,
      TodoEntry.subcontractSupplierReturn,
      TodoEntry.subcontractDrafts,
    ]);

    final watch = _watchReturning(3);
    // 任务中心 3 + 待退回 3 + 草稿 3×3 类 = 15；委外草稿 4 类 → 3+3+12 = 18。
    expect(todoModuleCount(TodoModule.purchase, watch), 15);
    expect(todoModuleCount(TodoModule.subcontract, watch), 18);
  });

  test('仓库容器 = 7 个分段入口 + 1 条草稿入口', () {
    expect(entriesOfModule(TodoModule.warehouse), hasLength(8));
    // 7 个分段各 2 + 草稿（只取 stockDocument 一类）2 = 16。
    expect(todoModuleCount(TodoModule.warehouse, _watchReturning(2)), 16);
  });

  test('钱流容器含 IQC 驳回入口（此前只在 hub 上有徽章、没进工作台累加）', () {
    expect(
      entriesOfModule(TodoModule.finance),
      contains(TodoEntry.financeIqcRejection),
    );
  });

  test('草稿每模块恰好一条入口；报表/历史/记录仍不得登记', () {
    // 2026-09-11 口径反转：草稿改红徽章并参与累加，所以它**在**注册表里，
    // 但每个模块只能有一条（多切一条就会把同一批草稿数两遍）。
    final draftEntries = TodoEntry.values
        .where((e) => e.name.toLowerCase().contains('draft'))
        .toList();
    expect(
      draftEntries.toSet(),
      _draftKinds.keys.toSet(),
      reason: '草稿入口集合与本文件重述的切片映射必须一一对应',
    );
    for (final entry in draftEntries) {
      expect(
        draftEntries.where((e) => e.module == entry.module),
        hasLength(1),
        reason: '模块 ${entry.module} 有多条草稿入口，同一批草稿会被数两遍',
      );
    }
    // 报表 / 历史 / 记录这类纯浏览集合仍然不许进待办累加。
    for (final entry in TodoEntry.values) {
      final name = entry.name.toLowerCase();
      for (final forbidden in const ['report', 'history', 'record']) {
        expect(
          name.contains(forbidden),
          isFalse,
          reason: '浏览型入口 $entry 不得登记为待办（会污染待办总数）',
        );
      }
    }
  });

  test('全部计数源为 0 时，容器与总数都为 0（徽章整个不渲染）', () {
    final watch = _watchReturning(0);
    for (final module in TodoModule.values) {
      expect(todoModuleCount(module, watch), 0);
    }
    expect(sumTodoEntries(TodoEntry.values, watch), 0);
  });
}
