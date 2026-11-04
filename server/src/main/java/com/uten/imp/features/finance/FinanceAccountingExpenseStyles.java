package com.uten.imp.features.finance;

import com.uten.imp.common.finance.AccountingExpensePurpose;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.*;
import jakarta.persistence.EntityManager;
import java.util.*;

/** One typed eligibility query over the existing source style UUIDs and confirmed 4101 chart mapping. */
public final class FinanceAccountingExpenseStyles {
    private FinanceAccountingExpenseStyles() { }
    public record Reference(UUID id,String code,String name,String category,String postingPurpose) { }
    public static void require(EntityManager em,UUID id,AccountingExpensePurpose purpose){
        if(id==null||purpose==null||!Boolean.TRUE.equals(em.createNativeQuery("SELECT fn_finance_expense_posting_style_allowed(:id,:purpose,true)").setParameter("id",id).setParameter("purpose",purpose.name()).getSingleResult()))throw new ApiException(ErrorCode.VALIDATION_FAILED,purpose==AccountingExpensePurpose.MANUFACTURING_COST?"制造成本须明确对应财务4101的在用末级ACCOUNT科目":"普通费用须为在用EXPENSE末级科目");
    }
    public static void requireAnyActive(EntityManager em,UUID id){
        if(id==null||!Boolean.TRUE.equals(em.createNativeQuery("SELECT COALESCE((SELECT status='使用' AND fn_finance_cost_expense_style_allowed(id) FROM payment_styles WHERE id=:id),false)").setParameter("id",id).getSingleResult()))throw new ApiException(ErrorCode.VALIDATION_FAILED,"科目须为在用费用末级或已明确4101的制造成本末级");
    }
    public static List<Reference> references(EntityManager em,AccountingExpensePurpose purpose){
        List<Reference> result=new ArrayList<>();for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT s.id,COALESCE(c.code,s.code),COALESCE(c.name,s.name),s.category FROM payment_styles s
                LEFT JOIN finance_chart_code_styles m ON m.style_id=s.id LEFT JOIN finance_chart_codes c ON c.code=m.code
                WHERE fn_finance_expense_posting_style_allowed(s.id,:purpose,true) ORDER BY s.path,s.id
                """).setParameter("purpose",purpose.name()))){result.add(new Reference((UUID)row[0],Objects.toString(row[1],""),Objects.toString(row[2],""),row[3].toString(),purpose.name()));}return List.copyOf(result);
    }
}
