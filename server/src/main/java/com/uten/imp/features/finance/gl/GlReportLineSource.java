package com.uten.imp.features.finance.gl;

import com.uten.imp.common.util.NativeQueryResults;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Collection;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;

/**
 * 按 {@code finance_report_line_bindings} 为报表行取数(ADR-112)。每类来源一条分组语句,
 * 结果按「行 → 月(1..12)」返回; 没有绑定的行不出现在结果里, 由报表标注未配置。
 */
@Component
@RequiredArgsConstructor
class GlReportLineSource {

    private final EntityManager em;

    /** 一次读出这些行的全部绑定与目标名称。 */
    Bindings bindings(Collection<String> lineKeys) {
        Set<String> keys = new TreeSet<>(lineKeys);
        Map<String, List<String>> names = new HashMap<>();
        Set<String> zero=new TreeSet<>();
        if (!keys.isEmpty()) {
            List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                    SELECT binding.line_key, COALESCE(style.name, department.name)
                    FROM finance_report_line_bindings binding
                    LEFT JOIN payment_styles style ON style.id = binding.style_id
                    LEFT JOIN departments department ON department.id = binding.department_id
                    WHERE binding.line_key IN (:keys)
                    ORDER BY binding.line_key, COALESCE(style.path, department.path)
                    """).setParameter("keys", keys));
            for (Object[] row : rows) {
                names.computeIfAbsent((String) row[0], ignored -> new ArrayList<>()).add((String) row[1]);
            }
            for(Object key:em.createNativeQuery("SELECT line_key FROM finance_report_line_confirmations WHERE confirmed_zero AND line_key IN(:keys)")
                    .setParameter("keys",keys).getResultList())zero.add(key.toString());
        }
        return new Bindings(names,zero);
    }

    /** 绑定科目的月净额(费用借净; 收入贷净由 category 决定符号)。只算绑定的科目本身, 不含下级。 */
    Map<String, BigDecimal[]> styleMonthly(Collection<String> lineKeys, String category,
                                           LocalDate from, LocalDate toInclusive) {
        if (lineKeys.isEmpty()) return Map.of();
        return monthly(NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                WITH selected_styles AS (
                    SELECT DISTINCT binding.line_key,binding.style_id,style.category,
                        EXISTS(SELECT 1 FROM finance_chart_code_styles m JOIN finance_chart_codes c ON c.code=m.code
                               WHERE m.style_id=style.id AND c.code LIKE '4101%') AS manufacturing_cost,
                        (NOT style.is_deleted AND NOT EXISTS(SELECT 1 FROM payment_styles child WHERE child.parent_id=style.id AND NOT child.is_deleted)
                         AND (style.category=:category OR (:category='EXPENSE' AND style.category='ACCOUNT'
                           AND (binding.line_key LIKE 'MFG\\_%' OR binding.line_key LIKE 'OP\\_%')
                           AND fn_finance_cost_expense_style_allowed(style.id)))) AS valid
                    FROM finance_report_line_bindings binding LEFT JOIN payment_styles style ON style.id=binding.style_id
                    WHERE binding.binding_kind='STYLE' AND binding.line_key IN(:keys)
                ), line_styles AS (SELECT * FROM selected_styles WHERE valid), actual AS (
                    SELECT line_styles.line_key,EXTRACT(MONTH FROM entry.entry_date)::int AS month,
                        CASE WHEN bool_or(line_styles.manufacturing_cost AND fn_finance_manufacturing_occurrence(entry.id) IS NULL) THEN NULL ELSE
                          SUM(CASE WHEN line_styles.manufacturing_cost THEN fn_finance_manufacturing_occurrence(entry.id)
                            WHEN :category='INCOME' THEN -entry.direction*entry.amount ELSE entry.direction*entry.amount END) END AS amount
                    FROM line_styles JOIN gl_entries entry ON entry.style_id=line_styles.style_id AND NOT entry.is_deleted
                    JOIN gl_vouchers voucher ON voucher.id=entry.voucher_id AND public.fn_finance_gl_voucher_is_booked(voucher.id)
                    WHERE entry.entry_date BETWEEN :from AND :to AND NOT public.fn_finance_entry_is_pnl_closing(entry.id)
                    GROUP BY 1,2
                ), invalid AS (SELECT DISTINCT line_key FROM selected_styles WHERE NOT COALESCE(valid,false)), months AS (
                    SELECT line_key,month FROM actual UNION SELECT invalid.line_key,month FROM invalid CROSS JOIN generate_series(1,12) month
                )
                SELECT months.line_key,months.month,CASE WHEN invalid.line_key IS NOT NULL THEN NULL ELSE actual.amount END
                FROM months LEFT JOIN actual USING(line_key,month) LEFT JOIN invalid USING(line_key)
                """).setParameter("keys", new TreeSet<>(lineKeys)).setParameter("category", category)
                .setParameter("from", from).setParameter("to", toInclusive)));
    }

    /** Actual wage-cost GL with proved original department metadata; HR approval alone never creates a cost. */
    Map<String, BigDecimal[]> payrollMonthly(Collection<String> lineKeys, int year, Integer month) {
        if (lineKeys.isEmpty()) return Map.of();
        return monthly(NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                WITH line_departments AS (
                    SELECT DISTINCT binding.line_key, department.id AS department_id
                    FROM finance_report_line_bindings binding
                    JOIN departments bound ON bound.id = binding.department_id
                    JOIN departments department
                      ON left(department.path, length(bound.path)) = bound.path
                    WHERE binding.binding_kind = 'DEPARTMENT' AND binding.line_key IN (:keys)
                ), actual AS (
                SELECT line_departments.line_key, substring(fact.period FROM 6 FOR 2)::int AS month,
                  CASE WHEN bool_or(fact.pending OR fact.gross_cost_signed IS NULL) THEN NULL ELSE SUM(fact.gross_cost_signed) END AS amount
                FROM line_departments
                JOIN v_finance_payroll_cost_facts fact ON fact.department_id=line_departments.department_id
                WHERE substring(fact.period FROM 1 FOR 4)::int=:year
                  AND (CAST(:month AS integer) IS NULL OR substring(fact.period FROM 6 FOR 2)::int=:month)
                GROUP BY 1, 2)
                SELECT DISTINCT d.line_key,m.month,actual.amount FROM line_departments d
                CROSS JOIN generate_series(1,12) m(month)
                LEFT JOIN actual ON actual.line_key=d.line_key AND actual.month=m.month
                WHERE CAST(:month AS integer) IS NULL OR m.month=:month
                """).setParameter("keys", new TreeSet<>(lineKeys)).setParameter("year", year)
                .setParameter("month", month)));
    }

    /**
     * 折旧/摊销事实: 公司账簿、有效(未被红冲)的固定资产正常折旧与长期待摊正常摊销, 按过账那一刻冻结在
     * 过账明细上的费用科目归行(与总账借方同一科目; 之后账簿改了费用科目也不挪动历史)。
     */
    Map<String, BigDecimal[]> depreciationMonthly(Collection<String> lineKeys, String fromPeriod, String toPeriod) {
        return depreciationMonthly(lineKeys,fromPeriod,toPeriod,"BOTH");
    }
    Map<String, BigDecimal[]> depreciationMonthly(Collection<String> lineKeys, String fromPeriod, String toPeriod,String kind) {
        if (lineKeys.isEmpty()) return Map.of();
        return monthly(NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                WITH line_styles AS (
                    SELECT DISTINCT binding.line_key, binding.style_id
                    FROM finance_report_line_bindings binding
                    WHERE binding.binding_kind = 'STYLE' AND binding.line_key IN (:keys)
                ), facts AS (
                    SELECT * FROM v_finance_asset_posting_facts
                    WHERE period BETWEEN :fromPeriod AND :toPeriod AND (:kind='BOTH' OR kind=:kind)
                ), unknown_months AS (
                    SELECT DISTINCT substring(period FROM 6 FOR 2)::int AS month
                    FROM facts WHERE expense_style_id IS NULL AND pending
                ), asset_totals AS (
                    SELECT period,expense_style_id,voucher_id,SUM(amount_local) AS amount,
                        bool_or(pending OR amount_local IS NULL) AS pending
                    FROM facts GROUP BY 1,2,3
                ), ledger AS (
                    SELECT to_char(e.entry_date,'YYYY-MM') AS period,e.style_id,v.id AS voucher_id,
                        CASE WHEN bool_or(EXISTS(SELECT 1 FROM finance_chart_code_styles m WHERE m.style_id=e.style_id AND m.code LIKE '4101%') AND fn_finance_manufacturing_occurrence(e.id) IS NULL) THEN NULL ELSE
                          SUM(CASE WHEN EXISTS(SELECT 1 FROM finance_chart_code_styles m WHERE m.style_id=e.style_id AND m.code LIKE '4101%')
                            THEN fn_finance_manufacturing_occurrence(e.id) ELSE e.direction*e.amount END) END AS amount,
                        bool_and(proof.voucher_id IS NOT NULL) AS reviewed
                    FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id
                    LEFT JOIN finance_gl_voucher_evidence proof ON proof.voucher_id=v.id
                    WHERE NOT e.is_deleted AND public.fn_finance_gl_voucher_is_booked(v.id)
                      AND to_char(e.entry_date,'YYYY-MM') BETWEEN :fromPeriod AND :toPeriod
                      AND NOT public.fn_finance_entry_is_pnl_closing(e.id)
                      AND EXISTS(SELECT 1 FROM line_styles b WHERE b.style_id=e.style_id)
                    GROUP BY 1,2,3
                ), reconciled AS (
                    SELECT COALESCE(a.period,l.period) AS period,COALESCE(a.expense_style_id,l.style_id) AS style_id,
                        CASE WHEN a.period IS NOT NULL THEN
                            CASE WHEN NOT a.pending AND l.voucher_id IS NOT NULL AND a.amount=l.amount THEN a.amount ELSE NULL END
                            WHEN l.reviewed THEN l.amount ELSE NULL END AS amount
                    FROM asset_totals a FULL JOIN ledger l ON l.period=a.period AND l.style_id=a.expense_style_id AND l.voucher_id=a.voucher_id
                ), values_by_line AS (
                    SELECT line_styles.line_key,substring(reconciled.period FROM 6 FOR 2)::int AS month,
                        CASE WHEN bool_or(reconciled.amount IS NULL) THEN NULL ELSE SUM(reconciled.amount) END AS amount
                    FROM line_styles JOIN reconciled ON reconciled.style_id=line_styles.style_id GROUP BY 1,2
                ), months AS (
                    SELECT line_key,month FROM values_by_line
                    UNION SELECT DISTINCT line_key,unknown_months.month FROM line_styles CROSS JOIN unknown_months
                )
                SELECT months.line_key,months.month,
                    CASE WHEN unknown_months.month IS NOT NULL THEN NULL ELSE values_by_line.amount END
                FROM months LEFT JOIN values_by_line USING(line_key,month) LEFT JOIN unknown_months USING(month)
                """).setParameter("keys", new TreeSet<>(lineKeys))
                .setParameter("fromPeriod", fromPeriod).setParameter("toPeriod", toPeriod).setParameter("kind",kind)));
    }

    /**
     * 管理费用 = 043 下全部费用科目月借净, 扣除已归到销售费用、税金、财务费用这些行的科目
     * (与利润表其它行不重复)。
     */
    BigDecimal[] adminMonthly(Collection<String> excludedLineKeys, LocalDate from, LocalDate toInclusive) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery(GlReportSourceScopes.adminSql()).setParameter("excluded", new TreeSet<>(excludedLineKeys))
                .setParameter("from", from).setParameter("to", toInclusive));
        BigDecimal[] months = new BigDecimal[13];
        for (Object[] row : rows) months[((Number) row[0]).intValue()] = (BigDecimal) row[1];
        return months;
    }

    private static Map<String, BigDecimal[]> monthly(List<Object[]> rows) {
        Map<String, BigDecimal[]> result = new LinkedHashMap<>();
        for (Object[] row : rows) {
            BigDecimal[] months = result.computeIfAbsent((String) row[0], ignored -> {
                BigDecimal[] values=new BigDecimal[13];java.util.Arrays.fill(values,1,13,BigDecimal.ZERO);return values;
            });
            months[((Number) row[1]).intValue()] = (BigDecimal) row[2];
        }
        return result;
    }

    /** 各行的绑定目标名称(科目名或部门名); 不在表里的行即未配置。 */
    record Bindings(Map<String, List<String>> namesByLine,Set<String> confirmedZero) {
        Bindings(Map<String,List<String>> namesByLine){this(namesByLine,Set.of());}
        boolean bound(String lineKey) {
            List<String> names = namesByLine.get(lineKey);
            return names != null && !names.isEmpty() || confirmedZero.contains(lineKey);
        }
        boolean conflicting(String key){return confirmedZero.contains(key)&&!names(key).isEmpty();}

        List<String> names(String lineKey) {
            return namesByLine.getOrDefault(lineKey, List.of());
        }
    }
}
