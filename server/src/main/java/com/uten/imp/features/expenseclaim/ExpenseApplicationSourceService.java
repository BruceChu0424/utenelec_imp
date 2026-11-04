package com.uten.imp.features.expenseclaim;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimDto;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import java.util.*;

/** Source form metadata only. This service cannot approve, pay or create a ledger. */
@Service @RequiredArgsConstructor
public class ExpenseApplicationSourceService {
    private final JdbcTemplate db;
    private final SecurityContextCurrentUser current;

    @Transactional(propagation=Propagation.MANDATORY)
    public void save(UUID claimId,String kind,String expenseKind,UUID travelId,String sourceKind){
        if(kind==null)kind="TRAVEL".equals(expenseKind)?"TRAVEL_REIMBURSEMENT":"REIMBURSEMENT";
        if(!Set.of("REIMBURSEMENT","TRAVEL_REIMBURSEMENT").contains(kind))throw invalid("原报销来源类型不正确");
        String nativeKind="TRAVEL_REIMBURSEMENT".equals(kind)?"TRAVEL":"GENERAL";
        if(expenseKind!=null&&!nativeKind.equals(expenseKind))throw invalid("报销类别与原申请类型不一致，请核对原表");
        var claim=db.queryForMap("SELECT applicant_id,expense_kind,status,is_deleted FROM expense_claims WHERE id=? FOR UPDATE",claimId);
        var actor=current.requireEmployeeId();
        boolean owner=Boolean.TRUE.equals(db.queryForObject("SELECT fn_canonical_employee_identity(?::uuid)=fn_canonical_employee_identity(?::uuid)",Boolean.class,actor,claim.get("applicant_id")));
        if(!owner)throw new ApiException(ErrorCode.FORBIDDEN);
        if(Boolean.TRUE.equals(claim.get("is_deleted"))||!Set.of("DRAFT","REJECTED").contains(claim.get("status")))throw invalid("只能修改本人可编辑报销草稿的原申请来源");
        if(!nativeKind.equals(claim.get("expense_kind")))throw invalid("原表类别与已保存报销类别不一致");
        UUID business=null,finance=null;
        if("TRAVEL_REIMBURSEMENT".equals(kind)){
            if(travelId==null)throw invalid("请明确选择本人已批准并由财务保管的出差申请");
            // Omitted namespace is the original request contract, never a probe of two tables.
            if(sourceKind==null)sourceKind="FINANCE_APPLICATION";
            if("BUSINESS_APPLICATION".equals(sourceKind))business=travelId;
            else if("FINANCE_APPLICATION".equals(sourceKind))finance=travelId;
            else throw invalid("出差来源类型不明确，请重新选择原申请");
        }else{
            if(travelId!=null||sourceKind!=null)throw invalid("普通报销不能混入出差申请来源");
        }
        db.update("""
            INSERT INTO expense_claim_source_links(claim_id,application_kind,travel_application_source_kind,
              business_travel_application_id,finance_travel_application_id,created_by,updated_by)
            VALUES(?,?,?,?,?,?,?) ON CONFLICT(claim_id) DO UPDATE SET application_kind=excluded.application_kind,
              travel_application_source_kind=excluded.travel_application_source_kind,
              business_travel_application_id=excluded.business_travel_application_id,
              finance_travel_application_id=excluded.finance_travel_application_id,
              updated_by=excluded.updated_by,updated_at=now()
            """,claimId,kind,sourceKind,business,finance,current.requireId(),current.requireId());
    }

    @Transactional(propagation=Propagation.MANDATORY)
    public void validateForSubmit(UUID id){db.queryForObject("SELECT fn_assert_expense_original_source(?)",Object.class,id);}

    @Transactional(readOnly=true)
    public List<ExpenseClaimDto> attach(List<ExpenseClaimDto> rows){
        if(rows.isEmpty())return rows;
        var ids=rows.stream().map(ExpenseClaimDto::id).toList();
        var params=new HashMap<String,Object>();params.put("ids",ids);
        var named=new org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate(db);
        Map<UUID,Map<String,Object>> sources=new HashMap<>();
        for(var r:named.queryForList("SELECT claim_id,application_kind,travel_application_source_kind,COALESCE(business_travel_application_id,finance_travel_application_id) AS travel_id FROM expense_claim_source_links WHERE claim_id IN(:ids)",params))sources.put((UUID)r.get("claim_id"),r);
        return rows.stream().map(row->{var source=sources.get(row.id());return source==null?row:row.withApplicationSource(
                (String)source.get("application_kind"),(UUID)source.get("travel_id"),(String)source.get("travel_application_source_kind"));}).toList();
    }
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
