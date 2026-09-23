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
        }
        return new Bindings(names);
    }

    /** 绑定科目的月净额(费用借净; 收入贷净由 category 决定符号)。只算绑定的科目本身, 不含下级。 */
    Map<String, BigDecimal[]> styleMonthly(Collection<String> lineKeys, String category,
                                           LocalDate from, LocalDate toInclusive) {
        if (lineKeys.isEmpty()) return Map.of();
        return monthly(NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                WITH line_styles AS (
                    SELECT DISTINCT binding.line_key, binding.style_id
                    FROM finance_report_line_bindings binding
                    JOIN payment_styles style ON style.id = binding.style_id AND style.category = :category
                    WHERE binding.binding_kind = 'STYLE' AND binding.line_key IN (:keys)
                )
                SELECT line_styles.line_key, EXTRACT(MONTH FROM entry.entry_date)::int,
                       SUM(CASE WHEN :category = 'INCOME' THEN -entry.direction * entry.amount
                                ELSE entry.direction * entry.amount END)
                FROM line_styles
                JOIN gl_entries entry ON entry.style_id = line_styles.style_id AND entry.is_deleted = FALSE
                WHERE entry.entry_date BETWEEN :from AND :to
                GROUP BY 1, 2
                """).setParameter("keys", new TreeSet<>(lineKeys)).setParameter("category", category)
                .setParameter("from", from).setParameter("to", toInclusive)));
    }

    /** 已审核(含已发布)工资单应发合计, 按绑定部门(含下级部门)归行; 同一部门不会同时绑到两条人工行(设置时校验)。 */
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
                )
                SELECT line_departments.line_key, slip.payroll_month::int, SUM(slip.gross_income)
                FROM line_departments
                JOIN payroll_slips slip ON slip.department_id_snapshot = line_departments.department_id
                JOIN payroll_batches batch ON batch.id = slip.batch_id
                WHERE slip.active AND batch.status IN ('APPROVED', 'PUBLISHED')
                  AND slip.payroll_year = :year
                  AND (CAST(:month AS integer) IS NULL OR slip.payroll_month = :month)
                GROUP BY 1, 2
                """).setParameter("keys", new TreeSet<>(lineKeys)).setParameter("year", year)
                .setParameter("month", month)));
    }

    /**
     * 折旧/摊销事实: 公司账簿、有效(未被红冲)的固定资产正常折旧与长期待摊正常摊销, 按过账那一刻冻结在
     * 过账明细上的费用科目归行(与总账借方同一科目; 之后账簿改了费用科目也不挪动历史)。
     */
    Map<String, BigDecimal[]> depreciationMonthly(Collection<String> lineKeys, String fromPeriod, String toPeriod) {
        if (lineKeys.isEmpty()) return Map.of();
        return monthly(NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                WITH line_styles AS (
                    SELECT DISTINCT binding.line_key, binding.style_id
                    FROM finance_report_line_bindings binding
                    WHERE binding.binding_kind = 'STYLE' AND binding.line_key IN (:keys)
                ), facts AS (
                    SELECT posting.expense_style_id, log.period::text AS period, log.amount
                    FROM fa_depreciation_log log
                    JOIN finance_asset_posting_lines posting ON posting.id = log.posting_line_id
                    JOIN finance_asset_posting_runs run
                      ON run.id = log.posting_run_id AND run.book_type = 'CORPORATE'
                    WHERE log.entry_kind = 'NORMAL' AND log.status = 'ACTIVE' AND log.is_deleted = FALSE
                      AND log.period BETWEEN :fromPeriod AND :toPeriod
                    UNION ALL
                    SELECT posting.expense_style_id, log.period::text, log.amount
                    FROM da_amortization_log log
                    JOIN finance_asset_posting_lines posting ON posting.id = log.posting_line_id
                    JOIN finance_asset_posting_runs run
                      ON run.id = log.posting_run_id AND run.book_type = 'CORPORATE'
                    WHERE log.entry_kind = 'NORMAL' AND log.status = 'ACTIVE' AND log.is_deleted = FALSE
                      AND log.period BETWEEN :fromPeriod AND :toPeriod
                )
                SELECT line_styles.line_key, substring(facts.period FROM 6 FOR 2)::int, SUM(facts.amount)
                FROM line_styles
                JOIN facts ON facts.expense_style_id = line_styles.style_id
                GROUP BY 1, 2
                """).setParameter("keys", new TreeSet<>(lineKeys))
                .setParameter("fromPeriod", fromPeriod).setParameter("toPeriod", toPeriod)));
    }

    /**
     * 管理费用 = 043 下全部费用科目月借净, 扣除已归到销售费用、税金、财务费用这些行的科目
     * (与利润表其它行不重复)。
     */
    BigDecimal[] adminMonthly(Collection<String> excludedLineKeys, LocalDate from, LocalDate toInclusive) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT EXTRACT(MONTH FROM entry.entry_date)::int, SUM(entry.direction * entry.amount)
                FROM gl_entries entry
                JOIN payment_styles style ON style.id = entry.style_id
                WHERE entry.is_deleted = FALSE AND style.category = 'EXPENSE'
                  AND left(style.path, 5) = '/043/'
                  AND NOT EXISTS (
                      SELECT 1 FROM finance_report_line_bindings binding
                      WHERE binding.binding_kind = 'STYLE' AND binding.style_id = style.id
                        AND binding.line_key IN (:excluded))
                  AND entry.entry_date BETWEEN :from AND :to
                GROUP BY 1
                """).setParameter("excluded", new TreeSet<>(excludedLineKeys))
                .setParameter("from", from).setParameter("to", toInclusive));
        BigDecimal[] months = new BigDecimal[13];
        for (Object[] row : rows) months[((Number) row[0]).intValue()] = (BigDecimal) row[1];
        return months;
    }

    private static Map<String, BigDecimal[]> monthly(List<Object[]> rows) {
        Map<String, BigDecimal[]> result = new LinkedHashMap<>();
        for (Object[] row : rows) {
            BigDecimal[] months = result.computeIfAbsent((String) row[0], ignored -> new BigDecimal[13]);
            months[((Number) row[1]).intValue()] = (BigDecimal) row[2];
        }
        return result;
    }

    /** 各行的绑定目标名称(科目名或部门名); 不在表里的行即未配置。 */
    record Bindings(Map<String, List<String>> namesByLine) {
        boolean bound(String lineKey) {
            List<String> names = namesByLine.get(lineKey);
            return names != null && !names.isEmpty();
        }

        List<String> names(String lineKey) {
            return namesByLine.getOrDefault(lineKey, List.of());
        }
    }
}
