package com.uten.imp.features.production.analysis;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.ProductionSubcontractRequestPort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.validation.RequestLimits;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.fulfillment.PlanningPackageFingerprint;
import com.uten.imp.features.production.mrp.ExecutionSegmentPreview;
import com.uten.imp.features.production.mrp.GeneratePlanningPackageRequest;
import com.uten.imp.features.production.mrp.MrpGenerateResult;
import com.uten.imp.features.production.mrp.PlanningPackageResult;
import com.uten.imp.features.production.mrp.PlanningPreviewResult;
import com.uten.imp.features.production.mrp.ProductionPlanningDraftService;
import com.uten.imp.features.production.mrp.ProductionPlanningDraftView;
import com.uten.imp.features.production.mrp.ProductionPlanningPackageService;
import com.uten.imp.features.production.plan.ProductionPlan;
import com.uten.imp.features.production.plan.ProductionPlanService;
import com.uten.imp.features.production.plan.ProductionPlanItem;
import com.uten.imp.features.production.plan.dto.PlanDetail;
import com.uten.imp.features.production.plan.dto.PlanItemLine;
import com.uten.imp.features.production.plan.dto.PlanSaveRequest;
import com.uten.imp.features.purchase.request.ProductionPurchaseRequestFacade;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;

/** Atomic write side for downstream pre-plan actions and formal plan creation. */
@Service
@RequiredArgsConstructor
public class MaterialAnalysisCommandService {

    private static final String OP_NOTIFY = "NOTIFY";
    private static final String OP_GENERATE = "GENERATE_PLAN";
    private static final String OP_CANCEL_ANALYSIS = "CANCEL_ANALYSIS";
    private static final String OP_CANCEL_ACTION = "CANCEL_ACTION";
    private static final String OP_CLAIM_SHARED_FUTURE = "CLAIM_SHARED_FUTURE";

    private final EntityManager em;
    private final MaterialAnalysisService analysisService;
    private final ChainNoticeService chainNotice;
    private final ProductionDocumentAccessPolicy access;
    private final ProductionPurchaseRequestFacade purchaseRequests;
    private final ProductionSubcontractRequestPort subcontractRequests;
    private final ProductionPlanService planService;
    private final ProductionPlanningPackageService planningPackages;
    private final ProductionPlanningDraftService planningDrafts;
    private final com.uten.imp.features.production.mrp.ProductionExecutionPackageCommandService
            executionPackages;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final ObjectMapper objectMapper;
    private final PreplanAnalysisStockPegService analysisPeg;
    private final PreplanStockEntitlementService stockEntitlement;
    private final SubcontractPreparationEntitlementHandoffService
            subcontractPreparationHandoffs;
    private final SubcontractMakeTaskService subcontractMakeTasks;
    private final com.uten.imp.application.concurrency.FulfillmentMutationLocks mutationLocks;
    private final com.uten.imp.application.port.ProductionMutationFootprintPort mutationFootprints;
    @org.springframework.beans.factory.annotation.Autowired
    private MaterialAnalysisRootSupplyService rootSupply;

    /**
     * 下达备料任务（采购/委外/自制）：先重算分配（库存与到货变化不触动分析头），再按操作组只补建「超过既有未结任务量」的增量，
     * 生成代际与外部单据；幂等键命中时重放既有结果。
     */
    @Transactional
    public AnalysisView notifySupply(UUID analysisId, NotifyRequest request) {
        return notifySupplyInternal(analysisId, request, false, null);
    }

    private AnalysisView notifySupplyInternal(
            UUID analysisId, NotifyRequest request, boolean allocationCurrent,
            Map<UUID, BigDecimal> arrangeQtyByMaterialLine) {
        tx.bind();
        // ADR-099：外部路线下达时会先自动认领同主仓公共在途，认领引用的是别的分析的
        // 申请/委外申请，必须与本分析一起预锁(与 claimSharedFuture 同一份足迹)，否则
        // 认领后的刷新会撞「回调来源超出预锁集合」。
        var mutationGuard = "MAKE".equals(request.target())
                ? lockAnalysisInventoryDimensions(analysisId)
                : lockAnalysisWithClaimableShared(analysisId);
        MaterialAnalysisService.AnalysisHeader header = analysisService.headerAfterPrelock(analysisId);
        requireNotFqcRecoveryWorkspace(analysisId);
        requireWritable(header, "只能下达本人负责的物料分析备料任务");
        String requestHash = notifyHash(analysisId, request);
        CommandReplay replay = commandReplay(analysisId, OP_NOTIFY,
                request.idempotencyKey(), requestHash);
        if (replay != null) {
            return analysisService.detailInternal(analysisId, false);
        }
        mutationGuard.verifyUnchanged();
        analysisService.requireCurrent(header, request.version(), request.fingerprint());
        // Stock, receipts and downstream document lifecycle can change without touching the
        // analysis header. Rebuild the authoritative allocation before calculating a delta.
        if (!allocationCurrent) analysisService.refreshLocked(analysisId);
        AnalysisView view = analysisService.detailInternal(analysisId, false);
        List<ActionGroup> groups = selectedGroups(view, request);
        for (ActionGroup group : groups) {
            // 2026-09-05 简化（ADR-71 后续）：自制路线退役单独「创建子件任务」——
            // 车间桶「创建生产计划」单次原子完成（锚点行+计划+可选审核）。
            if ("MAKE".equals(group.route())) {
                throw validation("自制路线请直接「创建生产计划」下达车间，不再单独创建子件任务");
            }
        }
        // 现货交接：根供给行上已有可分配现货时，这一次下达就是「把它交接过去」，
        // 不建任何 supply action——这是一条正当的零 action 成功路径，下面那道
        // 「一条都没建就回 409」的闸必须放它过去。
        boolean rootStockHandled = rootSupply != null
                && rootSupply.fulfillExisting(analysisId,
                groups.stream().flatMap(group -> group.materials().stream())
                        .filter(material -> "ROOT_SUPPLY".equals(material.nodeRole()))
                        .map(MaterialView::materialLineId).toList(),
                request.idempotencyKey());
        if (rootStockHandled) {
            analysisService.refreshLocked(analysisId);
            view = analysisService.detailInternal(analysisId, false);
            groups = selectedGroups(view, request);
        }
        requireNoActiveBorrowForSupplyMaterials(
                analysisId,
                groups.stream().flatMap(group -> group.materials().stream())
                        .map(MaterialView::materialLineId)
                        .collect(Collectors.toSet()));
        Map<String, SupplyQuantityInput> quantityInputs =
                quantityInputs(view, request, groups);
        List<UUID> subcontractGoodsIds = groups.stream()
                .filter(group -> "SUBCONTRACT".equals(group.route()))
                .map(group -> group.dimension().goodsId()).toList();
        Set<UUID> subcontractBomParents = activeBomParentIds(subcontractGoodsIds);
        // V581：有子层里再分一刀——「只有一个直属子件」的委外件直接发那个子件出去，
        // 不建前置自制任务，因此它和无子层叶子走同一条「出委外申请」通道。
        Set<UUID> subcontractSoleComponents =
                soleComponentSubcontractGoodsIds(subcontractGoodsIds);
        Set<UUID> subcontractMakeFirst = subcontractBomParents.stream()
                .filter(goodsId -> !subcontractSoleComponents.contains(goodsId))
                .collect(Collectors.toSet());
        var coverage = supplyCoverage(analysisId, groups);
        Map<UUID, ProductView> productsById = view.products().stream()
                .collect(Collectors.toMap(ProductView::analysisLineId, product -> product));
        List<ActionPlan> plans = new ArrayList<>();
        // ADR-099：下达采购/直接外发委外时先自动认领同主仓公共在途（按期优先、
        // 晚到其次），只为余下部分新下单；认领动作与新单一起记进本次命令。
        List<UUID> claimActionIds = new ArrayList<>();
        List<Map<String, String>> acceptedLateSources = new ArrayList<>();
        for (ActionGroup group : groups) {
            BigDecimal existingOpen = activeOpenActionQty(coverage, group);
            // V466 补货单通道收口：因 IQC 不合格取消的行动，其原订货单在实物退回
            // 登记后重新欠货（未收 + 已退 + 已退回不合格），这部分在途仍是有效覆盖，
            // 必须从可下达余量里扣除——否则原订单等补货 + 重新通知新单 = 双重补货。
            BigDecimal replacementInFlight = cancelledIqcReplacementInFlight(coverage, group);
            BigDecimal delta = group.demandRequiredQty()
                    .subtract(existingOpen)
                    .subtract(replacementInFlight)
                    .max(BigDecimal.ZERO)
                    .setScale(4, RoundingMode.CEILING);
            SupplyQuantityInput input = quantityInputs.get(group.groupKey());
            BigDecimal demandQty = delta;
            BigDecimal publicExtraQty = BigDecimal.ZERO.setScale(4);
            // 「本次必须整量接管」只对真正会创建下层责任的行成立：自制，以及
            // 需要先自制目标件的委外件。V581 的单一子件委外只是一张普通委外
            // 订货，可分批下达。
            boolean createsChildOwnership = "MAKE".equals(group.route())
                    || ("SUBCONTRACT".equals(group.route())
                        && subcontractMakeFirst.contains(group.dimension().goodsId()));
            // 我方供料的带 BOM 委外件(含 V581 单一子件件)原本被两条禁令同时罩着：
            // 既不许自己公共超量备货, 也不许自动认领别人的公共在途。2026-09-21/22 两条
            // 分别由两路改动放开, 本合并把它们并在一起 —— 它们本来就是相反的两件事:
            //
            // - 超量备货(V641/ADR-099 修订): 多下的量此前会凭空多出一份无人负责的子件需求,
            //   所以禁着。现在层级表上填多少子层就按多少算, 下达时在同一张「父件 + 下层
            //   一起下单」页里一并办掉, 无人负责的情形不再存在, 于是放开。
            // - 自动认领(ADR-101): 认领吃的是别人已经下好、料也由别人备的那一批成品, 本计划
            //   这一层不会因此多出任何子件需求 —— 认领行落的是 SHARED_FUTURE_CLAIM, 按
            //   EXTERNAL 归类, 正好把下层展开基准同步净掉。不放开的话同一颗件别人已经在路上,
            //   本计划仍要再下一单, 正是用户说的「需要的也要减去公共的、包括公共在途的」。
            //
            // 两条都放开之后这里不再需要 ownSupplyBom 这个判据, 故不再计算它;
            // subcontractBomParents 仍被 subcontractMakeFirst 用来识别「需先自制的委外件」。
            if (input != null) {
                BigDecimal requested = input.qty().setScale(4, RoundingMode.CEILING);
                if (createsChildOwnership) {
                    if (requested.compareTo(delta) != 0) {
                        throw validation("「" + groupLabel(group)
                                + "」子件任务当前必须按全部剩余需求 "
                                + delta.stripTrailingZeros().toPlainString()
                                + " 创建；本批生产数量请在子件任务创建后的计划向导中填写");
                    }
                } else {
                    // ADR-099 数量单一口径：填多少下多少——不超过「还需安排」的部分归本
                    // 需求，超出的部分记公共备货（需超量下达权限）。客户端不再拆成
                    // 「需求量 + 公共量」两个数，服务端按权威余量自行分账。
                    demandQty = requested.min(delta);
                    publicExtraQty = requested.subtract(demandQty).max(BigDecimal.ZERO)
                            .setScale(4, RoundingMode.CEILING);
                    if (publicExtraQty.signum() > 0
                            && !access.hasAuthority(
                                    "production_material_analysis:over_supply")) {
                        throw new ApiException(ErrorCode.FORBIDDEN,
                                "「" + groupLabel(group) + "」本次最多还能按需求下达 "
                                + delta.stripTrailingZeros().toPlainString()
                                + "，超出部分属主动公共备货，需要独立的超量下达权限");
                    }
                    // 2026-09-21 用户口径「采购能超量下, 委外和车间也要能」：我方供料的
                    // 委外件(含 V581 单一子件件)从此同样可以超量。原先这里与数据库
                    // preplan_public_surplus_subcontract_leaf_guard 一起拒绝, 理由是
                    // 「多下的量会凭空多出一份无人负责的子件需求」——那条理由已经不
                    // 成立：多下的量现在按计划产出量如实带大子件需求(ADR-099 修订,
                    // 层级表上填多少, 子层就按多少算), 下达时在同一张「父件 + 下层
                    // 一起下单」页里一并办掉, 没人负责的情形不再存在。V641 同步放开
                    // 数据库侧的形状守卫与运行时超订容量。
                }
            } else if (arrangeQtyByMaterialLine != null) {
                // Existing preparation commitment can still have unscheduled output.
                // A second workshop batch consumes that quota before adding public output;
                // the supply delta alone is zero once the original action owns the demand.
                BigDecimal arrangeQty = group.materials().stream()
                        .map(material -> arrangeQtyByMaterialLine.get(
                                material.materialLineId()))
                        .filter(Objects::nonNull)
                        .reduce(BigDecimal.ZERO, BigDecimal::max);
                if (arrangeQty.signum() > 0 && createsChildOwnership) {
                    BigDecimal unplannedCommitment = group.materials().stream()
                            .map(MaterialView::planAnchorAnalysisLineId)
                            .filter(Objects::nonNull).distinct()
                            .map(productsById::get).filter(Objects::nonNull)
                            .map(ProductView::remainingQty)
                            .reduce(BigDecimal.ZERO, BigDecimal::add);
                    publicExtraQty = arrangeQty.subtract(unplannedCommitment).subtract(delta)
                            .max(BigDecimal.ZERO)
                            .setScale(4, RoundingMode.CEILING);
                }
            }
            SafetySnapshot safety = groupSafetySnapshot(group.materials());
            BigDecimal confirmedSafety = input == null
                    || input.safetyReplenishmentQty() == null
                    ? null
                    : input.safetyReplenishmentQty()
                            .setScale(4, RoundingMode.CEILING);
            if ("BUY".equals(group.route())) {
                if (safety.gapQty().signum() > 0
                        && (confirmedSafety == null
                        || confirmedSafety.compareTo(safety.gapQty()) != 0)) {
                    throw validation("「" + groupLabel(group)
                            + "」公共安全库存补库已变化：当前固定补库 "
                            + safety.gapQty().stripTrailingZeros().toPlainString()
                            + "，请刷新数量确认后再提交");
                }
                if (safety.gapQty().signum() == 0
                        && confirmedSafety != null && confirmedSafety.signum() != 0) {
                    throw validation("「" + groupLabel(group)
                            + "」当前无需公共安全库存补库，请刷新后重新确认");
                }
            } else {
                if (confirmedSafety != null && confirmedSafety.signum() != 0) {
                    throw validation("只有采购路线可以提交公共安全库存补库");
                }
                if (safety.gapQty().signum() > 0) {
                    throw conflict("「" + groupLabel(group) + "」当前公共安全库存缺口 "
                            + safety.gapQty().stripTrailingZeros().toPlainString()
                            + "；本版本仅支持采购路线的公共安全库存补库，"
                            + "禁止重复下达委外/自制来伪装齐套，请先走独立补库或修正主数据");
                }
            }
            // ADR-099：外部路线先自动认领公共在途，认领到多少就少下多少新单。
            // ADR-101：我方供料的带 BOM 委外件也走这条路(只有「超量备货」仍然禁止)。
            BigDecimal claimedQty = BigDecimal.ZERO.setScale(4);
            if (!createsChildOwnership && demandQty.signum() > 0) {
                claimedQty = claimSharedFutureForGroup(analysisId, view, group, demandQty,
                        null, true, request.idempotencyKey(), requestHash,
                        claimActionIds, acceptedLateSources);
                demandQty = demandQty.subtract(claimedQty).max(BigDecimal.ZERO)
                        .setScale(4, RoundingMode.CEILING);
            }
            plans.add(new ActionPlan(group, demandQty, publicExtraQty, safety, claimedQty));
        }

        // 安全库存的物理粒度是仓+货+色；同一通知中的多个节点只能生成
        // 一份公共补库。稳定优先附着到本次有 demand exact 的 BUY action，
        // 若旧 demand 已 exact 到货而安全切片失败，则允许 safety-only action。
        Map<SafetyDimension, ActionPlan> safetyOwners = new LinkedHashMap<>();
        plans.stream().filter(plan -> "BUY".equals(plan.group().route()))
                .filter(plan -> plan.safety().gapQty().signum() > 0)
                .filter(plan -> plan.demandQty().signum() > 0)
                .forEach(plan -> safetyOwners.putIfAbsent(
                        SafetyDimension.of(plan.group()), plan));
        plans.stream().filter(plan -> "BUY".equals(plan.group().route()))
                .filter(plan -> plan.safety().gapQty().signum() > 0)
                .forEach(plan -> safetyOwners.putIfAbsent(
                        SafetyDimension.of(plan.group()), plan));

        List<ActionDraft> created = new ArrayList<>();
        List<GrownSupplyLine> grown = new ArrayList<>();
        for (ActionPlan plan : plans) {
            ActionGroup group = plan.group();
            SafetySnapshot frozenSafety = Objects.equals(
                    safetyOwners.get(SafetyDimension.of(group)), plan)
                    ? plan.safety()
                    : SafetySnapshot.ZERO;
            BigDecimal safetyQty = frozenSafety.gapQty();
            if (plan.demandQty().signum() == 0
                    && plan.publicExtraQty().signum() == 0
                    && safetyQty.signum() == 0) continue;
            // ADR-099：申请还没被采购/委外部门动过（明细未订货）时，追加量直接改到
            // 原申请明细上，不另立新单；带安全补库切片的批次仍走新单通道。
            boolean childOwnership = "MAKE".equals(group.route())
                    || ("SUBCONTRACT".equals(group.route())
                        && subcontractMakeFirst.contains(group.dimension().goodsId()));
            if (!childOwnership && safetyQty.signum() == 0) {
                GrowableSupplyLine line = growableSupplyLine(analysisId, group);
                if (line != null) {
                    growSupplyLine(analysisId, line, group,
                            plan.demandQty(), plan.publicExtraQty());
                    grown.add(new GrownSupplyLine(line, plan.demandQty().add(plan.publicExtraQty())));
                    continue;
                }
            }
            ActionSequence sequence = nextActionSequence(
                    analysisId, group.groupKey(), group.route());
            UUID actionId = UUID.randomUUID();
            String businessKey = PlanningPackageFingerprint.sha256(List.of(
                    "PREPLAN-SUPPLY-ACTION-V1", analysisId.toString(),
                    group.groupKey(), group.route(), Integer.toString(sequence.generation())));
            String actionIdempotency = "NOTIFY-" + PlanningPackageFingerprint.sha256(List.of(
                    request.idempotencyKey(), group.groupKey(), Integer.toString(sequence.generation())));
            em.createNativeQuery("""
                    INSERT INTO preplan_supply_actions (
                        id, analysis_id, warehouse_id, goods_id, color_id, unit_id,
                        need_date, route, requested_qty, public_surplus_qty,
                        operation_type,
                        safety_replenishment_qty, safety_stock_snapshot_qty,
                        public_available_snapshot_qty,
                        open_safety_supply_snapshot_qty, status,
                        idempotency_key, action_group_key, request_business_key,
                        generation, predecessor_action_id, request_hash,
                        created_by
                    ) VALUES (
                        :id, :analysisId, :warehouseId, :goodsId, :colorId, :unitId,
                        :needDate, :route, :demandQty, :publicSurplusQty,
                        'SUPPLY',
                        :safetyQty, :safetyStock, :publicAvailable,
                        :openSafetySupply, 'OPEN',
                        :idempotencyKey, :actionGroupKey, :businessKey,
                        :generation, :predecessorId, :requestHash,
                        :actorId
                    )
                    """)
                    .setParameter("id", actionId)
                    .setParameter("analysisId", analysisId)
                    .setParameter("warehouseId", view.warehouseId())
                    .setParameter("goodsId", group.dimension().goodsId())
                    .setParameter("colorId", group.dimension().colorId())
                    .setParameter("unitId", group.dimension().unitId())
                    .setParameter("needDate", group.needDate())
                    .setParameter("route", group.route())
                    .setParameter("demandQty", plan.demandQty())
                    .setParameter("publicSurplusQty", plan.publicExtraQty())
                    .setParameter("safetyQty", safetyQty)
                    .setParameter("safetyStock", frozenSafety.safetyStockQty())
                    .setParameter("publicAvailable", frozenSafety.publicAvailableQty())
                    .setParameter("openSafetySupply", frozenSafety.openSupplyQty())
                    .setParameter("idempotencyKey", actionIdempotency)
                    .setParameter("actionGroupKey", group.groupKey())
                    .setParameter("businessKey", businessKey)
                    .setParameter("generation", sequence.generation())
                    .setParameter("predecessorId", sequence.predecessorId())
                    .setParameter("requestHash", requestHash)
                    .setParameter("actorId", currentUser.requireId())
                    .executeUpdate();
            allocateAction(actionId, analysisId, group.materials(), plan.demandQty());
            created.add(new ActionDraft(
                    actionId, group, plan.demandQty(), plan.publicExtraQty(),
                    plan.publicExtraQty().signum() > 0 ? UUID.randomUUID() : null,
                    safetyQty, safetyQty.signum() > 0 ? UUID.randomUUID() : null));
        }

        // ADR-065 同批合并：一次通知的全部 BUY 合并生成一张采购申请、全部无子层
        // SUBCONTRACT 合并生成一张委外申请；明细行仍逐 action 锚定（撤回/绑定粒度不变），
        // 订货侧照旧按供应商分组拆订货单。MAKE 与委外前置自制保持逐条任务。
        PreparedExternalDocuments prepared =
                prepareExternalDocuments(analysisId, created, subcontractMakeFirst);
        for (ActionDraft action : created) {
            createExternalDocument(analysisId, action, prepared);
        }
        // ADR-065 修订（2026-09-03）：通知按单据聚合——每张申请只提醒一次
        // （N 种物料、单号、直达详情），不再逐 action 给同一批人重复发条。
        // 必须在全部 action 的 markCreated 完成之后发布，保证投递时单据链接已存在。
        if (prepared.purchaseRequest() != null) {
            chainNotice.notifyPreplanSupplyDocumentCreated(
                    prepared.purchaseRequest().requestId(), "PURCHASE_REQUEST");
        }
        if (prepared.subcontractApplication() != null) {
            chainNotice.notifyPreplanSupplyDocumentCreated(
                    prepared.subcontractApplication().applicationId(),
                    "SUBCONTRACT_APPLICATION");
        }
        // 就地追加的申请按单据各提醒一次（同一张申请多行追加合成一条）。
        Map<UUID, BigDecimal> grownByDocument = new LinkedHashMap<>();
        Map<UUID, String> grownDocumentTypes = new LinkedHashMap<>();
        for (GrownSupplyLine line : grown) {
            grownByDocument.merge(line.line().documentId(), line.addedQty(), BigDecimal::add);
            grownDocumentTypes.putIfAbsent(line.line().documentId(), line.line().documentType());
        }
        grownByDocument.forEach((documentId, addedQty) -> chainNotice
                .notifyPreplanSupplyDocumentIncreased(documentId,
                        grownDocumentTypes.get(documentId), addedQty));
        // 「一条 action 都没建」在服务端是**合法结局**，不能一律回 409：
        // 现货交接（rootStockHandled）、V466 原订单补货在途已覆盖、幂等回放
        // 都会走到这里。客户端要的是「这次到底有没有产生新的下达」——那由
        // 它按返回快照的 version/fingerprint 是否变化自行判定（只有真的写了东西
        // 才会 refreshLocked 换版本），不改本端点的成功语义（2026-09-15）。
        if (!created.isEmpty() || !grown.isEmpty() || !claimActionIds.isEmpty()) {
            // 2026-09-05 简化：子件行不再接管原子树需求、不迁移 exact 权益
            // （物料行保持原位单一份数据，计划侧不搬家）；旧模式遗留的委托
            // 由 refreshLocked 开头的批量归还收敛。
            analysisService.refreshLocked(analysisId);
        }
        recordCommand(analysisId, OP_NOTIFY, request.idempotencyKey(), requestHash,
                Map.of("actionIds", created.stream().map(ActionDraft::actionId).toList(),
                        "grownActionIds", grown.stream().map(line -> line.line().actionId()).toList(),
                        "claimActionIds", List.copyOf(claimActionIds),
                        "acceptedLateSources", List.copyOf(acceptedLateSources)));
        return analysisService.detailInternal(analysisId, false);
    }

    /**
     * Explicitly adopts approved public future supply.  The claim is a normal
     * demand allocation owned by the target analysis, but it reuses the source
     * document and never creates, edits, or cancels that document.
     */
    @Transactional
    public AnalysisView claimSharedFuture(
            UUID analysisId, ClaimSharedFutureRequest request) {
        tx.bind();
        var mutationGuard = mutationLocks.acquire(() -> mutationFootprints.forSharedFutureClaim(analysisId));
        MaterialAnalysisService.AnalysisHeader header = analysisService.headerAfterPrelock(analysisId);
        requireWritable(header, "只能为本人负责的物料分析采用公共在途");
        String requestHash = claimSharedFutureHash(analysisId, request);
        CommandReplay replay = commandReplay(analysisId, OP_CLAIM_SHARED_FUTURE,
                request.idempotencyKey(), requestHash);
        if (replay != null) {
            return analysisService.detailInternal(analysisId, false);
        }
        mutationGuard.verifyUnchanged();
        analysisService.requireCurrent(header, request.version(), request.fingerprint());
        analysisService.refreshLocked(analysisId);
        AnalysisView view = analysisService.detailInternal(analysisId, false);
        NotifyRequest selector = new NotifyRequest(
                view.version(), view.fingerprint(), request.idempotencyKey(),
                null, List.of(), request.actionGroupKeys(), List.of());
        List<ActionGroup> groups = selectedGroups(view, selector);
        Map<String,SharedFutureClaimQuantity> requestedQuantities=sharedFutureQuantities(request,groups);
        Set<UUID> subcontractBomParents = activeBomParentIds(groups.stream()
                .filter(group -> "SUBCONTRACT".equals(group.route()))
                .map(group -> group.dimension().goodsId()).toList());
        var coverage = supplyCoverage(analysisId, groups);
        List<UUID> createdIds = new ArrayList<>();
        List<Map<String,String>> acceptedLateSources=new ArrayList<>();
        for (ActionGroup group : groups) {
            // 2026-09-13 起自制（车间）物料也可采用公共在途：到达的合格供给
            // 直接冲减本计划自制需求，剩余仍走原下达车间流程。
            // ADR-101 起「我方供料 BOM 委外件」也能认领——认领的是别人已经备好料下好单的
            // 那一批，本计划不会因此多出无人负责的子件需求；禁止的只是自己超量备货。
            if (!Set.of("BUY", "SUBCONTRACT", "MAKE").contains(group.route())) {
                throw validation("只有采购、委外或自制物料可以采用公共在途");
            }
            BigDecimal existingOpen = activeOpenActionQty(coverage, group);
            BigDecimal needed = group.demandRequiredQty().subtract(existingOpen)
                    .subtract(cancelledIqcReplacementInFlight(coverage,group))
                    .max(BigDecimal.ZERO).setScale(4, RoundingMode.CEILING);
            SharedFutureClaimQuantity quantity=requestedQuantities.get(group.groupKey());
            if(quantity!=null) {
                if(quantity.qty().compareTo(needed)>0) throw conflict("本次认领数量超过尚未被有效供给覆盖的需求，请刷新后重试");
                needed=quantity.qty();
            }
            if (needed.signum() <= 0) continue;
            BigDecimal claimed = claimSharedFutureForGroup(analysisId, view, group, needed,
                    quantity, request.allowLateSupply(), request.idempotencyKey(), requestHash,
                    createdIds, acceptedLateSources);
            if (quantity != null && claimed.compareTo(needed) < 0) {
                throw conflict("公共在途余量已变化，本次认领未生效，请核对数量后重试");
            }
        }
        if (createdIds.isEmpty()) {
            throw conflict("当前没有可采用的同主仓、按期公共在途余量");
        }
        analysisService.refreshLocked(analysisId);
        recordCommand(analysisId, OP_CLAIM_SHARED_FUTURE,
                request.idempotencyKey(), requestHash,
                Map.of("actionIds",List.copyOf(createdIds),"allowLateSupply",request.allowLateSupply(),
                        "acceptedLateSources",List.copyOf(acceptedLateSources)));
        return analysisService.detailInternal(analysisId, false);
    }

    /**
     * 可认领的公共在途来源。
     *
     * <p>ADR-101：候选**只取同路线**({@code route = :route})。在此之前这里是
     * {@code route IN ('BUY','SUBCONTRACT')}，跨路线也能认领，而界面上告诉用户
     * 「其中 X 可自动认领」的 {@code sharedFutureClaimableQty} 一直是按路线过滤的——两侧口径
     * 不一致时，界面显示 0、用户照填 100 点下达，服务端却把需求全认领成 0，一张新申请明细都
     * 不生成，用户以为下了 100 其实一分没下。ADR-101 把「还需安排」改成预扣公共在途的净数，
     * 显示的数就是会下的数，两侧口径必须严格一致，跨路线认领要放开得连提示那一侧一起放开，
     * 那是另一次产品决策。
     */
    private List<SharedFutureSource> sharedFutureSources(
            UUID analysisId, ActionGroup group,boolean allowLateSupply) {
        return NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT source_action_id, available_to_claim_qty, expected_date,
                       claim_external_item_id, external_document_type,
                       external_document_id, external_document_no, route
                FROM v_preplan_public_surplus_source_state
                WHERE source_analysis_id <> :analysisId
                  AND fn_warehouse_same_main(warehouse_id, :warehouseId)
                  AND goods_id = :goodsId
                  AND color_id IS NOT DISTINCT FROM CAST(:colorId AS uuid)
                  AND unit_id = :unitId
                  AND route = :route
                  AND available_to_claim_qty > 0
                  AND claim_external_item_id IS NOT NULL
                  AND (:allowLateSupply=TRUE OR (expected_date IS NOT NULL AND
                       (CAST(:needDate AS date) IS NULL OR expected_date <= CAST(:needDate AS date))))
                ORDER BY expected_date, created_at, source_action_id
                """)
                .setParameter("analysisId", analysisId)
                .setParameter("warehouseId", selectedWarehouse(analysisId))
                .setParameter("goodsId", group.dimension().goodsId())
                .setParameter("colorId", group.dimension().colorId())
                .setParameter("unitId", group.dimension().unitId())
                .setParameter("route", group.route())
                .setParameter("needDate", group.needDate()).setParameter("allowLateSupply",allowLateSupply)).stream()
                .map(row -> new SharedFutureSource(
                        (UUID) row[0], decimal(row[1]),
                        MaterialAnalysisService.date(row[2]),
                        (UUID) row[3], Objects.toString(row[4], null),
                        (UUID) row[5], Objects.toString(row[6], null),
                        Objects.toString(row[7], null)))
                .toList();
    }

    /**
     * 为一个操作组认领同主仓公共在途（按期优先、晚到其次），返回实际认领量。
     * 既是「采用公共在途」命令的主体，也是下达采购/委外时的自动认领（ADR-099）：
     * 认领到的份额直接冲减本次要新下单的量。
     *
     * @param quantity 用户明确指定的认领量/来源（null = 自动按可用余量认领）
     * @return 本次实际认领量（可能为 0：没有可认领的同主仓公共在途）
     */
    private BigDecimal claimSharedFutureForGroup(
            UUID analysisId, AnalysisView view, ActionGroup group, BigDecimal needed,
            SharedFutureClaimQuantity quantity, boolean allowLateSupply,
            String idempotencyKey, String requestHash,
            List<UUID> createdIds, List<Map<String, String>> acceptedLateSources) {
        BigDecimal remaining = needed;
        List<SharedFutureSource> initial = sharedFutureSources(
                analysisId, group, allowLateSupply).stream()
                .filter(source -> quantity == null || quantity.sourceActionId() == null
                        || quantity.sourceActionId().equals(source.actionId())).toList();
        if (initial.isEmpty()) {
            if (quantity != null) {
                throw conflict("所选公共在途已不可认领；晚到或交期未明确的来源须明确确认后再采用");
            }
            return BigDecimal.ZERO.setScale(4);
        }
        List<UUID> sourceIds = initial.stream().map(SharedFutureSource::actionId)
                .distinct().sorted().toList();
        em.createNativeQuery("""
                SELECT id FROM preplan_supply_actions
                WHERE id IN (SELECT unnest(CAST(string_to_array(:ids, ',') AS uuid[]))) ORDER BY id FOR UPDATE
                """).setParameter("ids", sourceIds.stream().map(UUID::toString)
                .collect(Collectors.joining(","))).getResultList();
        List<SharedFutureSource> sources = sharedFutureSources(
                analysisId, group, allowLateSupply).stream()
                .filter(source -> quantity == null || quantity.sourceActionId() == null
                        || quantity.sourceActionId().equals(source.actionId())).toList();
        for (SharedFutureSource source : sources) {
            if (remaining.signum() <= 0) break;
            BigDecimal take = remaining.min(source.availableQty())
                    .setScale(4, RoundingMode.DOWN);
            if (take.signum() <= 0) continue;
            // 认领动作沿用「来源路线」：公共在途本身是采购/委外份额，
            // 目标行可以是采购、委外或自制。代次按 (分析, 操作组, 路线)
            // 取号，跨路线认领与目标同组的自制动作不会撞唯一索引，
            // 也让 fn_validate_preplan_shared_future_claim 的来源身份
            // 校验（来源与认领动作同路线、同单据）继续成立。
            String claimRoute = Objects.requireNonNullElse(
                    source.sourceRoute(), group.route());
            ActionSequence sequence = nextActionSequence(
                    analysisId, group.groupKey(), claimRoute);
            UUID actionId = UUID.randomUUID();
            String businessKey = PlanningPackageFingerprint.sha256(List.of(
                    "PREPLAN-SHARED-FUTURE-CLAIM-V1", analysisId.toString(),
                    group.groupKey(), source.actionId().toString(),
                    Integer.toString(sequence.generation())));
            String actionIdempotency = "CLAIM-" + PlanningPackageFingerprint.sha256(
                    List.of(idempotencyKey, group.groupKey(),
                            source.actionId().toString(),
                            Integer.toString(sequence.generation())));
            em.createNativeQuery("""
                    INSERT INTO preplan_supply_actions (
                        id, analysis_id, warehouse_id, goods_id, color_id, unit_id,
                        need_date, route, requested_qty, status,
                        external_document_type, external_document_id,
                        external_document_no, operation_type, claim_source_action_id,
                        idempotency_key, action_group_key, request_business_key,
                        generation, predecessor_action_id, request_hash, created_by)
                    VALUES (
                        :id, :analysisId, :warehouseId, :goodsId, :colorId, :unitId,
                        :needDate, :route, :qty, 'CREATED',
                        :documentType, :documentId, :documentNo,
                        'SHARED_FUTURE_CLAIM', :sourceActionId,
                        :idempotencyKey, :groupKey, :businessKey,
                        :generation, :predecessorId, :requestHash, :actorId)
                    """)
                    .setParameter("id", actionId)
                    .setParameter("analysisId", analysisId)
                    .setParameter("warehouseId", view.warehouseId())
                    .setParameter("goodsId", group.dimension().goodsId())
                    .setParameter("colorId", group.dimension().colorId())
                    .setParameter("unitId", group.dimension().unitId())
                    .setParameter("needDate", group.needDate())
                    .setParameter("route", claimRoute)
                    .setParameter("qty", take)
                    .setParameter("documentType", source.documentType())
                    .setParameter("documentId", source.documentId())
                    .setParameter("documentNo", source.documentNo())
                    .setParameter("sourceActionId", source.actionId())
                    .setParameter("idempotencyKey", actionIdempotency)
                    .setParameter("groupKey", group.groupKey())
                    .setParameter("businessKey", businessKey)
                    .setParameter("generation", sequence.generation())
                    .setParameter("predecessorId", sequence.predecessorId())
                    .setParameter("requestHash", requestHash)
                    .setParameter("actorId", currentUser.requireId())
                    .executeUpdate();
            allocateClaim(actionId, analysisId, group.materials(), take,
                    source.externalItemId());
            createdIds.add(actionId);
            if (source.expectedDate() == null
                    || group.needDate() != null && source.expectedDate().isAfter(group.needDate())) {
                acceptedLateSources.add(Map.of("claimActionId", actionId.toString(),
                        "sourceActionId", source.actionId().toString(),
                        "expectedDate", Objects.toString(source.expectedDate(), ""),
                        "originalNeedDate", Objects.toString(group.needDate(), "")));
            }
            remaining = remaining.subtract(take);
        }
        return needed.subtract(remaining).max(BigDecimal.ZERO).setScale(4, RoundingMode.DOWN);
    }

    /**
     * 本操作组最近一条仍可就地改量的申请明细（ADR-099）：申请仍开着、明细未订货、
     * 采购/委外部门还没动过它。找不到则返回 null，由调用方另立新单。
     */
    private GrowableSupplyLine growableSupplyLine(UUID analysisId, ActionGroup group) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT DISTINCT ON (action.id)
                       action.id, action.external_document_type, action.external_document_id,
                       action.external_document_no, allocation.external_item_id, action.created_at
                FROM preplan_supply_actions action
                JOIN preplan_supply_action_allocations allocation
                  ON allocation.action_id = action.id
                WHERE action.analysis_id = :analysisId
                  AND action.action_group_key = :groupKey
                  AND action.route = :route
                  AND action.operation_type = 'SUPPLY'
                  AND action.status = 'CREATED'
                  AND action.external_document_type IN ('PURCHASE_REQUEST','SUBCONTRACT_APPLICATION')
                  AND action.safety_replenishment_qty = 0
                  AND allocation.external_item_id IS NOT NULL
                  AND (action.public_surplus_external_item_id IS NULL
                       OR action.public_surplus_external_item_id = allocation.external_item_id)
                  AND fn_preplan_supply_action_growable(action.id)
                ORDER BY action.id, allocation.created_at, allocation.id
                """)
                .setParameter("analysisId", analysisId)
                .setParameter("groupKey", group.groupKey())
                .setParameter("route", group.route()));
        return rows.stream()
                .map(row -> new GrowableSupplyLine((UUID) row[0], Objects.toString(row[1], null),
                        (UUID) row[2], Objects.toString(row[3], null), (UUID) row[4],
                        row[5] == null ? null : row[5].toString()))
                .max(Comparator.comparing((GrowableSupplyLine line) -> Objects.toString(line.createdAt(), ""))
                        .thenComparing(line -> line.actionId().toString()))
                .orElse(null);
    }

    /**
     * 就地追加：申请明细数量改大，供给行动的需求量/公共量与各物料行的分摊同步增长。
     * 数据库守卫（V640）只对「明细未订货」的供给行动放开这类增长，其余仍不可变。
     */
    private void growSupplyLine(
            UUID analysisId, GrowableSupplyLine line, ActionGroup group,
            BigDecimal demandQty, BigDecimal publicExtraQty) {
        BigDecimal added = demandQty.add(publicExtraQty);
        if (added.signum() <= 0) return;
        em.createNativeQuery("""
                SELECT id FROM preplan_supply_actions WHERE id = :id FOR UPDATE
                """).setParameter("id", line.actionId()).getResultList();
        if ("PURCHASE_REQUEST".equals(line.documentType())) {
            purchaseRequests.increaseProductionDraftLine(
                    line.documentId(), line.externalItemId(), added);
        } else {
            subcontractRequests.increaseProductionDraftLine(
                    line.documentId(), line.externalItemId(), added);
        }
        int updated = em.createNativeQuery("""
                UPDATE preplan_supply_actions
                SET requested_qty = requested_qty + CAST(:demandQty AS numeric),
                    public_surplus_qty = public_surplus_qty + CAST(:publicExtraQty AS numeric),
                    public_surplus_external_item_id = CASE
                        WHEN CAST(:publicExtraQty AS numeric) > 0
                        THEN COALESCE(public_surplus_external_item_id, CAST(:externalItemId AS uuid))
                        ELSE public_surplus_external_item_id END,
                    updated_at = now()
                WHERE id = :id AND status = 'CREATED'
                """)
                .setParameter("demandQty", demandQty)
                .setParameter("publicExtraQty", publicExtraQty)
                .setParameter("externalItemId", line.externalItemId())
                .setParameter("id", line.actionId())
                .executeUpdate();
        if (updated != 1) {
            throw conflict("「" + groupLabel(group) + "」原申请状态已变化，请刷新后重试");
        }
        if (demandQty.signum() > 0) {
            growAllocations(analysisId, line, group.materials(), demandQty);
        }
    }

    /** 与 {@link #allocateAction} 同一分摊口径，只是落在既有分摊行上累加（缺行则补建）。 */
    private void growAllocations(
            UUID analysisId, GrowableSupplyLine line, List<MaterialView> materials, BigDecimal qty) {
        BigDecimal total = materials.stream().map(MaterialView::demandSupplyGapQty)
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        List<MaterialView> positive = materials.stream()
                .filter(material -> material.demandSupplyGapQty().signum() > 0).toList();
        BigDecimal remaining = qty;
        for (int index = 0; index < positive.size(); index++) {
            MaterialView material = positive.get(index);
            BigDecimal allocated = index == positive.size() - 1
                    ? remaining
                    : qty.multiply(material.demandSupplyGapQty())
                            .divide(total, 4, RoundingMode.DOWN).min(remaining);
            if (allocated.signum() <= 0) continue;
            int updated = em.createNativeQuery("""
                    UPDATE preplan_supply_action_allocations
                    SET allocated_qty = allocated_qty + CAST(:qty AS numeric)
                    WHERE action_id = :actionId AND analysis_material_id = :materialId
                    """)
                    .setParameter("qty", allocated)
                    .setParameter("actionId", line.actionId())
                    .setParameter("materialId", material.materialLineId())
                    .executeUpdate();
            if (updated == 0) {
                em.createNativeQuery("""
                        INSERT INTO preplan_supply_action_allocations (
                            id, analysis_id, action_id, analysis_material_id,
                            allocated_qty, external_item_id, created_by)
                        VALUES (:id, :analysisId, :actionId, :materialId,
                                :qty, :externalItemId, :actorId)
                        """)
                        .setParameter("id", UUID.randomUUID())
                        .setParameter("analysisId", analysisId)
                        .setParameter("actionId", line.actionId())
                        .setParameter("materialId", material.materialLineId())
                        .setParameter("qty", allocated)
                        .setParameter("externalItemId", line.externalItemId())
                        .setParameter("actorId", currentUser.requireId())
                        .executeUpdate();
            }
            remaining = remaining.subtract(allocated);
        }
        if (remaining.signum() != 0) {
            throw conflict("就地追加的节点分摊数量不守恒");
        }
    }

    private void allocateClaim(
            UUID actionId, UUID analysisId, List<MaterialView> materials,
            BigDecimal qty, UUID externalItemId) {
        BigDecimal total = materials.stream().map(MaterialView::demandSupplyGapQty)
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal remaining = qty;
        List<MaterialView> positive = materials.stream()
                .filter(material -> material.demandSupplyGapQty().signum() > 0).toList();
        for (int index = 0; index < positive.size(); index++) {
            MaterialView material = positive.get(index);
            BigDecimal allocated = index == positive.size() - 1
                    ? remaining
                    : qty.multiply(material.demandSupplyGapQty())
                            .divide(total, 4, RoundingMode.DOWN).min(remaining);
            if (allocated.signum() <= 0) continue;
            em.createNativeQuery("""
                    INSERT INTO preplan_supply_action_allocations (
                        id, analysis_id, action_id, analysis_material_id,
                        allocated_qty, external_item_id, created_by)
                    VALUES (:id, :analysisId, :actionId, :materialId,
                            :qty, :externalItemId, :actorId)
                    """)
                    .setParameter("id", UUID.randomUUID())
                    .setParameter("analysisId", analysisId)
                    .setParameter("actionId", actionId)
                    .setParameter("materialId", material.materialLineId())
                    .setParameter("qty", allocated)
                    .setParameter("externalItemId", externalItemId)
                    .setParameter("actorId", currentUser.requireId())
                    .executeUpdate();
            remaining = remaining.subtract(allocated);
        }
        if (remaining.signum() != 0) {
            throw conflict("公共在途采用的节点分摊数量不守恒");
        }
    }

    /**
     * V288 调货是分析内人工软分配；一旦据此创建外部采购/委外任务，后续 IQC
     * exact peg 将按原供应分摊行锁定，二者不能静默叠加。冲突必须在计划员通知
     * 供应时暴露，而不是等品质放行时才回滚。
     */
    void requireNoActiveBorrowForSupplyMaterials(
            UUID analysisId, Set<UUID> materialIds) {
        if (materialIds.isEmpty()) return;
        Number conflicts = (Number) em.createNativeQuery("""
                SELECT COUNT(*)
                FROM production_material_analysis_borrows borrow
                WHERE borrow.analysis_id = :analysisId
                  AND borrow.status = 'ACTIVE'
                  AND (borrow.from_material_id IN (SELECT unnest(CAST(string_to_array(:materialIds, ',') AS uuid[])))
                       OR borrow.to_material_id IN (SELECT unnest(CAST(string_to_array(:materialIds, ',') AS uuid[]))))
                """)
                .setParameter("analysisId", analysisId)
                .setParameter("materialIds", materialIds.stream().map(UUID::toString).collect(Collectors.joining(",")))
                .getSingleResult();
        if (conflicts.longValue() > 0) {
            throw conflict("所选物料存在生效中的分析内调货，不能据此创建采购/委外任务；"
                    + "请先撤销调拨，再按原物料行通知供应");
        }
    }

    /**
     * 下达车间（ADR-071）：所有自制行一视同仁，单事务原子完成——候选行先按
     * 全部剩余需求建子件任务（复用 notifySupply 的增量/幂等口径），随后按行内
     * 数量/车间/负责人逐行生成生产计划，有审核权限同事务审核下达。物料齐不齐
     * 不在本层判断：缺料批次生成自动提升的 WAITING 段，由车间侧等料齐套。
     * 任一行失败整体回滚，不会留下「已建子件、未出计划」的残留行；重试时
     * 幂等键回放，子件增量口径保证不重复建行。
     */
    @Transactional
    public GenerateResult issueWorkshopPlans(
            UUID analysisId, IssueWorkshopPlansRequest request) {
        if (request.lines().isEmpty()) {
            throw validation("本次没有要下达的行");
        }
        return issueWorkshopPlansInternal(analysisId, request, Map.of());
    }

    /**
     * @param typedOutputByMaterialLine 下达预览专用：层级表上每个父行填的数量
     *        (键 = 物料行 id)。只影响最后那次重算里「子件按父件计划产出展开」
     *        这一步，真实下达恒传空 Map。
     */
    private GenerateResult issueWorkshopPlansInternal(
            UUID analysisId, IssueWorkshopPlansRequest request,
            Map<UUID, BigDecimal> typedOutputByMaterialLine) {
        tx.bind();
        // 本命令会嵌套进 notifySupplyInternal 的 ARRANGE 腿(委外件有自制子层时建台账),
        // 那一腿按 ADR-099 要锁「本分析 + 可认领公共在途」。预锁一旦 prepared 就只允许
        // 覆盖检查、不允许补拿, 所以这里必须一次锁到同样宽, 否则同主仓只要存在可认领的
        // 公共在途, 下达车间与 issue-plans/preview 就必然 409(还会被自动重跑放大 5 次)。
        var mutationGuard = lockAnalysisWithClaimableShared(analysisId);
        MaterialAnalysisService.AnalysisHeader header = analysisService.headerAfterPrelock(analysisId);
        requireNotFqcRecoveryWorkspace(analysisId);
        requireWritable(header, "只能从本人负责的物料分析下达车间");
        String requestHash = issueHash(analysisId, request);
        CommandReplay replay = commandReplay(analysisId, OP_GENERATE,
                request.idempotencyKey(), requestHash);
        if (replay != null) {
            List<UUID> planIds = replayIds(replay.payload(), "planIds");
            Set<UUID> mergedPlanIds = new HashSet<>(replayIds(replay.payload(), "mergedPlanIds"));
            return new GenerateResult(analysisService.detailInternal(analysisId, false), true,
                    planIds.stream().map(this::generatedPlan)
                            .map(plan -> mergedPlanIds.contains(plan.planId()) ? plan.merged(null) : plan)
                            .toList());
        }
        mutationGuard.verifyUnchanged();
        analysisService.requireCurrent(header, request.version(), request.fingerprint());
        if (!Objects.equals(header.warehouseId(), request.warehouseId())) {
            throw conflict("目标仓库与分析当前仓库不一致，请刷新后重试");
        }
        if (request.approveNow() && !access.hasAuthority("production_plan:approve")) {
            throw new ApiException(ErrorCode.FORBIDDEN, "生成并审核需要独立的生产计划审核权限");
        }
        // Admission uses the original request CAS and BOM snapshot. Stock can
        // change through generic warehouse commands without updating this
        // analysis, so recompute allocation under the held mutation locks before
        // deciding a new child quota. Page entry and GET remain read-only.
        if (!request.lines().isEmpty()) {
            analysisService.requireCurrentBomSnapshot(analysisId, workshopSourceIds(analysisId, request));
        }
        analysisService.refreshLocked(analysisId);
        // 1) 候选行建「子件锚点行」（2026-09-05 简化：计划侧不再接管子树需求、
        //    不搬权益——物料行保持原位单一份数据，计划员照常在采购/委外桶下达；
        //    锚点行仅承载计划链接与执行进度）。MAKE 只建锚点行；有子层委外
        //    同时登记「先自制后通知」台账（notifySupply 既有链路，无权益委托）。
        AnalysisView preArrange = analysisService.detailInternal(analysisId, false);
        Map<UUID, String> candidateRoutes = candidateRoutesByMaterialLine(preArrange);
        Map<UUID, UUID> subcontractMaterialByAnchor = new HashMap<>();
        for (MaterialView material : preArrange.flatMaterials()) {
            if (material.planAnchorAnalysisLineId() != null
                    && "SUBCONTRACT".equals(material.sourceConfirmed())) {
                subcontractMaterialByAnchor.put(material.planAnchorAnalysisLineId(), material.materialLineId());
            }
        }
        List<UUID> makeLines = new ArrayList<>();
        List<UUID> subcontractLines = new ArrayList<>();
        // 2026-09-09 性能（保守优化）：flatMaterials 逐行线性扫描 + 每行一次
        // BOM 父检查查询 → 预建索引一次 + 候选货品集合一次批量父检查。
        Map<UUID, UUID> goodsByMaterialLine = new java.util.HashMap<>();
        for (MaterialView material : preArrange.flatMaterials()) {
            goodsByMaterialLine.putIfAbsent(material.materialLineId(), material.goodsId());
        }
        List<UUID> subcontractCandidateGoods = request.lines().stream()
                .map(IssueWorkshopPlansRequest.IssuePlanLine::materialLineId)
                .filter(java.util.Objects::nonNull)
                .filter(id -> "SUBCONTRACT".equals(candidateRoutes.get(id)))
                .map(goodsByMaterialLine::get)
                .filter(java.util.Objects::nonNull)
                .distinct().toList();
        java.util.Set<UUID> goodsWithMakeChildren = new java.util.HashSet<>(
                activeBomParentIds(subcontractCandidateGoods));
        // V581：只有一个直属子件的委外件不进车间——它直接发子件给委外商。
        goodsWithMakeChildren.removeAll(
                soleComponentSubcontractGoodsIds(subcontractCandidateGoods));
        for (IssueWorkshopPlansRequest.IssuePlanLine line : request.lines()) {
            if (line.materialLineId() == null) {
                UUID preparationMaterial = subcontractMaterialByAnchor.get(line.analysisLineId());
                if (preparationMaterial != null) subcontractLines.add(preparationMaterial);
                continue;
            }
            String route = candidateRoutes.get(line.materialLineId());
            if (route == null) {
                throw validation("候选物料节点不存在或路线未确认，请刷新后重试");
            }
            if ("MAKE".equals(route)) {
                makeLines.add(line.materialLineId());
                continue;
            }
            if (!"SUBCONTRACT".equals(route)) {
                throw validation("只有自制路线的物料才能直接下达车间");
            }
            UUID goodsId = goodsByMaterialLine.get(line.materialLineId());
            if (goodsId == null || !goodsWithMakeChildren.contains(goodsId)) {
                throw validation("无自制子层、或只有一个直属子件（直接发子件给委外商）的委外件"
                        + "请走委外下达，不能直接建生产计划");
            }
            subcontractLines.add(line.materialLineId());
        }
        // 入场已按实时库存刷新。先建立 MAKE 锚点，再让委外通知复用或更新该快照；
        // 仅在锚点实际改变且没有委外通知覆盖时，另作锚点后刷新。计划生成结束后
        // 再投影正式计划覆盖，始终满足 ADR-071 的「以当前权威快照逐行生成」。
        boolean anchorsChanged = !makeLines.isEmpty()
                && ensureWorkshopChildAnchors(analysisId, preArrange, makeLines);
        AnalysisView view = preArrange;
        if (!subcontractLines.isEmpty()) {
            // V589：把候选行的「本次数量」带给 ARRANGE——车间腿超量时台账与
            // 行动按「归需求量 + 公共备货产出」承接（用户口径：顶层做 5000，
            // 委外件就要加工 5000）。
            Map<UUID, BigDecimal> arrangeQty = new HashMap<>();
            for (IssueWorkshopPlansRequest.IssuePlanLine line : request.lines()) {
                UUID materialId = line.materialLineId() != null ? line.materialLineId()
                        : subcontractMaterialByAnchor.get(line.analysisLineId());
                if (materialId != null && line.qty() != null && subcontractLines.contains(materialId)) {
                    arrangeQty.merge(materialId, line.qty(), BigDecimal::max);
                }
            }
            view = notifySupplyInternal(analysisId, new NotifyRequest(
                    preArrange.version(), preArrange.fingerprint(),
                    request.idempotencyKey() + "-ARRANGE", "SUBCONTRACT",
                    subcontractLines, null, null), !anchorsChanged, arrangeQty);
            anchorsChanged = false;
        }
        // 2) 以最新快照逐行生成计划：产品行直接用行 id，候选行解析到刚建/既有子件行。
        if (anchorsChanged) {
            analysisService.refreshLocked(analysisId);
            view = analysisService.detailInternal(analysisId, false);
        }
        // Reuse the exact same transaction snapshot when anchors did not change.
        // notifySupply already returns its post-write view; discarding it would
        // repeat every warehouse, entitlement and document-chain projection.
        Map<UUID, ProductView> products = view.products().stream()
                .collect(Collectors.toMap(ProductView::analysisLineId, value -> value));
        Map<UUID, IssueWorkshopPlansRequest.IssuePlanLine> lineByAnalysisLine =
                new LinkedHashMap<>();
        // 2026-09-09 性能（保守优化）：子件行解析由逐行查询（N+1）改为一次
        // 批量预取——几十行候选时省下几十条同构 SQL，事务持锁时间同步缩短。
        Map<UUID, UUID> childLineByMaterialLine = batchChildLineIds(analysisId,
                request.lines().stream()
                        .map(IssueWorkshopPlansRequest.IssuePlanLine::materialLineId)
                        .filter(java.util.Objects::nonNull)
                        .collect(java.util.stream.Collectors.toSet()));
        for (IssueWorkshopPlansRequest.IssuePlanLine line : request.lines()) {
            UUID lineId = line.analysisLineId() != null
                    ? line.analysisLineId()
                    : childLineByMaterialLine.get(line.materialLineId());
            if (lineId == null || lineByAnalysisLine.put(lineId, line) != null) {
                throw validation("物料库存或候选任务已变化，本次未下达；请点击刷新重新核对后再提交");
            }
        }
        // BOM/订单来源漂移闸：分析快照之后 BOM 或销售订单状态变了就拒绝下达。
        // 一行都不下达的重算(预览只带层级数量)没有要校验的产品，跳过这道闸——
        // 它本来就只校验「本次要生成计划的那些产品」。
        if (!lineByAnalysisLine.isEmpty()) {
            analysisService.requireCurrentBomSnapshot(analysisId, lineByAnalysisLine.keySet());
        }
        PlanScheduleDefaults defaults = new PlanScheduleDefaults(
                request.billDate(), request.deliveryDate());
        List<GeneratedPlan> generated = new ArrayList<>();
        // Plan linking and approval change sources, plans and reservations, but
        // do not rewrite this analysis's material/BOM projection. Verify those
        // two static slices at both batch boundaries. ADR-107: the outermost
        // command ran its one discovery and one row-version recheck up front;
        // each nested command here only checks its declared ids in memory.
        try (var structure = mutationFootprints.openAnalysisStructureScope(analysisId)) {
            for (Map.Entry<UUID, IssueWorkshopPlansRequest.IssuePlanLine> entry
                    : lineByAnalysisLine.entrySet()) {
                UUID lineId = entry.getKey();
                IssueWorkshopPlansRequest.IssuePlanLine line = entry.getValue();
                ProductView product = products.get(lineId);
                if (product == null) {
                    throw validation("待生成计划产品不属于当前分析");
                }
                // ADR-099：剩余需求为 0 的行只有**明确声明** publicSurplusOnly 时才按
                // 「纯公共备货产出」再下一批(canIssueSurplus，V577 合法形态)——用户口径
                // 「父层级那里还是可以追加下单，多下的属于公共的」；不声明照旧 409，
                // 重复点击 / 过期候选不能悄悄多建一张计划。
                boolean surplusOnly = Boolean.TRUE.equals(line.publicSurplusOnly());
                if (!product.canSchedule()
                        && !(surplusOnly && product.canIssueSurplus() && line.qty().signum() > 0)) {
                    throw conflict(product.scheduleBlockedReason() == null
                            ? "当前产品不可排产" : product.scheduleBlockedReason());
                }
                // 超量下达（2026-09-14 用户口径「生产是可以超出数量下达的，
                // 超出部分就是公共的，其他计划可以占用」）：本批数量拆成
                // 「归本需求的量」+「公共备货产出量」两笔——前者照旧占
                // submitted_qty（V234 的 submitted+approved<=requested 守恒不动，
                // 锚点配额增长算法 growMakeAnchorQuotas 也不被污染），后者单独
                // 记在计划关联行的 public_surplus_qty 上，不绑定任何需求：产出
                // 入库后就是公共库存，其他计划可以直接用。
                BigDecimal demandQty = line.qty().min(product.remainingQty());
                BigDecimal surplusQty = line.qty().subtract(demandQty);
                // 2026-09-15 修订（用户口径「多余的不要单独列一张单，直接合并」）：
                // 销售订单来源顶层行超量不再拆成两张计划单，与非销售来源同一形状
                // ——一张计划、link 记 submitted=归需求量 + surplus=超量。销售侧
                // 守恒改由「分摊只认 submitted」保证：审核时 plan_order_item_links
                // 的容量与执行段销售分摊都只覆盖归本需求的量（ProductionPlanService
                // / ProductionExecutionPackageCommandService / DB 断言触发器同步
                // 放宽），「排产量 ≤ 订单未满足」原样成立。
                PlanQuantity quantity = new PlanQuantity(lineId, line.qty(),
                        line.billDate(), line.deliveryDate(), line.departmentId(),
                        line.workshopName(), line.workerId(), line.teamDepartmentId(),
                        line.productNo());
                validatePlanSchedule(quantity, defaults);
                // ADR-104：同一分析行已有一张还没开工的计划(草稿, 或已审核但车间没领料没开工)
                // 时, 追加量并进那张计划——同一单号、明细加量、关联行加量, 已审核的在同一个
                // 原工单同步加量。已提交领料或执行的计划照旧另立新单。
                GrowablePlan growable = growablePlanFor(
                        analysisId, lineId, quantity.departmentId(), request.approveNow());
                if (growable != null) {
                    generated.add(growPlan(analysisId, product, growable, quantity, defaults,
                            demandQty, surplusQty, request));
                    continue;
                }
                PlanDetail plan = createDraftPlan(analysisId, product, quantity, defaults, surplusQty);
                ProductionPlanningDraftView draft = savePlanningDraft(
                        analysisId, product, plan, quantity, defaults, request.warehouseId());
                PlanningPackageResult applied = null;
                if (request.approveNow()) {
                    planService.approve(plan.getId());
                    applied = planningPackages.currentResult(plan.getId()).orElseThrow(() ->
                            conflict("生产计划已审核但正式计划包未生成，事务已回滚"));
                }
                generated.add(toGenerated(plan, draft, applied));
            }
        }
        MaterialAnalysisService.AnalysisHeader postPlanHeader =
                analysisService.headerAfterPrelock(analysisId);
        if ("ACTIVE".equals(postPlanHeader.status())
                || "PARTIALLY_PLANNED".equals(postPlanHeader.status())) {
            // ADR-099：下层物料按计划产出量重算；已有自制锚点的物料需求变大时，
            // 锚点配额同步增长，车间桶的剩余可排量随之变大。
            // 预览还会把层级表上每个父行填的数量一起并进来(typedOutput)，于是
            // 中间层改量同样能把它自己的子层、孙层一路带大。
            analysisService.refreshWithAnchorGrowth(analysisId, Map.of(), typedOutputByMaterialLine);
        }
        recordCommand(analysisId, OP_GENERATE, request.idempotencyKey(), requestHash,
                Map.of("planIds", generated.stream().map(GeneratedPlan::planId).toList(),
                        "mergedPlanIds", generated.stream()
                                .filter(GeneratedPlan::mergedIntoExisting)
                                .map(GeneratedPlan::planId).toList()));
        return new GenerateResult(analysisService.detailInternal(analysisId, false), false,
                List.copyOf(generated));
    }

    /** ADR-104：可并入的既有计划(见 {@link #growablePlanFor})。 */
    private record GrowablePlan(
            UUID planId, String billNo, short status, UUID linkId, UUID planItemId,
            BigDecimal itemQty, BigDecimal submittedQty, BigDecimal surplusQty,
            UUID salesOrderItemId) {
    }

    /**
     * 同一分析行最近一张仍可并入的计划：库侧谓词 {@code fn_material_analysis_plan_growable}
     * (草稿或已审核、恰一条明细且累计全 0、没有报工/拆批、每段仍 WAITING/READY、备料单仍是
     * 未审核未发料的草稿)，再加两条应用侧口径——请求指定了生产车间时车间必须一致(换车间
     * = 另一张单)；没有「立即审核」的请求只并入草稿计划，不能把追加量悄悄并进一张已审核的
     * 计划绕过审核。找不到返回 null，由调用方照旧新建。
     */
    private GrowablePlan growablePlanFor(
            UUID analysisId, UUID analysisLineId, UUID departmentId, boolean approveNow) {
        return growablePlanFor(analysisId, analysisLineId, departmentId, approveNow, true);
    }

    /** [lock] = false 供下达预览(ADR-116): 同一谓词只读判定, 不锁计划行。 */
    private GrowablePlan growablePlanFor(
            UUID analysisId, UUID analysisLineId, UUID departmentId, boolean approveNow, boolean lock) {
        String sql = """
                SELECT plan.id, plan.bill_no, plan.status, link.id, item.id, item.qty,
                       link.submitted_qty, COALESCE(link.public_surplus_qty, 0), item.sales_order_item_id
                FROM production_plans plan
                JOIN production_material_analysis_plan_links link
                  ON link.plan_id = plan.id
                 AND link.analysis_id = plan.material_analysis_id
                 AND link.analysis_item_id = plan.material_analysis_item_id
                 AND link.allocation_status IN ('SUBMITTED', 'APPROVED')
                JOIN production_plan_items item
                  ON item.plan_id = plan.id AND item.is_deleted = FALSE
                WHERE plan.material_analysis_id = :analysisId
                  AND plan.material_analysis_item_id = :analysisLineId
                  AND fn_material_analysis_plan_growable(plan.id)
                """
                + (approveNow ? "" : "  AND plan.status = 0\n")
                + (departmentId == null ? "" : """
                  AND plan.department_id = :departmentId
                  AND NOT EXISTS (
                      SELECT 1 FROM production_execution_segments segment
                      WHERE segment.plan_id = plan.id AND NOT segment.is_deleted
                        AND segment.status NOT IN ('CANCELLED', 'REVERSED')
                        AND segment.workshop_department_id IS DISTINCT FROM CAST(:departmentId AS uuid))
                  """)
                + """
                ORDER BY link.created_at DESC, plan.id DESC
                LIMIT 1
                """ + (lock ? "FOR UPDATE OF plan, link, item\n" : "");
        var query = em.createNativeQuery(sql)
                .setParameter("analysisId", analysisId)
                .setParameter("analysisLineId", analysisLineId);
        if (departmentId != null) query.setParameter("departmentId", departmentId);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(query);
        if (rows.isEmpty()) return null;
        Object[] row = rows.getFirst();
        // A concurrent DRAW_REQUEST only changes the task, not the plan header.
        // After waiting for the plan lock, take a fresh READ COMMITTED snapshot
        // before changing any quantity; a newly executing plan must get a new order.
        if (lock && !Boolean.TRUE.equals(em.createNativeQuery(
                        "SELECT fn_material_analysis_plan_growable(CAST(:planId AS uuid))")
                .setParameter("planId", row[0]).getSingleResult())) return null;
        return new GrowablePlan((UUID) row[0], Objects.toString(row[1], null),
                ((Number) row[2]).shortValue(), (UUID) row[3], (UUID) row[4],
                decimalOf(row[5]), decimalOf(row[6]), decimalOf(row[7]), (UUID) row[8]);
    }

    private static BigDecimal decimalOf(Object value) {
        return value == null ? BigDecimal.ZERO : new BigDecimal(value.toString());
    }

    /**
     * ADR-104 并入追加：计划明细与关联行只增不减地改大(V645 放行；关联行触发器顺手把分析行的
     * submitted/approved 与版本推进)；草稿计划重排预排草案(立即审核时整张审核)，已审核计划先把
     * 销售分摊容量扩大，再同步增加原车间工单及其冻结物料需求。
     */
    private GeneratedPlan growPlan(
            UUID analysisId, ProductView product, GrowablePlan target, PlanQuantity quantity,
            PlanScheduleDefaults defaults, BigDecimal demandQty, BigDecimal surplusQty,
            IssueWorkshopPlansRequest request) {
        BigDecimal added = quantity.qty();
        int items = em.createNativeQuery("""
                        UPDATE production_plan_items
                        SET qty = qty + CAST(:added AS numeric),
                            updated_at = now(), updated_by = :actorId
                        WHERE id = :itemId AND plan_id = :planId AND is_deleted = FALSE
                          AND qty = CAST(:expectedQty AS numeric)
                        """)
                .setParameter("added", added)
                .setParameter("actorId", currentUser.requireId())
                .setParameter("itemId", target.planItemId())
                .setParameter("planId", target.planId())
                .setParameter("expectedQty", target.itemQty())
                .executeUpdate();
        if (items != 1) {
            throw conflict("「" + product.goodsName() + "」原计划 " + target.billNo()
                    + " 的数量已变化，请刷新后重试");
        }
        int links = em.createNativeQuery("""
                        UPDATE production_material_analysis_plan_links
                        SET submitted_qty = submitted_qty + CAST(:demandQty AS numeric),
                            public_surplus_qty = COALESCE(public_surplus_qty, 0) + CAST(:surplusQty AS numeric)
                        WHERE id = :linkId AND plan_id = :planId
                          AND submitted_qty = CAST(:expectedSubmitted AS numeric)
                          AND COALESCE(public_surplus_qty, 0) = CAST(:expectedSurplus AS numeric)
                        """)
                .setParameter("demandQty", demandQty)
                .setParameter("surplusQty", surplusQty)
                .setParameter("linkId", target.linkId())
                .setParameter("planId", target.planId())
                .setParameter("expectedSubmitted", target.submittedQty())
                .setParameter("expectedSurplus", target.surplusQty())
                .executeUpdate();
        if (links != 1) {
            throw conflict("「" + product.goodsName() + "」原计划 " + target.billNo()
                    + " 的关联数量已变化，请刷新后重试");
        }
        ProductionPlanItem managedItem = em.find(ProductionPlanItem.class, target.planItemId());
        if (managedItem != null) em.refresh(managedItem);
        if (target.status() == 0) {
            planningDrafts.supersedeActive(target.planId(), "物料分析追加数量并入后重排分段");
            PlanDetail plan = planService.detail(target.planId());
            ProductionPlanningDraftView draft = savePlanningDraft(
                    analysisId, product, plan, quantity, defaults, request.warehouseId());
            PlanningPackageResult applied = null;
            if (request.approveNow()) {
                planService.approve(plan.getId());
                applied = planningPackages.currentResult(plan.getId()).orElseThrow(() ->
                        conflict("生产计划已审核但正式计划包未生成，事务已回滚"));
            }
            return toGenerated(plan, draft, applied).merged(added);
        }
        if (target.salesOrderItemId() != null && demandQty.signum() > 0) {
            planService.growAnalysisPlanSalesAllocation(
                    target.planId(), target.planItemId(), demandQty);
        }
        executionPackages.growSegment(target.planId(),
                new com.uten.imp.features.production.mrp.ProductionExecutionPackageCommandService
                        .GrowSegmentRequest(
                        target.planItemId(), added,
                        target.salesOrderItemId() != null ? demandQty : BigDecimal.ZERO,
                        quantity.departmentId()));
        return generatedPlan(target.planId()).merged(added);
    }

    /**
     * 下达车间预览（ADR-099；ADR-116 起只读）：给出「按这批数量真实下达之后」的分析视图——
     * 下层需求、还需安排、锚点剩余全部按计划产出量重算。客户端据此在「父件 + 下层一起下单」
     * 页面和物料分析主表展示服务端算好的下层数量，不在浏览器里按单耗自行相乘。
     *
     * <p>{@link PreviewIssuePlansRequest#typedOutputs()} 是层级表上<b>每一行</b>输入框里的
     * 数量，按「计划产出量」并进重算——中间层改量、追加量同样带得动它自己的子层与孙层
     * (2026-09-21 用户口径)。{@code lines} 是本批真实要下达的行，可以为空(只重算)。</p>
     *
     * <p>2026-09-24(ADR-116) 起<b>不再真跑下达再回滚</b>：只读事务，不取分析锁、主仓协调锁
     * 或维度锁，不建计划/锚点/台账/命令记录。本批计划先按真实下达的同一套校验解析
     * (候选路线、锚点、可排产、ADR-104 并入)，再折成「下达后重读会多出来的事实」叠进
     * 内存投影，由与真实刷新同一套引擎、与 GET 详情同一个视图构建器算出结果。预览之间、
     * 预览与仓库命令之间不再互相排队或 409；幂等键不再使用(请求里保留字段只为兼容)。</p>
     */
    @Transactional(readOnly = true,
            isolation = org.springframework.transaction.annotation.Isolation.REPEATABLE_READ)
    public AnalysisView previewIssuePlans(UUID analysisId, PreviewIssuePlansRequest request) {
        if (request.lines().isEmpty() && request.typedOutputs().isEmpty()) {
            throw validation("预览至少要给出一行本批数量");
        }
        if (!request.lines().isEmpty()
                && !access.hasAuthority("production_material_analysis:generate")) {
            throw new ApiException(ErrorCode.FORBIDDEN, "预览下达车间需要生成生产计划权限");
        }
        Map<UUID, BigDecimal> typedOutputs = new LinkedHashMap<>();
        for (PreviewIssuePlansRequest.TypedOutput typed : request.typedOutputs()) {
            typedOutputs.merge(typed.materialLineId(), typed.qty(), BigDecimal::add);
        }
        MaterialAnalysisService.AnalysisHeader header = analysisService.readOnlyHeader(analysisId);
        requireNotFqcRecoveryWorkspace(analysisId);
        requireWritable(header, "只能从本人负责的物料分析下达车间");
        analysisService.requireCurrent(header, request.version(), request.fingerprint());
        if (!Objects.equals(header.warehouseId(), request.warehouseId())) {
            throw conflict("目标仓库与分析当前仓库不一致，请刷新后重试");
        }
        if (request.approveNow() && !access.hasAuthority("production_plan:approve")) {
            throw new ApiException(ErrorCode.FORBIDDEN, "生成并审核需要独立的生产计划审核权限");
        }
        MaterialAnalysisIssuePreviewOverlay overlay = MaterialAnalysisIssuePreviewOverlay.create();
        // 真实下达入口先按实况刷新一次(库存可能在上次刷新后被仓库命令改过)；预览同口径先投影
        // 「不含本批」的实况，锚点跟涨/跟落的基线、新锚点配额与可排产都以它为准。
        analysisService.projectIssuePreviewBase(analysisId, overlay);
        if (!request.lines().isEmpty()) {
            analysisService.addIssuePreviewSeeds(analysisId,
                    issuePreviewSeeds(analysisId, request.toIssueRequest(), overlay), request.approveNow(), overlay);
        }
        return analysisService.issuePreviewView(analysisId, overlay, Map.copyOf(typedOutputs));
    }

    /**
     * 把预览里的本批下达行按 {@link #issueWorkshopPlansInternal} 的同一套规则解析成
     * 「计划挂在哪一行、归需求多少、公共备货多少、是否并入既有计划」, 只读不写。
     * 真实下达会拒绝的行(路线不对、不可排产、候选已被在途覆盖)在这里同样拒绝。
     */
    private List<MaterialAnalysisService.IssuePreviewSeed> issuePreviewSeeds(
            UUID analysisId, IssueWorkshopPlansRequest request, MaterialAnalysisIssuePreviewOverlay overlay) {
        AnalysisView current = analysisService.issuePreviewDetail(analysisId, overlay);
        Map<UUID, String> candidateRoutes = candidateRoutesByMaterialLine(current);
        Map<UUID, UUID> goodsByMaterialLine = new HashMap<>();
        for (MaterialView material : current.flatMaterials()) {
            goodsByMaterialLine.putIfAbsent(material.materialLineId(), material.goodsId());
        }
        List<UUID> subcontractCandidateGoods = request.lines().stream()
                .map(IssueWorkshopPlansRequest.IssuePlanLine::materialLineId)
                .filter(Objects::nonNull)
                .filter(id -> "SUBCONTRACT".equals(candidateRoutes.get(id)))
                .map(goodsByMaterialLine::get).filter(Objects::nonNull).distinct().toList();
        Set<UUID> goodsWithMakeChildren = new HashSet<>(activeBomParentIds(subcontractCandidateGoods));
        goodsWithMakeChildren.removeAll(soleComponentSubcontractGoodsIds(subcontractCandidateGoods));
        List<UUID> makeLines = new ArrayList<>();
        for (IssueWorkshopPlansRequest.IssuePlanLine line : request.lines()) {
            if (line.materialLineId() == null) continue;
            String route = candidateRoutes.get(line.materialLineId());
            if (route == null) {
                throw validation("候选物料节点不存在或路线未确认，请刷新后重试");
            }
            if ("MAKE".equals(route)) {
                makeLines.add(line.materialLineId());
                continue;
            }
            if (!"SUBCONTRACT".equals(route)) {
                throw validation("只有自制路线的物料才能直接下达车间");
            }
            UUID goodsId = goodsByMaterialLine.get(line.materialLineId());
            if (goodsId == null || !goodsWithMakeChildren.contains(goodsId)) {
                throw validation("无自制子层、或只有一个直属子件（直接发子件给委外商）的委外件"
                        + "请走委外下达，不能直接建生产计划");
            }
        }
        // 与 ensureWorkshopChildAnchors 同口径的锚点安排：真实下达在建计划之前先新建锚点(初始配额
        // 计入父节点内部承诺)、给既有锚点补让料配额, 随后刷新一次。预览把同样的事实叠进投影再投一次。
        Map<UUID, BigDecimal> newAnchorQuota = new HashMap<>();
        boolean anchorsChanged = false;
        if (!makeLines.isEmpty()) {
            for (WorkshopAnchorDemand demand : workshopAnchorDemands(analysisId, current, makeLines)) {
                MaterialView representative = demand.group().materials().getFirst();
                String parentNodeRef = representative.analysisLineId() + "|" + representative.nodeKey();
                if (demand.existingAnchorId() == null) {
                    newAnchorQuota.put(representative.materialLineId(), demand.newQuota());
                    overlay.addInternalCommitment(parentNodeRef, demand.newQuota());
                    anchorsChanged = true;
                } else if (representative.priorityMakeSupplementQty().signum() > 0) {
                    BigDecimal supplement = representative.priorityMakeSupplementQty();
                    overlay.addSourceQuantities(demand.existingAnchorId(), supplement,
                            BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO);
                    overlay.addInternalCommitment(parentNodeRef, supplement);
                    anchorsChanged = true;
                }
            }
        }
        if (anchorsChanged) current = analysisService.reprojectIssuePreview(analysisId, overlay);
        Map<UUID, UUID> childLineByMaterialLine = batchChildLineIds(analysisId,
                request.lines().stream().map(IssueWorkshopPlansRequest.IssuePlanLine::materialLineId)
                        .filter(Objects::nonNull).collect(Collectors.toSet()));
        Map<UUID, ProductView> products = current.products().stream()
                .collect(Collectors.toMap(ProductView::analysisLineId, value -> value));
        Set<Object> seen = new HashSet<>();
        List<MaterialAnalysisService.IssuePreviewSeed> seeds = new ArrayList<>();
        PlanScheduleDefaults defaults = new PlanScheduleDefaults(request.billDate(), request.deliveryDate());
        for (IssueWorkshopPlansRequest.IssuePlanLine line : request.lines()) {
            UUID lineId = line.analysisLineId() != null
                    ? line.analysisLineId() : childLineByMaterialLine.get(line.materialLineId());
            validatePlanSchedule(new PlanQuantity(lineId, line.qty(), line.billDate(), line.deliveryDate(),
                    line.departmentId(), line.workshopName(), line.workerId(), line.teamDepartmentId(),
                    line.productNo()), defaults);
            if (lineId == null) {
                UUID material = line.materialLineId();
                boolean newAnchor = newAnchorQuota.containsKey(material)
                        || "SUBCONTRACT".equals(candidateRoutes.get(material));
                if (!newAnchor || !seen.add(material)) {
                    throw validation("物料库存或候选任务已变化，本次未下达；请点击刷新重新核对后再提交");
                }
                seeds.add(new MaterialAnalysisService.IssuePreviewSeed(null, material,
                        line.qty(), line.qty(), BigDecimal.ZERO, null, BigDecimal.ZERO));
                continue;
            }
            if (!seen.add(lineId)) {
                throw validation("物料库存或候选任务已变化，本次未下达；请点击刷新重新核对后再提交");
            }
            ProductView product = products.get(lineId);
            if (product == null) {
                throw validation("待生成计划产品不属于当前分析");
            }
            boolean surplusOnly = Boolean.TRUE.equals(line.publicSurplusOnly());
            if (!product.canSchedule()
                    && !(surplusOnly && product.canIssueSurplus() && line.qty().signum() > 0)) {
                throw conflict(product.scheduleBlockedReason() == null
                        ? "当前产品不可排产" : product.scheduleBlockedReason());
            }
            BigDecimal demandQty = line.qty().min(product.remainingQty());
            GrowablePlan growable = growablePlanFor(
                    analysisId, lineId, line.departmentId(), request.approveNow(), false);
            // ADR-104 并入一张草稿计划并立即审核: 审核把整条关联行(原已提交 + 本次)转成已审核。
            BigDecimal draftSubmitted = growable != null && growable.status() == 0
                    ? growable.submittedQty() : BigDecimal.ZERO;
            seeds.add(new MaterialAnalysisService.IssuePreviewSeed(lineId, null, line.qty(),
                    demandQty, line.qty().subtract(demandQty), growable == null ? null : growable.planId(),
                    draftSubmitted));
        }
        return seeds;
    }

    private Set<UUID> workshopSourceIds(UUID analysisId, IssueWorkshopPlansRequest request) {
        Set<UUID> sourceIds = request.lines().stream()
                .map(IssueWorkshopPlansRequest.IssuePlanLine::analysisLineId)
                .filter(Objects::nonNull).collect(Collectors.toCollection(LinkedHashSet::new));
        List<UUID> materialIds = request.lines().stream()
                .map(IssueWorkshopPlansRequest.IssuePlanLine::materialLineId)
                .filter(Objects::nonNull).distinct().toList();
        if (!materialIds.isEmpty()) sourceIds.addAll(NativeQueryResults.typedRows(em.createNativeQuery("""
                SELECT DISTINCT analysis_item_id FROM production_material_analysis_materials
                WHERE analysis_id=:analysisId AND id IN (:materialIds)
                """).setParameter("analysisId", analysisId).setParameter("materialIds", materialIds), UUID.class));
        return sourceIds;
    }

    /**
     * 下达车间的候选锚点（2026-09-05 简化）：按操作组只补建「剩余缺口」的
     * MAKE_COMPONENT 锚点行——不建 preplan action、不委托权益、不展开子树，
     * 物料行保持原位（计划员照常在采购/委外桶下达）。已有锚点只消费其
     * remainingQty，不从普通物理缺口再次增加来源需求；明确来源变更及V568
     * 有让料事实/净补供额度的追加责任例外，均保留独立证据。新锚点才按当前缺口建立需求。
     */
    private boolean ensureWorkshopChildAnchors(
            UUID analysisId, AnalysisView view, List<UUID> makeLineIds) {
        // 返回是否真的新建/增量了锚点行：调用方据此决定要不要补一次 refreshLocked
        // （既有锚点全部复用时快照未变，不必重算）。
        boolean changed = false;
        for (WorkshopAnchorDemand demand : workshopAnchorDemands(analysisId, view, makeLineIds)) {
            if (demand.existingAnchorId() != null) {
                MaterialView material=demand.group().materials().getFirst();
                if(material.priorityMakeSupplementQty().signum()>0) {
                    new PreplanReallocationMakeSupplement(em).append(analysisId,material.materialLineId(),
                            demand.existingAnchorId(),material.priorityMakeSupplementQty(),currentUser.requireId());
                    changed=true;
                }
                continue;
            }
            createOrIncrementMakeDemand(analysisId, demand.group(), demand.newQuota());
            changed = true;
        }
        return changed;
    }

    /** 一个候选操作组的锚点安排: 复用既有锚点, 或按剩余缺口新建(newQuota)。 */
    private record WorkshopAnchorDemand(ActionGroup group, UUID existingAnchorId, BigDecimal newQuota) {}

    /**
     * 候选锚点该怎么补(纯计算, 不写库): 真实下达据此建/加锚点, 下达预览(ADR-116)据此
     * 模拟新锚点的初始配额——两条路径同一套口径。缺口已被在途覆盖的组不建锚点, 不在结果里。
     */
    private List<WorkshopAnchorDemand> workshopAnchorDemands(
            UUID analysisId, AnalysisView view, List<UUID> makeLineIds) {
        List<ActionGroup> groups = selectedGroups(view, new NotifyRequest(
                null, null, "issue-anchor-" + analysisId, "MAKE",
                makeLineIds, null, null));
        Map<UUID, ProductView> products = view.products().stream()
                .collect(Collectors.toMap(ProductView::analysisLineId, product -> product));
        var coverage = supplyCoverage(analysisId, groups.stream()
                .filter(group -> group.materials().getFirst().planAnchorAnalysisLineId() == null)
                .toList());
        List<WorkshopAnchorDemand> result = new ArrayList<>();
        for (ActionGroup group : groups) {
            UUID anchorId = group.materials().getFirst().planAnchorAnalysisLineId();
            if (anchorId != null) {
                ProductView anchor = products.get(anchorId);
                if (anchor == null || !"MAKE_COMPONENT".equals(anchor.sourceType())) {
                    throw conflict("物料节点的计划锚点来源不一致，请刷新后核对路线");
                }
                result.add(new WorkshopAnchorDemand(group, anchorId, BigDecimal.ZERO));
                continue;
            }
            BigDecimal delta = group.demandRequiredQty()
                    .subtract(activeOpenActionQty(coverage, group))
                    .subtract(cancelledIqcReplacementInFlight(coverage, group))
                    .max(BigDecimal.ZERO)
                    .setScale(4, RoundingMode.CEILING);
            if (delta.signum() <= 0) continue;
            result.add(new WorkshopAnchorDemand(group, null, delta));
        }
        return result;
    }

    /**
     * 候选行的已确认路线（仅 actionable 物料节点）。自制根产品不是候选——它的
     * 产品行本身就是排产对象；确认为委外的根供给行可以是候选（ADR-099）：
     * 有自制子层的顶层委外件与中层同款，直接走 ARRANGE 建前置自制台账 +
     * 锚点 + 计划，不再需要客户端先走整量接管的通知通道。
     */
    private Map<UUID, String> candidateRoutesByMaterialLine(AnalysisView view) {
        return view.flatMaterials().stream()
                .filter(material -> material.actionable()
                        && (!"ROOT_SUPPLY".equals(material.nodeRole())
                            || "SUBCONTRACT".equals(material.sourceConfirmed())))
                .filter(material -> material.sourceConfirmed() != null)
                .collect(Collectors.toMap(MaterialView::materialLineId,
                        MaterialView::sourceConfirmed, (left, right) -> left));
    }

    /**
     * 批量解析候选物料对应的分析子件行 id（MAKE_COMPONENT / SUBCONTRACT_MAKE，按父锚点）：
     * parent_analysis_material_id → 子件 item id，一次 IN 查询替代逐行查询。
     * 唯一部分索引 uq_production_material_analysis_make_component_parent 保证每个父行
     * 至多一条未删除子件，故不需要 GROUP BY/聚合（也绕开 PostgreSQL 没有 min(uuid) 的坑）；
     * 同父多子件属数据异常，直接 409 而不是静默取一条。
     */
    private Map<UUID, UUID> batchChildLineIds(UUID analysisId, Set<UUID> materialLineIds) {
        if (materialLineIds.isEmpty()) {
            return Map.of();
        }
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT item.parent_analysis_material_id, item.id
                        FROM production_material_analysis_items item
                        WHERE item.analysis_id = :analysisId
                          AND item.parent_analysis_material_id IN (:materialLineIds)
                          AND item.source_type IN ('MAKE_COMPONENT', 'SUBCONTRACT_MAKE')
                          AND item.is_deleted = FALSE
                        """)
                        .setParameter("analysisId", analysisId)
                        .setParameter("materialLineIds", materialLineIds));
        Map<UUID, UUID> result = new HashMap<>();
        for (Object[] row : rows) {
            if (result.putIfAbsent((UUID) row[0], (UUID) row[1]) != null) {
                throw conflict("物料节点存在多条子件任务行，请刷新物料分析后核对");
            }
        }
        return result;
    }

    /** 计划级日期缺省（行内日期优先，缺省回退到本次下达的请求级日期）。 */
    private record PlanScheduleDefaults(LocalDate billDate, LocalDate deliveryDate) {
    }

    private static String issueHash(UUID analysisId, IssueWorkshopPlansRequest request) {
        List<String> parts = new ArrayList<>(List.of(
                "ISSUE-WORKSHOP-PLANS-V1", analysisId.toString(),
                Long.toString(request.version()), request.fingerprint(),
                request.warehouseId().toString(), request.billDate().toString(),
                Objects.toString(request.deliveryDate(), ""),
                Boolean.toString(request.approveNow())));
        request.lines().forEach(line -> {
            String itemHash = "LINE|" + Objects.toString(line.materialLineId(), "")
                    + "|" + Objects.toString(line.analysisLineId(), "")
                    + "|" + MaterialAnalysisService.decimalText(line.qty())
                    + "|" + Objects.toString(line.billDate(), "")
                    + "|" + Objects.toString(line.deliveryDate(), "")
                    + "|" + Objects.toString(line.departmentId(), "")
                    + "|" + Objects.toString(line.workshopName(), "")
                    + "|" + Objects.toString(line.workerId(), "")
                    + "|" + Objects.toString(line.teamDepartmentId(), "");
            String productNo = MaterialAnalysisService.blankToNull(line.productNo());
            if (productNo != null) {
                itemHash += "|PRODUCT_NO|" + productNo.length() + ":" + productNo;
            }
            parts.add(itemHash);
        });
        return PlanningPackageFingerprint.sha256(parts);
    }


    @Transactional
    public AnalysisView revokeRootOutput(UUID analysisId, UUID eventId, CancelRequest request) {
        tx.bind();
        var mutationGuard = lockAnalysisInventoryDimensions(analysisId);
        MaterialAnalysisService.AnalysisHeader header=analysisService.headerAfterPrelock(analysisId);
        requireWritable(header,"只能撤回本人负责的根产品现货交接");
        if (!access.hasAuthority("production_material_analysis:notify") || rootSupply==null) {
            throw new ApiException(ErrorCode.FORBIDDEN,"撤回根产品现货交接需要备料下达权限");
        }
        String hash=PlanningPackageFingerprint.sha256(List.of("ROOT_OUTPUT_REVOKE",
                analysisId.toString(),eventId.toString(),Long.toString(request.version()),
                request.fingerprint(),request.effectiveReason()));
        if (commandReplay(analysisId,"ROOT_OUTPUT_REVOKE",request.idempotencyKey(),hash)!=null) {
            return analysisService.detailInternal(analysisId,false);
        }
        if (!List.of("ACTIVE","PARTIALLY_PLANNED","COMPLETED").contains(header.status())
                || request.version()==null || request.version()!=header.version()
                || request.fingerprint()==null || !request.fingerprint().equalsIgnoreCase(header.fingerprint())) {
            throw conflict("物料分析或交接状态已变化，请刷新后再撤回");
        }
        mutationGuard.verifyUnchanged();
        rootSupply.revokeExistingOutput(analysisId,eventId,request.effectiveReason());
        analysisService.refreshLocked(analysisId);
        recordCommand(analysisId,"ROOT_OUTPUT_REVOKE",request.idempotencyKey(),hash,Map.of("eventId",eventId));
        return analysisService.detailInternal(analysisId,false);
    }

    @Transactional
    public AnalysisView cancelAction(
            UUID analysisId, UUID actionId, CancelRequest request) {
        tx.bind();
        var mutationGuard = lockAnalysisInventoryDimensions(analysisId);
        MaterialAnalysisService.AnalysisHeader header = analysisService.headerAfterPrelock(analysisId);
        requireWritable(header, "只能撤回本人负责的物料分析备料任务");
        String operationType = Objects.toString(em.createNativeQuery("""
                SELECT operation_type FROM preplan_supply_actions
                WHERE id = :actionId AND analysis_id = :analysisId
                """).setParameter("actionId", actionId)
                .setParameter("analysisId", analysisId)
                .getSingleResult(), "SUPPLY");
        if ("SHARED_FUTURE_CLAIM".equals(operationType)) {
            if (!access.hasAuthority(
                    "production_material_analysis:claim_shared_future")) {
                throw new ApiException(ErrorCode.FORBIDDEN,
                        "撤回公共在途采用需要对应采用权限");
            }
        } else if (!access.hasAuthority("production_material_analysis:notify")) {
            throw new ApiException(ErrorCode.FORBIDDEN,
                    "撤回普通备料任务需要备料下达权限");
        }
        String hash = PlanningPackageFingerprint.sha256(List.of(
                OP_CANCEL_ACTION, analysisId.toString(), actionId.toString(),
                Long.toString(request.version()), request.fingerprint(), request.effectiveReason()));
        CommandReplay replay = commandReplay(analysisId, OP_CANCEL_ACTION,
                request.idempotencyKey(), hash);
        if (replay != null) {
            return analysisService.detailInternal(analysisId, false);
        }
        mutationGuard.verifyUnchanged();
        analysisService.requireCurrent(header, request.version(), request.fingerprint());
        List<UUID> cancelledActionIds = cancelActionLocked(analysisId, actionId, request.effectiveReason());
        analysisService.refreshLocked(analysisId);
        recordCommand(analysisId, OP_CANCEL_ACTION, request.idempotencyKey(), hash,
                Map.of("actionIds", cancelledActionIds));
        return analysisService.detailInternal(analysisId, false);
    }

    @Transactional
    public AnalysisView cancelAnalysis(UUID analysisId, CancelRequest request) {
        tx.bind();
        var mutationGuard = lockAnalysisInventoryDimensions(analysisId);
        MaterialAnalysisService.AnalysisHeader header = analysisService.headerAfterPrelock(analysisId);
        requireWritable(header, "只能取消本人负责的物料分析");
        String hash = PlanningPackageFingerprint.sha256(List.of(
                OP_CANCEL_ANALYSIS, analysisId.toString(), Long.toString(request.version()),
                request.fingerprint(), request.effectiveReason()));
        CommandReplay replay = commandReplay(analysisId, OP_CANCEL_ANALYSIS,
                request.idempotencyKey(), hash);
        if (replay != null) {
            return analysisService.detailInternal(analysisId, false);
        }
        mutationGuard.verifyUnchanged();
        analysisService.requireCurrent(header, request.version(), request.fingerprint());
        if (rootSupply != null) rootSupply.requireAnalysisCancellationSafe(analysisId);
        subcontractPreparationHandoffs.requireSourceAnalysisCancellationSafe(
                analysisId);
        Number planned = (Number) em.createNativeQuery("""
                SELECT COUNT(*) FROM production_material_analysis_plan_links
                WHERE analysis_id = :id
                  AND allocation_status IN ('SUBMITTED','APPROVED')
                """).setParameter("id", analysisId).getSingleResult();
        if (planned.longValue() > 0) {
            throw conflict("分析已有待审核或已审核生产计划，必须先删除、驳回或红冲计划");
        }
        subcontractPreparationHandoffs.restoreForTargetAnalysis(
                analysisId, request.idempotencyKey());
        @SuppressWarnings("unchecked")
        List<UUID> actionIds = (List<UUID>) em.createNativeQuery("""
                SELECT id FROM preplan_supply_actions
                WHERE analysis_id = :id AND status IN ('OPEN','CREATED','IN_PROGRESS')
                ORDER BY CASE WHEN route = 'MAKE' THEN 0 ELSE 1 END,
                         created_at DESC, id DESC
                FOR UPDATE
                """).setParameter("id", analysisId).getResultList();
        for (UUID actionId : actionIds) {
            cancelActionLocked(analysisId, actionId, request.effectiveReason());
        }
        // 兜底清扫：自制备料入库绑定的预留锚点是生产计划行（不在行动外部明细上），
        // 连同其它遗留生效预留一并释放回公共现货池（V298）。
        analysisPeg.releaseForAnalysis(
                analysisId, request.effectiveReason(), request.idempotencyKey());
        em.createNativeQuery("""
                UPDATE production_material_analyses
                SET status = 'CANCELLED', cancelled_by = :actorId,
                    cancelled_at = now(), cancellation_reason = :reason,
                    version = version + 1, preview_fingerprint = NULL,
                    updated_at = now(), updated_by = :actorId
                WHERE id = :id
                """)
                .setParameter("actorId", currentUser.requireId())
                .setParameter("reason", request.effectiveReason())
                .setParameter("id", analysisId)
                .executeUpdate();
        recordCommand(analysisId, OP_CANCEL_ANALYSIS, request.idempotencyKey(), hash,
                Map.of("analysisId", analysisId));
        return analysisService.detailInternal(analysisId, false);
    }

    /**
     * 商业来源 -> 全部库存 -> 所有主仓协调器 -> 全部分析头 -> action/reservation。
     * IQC PASS 也先持有同一 inventory advisory lock，再锁供应分摊行；这样取消、
     * 计划生成与合格入库不会形成 action->inventory / inventory->action 反序。
     */
    com.uten.imp.application.concurrency.FulfillmentMutationLocks.Guard lockAnalysisInventoryDimensions(UUID analysisId) {
        return mutationLocks.acquire(
                com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.declaredAnalyses(List.of(analysisId)),
                () -> mutationFootprints.forAnalyses(List.of(analysisId)));
    }

    /**
     * 本分析 + 它可认领的同主仓公共在途(别的分析名下的申请/委外申请)的合并足迹。
     *
     * <p>ADR-099 的外部路线下达会先自动认领公共在途, 认领引用的是别的分析的单据,
     * 必须与本分析一起预锁。**凡是可能嵌套进 notifySupplyInternal 的入口都要用这一份**:
     * 预锁一旦 prepared, 嵌套的 acquire 只做覆盖检查(requireCovered), 不允许持锁补拿;
     * 外层若只锁了本分析, 嵌套那腿的合并足迹必然超出, 抛可重跑冲突, 再被最外层的自动
     * 重跑放大成 5 次同样的确定性失败, 最后仍是 409。2026-09-21 发布前审查实测:
     * issueWorkshopPlans 的 ARRANGE 腿(委外件有自制子层时建台账)正是这条路径,
     * 同主仓一旦存在可认领的公共在途, 下达车间与「父件+下层一起下单」的预览必挂。</p>
     */
    com.uten.imp.application.concurrency.FulfillmentMutationLocks.Guard lockAnalysisWithClaimableShared(UUID analysisId) {
        return mutationLocks.acquire(
                com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.declaredAnalyses(List.of(analysisId)), () -> {
            var own = mutationFootprints.forAnalyses(List.of(analysisId));
            var claimable = mutationFootprints.forSharedFutureClaim(analysisId);
            return com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.merge(
                    own.fingerprint() + "|" + claimable.fingerprint(), List.of(own, claimable));
        });
    }

    /**
     * A V414 FQC replenishment analysis is a recovery-only BOM workspace.
     * V415 is the sole authority that turns it into exact recovery demands;
     * ordinary notify/generate would create a second top-level plan or supply
     * chain for the same failed quantity.
     */
    private void requireNotFqcRecoveryWorkspace(UUID analysisId) {
        Number linked = (Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM production_fqc_replenishment_analysis_links link
                        WHERE link.material_analysis_id = :analysisId
                        """)
                .setParameter("analysisId", analysisId)
                .getSingleResult();
        if (linked != null && linked.longValue() > 0) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "该物料分析仅用于 FQC 补产 BOM 冻结；请在 FQC 补产待办确认物料方案，禁止重复生成普通计划或供给单");
        }
    }

    private List<ActionGroup> selectedGroups(AnalysisView view, NotifyRequest request) {
        Map<String, List<MaterialView>> allGroups = view.flatMaterials().stream()
                .filter(material -> material.actionable() || "ROOT_SUPPLY".equals(material.nodeRole()))
                .collect(Collectors.groupingBy(MaterialView::actionGroupKey,
                        LinkedHashMap::new, Collectors.toList()));
        Set<String> selected = new LinkedHashSet<>();
        if (request.actionGroupKeys() != null) selected.addAll(request.actionGroupKeys());
        if (request.materialLineIds() != null) {
            Map<UUID, String> lineGroups = view.flatMaterials().stream()
                    .filter(material -> material.actionable() || "ROOT_SUPPLY".equals(material.nodeRole())).collect(
                    Collectors.toMap(MaterialView::materialLineId,
                            MaterialView::actionGroupKey));
            for (UUID lineId : request.materialLineIds()) {
                String group = lineGroups.get(lineId);
                if (group == null) throw validation("通知物料节点不存在或已过期");
                selected.add(group);
            }
        }
        if (selected.isEmpty()) {
            throw validation("至少选择一个物料操作组");
        }
        if (selected.size() > RequestLimits.DOCUMENT_LINES) {
            throw validation("一次通知最多包含 " + RequestLimits.DOCUMENT_LINES
                    + " 个去重后的物料操作任务，当前为 " + selected.size()
                    + " 个；请分批选择后重试");
        }
        String target = request.target() == null ? null
                : MaterialAnalysisService.normalizeRoute(request.target());
        Map<UUID, LocalDate> needDates = new HashMap<>();
        Map<UUID, Integer> allocationPriorities = new HashMap<>();
        view.products().forEach(product ->
                needDates.put(product.analysisLineId(), product.deliveryDate()));
        view.products().forEach(product -> allocationPriorities.put(
                product.analysisLineId(), product.allocationPriority()));
        List<ActionGroup> result = new ArrayList<>();
        for (String key : selected) {
            List<MaterialView> lines = allGroups.get(key);
            if (lines == null || lines.isEmpty()) throw validation("物料操作组不存在或已过期");
            for (MaterialView line : lines) {
                String reason = view.planningBlockedReasons().get(line.analysisLineId());
                if (reason != null) throw conflict(reason);
            }
            if (lines.stream().flatMap(line -> line.downstreamReferences().stream())
                    .anyMatch(DownstreamReference::notificationReversalPending)) {
                throw conflict("该物料有历史委外通知待同步撤回，请先在详情完成同步后再下达");
            }
            Set<String> routes = lines.stream().map(MaterialView::sourceConfirmed)
                    .filter(Objects::nonNull).collect(Collectors.toSet());
            if (routes.size() != 1 || lines.stream().anyMatch(line -> !line.routeConfirmed())) {
                throw conflict("通知前必须确认操作组内全部物料路线");
            }
            String route = routes.iterator().next();
            // MAKE and a SUBCONTRACT item with an own-supply BOM may create
            // their explicit child task before lower-level materials arrive.
            // The child can then be assigned to a workshop; approval creates a
            // WAITING segment (zero reservation, no DRAW) until its own direct
            // materials are complete.  lowerLevelPending remains a diagnostic,
            // never an implicit create or a notification side effect.
            if (target != null && !target.equals(route)) {
                throw validation("所选物料路线与通知目标不一致");
            }
            MaterialView first = lines.getFirst();
            MaterialDimension dimension = new MaterialDimension(
                    first.goodsId(), first.colorId(), first.unitId());
            if (lines.stream().anyMatch(line -> !dimension.equals(new MaterialDimension(
                    line.goodsId(), line.colorId(), line.unitId())))) {
                throw conflict("物料操作组维度不一致，请刷新分析");
            }
            BigDecimal required = lines.stream().map(MaterialView::demandSupplyGapQty)
                    .reduce(BigDecimal.ZERO, BigDecimal::add)
                    .setScale(4, RoundingMode.CEILING);
            result.add(new ActionGroup(key, route, dimension,
                    allocationPriorities.getOrDefault(first.analysisLineId(), Integer.MAX_VALUE),
                    needDates.get(first.analysisLineId()), required, List.copyOf(lines)));
        }
        result.sort(Comparator.comparingInt(ActionGroup::sourcePriority)
                .thenComparing(ActionGroup::needDate,
                        Comparator.nullsLast(Comparator.naturalOrder()))
                .thenComparing(ActionGroup::groupKey));
        return List.copyOf(result);
    }

    /**
     * 解析「指定提交数量」：按操作组归集（materialLineId 先翻译成所属操作组），
     * 只允许覆盖本次选中的组；数量合法性与实时余量在 notifySupply 主循环复核。
     */
    private Map<String, SupplyQuantityInput> quantityInputs(
            AnalysisView view, NotifyRequest request, List<ActionGroup> selected) {
        if (request.quantities() == null || request.quantities().isEmpty()) {
            return Map.of();
        }
        Map<UUID, String> lineGroups = view.flatMaterials().stream()
                .filter(material -> material.actionable() || "ROOT_SUPPLY".equals(material.nodeRole()))
                .collect(Collectors.toMap(MaterialView::materialLineId,
                        MaterialView::actionGroupKey));
        Set<String> selectedKeys = selected.stream()
                .map(ActionGroup::groupKey).collect(Collectors.toSet());
        Map<String, SupplyQuantityInput> result = new LinkedHashMap<>();
        for (SupplyQuantityInput input : request.quantities()) {
            String key = MaterialAnalysisService.blankToNull(input.actionGroupKey());
            if (key == null && input.materialLineId() != null) {
                key = lineGroups.get(input.materialLineId());
            }
            if (key == null) {
                throw validation("提交数量的物料不存在或已过期，请刷新后重试");
            }
            if (!selectedKeys.contains(key)) {
                throw validation("提交数量与所选物料不匹配，请刷新后重试");
            }
            if (result.putIfAbsent(key, input) != null) {
                throw validation("同一物料的提交数量重复，请刷新后重试");
            }
        }
        return result;
    }

    /** One authoritative main-warehouse budget, repeated on each path of this material group. */
    static SafetySnapshot groupSafetySnapshot(List<MaterialView> materials) {
        if (materials.isEmpty() || materials.stream().anyMatch(material ->
                material.mainWarehousePublicAvailableQty() == null
                        || material.mainWarehouseOpenSafetySupplyQty() == null
                        || material.mainWarehouseSafetyReplenishmentGapQty() == null
                        || material.safetyStockQty() == null)) {
            throw conflict("主仓安全库存汇总缺失，请刷新物料分析后重试");
        }
        if (materials.stream().anyMatch(material ->
                material.mainWarehousePublicAvailableQty().signum() < 0
                        || material.mainWarehouseOpenSafetySupplyQty().signum() < 0
                        || material.mainWarehouseSafetyReplenishmentGapQty().signum() < 0
                        || material.safetyStockQty().signum() < 0)) {
            throw conflict("主仓安全库存汇总无效，请刷新物料分析后重试");
        }
        BigDecimal safetyStock = materials.stream()
                .map(MaterialView::safetyStockQty)
                .reduce(BigDecimal.ZERO, BigDecimal::max)
                .setScale(4, RoundingMode.CEILING);
        MaterialView first = materials.getFirst();
        BigDecimal publicAvailable = first.mainWarehousePublicAvailableQty()
                .setScale(4, RoundingMode.DOWN);
        BigDecimal openSupply = first.mainWarehouseOpenSafetySupplyQty()
                .setScale(4, RoundingMode.DOWN);
        BigDecimal gap = MaterialAnalysisService.publicSafetyReplenishmentGap(
                safetyStock, publicAvailable, openSupply);
        boolean inconsistent = materials.stream().anyMatch(material ->
                material.mainWarehousePublicAvailableQty().compareTo(publicAvailable) != 0
                        || material.mainWarehouseOpenSafetySupplyQty().compareTo(openSupply) != 0
                        || material.mainWarehouseSafetyReplenishmentGapQty().compareTo(gap) != 0);
        if (inconsistent) {
            throw conflict("公共安全库存补库快照不一致，请刷新后重试");
        }
        return new SafetySnapshot(safetyStock, publicAvailable, openSupply, gap);
    }

    /** 操作组的可读标签（货品名/编码），用于数量校验报错时指认是哪一件料。 */
    private static String groupLabel(ActionGroup group) {
        MaterialView first = group.materials().getFirst();
        String name = MaterialAnalysisService.blankToNull(first.goodsName());
        if (name != null) return name;
        String code = MaterialAnalysisService.blankToNull(first.goodsCode());
        return code == null ? "该物料" : code;
    }

    private void allocateAction(
            UUID actionId, UUID analysisId, List<MaterialView> materials, BigDecimal qty) {
        BigDecimal total = materials.stream().map(MaterialView::demandSupplyGapQty)
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal remaining = qty;
        List<MaterialView> positive = materials.stream()
                .filter(material -> material.demandSupplyGapQty().signum() > 0).toList();
        for (int index = 0; index < positive.size(); index++) {
            MaterialView material = positive.get(index);
            BigDecimal allocated = index == positive.size() - 1
                    ? remaining
                    : qty.multiply(material.demandSupplyGapQty()).divide(
                            total, 4, RoundingMode.DOWN).min(remaining);
            if (allocated.signum() <= 0) continue;
            em.createNativeQuery("""
                    INSERT INTO preplan_supply_action_allocations (
                        id, analysis_id, action_id, analysis_material_id,
                        allocated_qty, created_by
                    ) VALUES (
                        :id, :analysisId, :actionId, :materialId, :qty, :actorId
                    )
                    """)
                    .setParameter("id", UUID.randomUUID())
                    .setParameter("analysisId", analysisId)
                    .setParameter("actionId", actionId)
                    .setParameter("materialId", material.materialLineId())
                    .setParameter("qty", allocated)
                    .setParameter("actorId", currentUser.requireId())
                    .executeUpdate();
            remaining = remaining.subtract(allocated);
        }
        if (remaining.signum() != 0) {
            throw conflict("备料任务节点分摊数量不守恒");
        }
    }

    /**
     * ADR-065：一次通知的外部单据聚合预建。
     * 全部 BUY 行合并为一张采购申请（每 action 一条需求明细，安全库存补库单独成行）；
     * 全部无子层 SUBCONTRACT 行合并为一张委外申请。表头需求日期取各行最早日期，
     * 明细交期仍逐行保留各自操作组的 need_date。
     */
    private PreparedExternalDocuments prepareExternalDocuments(
            UUID analysisId, List<ActionDraft> created,
            Set<UUID> subcontractMakeFirst) {
        UUID employeeId = currentUser.requireEmployeeId();
        // 来源单据展示可读标签（计划前物料分析 + 分析日期），不再把分析 UUID 暴露给单据号/备注；
        // 谱系回溯改走 materialAnalysisId，与展示解耦。analyzed_at 实时查（refreshLocked 会推进）。
        // analyzed_at 是 TIMESTAMPTZ：Hibernate 6 原生查询按配置可能返回
        // Timestamp/OffsetDateTime/Instant（Testcontainers 下实测返回 Instant），
        // 强转 java.sql.Timestamp 会 CCE——逐类型归一到 Instant 再转上海日期。
        Object rawAnalyzedAt = em.createNativeQuery("""
                SELECT analyzed_at FROM production_material_analyses WHERE id = :id
                """)
                .setParameter("id", analysisId)
                .getSingleResult();
        java.time.Instant analyzedInstant;
        if (rawAnalyzedAt instanceof java.sql.Timestamp t) {
            analyzedInstant = t.toInstant();
        } else if (rawAnalyzedAt instanceof java.time.OffsetDateTime o) {
            analyzedInstant = o.toInstant();
        } else if (rawAnalyzedAt instanceof java.time.Instant i) {
            analyzedInstant = i;
        } else {
            throw new IllegalStateException(
                    "analyzed_at 返回了未支持的类型：" + rawAnalyzedAt.getClass().getName());
        }
        String sourceLabel = "计划前物料分析 "
                + analyzedInstant.atZone(BusinessTime.ZONE).toLocalDate();

        List<ProductionPurchaseRequestFacade.DraftLine> buyLines = new ArrayList<>();
        LocalDate purchaseNeedDate = null;
        List<ProductionSubcontractRequestPort.DraftLine> subcontractLines = new ArrayList<>();
        LocalDate subcontractNeedDate = null;
        Set<UUID> subcontractLeafActionIds = new LinkedHashSet<>();
        for (ActionDraft action : created) {
            LocalDate needDate = action.group().needDate();
            if ("BUY".equals(action.group().route())) {
                if (action.demandQty().signum() > 0
                        && action.publicExtraQty().signum() > 0) {
                    // 2026-09-15 用户口径「直接显示下达 5000，不是 1000 一条 4000 一条」：
                    // 需求片与公共超量片合成一条申请明细。锁定面不动——allocation
                    // 仍只分摊需求片，coverage/撤回按 action.requested_qty 走，
                    // 公共片经 markCreated 的 public_surplus_external_item_id 指回
                    // 同一条明细（fn_preplan_direct_overorder_capacity 的「需求件
                    // 同件超量」口径原生支持该形态）。
                    buyLines.add(new ProductionPurchaseRequestFacade.DraftLine(
                            action.actionId(), action.group().dimension().goodsId(),
                            action.group().dimension().colorId(),
                            action.group().dimension().unitId(),
                            action.demandQty().add(action.publicExtraQty()),
                            needDate, "生产需求精确备料+主动公共备货"));
                } else {
                    if (action.demandQty().signum() > 0) {
                        buyLines.add(new ProductionPurchaseRequestFacade.DraftLine(
                                action.actionId(), action.group().dimension().goodsId(),
                                action.group().dimension().colorId(),
                                action.group().dimension().unitId(), action.demandQty(),
                                needDate, "生产需求精确备料"));
                    }
                    if (action.publicExtraQty().signum() > 0) {
                        buyLines.add(new ProductionPurchaseRequestFacade.DraftLine(
                                action.publicSurplusSliceId(),
                                action.group().dimension().goodsId(),
                                action.group().dimension().colorId(),
                                action.group().dimension().unitId(),
                                action.publicExtraQty(), needDate,
                                "主动公共备货(不绑定来源物料分析)"));
                    }
                }
                if (action.safetyQty().signum() > 0) {
                    buyLines.add(new ProductionPurchaseRequestFacade.DraftLine(
                            action.safetySliceId(), action.group().dimension().goodsId(),
                            action.group().dimension().colorId(),
                            action.group().dimension().unitId(), action.safetyQty(),
                            needDate, "公共安全库存补库(不绑定单一物料分析)"));
                }
                purchaseNeedDate = earliest(purchaseNeedDate, needDate);
            } else if ("SUBCONTRACT".equals(action.group().route())
                    && !subcontractMakeFirst.contains(action.group().dimension().goodsId())) {
                subcontractLeafActionIds.add(action.actionId());
                if (action.demandQty().signum() > 0
                        && action.publicExtraQty().signum() > 0) {
                    // 同 BUY：需求片与公共超量片合成一条委外申请明细（2026-09-15）。
                    subcontractLines.add(new ProductionSubcontractRequestPort.DraftLine(
                            action.actionId(), action.group().dimension().goodsId(),
                            action.group().dimension().colorId(),
                            action.group().dimension().unitId(),
                            action.demandQty().add(action.publicExtraQty()),
                            needDate, "计划前物料分析委外备料+主动公共委外备货"));
                } else {
                    if (action.demandQty().signum() > 0) {
                        subcontractLines.add(new ProductionSubcontractRequestPort.DraftLine(
                                action.actionId(), action.group().dimension().goodsId(),
                                action.group().dimension().colorId(),
                                action.group().dimension().unitId(), action.demandQty(),
                                needDate, "计划前物料分析委外备料"));
                    }
                    if (action.publicExtraQty().signum() > 0) {
                        subcontractLines.add(new ProductionSubcontractRequestPort.DraftLine(
                                action.publicSurplusSliceId(),
                                action.group().dimension().goodsId(),
                                action.group().dimension().colorId(),
                                action.group().dimension().unitId(),
                                action.publicExtraQty(), needDate,
                                "主动公共委外备货(不绑定来源物料分析)"));
                    }
                }
                subcontractNeedDate = earliest(subcontractNeedDate, needDate);
            }
        }
        UUID warehouseId = selectedWarehouse(analysisId);
        ProductionPurchaseRequestFacade.DraftResult purchase = buyLines.isEmpty() ? null
                : purchaseRequests.createProductionDraft(
                        sourceLabel, analysisId, purchaseNeedDate, warehouseId,
                        List.copyOf(buyLines), employeeId, employeeId);
        ProductionSubcontractRequestPort.DraftResult subcontract = subcontractLines.isEmpty() ? null
                : subcontractRequests.createProductionDraft(
                        sourceLabel, analysisId, subcontractNeedDate, warehouseId,
                        List.copyOf(subcontractLines), employeeId, employeeId);
        return new PreparedExternalDocuments(
                purchase, subcontract, Set.copyOf(subcontractLeafActionIds));
    }

    private static LocalDate earliest(LocalDate current, LocalDate candidate) {
        if (candidate == null) return current;
        return current == null || candidate.isBefore(current) ? candidate : current;
    }

    private void createExternalDocument(
            UUID analysisId, ActionDraft action, PreparedExternalDocuments prepared) {
        if ("BUY".equals(action.group().route())) {
            ProductionPurchaseRequestFacade.DraftResult result = prepared.purchaseRequest();
            Map<UUID, ProductionPurchaseRequestFacade.DraftLineResult> bySlice =
                    result == null ? Map.of() : result.lines().stream().collect(
                            Collectors.toMap(
                                    ProductionPurchaseRequestFacade.DraftLineResult::demandId,
                                    value -> value));
            UUID demandItemId = action.demandQty().signum() > 0
                    ? Optional.ofNullable(bySlice.get(action.actionId()))
                            .map(ProductionPurchaseRequestFacade.DraftLineResult::requestItemId)
                            .orElseThrow(() -> conflict("采购申请缺少生产需求精确备料明细"))
                    : null;
            UUID safetyItemId = action.safetyQty().signum() > 0
                    ? Optional.ofNullable(bySlice.get(action.safetySliceId()))
                            .map(ProductionPurchaseRequestFacade.DraftLineResult::requestItemId)
                            .orElseThrow(() -> conflict("采购申请缺少公共安全库存补库明细"))
                    : null;
            UUID publicSurplusItemId = action.publicExtraQty().signum() > 0
                    ? Optional.ofNullable(bySlice.get(action.publicSurplusSliceId()))
                            .map(ProductionPurchaseRequestFacade.DraftLineResult::requestItemId)
                            // 合并明细形态（2026-09-15）：公共片与需求片同一条申请行。
                            .orElseGet(() -> Optional.ofNullable(bySlice.get(action.actionId()))
                                    .map(ProductionPurchaseRequestFacade.DraftLineResult::requestItemId)
                                    .orElseThrow(() -> conflict("采购申请缺少主动公共备货明细")))
                    : null;
            markCreated(action.actionId(), "PURCHASE_REQUEST", result.requestId(),
                    result.billNo(), demandItemId, safetyItemId,
                    publicSurplusItemId);
            return;
        }
        if ("SUBCONTRACT".equals(action.group().route())) {
            // V458：有子层级的委外件不在此刻生成委外申请（不通知委外部）。
            // 先在原分析内创建前置自制任务，待自制成品入库后按账本
            // 满批自动/手动分批生成委外申请。
            if (!prepared.subcontractLeafActionIds().contains(action.actionId())) {
                createSubcontractMakeTask(analysisId, action);
                return;
            }
            ProductionSubcontractRequestPort.DraftResult result =
                    prepared.subcontractApplication();
            ProductionSubcontractRequestPort.DraftLineResult demandLine =
                    action.demandQty().signum() > 0
                    ? result.lines().stream()
                            .filter(candidate -> action.actionId().equals(candidate.demandId()))
                            .findFirst()
                            .orElseThrow(() -> conflict(
                                    "委外申请缺少计划前物料分析备料明细"))
                    : null;
            ProductionSubcontractRequestPort.DraftLineResult publicLine =
                    action.publicExtraQty().signum() > 0
                    ? result.lines().stream()
                            .filter(candidate -> action.publicSurplusSliceId()
                                    .equals(candidate.demandId()))
                            .findFirst()
                            // 合并明细形态（2026-09-15）：公共片与需求片同一条申请行。
                            .orElseGet(() -> result.lines().stream()
                                    .filter(candidate -> action.actionId()
                                            .equals(candidate.demandId()))
                                    .findFirst()
                                    .orElseThrow(() -> conflict(
                                            "委外申请缺少主动公共备货明细")))
                    : null;
            markCreated(action.actionId(), "SUBCONTRACT_APPLICATION",
                    result.applicationId(), result.billNo(),
                    demandLine == null ? null : demandLine.applicationItemId(), null,
                    publicLine == null ? null : publicLine.applicationItemId());
            return;
        }
        UUID childItemId = createOrIncrementMakeDemand(analysisId, action);
        markCreated(action.actionId(), "PREPLAN_MAKE_TASK", childItemId,
                makeDemandSourceRef(childItemId), childItemId, null, null);
    }

    /** 自制备料需求行的可读来源编号（自制备料 日期 尾码）：面向展示，禁止 UUID。 */    private String makeDemandSourceRef(UUID itemId) {
        // 单列原生查询返回标量（String）而非 Object[]，不能走 oneRow 的
        // objectArrayRows 路径（会 CCE）；getResultList 空表时转业务 notFound。
        List<?> rows = em.createNativeQuery("""
                SELECT source_ref FROM production_material_analysis_items WHERE id = :id
                """).setParameter("id", itemId).getResultList();
        if (rows.isEmpty()) throw MaterialAnalysisService.notFound("自制备料需求不存在");
        return MaterialAnalysisService.string(rows.getFirst());
    }

    private UUID createOrIncrementMakeDemand(UUID analysisId, ActionDraft action) {
        return createOrIncrementMakeDemand(
                analysisId, action.group(), action.demandQty());
    }

    /** 锚点行按组创建/增量（不经 NotifyRequest；下达车间直发用）。 */
    private UUID createOrIncrementMakeDemand(
            UUID analysisId, ActionGroup group, BigDecimal demandQty) {
        UUID representative = group.materials().getFirst().materialLineId();
        List<Object[]> existing = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id, requested_qty
                FROM production_material_analysis_items
                WHERE analysis_id = :analysisId
                  AND source_type = 'MAKE_COMPONENT'
                  AND parent_analysis_material_id = :parentId
                  AND is_deleted = FALSE
                FOR UPDATE
                """).setParameter("analysisId", analysisId)
                .setParameter("parentId", representative));
        if (!existing.isEmpty()) {
            UUID itemId = (UUID) existing.getFirst()[0];
            em.createNativeQuery("""
                    UPDATE production_material_analysis_items
                    SET requested_qty = requested_qty + :qty,
                        delivery_date = COALESCE(:needDate, delivery_date),
                        updated_at = now(), updated_by = :actorId
                    WHERE id = :id
                    """)
                    .setParameter("qty", demandQty)
                    .setParameter("needDate", group.needDate())
                    .setParameter("actorId", currentUser.requireId())
                    .setParameter("id", itemId).executeUpdate();
            return itemId;
        }
        UUID itemId = UUID.randomUUID();
        // 可读来源编号「自制备料 <日期> <4位尾码>」：日期表意，尾码取自条目 id 仅作同日去重；
        // (source_type, source_ref) 有全局唯一索引，插入前查重避免碰撞（PG 唯一冲突会中止整个事务）。
        String sourceRef = nextMakeSourceRef(itemId);
        int linePriority = nextLinePriority(analysisId);
        em.createNativeQuery("""
                INSERT INTO production_material_analysis_items (
                    id, analysis_id, source_type, goods_id, color_id, unit_id,
                    source_ref, source_reason, requested_qty, delivery_date,
                    line_priority, parent_analysis_material_id,
                    created_by, updated_by
                ) VALUES (
                    :id, :analysisId, 'MAKE_COMPONENT', :goodsId, :colorId, :unitId,
                    :sourceRef, :sourceReason, :qty, :needDate,
                    :linePriority,
                    :parentId, :actorId, :actorId
                )
                """)
                .setParameter("id", itemId)
                .setParameter("analysisId", analysisId)
                .setParameter("goodsId", group.dimension().goodsId())
                .setParameter("colorId", group.dimension().colorId())
                .setParameter("unitId", group.dimension().unitId())
                .setParameter("sourceRef", sourceRef)
                .setParameter("sourceReason", "父级物料缺口确认自制备料")
                .setParameter("qty", demandQty)
                .setParameter("needDate", group.needDate())
                .setParameter("linePriority", linePriority)
                .setParameter("parentId", representative)
                .setParameter("actorId", currentUser.requireId())
                .executeUpdate();
        return itemId;
    }

    /**
     * V458：有子层级的委外件在下达时改为「先自制、后通知委外」。
     * 在原分析内创建 SUBCONTRACT_MAKE 前置自制任务行（子树需求委托给该行），
     * 同步维护 preplan_subcontract_make_tasks 账本；不生成委外申请、不通知委外部。
     */
    private void createSubcontractMakeTask(UUID analysisId, ActionDraft action) {
        UUID itemId = createOrIncrementSubcontractMakeDemand(analysisId, action);
        String sourceRef = makeDemandSourceRef(itemId);
        markCreated(action.actionId(), "SUBCONTRACT_MAKE_TASK",
                itemId, sourceRef, itemId, null, null);
        UUID representative = action.group().materials().getFirst().materialLineId();
        UUID warehouseId = selectedWarehouse(analysisId);
        UUID actorId = currentUser.requireId();
        List<UUID> existing = NativeQueryResults.typedRows(em.createNativeQuery("""
                SELECT id FROM preplan_subcontract_make_tasks
                WHERE analysis_id = :analysisId
                  AND analysis_material_id = :materialId
                  AND status = 'ACTIVE'
                FOR UPDATE
                """).setParameter("analysisId", analysisId)
                .setParameter("materialId", representative), UUID.class);
        BigDecimal requiredQty = action.demandQty()
                .add(Optional.ofNullable(action.publicExtraQty()).orElse(BigDecimal.ZERO));
        UUID taskId;
        if (existing.isEmpty()) {
            taskId = UUID.randomUUID();
            em.createNativeQuery("""
                    INSERT INTO preplan_subcontract_make_tasks (
                        id, analysis_id, analysis_material_id, supply_action_id,
                        preparation_item_id, goods_id, color_id, unit_id,
                        warehouse_id, required_qty, created_by, updated_by)
                    VALUES (
                        :id, :analysisId, :materialId, :actionId,
                        :itemId, :goodsId, :colorId, :unitId,
                        :warehouseId, :requiredQty, :actorId, :actorId)
                    """)
                    .setParameter("id", taskId)
                    .setParameter("analysisId", analysisId)
                    .setParameter("materialId", representative)
                    .setParameter("actionId", action.actionId())
                    .setParameter("itemId", itemId)
                    .setParameter("goodsId", action.group().dimension().goodsId())
                    .setParameter("colorId", action.group().dimension().colorId())
                    .setParameter("unitId", action.group().dimension().unitId())
                    .setParameter("warehouseId", warehouseId)
                    .setParameter("requiredQty", requiredQty)
                    .setParameter("actorId", actorId)
                    .executeUpdate();
        } else {
            taskId = existing.getFirst();
            // 任务需求量 = 任务行需求量（重下达只增不减）+ 仍未撤销的前置自制
            // 行动带来的公共备货产出（V589：车间腿超量由台账如实承接）。
            // 公共备货合计写成 SET 里的标量子查询：UPDATE ... FROM 的 LATERAL
            // 不允许引用更新目标别名 task（PG 报 invalid reference to FROM-clause）。
            em.createNativeQuery("""
                    UPDATE preplan_subcontract_make_tasks task
                    SET required_qty = item.requested_qty + COALESCE((
                            SELECT SUM(action.public_surplus_qty)
                            FROM preplan_supply_actions action
                            WHERE action.analysis_id = task.analysis_id
                              AND action.external_document_type = 'SUBCONTRACT_MAKE_TASK'
                              AND action.external_document_id = task.preparation_item_id
                              AND action.status <> 'CANCELLED'
                        ), 0),
                        version = task.version + 1,
                        updated_by = :actorId, updated_at = now()
                    FROM production_material_analysis_items item
                    WHERE task.id = :taskId
                      AND item.id = task.preparation_item_id
                    """)
                    .setParameter("taskId", taskId)
                    .setParameter("actorId", actorId)
                    .executeUpdate();
        }
        chainNotice.notifySubcontractMakeTaskCreated(taskId);
    }

    /** 委外前置自制任务行：与自制备料同构，但来源类型独立、可读编号前缀为「委外自制」。 */
    private UUID createOrIncrementSubcontractMakeDemand(UUID analysisId, ActionDraft action) {
        UUID representative = action.group().materials().getFirst().materialLineId();
        List<Object[]> existing = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id, source_type, requested_qty
                FROM production_material_analysis_items
                WHERE analysis_id = :analysisId
                  AND source_type IN ('MAKE_COMPONENT', 'SUBCONTRACT_MAKE')
                  AND parent_analysis_material_id = :parentId
                  AND is_deleted = FALSE
                FOR UPDATE
                """).setParameter("analysisId", analysisId)
                .setParameter("parentId", representative));
        if (!existing.isEmpty()) {
            String type = Objects.toString(existing.getFirst()[1], "");
            if (!"SUBCONTRACT_MAKE".equals(type)) {
                throw conflict("该节点已存在自制备料任务，路线互斥，请先刷新物料分析");
            }
            UUID itemId = (UUID) existing.getFirst()[0];
            em.createNativeQuery("""
                    UPDATE production_material_analysis_items
                    SET requested_qty = requested_qty + :qty,
                        delivery_date = COALESCE(:needDate, delivery_date),
                        updated_at = now(), updated_by = :actorId
                    WHERE id = :id
                    """)
                    .setParameter("qty", action.demandQty())
                    .setParameter("needDate", action.group().needDate())
                    .setParameter("actorId", currentUser.requireId())
                    .setParameter("id", itemId).executeUpdate();
            MaterialView material=action.group().materials().getFirst();
            BigDecimal attributed=material.priorityMakeSupplementQty().min(action.demandQty());
            if(attributed.signum()>0) new PreplanReallocationMakeSupplement(em).recordExistingIncrease(
                    analysisId,representative,itemId,attributed,decimal(existing.getFirst()[2]),
                    decimal(existing.getFirst()[2]).add(action.demandQty()),currentUser.requireId());
            return itemId;
        }
        UUID itemId = UUID.randomUUID();
        // 可读来源编号「委外自制 <日期> <4位尾码>」；(source_type, source_ref)
        // 有全局唯一索引，插入前查重避免碰撞（PG 唯一冲突会中止整个事务）。
        String sourceRef = nextSubcontractMakeSourceRef(itemId);
        int linePriority = nextLinePriority(analysisId);
        em.createNativeQuery("""
                INSERT INTO production_material_analysis_items (
                    id, analysis_id, source_type, goods_id, color_id, unit_id,
                    source_ref, source_reason, requested_qty, delivery_date,
                    line_priority, parent_analysis_material_id,
                    created_by, updated_by
                ) VALUES (
                    :id, :analysisId, 'SUBCONTRACT_MAKE', :goodsId, :colorId, :unitId,
                    :sourceRef, :sourceReason, :qty, :needDate,
                    :linePriority, :parentId, :actorId, :actorId
                )
                """)
                .setParameter("id", itemId)
                .setParameter("analysisId", analysisId)
                .setParameter("goodsId", action.group().dimension().goodsId())
                .setParameter("colorId", action.group().dimension().colorId())
                .setParameter("unitId", action.group().dimension().unitId())
                .setParameter("sourceRef", sourceRef)
                .setParameter("sourceReason", "父级委外件缺口确认前置自制")
                .setParameter("qty", action.demandQty())
                .setParameter("needDate", action.group().needDate())
                .setParameter("linePriority", linePriority)
                .setParameter("parentId", representative)
                .setParameter("actorId", currentUser.requireId())
                .executeUpdate();
        return itemId;
    }

    /** 生成未占用的委外前置自制来源编号；尾码碰撞时换码重试。 */
    private String nextSubcontractMakeSourceRef(UUID itemId) {
        String candidate = "委外自制 " + BusinessTime.today()
                + " " + itemId.toString().substring(0, 4);
        if (subcontractMakeSourceRefAvailable(candidate)) return candidate;
        for (int attempt = 0; attempt < 8; attempt++) {
            candidate = "委外自制 " + BusinessTime.today()
                    + " " + UUID.randomUUID().toString().substring(0, 4);
            if (subcontractMakeSourceRefAvailable(candidate)) return candidate;
        }
        throw conflict("委外自制来源编号生成冲突，请重试");
    }

    private boolean subcontractMakeSourceRefAvailable(String ref) {
        return em.createNativeQuery("""
                SELECT 1
                FROM production_material_analysis_items
                WHERE source_type = 'SUBCONTRACT_MAKE'
                  AND is_deleted = FALSE
                  AND lower(btrim(source_ref)) = lower(btrim(:ref))
                """).setParameter("ref", ref).getResultList().isEmpty();
    }

    /** 同批委外分流共用一次查询快照，避免多产品重复物料造成逐行往返。 */
    Set<UUID> activeBomParentIds(Collection<UUID> goodsIds) {
        List<UUID> distinctGoodsIds = goodsIds.stream().distinct().sorted().toList();
        if (distinctGoodsIds.isEmpty()) return Set.of();
        return Set.copyOf(NativeQueryResults.typedRows(em.createNativeQuery("""
                SELECT DISTINCT bom.goods_id
                FROM goods_bom_items bom
                JOIN goods child ON child.id = bom.component_goods_id
                 AND child.is_deleted = FALSE
                 AND COALESCE(child.auto_created, FALSE) = FALSE
                WHERE bom.goods_id IN (:goodsIds) AND bom.is_deleted = FALSE
                """, UUID.class).setParameter("goodsIds", distinctGoodsIds), UUID.class));
    }

    /**
     * V581：「只有一个直属子件」的委外货品——这类件不先自制，直接把那个子件
     * 发给委外商，委外商加工后交回目标件。
     *
     * <p>判据与 {@code SubcontractMaterialPlanService.soleOutboundComponent} 及
     * 迁移 V581 的 {@code fn_guard_subcontract_target_quantity_basis_insert}
     * 逐字同口径：活动直属边恰好 1 条、该边 PER_UNIT 且是真实投入阶段；
     * V646 起子件可有自己的制造 BOM。其余形态按既有「先自制再发外」处理。
     *
     * <p>与 {@link #activeBomParentIds} 一样，同批只发一次查询。
     */
    Set<UUID> soleComponentSubcontractGoodsIds(Collection<UUID> goodsIds) {
        List<UUID> distinctGoodsIds = goodsIds.stream()
                .filter(java.util.Objects::nonNull).distinct().sorted().toList();
        if (distinctGoodsIds.isEmpty()) return Set.of();
        // 判据本体是 V581 的 fn_subcontract_sole_component_goods（与订货批准侧
        // 共用同一个函数），这里只做一次批量过滤，不再抄一遍判据。
        return Set.copyOf(NativeQueryResults.typedRows(em.createNativeQuery("""
                SELECT goods.id
                FROM goods
                WHERE goods.id IN (:goodsIds)
                  AND fn_subcontract_sole_component_goods(goods.id)
                """, UUID.class).setParameter("goodsIds", distinctGoodsIds), UUID.class));
    }

    /** 分析内下一行序（与既有 line_priority 递增口径一致；行锁由调用方 lockHeader 保证串行）。 */
    private int nextLinePriority(UUID analysisId) {
        // 单列聚合原生查询恒返回一行标量（Integer），非 Object[]，不能走 oneRow（会 CCE）。
        Object value = em.createNativeQuery("""
                SELECT COALESCE(MAX(line_priority), 0) + 1
                FROM production_material_analysis_items
                WHERE analysis_id = :analysisId
                """).setParameter("analysisId", analysisId).getSingleResult();
        return ((Number) value).intValue();
    }

    /** 生成未占用的自制备料来源编号；尾码碰撞时换码重试（理论上限 8 次，4 位十六进制几乎不会连撞）。 */
    private String nextMakeSourceRef(UUID itemId) {
        String candidate = "自制备料 " + BusinessTime.today()
                + " " + itemId.toString().substring(0, 4);
        if (makeSourceRefAvailable(candidate)) return candidate;
        // 尾码撞车：换成随机码再试几次；仍撞则放弃（概率可忽略）。
        for (int attempt = 0; attempt < 8; attempt++) {
            candidate = "自制备料 " + BusinessTime.today()
                    + " " + UUID.randomUUID().toString().substring(0, 4);
            if (makeSourceRefAvailable(candidate)) return candidate;
        }
        throw conflict("自制备料来源编号生成冲突，请重试");
    }

    private boolean makeSourceRefAvailable(String ref) {
        return em.createNativeQuery("""
                SELECT 1
                FROM production_material_analysis_items
                WHERE source_type = 'MAKE_COMPONENT'
                  AND is_deleted = FALSE
                  AND lower(btrim(source_ref)) = lower(btrim(:ref))
                """).setParameter("ref", ref).getResultList().isEmpty();
    }

    private void markCreated(UUID actionId, String type, UUID documentId,
                             String documentNo, UUID externalItemId,
                             UUID safetyExternalItemId,
                             UUID publicSurplusExternalItemId) {
        em.createNativeQuery("""
                UPDATE preplan_supply_actions
                SET status = 'CREATED', external_document_type = :type,
                    external_document_id = :documentId,
                    external_document_no = :documentNo,
                    safety_external_item_id = :safetyExternalItemId,
                    public_surplus_external_item_id = :publicSurplusExternalItemId,
                    updated_at = now()
                WHERE id = :id
                """)
                .setParameter("type", type)
                .setParameter("documentId", documentId)
                .setParameter("documentNo", documentNo)
                .setParameter("safetyExternalItemId", safetyExternalItemId)
                .setParameter("publicSurplusExternalItemId",
                        publicSurplusExternalItemId)
                .setParameter("id", actionId).executeUpdate();
        if (externalItemId != null) {
            em.createNativeQuery("""
                    UPDATE preplan_supply_action_allocations
                    SET external_item_id = :externalItemId
                    WHERE action_id = :id
                    """)
                    .setParameter("externalItemId", externalItemId)
                    .setParameter("id", actionId).executeUpdate();
        }
    }

    /**
     * @param publicSurplusQty 本批中超出该任务行剩余需求、按公共备货产出记账的量
     *                         （不占 submitted_qty，不绑定任何需求；0 = 无超量）
     */
    private PlanDetail createDraftPlan(
            UUID analysisId, ProductView product, PlanQuantity quantity,
            PlanScheduleDefaults defaults, BigDecimal publicSurplusQty) {
        BigDecimal qty = quantity.qty();
        LocalDate billDate = itemBillDate(quantity, defaults);
        LocalDate deliveryDate = itemDeliveryDate(quantity, defaults);
        UUID departmentId = quantity.departmentId();
        String workshopName = quantity.workshopName();
        UUID workerId = quantity.workerId();
        PlanItemLine line = new PlanItemLine();
        line.setLineNo(1);
        // Preserve an explicit business product number. Blank input remains
        // server-owned and is allocated by ProductionPlanService only after it
        // has the immutable plan UUID and server-issued bill number.
        line.setProductNo(quantity.productNo());
        line.setGoodsId(product.goodsId());
        line.setColorId(product.colorId());
        line.setUnitId(product.unitId());
        line.setUnitRate(product.unitRate());
        line.setSalesOrderItemId(product.salesOrderItemId());
        line.setSalesOrderNo(product.salesOrderNo());
        line.setClientName(product.clientName());
        line.setOqty(product.requestedQty());
        BigDecimal normalizedQty;
        try {
            normalizedQty = qty.setScale(4, RoundingMode.UNNECESSARY);
        } catch (ArithmeticException ex) {
            throw validation("生产计划数量最多保留四位小数");
        }
        line.setQty(normalizedQty);
        line.setOrderDate(product.orderDate());
        line.setOutboundDate(product.deliveryDate());
        line.setPlanBeginDate(billDate);
        line.setPlanEndDate(deliveryDate);
        line.setSourceDocNo(product.salesOrderNo());
        line.setRemark("由生产物料分析分批生成");

        PlanSaveRequest save = new PlanSaveRequest();
        save.setBillDate(billDate);
        save.setDeliveryDate(deliveryDate);
        save.setDepartmentId(departmentId);
        save.setWorkshopName(workshopName);
        save.setWorkerId(workerId);
        save.setSourceDocNo(product.salesOrderNo());
        save.setRemark("物料分析 " + analysisId + " 原子生成");
        save.setItems(List.of(line));
        PlanDetail plan = planService.create(save);
        em.createNativeQuery("""
                UPDATE production_plans
                SET material_analysis_id = :analysisId,
                    material_analysis_item_id = :analysisItemId,
                    updated_at = now(), updated_by = :actorId
                WHERE id = :planId
                """)
                .setParameter("analysisId", analysisId)
                .setParameter("analysisItemId", product.analysisLineId())
                .setParameter("actorId", currentUser.requireId())
                .setParameter("planId", plan.getId()).executeUpdate();
        ProductionPlan managedPlan = em.find(ProductionPlan.class, plan.getId());
        em.refresh(managedPlan);
        // 计划量 = 归本需求的量 + 公共备货产出量。只有前者写进 submitted_qty
        // （分析需求守恒），后者单列，V577 的触发器按两者之和与计划行数量对账。
        em.createNativeQuery("""
                INSERT INTO production_material_analysis_plan_links (
                    id, analysis_id, analysis_item_id, plan_id,
                    submitted_qty, public_surplus_qty, allocation_status, created_by
                ) VALUES (
                    :id, :analysisId, :analysisItemId, :planId,
                    :qty, :surplusQty, 'SUBMITTED', :actorId
                )
                """)
                .setParameter("id", UUID.randomUUID())
                .setParameter("analysisId", analysisId)
                .setParameter("analysisItemId", product.analysisLineId())
                .setParameter("planId", plan.getId())
                .setParameter("qty", qty.subtract(publicSurplusQty))
                .setParameter("surplusQty", publicSurplusQty)
                .setParameter("actorId", currentUser.requireId()).executeUpdate();
        return plan;
    }

    private ProductionPlanningDraftView savePlanningDraft(
            UUID analysisId, ProductView product, PlanDetail plan,
            PlanQuantity quantity, PlanScheduleDefaults defaults,
            UUID warehouseId) {
        LocalDate billDate = itemBillDate(quantity, defaults);
        LocalDate deliveryDate = itemDeliveryDate(quantity, defaults);
        UUID departmentId = quantity.departmentId();
        UUID workerId = quantity.workerId();
        PlanningPreviewResult preview = planningPackages.preview(
                plan.getId(), warehouseId);
        if (preview.executionSegments().isEmpty()) {
            throw conflict("正式生产计划未形成可下达的执行分段");
        }
        BigDecimal expectedQty = plan.getItems().stream()
                .map(item -> item.getQty() == null ? BigDecimal.ZERO : item.getQty())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal proposedQty = preview.executionSegments().stream()
                .map(ExecutionSegmentPreview::plannedQty)
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        if (expectedQty.compareTo(proposedQty) != 0) {
            throw conflict("正式计划预览数量与分析结论不一致，事务已回滚，请重新分析");
        }
        GeneratePlanningPackageRequest formal = new GeneratePlanningPackageRequest();
        formal.setWarehouseId(warehouseId);
        formal.setIdempotencyKey("ANALYSIS-" + analysisId + "-" + product.analysisLineId());
        formal.setPreviewFingerprint(preview.fingerprint());
        formal.setGeneratePurchaseRequest(false);
        formal.setRoutes(List.of());
        formal.setItems(List.of());
        List<GeneratePlanningPackageRequest.ExecutionSegment> segments = new ArrayList<>();
        for (ExecutionSegmentPreview proposal : preview.executionSegments()) {
            String requestedStatus = proposal.suggestedStatus();
            if (!Set.of("READY", "WAITING").contains(requestedStatus)) {
                throw conflict("正式计划预览包含未知执行状态，事务已回滚，请重新分析");
            }
            // CompleteKitAllocator 已按同一权威库存快照把计划行拆成“当前完整
            // 齐套 READY + 剩余 WAITING”。必须保留它的数量、稳定 key 和状态；
            // 把混合结果重新压成一个全量 WAITING 会吞掉可立即生产的批次。
            segments.add(requestedSegment(
                    proposal, proposal.clientSegmentKey(), proposal.plannedQty(),
                    requestedStatus, departmentId, quantity.teamDepartmentId(), workerId,
                    billDate, deliveryDate));
        }
        formal.setSegments(List.copyOf(segments));
        return planningDrafts.save(plan.getId(), formal);
    }

    private static GeneratePlanningPackageRequest.ExecutionSegment requestedSegment(
            ExecutionSegmentPreview proposal, String clientSegmentKey,
            BigDecimal plannedQty, String requestedStatus,
            UUID departmentId, UUID teamDepartmentId, UUID workerId,
            LocalDate billDate, LocalDate deliveryDate) {
        GeneratePlanningPackageRequest.ExecutionSegment segment =
                new GeneratePlanningPackageRequest.ExecutionSegment();
        segment.setClientSegmentKey(clientSegmentKey);
        segment.setSourcePlanItemId(proposal.sourcePlanItemId());
        segment.setRequestedStatus(requestedStatus);
        // 这里的 WAITING 是客观缺料，不是人工延期；保持自动齐套提升。
        segment.setDeferUntilManualRelease(false);
        segment.setPlannedQty(plannedQty);
        segment.setWorkshopDepartmentId(departmentId == null
                ? proposal.workshopDepartmentId() : departmentId);
        segment.setTeamDepartmentId(teamDepartmentId == null
                ? proposal.teamDepartmentId() : teamDepartmentId);
        segment.setResponsibleEmployeeId(workerId == null
                ? proposal.responsibleEmployeeId() : workerId);
        segment.setPlanBeginDate(billDate);
        segment.setPlanEndDate(deliveryDate);
        segment.setBomFingerprint(proposal.bomFingerprint());
        return segment;
    }

    private static void validatePlanSchedule(
            PlanQuantity quantity, PlanScheduleDefaults defaults) {
        LocalDate billDate = itemBillDate(quantity, defaults);
        LocalDate deliveryDate = itemDeliveryDate(quantity, defaults);
        if (deliveryDate != null && deliveryDate.isBefore(billDate)) {
            throw validation("计划完成日期不能早于计划开始日期");
        }
    }

    private static LocalDate itemBillDate(
            PlanQuantity quantity, PlanScheduleDefaults defaults) {
        return quantity.billDate() == null ? defaults.billDate() : quantity.billDate();
    }

    private static LocalDate itemDeliveryDate(
            PlanQuantity quantity, PlanScheduleDefaults defaults) {
        return quantity.deliveryDate() == null
                ? defaults.deliveryDate() : quantity.deliveryDate();
    }

    private GeneratedPlan toGenerated(
            PlanDetail plan, ProductionPlanningDraftView draft,
            PlanningPackageResult applied) {
        if (applied == null) {
            return new GeneratedPlan(plan.getId(), plan.getBillNo(), "DRAFT",
                    draft.draftId(), null, List.of(), List.of(), List.of());
        }
        return new GeneratedPlan(plan.getId(), plan.getBillNo(), "APPROVED",
                draft.draftId(), applied.packageId(),
                applied.executionSegments().stream().map(value -> value.segmentId()).toList(),
                applied.drawDocuments().stream().map(MrpGenerateResult::requestId).toList(),
                applied.drawDocuments().stream()
                        .map(value -> new GeneratedDraw(value.requestId(), value.requestBillNo()))
                        .toList());
    }

    private GeneratedPlan generatedPlan(UUID planId) {
        Object[] plan = one(em.createNativeQuery("""
                SELECT id, bill_no, status FROM production_plans
                WHERE id = :id AND is_deleted = FALSE
                """).setParameter("id", planId), "幂等结果中的生产计划不存在");
        UUID draftId = scalarUuid("""
                SELECT id FROM production_planning_drafts
                WHERE plan_id = :id ORDER BY planned_at DESC, id DESC LIMIT 1
                """, planId);
        UUID packageId = scalarUuid("""
                SELECT id FROM production_planning_packages
                WHERE plan_id = :id AND status = 'CONFIRMED' AND is_deleted = FALSE
                ORDER BY created_at DESC, id DESC LIMIT 1
                """, planId);
        List<UUID> segments = packageId == null ? List.of() : uuidList("""
                SELECT id FROM production_execution_segments
                WHERE package_id = :id AND is_deleted = FALSE ORDER BY segment_no, id
                """, packageId);
        List<GeneratedDraw> draws = packageId == null ? List.of() : drawDocuments(packageId);
        return new GeneratedPlan((UUID) plan[0], Objects.toString(plan[1], null),
                ((Number) plan[2]).shortValue() == 1 ? "APPROVED" : "DRAFT",
                draftId, packageId, segments,
                draws.stream().map(GeneratedDraw::drawId).toList(), draws);
    }

    /** 计划包内的领料单（物料提货单）：id + 可读单号，按创建序。 */
    private List<GeneratedDraw> drawDocuments(UUID packageId) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT doc.document_id, stock.bill_no
                FROM production_planning_package_documents doc
                JOIN stock_documents stock ON stock.id = doc.document_id
                WHERE doc.package_id = :id AND doc.document_type = 'DRAW'
                ORDER BY doc.created_at, doc.id
                """).setParameter("id", packageId).getResultList();
        List<GeneratedDraw> result = new ArrayList<>();
        for (Object[] row : rows) {
            result.add(new GeneratedDraw((UUID) row[0], Objects.toString(row[1], null)));
        }
        return List.copyOf(result);
    }

    /**
     * 撤回一个备料任务。ADR-065 起采购/委外申请按整批合并生成：目标任务的
     * 外部单据若仍被同分析内其他生效任务共享，则共享任务在同一事务内一并撤回、
     * 单据只红冲一次；任何共享任务存在不可撤回依赖时整批失败（fail-closed）。
     *
     * @return 实际撤回的 action id 集合（目标 + 共享同单据的兄弟任务）
     */
    private List<UUID> cancelActionLocked(UUID analysisId, UUID actionId, String reason) {
        subcontractPreparationHandoffs.requireSupplyActionCancellationSafe(
                analysisId, actionId);
        Object[] row = one(em.createNativeQuery("""
                SELECT id, status, route, requested_qty, external_document_type,
                       external_document_id, operation_type, public_surplus_qty
                FROM preplan_supply_actions
                WHERE id = :actionId AND analysis_id = :analysisId
                FOR UPDATE
                """).setParameter("actionId", actionId)
                .setParameter("analysisId", analysisId), "备料任务不存在");
        String status = Objects.toString(row[1], "");
        String type = Objects.toString(row[4], null);
        UUID documentId = (UUID) row[5];
        boolean sharedFutureClaim = "SHARED_FUTURE_CLAIM".equals(
                Objects.toString(row[6], "SUPPLY"));
        if ("CANCELLED".equals(status)) {
            if (!sharedFutureClaim && "SUBCONTRACT_APPLICATION".equals(type)) {
                subcontractMakeTasks.reverseNotificationBatchesForApplication(documentId, reason);
            }
            return List.of();
        }
        List<UUID> batch = !sharedFutureClaim
                && sharesExternalDocument(type, documentId)
                ? sharedDocumentActionIds(analysisId, documentId)
                : List.of(actionId);
        for (UUID candidateId : batch) {
            cancelSingleActionLocked(analysisId, candidateId, reason);
        }
        return batch;
    }

    private static boolean sharesExternalDocument(String type, UUID documentId) {
        return documentId != null
                && ("PURCHASE_REQUEST".equals(type)
                || "SUBCONTRACT_APPLICATION".equals(type));
    }

    /** 同分析内共享同一张外部申请单据、且仍生效的全部任务（含目标，稳定顺序加锁）。 */
    private List<UUID> sharedDocumentActionIds(UUID analysisId, UUID documentId) {
        List<UUID> rows = NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT id
                        FROM preplan_supply_actions
                        WHERE analysis_id = :analysisId
                          AND external_document_id = :documentId
                          AND status IN ('OPEN','CREATED','IN_PROGRESS','DONE')
                        ORDER BY created_at, id
                        FOR UPDATE
                        """)
                .setParameter("analysisId", analysisId)
                .setParameter("documentId", documentId), UUID.class);
        // 目标行已被外层锁定；共享集合为空只可能来自并发撤回，此时退回目标本身。
        if (rows.isEmpty()) return List.of();
        return List.copyOf(rows);
    }

    /** 撤回单个任务行：外部单据（合并生成，可能已被同批兄弟先撤）红冲幂等。 */
    private void cancelSingleActionLocked(UUID analysisId, UUID actionId, String reason) {
        subcontractPreparationHandoffs.requireSupplyActionCancellationSafe(
                analysisId, actionId);
        Object[] row = one(em.createNativeQuery("""
                SELECT id, status, route, requested_qty, external_document_type,
                       external_document_id, operation_type, public_surplus_qty
                FROM preplan_supply_actions
                WHERE id = :actionId AND analysis_id = :analysisId
                FOR UPDATE
                """).setParameter("actionId", actionId)
                .setParameter("analysisId", analysisId), "备料任务不存在");
        String status = Objects.toString(row[1], "");
        if ("CANCELLED".equals(status)) return;
        String type = Objects.toString(row[4], null);
        UUID documentId = (UUID) row[5];
        boolean sharedFutureClaim = "SHARED_FUTURE_CLAIM".equals(
                Objects.toString(row[6], "SUPPLY"));
        if("FUTURE_TRANSFER".equals(Objects.toString(row[6],"SUPPLY"))) {
            throw conflict("专属在途调整请在转拨记录中撤销未实收份额，不能撤销原供给单据");
        }
        if (sharedFutureClaim) {
            // A claim reuses another action's document.  Cancelling it releases only
            // this analysis allocation/entitlement; the source document is immutable.
        } else if ("PURCHASE_REQUEST".equals(type)) {
            purchaseRequests.cancelGeneratedDraft(documentId,
                    ProductionPurchaseRequestFacade.LifecycleAction.REVERSE);
        } else if ("SUBCONTRACT_APPLICATION".equals(type)) {
            subcontractRequests.closeGeneratedDraft(documentId,
                    ProductionSubcontractRequestPort.LifecycleAction.REVERSE);
        } else if ("PREPLAN_MAKE_TASK".equals(type)) {
            cancelMakeDemand(analysisId, actionId, documentId, decimal(row[3]));
        } else if ("SUBCONTRACT_MAKE_TASK".equals(type)) {
            cancelSubcontractMakeDemand(analysisId, actionId,
                    documentId, decimal(row[3]), decimal(row[7]));
        } else if (!"OPEN".equals(status)) {
            throw conflict("备料任务缺少可撤回的真实下游单据引用");
        }
        em.createNativeQuery("""
                UPDATE preplan_supply_actions
                SET status = 'CANCELLED', cancelled_by = :actorId,
                    cancelled_at = now(), cancellation_reason = :reason,
                    updated_at = now()
                WHERE id = :id
                """)
                .setParameter("actorId", currentUser.requireId())
                .setParameter("reason", reason.strip())
                .setParameter("id", actionId).executeUpdate();
        if (!sharedFutureClaim && "SUBCONTRACT_APPLICATION".equals(type)) {
            subcontractMakeTasks.reverseNotificationBatchesForApplication(documentId, reason);
        }
        // 分析备料绑定对称释放（V298）：该任务外部单据明细（申请行/委外申请行）
        // 已收货入库并被绑定的量，随任务撤回回到公共现货池。
        List<UUID> externalItemIds = NativeQueryResults.typedRows(em.createNativeQuery("""
                SELECT DISTINCT external_item_id
                FROM preplan_supply_action_allocations
                WHERE analysis_id = :analysisId AND action_id = :actionId
                  AND external_item_id IS NOT NULL
                """)
                .setParameter("analysisId", analysisId)
                .setParameter("actionId", actionId), UUID.class);
        if (sharedFutureClaim) {
            analysisPeg.releaseForAction(analysisId, actionId, reason);
        } else {
            analysisPeg.releaseForSupplyItems(analysisId, externalItemIds, null);
        }
    }

    /**
     * V458：撤回委外前置自制任务。已有自制成品入库或已通知委外的量一律失败关闭；
     * 纯任务按自制备料同构口径回退任务行数量并作废账本行。
     */
    private void cancelSubcontractMakeDemand(
            UUID analysisId, UUID actionId, UUID itemId, BigDecimal qty, BigDecimal surplusQty) {
        List<Object[]> taskRows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id, required_qty, produced_qty, notified_qty
                FROM preplan_subcontract_make_tasks
                WHERE analysis_id = :analysisId
                  AND preparation_item_id = :itemId
                  AND status = 'ACTIVE'
                FOR UPDATE
                """).setParameter("analysisId", analysisId)
                .setParameter("itemId", itemId));
        if (!taskRows.isEmpty()) {
            Object[] taskRow = taskRows.getFirst();
            if (decimal(taskRow[2]).signum() > 0
                    || decimal(taskRow[3]).signum() > 0) {
                throw conflict("委外前置自制已有成品入库或已通知委外，不能撤回");
            }
            BigDecimal nextRequired = decimal(taskRow[1]).subtract(qty).subtract(surplusQty);
            BigDecimal planned = decimal(em.createNativeQuery("""
                    SELECT COALESCE(SUM(submitted_qty + public_surplus_qty), 0)
                    FROM production_material_analysis_plan_links
                    WHERE analysis_id = :analysisId AND analysis_item_id = :itemId
                      AND allocation_status IN ('SUBMITTED', 'APPROVED')
                    """).setParameter("analysisId", analysisId).setParameter("itemId", itemId)
                    .getSingleResult());
            if (nextRequired.compareTo(planned) < 0) {
                throw conflict("委外前置自制已有待审核或已审核计划，不能撤回其生产数量");
            }
            if (nextRequired.signum() > 0) {
                em.createNativeQuery("""
                        UPDATE preplan_subcontract_make_tasks
                        SET required_qty = :requiredQty,
                            version = version + 1,
                            updated_by = :actorId, updated_at = now()
                        WHERE id = :id
                        """)
                        .setParameter("requiredQty", nextRequired)
                        .setParameter("actorId", currentUser.requireId())
                        .setParameter("id", taskRow[0]).executeUpdate();
            } else {
                em.createNativeQuery("""
                        UPDATE preplan_subcontract_make_tasks
                        SET status = 'CANCELLED', version = version + 1,
                            updated_by = :actorId, updated_at = now()
                        WHERE id = :id
                        """)
                        .setParameter("actorId", currentUser.requireId())
                        .setParameter("id", taskRow[0]).executeUpdate();
            }
        }
        cancelMakeDemandRow(analysisId, actionId, itemId, qty,
                "委外前置自制备料需求不存在");
    }

    private void cancelMakeDemand(
            UUID analysisId, UUID actionId, UUID itemId, BigDecimal qty) {
        cancelMakeDemandRow(analysisId, actionId, itemId, qty, "自制备料需求不存在");
    }

    private void cancelMakeDemandRow(
            UUID analysisId, UUID actionId, UUID itemId, BigDecimal qty,
            String notFoundMessage) {
        Object[] item = one(em.createNativeQuery("""
                SELECT requested_qty, submitted_qty, approved_qty
                FROM production_material_analysis_items
                WHERE id = :id AND analysis_id = :analysisId
                  AND source_type IN ('MAKE_COMPONENT','SUBCONTRACT_MAKE')
                  AND is_deleted = FALSE
                FOR UPDATE
                """).setParameter("id", itemId).setParameter("analysisId", analysisId),
                notFoundMessage);
        BigDecimal minimum = decimal(item[1]).add(decimal(item[2]));
        BigDecimal next = decimal(item[0]).subtract(qty);
        if (next.compareTo(minimum) < 0) {
            throw conflict("自制备料需求已有待审核或已审核计划，不能撤回");
        }
        stockEntitlement.restoreMakeDelegationsForAction(
                analysisId, actionId, "MAKE-DELEGATE-CANCEL:" + actionId);
        Number other = (Number) em.createNativeQuery("""
                SELECT COUNT(*) FROM preplan_supply_actions
                WHERE analysis_id = :analysisId AND id <> :actionId
                  AND external_document_type IN (
                      'PREPLAN_MAKE_TASK','SUBCONTRACT_MAKE_TASK')
                  AND external_document_id = :itemId AND status <> 'CANCELLED'
                """).setParameter("analysisId", analysisId)
                .setParameter("actionId", actionId).setParameter("itemId", itemId)
                .getSingleResult();
        if (next.signum() == 0 && other.longValue() == 0) {
            em.createNativeQuery("""
                    UPDATE production_material_analysis_items
                    SET is_deleted = TRUE, deleted_at = now(), updated_at = now(),
                        updated_by = :actorId
                    WHERE id = :id
                    """).setParameter("actorId", currentUser.requireId())
                    .setParameter("id", itemId).executeUpdate();
        } else {
            em.createNativeQuery("""
                    UPDATE production_material_analysis_items
                    SET requested_qty = :qty, updated_at = now(), updated_by = :actorId
                    WHERE id = :id
                    """).setParameter("qty", next)
                    .setParameter("actorId", currentUser.requireId())
                    .setParameter("id", itemId).executeUpdate();
        }
    }

    /**
     * Finds open coverage by the material-node allocations as well as the
     * current V3 node key. Allocation lookup keeps actions created with the
     * legacy grouped key from being duplicated after the node model upgrade.
     */
    private MaterialAnalysisSupplyCoverageReader.Coverage supplyCoverage(
            UUID analysisId, List<ActionGroup> groups) {
        return new MaterialAnalysisSupplyCoverageReader(em).read(analysisId, groups.stream()
                .map(group -> new MaterialAnalysisSupplyCoverageReader.Group(
                        group.groupKey(), group.route(), group.materials().stream()
                                .map(MaterialView::materialLineId).toList())).toList());
    }

    private static BigDecimal activeOpenActionQty(
            MaterialAnalysisSupplyCoverageReader.Coverage coverage, ActionGroup group) {
        return coverage.active(group.groupKey(), group.route());
    }

    private static BigDecimal cancelledIqcReplacementInFlight(
            MaterialAnalysisSupplyCoverageReader.Coverage coverage, ActionGroup group) {
        return coverage.replacement(group.groupKey(), group.route());
    }

    private ActionSequence nextActionSequence(UUID analysisId, String groupKey, String route) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id, generation FROM preplan_supply_actions
                WHERE analysis_id = :analysisId AND action_group_key = :groupKey
                  AND route = :route
                ORDER BY generation DESC, id DESC LIMIT 1 FOR UPDATE
                """).setParameter("analysisId", analysisId)
                .setParameter("groupKey", groupKey).setParameter("route", route));
        return rows.isEmpty() ? new ActionSequence(1, null)
                : new ActionSequence(((Number) rows.getFirst()[1]).intValue() + 1,
                        (UUID) rows.getFirst()[0]);
    }

    private UUID selectedWarehouse(UUID analysisId) {
        Object value = em.createNativeQuery("""
                SELECT warehouse_id FROM production_material_analyses WHERE id = :id
                """).setParameter("id", analysisId).getSingleResult();
        if (value == null) throw conflict("物料分析未选择目标仓库");
        return (UUID) value;
    }

    private void requireWritable(MaterialAnalysisService.AnalysisHeader header, String message) {
        access.requireWritable(header.makerId(), message, analysisService.scopeForAnalysis(header));
    }

    private CommandReplay commandReplay(
            UUID analysisId, String operation, String key, String hash) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT request_hash, result_payload
                FROM production_material_analysis_commands
                WHERE analysis_id = :analysisId AND operation = :operation
                  AND idempotency_key = :key
                """).setParameter("analysisId", analysisId)
                .setParameter("operation", operation).setParameter("key", key));
        if (rows.isEmpty()) return null;
        if (!Objects.equals(hash, Objects.toString(rows.getFirst()[0], ""))) {
            throw conflict("同一幂等键已用于不同请求");
        }
        return new CommandReplay(Objects.toString(rows.getFirst()[1], "{}"));
    }

    private void recordCommand(
            UUID analysisId, String operation, String key, String hash,
            Map<String, ?> payload) {
        try {
            em.createNativeQuery("""
                    INSERT INTO production_material_analysis_commands (
                        id, analysis_id, operation, idempotency_key,
                        request_hash, result_payload, created_by
                    ) VALUES (
                        :id, :analysisId, :operation, :key,
                        :hash, CAST(:payload AS jsonb), :actorId
                    )
                    """)
                    .setParameter("id", UUID.randomUUID())
                    .setParameter("analysisId", analysisId)
                    .setParameter("operation", operation)
                    .setParameter("key", key)
                    .setParameter("hash", hash)
                    .setParameter("payload", objectMapper.writeValueAsString(payload))
                    .setParameter("actorId", currentUser.requireId()).executeUpdate();
        } catch (JsonProcessingException ex) {
            throw conflict("幂等结果序列化失败");
        }
    }

    private List<UUID> replayIds(String payload, String field) {
        try {
            JsonNode node = objectMapper.readTree(payload).path(field);
            List<UUID> result = new ArrayList<>();
            node.forEach(value -> result.add(UUID.fromString(value.asText())));
            return List.copyOf(result);
        } catch (JsonProcessingException | IllegalArgumentException ex) {
            throw conflict("幂等结果损坏，不能安全重放");
        }
    }

    private static String notifyHash(UUID analysisId, NotifyRequest request) {
        List<String> parts = new ArrayList<>(List.of(
                "NOTIFY-V3", analysisId.toString(), Long.toString(request.version()),
                request.fingerprint(), Objects.toString(request.target(), "")));
        if (request.actionGroupKeys() != null) request.actionGroupKeys().stream()
                .sorted().forEach(value -> parts.add("GROUP|" + value));
        if (request.materialLineIds() != null) request.materialLineIds().stream()
                .sorted().forEach(value -> parts.add("LINE|" + value));
        if (request.quantities() != null) request.quantities().stream()
                .map(value -> "QTY|" + Objects.toString(value.actionGroupKey(), "")
                        + "|" + Objects.toString(value.materialLineId(), "")
                        + "|" + MaterialAnalysisService.decimalText(value.qty())
                        + "|SAFETY|" + canonicalOptionalQuantity(
                                value.safetyReplenishmentQty()))
                .sorted().forEach(parts::add);
        return PlanningPackageFingerprint.sha256(parts);
    }

    private static Map<String,SharedFutureClaimQuantity> sharedFutureQuantities(ClaimSharedFutureRequest request,List<ActionGroup> groups) {
        if(request.quantities()==null || request.quantities().isEmpty()) return Map.of();
        Set<String> groupKeys=groups.stream().map(ActionGroup::groupKey).collect(Collectors.toSet());
        Map<String,SharedFutureClaimQuantity> result=new HashMap<>();
        for(SharedFutureClaimQuantity quantity:request.quantities()) {
            if(quantity==null || !groupKeys.contains(quantity.actionGroupKey()) || quantity.qty()==null || quantity.qty().signum()<=0
                    || quantity.qty().scale()>4 || quantity.qty().precision()-quantity.qty().scale()>14
                    || result.putIfAbsent(quantity.actionGroupKey(),quantity)!=null) throw validation("公共在途认领数量必须逐项对应本次选择，不得重复或超出数量精度");
        }
        if(result.size()!=groupKeys.size()) throw validation("请为每个所选物料填写本次认领数量");
        return Map.copyOf(result);
    }

    private static String claimSharedFutureHash(
            UUID analysisId, ClaimSharedFutureRequest request) {
        List<String> parts = new ArrayList<>(List.of(
                "CLAIM-SHARED-FUTURE-V1", analysisId.toString(),
                Long.toString(request.version()), request.fingerprint()));
        request.actionGroupKeys().stream().distinct().sorted()
                .forEach(value -> parts.add("GROUP|" + value));
        if(request.quantities()!=null) request.quantities().stream().sorted(Comparator.comparing(SharedFutureClaimQuantity::actionGroupKey))
                .forEach(quantity->parts.add("QUANTITY|"+quantity.actionGroupKey()+"|"+canonicalOptionalQuantity(quantity.qty())+"|"+Objects.toString(quantity.sourceActionId(),"AUTO")));
        if(request.allowLateSupply()) parts.add("ALLOW_LATE_SUPPLY|true");
        return PlanningPackageFingerprint.sha256(parts);
    }

    static String canonicalOptionalQuantity(BigDecimal value) {
        return value == null
                ? "NULL"
                : MaterialAnalysisService.decimalText(value);
    }

    private UUID scalarUuid(String sql, UUID id) {
        List<?> rows = em.createNativeQuery(sql).setParameter("id", id).getResultList();
        return rows.isEmpty() ? null : (UUID) rows.getFirst();
    }

    @SuppressWarnings("unchecked")
    private List<UUID> uuidList(String sql, UUID id) {
        return (List<UUID>) em.createNativeQuery(sql).setParameter("id", id).getResultList();
    }

    private static Object[] one(jakarta.persistence.Query query, String message) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(query);
        if (rows.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, message);
        return rows.getFirst();
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : new BigDecimal(value.toString());
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    private record MaterialDimension(UUID goodsId, UUID colorId, UUID unitId) {
    }

    private record ActionGroup(
            String groupKey, String route, MaterialDimension dimension,
            int sourcePriority, LocalDate needDate, BigDecimal demandRequiredQty,
            List<MaterialView> materials) {
    }

    private record SafetyDimension(UUID goodsId, UUID colorId) {
        static SafetyDimension of(ActionGroup group) {
            return new SafetyDimension(
                    group.dimension().goodsId(), group.dimension().colorId());
        }
    }

    record SafetySnapshot(
            BigDecimal safetyStockQty,
            BigDecimal publicAvailableQty,
            BigDecimal openSupplyQty,
            BigDecimal gapQty) {
        static final SafetySnapshot ZERO = new SafetySnapshot(
                BigDecimal.ZERO, BigDecimal.ZERO,
                BigDecimal.ZERO, BigDecimal.ZERO);
    }

    /**
     * @param claimedQty 本次下达前已自动认领的公共在途量（ADR-099），只记账不再下单
     */
    private record ActionPlan(
            ActionGroup group, BigDecimal demandQty, BigDecimal publicExtraQty,
            SafetySnapshot safety, BigDecimal claimedQty) {
    }

    /** 仍可就地改量的申请明细（ADR-099）：供给行动 + 它锚定的申请/申请明细。 */
    private record GrowableSupplyLine(
            UUID actionId, String documentType, UUID documentId, String documentNo,
            UUID externalItemId, String createdAt) {
    }

    private record GrownSupplyLine(GrowableSupplyLine line, BigDecimal addedQty) {
    }

    private record ActionDraft(
            UUID actionId,
            ActionGroup group,
            BigDecimal demandQty,
            BigDecimal publicExtraQty,
            UUID publicSurplusSliceId,
            BigDecimal safetyQty,
            UUID safetySliceId) {
    }

    /** ADR-065 同批合并的外部单据结果：整批一张采购申请 + 整批无子层委外一张申请。 */
    private record PreparedExternalDocuments(
            ProductionPurchaseRequestFacade.DraftResult purchaseRequest,
            ProductionSubcontractRequestPort.DraftResult subcontractApplication,
            Set<UUID> subcontractLeafActionIds) {
    }

    private record ActionSequence(int generation, UUID predecessorId) {
    }

    private record CommandReplay(String payload) {
    }

    private record SharedFutureSource(
            UUID actionId, BigDecimal availableQty, LocalDate expectedDate,
            UUID externalItemId, String documentType,
            UUID documentId, String documentNo, String sourceRoute) {
    }
}
