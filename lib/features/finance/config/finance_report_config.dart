// 钱流报表配置（财税部 → 钱流报表：5 张卡，镜像销售/采购「明细+汇总+单独卡」范式）。
//
// 5 张卡（finance_hub_page「钱流报表」分区）：
//   ① 应收应付 (Z)        → 左分类树 + 右Excel表（单独页 finance_ar_ap_overview_page）
//   ② 明细报表            → 本配置 detailCard（7 chip：应收/应付/收款/付款/费用/收入/费用冲销 明细）
//   ③ 汇总报表            → 本配置 summaryCard（6 chip：应收/应付/收款/付款/费用/收入 汇总）
//   ④ 往来对帐单 (I/J/K/L/X) → 单独页 finance_statement_page（客户/供应商选择 + 年度）
//   ⑤ 账户流水 (S/Q/R)     → 单独页 finance_account_flow_page（账户选择 + 银行存取空表）
//
// 后端：GET /api/finance/reports/{group}/{view} 返回 ReportTableResponse
//   { columns:[{key,label,type,width}], rows:[{...显示就绪}], facets, page, totalPages, total }。
//   rows 服务端 JOIN 出名称/人员(+子类括注)/总监/区域；facets 供表头 autofilter。
//
// 明细表：一行=单里一样货品/一笔（同单号可重复）；汇总表：一行=一整张单/一个往来单位。

/// 一个报表变体（卡内 ChoiceChip 的一项）。endpoint + 固定参数（如 direction=AR）。
class FinanceReportVariant {
  const FinanceReportVariant({
    required this.label,
    required this.endpoint,
    this.fixedParams = const {},
  });
  final String label;
  final String endpoint; // 如 '/finance/reports/ar-ap/detail'（apiClient 自动加 /api 前缀）
  final Map<String, String> fixedParams; // 如 {'direction':'AR'}（A/B 走 AR，C/D 走 AP）
}

/// 一张报表卡（一组 chip 切换的报表）。
class FinanceReportCard {
  const FinanceReportCard({required this.id, required this.title, required this.variants});
  final String id; // 路由用：detail | summary
  final String title;
  final List<FinanceReportVariant> variants;
}

/// ② 明细报表（7 chip）。A/C 走 ar-ap/detail（direction 区分）；E/G/M/O/V 走各自 detail。
const FinanceReportCard financeDetailCard = FinanceReportCard(
  id: 'detail',
  title: '钱流明细报表',
  variants: [
    FinanceReportVariant(label: '应收款明细', endpoint: '/finance/reports/ar-ap/detail', fixedParams: {'direction': 'AR'}),
    FinanceReportVariant(label: '应付款明细', endpoint: '/finance/reports/ar-ap/detail', fixedParams: {'direction': 'AP'}),
    FinanceReportVariant(label: '销售收款明细', endpoint: '/finance/reports/receipt/detail'),
    FinanceReportVariant(label: '采购付款明细', endpoint: '/finance/reports/payment/detail'),
    FinanceReportVariant(label: '一般费用明细', endpoint: '/finance/reports/expense/detail'),
    FinanceReportVariant(label: '其它收入明细', endpoint: '/finance/reports/income/detail'),
    FinanceReportVariant(label: '费用冲销明细', endpoint: '/finance/reports/fee-offset/detail'),
  ],
);

/// ③ 汇总报表（6 chip）。B/D 走 ar-ap/summary（direction 区分）；F/H/N/P 走各自 summary。
const FinanceReportCard financeSummaryCard = FinanceReportCard(
  id: 'summary',
  title: '钱流汇总报表',
  variants: [
    FinanceReportVariant(label: '应收款汇总', endpoint: '/finance/reports/ar-ap/summary', fixedParams: {'direction': 'AR'}),
    FinanceReportVariant(label: '应付款汇总', endpoint: '/finance/reports/ar-ap/summary', fixedParams: {'direction': 'AP'}),
    FinanceReportVariant(label: '销售收款汇总', endpoint: '/finance/reports/receipt/summary'),
    FinanceReportVariant(label: '采购付款汇总', endpoint: '/finance/reports/payment/summary'),
    FinanceReportVariant(label: '一般费用汇总', endpoint: '/finance/reports/expense/summary'),
    FinanceReportVariant(label: '其它收入汇总', endpoint: '/finance/reports/income/summary'),
  ],
);

/// ⑥ 对账单（5 chip，C2 财务 5 张手工对账单自动生成；模板列结构照抄附件 Excel）。
/// 委外加工/采购外放加工共用 subcontract 端点（附件 1 口径）；lossRate 默认 3%（后端参数）。
const FinanceReportCard financeReconCard = FinanceReportCard(
  id: 'recon',
  title: '对账单',
  variants: [
    FinanceReportVariant(label: '委外加工对账单', endpoint: '/finance/reports/statements/subcontract'),
    FinanceReportVariant(label: '采购外放加工对账单', endpoint: '/finance/reports/statements/subcontract'),
    FinanceReportVariant(label: '供应商对账单', endpoint: '/finance/reports/statements/supplier'),
    FinanceReportVariant(label: '其他应收款对账单', endpoint: '/finance/reports/statements/other-receivable'),
    FinanceReportVariant(label: '客户对账单', endpoint: '/finance/reports/statements/client'),
  ],
);

/// ⑦ 成本核算（8 chip，C4 王少春 4 项；附件 15/7/7-1/8/8-1/8-2/8-3）。
const FinanceReportCard financeCostCard = FinanceReportCard(
  id: 'cost',
  title: '成本核算',
  variants: [
    FinanceReportVariant(label: '产品成本汇总', endpoint: '/finance/reports/cost/product'),
    FinanceReportVariant(label: '销售成本核算汇总', endpoint: '/finance/reports/cost/sales-summary'),
    FinanceReportVariant(label: '铜柱加工费核算', endpoint: '/finance/reports/cost/copper-fee'),
    FinanceReportVariant(label: '插套酸洗入库明细', endpoint: '/finance/reports/cost/copper-pickling'),
    FinanceReportVariant(label: '塑料耗用明细', endpoint: '/finance/reports/cost/plastic'),
    FinanceReportVariant(label: '塑料领料明细', endpoint: '/finance/reports/cost/plastic-detail', fixedParams: {'kind': 'issue'}),
    FinanceReportVariant(label: '塑料退料明细', endpoint: '/finance/reports/cost/plastic-detail', fixedParams: {'kind': 'return'}),
    FinanceReportVariant(label: '产品入库明细', endpoint: '/finance/reports/cost/plastic-detail', fixedParams: {'kind': 'finished'}),
  ],
);

/// ⑧ 总账报表（8 chip，C3；附 9~16 + 科目余额表。year/month 由通用页 dateTo 推导）。
const FinanceReportCard financeGlCard = FinanceReportCard(
  id: 'gl',
  title: '总账报表',
  variants: [
    FinanceReportVariant(label: '科目余额表', endpoint: '/finance/reports/gl/trial-balance'),
    FinanceReportVariant(label: '资产负债表', endpoint: '/finance/reports/gl/balance-sheet'),
    FinanceReportVariant(label: '年度利润汇总表', endpoint: '/finance/reports/gl/profit-annual'),
    FinanceReportVariant(label: '月度利润表', endpoint: '/finance/reports/gl/profit-monthly'),
    FinanceReportVariant(label: '制造费用明细表', endpoint: '/finance/reports/gl/manufacturing-expense'),
    FinanceReportVariant(label: '管理费用明细表', endpoint: '/finance/reports/gl/admin-expense'),
    FinanceReportVariant(label: '销售费用明细表', endpoint: '/finance/reports/gl/sales-expense'),
    FinanceReportVariant(label: '经营损益表', endpoint: '/finance/reports/gl/operating-pl'),
    // C5 固定资产/长期待摊清单（管理 CRUD 走 /api/finance/fixed-assets|deferred-expenses，前端管理页待补）
    FinanceReportVariant(label: '固定资产折旧清单', endpoint: '/finance/reports/fa/depreciation-schedule'),
    FinanceReportVariant(label: '长期待摊摊销清单', endpoint: '/finance/reports/fa/amortization-schedule'),
  ],
);

/// 按 id 取卡片（路由参数 → 卡片）。
FinanceReportCard financeReportCardById(String id) {
  if (id == 'summary') return financeSummaryCard;
  if (id == 'recon') return financeReconCard;
  if (id == 'cost') return financeCostCard;
  if (id == 'gl') return financeGlCard;
  return financeDetailCard;
}
