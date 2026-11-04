package com.uten.imp.features.finance.gl;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;
import java.util.stream.Collectors;

/** Reads the caller's repeatable-read snapshot; never calculates from displayed codes or names. */
final class FinancialStatementService {
    private final EntityManager em;
    FinancialStatementService(EntityManager em) { this.em=em; }
    record Value(BigDecimal amount, boolean complete, String basis) {}
    record Snapshot(Map<String,Map<Integer,BigDecimal>> amounts,Set<String> configured,Set<String> zero,
                    Set<Integer> unmapped,Set<Integer> incompleteSources) {
        Snapshot(Map<String,Map<Integer,BigDecimal>> amounts,Set<String> configured,Set<String> zero,Set<Integer> unmapped) {
            this(amounts,configured,zero,unmapped,Set.of());
        }
    }

    List<Map<String,Object>> balance(LocalDate end) {
        Snapshot snapshot=read("BALANCE",end.withDayOfYear(1),end,false);
        var current=calculate("BALANCE",snapshot,1);var opening=calculate("BALANCE",snapshot,0);
        List<Map<String,Object>> rows=new ArrayList<>();
        for(var line:FinancialStatementCatalog.BALANCE) {
            var now=current.get(line.number());var before=opening.get(line.number());
            Map<String,Object> row=base(line);
            row.put("side",line.side());row.put("periodEnd",now.complete()?now.amount():null);
            row.put("yearStart",before.complete()?before.amount():null);
            row.put("basis",now.basis().equals(before.basis())?now.basis():"期末："+now.basis()+"；年初："+before.basis());
            row.put("__pending",!now.complete()||!before.complete());
            rows.add(row);
        }
        return rows;
    }
    List<Map<String,Object>> profit(int year) {
        return profit(year,12);
    }
    List<Map<String,Object>> profit(int year,int throughMonth) {
        Snapshot snapshot=read("PROFIT",LocalDate.of(year,1,1),java.time.YearMonth.of(year,throughMonth).atEndOfMonth(),true);
        return profitRows(snapshot,throughMonth,false);
    }
    List<Map<String,Object>> profitAnnual(int year) {
        return profitAnnual(year,12);
    }
    List<Map<String,Object>> profitAnnual(int year,int throughMonth) {
        var rows=profitRows(read("PROFIT",LocalDate.of(year,1,1),java.time.YearMonth.of(year,throughMonth).atEndOfMonth(),true),throughMonth,true);
        var future=java.util.stream.IntStream.rangeClosed(throughMonth+1,12).boxed().toList();
        for(var row:rows)row.put("__notApplicableMonths",future);
        return rows;
    }
    Map<Integer,Value> revenueMonths(int year,int throughMonth) {
        Snapshot snapshot=read("PROFIT",LocalDate.of(year,1,1),java.time.YearMonth.of(year,throughMonth).atEndOfMonth(),true);
        Map<Integer,Value> values=new LinkedHashMap<>();
        for(int month=1;month<=throughMonth;month++)values.put(month,calculate("PROFIT",snapshot,month).get(1));
        return Collections.unmodifiableMap(values);
    }
    private static List<Map<String,Object>> profitRows(Snapshot snapshot,int throughMonth,boolean annual) {
        List<Map<String,Object>> rows=new ArrayList<>();
        for(var line:FinancialStatementCatalog.PROFIT) {
            if(annual&&line.number()==32)rows.add(base(FinancialStatementCatalog.PRIOR_ADJUSTMENT));
            rows.add(base(line));
        }
        for(int month=1;month<=throughMonth;month++) {
            var calculated=calculate("PROFIT",snapshot,month);
            if(annual) {
                var adjustment=directValue(FinancialStatementCatalog.PRIOR_ADJUSTMENT,snapshot,month);
                calculated.put(33,adjustment);var net=calculated.get(32);
                calculated.put(32,new Value(net.amount().subtract(adjustment.amount()),net.complete()&&adjustment.complete(),
                        net.complete()&&adjustment.complete()?"按年度模板扣除已确认的以前年度损益调整":"年度调整或利润项目尚未核对完整"));
            }
            for(var row:rows) {
                var value=calculated.get((Integer)row.get("lineNo"));
                row.put("m"+month,value.complete()?value.amount():null);
                if(!value.complete())row.put("__pending",true);
                if(!row.containsKey("basis") || !value.complete())row.put("basis",value.basis());
            }
        }
        return rows;
    }
    private static Value directValue(FinancialStatementCatalog.Line line,Snapshot snapshot,int bucket) {
        BigDecimal amount=snapshot.amounts().getOrDefault(line.key(),Map.of()).getOrDefault(bucket,BigDecimal.ZERO);
        boolean known=snapshot.configured().contains(line.key()),zero=snapshot.zero().contains(line.key());
        boolean conflict=zero&&amount.signum()!=0;
        boolean sourceMissing=snapshot.incompleteSources().contains(bucket);
        return new Value(amount,(known||zero)&&!conflict&&!sourceMissing,sourceMissing?"接续起点前的历史发生额尚未提供":conflict?"已确认无业务但存在金额，请核对":known?"本系统已记账总账科目归集":
                zero?"财务已确认本行单独取数为零":"待财务配置科目或确认无业务");
    }
    private static Map<String,Object> base(FinancialStatementCatalog.Line l) {
        Map<String,Object> row=new LinkedHashMap<>();row.put("item",l.label());row.put("lineNo",l.number());return row;
    }
    static Map<Integer,Value> calculate(String sheet,Snapshot snapshot,int bucket) {
        Map<Integer,Value> values=new LinkedHashMap<>();
        var catalog=FinancialStatementCatalog.lines(sheet);
        for(var line:catalog) if(line.direct()) {
            BigDecimal amount=snapshot.amounts().getOrDefault(line.key(),Map.of()).getOrDefault(bucket,BigDecimal.ZERO);
            boolean known=snapshot.configured().contains(line.key());
            boolean zero=snapshot.zero().contains(line.key());
            boolean conflict=zero&&amount.signum()!=0;
            boolean incomeUnknown=sheet.equals("PROFIT")&&line.number()==1&&snapshot.amounts().getOrDefault("__INCOME_UNKNOWN",Map.of()).containsKey(bucket);
            boolean sourceMissing=snapshot.incompleteSources().contains(bucket);
            values.put(line.number(),new Value(amount,(known||zero)&&!conflict&&!incomeUnknown&&!sourceMissing,
                    sourceMissing?"接续起点前的历史来源尚未提供":incomeUnknown?"存在未归集收入，营业收入范围待核对":conflict?"已确认无业务但存在金额，请核对":known?"本系统已记账总账科目归集":zero?"财务已确认本行单独取数为零":"待财务配置科目或确认无业务"));
        }
        // Detail accounts are assigned once, then rolled into their parent. Unconfigured detail
        // breakdowns do not invalidate a parent whose remaining scope is explicitly configured.
        for(var line:catalog) if(!line.details().isEmpty()) {
            Value parent=values.get(line.number());BigDecimal amount=parent.amount();boolean complete=parent.complete();
            for(int n:line.details()) {
                var detail=values.get(n);amount=amount.add(detail.amount());
                if(!detail.complete()&&detail.amount().signum()!=0)complete=false;
            }
            values.put(line.number(),new Value(amount,complete,complete?parent.basis()+"（含其中明细）":"项目或其中明细尚未配置完整，或与无业务确认冲突"));
        }
        if(sheet.equals("BALANCE")) {
            Value retained=values.get(51);
            BigDecimal pnl=snapshot.amounts().getOrDefault("__PL",Map.of()).getOrDefault(bucket,BigDecimal.ZERO);
            values.put(51,new Value(retained.amount().add(pnl),retained.complete(),retained.basis()+"；加截至报表日未结转损益"));
        }
        for(var line:catalog)if(!line.direct()) {
            BigDecimal amount=BigDecimal.ZERO;boolean complete=true;
            for(int term:line.terms()) {
                Value value=values.get(Math.abs(term));complete&=value.complete();
                amount=amount.add(term<0?value.amount().negate():value.amount());
            }
            if(snapshot.unmapped().contains(bucket))complete=false;
            values.put(line.number(),new Value(amount,complete,complete?"按模板项目计算":
                    snapshot.unmapped().contains(bucket)?"存在未归集的总账科目，请核对取数设置":"组成项目尚未配置完整"));
        }
        return values;
    }
    private Snapshot read(String sheet,LocalDate from,LocalDate end,boolean monthly) {
        String cte=scope(sheet);
        var conflicts=NativeQueryResults.objectArrayRows(em.createNativeQuery(cte+"""
                SELECT style_id, string_agg(line_key, ',') FROM resolved
                GROUP BY style_id HAVING count(*)>1 LIMIT 1
                """));
        if(!conflicts.isEmpty())throw new ApiException(ErrorCode.CONFLICT,"财务报表科目归集冲突，请核对取数设置："+conflicts.getFirst()[1]);
        Set<String> configured=new HashSet<>(),zero=new HashSet<>();
        for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery(cte+"""
                SELECT line_key,false FROM candidates GROUP BY line_key
                UNION ALL SELECT c.line_key,true FROM finance_report_line_confirmations c
                JOIN definitions d ON d.line_key=c.line_key WHERE c.confirmed_zero
                """))) {
            if(Boolean.TRUE.equals(row[1]))zero.add((String)row[0]);else configured.add((String)row[0]);
        }
        String buckets=monthly?"SELECT n AS bucket,make_date(:year,n,1) AS begin_date,(make_date(:year,n,1)+interval '1 month'-interval '1 day')::date AS end_date FROM generate_series(1,:lastMonth) n"
                :"SELECT 0 AS bucket,NULL::date AS begin_date,CAST(:opening AS date) AS end_date UNION ALL SELECT 1,NULL::date,CAST(:end AS date)";
        String sql=cte+", buckets AS ("+buckets+")"+"""
                SELECT CASE WHEN :sheet='BALANCE' AND s.category IN ('INCOME','EXPENSE') THEN '__PL'
                            ELSE COALESCE(r.line_key,CASE WHEN s.category='INCOME' THEN '__UNMAPPED_INCOME' ELSE '__UNMAPPED' END) END AS line_key,b.bucket,
                       SUM(e.direction*e.amount*CASE WHEN :sheet='BALANCE' AND s.category IN ('INCOME','EXPENSE')
                            THEN -1 ELSE COALESCE(d.sign,1) END)
                FROM gl_entries e JOIN gl_vouchers voucher ON voucher.id=e.voucher_id AND fn_finance_gl_voucher_is_booked(voucher.id)
                JOIN payment_styles s ON s.id=e.style_id
                JOIN buckets b ON e.entry_date<=b.end_date AND (b.begin_date IS NULL OR e.entry_date>=b.begin_date)
                LEFT JOIN resolved r ON r.style_id=e.style_id LEFT JOIN definitions d ON d.line_key=r.line_key
                WHERE e.is_deleted=false AND (:sheet='BALANCE' OR s.category IN ('INCOME','EXPENSE') OR r.line_key='PL_PRIOR_ADJUSTMENT')
                  AND (:sheet='BALANCE' OR NOT fn_finance_entry_is_pnl_closing(e.id))
                GROUP BY 1,2,e.style_id
                """;
        var query=em.createNativeQuery(sql).setParameter("sheet",sheet);
        if(monthly)query.setParameter("year",from.getYear()).setParameter("lastMonth",end.getMonthValue());else query.setParameter("opening",from.minusDays(1)).setParameter("end",end);
        Map<String,Map<Integer,BigDecimal>> amounts=new HashMap<>();Set<Integer> unmapped=new HashSet<>();
        for(Object[] row:NativeQueryResults.objectArrayRows(query)) {
            String key=(String)row[0];int bucket=((Number)row[1]).intValue();BigDecimal amount=(BigDecimal)row[2];
            amounts.computeIfAbsent(key,k->new HashMap<>()).merge(bucket,amount,BigDecimal::add);
            if(key.startsWith("__UNMAPPED")&&amount.signum()!=0) {
                unmapped.add(bucket);
                if(key.equals("__UNMAPPED_INCOME"))amounts.computeIfAbsent("__INCOME_UNKNOWN",k->new HashMap<>()).put(bucket,BigDecimal.ONE);
            }
        }
        Set<Integer> incompleteSources=new HashSet<>();
        if(monthly)FinancialLedgerReadScope.months(em,from.getYear(),end.getMonthValue()).forEach((month,value)->{
            if(!value.complete())incompleteSources.add(month);
        });
        else {
            if(!FinancialLedgerReadScope.asOf(em,from.minusDays(1)).complete())incompleteSources.add(0);
            if(!FinancialLedgerReadScope.asOf(em,end).complete())incompleteSources.add(1);
        }
        return new Snapshot(amounts,configured,zero,unmapped,incompleteSources);
    }
    private static String scope(String sheet) {
        var definitions=FinancialStatementCatalog.mappingLines(sheet).stream().filter(FinancialStatementCatalog.Line::direct).toList();
        String values=definitions.stream().map(l->"('%s','%s',%s)".formatted(l.key(),l.category(),l.sign())).collect(Collectors.joining(","));
        String defaults=definitions.stream().flatMap(l->l.roots().stream().map(r->"('%s','%s')".formatted(l.key(),r))).collect(Collectors.joining(","));
        return GlReportSourceScopes.scope(GlReportSourceScopes.Root.values())+"""
                , definitions(line_key,category,sign) AS (VALUES %s), defaults(line_key,root_key) AS (VALUES %s),
                candidates AS (
                    SELECT b.style_id,b.line_key,0 AS priority FROM finance_report_line_bindings b
                    JOIN definitions d ON d.line_key=b.line_key
                    JOIN payment_styles s ON s.id=b.style_id AND s.category=d.category WHERE b.binding_kind='STYLE'
                    UNION
                    SELECT scope.style_id,d.line_key,2 FROM report_style_scope scope JOIN defaults d ON d.root_key=scope.root_key
                    UNION
                    SELECT a.cost_style_snapshot_id,'BS_18',1 FROM fixed_assets a WHERE %s AND a.cost_style_snapshot_id IS NOT NULL
                    UNION
                    SELECT a.accumulated_style_snapshot_id,'BS_19',1 FROM fixed_assets a WHERE %s AND a.accumulated_style_snapshot_id IS NOT NULL
                    UNION
                    SELECT a.cost_style_snapshot_id,'BS_27',1 FROM deferred_expenses a WHERE %s AND a.cost_style_snapshot_id IS NOT NULL
                ), ranked AS (SELECT *,min(priority) OVER(PARTITION BY style_id) AS best FROM candidates),
                resolved AS (SELECT DISTINCT style_id,line_key FROM ranked WHERE priority=best)
                """.formatted(values,defaults,sheet.equals("BALANCE")?"true":"false",sheet.equals("BALANCE")?"true":"false",sheet.equals("BALANCE")?"true":"false");
    }
}
