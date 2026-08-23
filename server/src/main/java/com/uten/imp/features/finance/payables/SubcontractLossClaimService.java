package com.uten.imp.features.finance.payables;

import com.uten.imp.application.port.SubcontractLossClaimPort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.arap.ArApLedgerService;
import com.uten.imp.features.finance.gl.GlPostingService;
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
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.features.finance.payables.SubcontractLossClaimContracts.*;

/** Finance-owned responsibility and claim workflow for approved subcontract material loss. */
@Service
@RequiredArgsConstructor
public class SubcontractLossClaimService implements SubcontractLossClaimPort {
    public static final String AP_SOURCE_TYPE = "SUBCONTRACT_LOSS_OFFSET";
    private static final int MONEY_SCALE = 4;
    private static final int QTY_SCALE = 4;
    private static final Set<String> TYPES = Set.of(
            "COMPANY_BEAR", "SERVICE_PRICE_REDUCTION", "CASH_COMPENSATION",
            "AP_OFFSET", "MATERIAL_REPLACEMENT", "OUTPUT_REPLACEMENT",
            "SCRAP_RETURN", "WAIVER");
    private static final Set<String> MONEY_TYPES = Set.of(
            "SERVICE_PRICE_REDUCTION", "CASH_COMPENSATION", "AP_OFFSET");
    private static final Set<String> IMMEDIATE_TYPES = Set.of(
            "COMPANY_BEAR", "WAIVER", "AP_OFFSET");

    private final EntityManager em;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final ArApLedgerService arApService;
    private final SupplierOpenItemOffsetService offsetService;
    private final GlPostingService glPostingService;
    private final SupplierClosedPeriodGuard closedPeriodGuard;

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void validateApprovedWaste(ApprovedWaste waste) {
        if (waste == null || waste.wasteId() == null || waste.supplierId() == null
                || waste.wasteBillNo() == null || waste.wasteBillNo().isBlank()) {
            throw validation("委外损耗责任单缺少损耗单或委外商身份");
        }
        closedPeriodGuard.requireOpen(
                waste.supplierId(),baseCurrencyId(),waste.wasteDate(),"委外损耗审核");
        if (waste.lines().isEmpty()) {
            throw validation("委外损耗责任单缺少材料明细");
        }
        for (LossLine input : waste.lines()) {
            BigDecimal actual = positiveQty(input.actualLossQty(), "实际损耗量");
            BigDecimal allowedInput = nonNegative(input.allowedLossQty(), "合同允许损耗量");
            BigDecimal allowed = qty(allowedInput.min(actual));
            BigDecimal excess = qty(actual.subtract(allowed));
            SourceCost source = sourceCost(input.materialIssueItemId());
            requireValuedExcess(excess, source.unitBookValueLocal());
        }
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void openForApprovedWaste(ApprovedWaste waste) {
        tx.bind();
        if (waste == null || waste.wasteId() == null || waste.supplierId() == null
                || waste.wasteBillNo() == null || waste.wasteBillNo().isBlank()) {
            throw validation("委外损耗责任单缺少损耗单或委外商身份");
        }
        if (waste.lines().isEmpty()) {
            throw validation("委外损耗责任单缺少材料明细");
        }
        long existing = ((Number) em.createNativeQuery(
                        "SELECT COUNT(*) FROM subcontract_loss_cases WHERE waste_id=:wasteId")
                .setParameter("wasteId", waste.wasteId()).getSingleResult()).longValue();
        if (existing != 0) throw conflict("该损耗单已经生成财务责任单");

        UUID actor = currentUser.requireId();
        UUID currencyId = baseCurrencyId();
        closedPeriodGuard.requireOpen(
                waste.supplierId(), currencyId, waste.wasteDate(), "委外损耗责任开案");
        List<PreparedLine> prepared = new ArrayList<>();
        BigDecimal actualTotal = zero();
        BigDecimal allowedTotal = zero();
        BigDecimal excessTotal = zero();
        BigDecimal lossValueTotal = zero();
        for (LossLine input : waste.lines()) {
            BigDecimal actual = positiveQty(input.actualLossQty(), "实际损耗量");
            BigDecimal allowedInput = nonNegative(input.allowedLossQty(), "合同允许损耗量");
            BigDecimal allowed = qty(allowedInput.min(actual));
            BigDecimal excess = qty(actual.subtract(allowed));
            SourceCost source = sourceCost(input.materialIssueItemId());
            BigDecimal unitValue = source.unitBookValueLocal();
            requireValuedExcess(excess, unitValue);
            BigDecimal lossValue = money(excess.multiply(unitValue));
            prepared.add(new PreparedLine(input, source.orderItemId(), actual, allowed, excess,
                    unitValue, lossValue, unitValue.signum() > 0 ? "VALUED" : "MISSING_COST"));
            actualTotal = actualTotal.add(actual);
            allowedTotal = allowedTotal.add(allowed);
            excessTotal = excessTotal.add(excess);
            lossValueTotal = lossValueTotal.add(lossValue);
        }
        actualTotal = qty(actualTotal);
        allowedTotal = qty(allowedTotal);
        excessTotal = qty(excessTotal);
        lossValueTotal = money(lossValueTotal);
        boolean hasExcess=prepared.stream().anyMatch(line->line.excess().signum()>0);
        Set<UUID> unitIds=new HashSet<>();
        boolean allUnitsKnown=true;
        for(PreparedLine line:prepared){
            UUID unitId=line.input().unitId();
            if(unitId==null)allUnitsKnown=false;else unitIds.add(unitId);
        }
        boolean sameUnit=allUnitsKnown&&unitIds.size()==1;
        BigDecimal headerActual=sameUnit?actualTotal:null;
        BigDecimal headerAllowed=sameUnit?allowedTotal:null;
        BigDecimal headerExcess=sameUnit?excessTotal:null;
        UUID headerUnit=sameUnit?unitIds.iterator().next():null;
        BigDecimal suggested=hasExcess?money(nonNegativeOrZero(waste.suggestedClaimAmountLocal())):zero();
        String status=hasExcess?"OPEN":"RESOLVED";
        UUID caseId = UUID.randomUUID();
        em.createNativeQuery("""
                INSERT INTO subcontract_loss_cases(
                    id, waste_id, waste_bill_no, supplier_id, status,
                    actual_loss_qty, allowed_loss_qty, excess_loss_qty,
                    quantity_unit_id,quantity_summary_kind,
                    loss_book_value_local,claim_amount_local,suggested_claim_amount_local,currency_id,
                    resolved_by, resolved_at, created_by, updated_by)
                VALUES (
                    :id, :wasteId, :wasteBillNo, :supplierId, :status,
                    :actual,:allowed,:excess,:quantityUnit,:quantityKind,:lossValue,0,:suggested,:currencyId,
                    CASE WHEN :status='RESOLVED' THEN :actor ELSE NULL END,
                    CASE WHEN :status='RESOLVED' THEN now() ELSE NULL END,
                    :actor, :actor)
                """)
                .setParameter("id", caseId)
                .setParameter("wasteId", waste.wasteId())
                .setParameter("wasteBillNo", waste.wasteBillNo().trim())
                .setParameter("supplierId", waste.supplierId())
                .setParameter("status", status)
                .setParameter("actual",headerActual)
                .setParameter("allowed",headerAllowed)
                .setParameter("excess",headerExcess)
                .setParameter("quantityUnit",headerUnit)
                .setParameter("quantityKind",sameUnit?"SAME_UNIT":"MIXED_UNITS")
                .setParameter("lossValue", lossValueTotal)
                .setParameter("suggested",suggested)
                .setParameter("currencyId", currencyId)
                .setParameter("actor", actor)
                .executeUpdate();

        for (PreparedLine line : prepared) {
            LossLine input = line.input();
            em.createNativeQuery("""
                    INSERT INTO subcontract_loss_case_lines(
                        id, case_id, waste_item_id, material_issue_item_id, order_item_id,
                        goods_id, color_id, unit_id,
                        actual_loss_qty, allowed_loss_qty, excess_loss_qty,
                        unit_book_value_local, loss_book_value_local, valuation_status,
                        goods_code_snapshot, goods_name_snapshot, created_by, updated_by)
                    VALUES (
                        :id, :caseId, :wasteItemId, :issueItemId, :orderItemId,
                        :goodsId, :colorId, :unitId,
                        :actual, :allowed, :excess, :unitValue, :lossValue, :valuation,
                        :goodsCode, :goodsName, :actor, :actor)
                    """)
                    .setParameter("id", UUID.randomUUID())
                    .setParameter("caseId", caseId)
                    .setParameter("wasteItemId", input.wasteItemId())
                    .setParameter("issueItemId", input.materialIssueItemId())
                    .setParameter("orderItemId", line.orderItemId())
                    .setParameter("goodsId", input.goodsId())
                    .setParameter("colorId", input.colorId())
                    .setParameter("unitId", input.unitId())
                    .setParameter("actual", line.actual())
                    .setParameter("allowed", line.allowed())
                    .setParameter("excess", line.excess())
                    .setParameter("unitValue", line.unitValue())
                    .setParameter("lossValue", line.lossValue())
                    .setParameter("valuation", line.valuationStatus())
                    .setParameter("goodsCode", input.goodsCode())
                    .setParameter("goodsName", input.goodsName())
                    .setParameter("actor", actor)
                    .executeUpdate();
        }
        appendEvent(caseId,hasExcess?"OPENED":"WITHIN_TOLERANCE",
                hasExcess?"超过合同允许损耗，等待财务责任决定":"实际损耗未超过合同允许量");
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void beforeWasteReverse(UUID wasteId) {
        tx.bind();
        @SuppressWarnings("unchecked")
        List<UUID> wasteSuppliers=em.createNativeQuery("""
                SELECT supplier_id FROM subcontract_wastes
                WHERE id=:wasteId AND COALESCE(is_deleted,FALSE)=FALSE
                FOR SHARE
                """).setParameter("wasteId",wasteId).getResultList();
        if(wasteSuppliers.size()!=1)throw conflict("委外损耗单不存在或已删除，禁止红冲");
        closedPeriodGuard.requireOpen(
                wasteSuppliers.getFirst(),baseCurrencyId(),BusinessTime.today(),"委外损耗红冲");

        List<Object[]> rows = em.createNativeQuery("""
                SELECT id, status, row_version,
                       (SELECT COUNT(*) FROM subcontract_loss_resolutions r WHERE r.case_id=c.id)
                FROM subcontract_loss_cases c
                WHERE waste_id=:wasteId AND COALESCE(is_deleted,FALSE)=FALSE
                FOR UPDATE
                """).setParameter("wasteId", wasteId).getResultList();
        if (rows.isEmpty()) return; // pre-V330 historical waste
        Object[] row = rows.getFirst();
        UUID caseId = (UUID) row[0];
        String status = text(row[1]);
        long resolutions = ((Number) row[3]).longValue();
        if (Set.of("CANCELED", "REVERSED").contains(status)) return;
        if (("OPEN".equals(status) || "RESOLVED".equals(status)) && resolutions == 0) {
            em.createNativeQuery("""
                    UPDATE subcontract_loss_cases
                    SET status='CANCELED', row_version=row_version+1,
                        updated_by=:actor, updated_at=now()
                    WHERE id=:id
                    """).setParameter("actor", currentUser.requireId())
                    .setParameter("id", caseId).executeUpdate();
            appendEvent(caseId, "CANCELED_BY_WASTE_REVERSAL", "损耗实物事实准备红冲");
            return;
        }
        throw conflict("该损耗已形成财务责任/索赔处理，请先反转责任决定再红冲损耗单");
    }

    @Transactional(readOnly = true)
    public CasePage list(UUID supplierId, String status, String keyword, int page, int size) {
        int safePage = Math.max(1, page);
        int safeSize = Math.min(Math.max(1, size), 200);
        StringBuilder where = new StringBuilder(
                " WHERE COALESCE(loss.is_deleted,FALSE)=FALSE");
        Map<String, Object> params = new LinkedHashMap<>();
        if (supplierId != null) {
            where.append(" AND loss.supplier_id=:supplierId");
            params.put("supplierId", supplierId);
        }
        if (status != null && !status.isBlank()) {
            String normalized = status.trim().toUpperCase(Locale.ROOT);
            if (!Set.of("OPEN", "ACCEPTED", "DISPUTED", "AWAITING_FULFILLMENT",
                    "RESOLVED", "WAIVED", "CANCELED", "REVERSED").contains(normalized)) {
                throw validation("无效的委外超耗责任状态");
            }
            where.append(" AND loss.status=:status");
            params.put("status", normalized);
        }
        if (keyword != null && !keyword.isBlank()) {
            where.append(" AND (LOWER(loss.waste_bill_no) LIKE :keyword"
                    + " OR LOWER(COALESCE(supplier.code,'')) LIKE :keyword"
                    + " OR LOWER(COALESCE(supplier.name,'')) LIKE :keyword)");
            params.put("keyword", "%" + keyword.trim().toLowerCase(Locale.ROOT) + "%");
        }
        String from = " FROM subcontract_loss_cases loss"
                + " JOIN suppliers supplier ON supplier.id=loss.supplier_id";
        Query data = em.createNativeQuery(summarySelect() + from + where
                + " ORDER BY loss.created_at DESC, loss.id LIMIT :limit OFFSET :offset");
        bind(data, params);
        data.setParameter("limit", safeSize);
        data.setParameter("offset", (long) (safePage - 1) * safeSize);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = data.getResultList();
        Query count = em.createNativeQuery("SELECT COUNT(*)" + from + where);
        bind(count, params);
        long total = ((Number) count.getSingleResult()).longValue();
        return new CasePage(rows.stream().map(this::summary).toList(), safePage, safeSize,
                total, (int) ((total + safeSize - 1) / safeSize));
    }

    @Transactional(readOnly = true)
    public CaseDetail detail(UUID id) {
        CaseSummary summary = requireSummary(id);
        @SuppressWarnings("unchecked")
        List<Object[]> lineRows = em.createNativeQuery("""
                SELECT id, waste_item_id, material_issue_item_id, order_item_id,
                       goods_id, goods_code_snapshot, goods_name_snapshot, color_id, unit_id,
                       actual_loss_qty, allowed_loss_qty, excess_loss_qty,
                       unit_book_value_local, loss_book_value_local, valuation_status
                FROM subcontract_loss_case_lines WHERE case_id=:id ORDER BY id
                """).setParameter("id", id).getResultList();
        List<CaseLine> lines = lineRows.stream().map(row -> new CaseLine(
                uuid(row[0]), uuid(row[1]), uuid(row[2]), uuid(row[3]), uuid(row[4]),
                text(row[5]), text(row[6]), uuid(row[7]), uuid(row[8]),
                quantity(row[9]), quantity(row[10]), quantity(row[11]),
                money(row[12]), money(row[13]), text(row[14]))).toList();
        @SuppressWarnings("unchecked")
        List<Object[]> resolutionRows = em.createNativeQuery("""
                SELECT id, case_line_id, resolution_type, quantity, amount_local,
                       due_date, status, note, evidence_reference, fulfillment_doc_type,
                       fulfillment_doc_id, fulfillment_doc_no, offset_ledger_id, fulfilled_at
                FROM subcontract_loss_resolutions WHERE case_id=:id ORDER BY created_at,id
                """).setParameter("id", id).getResultList();
        List<Resolution> resolutions = resolutionRows.stream().map(row -> new Resolution(
                uuid(row[0]), uuid(row[1]), text(row[2]), quantity(row[3]), money(row[4]),
                date(row[5]), text(row[6]), text(row[7]), text(row[8]), text(row[9]),
                uuid(row[10]), text(row[11]), uuid(row[12]), text(row[13]))).toList();
        @SuppressWarnings("unchecked")
        List<Object[]> eventRows = em.createNativeQuery("""
                SELECT id,event_type,actor_user_id,reason,created_at
                FROM subcontract_loss_events WHERE case_id=:id ORDER BY created_at,id
                """).setParameter("id", id).getResultList();
        List<Event> events = eventRows.stream().map(row -> new Event(
                uuid(row[0]), text(row[1]), uuid(row[2]), text(row[3]), text(row[4]))).toList();
        return new CaseDetail(summary, lines, resolutions, events);
    }

    @Transactional
    public CaseDetail decide(UUID caseId, DecisionRequest request) {
        tx.bind();
        CasePeriodIdentity identity=casePeriodIdentity(caseId);
        closedPeriodGuard.requireOpen(
                identity.supplierId(),identity.currencyId(),BusinessTime.today(),"委外损耗责任决定");
        CaseRow loss = lockCase(caseId);
        requireCasePeriodIdentityUnchanged(loss,identity);
        requireVersion(loss, request == null ? -1 : request.expectedVersion());
        if (!Set.of("OPEN", "DISPUTED").contains(loss.status())) {
            throw conflict("仅待处理或争议中的责任单可作决定");
        }
        String reason = bounded(request.reason(), 2000, "责任决定说明");
        if (request.disputed()) {
            if (request.resolutions() != null && !request.resolutions().isEmpty()) {
                throw validation("标记争议时不能同时提交赔偿方案");
            }
            updateCaseDecision(loss, "DISPUTED", reason, BigDecimal.ZERO, false);
            em.createNativeQuery("UPDATE subcontract_loss_cases SET dispute_reason=:reason WHERE id=:id")
                    .setParameter("reason", reason).setParameter("id", caseId).executeUpdate();
            appendEvent(caseId, "DISPUTED", reason);
            return detail(caseId);
        }
        List<ResolutionInput> inputs = request.resolutions() == null ? List.of() : request.resolutions();
        if (inputs.isEmpty()) throw validation("非争议决定必须填写至少一种责任处理方案");
        Map<UUID, LineRow> lines = lockLines(caseId);
        validateResolutionCoverage(lines, inputs);
        UUID currencyId = loss.currencyId();
        BigDecimal claimTotal = BigDecimal.ZERO;
        boolean pending = false;
        int resolutionSequence=1;
        for (ResolutionInput input : inputs) {
            String type = normalizedType(input.type());
            BigDecimal quantity = nonNegative(input.quantity(), "处理数量");
            BigDecimal amount = nonNegative(input.amountLocal(), "处理金额");
            if (MONEY_TYPES.contains(type) && amount.signum() <= 0) {
                throw validation(type + " 的金额必须大于 0");
            }
            if (MONEY_TYPES.contains(type) && currencyId == null) {
                throw conflict("本币主档不唯一，不能生成货币索赔或抵销");
            }
            UUID resolutionId = UUID.randomUUID();
            boolean payableOffset = "AP_OFFSET".equals(type);
            boolean cashClaim="CASH_COMPENSATION".equals(type);
            boolean immediate = IMMEDIATE_TYPES.contains(type);
            List<OffsetTarget> offsetTargets = input.offsetTargets() == null
                    ? List.of() : input.offsetTargets();
            if (payableOffset) {
                BigDecimal allocated = offsetTargets.stream()
                        .map(OffsetTarget::amountOriginal)
                        .map(value -> nonNegative(value, "抵销原币金额"))
                        .reduce(BigDecimal.ZERO, BigDecimal::add);
                if (offsetTargets.isEmpty() || money(allocated).compareTo(money(amount)) != 0) {
                    throw validation("应付抵销必须逐笔选择目标应付，目标原币合计等于处理金额");
                }
            } else if (!offsetTargets.isEmpty()) {
                throw validation("只有应付抵销可以选择目标应付");
            }

            // Insert the accepted resolution before creating its AP/offset descendants;
            // V332 holds an FK to this exact business decision.
            String initialStatus = immediate && !payableOffset ? "FULFILLED" : "PENDING";
            em.createNativeQuery("""
                    INSERT INTO subcontract_loss_resolutions(
                        id,case_id,case_line_id,resolution_seq,resolution_type,quantity,amount_local,due_date,
                        status,note,fulfilled_by,fulfilled_at,created_by,updated_by)
                    VALUES (
                        :id,:caseId,:lineId,:sequence,:type,:quantity,:amount,:dueDate,
                        :status,:note,
                        CASE WHEN :status='FULFILLED' THEN :actor ELSE NULL END,
                        CASE WHEN :status='FULFILLED' THEN now() ELSE NULL END,
                        :actor,:actor)
                    """)
                    .setParameter("id", resolutionId)
                    .setParameter("caseId", caseId)
                    .setParameter("lineId", input.caseLineId())
                    .setParameter("sequence",resolutionSequence)
                    .setParameter("type", type)
                    .setParameter("quantity", qty(quantity))
                    .setParameter("amount", money(amount))
                    .setParameter("dueDate", input.dueDate())
                    .setParameter("status", initialStatus)
                    .setParameter("note", optionalBounded(input.note(), 2000, "方案说明"))
                    .setParameter("actor", currentUser.requireId())
                    .executeUpdate();

            if (payableOffset) {
                // 一次决定可包含多条抵销方案，凭证号按 resolution 唯一，避免 UNIQUE(voucher_no) 冲突
                arApService.postArAp(new ArApLedgerService.ArApPostingRequest(
                        "AP", AP_SOURCE_TYPE, resolutionId,
                        loss.wasteBillNo() + "-索赔抵销-" + resolutionId, BusinessTime.today(),
                        null, loss.supplierId(), currencyId, BigDecimal.ONE,
                        amount.negate(), null, reason, amount.negate()));
                UUID offsetLedgerId = postedLedgerId(resolutionId);
                offsetService.apply(resolutionId, offsetLedgerId, loss.supplierId(), currencyId,
                        BusinessTime.today(), offsetTargets.stream()
                                .map(target -> new SupplierOpenItemOffsetService.Target(
                                        target.payableId(), target.amountOriginal()))
                                .toList(), reason);
                em.createNativeQuery("""
                    UPDATE subcontract_loss_resolutions
                    SET status='FULFILLED',offset_ledger_id=:ledgerId,
                        fulfilled_by=:actor,fulfilled_at=now(),updated_by=:actor,updated_at=now()
                    WHERE id=:id AND status='PENDING'
                    """).setParameter("ledgerId",offsetLedgerId)
                        .setParameter("actor",currentUser.requireId())
                        .setParameter("id",resolutionId).executeUpdate();
            }else if(cashClaim){
                UUID claimId=createCashClaimReceivable(loss,resolutionId,amount,input.dueDate());
                em.createNativeQuery("""
                    UPDATE subcontract_loss_resolutions SET claim_receivable_id=:claimId,
                        updated_by=:actor,updated_at=now() WHERE id=:id AND status='PENDING'
                    """).setParameter("claimId",claimId).setParameter("actor",currentUser.requireId())
                        .setParameter("id",resolutionId).executeUpdate();
            }
            if (MONEY_TYPES.contains(type)) claimTotal = claimTotal.add(amount);
            pending |= !immediate;
            resolutionSequence++;
        }
        String status = pending ? "AWAITING_FULFILLMENT" : "RESOLVED";
        updateCaseDecision(loss, status, reason, money(claimTotal), !pending);
        appendEvent(caseId, "DECIDED", reason);
        return detail(caseId);
    }

    @Transactional
    public CaseDetail fulfill(UUID caseId, UUID resolutionId, FulfillmentRequest request) {
        tx.bind();
        CasePeriodIdentity identity=casePeriodIdentity(caseId);
        String guardedResolutionType=resolutionTypeIdentity(caseId,resolutionId);
        boolean cashCompensation="CASH_COMPENSATION".equals(guardedResolutionType);
        LocalDate fulfillmentDate=cashCompensation
                ?(request==null?null:request.cashReceiptDate()):BusinessTime.today();
        closedPeriodGuard.requireOpen(
                identity.supplierId(),identity.currencyId(),fulfillmentDate,"委外损耗补偿履约");
        CaseRow loss = lockCase(caseId);
        requireCasePeriodIdentityUnchanged(loss,identity);
        requireVersion(loss, request == null ? -1 : request.expectedCaseVersion());
        if (!"AWAITING_FULFILLMENT".equals(loss.status())) {
            throw conflict("仅待履约责任单可登记补偿结果");
        }
        ResolutionRow resolution = lockResolution(caseId, resolutionId);
        if(!Objects.equals(resolution.type(),guardedResolutionType)){
            throw conflict("委外损耗处理方案类型已变化，请刷新后重试");
        }
        if (!"PENDING".equals(resolution.status())) throw conflict("该处理方案已完成或已反转");
        if("SERVICE_PRICE_REDUCTION".equals(resolution.type())){
            throw conflict("加工费折让必须先取得红字发票或供应商贷项凭证，当前不能冒充财税完成");
        }
        if("OUTPUT_REPLACEMENT".equals(resolution.type())){
            throw conflict("补合格品/免费重作必须使用不重复耗用我方材料的专用补偿入库，普通委外进仓不可冒充");
        }
        BigDecimal fulfilledQty = nonNegative(request.fulfilledQuantity(), "履约数量");
        if (resolution.quantity().signum() > 0
                && qty(fulfilledQty).compareTo(resolution.quantity()) != 0) {
            throw validation("当前只允许整笔履约；履约数量必须等于方案数量");
        }
        String evidence = bounded(request.evidenceReference(), 1000, "履约证据");
        if(cashCompensation)fulfillCashCompensation(loss,resolution,request);
        else recordFulfillmentDocument(loss,resolution,request);
        em.createNativeQuery("""
                UPDATE subcontract_loss_resolutions
                SET status='FULFILLED', evidence_reference=:evidence,
                    fulfillment_doc_type=:docType, fulfillment_doc_id=:docId,
                    fulfillment_doc_no=:docNo, note=COALESCE(:note,note),
                    fulfilled_by=:actor, fulfilled_at=now(), updated_by=:actor, updated_at=now()
                WHERE id=:id AND status='PENDING'
                """)
                .setParameter("evidence", evidence)
                .setParameter("docType", request.fulfillmentDocType())
                .setParameter("docId", request.fulfillmentDocId())
                .setParameter("docNo", request.fulfillmentDocNo())
                .setParameter("note", optionalBounded(request.note(), 2000, "履约说明"))
                .setParameter("actor", currentUser.requireId())
                .setParameter("id", resolutionId)
                .executeUpdate();
        long pending = ((Number) em.createNativeQuery("""
                SELECT COUNT(*) FROM subcontract_loss_resolutions
                WHERE case_id=:id AND status='PENDING'
                """).setParameter("id", caseId).getSingleResult()).longValue();
        em.createNativeQuery("""
                UPDATE subcontract_loss_cases
                SET status=CASE WHEN :pending=0 THEN 'RESOLVED' ELSE status END,
                    row_version=row_version+1,
                    resolved_by=CASE WHEN :pending=0 THEN :actor ELSE resolved_by END,
                    resolved_at=CASE WHEN :pending=0 THEN now() ELSE resolved_at END,
                    updated_by=:actor,updated_at=now()
                WHERE id=:id
                """).setParameter("pending", pending)
                .setParameter("actor", currentUser.requireId())
                .setParameter("id", caseId).executeUpdate();
        appendEvent(caseId, "FULFILLED", evidence);
        return detail(caseId);
    }

    @Transactional
    public CaseDetail reverseFulfillment(UUID caseId,UUID resolutionId,
                                         ReverseFulfillmentRequest request){
        tx.bind();
        CasePeriodIdentity identity=casePeriodIdentity(caseId);
        closedPeriodGuard.requireOpen(
                identity.supplierId(),identity.currencyId(),BusinessTime.today(),"委外损耗履约反转");
        CaseRow loss=lockCase(caseId);
        requireCasePeriodIdentityUnchanged(loss,identity);
        requireVersion(loss,request==null?-1:request.expectedCaseVersion());
        String reason=bounded(request.reason(),2000,"履约反转原因");
        ResolutionRow resolution=lockResolution(caseId,resolutionId);
        if("CASH_COMPENSATION".equals(resolution.type())){
            return reverseCashCompensationFulfillment(loss,resolution,reason);
        }
        if(!"FULFILLED".equals(resolution.status())
                || IMMEDIATE_TYPES.contains(resolution.type())){
            throw conflict("仅已完成的补料、补货或废料返还可以反转履约");
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows=em.createNativeQuery("""
                SELECT id,case_line_id,document_type,document_id,document_item_id,
                       quantity,status,row_version
                FROM subcontract_loss_fulfillment_allocations
                WHERE resolution_id=:resolutionId FOR UPDATE
                """).setParameter("resolutionId",resolutionId).getResultList();
        if(rows.size()!=1)throw conflict("履约分配缺失或重复，禁止反转");
        Object[] row=rows.getFirst();
        UUID allocationId=uuid(row[0]);
        UUID caseLineId=uuid(row[1]);
        String documentType=text(row[2]);
        UUID documentId=uuid(row[3]);
        BigDecimal quantity=decimal(row[5]);
        if(!"APPLIED".equals(text(row[6])))throw conflict("履约已经反转");
        long allocationVersion=((Number)row[7]).longValue();
        if("SUPPLIER_MATERIAL_REPLACEMENT".equals(documentType)){
            @SuppressWarnings("unchecked")
            List<UUID> issueItems=em.createNativeQuery("""
                    SELECT material_issue_item_id FROM subcontract_loss_case_lines
                    WHERE id=:lineId AND case_id=:caseId FOR UPDATE
                    """).setParameter("lineId",caseLineId)
                    .setParameter("caseId",caseId).getResultList();
            if(issueItems.size()!=1||issueItems.getFirst()==null)throw conflict("补料来源发料行缺失");
            int restored=em.createNativeQuery("""
                    UPDATE subcontract_material_issue_items
                    SET compensated_qty=compensated_qty-:quantity,updated_at=now()
                    WHERE id=:id AND compensated_qty>=:quantity
                    """).setParameter("quantity",quantity)
                    .setParameter("id",issueItems.getFirst()).executeUpdate();
            if(restored!=1)throw conflict("补料已被后续消费或退回，必须先反转后续实物业务");
        }else{
            String table=switch(documentType){
                case "SUBCONTRACT_RECEIPT"->"subcontract_receipts";
                case "SUBCONTRACT_MATERIAL_RETURN"->"subcontract_material_returns";
                default->throw conflict("未知履约实物类型");
            };
            long reversed=((Number)em.createNativeQuery(
                    "SELECT COUNT(*) FROM "+table+" WHERE id=:id AND (status=-1 OR COALESCE(is_deleted,FALSE))")
                    .setParameter("id",documentId).getSingleResult()).longValue();
            if(reversed!=1)throw conflict("请先红冲对应补货或废料返还实物单据");
        }
        int updated=em.createNativeQuery("""
                UPDATE subcontract_loss_fulfillment_allocations
                SET status='REVERSED',row_version=row_version+1,reversed_by=:actor,
                    reversed_at=now(),reverse_reason=:reason
                WHERE id=:id AND row_version=:version AND status='APPLIED'
                """).setParameter("actor",currentUser.requireId())
                .setParameter("reason",reason).setParameter("id",allocationId)
                .setParameter("version",allocationVersion).executeUpdate();
        if(updated!=1)throw conflict("履约分配版本已变化，请刷新后重试");
        em.createNativeQuery("""
                UPDATE subcontract_loss_resolutions
                SET status='PENDING',fulfilled_by=NULL,fulfilled_at=NULL,updated_by=:actor,updated_at=now()
                WHERE id=:id AND status='FULFILLED'
                """).setParameter("actor",currentUser.requireId())
                .setParameter("id",resolutionId).executeUpdate();
        em.createNativeQuery("""
                UPDATE subcontract_loss_cases
                SET status='AWAITING_FULFILLMENT',row_version=row_version+1,
                    resolved_by=NULL,resolved_at=NULL,updated_by=:actor,updated_at=now()
                WHERE id=:id
                """).setParameter("actor",currentUser.requireId())
                .setParameter("id",caseId).executeUpdate();
        appendEvent(caseId,"FULFILLMENT_REVERSED",reason);
        return detail(caseId);
    }

    private CaseDetail reverseCashCompensationFulfillment(CaseRow loss,ResolutionRow resolution,
                                                          String reason){
        if(!"FULFILLED".equals(resolution.status())||resolution.claimReceivableId()==null){
            throw conflict("现金赔偿尚未到账或已反转");
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows=em.createNativeQuery("""
                SELECT receipt.id,receipt.account_id,receipt.amount_local,receipt.receipt_date,
                       receipt.reconciliation_id,receipt.row_version,receipt.status,
                       claim.row_version,claim.status
                FROM supplier_claim_cash_receipts receipt
                JOIN supplier_claim_receivables claim ON claim.id=receipt.claim_receivable_id
                WHERE receipt.resolution_id=:resolutionId FOR UPDATE OF receipt,claim
                """).setParameter("resolutionId",resolution.id()).getResultList();
        if(rows.size()!=1)throw conflict("现金赔偿到账事实缺失或重复");
        Object[] row=rows.getFirst();
        UUID receiptId=uuid(row[0]);UUID accountId=uuid(row[1]);
        BigDecimal amount=decimal(row[2]);LocalDate receiptDate=LocalDate.parse(row[3].toString());
        UUID reconciliationId=uuid(row[4]);long receiptVersion=((Number)row[5]).longValue();
        long claimVersion=((Number)row[7]).longValue();
        if(!"APPROVED".equals(text(row[6]))||!"SETTLED".equals(text(row[8]))){
            throw conflict("现金赔偿到账或索赔应收状态不允许反转");
        }
        glPostingService.lockAutoProjectionPeriod(receiptDate);
        glPostingService.removeSupplierClaimCashReceiptDoc(receiptId,"SPCR-"+resolution.id(),receiptDate);
        int accountUpdated=em.createNativeQuery("""
                UPDATE accounts SET balance_current=COALESCE(balance_current,0)-:amount,
                    receipts_total=COALESCE(receipts_total,0)-:amount,updated_at=now()
                WHERE id=:id
                """).setParameter("amount",amount).setParameter("id",accountId).executeUpdate();
        if(accountUpdated!=1)throw conflict("现金赔偿反转账户余额失败");
        int reconciliationUpdated=em.createNativeQuery("""
                UPDATE finance_reconciliations SET is_deleted=TRUE,deleted_at=now(),updated_at=now()
                WHERE id=:id AND COALESCE(is_deleted,FALSE)=FALSE
                """).setParameter("id",reconciliationId).executeUpdate();
        if(reconciliationUpdated!=1)throw conflict("现金赔偿资金流水已变化，禁止反转");
        int receiptUpdated=em.createNativeQuery("""
                UPDATE supplier_claim_cash_receipts
                SET status='REVERSED',row_version=row_version+1,reversed_by=:actor,
                    reversed_at=now(),reverse_reason=:reason,updated_by=:actor,updated_at=now()
                WHERE id=:id AND row_version=:version AND status='APPROVED'
                """).setParameter("actor",currentUser.requireId())
                .setParameter("reason",reason).setParameter("id",receiptId)
                .setParameter("version",receiptVersion).executeUpdate();
        if(receiptUpdated!=1)throw conflict("现金赔偿到账版本已变化，请刷新后重试");
        int claimUpdated=em.createNativeQuery("""
                UPDATE supplier_claim_receivables
                SET settled_original=0,settled_local=0,balance_original=amount_original,
                    balance_local=amount_local,status='OPEN',settled_date=NULL,
                    row_version=row_version+1,updated_by=:actor,updated_at=now()
                WHERE id=:id AND row_version=:version AND status='SETTLED'
                """).setParameter("actor",currentUser.requireId())
                .setParameter("id",resolution.claimReceivableId())
                .setParameter("version",claimVersion).executeUpdate();
        if(claimUpdated!=1)throw conflict("索赔应收版本已变化，请刷新后重试");
        em.createNativeQuery("""
                UPDATE subcontract_loss_resolutions
                SET status='PENDING',fulfilled_by=NULL,fulfilled_at=NULL,updated_by=:actor,updated_at=now()
                WHERE id=:id AND status='FULFILLED'
                """).setParameter("actor",currentUser.requireId())
                .setParameter("id",resolution.id()).executeUpdate();
        em.createNativeQuery("""
                UPDATE subcontract_loss_cases
                SET status='AWAITING_FULFILLMENT',row_version=row_version+1,
                    resolved_by=NULL,resolved_at=NULL,updated_by=:actor,updated_at=now()
                WHERE id=:id
                """).setParameter("actor",currentUser.requireId())
                .setParameter("id",loss.id()).executeUpdate();
        appendEvent(loss.id(),"CASH_FULFILLMENT_REVERSED",reason);
        return detail(loss.id());
    }

    @Transactional
    public CaseDetail reverse(UUID caseId, ReverseRequest request) {
        tx.bind();
        CasePeriodIdentity identity=casePeriodIdentity(caseId);
        closedPeriodGuard.requireOpen(
                identity.supplierId(),identity.currencyId(),BusinessTime.today(),"委外损耗责任反转");
        CaseRow loss = lockCase(caseId);
        requireCasePeriodIdentityUnchanged(loss,identity);
        requireVersion(loss, request == null ? -1 : request.expectedVersion());
        String reason = bounded(request.reason(), 2000, "反转原因");
        if (Set.of("OPEN", "CANCELED", "REVERSED").contains(loss.status())) {
            throw conflict("当前责任单没有可反转的财务决定");
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT id,resolution_type,status,offset_ledger_id,claim_receivable_id
                FROM subcontract_loss_resolutions
                WHERE case_id=:id ORDER BY resolution_seq DESC FOR UPDATE
                """).setParameter("id", caseId).getResultList();
        for (Object[] row : rows) {
            UUID resolutionId = (UUID) row[0];
            String type = text(row[1]);
            String status = text(row[2]);
            UUID offsetLedgerId = uuid(row[3]);
            UUID claimReceivableId=uuid(row[4]);
            if ("FULFILLED".equals(status) && !IMMEDIATE_TYPES.contains(type)) {
                throw conflict("补料、补货或废料返还已经履约，请先红冲对应实物单据");
            }
            if (offsetLedgerId != null) {
                offsetService.reverseForResolution(resolutionId, reason);
                long residual = ((Number) em.createNativeQuery("""
                        SELECT COUNT(*) FROM ar_ap_ledger
                        WHERE id=:id AND (amount_offset_original<>0 OR amount_offset_local<>0)
                        """).setParameter("id", offsetLedgerId).getSingleResult()).longValue();
                if (residual != 0) throw conflict("索赔贷项仍被其它业务使用，禁止反立账");
                arApService.reverseArAp(resolutionId, AP_SOURCE_TYPE);
            }
            if(claimReceivableId!=null){
                List<Object> claimDates=em.createNativeQuery("""
                        SELECT claim_date FROM supplier_claim_receivables
                        WHERE id=:id AND status='OPEN' FOR UPDATE
                        """).setParameter("id",claimReceivableId).getResultList();
                if(claimDates.size()!=1)
                    throw conflict("索赔应收不存在或已反转，请刷新后重试");
                LocalDate claimDate=LocalDate.parse(claimDates.getFirst().toString());
                glPostingService.removeSupplierClaimReceivableDoc(
                        claimReceivableId,"SPCL-"+resolutionId,claimDate);

                int claimReversed=em.createNativeQuery("""
                        UPDATE supplier_claim_receivables
                        SET status='REVERSED',row_version=row_version+1,reversed_by=:actor,
                            reversed_at=now(),reverse_reason=:reason,
                            is_deleted=TRUE,deleted_at=now(),updated_by=:actor,updated_at=now()
                        WHERE id=:id AND status='OPEN' AND settled_original=0 AND settled_local=0
                        """).setParameter("actor",currentUser.requireId())
                        .setParameter("reason",reason).setParameter("id",claimReceivableId)
                        .executeUpdate();
                if(claimReversed!=1)throw conflict("现金索赔已发生到账或后续业务，请先反转现金履约");
            }
            em.createNativeQuery("""
                    UPDATE subcontract_loss_resolutions
                    SET status='REVERSED', reversed_by=:actor, reversed_at=now(),
                        updated_by=:actor,updated_at=now()
                    WHERE id=:id
                    """).setParameter("actor", currentUser.requireId())
                    .setParameter("id", resolutionId).executeUpdate();
        }
        em.createNativeQuery("""
                UPDATE subcontract_loss_cases
                SET status='REVERSED',row_version=row_version+1,
                    updated_by=:actor,updated_at=now()
                WHERE id=:id
                """).setParameter("actor", currentUser.requireId())
                .setParameter("id", caseId).executeUpdate();
        appendEvent(caseId, "REVERSED", reason);
        return detail(caseId);
    }

    private void validateResolutionCoverage(Map<UUID, LineRow> lines, List<ResolutionInput> inputs) {
        Map<UUID, BigDecimal> allocated = new HashMap<>();
        for (ResolutionInput input : inputs) {
            if (input == null || input.caseLineId() == null || !lines.containsKey(input.caseLineId())) {
                throw validation("每种处理方案必须关联本责任单的一条超耗材料明细");
            }
            normalizedType(input.type());
            allocated.merge(input.caseLineId(), nonNegative(input.quantity(), "处理数量"), BigDecimal::add);
        }
        for (LineRow line : lines.values()) {
            BigDecimal expected = qty(line.excessQty());
            BigDecimal actual = qty(allocated.getOrDefault(line.id(), BigDecimal.ZERO));
            if (actual.compareTo(expected) != 0) {
                throw validation("每条材料的处理数量合计必须等于超耗量：" + line.goodsName());
            }
        }
    }

    private void fulfillCashCompensation(CaseRow loss,ResolutionRow resolution,
                                         FulfillmentRequest request){
        if(resolution.claimReceivableId()==null)throw conflict("现金赔偿缺少索赔应收来源");
        if(request.accountId()==null||request.cashReceiptDate()==null
                ||request.fulfilledAmountLocal()==null)throw validation("现金赔偿到账必须填写账户、到账日和金额");
        if(request.cashReceiptDate().isAfter(BusinessTime.today()))throw validation("现金赔偿到账日不能晚于今天");
        BigDecimal cashLocal=money(request.fulfilledAmountLocal());
        if(cashLocal.signum()<=0||cashLocal.compareTo(money(resolution.amountLocal()))!=0){
            throw validation("现金赔偿本次到账金额必须等于已确认赔偿金额");
        }
        @SuppressWarnings("unchecked")
        List<Object[]> claims=em.createNativeQuery("""
                SELECT supplier_id,currency_id,amount_original,exchange_rate,amount_local,
                       balance_original,balance_local,status,row_version
                FROM supplier_claim_receivables
                WHERE id=:id AND COALESCE(is_deleted,FALSE)=FALSE FOR UPDATE
                """).setParameter("id",resolution.claimReceivableId()).getResultList();
        if(claims.size()!=1)throw conflict("索赔应收不存在或已失效");
        Object[] claim=claims.getFirst();
        UUID supplierId=uuid(claim[0]);
        UUID currencyId=uuid(claim[1]);
        BigDecimal balanceOriginal=decimal(claim[5]);
        BigDecimal balanceLocal=decimal(claim[6]);
        long claimVersion=((Number)claim[8]).longValue();
        if(!Objects.equals(supplierId,loss.supplierId())||!"OPEN".equals(text(claim[7]))
                ||balanceLocal.compareTo(cashLocal)!=0||balanceOriginal.compareTo(cashLocal)!=0
                ||decimal(claim[3]).compareTo(BigDecimal.ONE)!=0){
            throw conflict("现金赔偿索赔应收余额、币种或供应商不一致");
        }
        @SuppressWarnings("unchecked")
        List<Object[]> accounts=em.createNativeQuery("""
                SELECT account.currency_id,account_style_id(account.id)
                FROM accounts account WHERE account.id=:id AND account.status='使用'
                  AND COALESCE(account.is_deleted,FALSE)=FALSE FOR UPDATE
                """).setParameter("id",request.accountId()).getResultList();
        if(accounts.size()!=1)throw conflict("赔偿到账账户不存在或已停用");
        UUID accountCurrency=uuid(accounts.getFirst()[0]);
        if(accountCurrency!=null&&!Objects.equals(accountCurrency,currencyId)){
            throw conflict("赔偿到账账户币种与索赔币种不一致");
        }
        if(accounts.getFirst()[1]==null)throw conflict("赔偿到账账户未绑定可用总账科目");
        glPostingService.lockAutoProjectionPeriod(request.cashReceiptDate());
        int accountUpdated=em.createNativeQuery("""
                UPDATE accounts SET balance_current=COALESCE(balance_current,0)+:amount,
                    receipts_total=COALESCE(receipts_total,0)+:amount,updated_at=now()
                WHERE id=:id
                """).setParameter("amount",cashLocal)
                .setParameter("id",request.accountId()).executeUpdate();
        if(accountUpdated!=1)throw conflict("赔偿到账账户余额更新失败");
        UUID reconciliationId=UUID.randomUUID();
        UUID cashReceiptId=UUID.randomUUID();
        String billNo="SPCR-"+resolution.id();
        java.time.OffsetDateTime businessDate=request.cashReceiptDate()
                .atStartOfDay(java.time.ZoneOffset.UTC).toOffsetDateTime();
        em.createNativeQuery("""
                INSERT INTO finance_reconciliations(
                    id,bill_no,source_doc_type,source_doc_id,account_id,counterpart_name,
                    in_amount,out_amount,bill_date,settled_date,source_remark,
                    created_at,updated_at,is_deleted)
                VALUES(:id,:billNo,'SUPPLIER_CLAIM_RECEIPT',:sourceId,:accountId,
                    (SELECT name FROM suppliers WHERE id=:supplierId),
                    :amount,0,:billDate,now(),:remark,now(),now(),FALSE)
                """).setParameter("id",reconciliationId).setParameter("billNo",billNo)
                .setParameter("sourceId",cashReceiptId).setParameter("accountId",request.accountId())
                .setParameter("supplierId",supplierId).setParameter("amount",cashLocal)
                .setParameter("billDate",businessDate)
                .setParameter("remark","供应商现金赔偿到账").executeUpdate();
        int claimUpdated=em.createNativeQuery("""
                UPDATE supplier_claim_receivables
                SET settled_original=amount_original,settled_local=amount_local,
                    balance_original=0,balance_local=0,status='SETTLED',settled_date=:date,
                    row_version=row_version+1,updated_by=:actor,updated_at=now()
                WHERE id=:id AND row_version=:version AND status='OPEN'
                """).setParameter("date",request.cashReceiptDate())
                .setParameter("actor",currentUser.requireId())
                .setParameter("id",resolution.claimReceivableId())
                .setParameter("version",claimVersion).executeUpdate();
        if(claimUpdated!=1)throw conflict("索赔应收版本已变化，请刷新后重试");
        em.createNativeQuery("""
                INSERT INTO supplier_claim_cash_receipts(
                    id,claim_receivable_id,resolution_id,case_id,supplier_id,account_id,
                    currency_id,bill_no,receipt_date,amount_original,exchange_rate,
                    amount_local,book_applied_local,exchange_difference,reconciliation_id,
                    status,created_by,updated_by)
                VALUES(:id,:claimId,:resolutionId,:caseId,:supplierId,:accountId,
                    :currencyId,:billNo,:date,:amount,1,:amount,:amount,0,:reconciliationId,
                    'APPROVED',:actor,:actor)
                """).setParameter("id",cashReceiptId)
                .setParameter("claimId",resolution.claimReceivableId())
                .setParameter("resolutionId",resolution.id()).setParameter("caseId",loss.id())
                .setParameter("supplierId",supplierId).setParameter("accountId",request.accountId())
                .setParameter("currencyId",currencyId).setParameter("billNo",billNo)
                .setParameter("date",request.cashReceiptDate()).setParameter("amount",cashLocal)
                .setParameter("reconciliationId",reconciliationId)
                .setParameter("actor",currentUser.requireId()).executeUpdate();
    }

    private void recordFulfillmentDocument(CaseRow loss, ResolutionRow resolution,
                                           FulfillmentRequest request) {
        String type = resolution.type();
        if (!Set.of("MATERIAL_REPLACEMENT", "OUTPUT_REPLACEMENT", "SCRAP_RETURN").contains(type)) {
            return;
        }
        BigDecimal quantity = resolution.quantity();
        String documentType;
        UUID documentId = request.fulfillmentDocId();
        UUID documentItemId = request.fulfillmentDocItemId();
        if ("MATERIAL_REPLACEMENT".equals(type)) {
            documentType = "SUPPLIER_MATERIAL_REPLACEMENT";
            if (request.fulfillmentDocType() != null
                    && !documentType.equals(request.fulfillmentDocType())) {
                throw validation("供应商补料不应冒充仓库收货或材料退回单");
            }
            @SuppressWarnings("unchecked")
            List<UUID> issueItems = em.createNativeQuery("""
                    SELECT material_issue_item_id FROM subcontract_loss_case_lines
                    WHERE id=:lineId AND case_id=:caseId FOR UPDATE
                    """).setParameter("lineId", resolution.caseLineId())
                    .setParameter("caseId", loss.id()).getResultList();
            if (issueItems.size()!=1 || issueItems.getFirst()==null) {
                throw conflict("超耗明细缺少原发料行，不能登记供应商补料");
            }
            int updated=em.createNativeQuery("""
                    UPDATE subcontract_material_issue_items
                    SET compensated_qty=compensated_qty+:quantity,updated_at=now()
                    WHERE id=:id AND COALESCE(is_deleted,FALSE)=FALSE
                    """).setParameter("quantity",quantity)
                    .setParameter("id",issueItems.getFirst()).executeUpdate();
            if(updated!=1)throw conflict("供应商补料回写失败");
            documentId=null;
            documentItemId=null;
        } else {
            if (documentId==null || documentItemId==null || request.fulfillmentDocType()==null) {
                throw validation("补货或废料返还必须关联已审核的实物单据头和明细 UUID");
            }
            documentType="OUTPUT_REPLACEMENT".equals(type)
                    ? "SUBCONTRACT_RECEIPT" : "SUBCONTRACT_MATERIAL_RETURN";
            if(!documentType.equals(request.fulfillmentDocType())) {
                throw validation("履约单据类型与补偿方案不匹配");
            }
            String sql;
            if("OUTPUT_REPLACEMENT".equals(type)) {
                sql="""
                    SELECT COUNT(*)
                    FROM subcontract_receipt_items item
                    JOIN subcontract_receipts document ON document.id=item.receipt_id
                    JOIN subcontract_loss_case_lines claim_line ON claim_line.id=:lineId
                    WHERE item.id=:itemId AND document.id=:documentId
                      AND document.supplier_id=:supplierId AND document.status=1
                      AND COALESCE(document.is_deleted,FALSE)=FALSE
                      AND COALESCE(item.is_deleted,FALSE)=FALSE
                      AND item.order_item_id=claim_line.order_item_id
                      AND item.qty>=:quantity
                      AND COALESCE(item.amount_local,0)=0
                    """;
            } else {
                sql="""
                    SELECT COUNT(*)
                    FROM subcontract_material_return_items item
                    JOIN subcontract_material_returns document
                      ON document.id=item.material_return_id
                    JOIN subcontract_loss_case_lines claim_line ON claim_line.id=:lineId
                    WHERE item.id=:itemId AND document.id=:documentId
                      AND document.supplier_id=:supplierId AND document.status=1
                      AND COALESCE(document.is_deleted,FALSE)=FALSE
                      AND COALESCE(item.is_deleted,FALSE)=FALSE
                      AND item.material_issue_item_id=claim_line.material_issue_item_id
                      AND item.goods_id=claim_line.goods_id
                      AND item.qty>=:quantity
                    """;
            }
            long count=((Number)em.createNativeQuery(sql)
                    .setParameter("lineId",resolution.caseLineId())
                    .setParameter("itemId",documentItemId)
                    .setParameter("documentId",documentId)
                    .setParameter("supplierId",loss.supplierId())
                    .setParameter("quantity",quantity).getSingleResult()).longValue();
            if(count!=1)throw conflict("履约明细与索赔订单、材料、数量或委外商不一致");
        }
        em.createNativeQuery("""
                INSERT INTO subcontract_loss_fulfillment_allocations(
                    id,resolution_id,case_line_id,document_type,document_id,
                    document_item_id,quantity,created_by)
                VALUES (:id,:resolutionId,:lineId,:type,:documentId,:itemId,:quantity,:actor)
                """).setParameter("id",UUID.randomUUID())
                .setParameter("resolutionId",resolution.id())
                .setParameter("lineId",resolution.caseLineId())
                .setParameter("type",documentType)
                .setParameter("documentId",documentId)
                .setParameter("itemId",documentItemId)
                .setParameter("quantity",quantity)
                .setParameter("actor",currentUser.requireId()).executeUpdate();
    }

    private SourceCost sourceCost(UUID materialIssueItemId) {
        if (materialIssueItemId == null) return new SourceCost(null, zero());
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT item.order_item_id,
                       CASE WHEN COALESCE(item.qty,0)>0 AND COALESCE(item.amount_local,0)>0
                            THEN item.amount_local/item.qty ELSE 0 END
                FROM subcontract_material_issue_items item
                JOIN subcontract_material_issues issue ON issue.id=item.issue_id
                WHERE item.id=:id AND issue.status=1
                  AND COALESCE(item.is_deleted,FALSE)=FALSE
                  AND COALESCE(issue.is_deleted,FALSE)=FALSE
                """).setParameter("id", materialIssueItemId).getResultList();
        if (rows.size() != 1) return new SourceCost(null, zero());
        return new SourceCost(uuid(rows.getFirst()[0]), money(decimal(rows.getFirst()[1])));
    }

    private UUID baseCurrencyId() {
        @SuppressWarnings("unchecked")
        List<UUID> rows = em.createNativeQuery("""
                SELECT id FROM currencies
                WHERE COALESCE(is_deleted,FALSE)=FALSE AND status='使用'
                  AND (UPPER(BTRIM(code)) IN ('CNY','RMB') OR BTRIM(name)='人民币')
                ORDER BY id
                """).getResultList();
        return rows.size() == 1 ? rows.getFirst() : null;
    }

    private UUID postedLedgerId(UUID resolutionId){
        @SuppressWarnings("unchecked")
        List<UUID> ids=em.createNativeQuery("""
                SELECT id FROM ar_ap_ledger
                WHERE source_doc_type=:type AND source_doc_id=:sourceId
                  AND status=1 AND COALESCE(is_deleted,FALSE)=FALSE
                FOR UPDATE
                """).setParameter("type",AP_SOURCE_TYPE)
                .setParameter("sourceId",resolutionId).getResultList();
        if(ids.size()!=1)throw conflict("索赔贷项立账结果缺失或重复");
        return ids.getFirst();
    }

    private UUID createCashClaimReceivable(CaseRow loss,UUID resolutionId,
                                           BigDecimal amount,LocalDate dueDate){
        UUID claimId=UUID.randomUUID();
        UUID actor=currentUser.requireId();
        em.createNativeQuery("""
                INSERT INTO supplier_claim_receivables(
                    id,resolution_id,case_id,supplier_id,currency_id,bill_no,claim_date,due_date,
                    amount_original,exchange_rate,amount_local,settled_original,settled_local,
                    balance_original,balance_local,status,created_by,updated_by)
                VALUES(:id,:resolutionId,:caseId,:supplierId,:currencyId,:billNo,CURRENT_DATE,:dueDate,
                    :amount,1,:amount,0,0,:amount,:amount,'OPEN',:actor,:actor)
                """).setParameter("id",claimId)
                .setParameter("resolutionId",resolutionId)
                .setParameter("caseId",loss.id())
                .setParameter("supplierId",loss.supplierId())
                .setParameter("currencyId",loss.currencyId())
                .setParameter("billNo","SPCL-"+resolutionId)
                .setParameter("dueDate",dueDate)
                .setParameter("amount",money(amount))
                .setParameter("actor",actor).executeUpdate();
        return claimId;
    }

    private CaseSummary requireSummary(UUID id) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery(summarySelect()
                        + " FROM subcontract_loss_cases loss"
                        + " JOIN suppliers supplier ON supplier.id=loss.supplier_id"
                        + " WHERE loss.id=:id AND COALESCE(loss.is_deleted,FALSE)=FALSE")
                .setParameter("id", id).getResultList();
        if (rows.size() != 1) throw new ApiException(ErrorCode.NOT_FOUND, "委外超耗责任单不存在");
        return summary(rows.getFirst());
    }

    private CasePeriodIdentity casePeriodIdentity(UUID caseId){
        @SuppressWarnings("unchecked")
        List<Object[]> rows=em.createNativeQuery("""
                SELECT supplier_id,currency_id
                FROM subcontract_loss_cases
                WHERE id=:id AND COALESCE(is_deleted,FALSE)=FALSE
                """).setParameter("id",caseId).getResultList();
        if(rows.size()!=1)throw new ApiException(
                ErrorCode.NOT_FOUND,"委外超耗责任单不存在");
        return new CasePeriodIdentity(uuid(rows.getFirst()[0]),uuid(rows.getFirst()[1]));
    }

    private String resolutionTypeIdentity(UUID caseId,UUID resolutionId){
        @SuppressWarnings("unchecked")
        List<String> rows=em.createNativeQuery("""
                SELECT resolution_type FROM subcontract_loss_resolutions
                WHERE id=:resolutionId AND case_id=:caseId
                """).setParameter("resolutionId",resolutionId)
                .setParameter("caseId",caseId).getResultList();
        if(rows.size()!=1)throw conflict("委外损耗处理方案不存在");
        return rows.getFirst();
    }

    private static void requireCasePeriodIdentityUnchanged(
            CaseRow loss,CasePeriodIdentity identity){
        if(!Objects.equals(loss.supplierId(),identity.supplierId())
                ||!Objects.equals(loss.currencyId(),identity.currencyId())){
            throw conflict("委外损耗责任单供应商或币种已变化，请刷新后重试");
        }
    }

    private CaseRow lockCase(UUID id) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT id,waste_id,waste_bill_no,supplier_id,status,
                       excess_loss_qty,currency_id,row_version
                FROM subcontract_loss_cases
                WHERE id=:id AND COALESCE(is_deleted,FALSE)=FALSE FOR UPDATE
                """).setParameter("id", id).getResultList();
        if (rows.size() != 1) throw new ApiException(ErrorCode.NOT_FOUND, "委外超耗责任单不存在");
        Object[] row = rows.getFirst();
        return new CaseRow((UUID) row[0], (UUID) row[1], text(row[2]), (UUID) row[3],
                text(row[4]), row[5]==null?null:decimal(row[5]), uuid(row[6]), ((Number) row[7]).longValue());
    }

    private Map<UUID, LineRow> lockLines(UUID caseId) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT id,excess_loss_qty,COALESCE(goods_name_snapshot,goods_code_snapshot,id::text)
                FROM subcontract_loss_case_lines WHERE case_id=:id ORDER BY id FOR UPDATE
                """).setParameter("id", caseId).getResultList();
        Map<UUID, LineRow> result = new LinkedHashMap<>();
        for (Object[] row : rows) {
            LineRow line = new LineRow((UUID) row[0], decimal(row[1]), text(row[2]));
            result.put(line.id(), line);
        }
        return result;
    }

    private ResolutionRow lockResolution(UUID caseId, UUID resolutionId) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT id,case_line_id,resolution_type,status,quantity,amount_local,claim_receivable_id
                FROM subcontract_loss_resolutions
                WHERE id=:id AND case_id=:caseId FOR UPDATE
                """).setParameter("id", resolutionId)
                .setParameter("caseId", caseId).getResultList();
        if (rows.size() != 1) throw new ApiException(ErrorCode.NOT_FOUND, "责任处理方案不存在");
        Object[] row = rows.getFirst();
        return new ResolutionRow((UUID) row[0],uuid(row[1]),text(row[2]),text(row[3]),
                decimal(row[4]),decimal(row[5]),uuid(row[6]));
    }

    private void updateCaseDecision(CaseRow loss, String status, String reason,
                                    BigDecimal claimAmount, boolean resolved) {
        int updated = em.createNativeQuery("""
                UPDATE subcontract_loss_cases
                SET status=:status, decision_reason=:reason, claim_amount_local=:claimAmount,
                    decided_by=:actor,decided_at=now(),
                    resolved_by=CASE WHEN :resolved THEN :actor ELSE NULL END,
                    resolved_at=CASE WHEN :resolved THEN now() ELSE NULL END,
                    row_version=row_version+1,updated_by=:actor,updated_at=now()
                WHERE id=:id AND row_version=:version
                """).setParameter("status", status)
                .setParameter("reason", reason)
                .setParameter("claimAmount", money(claimAmount))
                .setParameter("actor", currentUser.requireId())
                .setParameter("resolved", resolved)
                .setParameter("id", loss.id())
                .setParameter("version", loss.version())
                .executeUpdate();
        if (updated != 1) throw conflict("责任单版本已变化，请刷新后重试");
    }

    private void appendEvent(UUID caseId, String type, String reason) {
        em.createNativeQuery("""
                INSERT INTO subcontract_loss_events(id,case_id,event_type,actor_user_id,reason,payload)
                VALUES (:id,:caseId,:type,:actor,:reason,'{}'::jsonb)
                """).setParameter("id", UUID.randomUUID())
                .setParameter("caseId", caseId)
                .setParameter("type", type)
                .setParameter("actor", currentUser.requireId())
                .setParameter("reason", optionalBounded(reason, 2000, "事件说明"))
                .executeUpdate();
    }

    private static void requireVersion(CaseRow row, long expected) {
        if (expected < 0 || row.version() != expected) {
            throw conflict("责任单版本已变化，请刷新后重试");
        }
    }

    private static String summarySelect() {
        return """
                SELECT loss.id,loss.waste_id,loss.waste_bill_no,loss.supplier_id,
                       supplier.code,supplier.name,loss.status,
                       loss.actual_loss_qty,loss.allowed_loss_qty,loss.excess_loss_qty,
                       loss.loss_book_value_local,loss.claim_amount_local,
                       loss.row_version,loss.created_at
                """;
    }

    private CaseSummary summary(Object[] row) {
        return new CaseSummary(uuid(row[0]), uuid(row[1]), text(row[2]), uuid(row[3]),
                text(row[4]), text(row[5]), text(row[6]), quantity(row[7]), quantity(row[8]),
                quantity(row[9]), money(row[10]), money(row[11]),
                ((Number) row[12]).longValue(), text(row[13]));
    }

    private static void bind(Query query, Map<String, Object> params) {
        params.forEach(query::setParameter);
    }

    private static String normalizedType(String value) {
        String type = value == null ? "" : value.trim().toUpperCase(Locale.ROOT);
        if (!TYPES.contains(type)) throw validation("无效的委外超耗处理类型：" + value);
        return type;
    }

    static void requireValuedExcess(BigDecimal excess, BigDecimal unitBookValueLocal) {
        if (excess != null && excess.signum() > 0
                && (unitBookValueLocal == null || unitBookValueLocal.signum() <= 0)) {
            throw conflict("超耗材料缺少有效发料账面成本，禁止以 0 金额确认异常损失或索赔");
        }
    }

    private static BigDecimal positiveQty(BigDecimal value, String label) {
        if (value == null || value.signum() <= 0) throw validation(label + "必须大于 0");
        return qty(value);
    }

    private static BigDecimal nonNegative(BigDecimal value, String label) {
        if (value == null) return zero();
        if (value.signum() < 0) throw validation(label + "不能为负");
        return value;
    }

    private static BigDecimal nonNegativeOrZero(BigDecimal value) {
        return value == null || value.signum() < 0 ? zero() : value;
    }

    private static BigDecimal qty(BigDecimal value) {
        return value.setScale(QTY_SCALE, RoundingMode.HALF_UP);
    }

    private static BigDecimal money(BigDecimal value) {
        return value.setScale(MONEY_SCALE, RoundingMode.HALF_UP);
    }

    private static BigDecimal zero() {
        return BigDecimal.ZERO.setScale(MONEY_SCALE);
    }

    private static BigDecimal decimal(Object value) {
        if (value instanceof BigDecimal decimal) return decimal;
        return new BigDecimal(value.toString());
    }

    private static String quantity(Object value) {
        return value == null ? null : qty(decimal(value)).toPlainString();
    }

    private static String money(Object value) {
        return value == null ? null : money(decimal(value)).toPlainString();
    }

    private static UUID uuid(Object value) {
        return value instanceof UUID uuid ? uuid : value == null ? null : UUID.fromString(value.toString());
    }

    private static String text(Object value) {
        return value == null ? null : value.toString();
    }

    private static String date(Object value) {
        return value == null ? null : value.toString();
    }

    private static String bounded(String value, int max, String label) {
        if (value == null || value.isBlank()) throw validation(label + "不能为空");
        return optionalBounded(value, max, label);
    }

    private static String optionalBounded(String value, int max, String label) {
        if (value == null) return null;
        String trimmed = value.trim();
        if (trimmed.length() > max) throw validation(label + "不能超过 " + max + " 个字符");
        return trimmed.isEmpty() ? null : trimmed;
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    private record SourceCost(UUID orderItemId, BigDecimal unitBookValueLocal) {}
    private record PreparedLine(LossLine input, UUID orderItemId, BigDecimal actual,
                                BigDecimal allowed, BigDecimal excess, BigDecimal unitValue,
                                BigDecimal lossValue, String valuationStatus) {}
    private record CasePeriodIdentity(UUID supplierId,UUID currencyId) {}
    private record CaseRow(UUID id, UUID wasteId, String wasteBillNo, UUID supplierId,
                           String status, BigDecimal excessQty, UUID currencyId, long version) {}
    private record LineRow(UUID id, BigDecimal excessQty, String goodsName) {}
    private record ResolutionRow(UUID id,UUID caseLineId,String type,String status,
                                 BigDecimal quantity,BigDecimal amountLocal,UUID claimReceivableId) {}
}
