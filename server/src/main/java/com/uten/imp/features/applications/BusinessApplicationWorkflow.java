package com.uten.imp.features.applications;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.*;

/** One ordered workflow contract; kinds retain their distinct business purpose. */
public final class BusinessApplicationWorkflow {
    private BusinessApplicationWorkflow() {}
    public static final Map<String,String> KINDS=Map.of("TRAVEL","出差申请","PAYMENT","付款申请",
            "PREPAYMENT","预付申请","SUPPLIER_PAYMENT","供应商付款申请");
    public static final Set<String> REVIEW_STAGES=Set.of("DEPARTMENT","PROCUREMENT","FINANCE_INITIAL","FINANCE_REVIEW","VICE_EXECUTIVE","EXECUTIVE");
    public static final Map<String,String> APPLY_PERMISSIONS=Map.of("TRAVEL","application:apply:travel",
            "PAYMENT","application:apply:payment","PREPAYMENT","application:apply:prepayment","SUPPLIER_PAYMENT","application:apply:supplier_payment");
    public static String applyPermission(String kind){return APPLY_PERMISSIONS.getOrDefault(kind,"__DENIED_APPLICATION_KIND__");}
    public static List<String> stages(String kind) {
        return switch(kind) {
            case "TRAVEL" -> List.of("DEPARTMENT","EXECUTIVE","FINANCE_RECEIVE");
            case "PAYMENT","PREPAYMENT" -> List.of("DEPARTMENT","FINANCE_INITIAL","FINANCE_REVIEW","EXECUTIVE","PAYMENT");
            case "SUPPLIER_PAYMENT" -> List.of("PROCUREMENT","FINANCE_REVIEW","VICE_EXECUTIVE","EXECUTIVE","PAYMENT");
            default -> throw invalid("未知申请类别");
        };
    }
    public static String next(String kind,String stage) {
        var stages=stages(kind); int index=stages.indexOf(stage);
        if(index<0)throw invalid("审批节点与申请类别不匹配");
        return index+1==stages.size()?null:stages.get(index+1);
    }
    public static String permission(String stage) {
        return switch(stage==null?"":stage) {
            case "FINANCE_RECEIVE" -> "application:receive";
            case "PAYMENT" -> "application:pay";
            case "FINANCE_POSTING" -> "application:prepayment:link_finance";
            case "DEPARTMENT" -> "application:approve:department";
            case "PROCUREMENT" -> "application:approve:procurement";
            case "FINANCE_INITIAL" -> "application:approve:finance_initial";
            case "FINANCE_REVIEW" -> "application:approve:finance_review";
            case "VICE_EXECUTIVE" -> "application:approve:vice_executive";
            case "EXECUTIVE" -> "application:approve:executive";
            default -> "__DENIED_APPLICATION_STAGE__";
        };
    }
    public static String label(String stage) {
        return switch(stage==null?"":stage) {
            case "DEPARTMENT" -> "部门负责人审核"; case "PROCUREMENT" -> "采购部意见";
            case "FINANCE_INITIAL" -> "财务初核"; case "FINANCE_REVIEW" -> "财务复核";
            case "VICE_EXECUTIVE" -> "副总审批"; case "EXECUTIVE" -> "总经办批准";
            case "FINANCE_RECEIVE" -> "财务接收保管"; case "PAYMENT" -> "出纳登记付款";
            default -> "已结束";
        };
    }
    public static String label(String kind,String stage){
        if("SUPPLIER_PAYMENT".equals(kind)){
            if("FINANCE_REVIEW".equals(stage))return "财务部意见";
            if("EXECUTIVE".equals(stage))return "总经理审批";
        }
        return label(stage);
    }
    public static Set<String> scope(String stage) {
        if(stage==null||stage.isBlank())return Set.of("DEPARTMENT","PROCUREMENT","FINANCE_INITIAL","FINANCE_REVIEW","VICE_EXECUTIVE","EXECUTIVE","FINANCE_RECEIVE","PAYMENT","FINANCE_POSTING");
        if("FINANCE".equals(stage))return Set.of("FINANCE_INITIAL","FINANCE_REVIEW","FINANCE_RECEIVE","PAYMENT","FINANCE_POSTING");
        if("MANAGEMENT".equals(stage))return Set.of("VICE_EXECUTIVE","EXECUTIVE");
        if("PMC".equals(stage))return Set.of("DEPARTMENT","PROCUREMENT");
        if(scope(null).contains(stage))return Set.of(stage);
        throw invalid("未知审批分类");
    }
    public static BigDecimal amount(String value,boolean travel) {
        try {
            if(value==null||!value.matches("[0-9]{1,14}(?:\\.[0-9]{1,2})?"))throw invalid("金额请填写最多两位小数的非负数字");
            BigDecimal amount=new BigDecimal(value).setScale(2,RoundingMode.UNNECESSARY);
            if(amount.signum()<0||(!travel&&amount.signum()==0))throw invalid("付款金额必须大于零");
            return amount;
        } catch(NumberFormatException|ArithmeticException ex){throw invalid("金额格式不正确");}
    }
    public static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
