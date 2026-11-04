package com.uten.imp.features.expenseclaim.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.Size;

import java.util.List;

public record ExpenseClaimCreateRequest(
        @NotBlank @Size(max = 200) String title,
        @Size(max = 2000) String remark,
        @NotEmpty @Size(max = 100) List<@Valid ExpenseClaimItemInput> items, Long expectedVersion,
        String expenseKind, String applicationKind,java.util.UUID travelApplicationId,String travelApplicationSourceKind
) {
    public ExpenseClaimCreateRequest(String title, String remark, List<ExpenseClaimItemInput> items) { this(title,remark,items,null,"GENERAL",null,null,null); }
    public ExpenseClaimCreateRequest(String title, String remark, List<ExpenseClaimItemInput> items, Long expectedVersion) { this(title,remark,items,expectedVersion,"GENERAL",null,null,null); }
    public ExpenseClaimCreateRequest(String title,String remark,List<ExpenseClaimItemInput> items,Long expectedVersion,String expenseKind){this(title,remark,items,expectedVersion,expenseKind,null,null,null);}
    public ExpenseClaimCreateRequest(String title,String remark,List<ExpenseClaimItemInput> items,Long expectedVersion,String applicationKind,java.util.UUID travelApplicationId){this(title,remark,items,expectedVersion,"TRAVEL_REIMBURSEMENT".equals(applicationKind)?"TRAVEL":"GENERAL",applicationKind,travelApplicationId,null);}
}
