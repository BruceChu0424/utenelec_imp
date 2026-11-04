package com.uten.imp.features.finance.application;

import com.uten.imp.application.port.*;
import com.uten.imp.common.web.*;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.time.*;
import java.util.*;

/** Payroll-review-only identity/source references. Every capacity comes from the shared actual GL pool. */
@Service @RequiredArgsConstructor
public class FinancePayrollApplicationReferences {
    private final JdbcTemplate db;private final FinanceApplicationService applications;private final FinanceApplicationRoles roles;
    private final ObjectProvider<FinancePayrollPaymentPort> payroll;private final FinanceApplicationPaymentAuthorityPort authority;
    private final FinanceGlSettlementCapacityPort capacity;private final FinancialChartCurrencyReadPort currencies;private final TaskClaimService claims;
    @Transactional public Map<String,Object> references(UUID id,String expected,UUID lease){var app=gate(id,expected,lease);var source=payroll.getObject().source((UUID)app.get("source_id"),false);List<UUID> employees=source.slips().stream().map(FinancePayrollPaymentPort.Slip::employeeId).distinct().toList();
        var out=new LinkedHashMap<String,Object>();out.put("source",source);out.put("styles",db.queryForList("""
            SELECT s.id,COALESCE(c.code,s.code) AS code,COALESCE(c.name,s.name) AS name,s.category,c.code AS "accountCode",
              fn_finance_cost_expense_style_allowed(s.id) AS "costAllowed",fn_finance_payroll_wage_style_allowed(s.id) AS "wageAllowed",
              fn_finance_payroll_employee_settlement_style_allowed(s.id) AS "employeeSettlementAllowed"
            FROM payment_styles s LEFT JOIN finance_chart_code_styles m ON m.style_id=s.id LEFT JOIN finance_chart_codes c ON c.code=m.code
            WHERE NOT s.is_deleted AND s.status='使用' AND NOT EXISTS(SELECT 1 FROM payment_styles child WHERE child.parent_id=s.id AND NOT child.is_deleted)
              AND s.category IN('EXPENSE','LIABILITY','INCOME','ACCOUNT') ORDER BY COALESCE(c.code,s.code),s.id
            """));
        out.put("departments",db.queryForList("SELECT DISTINCT department_id_snapshot AS id,department_name_snapshot AS name FROM payroll_slips WHERE batch_id=? AND active ORDER BY department_name_snapshot,department_id_snapshot",source.batchId()));
        out.put("auxiliaries",employees.isEmpty()?List.of():new NamedParameterJdbcTemplate(db).queryForList("SELECT id,source_system AS \"sourceSystem\",source_code AS code,source_name AS name,employee_id AS \"employeeId\" FROM finance_auxiliary_items WHERE status='ACTIVE' AND role='EMPLOYEE' AND employee_id IN(:employees) ORDER BY source_system,source_code,id",Map.of("employees",employees)));
        var prior=db.queryForList("SELECT batch_id,mode,voucher_id,instruction_snapshot::text,source_fingerprint,created_at FROM finance_payroll_accruals WHERE batch_id=?",source.batchId());
        if(!prior.isEmpty()){var row=prior.getFirst();var frozen=applications.decode(row.get("instruction_snapshot").toString());var summary=new LinkedHashMap<String,Object>();summary.put("batchId",row.get("batch_id"));summary.put("mode",row.get("mode"));summary.put("voucherId",row.get("voucher_id"));summary.put("instruction",frozen);summary.put("sourceFingerprint",row.get("source_fingerprint"));summary.put("createdAt",row.get("created_at"));out.put("accrual",summary);out.put("reusedAccrual",true);out.put("netAlready","EXISTING_CONFIRMED_LIABILITY".equals(row.get("mode"))&&"NET_AFTER_DEDUCTIONS".equals(frozen.get("existingLiabilityBasis")));}else{out.put("reusedAccrual",false);out.put("netAlready",false);}
        out.put("evidence",db.queryForList("SELECT id,original_name AS name,sha256 FROM attachments WHERE owner_type='FINANCE_APPLICATION' AND owner_id=? AND lifecycle_state='CLEAN' AND delete_requested_at IS NULL ORDER BY original_name,id",id));return out;
    }
    @Transactional public Map<String,Object> candidates(UUID id,String expected,UUID lease,UUID styleId,UUID auxiliaryId,UUID employeeId,String kind,LocalDate asOf,String search,UUID selectedEntry,Integer selectedAllocation){var app=gate(id,expected,lease);var source=payroll.getObject().source((UUID)app.get("source_id"),false);
        if(asOf==null||asOf.isAfter(com.uten.imp.common.time.BusinessTime.today()))throw invalid("请选择明确已到的会计核对日期");if(!Set.of("WAGE_LIABILITY","DEDUCTION","EXISTING_NON_CASH_VOUCHER").contains(kind))throw invalid("工资会计来源用途不正确");
        var styles=db.queryForList("SELECT s.id,s.category,c.code FROM payment_styles s JOIN finance_chart_code_styles m ON m.style_id=s.id JOIN finance_chart_codes c ON c.code=m.code WHERE s.id=? AND NOT s.is_deleted AND s.status='使用' AND NOT EXISTS(SELECT 1 FROM payment_styles child WHERE child.parent_id=s.id AND NOT child.is_deleted)",styleId);if(styles.size()!=1)throw invalid("请先选择已明确对应财务代码的在用末级科目");String code=styles.getFirst().get("code").toString();if(kind.equals("WAGE_LIABILITY")&&!"LIABILITY".equals(styles.getFirst().get("category")))throw invalid("原工资负债来源须为LIABILITY末级科目");
        if(!kind.equals("DEDUCTION")&&!Boolean.TRUE.equals(db.queryForObject("SELECT fn_finance_payroll_wage_style_allowed(?)",Boolean.class,styleId)))throw invalid("应付工资须明确对应原职工薪酬科目或BS35，不使用供应商应付或税款代替");
        if(kind.equals("DEDUCTION")&&!Boolean.TRUE.equals(db.queryForObject("SELECT fn_finance_payroll_employee_settlement_style_allowed(?)",Boolean.class,styleId)))throw invalid("员工借款清偿须选择明确其他应收资产科目，不使用库存、资金或制造成本替代");
        if(auxiliaryId!=null){if(employeeId==null||source.slips().stream().noneMatch(s->s.employeeId().equals(employeeId)))throw invalid("员工不在本原工资批次内");int match=db.queryForObject("SELECT count(*) FROM finance_auxiliary_items WHERE id=? AND status='ACTIVE' AND role='EMPLOYEE' AND employee_id=fn_canonical_employee_identity(?)",Integer.class,auxiliaryId,employeeId);if(match!=1)throw invalid("辅助项目未明确对应本工资条员工，不能按同名选择");}else if(kind.equals("DEDUCTION"))throw invalid("员工往来扣款须明确本人的辅助项目");
        var currency=currencies.read(Set.of(code)).get(code);if(currency==null||!source.currencyId().equals(currency.currencyId()))throw invalid("所选科目会计币种未明确证明为原工资本位币");
        if(kind.equals("EXISTING_NON_CASH_VOUCHER")){
            if(source.netIncome().signum()!=0||source.grossIncome().signum()<=0||source.grossIncome().compareTo(source.totalDeduction())!=0)throw invalid("本支线仅核对实发为0且已有真实应发/扣款的原工资清偿凭证");
            String term=Objects.toString(search,"").strip();if(term.length()>100)throw invalid("查询内容过长");String like="%"+term.replace("!","!!").replace("%","!%").replace("_","!_")+"%";
            var rows=db.queryForList("SELECT v.id AS \"voucherId\",v.voucher_no AS \"voucherNo\",v.voucher_date AS date,SUM(e.amount)::text AS \"sourceAmountLocal\",true AS ready FROM gl_vouchers v JOIN gl_entries e ON e.voucher_id=v.id WHERE v.status=1 AND NOT v.is_deleted AND v.reversed_by_voucher_id IS NULL AND v.voucher_date<=? AND NOT e.is_deleted AND e.style_id=? AND e.direction=1 AND v.voucher_no ILIKE ? ESCAPE '!' GROUP BY v.id,v.voucher_no,v.voucher_date HAVING SUM(e.amount)>0 ORDER BY v.voucher_date,v.voucher_no,v.id LIMIT 101",asOf,styleId,like);
            return Map.of("items",rows.size()>100?rows.subList(0,100):rows,"more",rows.size()>100,"basis","明确认领已有非现金原凭证；保存准备时复核原工资、科目、员工辅助与原币，不能按同额自动对应");
        }
        int direction=kind.equals("WAGE_LIABILITY")?-1:1;var scope=new FinanceGlSettlementCapacityPort.Scope(styleId,code,auxiliaryId,currency.currencyId(),source.currencyId(),direction,asOf,auxiliaryId==null?null:"EMPLOYEE");var mode=auxiliaryId==null?FinanceGlSettlementCapacityPort.Mode.CONFIRMED_AGGREGATE_LIABILITY:FinanceGlSettlementCapacityPort.Mode.EXPLICIT_GL_SOURCE;
        String term=Objects.toString(search,"").strip();if(term.length()>100)throw invalid("查询内容过长");String like="%"+term.replace("!","!!").replace("%","!%").replace("_","!_")+"%";
        if((selectedEntry==null)!=(selectedAllocation==null))throw invalid("请保留完整原GL分配标识");List<Object> parameters=new ArrayList<>(Arrays.asList(styleId,direction,code,auxiliaryId,currency.currencyId(),source.currencyId(),asOf,like,like));if(selectedEntry!=null){parameters.add(selectedEntry);parameters.add(selectedAllocation);}
        var rows=db.queryForList("""
            SELECT e.id AS "entryId",v.id AS "voucherId",v.voucher_no AS "voucherNo",a.allocation_no AS "allocationNo",e.entry_date AS date,
              a.amount_local::text AS "sourceAmountLocal",a.amount_original::text AS "sourceAmountOriginal"
            FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id JOIN finance_gl_entry_allocations a ON a.entry_id=e.id
            WHERE e.style_id=? AND e.direction=? AND NOT e.is_deleted AND public.fn_finance_gl_voucher_is_booked(v.id)
              AND a.account_code=? AND a.auxiliary_id IS NOT DISTINCT FROM ?::uuid AND a.currency_id IS NOT DISTINCT FROM ?::uuid
              AND a.original_currency_id=? AND e.entry_date<=? AND (v.voucher_no ILIKE ? ESCAPE '!' OR e.source_bill_no ILIKE ? ESCAPE '!')
            """+(selectedEntry==null?"":" AND e.id=? AND a.allocation_no=?")+" ORDER BY e.entry_date,v.voucher_no,e.line_no,e.id,a.allocation_no LIMIT 101",parameters.toArray());
        List<Map<String,Object>> result=new ArrayList<>();for(var row:rows.subList(0,Math.min(rows.size(),100))){var item=new LinkedHashMap<>(row);if(selectedEntry!=null){var ref=new FinanceGlSettlementCapacityPort.SourceRef((UUID)row.get("entryId"),((Number)row.get("allocationNo")).intValue());var preview=capacity.preview(scope,mode,List.of(ref));var selected=preview.sources().stream().filter(p->p.source().equals(ref)).findFirst().orElse(null);item.put("sourceFingerprint",preview.fingerprint());item.put("amountLocal",preview.availableLocal()==null||selected==null?null:preview.availableLocal().min(selected.amountLocal()).toPlainString());item.put("amountOriginal",preview.availableOriginal()==null||selected==null?null:preview.availableOriginal().min(selected.amountOriginal()).toPlainString());item.put("issues",preview.issues());item.put("ready",preview.ready());item.put("basis",preview.basis());}result.add(item);}
        Map<String,Object> out=new LinkedHashMap<>();out.put("items",result);out.put("more",rows.size()>100);if(auxiliaryId!=null){var preview=capacity.preview(scope,FinanceGlSettlementCapacityPort.Mode.AUXILIARY_BALANCE_POOL,List.of());out.put("balancePool",preview);}return out;
    }
    private Map<String,Object> gate(UUID id,String expected,UUID lease){roles.live(FinanceApplicationPermissions.REVIEW);var app=applications.lockSourceAndRow(id);applications.fresh(app,expected);if(!"PAYROLL_BATCH".equals(app.get("source_kind")))throw invalid("这不是原工资付款申请");claims.requireActiveClaimByMe(FinanceApplicationService.CLAIM,id.toString(),lease);authority.requirePayrollPreparation(id,(UUID)app.get("source_id"),expected);return app;}
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
