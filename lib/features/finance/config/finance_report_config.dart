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

/// 按 id 取卡片（路由参数 → 卡片）。
FinanceReportCard financeReportCardById(String id) {
  if (id == 'summary') return financeSummaryCard;
  return financeDetailCard;
}
