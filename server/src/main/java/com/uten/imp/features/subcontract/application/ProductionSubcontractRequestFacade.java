package com.uten.imp.features.subcontract.application;

import com.uten.imp.application.port.ProductionSubcontractRequestPort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.subcontract.SubcontractGoodsSnapshot;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/** Subcontract-owned adapter for production-generated application drafts. */
@Service
@RequiredArgsConstructor
public class ProductionSubcontractRequestFacade
        implements ProductionSubcontractRequestPort {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    private final SubcontractApplicationRepository applicationRepo;
    private final SubcontractApplicationItemRepository itemRepo;
    private final DocNumberService docNumberService;
    private final EntityManager em;

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public DraftResult createProductionDraft(
            String productionPlanNo,
            java.time.LocalDate needDate,
            UUID warehouseId,
            List<DraftLine> requestedLines,
            UUID applicantEmployeeId,
            UUID makerEmployeeId) {
        List<DraftLine> lines = requestedLines == null
                ? List.of()
                : requestedLines.stream()
                .filter(Objects::nonNull)
                .sorted(Comparator
                        .comparing(DraftLine::goodsId)
                        .thenComparing(line ->
                                Objects.toString(line.colorId(), ""))
                        .thenComparing(DraftLine::demandId))
                .toList();
        if (lines.isEmpty()) {
            return null;
        }
        lines.forEach(ProductionSubcontractRequestFacade::validate);

        SubcontractApplication application =
                new SubcontractApplication();
        application.setBillNo(
                docNumberService.nextNumber(
                        DocNumberPrefix.SUB_APPLICATION));
        application.setBillDate(BusinessTime.today());
        application.setWarehouseId(warehouseId);
        application.setSupplierId(null);
        application.setApplicantId(applicantEmployeeId);
        application.setMakerId(makerEmployeeId);
        application.setNeedDate(needDate);
        application.setSourceDocNo(productionPlanNo);
        application.setRemark(
                "生产计划 " + productionPlanNo
                        + " 委外来源物料缺口自动生成；供应商待委外部门确认");
        application.setTotalOriginal(BigDecimal.ZERO);
        application.setTotalLocal(BigDecimal.ZERO);
        application.setStatus(STATUS_APPROVED);
        applicationRepo.save(application);

        OffsetDateTime snapshotLockedAt = OffsetDateTime.now();
        Map<UUID, SubcontractGoodsSnapshot> goodsSnapshots =
                SubcontractGoodsSnapshot.fromMaster(
                        em,
                        lines.stream().map(DraftLine::goodsId).toList(),
                        SubcontractGoodsSnapshot.MASTER_AT_APPROVAL);

        List<DraftLineResult> created = new ArrayList<>();
        int lineNo = 0;
        for (DraftLine line : lines) {
            SubcontractApplicationItem item =
                    new SubcontractApplicationItem();
            item.setApplicationId(application.getId());
            item.setBillNo(application.getBillNo());
            item.setBillDate(application.getBillDate());
            item.setLineNo(++lineNo);
            item.setGoodsId(line.goodsId());
            SubcontractGoodsSnapshot goodsSnapshot = SubcontractGoodsSnapshot.require(
                    goodsSnapshots, line.goodsId(), "生产计划委外申请明细");
            item.setGoodsCodeSnapshot(goodsSnapshot.code());
            item.setGoodsNameSnapshot(goodsSnapshot.name());
            item.setGoodsSnapshotSource(goodsSnapshot.source());
            item.setGoodsSnapshotLockedAt(snapshotLockedAt);
            item.setColorId(line.colorId());
            item.setUnitId(line.unitId());
            item.setUnitRate(BigDecimal.ONE);
            item.setQty(line.qty());
            item.setPrice(BigDecimal.ZERO);
            item.setAmountOriginal(BigDecimal.ZERO);
            item.setAmountLocal(BigDecimal.ZERO);
            item.setOrderedQty(BigDecimal.ZERO);
            item.setSourceDocNo(productionPlanNo);
            item.setRemark(line.remark());
            itemRepo.save(item);
            created.add(new DraftLineResult(
                    line.demandId(),
                    item.getId(),
                    line.needDate() == null ? needDate : line.needDate(),
                    line.qty()));
        }
        itemRepo.flush();
        applicationRepo.flush();
        return new DraftResult(
                application.getId(),
                application.getBillNo(),
                List.copyOf(created));
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void closeGeneratedDraft(
            UUID applicationId, LifecycleAction action) {
        SubcontractApplication application = em.find(
                SubcontractApplication.class,
                applicationId,
                LockModeType.PESSIMISTIC_WRITE);
        if (application == null || application.isDeleted()) {
            if (action == LifecycleAction.CANCEL) {
                return;
            }
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "计划包关联的委外申请不存在");
        }
        List<Object[]> items = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT id, COALESCE(ordered_qty, 0)
                                FROM subcontract_application_items
                                WHERE application_id = :applicationId
                                  AND is_deleted = FALSE
                                ORDER BY id
                                FOR UPDATE
                                """)
                        .setParameter(
                                "applicationId", applicationId));
        if (items.stream().anyMatch(
                row -> decimal(row[1]).signum() > 0)) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "计划包委外申请已转委外订单，必须先反向处理下游单据");
        }
        if (action == LifecycleAction.CANCEL) {
            if (application.getStatus() != STATUS_DRAFT
                    && application.getStatus() != STATUS_APPROVED) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "仅无下游订货的计划委外申请可随计划包取消");
            }
            application.setDeleted(true);
            application.setDeletedAt(OffsetDateTime.now());
        } else {
            if (application.getStatus() != STATUS_DRAFT
                    && application.getStatus() != STATUS_APPROVED
                    && application.getStatus() != STATUS_REVERSED) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "委外申请状态不允许红冲");
            }
            application.setStatus(STATUS_REVERSED);
            application.setClosed(true);
        }
        applicationRepo.save(application);
    }

    private static void validate(DraftLine line) {
        if (line.demandId() == null
                || line.goodsId() == null
                || line.unitId() == null
                || line.qty() == null
                || line.qty().signum() <= 0) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "委外需求行缺少必填维度或数量无效");
        }
    }

    private static BigDecimal decimal(Object value) {
        return value == null
                ? BigDecimal.ZERO
                : new BigDecimal(value.toString());
    }
}
