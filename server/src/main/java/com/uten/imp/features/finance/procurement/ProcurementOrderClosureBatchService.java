package com.uten.imp.features.finance.procurement;

import com.uten.imp.common.concurrency.ProcurementMutationFootprint.OrderRef;
import com.uten.imp.common.concurrency.ProcurementMutationLocks;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.FinanceApproval;
import com.uten.imp.features.finance.procurement.ProcurementOrderClosureService.ClosurePreview;
import com.uten.imp.features.finance.procurement.ProcurementOrderClosureService.ClosureRequest;
import com.uten.imp.security.TxSessionVars;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.UUID;

/** Explicit whole-order batch requests. Every order completes, or the entire transaction rolls back. */
@Service
@RequiredArgsConstructor
public class ProcurementOrderClosureBatchService {
    private final ProcurementOrderClosureService closures;
    private final ProcurementMutationLocks locks;
    private final TxSessionVars tx;

    public record Target(@NotBlank String orderType,@NotNull UUID orderId) {}
    public record PreviewRequest(@NotEmpty @Size(max=50) List<@Valid Target> orders) {}
    public record SubmissionItem(@NotBlank String orderType,@NotNull UUID orderId,@NotBlank String expectedFingerprint) {}
    public record SubmissionRequest(@NotBlank String mode,@NotBlank @Size(max=1000) String reason,
                                    @NotEmpty @Size(max=50) List<@Valid SubmissionItem> items) {}
    public record BatchPreview(List<ClosurePreview> items,boolean canSubmit) {}
    public record BatchSubmission(int submittedCount,List<FinanceApproval> approvals) {}

    /** Each preview owns its read transaction so a forbidden row cannot poison the remaining previews. */
    @PreAuthorize("hasAnyAuthority('purchase_order:view','subcontract_order:view')")
    public BatchPreview preview(PreviewRequest request) {
        List<Target> targets=targets(request==null?null:request.orders());
        List<ClosurePreview> items=new ArrayList<>();
        for(Target target:targets) {
            try {
                items.add(closures.preview(target.orderType(),target.orderId()));
            } catch(ApiException unavailable) {
                // Never return a commercial snapshot for a row whose live permission/scope check failed.
                items.add(new ClosurePreview(target.orderType(),target.orderId(),"","",false,
                        unavailable.getMessage(),List.of(),false,unavailable.getMessage(),false,null));
            }
        }
        return new BatchPreview(List.copyOf(items),items.stream().allMatch(ClosurePreview::canSubmit));
    }

    @Transactional
    @PreAuthorize("hasAnyAuthority('purchase_order:submit_finance','subcontract_order:submit_finance')")
    public BatchSubmission submit(SubmissionRequest request) {
        tx.bind();
        if(request==null || !("CLOSE".equals(request.mode()) || "CLOSE_AND_REORDER".equals(request.mode())))
            throw invalid("请选择直接结束或结束并重建剩余订单");
        String reason=request.reason()==null?"":request.reason().strip();
        if(reason.isEmpty()||reason.length()>1000)throw invalid("请填写结束原因，最多1000字");
        if(request.items()==null||request.items().isEmpty()||request.items().size()>50)
            throw invalid("批量取消/结束每次请选择1至50张订单");
        LinkedHashMap<Target,SubmissionItem> distinct=new LinkedHashMap<>();
        for(SubmissionItem item:request.items()) {
            if(item==null||item.expectedFingerprint()==null||item.expectedFingerprint().isBlank())
                throw invalid("请先逐单核对本批订单的剩余数量");
            Target target=normalize(new Target(item.orderType(),item.orderId()));
            SubmissionItem previous=distinct.putIfAbsent(target,new SubmissionItem(target.orderType(),target.orderId(),item.expectedFingerprint()));
            if(previous!=null&&!previous.expectedFingerprint().equals(item.expectedFingerprint()))
                throw invalid("同一订单出现不同的核对版本，请刷新后重新选择");
        }
        var guard=locks.ordersWithHeldPreStock(distinct.keySet().stream().map(target->new OrderRef(target.orderType(),target.orderId())).toList());
        guard.verifyUnchanged();
        // Recheck ALL rows before the first case, event or notification is inserted.
        for(SubmissionItem item:distinct.values()) {
            if(closures.completedMatchingRequest(item.orderType(),item.orderId(),request.mode(),reason,item.expectedFingerprint())!=null) continue;
            ClosurePreview preview=closures.preview(item.orderType(),item.orderId());
            if(!preview.canSubmit())throw conflict(preview.billNo()+"："+preview.blockReason());
            if(!preview.fingerprint().equals(item.expectedFingerprint()))
                throw conflict(preview.billNo()+"：收退货、质检或材料事实已变化，请重新核对整批订单");
            if("CLOSE_AND_REORDER".equals(request.mode())&&!preview.canReorder())
                throw conflict(preview.billNo()+"："+preview.blockReorderReason());
        }
        List<FinanceApproval> submitted=new ArrayList<>();
        for(SubmissionItem item:distinct.values())submitted.add(closures.submit(item.orderType(),item.orderId(),
                new ClosureRequest(request.mode(),reason,item.expectedFingerprint())));
        return new BatchSubmission(submitted.size(),List.copyOf(submitted));
    }

    private List<Target> targets(List<Target> supplied) {
        if(supplied==null||supplied.isEmpty()||supplied.size()>50)
            throw invalid("批量取消/结束每次请选择1至50张订单");
        return supplied.stream().map(ProcurementOrderClosureBatchService::normalize).distinct().toList();
    }
    private static Target normalize(Target target) {
        if(target==null||target.orderId()==null)throw invalid("请选择有效订货单");
        return new Target(ProcurementApprovalProjectionQuery.requireOrderType(target.orderType()),target.orderId());
    }
    private static ApiException invalid(String message) {return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
    private static ApiException conflict(String message) {return new ApiException(ErrorCode.CONFLICT,message);}
}
