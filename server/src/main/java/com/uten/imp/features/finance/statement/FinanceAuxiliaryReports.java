package com.uten.imp.features.finance.statement;

import com.uten.imp.features.finance.FinanceCompanyReportAccess;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.features.finance.gl.FinanceTemplateContract;
import com.uten.imp.features.finance.gl.FinancialLedgerReadScope;
import com.uten.imp.features.finance.report.*;
import com.uten.imp.common.report.ReportTotalsCalculator;
import com.uten.imp.common.web.*;
import jakarta.persistence.EntityManager;
import java.time.LocalDate;
import java.util.*;

/** Source auxiliary balances are slices of the same GL allocations, never another amount store. */
public final class FinanceAuxiliaryReports {
    private FinanceAuxiliaryReports() { }
    public static ReportTableResponse balances(EntityManager em,FinanceDocumentAccessPolicy access,boolean receivable,
            LocalDate from,LocalDate to,String accountCode,UUID auxiliaryId,UUID currencyId,String sourceSystem,
            int page,int size,FinanceReportColumnOptions options) {
        return balances(em,access,receivable,from,to,accountCode,auxiliaryId,currencyId,sourceSystem,null,page,size,options);
    }
    public static ReportTableResponse selectedBalances(EntityManager em,FinanceDocumentAccessPolicy access,boolean receivable,
            LocalDate from,LocalDate to,UUID currencyId,String sourceSystem,Collection<UUID> auxiliaryIds,
            int page,int size) {
        if(auxiliaryIds==null||auxiliaryIds.isEmpty()||auxiliaryIds.size()>2000||auxiliaryIds.stream().anyMatch(Objects::isNull))throw invalid("请选择1至2000条有效辅助身份");
        String ids="{"+String.join(",",auxiliaryIds.stream().distinct().map(UUID::toString).toList())+"}";
        return balances(em,access,receivable,from,to,null,null,currencyId,sourceSystem,ids,page,size,FinanceReportColumnOptions.NONE);
    }
    private static ReportTableResponse balances(EntityManager em,FinanceDocumentAccessPolicy access,boolean receivable,
            LocalDate from,LocalDate to,String accountCode,UUID auxiliaryId,UUID currencyId,String sourceSystem,String auxiliaryIds,
            int page,int size,FinanceReportColumnOptions options) {
        FinanceCompanyReportAccess.require(access);
        if(from==null||to==null||from.isAfter(to))throw invalid("请选择完整且先后正确的会计期间");
        if(java.time.temporal.ChronoUnit.MONTHS.between(from.withDayOfMonth(1),to.withDayOfMonth(1))>120)
            throw invalid("辅助明细的单次核对期间不能超过十年");
        var openingScope=FinancialLedgerReadScope.asOf(em,from.minusDays(1));var periodScope=FinancialLedgerReadScope.range(em,from,to);
        var closingScope=FinancialLedgerReadScope.asOf(em,to);
        String prefix=receivable?"1122":"2202",role=receivable?"CUSTOMER":"SUPPLIER";
        if(accountCode!=null&&!accountCode.isBlank()&&!accountCode.startsWith(prefix))throw invalid("所选科目不属于本张应收/应付账款明细，不能把收入或其他科目混入");
        var columns=columns(receivable);var projected=new ArrayList<>(columns);
        projected.addAll(List.of(ReportColumn.text("__auxiliaryId",""),ReportColumn.text("__currencyId",""),ReportColumn.text("__sourceSystem",""),
                ReportColumn.text("__basis",""),ReportColumn.money("__closingNormalNet",""),ReportColumn.bool("__pending","")));
        List<ReportTotalsCalculator.Spec> totals=List.of(new ReportTotalsCalculator.Spec("debit","本期借方金额合计","money",null,null,true),
                new ReportTotalsCalculator.Spec("credit","本期贷方金额合计","money",null,null,true),
                new ReportTotalsCalculator.Spec("__closingNormalNet",receivable?"应收未收余额合计":"应付未付余额合计","money",null,null,true));
        return FinanceProjectedReportTable.query(em,projected,sql(receivable),q->{
                    q.setParameter("from",from);q.setParameter("to",to);q.setParameter("prefix",prefix);q.setParameter("role",role);
                    q.setParameter("accountCode",accountCode==null||accountCode.isBlank()?null:accountCode);
                    q.setParameter("auxiliaryId",auxiliaryId);q.setParameter("currencyId",currencyId);
                    q.setParameter("auxiliaryIds",auxiliaryIds);
                    q.setParameter("scopeOpening",openingScope.complete());q.setParameter("scopePeriod",periodScope.complete());q.setParameter("scopeClosing",closingScope.complete());
                    q.setParameter("sourceSystem",sourceSystem==null||sourceSystem.isBlank()?null:sourceSystem);},
                "report.\"accountCode\",report.\"__sourceSystem\",report.\"partyCode\",report.\"__auxiliaryId\"",
                options.filters(),Set.of("openingDirection","closingDirection"),page,size,options.sort(),options.order(),false,totals);
    }
    static List<ReportColumn> columns(boolean receivable) {
        String template=receivable?"receivableAuxiliaryDetail":"payableAuxiliaryDetail";
        String[] keys=receivable?new String[]{"accountCode","accountName","partyCode","partyName","openingDirection","openingDebit","openingCredit","openingBalance","debit","credit","closingDebit","closingCredit","closingDirection","closingBalance"}:
                new String[]{"accountCode","accountName","partyCode","partyName","openingDebit","openingCredit","openingDirection","openingBalance","debit","credit","closingDebit","closingCredit","closingDirection","closingBalance"};
        var result=new ArrayList<ReportColumn>();
        for(int i=0;i<keys.length;i++) {
            String key=keys[i];boolean text=i<4||key.endsWith("Direction");
            ReportColumn column=new ReportColumn(key,FinanceTemplateContract.header(template,i),text?"text":"money",i==1||i==3?230:120)
                    .withHeaderGroups(FinanceTemplateContract.headerGroups(template,i));
            if(!text)column=column.withUnitLabel("元");result.add(column);
        }
        return List.copyOf(result);
    }
    static String sql(boolean receivable) {
        String select=receivable?"""
                code AS "accountCode",name AS "accountName",source_code AS "partyCode",source_name AS "partyName",
                CASE WHEN opening IS NULL THEN NULL WHEN opening>0 THEN '借' WHEN opening<0 THEN '贷' ELSE '平' END AS "openingDirection",
                CASE WHEN opening IS NOT NULL THEN greatest(opening,0) END AS "openingDebit",CASE WHEN opening IS NOT NULL THEN greatest(-opening,0) END AS "openingCredit",abs(opening) AS "openingBalance",
                debit,credit,CASE WHEN closing IS NOT NULL THEN greatest(closing,0) END AS "closingDebit",CASE WHEN closing IS NOT NULL THEN greatest(-closing,0) END AS "closingCredit",
                CASE WHEN closing IS NULL THEN NULL WHEN closing>0 THEN '借' WHEN closing<0 THEN '贷' ELSE '平' END AS "closingDirection",abs(closing) AS "closingBalance"
                """:"""
                code AS "accountCode",name AS "accountName",source_code AS "partyCode",source_name AS "partyName",
                CASE WHEN opening IS NOT NULL THEN greatest(opening,0) END AS "openingDebit",CASE WHEN opening IS NOT NULL THEN greatest(-opening,0) END AS "openingCredit",
                CASE WHEN opening IS NULL THEN NULL WHEN opening>0 THEN '借' WHEN opening<0 THEN '贷' ELSE '平' END AS "openingDirection",abs(opening) AS "openingBalance",
                debit,credit,CASE WHEN closing IS NOT NULL THEN greatest(closing,0) END AS "closingDebit",CASE WHEN closing IS NOT NULL THEN greatest(-closing,0) END AS "closingCredit",
                CASE WHEN closing IS NULL THEN NULL WHEN closing>0 THEN '借' WHEN closing<0 THEN '贷' ELSE '平' END AS "closingDirection",abs(closing) AS "closingBalance"
                """;
        return """
                WITH facts AS (
                    SELECT allocation.account_code,allocation.auxiliary_id,allocation.currency_id,
                           allocation.source_system,allocation.source_code,allocation.source_name,allocation.source_account_name,allocation.source_account_path_name,
                           entry.entry_date,entry.created_at,entry.id,allocation.allocation_no,entry.direction,allocation.amount_local
                    FROM finance_gl_entry_allocations allocation
                    JOIN gl_entries entry ON entry.id=allocation.entry_id
                    JOIN gl_vouchers voucher ON voucher.id=entry.voucher_id
                    WHERE NOT entry.is_deleted AND fn_finance_gl_voucher_is_booked(voucher.id) AND entry.entry_date<=:to
                      AND left(allocation.account_code,4)=:prefix AND allocation.auxiliary_role=:role
                      AND (CAST(:accountCode AS text) IS NULL OR allocation.account_code=:accountCode)
                      AND (CAST(:auxiliaryId AS uuid) IS NULL OR allocation.auxiliary_id=:auxiliaryId)
                      AND (CAST(:auxiliaryIds AS uuid[]) IS NULL OR allocation.auxiliary_id=ANY(CAST(:auxiliaryIds AS uuid[])))
                      AND (CAST(:currencyId AS uuid) IS NULL OR allocation.currency_id=:currencyId)
                      AND (CAST(:sourceSystem AS text) IS NULL OR allocation.source_system=:sourceSystem)
                ), opening_evidence AS (
                    SELECT proof.* FROM finance_gl_auxiliary_opening_evidence proof
                    WHERE proof.effective_from<=:from AND left(proof.account_code,4)=:prefix AND proof.auxiliary_role=:role
                      AND (CAST(:accountCode AS text) IS NULL OR proof.account_code=:accountCode)
                      AND (CAST(:auxiliaryId AS uuid) IS NULL OR proof.auxiliary_id=:auxiliaryId)
                      AND (CAST(:auxiliaryIds AS uuid[]) IS NULL OR proof.auxiliary_id=ANY(CAST(:auxiliaryIds AS uuid[])))
                      AND (CAST(:currencyId AS uuid) IS NULL OR proof.currency_id=:currencyId)
                      AND (CAST(:sourceSystem AS text) IS NULL OR proof.source_system=:sourceSystem)
                ), period_check AS (
                    SELECT CAST(:scopePeriod AS boolean) AS period_known
                ), snapshots AS (
                    SELECT account_code,auxiliary_id,currency_id,source_system,source_code,source_name,source_account_name,source_account_path_name,
                           entry_date AS snapshot_date,created_at,id,allocation_no FROM facts
                    UNION ALL
                    SELECT account_code,auxiliary_id,currency_id,source_system,source_code,source_name,source_account_name,source_account_path_name,
                           effective_from,approved_at,id,0 FROM opening_evidence
                ), labels AS (
                    SELECT DISTINCT ON(account_code,auxiliary_id,currency_id) account_code,auxiliary_id,currency_id,
                           source_system,source_code,source_name,source_account_name
                    FROM snapshots ORDER BY account_code,auxiliary_id,currency_id,snapshot_date DESC,created_at DESC,id DESC,allocation_no DESC
                ), path_labels AS (
                    SELECT DISTINCT ON(account_code,auxiliary_id,currency_id) account_code,auxiliary_id,currency_id,source_account_path_name
                    FROM snapshots WHERE source_account_path_name IS NOT NULL
                    ORDER BY account_code,auxiliary_id,currency_id,snapshot_date DESC,created_at DESC,id DESC,allocation_no DESC
                ), amounts AS (
                    SELECT account_code,auxiliary_id,currency_id,
                           SUM(CASE WHEN entry_date<:from THEN direction*amount_local ELSE 0 END) AS opening,
                           SUM(CASE WHEN entry_date>=:from AND direction=1 THEN amount_local ELSE 0 END) AS debit,
                           SUM(CASE WHEN entry_date>=:from AND direction=-1 THEN amount_local ELSE 0 END) AS credit,
                           SUM(direction*amount_local) AS closing
                    FROM facts GROUP BY account_code,auxiliary_id,currency_id
                ), scopes AS (
                    SELECT account_code,auxiliary_id,currency_id,false AS missing_nonzero FROM amounts
                    UNION ALL
                    SELECT proof.account_code,proof.auxiliary_id,proof.currency_id,
                           bool_or(proof.opening_debit<>0 OR proof.opening_credit<>0) AS missing_nonzero
                    FROM opening_evidence proof WHERE NOT EXISTS(SELECT 1 FROM amounts amount
                        WHERE amount.account_code=proof.account_code AND amount.auxiliary_id=proof.auxiliary_id AND amount.currency_id=proof.currency_id)
                    GROUP BY proof.account_code,proof.auxiliary_id,proof.currency_id
                ), coverage_scopes AS (
                    SELECT DISTINCT account_code,currency_id FROM scopes
                ), coverage_missing AS (
                    SELECT coverage_scope.account_code,coverage_scope.currency_id,
                           count(*) FILTER(WHERE entry.entry_date<:from AND COALESCE(covered.amount,0)<>entry.amount) AS opening_missing,
                           count(*) FILTER(WHERE entry.entry_date>=:from AND COALESCE(covered.amount,0)<>entry.amount) AS movement_missing
                    FROM coverage_scopes coverage_scope JOIN finance_chart_code_styles mapping ON mapping.code=coverage_scope.account_code
                    LEFT JOIN gl_entries entry ON entry.style_id=mapping.style_id AND NOT entry.is_deleted AND entry.entry_date<=:to
                      AND fn_finance_gl_voucher_is_booked(entry.voucher_id)
                    LEFT JOIN LATERAL(SELECT
                """+FinanceAuxiliaryCompleteness.coveredAmountSql("entry","coverage_scope.account_code","coverage_scope.currency_id")+"""
                      AS amount) covered ON true
                    GROUP BY coverage_scope.account_code,coverage_scope.currency_id
                ), complete AS (
                    SELECT chart.code,COALESCE(path.source_account_path_name,labels.source_account_name,chart.name) AS name,labels.*,
                           path.source_account_path_name,
                           COALESCE(coverage.opening_missing,0)+COALESCE(coverage.movement_missing,0)>0 AS missing_auxiliary_allocation,
                           CAST(:scopeOpening AS boolean) AND NOT scopes.missing_nonzero AND scopes.currency_id IS NOT NULL AND COALESCE(coverage.opening_missing,0)=0 AS opening_known,
                           period.period_known AND scopes.currency_id IS NOT NULL AND COALESCE(coverage.movement_missing,0)=0 AS period_known,
                           CAST(:scopeClosing AS boolean) AND NOT scopes.missing_nonzero AND scopes.currency_id IS NOT NULL AND COALESCE(coverage.opening_missing,0)+COALESCE(coverage.movement_missing,0)=0 AS closing_known,
                           CASE WHEN CAST(:scopeOpening AS boolean) AND NOT scopes.missing_nonzero AND scopes.currency_id IS NOT NULL AND COALESCE(coverage.opening_missing,0)=0 THEN COALESCE(amounts.opening,0) END AS opening,
                           CASE WHEN period.period_known AND scopes.currency_id IS NOT NULL AND COALESCE(coverage.movement_missing,0)=0 THEN COALESCE(amounts.debit,0) END AS debit,
                           CASE WHEN period.period_known AND scopes.currency_id IS NOT NULL AND COALESCE(coverage.movement_missing,0)=0 THEN COALESCE(amounts.credit,0) END AS credit,
                           CASE WHEN CAST(:scopeClosing AS boolean) AND NOT scopes.missing_nonzero AND scopes.currency_id IS NOT NULL AND COALESCE(coverage.opening_missing,0)+COALESCE(coverage.movement_missing,0)=0 THEN COALESCE(amounts.closing,0) END AS closing
                    FROM scopes JOIN labels USING(account_code,auxiliary_id,currency_id)
                    LEFT JOIN amounts USING(account_code,auxiliary_id,currency_id)
                    LEFT JOIN path_labels path USING(account_code,auxiliary_id,currency_id)
                    CROSS JOIN period_check period
                    JOIN finance_chart_codes chart ON chart.code=scopes.account_code
                    LEFT JOIN coverage_missing coverage ON coverage.account_code=scopes.account_code AND coverage.currency_id IS NOT DISTINCT FROM scopes.currency_id
                )
                SELECT
                """+select+"""
                ,auxiliary_id AS "__auxiliaryId",currency_id AS "__currencyId",source_system AS "__sourceSystem",
                CASE WHEN missing_auxiliary_allocation THEN '所选科目尚有未完整分配真实辅助对象的已记账来源；不能把已分配部分作为完整往来余额'
                     WHEN currency_id IS NULL THEN '原会计科目币别属性尚未明确，金额保留待核对'
                     WHEN NOT opening_known THEN '期初日期在接续边界之前或非零期初缺少GL事实；未提供的历史不能当零'
                     WHEN NOT period_known THEN '所选期间跨接续起点前未提供的历史，发生额未知；期末另按已记账截至日读取'
                     WHEN source_account_path_name IS NULL THEN '该用途原科目路径名尚未核验，暂保留原凭证或目录名称；金额为总账本币事实'
                     ELSE '本系统已记账本币分配事实，不含未记账单据；按科目、辅助项目UUID及币别属性隔离；原币另有独立证据与单位' END AS "__basis",
                """+(receivable?"closing":"-closing")+" AS \"__closingNormalNet\",(source_account_path_name IS NULL OR NOT opening_known OR NOT period_known OR NOT closing_known) AS \"__pending\" FROM complete";
    }
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
