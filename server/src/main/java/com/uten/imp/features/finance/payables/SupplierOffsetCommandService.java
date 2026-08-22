package com.uten.imp.features.finance.payables;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.gl.GlPostingService;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDate;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.features.finance.payables.SupplierOffsetContracts.*;

/** Finance command facade for applying purchase-return or accepted-claim credits. */
@Service
@RequiredArgsConstructor
public class SupplierOffsetCommandService {
    private final EntityManager em;
    private final TxSessionVars tx;
    private final SupplierOpenItemOffsetService offsets;
    private final GlPostingService glPosting;
    private final SupplierClosedPeriodGuard closedPeriodGuard;

    @Transactional
    public ApplyResult apply(ApplyRequest request){
        tx.bind();
        if(request==null||request.sourceLedgerId()==null||request.targets()==null
                ||request.targets().isEmpty())throw validation("贷项应用请求不完整");
        @SuppressWarnings("unchecked")
        List<Object[]> rows=em.createNativeQuery("""
                SELECT supplier_id,currency_id,open_item_kind
                FROM ar_ap_ledger
                WHERE id=:id AND direction='AP' AND status=1
                  AND COALESCE(is_deleted,FALSE)=FALSE
                """).setParameter("id",request.sourceLedgerId()).getResultList();
        if(rows.size()!=1)throw new ApiException(ErrorCode.NOT_FOUND,"贷项或索赔不存在");
        Object[] row=rows.getFirst();
        String kind=row[2].toString();
        if(!Set.of("CREDIT","CLAIM_CREDIT").contains(kind)){
            if("PREPAYMENT".equals(kind))throw conflict(
                    "供应商预付款是资产，不得继续按负应付应用；专用预付款科目/总账链完成前禁止自动核销");
            throw conflict("抵销来源不是可用的供应商贷项或已确认索赔");
        }
        UUID batchId=UUID.randomUUID();
        LocalDate effective=BusinessTime.today();
        if(request.effectiveDate()!=null&&!effective.equals(request.effectiveDate())){
            throw conflict("贷项应用日期由服务端按今天记账；禁止倒填或预填财务期间");
        }
        closedPeriodGuard.requireOpen(
                (UUID)row[0],(UUID)row[1],effective,"供应商贷项或索赔抵销");
        glPosting.lockAutoProjectionPeriod(effective);
        offsets.applyBatch(batchId,null,request.sourceLedgerId(),(UUID)row[0],(UUID)row[1],effective,
                request.targets().stream().map(target->new SupplierOpenItemOffsetService.Target(
                        target.payableId(),target.amountOriginal())).toList(),request.reason());
        return new ApplyResult(batchId);
    }

    @Transactional
    public void reverse(UUID batchId,ReverseRequest request){
        tx.bind();
        if(batchId==null||request==null)throw validation("抵销反转请求不完整");
        glPosting.lockAutoProjectionPeriod(BusinessTime.today());
        offsets.reverseBatch(batchId,request.reason());
    }

    private static ApiException validation(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
}
