package com.uten.imp.features.finance.payables;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.ProcurementIqcRejectionPort;
import com.uten.imp.application.port.ProcurementArrivalControlPort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.arap.ArApLedgerService;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.CaseCounts;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.CaseDetail;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.CaseEventItem;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.CaseItem;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.CasePage;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.CloseNoCreditRequest;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.ConfirmCreditRequest;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.RecordReturnRequest;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.ReplacementAllocationItem;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.ReverseRequest;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.RetryFinanceProjectionRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/** Separates IQC failure, physical supplier return and finance-confirmed supplier credit. */
@Service
@RequiredArgsConstructor
public class ProcurementIqcRejectionService implements ProcurementIqcRejectionPort {
    public static final String EVENT_OPENED = "PROCUREMENT_IQC_REJECTION_OPENED";
    public static final String EVENT_RETURNED = "PROCUREMENT_IQC_REJECTION_RETURNED";
    public static final String EVENT_CREDIT_CONFIRMED = "PROCUREMENT_IQC_CREDIT_CONFIRMED";
    public static final String EVENT_NO_CREDIT = "PROCUREMENT_IQC_REJECTION_NO_CREDIT";
    public static final String EVENT_REVERSED = "PROCUREMENT_IQC_REJECTION_REVERSED";
    public static final String EVENT_FINANCE_EXCEPTION =
            "PROCUREMENT_IQC_REJECTION_FINANCE_EXCEPTION";

    private static final Set<String> TYPES = Set.of("PURCHASE", "SUBCONTRACT");
    private static final Set<String> FILTER_STATUSES = Set.of(
            "PENDING_RETURN", "RETURN_RECORDED", "CREDIT_CONFIRMED",
            "CLOSED_NO_CREDIT", "FINANCE_EXCEPTION", "REVERSED","TERMINAL");

    private final EntityManager em;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final ArApLedgerService arApService;
    private final SupplierOpenItemOffsetService offsetService;
    private final BusinessEventPublisher events;
    private final ProcurementArrivalControlPort arrivalControl;

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void projectDetected(
            UUID outboxEventId,
            String rawReceiptType,
            UUID receiptId,
            UUID inspectionItemId,
            UUID inspectionEventId,
            UUID actorUserId) {
        if (outboxEventId == null || inspectionEventId == null || actorUserId == null) {
            throw validation("IQC不合格投影缺少事件或操作人身份");
        }
        tx.bindActor(actorUserId);
        String receiptType = type(rawReceiptType);
        if (alreadyHandled(inspectionEventId)) return;
        Source source = lockSource(receiptType, receiptId, inspectionItemId);
        if (!"PARTIAL".equals(source.inspectionStatus())
                && !"RESOLVED".equals(source.inspectionStatus())) {
            throw conflict("IQC失败事件状态与冻结行不一致");
        }
        if (source.receivedBase().signum() <= 0
                || source.failedBase().signum() <= 0
                || source.failedBase().compareTo(source.receivedBase()) > 0
                || source.unitRate().signum() <= 0
                || money(source.receiptQty().multiply(source.unitRate()))
                        .compareTo(money(source.receivedBase())) != 0) {
            throw conflict("IQC失败数量、收货数量或单位换算不守恒");
        }
        BigDecimal ratio = source.failedBase().divide(
                source.receivedBase(), 12, RoundingMode.HALF_UP);
        BigDecimal failedQty = quantity(source.receiptQty().multiply(ratio));
        FailedAmounts failedAmounts=failedAmounts(
                inspectionItemId,source.receivedBase(),source.failedBase(),
                source.receiptOriginal(),source.receiptLocal());
        BigDecimal failedOriginal=failedAmounts.original();
        BigDecimal failedLocal=failedAmounts.local();
        Projection projection = projection(source, failedOriginal, failedLocal);

        @SuppressWarnings("unchecked")
        List<Object[]> existing = em.createNativeQuery("""
                        SELECT id,status,row_version
                        FROM procurement_iqc_rejection_cases
                        WHERE inspection_item_id=:inspectionItemId
                        FOR UPDATE
                        """)
                .setParameter("inspectionItemId", inspectionItemId)
                .getResultList();
        UUID caseId;
        long version;
        if (existing.isEmpty()) {
            caseId = UUID.randomUUID();
            version = 1;
            em.createNativeQuery("""
                    INSERT INTO procurement_iqc_rejection_cases(
                        id,receipt_type,receipt_id,receipt_item_id,inspection_item_id,
                        order_item_id,source_ap_ledger_id,receipt_bill_no,order_bill_no,
                        supplier_id,currency_id,exchange_rate,tax_rate,settlement_method_id,
                        goods_id,color_id,unit_id,unit_rate,received_base_qty,
                        received_qty,received_amount_original,received_amount_local,
                        failed_base_qty,failed_qty,failed_amount_original,failed_amount_local,
                        owner_user_id,status,row_version,
                        finance_exception_code,finance_exception_message,
                        finance_exception_at,created_by,updated_by)
                    VALUES(
                        :id,:receiptType,:receiptId,:receiptItemId,:inspectionItemId,
                        :orderItemId,:sourceApId,:receiptBillNo,:orderBillNo,
                        :supplierId,:currencyId,:rate,:taxRate,:settlementMethodId,
                        :goodsId,:colorId,:unitId,:unitRate,:receivedBase,
                        :receivedQty,:receivedOriginal,:receivedLocal,
                        :failedBase,:failedQty,:failedOriginal,:failedLocal,
                        :ownerUserId,:status,1,:exceptionCode,:exceptionMessage,
                        :exceptionAt,:actor,:actor)
                    """)
                    .setParameter("id", caseId)
                    .setParameter("receiptType", receiptType)
                    .setParameter("receiptId", receiptId)
                    .setParameter("receiptItemId", source.receiptItemId())
                    .setParameter("inspectionItemId", inspectionItemId)
                    .setParameter("orderItemId", source.orderItemId())
                    .setParameter("sourceApId", projection.sourceApLedgerId())
                    .setParameter("receiptBillNo", source.receiptBillNo())
                    .setParameter("orderBillNo", source.orderBillNo())
                    .setParameter("supplierId", source.supplierId())
                    .setParameter("currencyId", source.currencyId())
                    .setParameter("rate", source.exchangeRate())
                    .setParameter("taxRate", source.taxRate())
                    .setParameter("settlementMethodId", source.settlementMethodId())
                    .setParameter("goodsId", source.goodsId())
                    .setParameter("colorId", source.colorId())
                    .setParameter("unitId", source.unitId())
                    .setParameter("unitRate", source.unitRate())
                    .setParameter("receivedBase", source.receivedBase())
                    .setParameter("receivedQty",source.receiptQty())
                    .setParameter("receivedOriginal",source.receiptOriginal())
                    .setParameter("receivedLocal",source.receiptLocal())
                    .setParameter("failedBase", source.failedBase())
                    .setParameter("failedQty", failedQty)
                    .setParameter("failedOriginal", failedOriginal)
                    .setParameter("failedLocal", failedLocal)
                    .setParameter("ownerUserId", source.ownerUserId())
                    .setParameter("status", projection.status())
                    .setParameter("exceptionCode", projection.exceptionCode())
                    .setParameter("exceptionMessage", projection.exceptionMessage())
                    .setParameter("exceptionAt", projection.exceptionCode() == null
                            ? null : java.time.OffsetDateTime.now())
                    .setParameter("actor", actorUserId)
                    .executeUpdate();
        } else {
            Object[] row = existing.getFirst();
            caseId = uuid(row[0]);
            if (!Set.of("PENDING_RETURN","FINANCE_EXCEPTION").contains(text(row[1]))) {
                throw conflict("IQC失败数量在退回或贷项确认后又发生变化，请先反向下游任务");
            }
            long previousVersion = ((Number) row[2]).longValue();
            version = previousVersion + 1;
            int updated = em.createNativeQuery("""
                    UPDATE procurement_iqc_rejection_cases
                    SET source_ap_ledger_id=:sourceApId,
                        failed_base_qty=:failedBase,failed_qty=:failedQty,
                        failed_amount_original=:failedOriginal,
                        failed_amount_local=:failedLocal,
                        status=:status,finance_exception_code=:exceptionCode,
                        finance_exception_message=:exceptionMessage,
                        finance_exception_at=:exceptionAt,
                        row_version=row_version+1,updated_by=:actor
                    WHERE id=:id AND status IN('PENDING_RETURN','FINANCE_EXCEPTION')
                      AND row_version=:version
                    """)
                    .setParameter("sourceApId", projection.sourceApLedgerId())
                    .setParameter("failedBase", source.failedBase())
                    .setParameter("failedQty", failedQty)
                    .setParameter("failedOriginal", failedOriginal)
                    .setParameter("failedLocal", failedLocal)
                    .setParameter("status", projection.status())
                    .setParameter("exceptionCode", projection.exceptionCode())
                    .setParameter("exceptionMessage", projection.exceptionMessage())
                    .setParameter("exceptionAt", projection.exceptionCode() == null
                            ? null : java.time.OffsetDateTime.now())
                    .setParameter("actor", actorUserId)
                    .setParameter("id", caseId)
                    .setParameter("version", previousVersion)
                    .executeUpdate();
            if (updated != 1) throw conflict("IQC失败任务版本已变化");
        }
        appendEvent(
                caseId,
                projection.exceptionCode() == null ? "FAIL_PROJECTED" : "FINANCE_EXCEPTION",
                inspectionEventId, actorUserId,
                projection.exceptionCode() == null
                        ? "IQC失败来源、数量与金额已冻结"
                        : projection.exceptionMessage());
        publish(EVENT_OPENED,caseId,receiptType,projection.status(),version,
                inspectionEventId.toString());
        if(projection.exceptionCode()!=null){
            publish(EVENT_FINANCE_EXCEPTION,caseId,receiptType,
                    projection.status(),version,inspectionEventId.toString());
        }
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void beforeReceiptReverse(String rawReceiptType, UUID receiptId) {
        tx.bind();
        String receiptType = type(rawReceiptType);
        long pendingProjection=((Number)em.createNativeQuery("""
                SELECT COUNT(*) FROM business_outbox
                WHERE event_type='PROCUREMENT_IQC_REJECTION_DETECTED'
                  AND payload->>'receiptType'=:receiptType
                  AND payload->>'receiptId'=:receiptId
                  AND status<>1
                """).setParameter("receiptType",receiptType)
                .setParameter("receiptId",receiptId.toString())
                .getSingleResult()).longValue();
        if(pendingProjection!=0){
            throw conflict("该收货仍有IQC失败财务投影待处理或待重试，禁止红冲");
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT id,status,row_version,return_recorded_at
                        FROM procurement_iqc_rejection_cases
                        WHERE receipt_type=:receiptType AND receipt_id=:receiptId
                          AND COALESCE(is_deleted,FALSE)=FALSE
                        ORDER BY id FOR UPDATE
                        """)
                .setParameter("receiptType", receiptType)
                .setParameter("receiptId", receiptId)
                .getResultList();
        for (Object[] row : rows) {
            UUID caseId = uuid(row[0]);
            String status = text(row[1]);
            long version = ((Number) row[2]).longValue();
            if ("REVERSED".equals(status)) continue;
            if (!Set.of("PENDING_RETURN","FINANCE_EXCEPTION").contains(status)) {
                throw conflict("IQC不合格已登记实物退回或供应商贷项，请先反向该任务");
            }
            if("FINANCE_EXCEPTION".equals(status)&&row[3]!=null){
                throw conflict("财务异常任务已登记实物退回，请先反向退回/补货事实");
            }
            int updated=em.createNativeQuery("""
                    UPDATE procurement_iqc_rejection_cases
                    SET status='REVERSED',row_version=row_version+1,
                        previous_status=:previousStatus,
                        reversed_by=:actor,reversed_at=now(),
                        reverse_reason='来源收货红冲',updated_by=:actor
                    WHERE id=:id AND status=:previousStatus AND row_version=:version
                    """).setParameter("actor", currentUser.requireId())
                    .setParameter("previousStatus",status)
                    .setParameter("version",version)
                    .setParameter("id", caseId).executeUpdate();
            if(updated!=1)throw concurrentChange();
            appendEvent(caseId, "SOURCE_RECEIPT_REVERSED", null, "来源收货红冲");
            publish(EVENT_REVERSED, caseId, receiptType, "REVERSED", version + 1,
                    "SOURCE_RECEIPT");
        }
    }

    @Transactional(readOnly = true)
    public CasePage list(
            String rawReceiptType, String rawStatus, String keyword, int page, int size) {
        String receiptType = optionalType(rawReceiptType);
        String status = upper(rawStatus);
        if (status != null && !FILTER_STATUSES.contains(status)) {
            throw validation("IQC不合格任务状态无效");
        }
        int safePage = Math.max(1, page);
        int safeSize = Math.min(Math.max(1, size), 200);
        StringBuilder where = new StringBuilder(
                " WHERE COALESCE(rejection.is_deleted,FALSE)=FALSE");
        Map<String, Object> params = new LinkedHashMap<>();
        if (receiptType != null) add(where, params, "rejection.receipt_type=:receiptType",
                "receiptType", receiptType);
        if ("TERMINAL".equals(status)) {
            where.append(" AND rejection.status IN(")
                    .append("'CREDIT_CONFIRMED','CLOSED_NO_CREDIT','REVERSED')");
        } else if (status != null) {
            add(where, params, "rejection.status=:status", "status", status);
        }
        if (keyword != null && !keyword.isBlank()) {
            add(where, params, "(LOWER(rejection.receipt_bill_no) LIKE :keyword"
                            + " OR LOWER(COALESCE(rejection.order_bill_no,'')) LIKE :keyword"
                            + " OR LOWER(COALESCE(supplier.name,'')) LIKE :keyword"
                            + " OR LOWER(COALESCE(goods.code,'')) LIKE :keyword"
                            + " OR LOWER(COALESCE(goods.name,'')) LIKE :keyword)",
                    "keyword", "%" + keyword.trim().toLowerCase(Locale.ROOT) + "%");
        }
        if (!canViewAllCases()) {
            add(where, params, "rejection.owner_user_id=:currentUserId",
                    "currentUserId", currentUser.requireId());
        }
        Query data = em.createNativeQuery(select() + from() + where
                + " ORDER BY rejection.created_at DESC,rejection.id LIMIT :limit OFFSET :offset");
        bind(data, params);
        data.setParameter("limit", safeSize);
        data.setParameter("offset", (long) (safePage - 1) * safeSize);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = data.getResultList();
        Query count = em.createNativeQuery("SELECT COUNT(*)" + from() + where);
        bind(count, params);
        long total = ((Number) count.getSingleResult()).longValue();
        return new CasePage(rows.stream().map(this::item).toList(),
                safePage, safeSize, total, (int) ((total + safeSize - 1) / safeSize));
    }

    @Transactional(readOnly = true)
    public CaseCounts counts(String rawReceiptType, String keyword) {
        String receiptType = optionalType(rawReceiptType);
        StringBuilder where = new StringBuilder(
                " WHERE COALESCE(rejection.is_deleted,FALSE)=FALSE");
        Map<String, Object> params = new LinkedHashMap<>();
        if (receiptType != null) {
            add(where, params, "rejection.receipt_type=:receiptType",
                    "receiptType", receiptType);
        }
        if (keyword != null && !keyword.isBlank()) {
            add(where, params, "(LOWER(rejection.receipt_bill_no) LIKE :keyword"
                            + " OR LOWER(COALESCE(rejection.order_bill_no,'')) LIKE :keyword"
                            + " OR LOWER(COALESCE(supplier.name,'')) LIKE :keyword"
                            + " OR LOWER(COALESCE(goods.code,'')) LIKE :keyword"
                            + " OR LOWER(COALESCE(goods.name,'')) LIKE :keyword)",
                    "keyword", "%" + keyword.trim().toLowerCase(Locale.ROOT) + "%");
        }
        if (!canViewAllCases()) {
            add(where, params, "rejection.owner_user_id=:currentUserId",
                    "currentUserId", currentUser.requireId());
        }
        Query query = em.createNativeQuery("""
                SELECT COUNT(*),
                       COUNT(*) FILTER (WHERE rejection.status='PENDING_RETURN'),
                       COUNT(*) FILTER (WHERE rejection.status='RETURN_RECORDED'),
                       COUNT(*) FILTER (WHERE rejection.status='CREDIT_CONFIRMED'),
                       COUNT(*) FILTER (WHERE rejection.status='CLOSED_NO_CREDIT'),
                       COUNT(*) FILTER (WHERE rejection.status='FINANCE_EXCEPTION'),
                       COUNT(*) FILTER (WHERE rejection.status='REVERSED')
                """ + from() + where);
        bind(query, params);
        Object[] row = (Object[]) query.getSingleResult();
        return new CaseCounts(
                number(row[0]), number(row[1]), number(row[2]), number(row[3]),
                number(row[4]), number(row[5]), number(row[6]));
    }

    @Transactional(readOnly = true)
    public CaseDetail detail(UUID id) {
        return new CaseDetail(
                item(requireSummary(id)),
                events(id),
                replacementAllocations(id));
    }

    @Transactional
    public CaseDetail recordReturn(UUID id, RecordReturnRequest request) {
        tx.bind();
        requireAction("procurement_iqc_rejection:record_return");
        @SuppressWarnings("unchecked")
        List<UUID> inspectionIds=em.createNativeQuery("""
                SELECT inspection_item_id
                FROM procurement_iqc_rejection_cases
                WHERE id=:id AND is_deleted=FALSE
                """).setParameter("id",id).getResultList();
        if(inspectionIds.size()!=1)throw new ApiException(
                ErrorCode.NOT_FOUND,"IQC不合格退回/贷项任务不存在");
        UUID inspectionItemId=inspectionIds.getFirst();
        @SuppressWarnings("unchecked")
        List<String> inspectionStatuses=em.createNativeQuery("""
                SELECT status FROM procurement_inspection_items
                WHERE id=:id FOR UPDATE
                """).setParameter("id",inspectionItemId).getResultList();
        if(inspectionStatuses.size()!=1)throw conflict("IQC权威质检行不存在");
        LockedCase row = lock(id);
        if(request==null)throw validation("实物退回请求不能为空");
        String requestHash=commandHash("RECORD_RETURN",request);
        if(commandReplay(request.commandId(),id,"RECORD_RETURN",requestHash)){
            return detail(id);
        }
        requireVersion(row, request.expectedVersion());
        if (!canViewAllCases()
                && !currentUser.requireId().equals(row.ownerUserId())) {
            throw new ApiException(ErrorCode.FORBIDDEN, "只能登记本人负责订单的IQC不合格退回");
        }
        if (!Set.of("PENDING_RETURN","FINANCE_EXCEPTION").contains(row.status())) {
            throw conflict("仅待退回任务可登记实物退回");
        }
        if(!"RESOLVED".equals(inspectionStatuses.getFirst())){
            throw conflict("IQC尚未整行结案，不能提前登记实物退回");
        }
        long pendingProjection=((Number)em.createNativeQuery("""
                SELECT COUNT(*) FROM business_outbox
                WHERE event_type='PROCUREMENT_IQC_REJECTION_DETECTED'
                  AND aggregate_id=:inspectionItemId AND status<>1
                """).setParameter("inspectionItemId",inspectionItemId)
                .getSingleResult()).longValue();
        if(pendingProjection!=0){
            throw conflict("IQC失败检测事件尚未完成财务投影，不能登记实物退回");
        }
        String returnReference = bounded(
                request.returnReference(), 200, "实物退回凭证编号");
        String returnNote = bounded(request.returnNote(), 2000, "实物退回说明");
        LocalDate openedDate=localDate(em.createNativeQuery("""
                SELECT (created_at AT TIME ZONE 'Asia/Shanghai')::date
                FROM procurement_iqc_rejection_cases WHERE id=:id
                """).setParameter("id",id).getSingleResult());
        validateReturnDate(openedDate,request.returnDate(),BusinessTime.today());
        String recordedStatus="FINANCE_EXCEPTION".equals(row.status())
                ?"FINANCE_EXCEPTION":"RETURN_RECORDED";
        int updated = em.createNativeQuery("""
                UPDATE procurement_iqc_rejection_cases
                SET status=:recordedStatus,
                    return_reference=:returnReference,
                    return_date=:returnDate,
                    return_note=:returnNote,
                    return_recorded_by=:actor,return_recorded_at=now(),
                    row_version=row_version+1,updated_by=:actor,updated_at=now()
                WHERE id=:id AND status=:previousStatus AND row_version=:version
                """).setParameter("recordedStatus",recordedStatus)
                .setParameter("previousStatus",row.status())
                .setParameter("returnReference", returnReference)
                .setParameter("returnDate", request.returnDate())
                .setParameter("returnNote", returnNote)
                .setParameter("actor", currentUser.requireId())
                .setParameter("id", id)
                .setParameter("version", row.version()).executeUpdate();
        if (updated != 1) throw concurrentChange();
        arrivalControl.refreshAfterReturn(
                row.receiptType(),List.of(orderItemId(id)));
        appendCommandEvent(
                id, "RETURN_RECORDED", request.commandId(),
                returnReference, request.returnDate(), returnNote);
        appendCommand(
                request.commandId(),id,"RECORD_RETURN",row.version(),
                requestHash,recordedStatus,row.version()+1);
        publish(EVENT_RETURNED, id, row.receiptType(), recordedStatus,
                row.version() + 1, "RETURN");
        return detail(id);
    }

    @Transactional
    public CaseDetail confirmCredit(UUID id, ConfirmCreditRequest request) {
        tx.bind();
        LockedCase row = lock(id);
        requireAction("procurement_iqc_rejection:confirm_credit");
        requireAction("procurement_iqc_rejection:amount:view");
        if(request==null)throw validation("供应商贷项确认请求不能为空");
        String requestHash=commandHash("CONFIRM_CREDIT",request);
        if(commandReplay(request.commandId(),id,"CONFIRM_CREDIT",requestHash)){
            return detail(id);
        }
        requireVersion(row, request.expectedVersion());
        if (!"RETURN_RECORDED".equals(row.status())) {
            throw conflict("必须先确认不合格实物已退回供应商，财务才能确认贷项");
        }
        String reason = bounded(request.reason(), 2000, "供应商贷项确认说明");
        String creditReference = bounded(
                request.creditReference(), 200, "供应商贷项/红字凭证编号");
        if (row.failedOriginal().signum() <= 0 || row.failedLocal().signum() <= 0) {
            throw conflict("零金额任务只能确认无需贷项，禁止生成零金额负应付");
        }
        LocalDate returnDate=localDate(em.createNativeQuery("""
                SELECT return_date FROM procurement_iqc_rejection_cases
                WHERE id=:id
                """).setParameter("id",id).getSingleResult());
        validateCreditDate(returnDate,request.creditDate(),BusinessTime.today());
        @SuppressWarnings("unchecked")
        List<Object[]> payableRows = em.createNativeQuery("""
                        SELECT amount_balance_original,amount_balance,
                               supplier_id,currency_id,exchange_rate,settlement_type_id
                        FROM ar_ap_ledger
                        WHERE id=:id AND direction='AP' AND status=1
                          AND COALESCE(is_deleted,FALSE)=FALSE
                        FOR UPDATE
                        """).setParameter("id", row.sourceApLedgerId()).getResultList();
        if(payableRows.size()!=1)throw conflict("来源正应付已缺失或红冲，禁止确认贷项");
        Object[] sourceAp=payableRows.getFirst();
        if(!java.util.Objects.equals(uuid(sourceAp[2]),row.supplierId())
                ||!java.util.Objects.equals(uuid(sourceAp[3]),row.currencyId())
                ||decimal(sourceAp[4]).compareTo(row.exchangeRate())!=0
                ||!java.util.Objects.equals(uuid(sourceAp[5]),row.settlementMethodId())){
            throw conflict("来源正应付身份与IQC冻结快照不一致");
        }
        BigDecimal positiveBalance=decimal(sourceAp[0]).max(BigDecimal.ZERO);

        UUID creditSourceId = id;
        String sourceType = creditSourceType(row.receiptType());
        LocalDate today = request.creditDate();
        String creditNo = "IQCC-" + creditSourceId;
        arApService.postArAp(new ArApLedgerService.ArApPostingRequest(
                "AP", sourceType, creditSourceId, creditNo, today,
                null, row.supplierId(), row.currencyId(), row.exchangeRate(),
                row.failedLocal().negate(), null, reason, row.failedOriginal().negate(),
                today, null, List.of(), row.settlementMethodId()));
        UUID creditLedgerId = postedLedgerId(creditSourceId, sourceType);
        BigDecimal offsetAmount=money(positiveBalance.min(row.failedOriginal()));
        UUID offsetId=null;
        if(offsetAmount.signum()>0){
            UUID offsetBatchId=UUID.randomUUID();
            offsetService.applyIqcCreditBatch(
                    id,offsetBatchId,creditLedgerId,row.supplierId(),row.currencyId(),
                    today,List.of(new SupplierOpenItemOffsetService.Target(
                            row.sourceApLedgerId(),offsetAmount)),reason);
            @SuppressWarnings("unchecked")
            List<UUID> offsetIds=em.createNativeQuery("""
                    SELECT id FROM supplier_open_item_offsets
                    WHERE offset_batch_id=:batchId AND status='APPLIED'
                    ORDER BY id FOR UPDATE
                    """).setParameter("batchId",offsetBatchId).getResultList();
            if(offsetIds.size()!=1){
                throw conflict("IQC专用贷项必须且只能形成一条来源应付抵销");
            }
            offsetId=offsetIds.getFirst();
        }
        int updated = em.createNativeQuery("""
                UPDATE procurement_iqc_rejection_cases
                SET status='CREDIT_CONFIRMED',
                    credit_source_id=:creditSourceId,credit_ledger_id=:creditLedgerId,
                    offset_id=:offsetId,credit_reference=:creditReference,
                    credit_date=:creditDate,credit_reason=:reason,
                    credit_confirmed_by=:actor,credit_confirmed_at=now(),
                    row_version=row_version+1,updated_by=:actor
                WHERE id=:id AND status='RETURN_RECORDED' AND row_version=:version
                """).setParameter("creditSourceId", creditSourceId)
                .setParameter("creditLedgerId", creditLedgerId)
                .setParameter("offsetId", offsetId)
                .setParameter("creditReference", creditReference)
                .setParameter("creditDate",today)
                .setParameter("reason", reason)
                .setParameter("actor", currentUser.requireId())
                .setParameter("id", id)
                .setParameter("version", row.version()).executeUpdate();
        if (updated != 1) throw concurrentChange();
        appendCommandEvent(
                id, "CREDIT_CONFIRMED", request.commandId(),
                creditReference, request.creditDate(), reason);
        appendCommand(
                request.commandId(),id,"CONFIRM_CREDIT",row.version(),
                requestHash,"CREDIT_CONFIRMED",row.version()+1);
        publish(EVENT_CREDIT_CONFIRMED, id, row.receiptType(), "CREDIT_CONFIRMED",
                row.version() + 1, creditSourceId.toString());
        return detail(id);
    }

    @Transactional
    public CaseDetail reverseCredit(UUID id, ReverseRequest request) {
        tx.bind();
        LockedCase row = lock(id);
        requireAction("procurement_iqc_rejection:reverse");
        requireAction("procurement_iqc_rejection:amount:view");
        if(request==null)throw validation("IQC贷项反向请求不能为空");
        String requestHash=commandHash("REVERSE",request);
        if(commandReplay(request.commandId(),id,"REVERSE",requestHash)){
            return detail(id);
        }
        requireVersion(row, request.expectedVersion());
        if (!"CREDIT_CONFIRMED".equals(row.status())
                || row.creditSourceId() == null || row.creditLedgerId()==null) {
            throw conflict("该任务没有可反向的供应商贷项");
        }
        requireNoActiveReplacementAllocation(id);
        String reason = bounded(request.reason(), 2000, "贷项反向原因");
        if(row.offsetId()!=null){
            UUID batchId=(UUID)em.createNativeQuery("""
                    SELECT offset_batch_id FROM supplier_open_item_offsets
                    WHERE id=:id AND status='APPLIED' FOR UPDATE
                    """).setParameter("id",row.offsetId()).getSingleResult();
            offsetService.reverseBatch(batchId, reason);
        }
        arApService.reverseArAp(row.creditSourceId(), creditSourceType(row.receiptType()));
        int updated = em.createNativeQuery("""
                UPDATE procurement_iqc_rejection_cases
                SET status='RETURN_RECORDED',row_version=row_version+1,
                    credit_source_id=NULL,credit_ledger_id=NULL,offset_id=NULL,
                    credit_reference=NULL,credit_date=NULL,credit_reason=NULL,
                    credit_confirmed_by=NULL,credit_confirmed_at=NULL,
                    updated_by=:actor
                WHERE id=:id AND status='CREDIT_CONFIRMED' AND row_version=:version
                """).setParameter("actor", currentUser.requireId())
                .setParameter("id", id)
                .setParameter("version", row.version()).executeUpdate();
        if (updated != 1) throw concurrentChange();
        appendCommandEvent(
                id, "CREDIT_REVERSED", request.commandId(),
                null, BusinessTime.today(), reason);
        appendCommand(
                request.commandId(),id,"REVERSE",row.version(),requestHash,
                "RETURN_RECORDED",row.version()+1);
        publish(EVENT_REVERSED, id, row.receiptType(), "RETURN_RECORDED",
                row.version() + 1, "CREDIT");
        return detail(id);
    }

    @Transactional
    public CaseDetail reverseReturn(UUID id, ReverseRequest request) {
        tx.bind();
        LockedCase row = lock(id);
        requireAction("procurement_iqc_rejection:reverse");
        if(request==null)throw validation("IQC实物退回反向请求不能为空");
        String requestHash=commandHash("REVERSE",request);
        if(commandReplay(request.commandId(),id,"REVERSE",requestHash)){
            return detail(id);
        }
        requireVersion(row, request.expectedVersion());
        if (!"RETURN_RECORDED".equals(row.status())) {
            throw conflict("仅未确认贷项的实物退回记录可以反向");
        }
        if(row.creditLedgerId()!=null)throw conflict("该实物退回已有供应商贷项，请先反向贷项");
        requireNoActiveReplacementAllocation(id);
        String reason = bounded(request.reason(), 2000, "实物退回反向原因");
        int updated = em.createNativeQuery("""
                UPDATE procurement_iqc_rejection_cases
                SET status='PENDING_RETURN',row_version=row_version+1,
                    return_reference=NULL,return_date=NULL,return_note=NULL,
                    return_recorded_by=NULL,return_recorded_at=NULL,
                    updated_by=:actor
                WHERE id=:id AND status='RETURN_RECORDED' AND row_version=:version
                """).setParameter("actor", currentUser.requireId())
                .setParameter("id", id)
                .setParameter("version", row.version()).executeUpdate();
        if (updated != 1) throw concurrentChange();
        arrivalControl.refreshAfterReturn(
                row.receiptType(),List.of(orderItemId(id)));
        appendCommandEvent(
                id, "RETURN_REVERSED", request.commandId(),
                null, BusinessTime.today(), reason);
        appendCommand(
                request.commandId(),id,"REVERSE",row.version(),requestHash,
                "PENDING_RETURN",row.version()+1);
        publish(EVENT_REVERSED, id, row.receiptType(), "PENDING_RETURN",
                row.version() + 1, "RETURN");
        return detail(id);
    }

    @Transactional
    public CaseDetail closeNoCredit(UUID id, CloseNoCreditRequest request) {
        tx.bind();
        LockedCase row = lock(id);
        requireAction("procurement_iqc_rejection:close_no_credit");
        if(request==null)throw validation("零金额无需贷项请求不能为空");
        String requestHash=commandHash("CLOSE_NO_CREDIT",request);
        if(commandReplay(request.commandId(),id,"CLOSE_NO_CREDIT",requestHash)){
            return detail(id);
        }
        requireVersion(row, request.expectedVersion());
        if (!"RETURN_RECORDED".equals(row.status())) {
            throw conflict("仅已登记实物退回且未确认贷项的任务可无贷项结案");
        }
        if (row.failedOriginal().signum() != 0 || row.failedLocal().signum() != 0) {
            throw conflict("失败金额非零，必须确认供应商贷项，不能按无贷项结案");
        }
        String reason = bounded(request.reason(), 2000, "无贷项结案原因");
        int updated = em.createNativeQuery("""
                UPDATE procurement_iqc_rejection_cases
                SET status='CLOSED_NO_CREDIT',
                    closed_no_credit_reason=:reason,
                    closed_no_credit_by=:actor,
                    closed_no_credit_at=now(),
                    row_version=row_version+1,
                    updated_by=:actor
                WHERE id=:id AND status='RETURN_RECORDED' AND row_version=:version
                """)
                .setParameter("reason", reason)
                .setParameter("actor", currentUser.requireId())
                .setParameter("id", id)
                .setParameter("version", row.version())
                .executeUpdate();
        if (updated != 1) throw concurrentChange();
        appendCommandEvent(
                id, "CLOSED_NO_CREDIT", request.commandId(),
                null, BusinessTime.today(), reason);
        appendCommand(
                request.commandId(),id,"CLOSE_NO_CREDIT",row.version(),
                requestHash,"CLOSED_NO_CREDIT",row.version()+1);
        publish(EVENT_NO_CREDIT, id, row.receiptType(), "CLOSED_NO_CREDIT",
                row.version() + 1, request.commandId().toString());
        return detail(id);
    }

    @Transactional
    public CaseDetail reverse(UUID id, ReverseRequest request) {
        tx.bind();
        LockedCase row = lock(id);
        requireAction("procurement_iqc_rejection:reverse");
        if(request==null)throw validation("IQC闭环反向请求不能为空");
        String requestHash=commandHash("REVERSE",request);
        if(commandReplay(request.commandId(),id,"REVERSE",requestHash)){
            return detail(id);
        }
        requireVersion(row, request.expectedVersion());
        if ("CREDIT_CONFIRMED".equals(row.status())) {
            return reverseCredit(id, request);
        }
        if ("RETURN_RECORDED".equals(row.status())) {
            return reverseReturn(id, request);
        }
        if("FINANCE_EXCEPTION".equals(row.status())){
            long hasReturn=((Number)em.createNativeQuery("""
                    SELECT COUNT(*) FROM procurement_iqc_rejection_cases
                    WHERE id=:id AND return_recorded_at IS NOT NULL
                    """).setParameter("id",id).getSingleResult()).longValue();
            if(hasReturn!=1)throw conflict("财务异常任务尚无可反向的实物退回事实");
            requireNoActiveReplacementAllocation(id);
            String reason=bounded(request.reason(),2000,"实物退回反向原因");
            int updated=em.createNativeQuery("""
                    UPDATE procurement_iqc_rejection_cases
                    SET return_reference=NULL,return_date=NULL,return_note=NULL,
                        return_recorded_by=NULL,return_recorded_at=NULL,
                        row_version=row_version+1,updated_by=:actor
                    WHERE id=:id AND status='FINANCE_EXCEPTION'
                      AND row_version=:version
                    """).setParameter("actor",currentUser.requireId())
                    .setParameter("id",id)
                    .setParameter("version",row.version()).executeUpdate();
            if(updated!=1)throw concurrentChange();
            arrivalControl.refreshAfterReturn(
                    row.receiptType(),List.of(orderItemId(id)));
            appendCommandEvent(id,"RETURN_REVERSED",request.commandId(),
                    null,BusinessTime.today(),reason);
            appendCommand(request.commandId(),id,"REVERSE",row.version(),
                    requestHash,"FINANCE_EXCEPTION",row.version()+1);
            publish(EVENT_REVERSED,id,row.receiptType(),"FINANCE_EXCEPTION",
                    row.version()+1,request.commandId().toString());
            return detail(id);
        }
        if (!"CLOSED_NO_CREDIT".equals(row.status())) {
            throw conflict("当前IQC不合格任务状态没有可反向的处置");
        }
        requireNoActiveReplacementAllocation(id);
        String reason = bounded(request.reason(), 2000, "IQC处置反向原因");
        int updated = em.createNativeQuery("""
                UPDATE procurement_iqc_rejection_cases
                SET status='RETURN_RECORDED',
                    closed_no_credit_reason=NULL,
                    closed_no_credit_by=NULL,
                    closed_no_credit_at=NULL,
                    row_version=row_version+1,
                    updated_by=:actor
                WHERE id=:id
                  AND status='CLOSED_NO_CREDIT'
                  AND row_version=:version
                """)
                .setParameter("actor", currentUser.requireId())
                .setParameter("id", id)
                .setParameter("version", row.version())
                .executeUpdate();
        if (updated != 1) throw concurrentChange();
        appendCommandEvent(
                id, "NO_CREDIT_REVERSED", request.commandId(),
                null, BusinessTime.today(), reason);
        appendCommand(
                request.commandId(),id,"REVERSE",row.version(),requestHash,
                "RETURN_RECORDED",row.version()+1);
        publish(EVENT_REVERSED, id, row.receiptType(), "RETURN_RECORDED",
                row.version() + 1, request.commandId().toString());
        return detail(id);
    }

    @Transactional
    public CaseDetail retryFinanceProjection(
            UUID id, RetryFinanceProjectionRequest request) {
        tx.bind();
        requireAction("procurement_iqc_rejection:confirm_credit");
        requireAction("procurement_iqc_rejection:amount:view");
        if(request==null)throw validation("财务投影重试请求不能为空");
        @SuppressWarnings("unchecked")
        List<Object[]> identities=em.createNativeQuery("""
                SELECT receipt_type,receipt_id,inspection_item_id
                FROM procurement_iqc_rejection_cases
                WHERE id=:id AND is_deleted=FALSE
                """).setParameter("id",id).getResultList();
        if(identities.size()!=1)throw new ApiException(
                ErrorCode.NOT_FOUND,"IQC不合格退回/贷项任务不存在");
        Object[] identity=identities.getFirst();
        Source source=lockSource(
                text(identity[0]),uuid(identity[1]),uuid(identity[2]));
        LockedCase row = lock(id);
        String requestHash=commandHash("RETRY_FINANCE_PROJECTION",request);
        if(commandReplay(request.commandId(),id,
                "RETRY_FINANCE_PROJECTION",requestHash)){
            return detail(id);
        }
        requireVersion(row, request.expectedVersion());
        if (!"FINANCE_EXCEPTION".equals(row.status())) {
            throw conflict("仅财务投影异常任务可重试");
        }
        String retryReason = bounded(request.reason(), 2000, "财务投影重试原因");
        Projection projection=projection(
                source,row.failedOriginal(),row.failedLocal());
        boolean physicalReturned=((Number)em.createNativeQuery("""
                SELECT COUNT(*) FROM procurement_iqc_rejection_cases
                WHERE id=:id AND return_recorded_at IS NOT NULL
                """).setParameter("id",id).getSingleResult()).longValue()==1;
        String nextStatus=projection.exceptionCode()==null
                ?(physicalReturned?"RETURN_RECORDED":"PENDING_RETURN")
                :"FINANCE_EXCEPTION";
        int restored = em.createNativeQuery("""
                UPDATE procurement_iqc_rejection_cases
                SET source_ap_ledger_id=:sourceApId,status=:status,
                    finance_exception_code=:exceptionCode,
                    finance_exception_message=:exceptionMessage,
                    finance_exception_at=:exceptionAt,
                    row_version=row_version+1,updated_by=:actor
                WHERE id=:id AND status='FINANCE_EXCEPTION' AND row_version=:version
                """)
                .setParameter("sourceApId",projection.sourceApLedgerId())
                .setParameter("status",nextStatus)
                .setParameter("exceptionCode",projection.exceptionCode())
                .setParameter("exceptionMessage",projection.exceptionMessage())
                .setParameter("exceptionAt",projection.exceptionCode()==null
                        ?null:java.time.OffsetDateTime.now())
                .setParameter("actor", currentUser.requireId())
                .setParameter("id", id)
                .setParameter("version", row.version())
                .executeUpdate();
        if (restored != 1) throw concurrentChange();
        appendCommandEvent(
                id, "FINANCE_PROJECTION_RETRIED", request.commandId(),
                projection.exceptionCode(), BusinessTime.today(), retryReason);
        appendCommand(
                request.commandId(),id,"RETRY_FINANCE_PROJECTION",row.version(),
                requestHash,nextStatus,row.version()+1);
        publish(projection.exceptionCode()==null?EVENT_OPENED:EVENT_FINANCE_EXCEPTION,
                id,row.receiptType(),nextStatus,row.version()+1,
                request.commandId().toString());
        return detail(id);
    }

    private Source lockSource(String receiptType, UUID receiptId, UUID inspectionItemId) {
        Tables table = tables(receiptType);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT inspection.receipt_item_id,inspection.received_base_qty,
                       inspection.failed_base_qty,inspection.status,
                       receipt_item.order_item_id,receipt_item.goods_id,receipt_item.color_id,
                       receipt_item.unit_id,receipt_item.unit_rate,receipt_item.qty,
                       receipt_item.amount_original,receipt_item.amount_local,
                       receipt_doc.bill_no,receipt_doc.total_original,receipt_doc.total_local,
                       receipt_doc.supplier_id,receipt_doc.currency_id,
                       receipt_doc.exchange_rate,receipt_doc.tax_rate,
                       receipt_doc.settlement_method_id,
                       order_doc.bill_no,owner_user.id
                FROM procurement_inspection_items inspection
                JOIN %s receipt_item ON receipt_item.id=inspection.receipt_item_id
                JOIN %s receipt_doc ON receipt_doc.id=receipt_item.receipt_id
                JOIN %s order_item ON order_item.id=receipt_item.order_item_id
                JOIN %s order_doc ON order_doc.id=order_item.order_id
                LEFT JOIN users owner_user
                  ON owner_user.employee_id=order_doc.maker_id
                 AND owner_user.status='active'
                 AND COALESCE(owner_user.is_deleted,FALSE)=FALSE
                WHERE inspection.id=:inspectionItemId
                  AND inspection.receipt_type=:receiptType
                  AND inspection.receipt_id=:receiptId
                  AND receipt_doc.status=1 AND order_doc.status=1
                  AND COALESCE(receipt_item.is_deleted,FALSE)=FALSE
                  AND COALESCE(receipt_doc.is_deleted,FALSE)=FALSE
                  AND COALESCE(order_item.is_deleted,FALSE)=FALSE
                  AND COALESCE(order_doc.is_deleted,FALSE)=FALSE
                FOR UPDATE OF inspection,receipt_item,receipt_doc,order_item,order_doc
                """.formatted(
                        table.receiptItemTable(), table.receiptTable(),
                        table.orderItemTable(), table.orderTable()))
                .setParameter("inspectionItemId", inspectionItemId)
                .setParameter("receiptType", receiptType)
                .setParameter("receiptId", receiptId)
                .getResultList();
        if (rows.size() != 1) {
            throw conflict("IQC失败来源收货或订货缺失/重复，等待来源事实修复");
        }
        Object[] row = rows.getFirst();
        @SuppressWarnings("unchecked")
        List<Object[]> ledgerRows = em.createNativeQuery("""
                        SELECT id,supplier_id,currency_id,exchange_rate,
                               settlement_type_id,amount_original,amount_original_local
                        FROM ar_ap_ledger
                        WHERE source_doc_type=:sourceDocType
                          AND source_doc_id=:receiptId
                          AND direction='AP' AND status=1
                          AND COALESCE(is_deleted,FALSE)=FALSE
                        ORDER BY id FOR UPDATE
                        """)
                .setParameter("sourceDocType", table.receiptSourceType())
                .setParameter("receiptId", receiptId)
                .getResultList();
        List<SourceAp> sourceAps = ledgerRows.stream().map(value -> new SourceAp(
                uuid(value[0]),uuid(value[1]),uuid(value[2]),decimal(value[3]),
                uuid(value[4]),decimal(value[5]),decimal(value[6]))).toList();
        return new Source(
                uuid(row[0]), decimal(row[1]), decimal(row[2]), text(row[3]),
                uuid(row[4]), uuid(row[5]), uuid(row[6]), uuid(row[7]), decimal(row[8]),
                decimal(row[9]), decimal(row[10]), decimal(row[11]), text(row[12]),
                decimal(row[13]),decimal(row[14]),uuid(row[15]),uuid(row[16]),
                decimal(row[17]),decimal(row[18]),uuid(row[19]),text(row[20]),
                uuid(row[21]),sourceAps);
    }

    private Projection projection(
            Source source,BigDecimal failedOriginal,BigDecimal failedLocal){
        if((failedOriginal.signum()==0)!=(failedLocal.signum()==0)){
            return Projection.exception(
                    "FAILED_AMOUNT_SHAPE",
                    "IQC失败原币/本币金额零值形态不一致，需修复权威收货金额");
        }
        boolean zeroReceipt=source.receiptTotalOriginal().signum()==0
                && source.receiptTotalLocal().signum()==0;
        if(source.sourceAps().isEmpty()){
            if(zeroReceipt){
                return new Projection("PENDING_RETURN",null,null,null);
            }
            return Projection.exception(
                    "SOURCE_AP_MISSING","来源收货的有效正应付缺失");
        }
        if(source.sourceAps().size()!=1){
            return Projection.exception(
                    "SOURCE_AP_DUPLICATED","来源收货存在重复有效正应付");
        }
        SourceAp ap=source.sourceAps().getFirst();
        if(!java.util.Objects.equals(ap.supplierId(),source.supplierId())
                ||!java.util.Objects.equals(ap.currencyId(),source.currencyId())
                ||ap.exchangeRate().compareTo(source.exchangeRate())!=0
                ||!java.util.Objects.equals(
                        ap.settlementMethodId(),source.settlementMethodId())
                ||ap.amountOriginal().compareTo(source.receiptTotalOriginal())!=0
                ||ap.amountLocal().compareTo(source.receiptTotalLocal())!=0){
            return Projection.exception(
                    "SOURCE_AP_MISMATCH",
                    "来源应付与收货供应商、币种、汇率、结算或总金额不一致");
        }
        return new Projection("PENDING_RETURN",ap.id(),null,null);
    }

    private FailedAmounts failedAmounts(
            UUID inspectionItemId,BigDecimal receivedBase,BigDecimal expectedFailedBase,
            BigDecimal receivedOriginal,BigDecimal receivedLocal){
        @SuppressWarnings("unchecked")
        List<Object[]> rows=em.createNativeQuery("""
                SELECT action,base_qty
                FROM procurement_inspection_events
                WHERE inspection_item_id=:inspectionItemId
                  AND action IN('PASS','FAIL')
                ORDER BY occurred_at,id
                """).setParameter("inspectionItemId",inspectionItemId).getResultList();
        if(rows.isEmpty())throw conflict("IQC失败缺少追加式处置事件，禁止猜测金额");
        BigDecimal resolvedBefore=BigDecimal.ZERO;
        BigDecimal failedBase=BigDecimal.ZERO;
        BigDecimal failedOriginal=BigDecimal.ZERO;
        BigDecimal failedLocal=BigDecimal.ZERO;
        for(Object[] row:rows){
            BigDecimal sliceBase=decimal(row[1]);
            BigDecimal next=resolvedBefore.add(sliceBase);
            if(next.compareTo(receivedBase)>0){
                throw conflict("IQC处置事件累计超过冻结收货基本量");
            }
            BigDecimal originalSlice=money(
                    receivedOriginal.multiply(next)
                            .divide(receivedBase,4,RoundingMode.HALF_UP)
                    .subtract(receivedOriginal.multiply(resolvedBefore)
                            .divide(receivedBase,4,RoundingMode.HALF_UP)));
            BigDecimal localSlice=money(
                    receivedLocal.multiply(next)
                            .divide(receivedBase,4,RoundingMode.HALF_UP)
                    .subtract(receivedLocal.multiply(resolvedBefore)
                            .divide(receivedBase,4,RoundingMode.HALF_UP)));
            if("FAIL".equals(text(row[0]))){
                failedBase=failedBase.add(sliceBase);
                failedOriginal=failedOriginal.add(originalSlice);
                failedLocal=failedLocal.add(localSlice);
            }
            resolvedBefore=next;
        }
        if(failedBase.compareTo(expectedFailedBase)!=0){
            throw conflict("IQC失败事件累计与权威质检失败量不一致");
        }
        return new FailedAmounts(money(failedOriginal),money(failedLocal));
    }

    private boolean alreadyHandled(UUID eventId) {
        long count = ((Number) em.createNativeQuery("""
                        SELECT COUNT(*) FROM procurement_iqc_rejection_events
                        WHERE source_inspection_event_id=:eventId
                        """).setParameter("eventId", eventId).getSingleResult()).longValue();
        return count != 0;
    }

    private void appendEvent(UUID caseId, String eventType, UUID sourceEventId, String reason) {
        appendEvent(
                caseId, eventType, sourceEventId,
                currentUser.requireId(), reason);
    }

    private void appendEvent(
            UUID caseId,
            String eventType,
            UUID sourceEventId,
            UUID actorUserId,
            String reason) {
        em.createNativeQuery("""
                INSERT INTO procurement_iqc_rejection_events(
                    id,case_id,event_type,source_inspection_event_id,
                    actor_user_id,reason)
                VALUES(:id,:caseId,:eventType,:sourceEventId,:actor,:reason)
                """).setParameter("id", UUID.randomUUID())
                .setParameter("caseId", caseId)
                .setParameter("eventType", eventType)
                .setParameter("sourceEventId", sourceEventId)
                .setParameter("actor", actorUserId)
                .setParameter("reason", reason)
                .executeUpdate();
    }

    private void appendCommandEvent(
            UUID caseId,
            String eventType,
            UUID commandId,
            String reference,
            LocalDate eventDate,
            String reason) {
        em.createNativeQuery("""
                INSERT INTO procurement_iqc_rejection_events(
                    id,case_id,event_type,actor_user_id,command_id,
                    reference,event_date,reason)
                VALUES(:id,:caseId,:eventType,:actor,:commandId,
                       :reference,:eventDate,:reason)
                """)
                .setParameter("id", UUID.randomUUID())
                .setParameter("caseId", caseId)
                .setParameter("eventType", eventType)
                .setParameter("actor", currentUser.requireId())
                .setParameter("commandId", commandId)
                .setParameter("reference", reference)
                .setParameter("eventDate", eventDate)
                .setParameter("reason", reason)
                .executeUpdate();
    }

    private String commandHash(String commandType,Object request){
        try{
            byte[] digest=MessageDigest.getInstance("SHA-256").digest(
                    (commandType+"|"+String.valueOf(request))
                            .getBytes(StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(digest);
        }catch(Exception error){
            throw new IllegalStateException("IQC命令摘要计算失败",error);
        }
    }

    private boolean commandReplay(
            UUID commandId,UUID caseId,String commandType,String requestHash){
        if(commandId==null)throw validation("命令UUID不能为空");
        @SuppressWarnings("unchecked")
        List<Object[]> rows=em.createNativeQuery("""
                SELECT case_id,command_type,request_hash
                FROM procurement_iqc_rejection_commands
                WHERE id=:id
                """).setParameter("id",commandId).getResultList();
        if(rows.isEmpty())return false;
        Object[] row=rows.getFirst();
        if(rows.size()!=1||!java.util.Objects.equals(uuid(row[0]),caseId)
                ||!java.util.Objects.equals(text(row[1]),commandType)
                ||!java.util.Objects.equals(text(row[2]),requestHash)){
            throw conflict("相同命令UUID已用于不同IQC任务或不同请求");
        }
        return true;
    }

    private void appendCommand(
            UUID commandId,UUID caseId,String commandType,long expectedVersion,
            String requestHash,String resultStatus,long resultVersion){
        em.createNativeQuery("""
                INSERT INTO procurement_iqc_rejection_commands(
                    id,case_id,command_type,expected_version,actor_user_id,
                    request_hash,result_status,result_version)
                VALUES(:id,:caseId,:commandType,:expectedVersion,:actor,
                       :requestHash,:resultStatus,:resultVersion)
                """).setParameter("id",commandId)
                .setParameter("caseId",caseId)
                .setParameter("commandType",commandType)
                .setParameter("expectedVersion",expectedVersion)
                .setParameter("actor",currentUser.requireId())
                .setParameter("requestHash",requestHash)
                .setParameter("resultStatus",resultStatus)
                .setParameter("resultVersion",resultVersion)
                .executeUpdate();
    }

    private List<CaseEventItem> events(UUID caseId) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT id,event_type,actor_user_id,command_id,
                               reference,event_date,reason,created_at
                        FROM procurement_iqc_rejection_events
                        WHERE case_id=:caseId
                        ORDER BY created_at,id
                        """)
                .setParameter("caseId", caseId)
                .getResultList();
        return rows.stream().map(row -> new CaseEventItem(
                uuid(row[0]), text(row[1]), uuid(row[2]), uuid(row[3]),
                text(row[4]), text(row[5]), text(row[6]), text(row[7])))
                .toList();
    }

    private List<ReplacementAllocationItem> replacementAllocations(UUID caseId) {
        boolean canSeeAmount=has("procurement_iqc_rejection:amount:view");
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT id,replacement_receipt_type,replacement_receipt_id,
                               replacement_receipt_item_id,allocated_base_qty,
                               allocated_qty,allocated_amount_original,allocated_amount_local,
                               status,created_at,reversed_at
                        FROM procurement_iqc_replacement_allocations
                        WHERE case_id=:caseId
                        ORDER BY created_at,id
                        """)
                .setParameter("caseId", caseId)
                .getResultList();
        return rows.stream().map(row -> new ReplacementAllocationItem(
                uuid(row[0]), text(row[1]), uuid(row[2]), uuid(row[3]),
                quantity(row[4]),quantity(row[5]),
                canSeeAmount?money(row[6]):null,
                canSeeAmount?money(row[7]):null,text(row[8]),
                text(row[9]), text(row[10])))
                .toList();
    }

    private void requireNoActiveReplacementAllocation(UUID caseId) {
        long count = ((Number) em.createNativeQuery("""
                        SELECT COUNT(*) FROM procurement_iqc_replacement_allocations
                        WHERE case_id=:caseId AND status='ACTIVE'
                        """).setParameter("caseId", caseId).getSingleResult()).longValue();
        if (count != 0) {
            throw conflict("该失败退回切片已被补货收货占用，请先红冲补货收货");
        }
    }

    private void publish(
            String eventType, UUID caseId, String receiptType,
            String status, long version, String discriminator) {
        events.publishOnce(eventType, "PROCUREMENT_IQC_REJECTION", caseId,
                Map.of("receiptType", receiptType, "status", status, "version", version),
                eventType + ":" + caseId + ":" + discriminator);
    }

    private Object[] requireSummary(UUID id) {
        String scope = canViewAllCases() ? "" : " AND rejection.owner_user_id=:currentUserId";
        Query query = em.createNativeQuery(
                select() + from() + " WHERE rejection.id=:id"
                        + " AND COALESCE(rejection.is_deleted,FALSE)=FALSE" + scope)
                .setParameter("id", id);
        if (!canViewAllCases()) {
            query.setParameter("currentUserId", currentUser.requireId());
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows = query.getResultList();
        if (rows.size() != 1) throw new ApiException(
                ErrorCode.NOT_FOUND, "IQC不合格退回/贷项任务不存在");
        return rows.getFirst();
    }

    private LockedCase lock(UUID id) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT id,receipt_type,inspection_item_id,status,row_version,
                               supplier_id,currency_id,exchange_rate,settlement_method_id,
                               failed_amount_original,failed_amount_local,source_ap_ledger_id,
                               credit_source_id,credit_ledger_id,offset_id,owner_user_id
                        FROM procurement_iqc_rejection_cases
                        WHERE id=:id AND COALESCE(is_deleted,FALSE)=FALSE
                        FOR UPDATE
                        """).setParameter("id", id).getResultList();
        if (rows.size() != 1) throw new ApiException(
                ErrorCode.NOT_FOUND, "IQC不合格退回/贷项任务不存在");
        Object[] row = rows.getFirst();
        return new LockedCase(uuid(row[0]), text(row[1]), uuid(row[2]), text(row[3]),
                ((Number) row[4]).longValue(), uuid(row[5]), uuid(row[6]), decimal(row[7]),
                uuid(row[8]), decimal(row[9]), decimal(row[10]), uuid(row[11]),
                uuid(row[12]),uuid(row[13]),uuid(row[14]),uuid(row[15]));
    }

    private UUID postedLedgerId(UUID sourceId, String sourceType) {
        @SuppressWarnings("unchecked")
        List<UUID> ids = em.createNativeQuery("""
                        SELECT id FROM ar_ap_ledger
                        WHERE source_doc_id=:sourceId AND source_doc_type=:sourceType
                          AND status=1 AND COALESCE(is_deleted,FALSE)=FALSE
                        FOR UPDATE
                        """).setParameter("sourceId", sourceId)
                .setParameter("sourceType", sourceType).getResultList();
        if (ids.size() != 1) throw conflict("IQC供应商贷项立账缺失或重复");
        return ids.getFirst();
    }

    private UUID orderItemId(UUID caseId){
        Object value=em.createNativeQuery("""
                SELECT order_item_id FROM procurement_iqc_rejection_cases
                WHERE id=:id AND is_deleted=FALSE
                """).setParameter("id",caseId).getSingleResult();
        return uuid(value);
    }

    private CaseItem item(Object[] row) {
        String receiptType = text(row[1]);
        String status = text(row[18]);
        boolean canSeePrice = has("procurement_iqc_rejection:amount:view");
        List<String> actions = new ArrayList<>();
        boolean ownCase = java.util.Objects.equals(
                currentUser.requireId(), uuid(row[20]));
        boolean inspectionResolved = "RESOLVED".equals(text(row[32]));
        if (("PENDING_RETURN".equals(status)
                ||("FINANCE_EXCEPTION".equals(status)&&row[24]==null))
                && has("procurement_iqc_rejection:record_return")
                && inspectionResolved
                && (ownCase || canViewAllCases())) {
            actions.add("RECORD_RETURN");
        }
        if ("RETURN_RECORDED".equals(status)
                && has("procurement_iqc_rejection:confirm_credit")
                && has("procurement_iqc_rejection:amount:view")
                && decimal(row[14]).signum()>0
                && decimal(row[15]).signum()>0
                && canViewAllCases()) {
            actions.add("CONFIRM_CREDIT");
        }
        if ("RETURN_RECORDED".equals(status)
                && has("procurement_iqc_rejection:close_no_credit")
                && canViewAllCases()
                && decimal(row[14]).signum() == 0
                && decimal(row[15]).signum() == 0) {
            actions.add("CLOSE_NO_CREDIT");
        }
        if (Set.of("RETURN_RECORDED", "CREDIT_CONFIRMED", "CLOSED_NO_CREDIT")
                .contains(status)
                && has("procurement_iqc_rejection:reverse") && canViewAllCases()
                && (!"CREDIT_CONFIRMED".equals(status)
                    || has("procurement_iqc_rejection:amount:view"))) {
            actions.add("REVERSE");
        }
        if ("FINANCE_EXCEPTION".equals(status)
                && has("procurement_iqc_rejection:confirm_credit")
                && has("procurement_iqc_rejection:amount:view")
                && canViewAllCases()) {
            actions.add("RETRY_FINANCE_PROJECTION");
        }
        if("FINANCE_EXCEPTION".equals(status)&&row[24]!=null
                &&has("procurement_iqc_rejection:reverse")&&canViewAllCases()){
            actions.add("REVERSE");
        }
        String holdReason = Set.of("PENDING_RETURN", "RETURN_RECORDED").contains(status)
                ? "IQC不合格实物退回及供应商贷项尚未闭环"
                : "FINANCE_EXCEPTION".equals(status) ? text(row[31]) : null;
        return new CaseItem(
                uuid(row[0]), receiptType, uuid(row[2]), uuid(row[3]), uuid(row[4]),
                text(row[5]), text(row[6]), uuid(row[7]), text(row[8]), text(row[9]),
                text(row[10]), quantity(row[11]), quantity(row[12]), text(row[13]),
                canSeePrice ? money(row[14]) : null,
                canSeePrice ? money(row[15]) : null,
                text(row[16]), status, ((Number) row[19]).longValue(), uuid(row[20]),
                text(row[21]), text(row[22]), text(row[23]), text(row[24]),
                text(row[25]), text(row[26]), text(row[27]),
                text(row[28]), text(row[29]), text(row[30]), text(row[31]),
                holdReason,
                List.copyOf(actions), !canSeePrice);
    }

    private boolean canConfirmCredit() {
        return has("procurement_iqc_rejection:confirm_credit");
    }

    private boolean canViewAllCases() {
        return has("procurement_iqc_rejection:view_all")
                || has("procurement_iqc_rejection:record_return")
                || has("procurement_iqc_rejection:confirm_credit")
                || has("procurement_iqc_rejection:close_no_credit")
                || has("procurement_iqc_rejection:reverse");
    }

    private void requireAction(String permission) {
        if (!has(permission)) {
            throw new ApiException(
                    ErrorCode.FORBIDDEN,"缺少IQC不合格闭环动作权限："+permission);
        }
    }

    private boolean has(String permission) {
        return currentUser.get().map(user -> user.isSuperAdmin()
                || user.getPermissions().contains(permission)).orElse(false);
    }

    private static String select() {
        return """
                SELECT rejection.id,rejection.receipt_type,rejection.receipt_id,
                       rejection.receipt_item_id,rejection.inspection_item_id,
                       rejection.receipt_bill_no,rejection.order_bill_no,
                       rejection.supplier_id,supplier.name,goods.code,goods.name,
                       rejection.failed_base_qty,rejection.failed_qty,unit.name,
                       rejection.failed_amount_original,rejection.failed_amount_local,
                       currency.code,rejection.exchange_rate,rejection.status,
                       rejection.row_version,rejection.owner_user_id,
                       rejection.return_reference,rejection.return_date,
                       rejection.return_note,rejection.return_recorded_at,
                       rejection.credit_reference,rejection.credit_date,
                       rejection.credit_confirmed_at,
                       rejection.closed_no_credit_reason,
                       rejection.closed_no_credit_at,
                       rejection.finance_exception_code,
                       rejection.finance_exception_message,
                       inspection.status
                """;
    }

    private static String from() {
        return """
                 FROM procurement_iqc_rejection_cases rejection
                 JOIN suppliers supplier ON supplier.id=rejection.supplier_id
                 JOIN goods goods ON goods.id=rejection.goods_id
                 JOIN procurement_inspection_items inspection
                   ON inspection.id=rejection.inspection_item_id
                 LEFT JOIN units unit ON unit.id=rejection.unit_id
                 LEFT JOIN currencies currency ON currency.id=rejection.currency_id
                """;
    }

    private static void add(
            StringBuilder where, Map<String, Object> params,
            String predicate, String name, Object value) {
        where.append(" AND ").append(predicate);
        params.put(name, value);
    }

    private static void bind(Query query, Map<String, Object> params) {
        params.forEach(query::setParameter);
    }

    private static void requireVersion(LockedCase row, long expected) {
        if (expected < 0 || row.version() != expected) throw concurrentChange();
    }

    private static String type(String value) {
        String normalized = upper(value);
        if (normalized == null || !TYPES.contains(normalized)) {
            throw validation("收货类型仅支持 PURCHASE/SUBCONTRACT");
        }
        return normalized;
    }

    private static String optionalType(String value) {
        return value == null || value.isBlank() ? null : type(value);
    }

    private static Tables tables(String type) {
        return "PURCHASE".equals(type)
                ? new Tables("purchase_receipt_items", "purchase_receipts",
                    "purchase_order_items", "purchase_orders", "PURCHASE_RECEIPT")
                : new Tables("subcontract_receipt_items", "subcontract_receipts",
                    "subcontract_order_items", "subcontract_orders", "SUBCONTRACT_RECEIPT");
    }

    private static String creditSourceType(String receiptType) {
        return "PURCHASE".equals(receiptType)
                ? "PURCHASE_IQC_CREDIT" : "SUBCONTRACT_IQC_CREDIT";
    }

    private static String upper(String value) {
        return value == null || value.isBlank() ? null : value.trim().toUpperCase(Locale.ROOT);
    }

    private static String bounded(String value, int max, String label) {
        if (value == null || value.isBlank()) throw validation(label + "不能为空");
        String trimmed = value.trim();
        if (trimmed.length() > max) throw validation(label + "不能超过" + max + "个字符");
        return trimmed;
    }

    private static UUID uuid(Object value) {
        return value instanceof UUID id ? id
                : value == null ? null : UUID.fromString(value.toString());
    }

    private static String text(Object value) {
        return value == null ? null : value.toString();
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO
                : value instanceof BigDecimal decimal ? decimal : new BigDecimal(value.toString());
    }

    private static long number(Object value) {
        return value == null ? 0 : ((Number) value).longValue();
    }

    private static LocalDate localDate(Object value) {
        if (value == null) return null;
        if (value instanceof LocalDate date) return date;
        if (value instanceof java.sql.Date date) return date.toLocalDate();
        return LocalDate.parse(value.toString());
    }

    static void validateReturnDate(
            LocalDate openedDate,LocalDate returnDate,LocalDate today){
        if(openedDate==null||returnDate==null||today==null
                ||returnDate.isBefore(openedDate)||returnDate.isAfter(today)){
            throw validation("实物退回日期必须介于IQC失败任务开案业务日和今天之间");
        }
    }

    static void validateCreditDate(
            LocalDate returnDate,LocalDate creditDate,LocalDate today){
        if(returnDate==null||creditDate==null||today==null
                ||creditDate.isBefore(returnDate)||creditDate.isAfter(today)){
            throw validation("供应商贷项日期必须介于实物退回日期和今天之间");
        }
    }

    private static Object[] one(Query query, String message) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = query.getResultList();
        if (rows.size() != 1) throw conflict(message);
        return rows.getFirst();
    }

    private static BigDecimal moneyValue(Object value) {
        return decimal(value).setScale(4, RoundingMode.HALF_UP);
    }

    private static String money(Object value) {
        return value == null ? null : moneyValue(value).toPlainString();
    }

    private static String quantity(Object value) {
        return value == null ? null
                : decimal(value).stripTrailingZeros().toPlainString();
    }

    private static BigDecimal money(BigDecimal value) {
        return value.setScale(4, RoundingMode.HALF_UP);
    }

    private static BigDecimal quantity(BigDecimal value) {
        return value.setScale(4, RoundingMode.HALF_UP);
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    private static ApiException concurrentChange() {
        return new ApiException(ErrorCode.CONFLICT, "任务版本已变化，请刷新后重试");
    }

    private record Tables(
            String receiptItemTable, String receiptTable,
            String orderItemTable, String orderTable, String receiptSourceType) {
    }

    private record SourceAp(
            UUID id,UUID supplierId,UUID currencyId,BigDecimal exchangeRate,
            UUID settlementMethodId,BigDecimal amountOriginal,BigDecimal amountLocal){}

    private record Source(
            UUID receiptItemId, BigDecimal receivedBase, BigDecimal failedBase,
            String inspectionStatus, UUID orderItemId, UUID goodsId, UUID colorId,
            UUID unitId, BigDecimal unitRate, BigDecimal receiptQty,
            BigDecimal receiptOriginal, BigDecimal receiptLocal, String receiptBillNo,
            BigDecimal receiptTotalOriginal,BigDecimal receiptTotalLocal,
            UUID supplierId, UUID currencyId, BigDecimal exchangeRate, BigDecimal taxRate,
            UUID settlementMethodId, String orderBillNo, UUID ownerUserId,
            List<SourceAp> sourceAps) {
    }

    private record Projection(
            String status,UUID sourceApLedgerId,
            String exceptionCode,String exceptionMessage){
        static Projection exception(String code,String message){
            return new Projection("FINANCE_EXCEPTION",null,code,message);
        }
    }

    private record FailedAmounts(BigDecimal original,BigDecimal local){}

    private record LockedCase(
            UUID id, String receiptType, UUID inspectionItemId, String status, long version,
            UUID supplierId, UUID currencyId, BigDecimal exchangeRate, UUID settlementMethodId,
            BigDecimal failedOriginal, BigDecimal failedLocal, UUID sourceApLedgerId,
            UUID creditSourceId,UUID creditLedgerId,UUID offsetId, UUID ownerUserId) {
    }
}
