package com.uten.imp.features.stock.ledger;

import java.util.Arrays;
import java.util.Optional;
import java.util.Set;
import java.util.stream.Collectors;

/**
 * 出入库流水的来源单据登记表 (stock_movements.source_doc_type → 单据头表、单号、往来方、查看权限)。
 *
 * <p>流水页的单号/往来方/单据种类全部由这里生成 SQL (每种来源一条带类型守卫的 LEFT JOIN, 只作用于当前页行),
 * 往来方名称的可见性也按这里登记的「能打开该来源单据的权限」判断 ({@link StockLedgerSourceAccess})。
 * 新来源 (如在途 V740 的 WORKSHOP_MATERIAL_COUNT: workshop_material_counts 没有单号, 单号取
 * '内料仓盘点 第' || period_no || '期', 往来方取车间) 只需在此加一个常量并覆盖需要的表达式。
 *
 * <p>权限码写成字面量: stock 不直接依赖 warehouse/purchase/sales 等特性 (ADR-017 依赖边)。
 */
public enum StockLedgerSource {
    PURCHASE_RECEIPT("PURCHASE_RECEIPT", "purchase_receipts", "src_pr", CounterpartKind.SUPPLIER, "supplier_id",
            "purchase_receipt:view", "warehouse_purchase_receipt_history:view"),
    PURCHASE_RETURN("PURCHASE_RETURN", "purchase_returns", "src_prt", CounterpartKind.SUPPLIER, "supplier_id",
            "purchase_return:view"),
    SALES_SHIPMENT("SALES_SHIPMENT", "sales_shipments", "src_ss", CounterpartKind.CLIENT, "client_id",
            "sales_shipment:view", "sales_other_shipment:view", "sales_shipment_finance:view",
            "warehouse_sales_outbound:view"),
    SALES_RETURN("SALES_RETURN", "sales_returns", "src_sr", CounterpartKind.CLIENT, "client_id",
            "sales_return:view"),
    SALES_OTHER_SHIPMENT("SALES_OTHER_SHIPMENT", "sales_other_shipments", "src_sos", CounterpartKind.CLIENT,
            "client_id", "sales_other_shipment:view"),
    SUBCONTRACT_RECEIPT("SUBCONTRACT_RECEIPT", "subcontract_receipts", "src_scr", CounterpartKind.SUBCONTRACTOR,
            "supplier_id", "subcontract_receipt:view", "warehouse_subcontract_receipt_history:view"),
    SUBCONTRACT_RETURN("SUBCONTRACT_RETURN", "subcontract_returns", "src_sct", CounterpartKind.SUBCONTRACTOR,
            "supplier_id", "subcontract_return:view", "warehouse_subcontract_finished_return_history:view"),
    SUBCONTRACT_MATERIAL_ISSUE("SUBCONTRACT_MATERIAL_ISSUE", "subcontract_material_issues", "src_smi",
            CounterpartKind.SUBCONTRACTOR, "supplier_id",
            "subcontract_material_issue:view", "warehouse_subcontract_outbound_history:view"),
    SUBCONTRACT_MATERIAL_RETURN("SUBCONTRACT_MATERIAL_RETURN", "subcontract_material_returns", "src_smr",
            CounterpartKind.SUBCONTRACTOR, "supplier_id",
            "subcontract_material_return:view", "warehouse_subcontract_material_return_history:view"),
    SUBCONTRACT_WASTE("SUBCONTRACT_WASTE", "subcontract_wastes", "src_sw", CounterpartKind.SUBCONTRACTOR,
            "supplier_id", "subcontract_waste:view", "warehouse_subcontract_waste_history:view"),
    /**
     * 仓库单据 (其它入/出、报废、领料、退料、产成品进/出仓、调拨、盘点): 单号只在 (doc_type, bill_no) 内唯一,
     * 所以同时下发 doc_type 作 sourceDocCode (前端按它开对应单据页)。往来方按单据种类取:
     * 领料/退料 = 车间 (department_id); 产成品进仓 = 日报车间 (没有时单据车间); 其余有供应商/客户的取之。
     * 调拨两腿的往来方是对方仓库, 由流水查询按对应腿统一给出 (不在这里)。
     */
    STOCK_DOC("STOCK_DOC", "stock_documents", "src_sd", null, null, "stock_doc:view") {
        @Override
        String extraJoins() {
            return "LEFT JOIN production_daily_reports src_sd_pdr ON src_sd_pdr.id = src_sd.source_daily_report_id\n";
        }

        @Override
        String docCodeExpr() {
            return "src_sd.doc_type";
        }

        @Override
        String counterpartKindExpr() {
            return """
                    CASE
                        WHEN src_sd.doc_type IN ('DRAW', 'WDRAW') AND src_sd.department_id IS NOT NULL THEN 'WORKSHOP'
                        WHEN src_sd.doc_type = 'FINISHED_IN'
                             AND COALESCE(src_sd_pdr.department_id, src_sd.department_id) IS NOT NULL THEN 'WORKSHOP'
                        WHEN src_sd.doc_type NOT IN ('DRAW', 'WDRAW', 'FINISHED_IN')
                             AND src_sd.supplier_id IS NOT NULL THEN 'SUPPLIER'
                        WHEN src_sd.doc_type NOT IN ('DRAW', 'WDRAW', 'FINISHED_IN')
                             AND src_sd.client_id IS NOT NULL THEN 'CLIENT'
                    END""";
        }

        @Override
        String counterpartIdExpr() {
            return """
                    CASE
                        WHEN src_sd.doc_type IN ('DRAW', 'WDRAW') THEN src_sd.department_id
                        WHEN src_sd.doc_type = 'FINISHED_IN'
                            THEN COALESCE(src_sd_pdr.department_id, src_sd.department_id)
                        ELSE COALESCE(src_sd.supplier_id, src_sd.client_id)
                    END""";
        }
    };

    /** 往来方种类: 名称分别取 suppliers / suppliers / clients / departments / warehouses。 */
    public enum CounterpartKind {
        SUPPLIER, SUBCONTRACTOR, CLIENT, WORKSHOP, WAREHOUSE
    }

    private final String code;
    private final String table;
    private final String alias;
    private final CounterpartKind counterpartKind;
    private final String counterpartColumn;
    private final Set<String> viewAuthorities;

    StockLedgerSource(String code, String table, String alias, CounterpartKind counterpartKind,
                      String counterpartColumn, String... viewAuthorities) {
        this.code = code;
        this.table = table;
        this.alias = alias;
        this.counterpartKind = counterpartKind;
        this.counterpartColumn = counterpartColumn;
        this.viewAuthorities = Set.copyOf(Arrays.asList(viewAuthorities));
    }

    /** stock_movements.source_doc_type 的值。 */
    public String code() {
        return code;
    }

    /** 能打开这类来源单据的权限 (持有任一即可看往来方名称)。 */
    public Set<String> viewAuthorities() {
        return viewAuthorities;
    }

    public static Optional<StockLedgerSource> of(String code) {
        if (code == null) {
            return Optional.empty();
        }
        for (StockLedgerSource source : values()) {
            if (source.code.equals(code)) {
                return Optional.of(source);
            }
        }
        return Optional.empty();
    }

    /** 单据头表额外需要的关联 (默认没有)。 */
    String extraJoins() {
        return "";
    }

    /** 单号表达式。 */
    String billNoExpr() {
        return alias + ".bill_no";
    }

    /** 单据种类表达式 (仓库单据的 doc_type; 其它来源为 null)。 */
    String docCodeExpr() {
        return null;
    }

    /** 往来方种类表达式 (字符串常量或 CASE)。 */
    String counterpartKindExpr() {
        return "CASE WHEN " + alias + "." + counterpartColumn + " IS NOT NULL THEN '" + counterpartKind.name() + "' END";
    }

    /** 往来方 id 表达式。 */
    String counterpartIdExpr() {
        return alias + "." + counterpartColumn;
    }

    /**
     * 全部来源单据头的 LEFT JOIN (每条带 source_doc_type 守卫, 一行最多命中一条)。
     *
     * @param row 流水行别名 (需有 source_doc_type / source_doc_id)
     */
    public static String joins(String row) {
        return Arrays.stream(values())
                .map(s -> "LEFT JOIN " + s.table + " " + s.alias + " ON " + row + ".source_doc_type = '" + s.code
                        + "' AND " + s.alias + ".id = " + row + ".source_doc_id\n" + s.extraJoins())
                .collect(Collectors.joining());
    }

    /** 单号: 按 source_doc_type 取对应单据头的单号。 */
    public static String billNoSelect(String row) {
        return caseBySource(row, StockLedgerSource::billNoExpr);
    }

    /** 单据种类 (仓库单据 doc_type)。 */
    public static String docCodeSelect(String row) {
        return caseBySource(row, StockLedgerSource::docCodeExpr);
    }

    /** 往来方种类 (不含调拨对方仓, 由调用方先判)。 */
    static String counterpartKindSelect(String row) {
        return caseBySource(row, StockLedgerSource::counterpartKindExpr);
    }

    /** 往来方 id (不含调拨对方仓, 由调用方先判)。 */
    static String counterpartIdSelect(String row) {
        return caseBySource(row, StockLedgerSource::counterpartIdExpr);
    }

    private static String caseBySource(String row, java.util.function.Function<StockLedgerSource, String> expr) {
        StringBuilder sql = new StringBuilder("CASE ").append(row).append(".source_doc_type");
        boolean any = false;
        for (StockLedgerSource source : values()) {
            String value = expr.apply(source);
            if (value == null) {
                continue;
            }
            any = true;
            sql.append(" WHEN '").append(source.code).append("' THEN ").append(value);
        }
        return any ? sql.append(" END").toString() : "CAST(NULL AS text)";
    }
}
