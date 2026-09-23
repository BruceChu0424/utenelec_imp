// 黄色「进行中」注册表的累加契约(ADR-100)。
//
// 与红色那支(todo_badge_registry_test.dart)同构, 钉的是同三件事:
//   · 每个入口恰好读一个计数源(读两个就是同一件活数两遍);
//   · 容器 = 其内部入口之和, 导航总数 = 各容器之和(杜绝「外层写 1、内层合计 5」);
//   · 全部为 0 时整条链是 0(徽章整个不渲染)。
//
// 外加一件红色那支没有的事: **刻意不登记的模块必须保持空**。黄色最容易出的错
// 不是漏登记, 而是「哪张卡看着都该有个在办数字」, 顺手给钱流/品质也登记一条 ——
// 那些在办量早就被采购/仓库/销售那几张卡数过了, 再数一遍就是跨卡双计。
// 那几条判断的理由写在 in_progress_badge_registry.dart 末尾「已知重叠」一节。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/repositories/production_execution_workbench_repository.dart';
import 'package:uten_imp/shared/badges/in_progress_badge_registry.dart';

/// `ref.watch` 替身: 所有「计数型」provider 一律返回 [count]。
///
/// 它不看 provider 是谁、只看返回类型, 所以「入口算出来 == count」
/// 等价于断言「该入口恰好读了一个计数源、且原样返回」。
T Function<T>(ProviderListenable<T>) _watchReturning(int count) {
  return <T>(ProviderListenable<T> provider) => _stubValue<T>(count) as T;
}

Object _stubValue<T>(int count) {
  if (T == int) return count;
  if (T == bool) return true;
  if (T == AsyncValue<int>) return AsyncValue<int>.data(count);
  // 车间任务快照: **只有 inProgress 桩成 count**(与红色那支刚好相反, 它只桩 preparing)。
  // 红黄各读各的字段, 两支用例合起来把这条分工钉死: 谁读串了谁红。
  if (T == WorkshopTaskCountBreakdown) {
    return WorkshopTaskCountBreakdown(inProgress: count);
  }
  if (T == Set<String>) return <String>{};
  throw UnsupportedError('计数源返回了未知类型 $T, 请同步更新本测试的桩');
}

/// 刻意不登记黄色的容器 —— 每一条都是「登记了就跨卡双计」的判断, 不是遗漏。
/// 改这张表之前先读 in_progress_badge_registry.dart 末尾那一节。
const _modulesWithoutInProgress = <BadgeModule, String>{
  BadgeModule.finance: '财务的活全是审批队列: 球一旦离开财务就落在采购/仓库/销售那几张卡上',
  BadgeModule.quality: 'IQC/FQC 只有待检与已出结论两档, 没有在办态',
  BadgeModule.system: '服务器告警只有「还在报」与「已恢复」, 不是流程',
};

void main() {
  test('每个入口都归属且仅归属一个容器', () {
    final byModule = <InProgressEntry>[
      for (final module in BadgeModule.values)
        ...inProgressEntriesOfModule(module),
    ];
    expect(
      byModule.toSet().length,
      InProgressEntry.values.length,
      reason: '有入口重复登记在多个容器, 会被父层数两遍',
    );
    expect(
      byModule.length,
      InProgressEntry.values.length,
      reason: '有入口没被任何容器收走, 父层就会漏数',
    );
  });

  test('每个入口恰好读一个计数源', () {
    final watch = _watchReturning(7);
    for (final entry in InProgressEntry.values) {
      expect(
        inProgressEntryCount(entry, watch),
        7,
        reason:
            '入口 $entry 的计数不等于其唯一计数源——要么没接源, '
            '要么读了两个源把同一件活数了两遍',
      );
    }
  });

  test('容器徽章 = 其内部入口之和; 导航黄色总数 = 各容器之和', () {
    final watch = _watchReturning(1);

    var moduleTotal = 0;
    for (final module in BadgeModule.values) {
      final entries = inProgressEntriesOfModule(module);
      final actual = inProgressModuleCount(module, watch);
      expect(
        actual,
        entries.length,
        reason: '容器 $module 的黄徽章数必须等于其内部入口之和(桩值 1 时即入口个数)',
      );
      moduleTotal += actual;
    }

    expect(
      sumInProgressEntries(InProgressEntry.values, watch),
      moduleTotal,
      reason: '导航黄色总数必须等于各容器之和',
    );
    expect(moduleTotal, InProgressEntry.values.length);
  });

  test('刻意不登记黄色的容器必须保持空(登记了就是跨卡双计)', () {
    for (final entry in _modulesWithoutInProgress.entries) {
      expect(
        inProgressEntriesOfModule(entry.key),
        isEmpty,
        reason:
            '${entry.key} 不该有黄色入口: ${entry.value}。'
            '要推翻这条判断, 先改 in_progress_badge_registry.dart 末尾的「已知重叠」并说明理由',
      );
    }
  });

  test('生产两张卡各登记一条, 且分属不同视角(不是同一批活数两遍)', () {
    // 「生产管理」数的是计划员视角的批次, 「我的车间任务」数的是车间工视角的工单段,
    // 读取范围也不同(全部可见 vs 仅指派给本人)。两条都登记是有意为之, 所以这里
    // 正面钉住「恰好两条」——将来谁想合并成一条, 得先来改这个用例。
    expect(inProgressEntriesOfModule(BadgeModule.production), hasLength(2));
    expect(
      inProgressEntriesOfModule(BadgeModule.production),
      containsAll(const [
        InProgressEntry.productionBatches,
        InProgressEntry.productionWorkshop,
      ]),
    );
  });

  test('销售只登记订单进度一条(出货/订货/报价/退货四张卡不再各数一遍)', () {
    // 订单进度的「出货待财审 / 等仓库出货」本就是从出货单派生的, 单据卡再数一遍
    // 就是同一批出货翻倍。这是黄链里最容易复发的双计。
    expect(inProgressEntriesOfModule(BadgeModule.sales), const [
      InProgressEntry.salesOrderInFlight,
    ]);
  });

  test('仓库只登记「等待检查结果」一条(委外出库「等子件到货」不登记)', () {
    // 出库任务中心「委外出库」的等子件到货任务(ADR-103)只画在分段上: 那些委外单
    // 已全在委外任务中心的 IN_PROGRESS 黄数里, 仓库卡再数一遍是跨卡双计(与钱流
    // 不登记同理)。将来谁想给仓库卡补这枚黄, 得先来改这个用例和注册表末尾那一节。
    expect(inProgressEntriesOfModule(BadgeModule.warehouse), const [
      InProgressEntry.warehouseQualityWaiting,
    ]);
  });

  test('全部计数源为 0 时, 容器与总数都为 0(徽章整个不渲染)', () {
    final watch = _watchReturning(0);
    for (final module in BadgeModule.values) {
      expect(inProgressModuleCount(module, watch), 0);
    }
    expect(sumInProgressEntries(InProgressEntry.values, watch), 0);
  });
}
