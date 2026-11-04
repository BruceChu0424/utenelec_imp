package com.uten.imp.features.finance.application;

import com.uten.imp.features.finance.gl.FinanceTemplateContract;
import com.uten.imp.common.web.*;
import java.util.*;

/** Original six paths. Roles are identities configured by UUID; captions are source-paper data. */
public final class FinanceApplicationCatalog {
    private FinanceApplicationCatalog() { }
    public enum Kind { TRAVEL_APPLICATION,TRAVEL_REIMBURSEMENT,REIMBURSEMENT,PAYMENT_APPLICATION,PREPAYMENT_APPLICATION,PAYROLL_PAYMENT }
    public enum Role { DEPARTMENT_REVIEW,TRAVEL_APPROVAL,FINANCE_CUSTODY,FINANCE_REVIEW_1,FINANCE_REVIEW_2,MANAGEMENT_PAYMENT }
    public record Step(int ordinal,Role role,String label,String action) { }
    public static Kind kind(String raw){try{return Kind.valueOf(raw);}catch(Exception e){throw new ApiException(ErrorCode.VALIDATION_FAILED,"申请类型不正确");}}
    public static String title(Kind kind){return FinanceTemplateContract.template("financeApplications").required("types").required(kind.name()).asText();}
    public static String roleTitle(Role role){return FinanceTemplateContract.template("financeApplications").required("roles").required(role.name()).asText();}
    public static List<Step> steps(Kind kind){
        List<Role> roles=switch(kind){
            case TRAVEL_APPLICATION->List.of(Role.DEPARTMENT_REVIEW,Role.TRAVEL_APPROVAL,Role.FINANCE_CUSTODY);
            case PAYROLL_PAYMENT->List.of(Role.FINANCE_REVIEW_2,Role.MANAGEMENT_PAYMENT);
            default->List.of(Role.DEPARTMENT_REVIEW,Role.FINANCE_REVIEW_1,Role.FINANCE_REVIEW_2,Role.MANAGEMENT_PAYMENT);
        };
        List<Step> result=new ArrayList<>();for(int i=0;i<roles.size();i++){var role=roles.get(i);result.add(new Step(i+1,role,roleTitle(role),role==Role.FINANCE_CUSTODY?"ARCHIVE":"APPROVE"));}return List.copyOf(result);
    }
}
