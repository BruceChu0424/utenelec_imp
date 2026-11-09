package com.uten.imp.features.sales;

import com.uten.imp.application.port.SalesManagerReviewNoticePort;
import com.uten.imp.application.port.SalesManagerReviewerEligibilityPort;
import com.uten.imp.application.port.TaskClaimMutationGuardPort;
import com.uten.imp.common.util.NativeValueConverters;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.sales.order.SalesOrder;
import com.uten.imp.features.sales.order.SalesOrderRepository;
import com.uten.imp.features.sales.order.SalesOrderRevisionService;
import com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService.FinanceBatchConfirmRequest;
import com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService.FinanceBatchConfirmResult;
import com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService.FinanceConfirmRequest;
import com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService.FinanceRejectRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Management queue and order decisions; commercial calculations remain in the existing document services. */
@Service
@RequiredArgsConstructor
public class SalesManagerReviewService implements com.uten.imp.application.port.SalesManagerReviewCatchUpPort {
    private com.uten.imp.features.sales.order.SalesOrderDeliveryService deliveryService;
    @org.springframework.beans.factory.annotation.Autowired
    public void setDeliveryService(com.uten.imp.features.sales.order.SalesOrderDeliveryService service) { deliveryService=service; }
    public static final String ORDER_TARGET = "SALES_ORDER_MANAGER_REVIEW";
    private final EntityManager em;
    private final SalesOrderRepository orders;
    private final SalesOrderRevisionService revisions;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final SalesManagerReviewerEligibilityPort reviewers;
    private final TaskClaimMutationGuardPort claims;
    private final SalesManagerReviewNoticePort notices;
    private final com.uten.imp.features.notice.ChainNoticeService chainNotice;

    /** Login/arrival reads call this in a separate write transaction; ordinary reads never become business decisions. */
    @Override
    @Transactional(propagation=org.springframework.transaction.annotation.Propagation.REQUIRES_NEW)
    public void catchUp(UUID userId) {
        if(!currentUser.requireId().equals(userId)) throw new ApiException(ErrorCode.FORBIDDEN,"只能检查本人审核提醒");
        tx.bind();
        for(String kind:List.of("quote","order")) {
            // Actual grants determine task ownership; implicit super-admin authority is not a subscription.
            if(!reviewers.reviewers(kind).contains(userId)) continue;
            String event="SALES_"+kind.toUpperCase(java.util.Locale.ROOT)+"_PENDING_MANAGER_REVIEW";
            @SuppressWarnings("unchecked") List<UUID> ids=em.createNativeQuery("SELECT o.id FROM "+table(kind)
                    +" o WHERE NOT o.is_deleted AND o.manager_review_state='PENDING' AND "+reviewable(kind)
                    +" AND NOT EXISTS(SELECT 1 FROM notices n WHERE n.audience_user_id=:user AND n.aggregate_id=o.id"
                    +" AND n.source_event=:event AND n.resolved_at IS NULL) ORDER BY o.id LIMIT 20 FOR UPDATE OF o SKIP LOCKED")
                    .setParameter("user",userId).setParameter("event",event).getResultList();
            for(UUID id:ids) notices.pendingForUser(kind,id,userId);
        }
    }

    public record Task(UUID id, String billNo, LocalDate billDate, String clientName, String sellerName,
            String currencyName,
            @com.fasterxml.jackson.databind.annotation.JsonSerialize(using=com.uten.imp.common.finance.ExactDecimalText.class) BigDecimal totalOriginal,
            String state, long revision, String reason, OffsetDateTime approvedAt, String approvedByName,
            OffsetDateTime rejectedAt, String rejectedByName, String remark, String kind) {}

    static String table(String kind) {
        return switch (kind) { case "quote" -> "sales_quotes"; case "order" -> "sales_orders";
            default -> throw new ApiException(ErrorCode.VALIDATION_FAILED, "单据类型不正确"); };
    }

    private void requireAccess(String kind, String action) {
        table(kind);
        if (!reviewers.eligible(currentUser.requireId(), kind, action))
            throw new ApiException(ErrorCode.FORBIDDEN, "当前账号没有本次销售负责人审核权限，或员工账号已停用");
    }

    static String reviewable(String kind) {
        return "quote".equals(kind) ? "o.status=2 AND NOT o.is_closed"
                : "o.status=1 AND NOT o.is_stopped AND (NOT o.is_closed OR o.finance_review_revision>0) AND o.requoted_to_id IS NULL AND NOT o.finance_confirmed AND NOT o.finance_rejected";
    }

    @Transactional(readOnly=true)
    public PageResponse<Task> list(String kind, String state, String keyword, int page, int size) {
        return list(kind,state,keyword,page,size,Map.of());
    }

    @Transactional(readOnly=true)
    public PageResponse<Task> list(String kind, String state, String keyword, int page, int size,
            Map<String,String> columns) {
        List<String> kinds;
        if ("all".equals(kind)) {
            kinds=List.of("quote","order").stream()
                    .filter(value -> reviewers.eligible(currentUser.requireId(),value,"view")).toList();
            if(kinds.isEmpty()) throw new ApiException(ErrorCode.FORBIDDEN,"当前账号没有销售负责人审核查看权限");
        } else { requireAccess(kind,"view"); kinds=List.of(kind); }
        String normalized=state==null?"PENDING":state.toUpperCase(java.util.Locale.ROOT);
        if(!List.of("PENDING","APPROVED","REJECTED","HISTORY").contains(normalized))
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"审核分类不正确");
        boolean history="HISTORY".equals(normalized), pending="PENDING".equals(normalized);
        String union=kinds.stream().map(value -> taskProjection(value,history,pending))
                .collect(java.util.stream.Collectors.joining(" UNION ALL "));
        String search=com.uten.imp.common.util.KeywordSearch.phrase(keyword);
        var fields=new java.util.LinkedHashMap<String,com.uten.imp.common.util.SqlColumnSearch.Field>();
        for(String key:List.of("billNo","client","seller","kind","state","reason","approver")) {
            String expression=switch(key) {
                case "kind" -> "CASE t.kind WHEN 'quote' THEN '报价单' ELSE '订货单' END";
                case "state" -> "CASE t.state WHEN 'PENDING' THEN '等待销售负责人审核' WHEN 'APPROVED' THEN '负责人已通过' ELSE '负责人已驳回' END";
                default -> "t."+key;
            };
            fields.put(key,com.uten.imp.common.util.SqlColumnSearch.Field.text(expression));
        }
        fields.put("amount",com.uten.imp.common.util.SqlColumnSearch.Field.decimal("t.amount"));
        fields.put("billDate",com.uten.imp.common.util.SqlColumnSearch.Field.calendarDate("t.billDate"));
        fields.put("approvedAt",com.uten.imp.common.util.SqlColumnSearch.Field.instant("t.approvedAt"));
        var headers=com.uten.imp.common.util.SqlColumnSearch.criteria(columns,fields,"manager_");
        String from=" FROM ("+union+") t WHERE "+headers.predicate()
                +(search.isEmpty()?"":" AND "+com.uten.imp.common.util.TaskKeywordSearch.conditionParameter("keyword","t.billNo","t.client","t.seller"));
        var count=em.createNativeQuery("SELECT COUNT(*)"+from);
        if(!history) count.setParameter("managerState",normalized);
        headers.bind(count); if(!search.isEmpty()) count.setParameter("keyword",search);
        long total=((Number)count.getSingleResult()).longValue();
        int sz=Math.max(1,Math.min(size,Pageables.MAX_PAGE_SIZE)),pages=(int)((total+sz-1)/sz);
        int p=Math.max(1,Math.min(page,Math.max(1,pages)));
        var query=em.createNativeQuery("SELECT t.id,t.billNo,t.billDate,t.client,t.seller,t.currency,t.amount,t.state,t.revision,"
                +"t.reason,t.approvedAt,t.approver,t.rejectedAt,t.rejector,t.remark,t.kind"+from
                +" ORDER BY t.billDate,t.billNo,t.id LIMIT :lim OFFSET :off")
                .setParameter("lim",sz).setParameter("off",(long)(p-1)*sz);
        if(!history) query.setParameter("managerState",normalized);
        headers.bind(query); if(!search.isEmpty()) query.setParameter("keyword",search);
        @SuppressWarnings("unchecked") List<Object[]> rows=query.getResultList();
        List<Task> result=rows.stream().map(r -> new Task(NativeValueConverters.uuid(r[0]),(String)r[1],NativeValueConverters.toLocalDate(r[2]),
                (String)r[3],(String)r[4],(String)r[5],NativeValueConverters.toBigDecimal(r[6]),(String)r[7],((Number)r[8]).longValue(),
                (String)r[9],NativeValueConverters.toOffsetDateTime(r[10]),(String)r[11],
                NativeValueConverters.toOffsetDateTime(r[12]),(String)r[13],(String)r[14],(String)r[15])).toList();
        return new PageResponse<>(result,p,sz,total,pages);
    }

    private static String taskProjection(String kind,boolean history,boolean pending) {
        String sourceTable=table(kind);
        String revision="quote".equals(kind)?"o.review_revision":"o.finance_review_revision";
        String kindLiteral="quote".equals(kind)?"'quote'":"'order'";
        String status=history?"o.manager_review_state IN ('APPROVED','REJECTED')":"o.manager_review_state=:managerState";
        // Stable unique aliases keep both document projections and native row mapping consistent.
        return "SELECT o.id AS id,o.bill_no AS billNo,o.bill_date AS billDate,COALESCE(c.name,'') AS client,"
                +"COALESCE(seller.full_name,'') AS seller,COALESCE(cur.name,'') AS currency,o.total_original AS amount,"
                +"o.manager_review_state AS state,"+revision+" AS revision,o.manager_reject_reason AS reason,"
                +"o.manager_approved_at AS approvedAt,approver.full_name AS approver,o.manager_rejected_at AS rejectedAt,"
                +"rejector.full_name AS rejector,o.manager_review_remark AS remark,"+kindLiteral+" AS kind"
                +" FROM "+sourceTable+" o LEFT JOIN clients c ON c.id=o.client_id"
                +" LEFT JOIN employees seller ON seller.id=COALESCE(o.seller_id,o.maker_id)"
                +" LEFT JOIN currencies cur ON cur.id=o.currency_id LEFT JOIN employees approver ON approver.id=o.manager_approved_by"
                +" LEFT JOIN employees rejector ON rejector.id=o.manager_rejected_by WHERE NOT o.is_deleted AND "+status
                +(pending?" AND "+reviewable(kind):"");
    }

    @Transactional(readOnly=true)
    public Map<String,Long> counts() {
        long quote=count("quote"), order=count("order");
        return Map.of("quote",quote,"order",order,"count",quote+order);
    }
    private long count(String kind) {
        var permissions = currentUser.get().map(com.uten.imp.security.AuthUser::getPermissions).orElse(java.util.Set.of());
        String prefix="sales_"+kind+"_manager:";
        if (!permissions.contains(prefix+"view") || !(permissions.contains(prefix+"confirm") || permissions.contains(prefix+"reject"))) return 0;
        if (!reviewers.eligible(currentUser.requireId(),kind,"claim")) return 0;
        return ((Number)em.createNativeQuery("SELECT COUNT(*) FROM "+table(kind)
                +" o WHERE NOT o.is_deleted AND o.manager_review_state='PENDING' AND "+reviewable(kind)).getSingleResult()).longValue();
    }

    private SalesOrder lock(UUID id, Long revision) {
        if (revision == null) throw new ApiException(ErrorCode.VALIDATION_FAILED,"缺少审核修订号，请刷新后重试");
        SalesOrder order=orders.findActiveByIdForUpdate(id).orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND,"销售订货单不存在"));
        com.uten.imp.common.history.ImportedBusinessDocumentPolicy.mutable(em,"sales_orders",order);
        if (revision != order.getFinanceReviewRevision())
            throw new ApiException(ErrorCode.CONFLICT,"订单已变化，请刷新并核对当前版本后再审核");
        if (order.getStatus()==null || order.getStatus()!=1 || order.isStopped()
                || (order.isClosed() && order.getFinanceReviewRevision()==0) || order.getRequotedToId()!=null || order.isFinanceConfirmed())
            throw new ApiException(ErrorCode.CONFLICT,"订单已不在销售负责人审核阶段");
        return order;
    }
    private static void requirePending(SalesOrder order) {
        if(order.isFinanceRejected()) throw new ApiException(ErrorCode.CONFLICT,"订单已由财务退回，须销售修订并重新提交后再审核");
        if (!order.getManagerReview().pending()) throw new ApiException(ErrorCode.CONFLICT,"订单已不在待负责人审核状态，请刷新");
    }
    private static String note(String value, boolean required) {
        String result=value==null ? "" : value.strip();
        if ((required && result.isEmpty()) || result.length()>500)
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"请填写原因，且不要超过 500 字");
        return result.isEmpty()?null:result;
    }
    @Transactional
    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('sales_order_manager:view') and hasAuthority('sales_order_manager:confirm')")
    public void confirmOrder(UUID id, FinanceConfirmRequest request) {
        requireAccess("order","confirm"); tx.bind();
        if (request == null) throw new ApiException(ErrorCode.VALIDATION_FAILED,"请提供负责人审核确认请求");
        if (request.expectedClaimId() == null) throw new ApiException(ErrorCode.VALIDATION_FAILED,"缺少本次审核认领编号，请重新认领后重试");
        SalesOrder order=lock(id,request.expectedRevision()); requirePending(order);
        claims.requireActiveClaimByMe(ORDER_TARGET,id.toString(),request.expectedClaimId());
        order.getManagerReview().setDecisionClaimId(request.expectedClaimId());
        approve(order,note(request.remark(),false));
    }
    @Transactional
    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('sales_order_manager:view') and hasAuthority('sales_order_manager:confirm')")
    public FinanceBatchConfirmResult confirmOrders(FinanceBatchConfirmRequest request) {
        requireAccess("order","confirm"); tx.bind();
        if (request==null || request.orderIds()==null || request.orderIds().isEmpty() || request.orderIds().size()>100
                || request.orderIds().stream().anyMatch(java.util.Objects::isNull))
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"请选择 1 至 100 笔订单");
        var ids=request.orderIds().stream().distinct().sorted(java.util.Comparator.comparing(UUID::toString)).toList();
        if (request.expectedRevisions() == null || request.expectedClaimIds() == null
                || ids.stream().anyMatch(id -> request.expectedRevisions().get(id) == null || request.expectedClaimIds().get(id) == null))
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"每笔订单都须提供审核修订号和本次认领编号");
        var locked=new ArrayList<SalesOrder>();
        String remark=note(request.remark(),false);
        for (UUID id:ids) { var order=lock(id,request.expectedRevisions().get(id)); requirePending(order); locked.add(order); }
        claims.requireActiveClaimsByMe(ORDER_TARGET,ids.stream().map(id -> new TaskClaimMutationGuardPort.ClaimExpectation(
                id.toString(),request.expectedClaimIds().get(id))).toList());
        for (SalesOrder order:locked) { order.getManagerReview().setDecisionClaimId(request.expectedClaimIds().get(order.getId())); approve(order,remark); }
        return new FinanceBatchConfirmResult(ids.size(),ids.size(),0,ids);
    }
    private void approve(SalesOrder order,String remark) {
        if (deliveryService!=null) deliveryService.validateOrderApproval(order.getId());
        order.getManagerReview().approve(currentUser.requireEmployeeId(),remark);
        order.setFinanceReviewRevision(order.getFinanceReviewRevision()+1);
        orders.saveAndFlush(order); event(order,"APPROVED",remark);
        notices.resolved("order",order.getId(),"APPROVED");
        claims.release(ORDER_TARGET,order.getId().toString());
        chainNotice.notifyOrderPendingFinanceConfirmation(order.getId(),order.getFinanceConfirmedAt()!=null);
    }
    @Transactional
    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('sales_order_manager:view') and hasAuthority('sales_order_manager:reject')")
    public void rejectOrder(UUID id, FinanceRejectRequest request) {
        requireAccess("order","reject"); tx.bind();
        if (request == null) throw new ApiException(ErrorCode.VALIDATION_FAILED,"请提供负责人审核驳回请求");
        String reason=note(request.reason(),true);
        if (request.expectedClaimId() == null) throw new ApiException(ErrorCode.VALIDATION_FAILED,"缺少本次审核认领编号，请重新认领后重试");
        SalesOrder order=lock(id,request.expectedRevision()); requirePending(order);
        claims.requireActiveClaimByMe(ORDER_TARGET,id.toString(),request.expectedClaimId());
        order.getManagerReview().reject(currentUser.requireEmployeeId(),reason);
        order.getManagerReview().setDecisionClaimId(request.expectedClaimId());
        order.setFinanceReviewRevision(order.getFinanceReviewRevision()+1);
        orders.saveAndFlush(order); event(order,"REJECTED",reason);
        notices.resolved("order",id,"REJECTED"); notices.rejected("order",id,reason); claims.release(ORDER_TARGET,id.toString());
    }
    /** The client persists this identity before sending; only its immutable event proves a lost response. */
    public record ReverseRequest(
            @jakarta.validation.constraints.NotNull UUID decisionId,
            @jakarta.validation.constraints.NotNull Long expectedRevision,
            @jakarta.validation.constraints.NotBlank @jakarta.validation.constraints.Size(max=500) String reason) {}

    @Transactional
    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('sales_order_manager:view') and hasAuthority('sales_order_manager:reverse')")
    public void reverseOrder(UUID id, ReverseRequest request) {
        requireAccess("order","reverse"); tx.bind();
        if (request == null || request.decisionId() == null)
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"缺少反审核决定身份，请重新核对后提交");
        String reason=note(request.reason(),true);
        SalesOrder order=lock(id,request.expectedRevision());
        if (!order.getManagerReview().approved() || order.isFinanceRejected())
            throw new ApiException(ErrorCode.CONFLICT,"只有负责人已批准、财务尚未办结的订单可以反审核");
        claims.requireNoActiveClaim("SALES_ORDER_FINANCE_CONFIRM",id.toString());
        order.getManagerReview().submit(); order.setFinanceReviewRevision(order.getFinanceReviewRevision()+1);
        orders.saveAndFlush(order); event(order,"REVERSED",reason,request.decisionId());
        chainNotice.resolveSalesFinanceReviewNotices(id,"MANAGER_REVERSED"); notices.pending("order",id);
    }
    private void event(SalesOrder order,String action,String reason) {
        event(order,action,reason,UUID.randomUUID());
    }
    private void event(SalesOrder order,String action,String reason,UUID decisionId) {
        String snapshot=revisions.snapshot(order.getId());
        int inserted=em.createNativeQuery("INSERT INTO sales_order_manager_review_events(id,order_id,revision,action,actor_id,reason,claim_id,snapshot) VALUES(:decision,:id,:rev,:action,:actor,:reason,:claim,CAST(:snapshot AS jsonb)) ON CONFLICT(id) DO NOTHING")
                .setParameter("decision",decisionId)
                .setParameter("id",order.getId()).setParameter("rev",order.getFinanceReviewRevision()).setParameter("action",action)
                .setParameter("actor",currentUser.requireEmployeeId()).setParameter("reason",reason)
                .setParameter("claim",order.getManagerReview().getDecisionClaimId()).setParameter("snapshot",snapshot).executeUpdate();
        if (inserted != 1) throw new ApiException(ErrorCode.CONFLICT,"决定身份已经使用，请读取原审核结果，不能重放或覆盖");
    }
}
