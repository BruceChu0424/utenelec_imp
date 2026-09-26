package com.uten.imp.features.subcontract.plan;

import com.uten.imp.application.port.SubcontractShortDeliveryPort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.stock.InventoryMutationLock;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueItemRepository;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.mockito.ArgumentMatchers;
import org.springframework.beans.factory.support.StaticListableBeanFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;

import java.math.BigDecimal;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyBoolean;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * V436 委外目标件出仓定向单测。
 *
 * <p>新批准行永远以订货目标件为计划/出仓货品：无活动子 BOM 直接通知仓库并建草稿；
 * 有活动子 BOM 必须先走正常 MAKE 链，仓库实收入库前不得建目标件出仓草稿。
 */
class SubcontractMaterialPlanServiceTest {

    private static final UUID ORDER_ID = UUID.randomUUID();
    private static final UUID OUTBOUND_WAREHOUSE_ID = UUID.randomUUID();
    private static final UUID SUPPLIER_ID = UUID.randomUUID();
    private static final UUID ACTOR_ID = UUID.randomUUID();
    private static final UUID DIRECT_ITEM_ID = UUID.randomUUID();
    private static final UUID MAKE_ITEM_ID = UUID.randomUUID();
    private static final UUID DIRECT_GOODS_ID = UUID.randomUUID();
    private static final UUID MAKE_GOODS_ID = UUID.randomUUID();
    private static final UUID COMPONENT_GOODS_ID = UUID.randomUUID();
    private static final UUID SOLE_ITEM_ID = UUID.randomUUID();
    private static final UUID SOLE_GOODS_ID = UUID.randomUUID();
    private static final UUID SOLE_BASE_UNIT_ID = UUID.randomUUID();
    private static final UUID COMPONENT_UNIT_ID = UUID.randomUUID();
    private static final UUID DIRECT_BASE_UNIT_ID = UUID.randomUUID();
    private static final UUID MAKE_BASE_UNIT_ID = UUID.randomUUID();
    private static final UUID DOCUMENT_UNIT_ID = UUID.randomUUID();
    private static final UUID WAREHOUSE_ID = UUID.randomUUID();

    private EntityManager em;
    private JdbcTemplate jdbc;
    private SubcontractMaterialIssueRepository issueRepo;
    private SubcontractMaterialIssueItemRepository issueItemRepo;
    private ChainNoticeService chainNotice;
    private InventoryMutationLock inventoryLock;
    private SubcontractMaterialPlanService service;

    private List<Object[]> orderRows;
    private List<Object[]> orderItemRows;
    private List<Object[]> goodsRows;
    private List<Object[]> issueRows;
    private List<Object[]> remainingRows;
    private Map<UUID, List<Object[]>> bomRowsByGoods;
    /** V581：货品 → 其唯一叶子子件行 [component_goods_id, color_id, unit_id, qty]；空=不是该形态。 */
    private Map<UUID, List<Object[]>> soleComponentRowsByGoods;
    private Map<UUID, BigDecimal> availableBaseByGoods;
    /** ADR-101：建出仓草稿时该仓能动用多少现货；0 表示一件都没有，本轮不该建草稿。 */
    private BigDecimal onHandForOutbound;

    @BeforeEach
    void setUp() {
        em = mock(EntityManager.class);
        jdbc = mock(JdbcTemplate.class);
        issueRepo = mock(SubcontractMaterialIssueRepository.class);
        issueItemRepo = mock(SubcontractMaterialIssueItemRepository.class);
        chainNotice = mock(ChainNoticeService.class);
        inventoryLock = mock(InventoryMutationLock.class);
        orderRows = List.of();
        orderItemRows = List.of();
        goodsRows = List.of();
        issueRows = List.of();
        remainingRows = List.of();
        bomRowsByGoods = Map.of();
        soleComponentRowsByGoods = Map.of();
        availableBaseByGoods = Map.of();
        stubNativeQueriesBySql();
        // 直下单销售式供货：按货品 stub 全局可用量（未设置的货品视为 0=全缺）。
        when(jdbc.queryForObject(
                ArgumentMatchers.<String>argThat(sql -> sql != null
                        && sql.contains("FROM stock_balances b")),
                eq(BigDecimal.class), any(), any(), any(), any()))
                .thenAnswer(invocation -> {
                    UUID goodsId = invocation.getArgument(2);
                    BigDecimal value = availableBaseByGoods.get(goodsId);
                    return value == null ? BigDecimal.ZERO : value;
                });
        when(jdbc.query(
                ArgumentMatchers.<String>argThat(sql -> sql != null
                        && sql.contains("FROM subcontract_material_plan_items pi")),
                ArgumentMatchers.<RowMapper<Object[]>>any(), any(Object.class)))
                .thenAnswer(invocation -> remainingRows);
        // ADR-101：建草稿前按「该仓此刻的合格可动用量」截断，没货就不建。
        // 默认给足现货，好让既有用例仍然测「批准时排计划、建草稿、通知仓库」这件事本身；
        // 「没货不派活」由 componentOutboundWithoutChildStockCreatesNoDraftAndNoNotice 单独钉。
        onHandForOutbound = new BigDecimal("999999");
        when(jdbc.query(
                ArgumentMatchers.<String>argThat(sql -> sql != null
                        && sql.contains("FROM v_stock_available sa")
                        && sql.contains("JOIN warehouses w")),
                ArgumentMatchers.<RowMapper<Object[]>>any(), any(), any()))
                .thenAnswer(invocation -> onHandForOutbound.signum() <= 0
                        ? List.<Object[]>of()
                        : List.<Object[]>of(new Object[]{OUTBOUND_WAREHOUSE_ID, onHandForOutbound}));
        when(jdbc.query(
                ArgumentMatchers.<String>argThat(sql -> sql != null
                        && sql.contains("FROM v_stock_available sa")
                        && !sql.contains("JOIN warehouses w")),
                ArgumentMatchers.<RowMapper<BigDecimal>>any(), any(), any(), any()))
                .thenAnswer(invocation -> List.of(onHandForOutbound));
        when(jdbc.query(
                ArgumentMatchers.<String>argThat(sql -> sql != null
                        && sql.contains("fn_subcontract_component_available_stock")),
                ArgumentMatchers.<RowMapper<Object[]>>any(), any(Object.class)))
                .thenAnswer(invocation -> onHandForOutbound.signum() <= 0 ? List.<Object[]>of()
                        : List.<Object[]>of(new Object[]{OUTBOUND_WAREHOUSE_ID,onHandForOutbound}));
        when(jdbc.query(
                ArgumentMatchers.<String>argThat(sql -> sql != null
                        && sql.contains("fn_subcontract_component_available_stock")),
                ArgumentMatchers.<RowMapper<Object[]>>any(), any(), any(), any()))
                .thenAnswer(invocation -> onHandForOutbound.signum() <= 0 ? List.<Object[]>of()
                        : List.<Object[]>of(new Object[]{OUTBOUND_WAREHOUSE_ID,onHandForOutbound}));

        DocNumberService docNumber = mock(DocNumberService.class);
        when(docNumber.nextNumber(eq(DocNumberPrefix.SUB_MATERIAL_ISSUE)))
                .thenReturn("EC-TEST-0001");
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.requireId()).thenReturn(ACTOR_ID);
        service = new SubcontractMaterialPlanService(
                em, jdbc, docNumber, issueRepo, issueItemRepo, currentUser,
                chainNotice, inventoryLock,
                mock(com.uten.imp.application.port.SubcontractOrderPreparationPort.class),
                new StaticListableBeanFactory().getBeanProvider(SubcontractShortDeliveryPort.class));
    }

    @Test
    void approvalWithoutBomPlansTargetInBaseUnitCreatesDraftAndNotifiesWarehouse() {
        BigDecimal orderQty = new BigDecimal("5");
        BigDecimal unitRate = new BigDecimal("12.5");
        BigDecimal plannedBaseQty = new BigDecimal("62.5000");
        UUID planItemId = UUID.randomUUID();
        orderRows = rows(new Object[]{ORDER_ID, "EO-DIRECT", SUPPLIER_ID, null});
        orderItemRows = rows(new Object[]{
                DIRECT_ITEM_ID, DIRECT_GOODS_ID, null, orderQty, 1,
                unitRate, DOCUMENT_UNIT_ID, WAREHOUSE_ID});
        goodsRows = rows(new Object[]{
                DIRECT_GOODS_ID, "FG-D", "直接委外目标件",
                DIRECT_BASE_UNIT_ID, "A-01"});
        remainingRows = rows(new Object[]{
                planItemId, DIRECT_ITEM_ID, DIRECT_GOODS_ID, null,
                DIRECT_GOODS_ID, DIRECT_BASE_UNIT_ID, unitRate,
                plannedBaseQty, plannedBaseQty, null, null, "DIRECT_OUTBOUND"});

        service.createPlanOnApproval(ORDER_ID);

        ArgumentCaptor<UUID> insertedPlanItemId = ArgumentCaptor.forClass(UUID.class);
        verify(jdbc).update(
                planItemInsertSql(),
                insertedPlanItemId.capture(), any(UUID.class), eq(DIRECT_ITEM_ID), eq(1),
                eq(DIRECT_GOODS_ID), ArgumentMatchers.<UUID>isNull(),
                eq(DIRECT_GOODS_ID), ArgumentMatchers.<UUID>isNull(),
                eq(DIRECT_BASE_UNIT_ID), eq(unitRate), eq(plannedBaseQty),
                eq("DIRECT_OUTBOUND"), eq("READY_OUTBOUND"), eq(plannedBaseQty),
                eq(WAREHOUSE_ID), eq(false), fingerprint(),
                ArgumentMatchers.<UUID>isNull(), ArgumentMatchers.<UUID>isNull(),
                eq(ACTOR_ID), eq(ACTOR_ID));
        verify(issueRepo).save(ArgumentMatchers.argThat(draft ->
                draft.getStatus() == 0
                        && SUPPLIER_ID.equals(draft.getSupplierId())
                        && draft.getMakerId() == null
                        && "EC-TEST-0001".equals(draft.getBillNo())));
        verify(issueItemRepo).save(ArgumentMatchers.argThat(item ->
                item.getQty().compareTo(plannedBaseQty) == 0
                        && planItemId.equals(item.getPlanItemId())
                        && DIRECT_ITEM_ID.equals(item.getOrderItemId())
                        && DIRECT_GOODS_ID.equals(item.getGoodsId())
                        && DIRECT_GOODS_ID.equals(item.getParentGoodsId())
                        && DIRECT_BASE_UNIT_ID.equals(item.getUnitId())
                        && BigDecimal.ONE.compareTo(item.getUnitRate()) == 0));
        verify(chainNotice).notifySubcontractOutboundReady(insertedPlanItemId.getValue());
        verify(chainNotice, never()).notifySubcontractPreparationRequired(any());
    }

    @Test
    void approvalWithBomPlansTargetAsMakeThenActionRequiredWithoutDraft() {
        BigDecimal plannedBaseQty = new BigDecimal("14.0000");
        UUID bomEdgeId = UUID.randomUUID();
        orderRows = rows(new Object[]{ORDER_ID, "EO-MAKE", SUPPLIER_ID, null});
        orderItemRows = rows(new Object[]{
                MAKE_ITEM_ID, MAKE_GOODS_ID, null, new BigDecimal("7"), 1,
                new BigDecimal("2"), DOCUMENT_UNIT_ID, WAREHOUSE_ID});
        goodsRows = rows(new Object[]{
                MAKE_GOODS_ID, "FG-M", "需先自制目标件", MAKE_BASE_UNIT_ID, "B-01"});
        bomRowsByGoods = Map.of(MAKE_GOODS_ID, rows(new Object[]{
                bomEdgeId, COMPONENT_GOODS_ID, null, new BigDecimal("3")}));

        service.createPlanOnApproval(ORDER_ID);

        ArgumentCaptor<UUID> insertedPlanItemId = ArgumentCaptor.forClass(UUID.class);
        verify(jdbc).update(
                planItemInsertSql(),
                insertedPlanItemId.capture(), any(UUID.class), eq(MAKE_ITEM_ID), eq(1),
                eq(MAKE_GOODS_ID), ArgumentMatchers.<UUID>isNull(),
                eq(MAKE_GOODS_ID), ArgumentMatchers.<UUID>isNull(),
                eq(MAKE_BASE_UNIT_ID), eq(new BigDecimal("2")), eq(plannedBaseQty),
                eq("MAKE_THEN_OUTBOUND"), eq("ACTION_REQUIRED"), eq(BigDecimal.ZERO),
                eq(WAREHOUSE_ID), eq(true), fingerprint(),
                ArgumentMatchers.<UUID>isNull(), ArgumentMatchers.<UUID>isNull(),
                eq(ACTOR_ID), eq(ACTOR_ID));
        verify(issueRepo, never()).save(any());
        verify(issueItemRepo, never()).save(any());
        verify(chainNotice).notifySubcontractPrepareShortage(insertedPlanItemId.getValue());
        verify(chainNotice, never()).notifySubcontractOutboundReady(any());
    }

    @Test
    void approvalWithBomAndFullStockShipsDirectlyWithoutMakeLine() {
        orderRows = rows(new Object[]{ORDER_ID, "EO-STOCK-FULL", SUPPLIER_ID, null});
        orderItemRows = rows(new Object[]{
                MAKE_ITEM_ID, MAKE_GOODS_ID, null, new BigDecimal("7"), 1,
                new BigDecimal("2"), DOCUMENT_UNIT_ID, WAREHOUSE_ID});
        goodsRows = rows(new Object[]{
                MAKE_GOODS_ID, "FG-M", "需先自制目标件", MAKE_BASE_UNIT_ID, "B-01"});
        bomRowsByGoods = Map.of(MAKE_GOODS_ID, rows(new Object[]{
                UUID.randomUUID(), COMPONENT_GOODS_ID, null, new BigDecimal("3")}));
        availableBaseByGoods = Map.of(MAKE_GOODS_ID, new BigDecimal("99"));
        // ADR-101：现货充足这一路真的会排出一张草稿，仓库才会被叫。
        remainingRows = rows(new Object[]{
                UUID.randomUUID(), MAKE_ITEM_ID, MAKE_GOODS_ID, null,
                MAKE_GOODS_ID, MAKE_BASE_UNIT_ID, new BigDecimal("2"),
                new BigDecimal("14.0000"), new BigDecimal("14.0000"), null,
                WAREHOUSE_ID, "DIRECT_OUTBOUND"});

        service.createPlanOnApproval(ORDER_ID);

        // 现货充足：整行拆为 DIRECT 直发，不再生成前置自制行，也不再通知计划部补产。
        verify(jdbc).update(
                planItemInsertSql(),
                any(UUID.class), any(UUID.class), eq(MAKE_ITEM_ID), eq(1),
                eq(MAKE_GOODS_ID), ArgumentMatchers.<UUID>isNull(),
                eq(MAKE_GOODS_ID), ArgumentMatchers.<UUID>isNull(),
                eq(MAKE_BASE_UNIT_ID), eq(new BigDecimal("2")),
                eq(new BigDecimal("14.0000")),
                eq("DIRECT_OUTBOUND"), eq("READY_OUTBOUND"),
                eq(new BigDecimal("14.0000")),
                eq(WAREHOUSE_ID), eq(true), fingerprint(),
                ArgumentMatchers.<UUID>isNull(), ArgumentMatchers.<UUID>isNull(),
                eq(ACTOR_ID), eq(ACTOR_ID));
        verify(jdbc, never()).update(
                planItemInsertSql(),
                any(UUID.class), any(UUID.class), any(UUID.class), any(int.class),
                eq(MAKE_GOODS_ID), any(), any(),
                any(UUID.class), any(), any(),
                eq("MAKE_THEN_OUTBOUND"), any(), any(),
                any(), anyBoolean(), any(), any(), any(),
                any(), any());
        verify(chainNotice).notifySubcontractOutboundReady(any());
        verify(chainNotice, never()).notifySubcontractPrepareShortage(any());
    }

    @Test
    void approvalWithBomAndPartialStockSplitsDirectAndShortageLines() {
        orderRows = rows(new Object[]{ORDER_ID, "EO-STOCK-PART", SUPPLIER_ID, null});
        orderItemRows = rows(new Object[]{
                MAKE_ITEM_ID, MAKE_GOODS_ID, null, new BigDecimal("7"), 1,
                new BigDecimal("2"), DOCUMENT_UNIT_ID, WAREHOUSE_ID});
        goodsRows = rows(new Object[]{
                MAKE_GOODS_ID, "FG-M", "需先自制目标件", MAKE_BASE_UNIT_ID, "B-01"});
        bomRowsByGoods = Map.of(MAKE_GOODS_ID, rows(new Object[]{
                UUID.randomUUID(), COMPONENT_GOODS_ID, null, new BigDecimal("3")}));
        // 需求 14、现货 5 → DIRECT 行 5 + MAKE 缺口行 9。
        availableBaseByGoods = Map.of(MAKE_GOODS_ID, new BigDecimal("5"));
        // ADR-101：能直发的那 5 个排出一张草稿，仓库被叫；缺口那 9 个仍去交计划部。
        remainingRows = rows(new Object[]{
                UUID.randomUUID(), MAKE_ITEM_ID, MAKE_GOODS_ID, null,
                MAKE_GOODS_ID, MAKE_BASE_UNIT_ID, new BigDecimal("2"),
                new BigDecimal("5.0000"), new BigDecimal("5.0000"), null,
                WAREHOUSE_ID, "DIRECT_OUTBOUND"});

        service.createPlanOnApproval(ORDER_ID);

        verify(jdbc).update(
                planItemInsertSql(),
                any(UUID.class), any(UUID.class), eq(MAKE_ITEM_ID), eq(1),
                eq(MAKE_GOODS_ID), ArgumentMatchers.<UUID>isNull(),
                eq(MAKE_GOODS_ID), ArgumentMatchers.<UUID>isNull(),
                eq(MAKE_BASE_UNIT_ID), eq(new BigDecimal("2")),
                eq(new BigDecimal("5.0000")),
                eq("DIRECT_OUTBOUND"), eq("READY_OUTBOUND"),
                eq(new BigDecimal("5.0000")),
                eq(WAREHOUSE_ID), eq(true), fingerprint(),
                ArgumentMatchers.<UUID>isNull(), ArgumentMatchers.<UUID>isNull(),
                eq(ACTOR_ID), eq(ACTOR_ID));
        verify(jdbc).update(
                planItemInsertSql(),
                any(UUID.class), any(UUID.class), eq(MAKE_ITEM_ID), eq(2),
                eq(MAKE_GOODS_ID), ArgumentMatchers.<UUID>isNull(),
                eq(MAKE_GOODS_ID), ArgumentMatchers.<UUID>isNull(),
                eq(MAKE_BASE_UNIT_ID), eq(new BigDecimal("2")),
                eq(new BigDecimal("9.0000")),
                eq("MAKE_THEN_OUTBOUND"), eq("ACTION_REQUIRED"), eq(BigDecimal.ZERO),
                eq(WAREHOUSE_ID), eq(true), fingerprint(),
                ArgumentMatchers.<UUID>isNull(), ArgumentMatchers.<UUID>isNull(),
                eq(ACTOR_ID), eq(ACTOR_ID));
        verify(chainNotice).notifySubcontractOutboundReady(any());
        verify(chainNotice).notifySubcontractPrepareShortage(any());
    }

    @Test
    void approvalWithSharedStockPoolDoesNotDoubleCountAcrossLines() {
        UUID secondItem = UUID.randomUUID();
        orderRows = rows(new Object[]{ORDER_ID, "EO-STOCK-POOL", SUPPLIER_ID, null});
        orderItemRows = List.of(
                new Object[]{MAKE_ITEM_ID, MAKE_GOODS_ID, null,
                        new BigDecimal("5"), 1, BigDecimal.ONE,
                        DOCUMENT_UNIT_ID, WAREHOUSE_ID},
                new Object[]{secondItem, MAKE_GOODS_ID, null,
                        new BigDecimal("5"), 2, BigDecimal.ONE,
                        DOCUMENT_UNIT_ID, WAREHOUSE_ID});
        goodsRows = rows(new Object[]{
                MAKE_GOODS_ID, "FG-M", "需先自制目标件", MAKE_BASE_UNIT_ID, "B-01"});
        bomRowsByGoods = Map.of(MAKE_GOODS_ID, rows(new Object[]{
                UUID.randomUUID(), COMPONENT_GOODS_ID, null, BigDecimal.ONE}));
        // 同货两行各需 5、可用量共 6：首行直发 5，次行直发 1 + 缺口 4，不重复占用。
        availableBaseByGoods = Map.of(MAKE_GOODS_ID, new BigDecimal("6"));

        service.createPlanOnApproval(ORDER_ID);

        verify(jdbc).update(
                planItemInsertSql(),
                any(UUID.class), any(UUID.class), eq(MAKE_ITEM_ID), eq(1),
                eq(MAKE_GOODS_ID), ArgumentMatchers.<UUID>isNull(),
                eq(MAKE_GOODS_ID), ArgumentMatchers.<UUID>isNull(),
                eq(MAKE_BASE_UNIT_ID), eq(BigDecimal.ONE), eq(new BigDecimal("5.0000")),
                eq("DIRECT_OUTBOUND"), eq("READY_OUTBOUND"), eq(new BigDecimal("5.0000")),
                eq(WAREHOUSE_ID), eq(true), fingerprint(),
                ArgumentMatchers.<UUID>isNull(), ArgumentMatchers.<UUID>isNull(),
                eq(ACTOR_ID), eq(ACTOR_ID));
        verify(jdbc).update(
                planItemInsertSql(),
                any(UUID.class), any(UUID.class), eq(secondItem), eq(2),
                eq(MAKE_GOODS_ID), ArgumentMatchers.<UUID>isNull(),
                eq(MAKE_GOODS_ID), ArgumentMatchers.<UUID>isNull(),
                eq(MAKE_BASE_UNIT_ID), eq(BigDecimal.ONE), eq(new BigDecimal("1.0000")),
                eq("DIRECT_OUTBOUND"), eq("READY_OUTBOUND"), eq(new BigDecimal("1.0000")),
                eq(WAREHOUSE_ID), eq(true), fingerprint(),
                ArgumentMatchers.<UUID>isNull(), ArgumentMatchers.<UUID>isNull(),
                eq(ACTOR_ID), eq(ACTOR_ID));
        verify(jdbc).update(
                planItemInsertSql(),
                any(UUID.class), any(UUID.class), eq(secondItem), eq(3),
                eq(MAKE_GOODS_ID), ArgumentMatchers.<UUID>isNull(),
                eq(MAKE_GOODS_ID), ArgumentMatchers.<UUID>isNull(),
                eq(MAKE_BASE_UNIT_ID), eq(BigDecimal.ONE), eq(new BigDecimal("4.0000")),
                eq("MAKE_THEN_OUTBOUND"), eq("ACTION_REQUIRED"), eq(BigDecimal.ZERO),
                eq(WAREHOUSE_ID), eq(true), fingerprint(),
                ArgumentMatchers.<UUID>isNull(), ArgumentMatchers.<UUID>isNull(),
                eq(ACTOR_ID), eq(ACTOR_ID));
    }

    @Test
    void mixedOrderCreatesOnePlanPerTargetButDraftContainsOnlyDirectLine() {
        UUID directPlanItemId = UUID.randomUUID();
        orderRows = rows(new Object[]{ORDER_ID, "EO-MIX", SUPPLIER_ID, null});
        orderItemRows = List.of(
                new Object[]{DIRECT_ITEM_ID, DIRECT_GOODS_ID, null,
                        new BigDecimal("3"), 1, BigDecimal.ONE,
                        DOCUMENT_UNIT_ID, WAREHOUSE_ID},
                new Object[]{MAKE_ITEM_ID, MAKE_GOODS_ID, null,
                        new BigDecimal("4"), 2, BigDecimal.ONE,
                        DOCUMENT_UNIT_ID, WAREHOUSE_ID});
        goodsRows = List.of(
                new Object[]{DIRECT_GOODS_ID, "FG-D", "直接件",
                        DIRECT_BASE_UNIT_ID, "A-01"},
                new Object[]{MAKE_GOODS_ID, "FG-M", "自制后委外件",
                        MAKE_BASE_UNIT_ID, "B-01"});
        bomRowsByGoods = Map.of(MAKE_GOODS_ID, rows(new Object[]{
                UUID.randomUUID(), COMPONENT_GOODS_ID, null, BigDecimal.ONE}));
        remainingRows = rows(new Object[]{
                directPlanItemId, DIRECT_ITEM_ID, DIRECT_GOODS_ID, null,
                DIRECT_GOODS_ID, DIRECT_BASE_UNIT_ID, BigDecimal.ONE,
                new BigDecimal("3.0000"), new BigDecimal("3.0000"), null, null,
                "DIRECT_OUTBOUND"});

        service.createPlanOnApproval(ORDER_ID);

        verify(jdbc).update(
                planItemInsertSql(),
                any(UUID.class), any(UUID.class), eq(DIRECT_ITEM_ID), eq(1),
                eq(DIRECT_GOODS_ID), ArgumentMatchers.<UUID>isNull(),
                eq(DIRECT_GOODS_ID), ArgumentMatchers.<UUID>isNull(),
                eq(DIRECT_BASE_UNIT_ID), eq(BigDecimal.ONE), eq(new BigDecimal("3.0000")),
                eq("DIRECT_OUTBOUND"), eq("READY_OUTBOUND"), eq(new BigDecimal("3.0000")),
                eq(WAREHOUSE_ID), eq(false), fingerprint(),
                ArgumentMatchers.<UUID>isNull(), ArgumentMatchers.<UUID>isNull(),
                eq(ACTOR_ID), eq(ACTOR_ID));
        verify(jdbc).update(
                planItemInsertSql(),
                any(UUID.class), any(UUID.class), eq(MAKE_ITEM_ID), eq(2),
                eq(MAKE_GOODS_ID), ArgumentMatchers.<UUID>isNull(),
                eq(MAKE_GOODS_ID), ArgumentMatchers.<UUID>isNull(),
                eq(MAKE_BASE_UNIT_ID), eq(BigDecimal.ONE), eq(new BigDecimal("4.0000")),
                eq("MAKE_THEN_OUTBOUND"), eq("ACTION_REQUIRED"), eq(BigDecimal.ZERO),
                eq(WAREHOUSE_ID), eq(true), fingerprint(),
                ArgumentMatchers.<UUID>isNull(), ArgumentMatchers.<UUID>isNull(),
                eq(ACTOR_ID), eq(ACTOR_ID));
        verify(issueItemRepo).save(ArgumentMatchers.argThat(item ->
                directPlanItemId.equals(item.getPlanItemId())
                        && DIRECT_GOODS_ID.equals(item.getGoodsId())
                        && item.getQty().compareTo(new BigDecimal("3.0000")) == 0));
        verify(chainNotice).notifySubcontractOutboundReady(any());
        verify(chainNotice).notifySubcontractPrepareShortage(any());
    }

    @Test
    void issueApprovalBeyondPlanIsRejectedByCas() {
        issueRows = rows(new Object[]{
                UUID.randomUUID(), UUID.randomUUID(), new BigDecimal("50")});
        when(jdbc.update(anyString(), any(), any(), any())).thenReturn(0);

        ApiException error = assertThrows(ApiException.class,
                () -> service.syncAfterIssueApproved(UUID.randomUUID()));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertTrue(error.getMessage().contains("计划余量"));
        verify(issueRepo, never()).save(any());
    }

    @Test
    void closePlanRequiresReason() {
        ApiException error = assertThrows(ApiException.class,
                () -> service.closePlan(UUID.randomUUID(), "  "));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
    }

    @Test
    void approvalReversalAndQuantityChangesLockStockBeforePreparationState() {
        orderItemRows = List.of(
                new Object[]{MAKE_ITEM_ID,MAKE_GOODS_ID,null},
                new Object[]{DIRECT_ITEM_ID,DIRECT_GOODS_ID,null});
        List<com.uten.imp.features.stock.InventoryKey> expected = List.of(
                new com.uten.imp.features.stock.InventoryKey(MAKE_GOODS_ID,null),
                new com.uten.imp.features.stock.InventoryKey(DIRECT_GOODS_ID,null))
                .stream().sorted().toList();
        service.createPlanOnApproval(ORDER_ID);
        var approval = org.mockito.Mockito.inOrder(em,inventoryLock);
        approval.verify(em).createNativeQuery(ArgumentMatchers.argThat(sql -> sql.contains("inventory_item")));
        approval.verify(inventoryLock).lockAll(expected);
        approval.verify(em).createNativeQuery(ArgumentMatchers.argThat(sql -> sql.contains("FROM subcontract_orders WHERE id")));

        org.mockito.Mockito.clearInvocations(em,inventoryLock,jdbc);
        service.cancelForOrderReversal(ORDER_ID);
        var reversal = org.mockito.Mockito.inOrder(em,inventoryLock,jdbc);
        reversal.verify(em).createNativeQuery(ArgumentMatchers.argThat(sql -> sql.contains("inventory_item")));
        reversal.verify(inventoryLock).lockAll(expected);
        reversal.verify(jdbc).queryForList(ArgumentMatchers.argThat(sql -> sql.contains("FROM subcontract_material_plans")),
                eq(UUID.class),eq(ORDER_ID));

        org.mockito.Mockito.clearInvocations(em,inventoryLock,jdbc);
        service.applyOrderQtyChange(ORDER_ID,Map.of(),Map.of(),Map.of());
        var change = org.mockito.Mockito.inOrder(em,inventoryLock,jdbc);
        change.verify(em).createNativeQuery(ArgumentMatchers.argThat(sql -> sql.contains("inventory_item")));
        change.verify(inventoryLock).lockAll(expected);
        change.verifyNoMoreInteractions();
    }

    /**
     * V581：目标件只有一个叶子子件时，批准落的是**发子件**的
     * COMPONENT_OUTBOUND 行——父件仍是订货目标件，goods/unit 换成那颗子件，
     * 冻结单耗 = 订货换算率 × BOM 单耗，计划量 = 订货量 × 冻结单耗。
     * 仓库随即拿到出仓草稿（发的是子件），不再要求先自制。
     */
    @Test
    void approvalWithSoleLeafComponentPlansComponentOutboundAndNotifiesWarehouse() {
        BigDecimal orderQty = new BigDecimal("7");
        BigDecimal orderUnitRate = new BigDecimal("2");
        BigDecimal bomQty = new BigDecimal("3");
        BigDecimal componentUnitQty = new BigDecimal("6.000000");
        BigDecimal plannedComponentQty = new BigDecimal("42.0000");
        UUID planItemId = UUID.randomUUID();
        orderRows = rows(new Object[]{ORDER_ID, "EO-SOLE", SUPPLIER_ID, null});
        orderItemRows = rows(new Object[]{
                SOLE_ITEM_ID, SOLE_GOODS_ID, null, orderQty, 1,
                orderUnitRate, DOCUMENT_UNIT_ID, WAREHOUSE_ID});
        goodsRows = rows(new Object[]{
                SOLE_GOODS_ID, "FG-S", "单一子件委外目标件",
                SOLE_BASE_UNIT_ID, "C-01"});
        bomRowsByGoods = Map.of(SOLE_GOODS_ID, rows(new Object[]{
                UUID.randomUUID(), COMPONENT_GOODS_ID, null, bomQty}));
        soleComponentRowsByGoods = Map.of(SOLE_GOODS_ID, rows(new Object[]{
                COMPONENT_GOODS_ID, null, COMPONENT_UNIT_ID, bomQty}));
        remainingRows = rows(new Object[]{
                planItemId, SOLE_ITEM_ID, SOLE_GOODS_ID, null,
                COMPONENT_GOODS_ID, COMPONENT_UNIT_ID, componentUnitQty,
                plannedComponentQty, plannedComponentQty, null, null,
                "COMPONENT_OUTBOUND"});

        service.createPlanOnApproval(ORDER_ID);

        ArgumentCaptor<UUID> insertedPlanItemId = ArgumentCaptor.forClass(UUID.class);
        verify(jdbc).update(
                planItemInsertSql(),
                insertedPlanItemId.capture(), any(UUID.class), eq(SOLE_ITEM_ID), eq(1),
                eq(SOLE_GOODS_ID), ArgumentMatchers.<UUID>isNull(),
                eq(COMPONENT_GOODS_ID), ArgumentMatchers.<UUID>isNull(),
                eq(COMPONENT_UNIT_ID), eq(componentUnitQty), eq(plannedComponentQty),
                eq("COMPONENT_OUTBOUND"), eq("READY_OUTBOUND"), eq(plannedComponentQty),
                // 建议仓留空：批准时不占子件库存，否则子件还没到货就把财审顶回去。
                ArgumentMatchers.<UUID>isNull(), eq(true), fingerprint(),
                ArgumentMatchers.<UUID>isNull(), ArgumentMatchers.<UUID>isNull(),
                eq(ACTOR_ID), eq(ACTOR_ID));
        // 出仓明细发的是子件，父件仍记目标件（回厂按冻结单耗倒扣要靠这对身份）。
        verify(issueItemRepo).save(ArgumentMatchers.argThat(item ->
                COMPONENT_GOODS_ID.equals(item.getGoodsId())
                        && SOLE_GOODS_ID.equals(item.getParentGoodsId())
                        && COMPONENT_UNIT_ID.equals(item.getUnitId())
                        && item.getQty().compareTo(plannedComponentQty) == 0));
        verify(chainNotice).notifySubcontractOutboundReady(insertedPlanItemId.getValue());
        verify(chainNotice, never()).notifySubcontractPrepareShortage(any());
    }

    /**
     * ADR-101：子件还在采购路上时批准订货——计划行照落，但**不开出仓草稿、不叫仓库**。
     * 在此之前这里会开一张满量草稿并发通知，仓库点进去拣不出货，保存才被「合格可动用库存
     * 不足」打回，四个岗位白跑一趟。
     */
    @Test
    void soleLeafComponentWithoutChildStockPlansTheLineButStagesNoWarehouseWork() {
        BigDecimal bomQty = new BigDecimal("3");
        BigDecimal componentUnitQty = new BigDecimal("6.000000");
        BigDecimal plannedComponentQty = new BigDecimal("60.0000");
        orderRows = rows(new Object[]{ORDER_ID, "EO-SOLE-NOSTOCK", SUPPLIER_ID, null});
        orderItemRows = rows(new Object[]{
                SOLE_ITEM_ID, SOLE_GOODS_ID, null, new BigDecimal("10"), 1,
                new BigDecimal("2"), DOCUMENT_UNIT_ID, null});
        goodsRows = rows(new Object[]{
                SOLE_GOODS_ID, "FG-S", "单一子件委外件", SOLE_BASE_UNIT_ID, "C-01"});
        bomRowsByGoods = Map.of(SOLE_GOODS_ID, rows(new Object[]{
                UUID.randomUUID(), COMPONENT_GOODS_ID, null, bomQty}));
        soleComponentRowsByGoods = Map.of(SOLE_GOODS_ID, rows(new Object[]{
                COMPONENT_GOODS_ID, null, COMPONENT_UNIT_ID, bomQty}));
        remainingRows = rows(new Object[]{
                UUID.randomUUID(), SOLE_ITEM_ID, SOLE_GOODS_ID, null,
                COMPONENT_GOODS_ID, COMPONENT_UNIT_ID, componentUnitQty,
                plannedComponentQty, plannedComponentQty, null, null,
                "COMPONENT_OUTBOUND"});
        // 子件一件都没有。
        onHandForOutbound = BigDecimal.ZERO;

        service.createPlanOnApproval(ORDER_ID);

        verify(jdbc).update(
                planItemInsertSql(),
                any(UUID.class), any(UUID.class), eq(SOLE_ITEM_ID), eq(1),
                eq(SOLE_GOODS_ID), ArgumentMatchers.<UUID>isNull(),
                eq(COMPONENT_GOODS_ID), ArgumentMatchers.<UUID>isNull(),
                eq(COMPONENT_UNIT_ID), eq(componentUnitQty), eq(plannedComponentQty),
                eq("COMPONENT_OUTBOUND"), eq("READY_OUTBOUND"), eq(plannedComponentQty),
                ArgumentMatchers.<UUID>isNull(), eq(true), fingerprint(),
                ArgumentMatchers.<UUID>isNull(), ArgumentMatchers.<UUID>isNull(),
                eq(ACTOR_ID), eq(ACTOR_ID));
        verify(issueItemRepo, never()).save(any());
        verify(chainNotice, never()).notifySubcontractOutboundReady(any());
        verify(chainNotice, never()).notifySubcontractPrepareShortage(any());
    }

    /**
     * ADR-103 路线 B 锁：目标件只有一个叶子子件 (COMPONENT_OUTBOUND) 时, 子件在作业叶仓里
     * 一件都没有, 送审/批准 (requireNoMakeThenShortage) 与建单/改单 (requireSoleComponentStockAvailable)
     * 同一把锁 409, 文案大白话逐行点名委外件与子件。
     */
    @Test
    void soleLeafComponentWithoutChildStockLocksSubmitAndApprovalWithPlainMessage() {
        stageSoleComponentOrder();
        // 子件一件都没有。
        onHandForOutbound = BigDecimal.ZERO;

        ApiException submit = assertThrows(ApiException.class,
                () -> service.requireNoMakeThenShortage(ORDER_ID));
        assertEquals(ErrorCode.CONFLICT, submit.getCode());
        assertTrue(submit.getMessage().contains("仓里还一件都没有"), submit.getMessage());
        assertTrue(submit.getMessage().contains("委外件 单一子件委外件(FG-S)"), submit.getMessage());
        assertTrue(submit.getMessage().contains("子件 委外子件(COMP-1)"), submit.getMessage());
        assertTrue(submit.getMessage().contains("入库后任务中心会自动解锁"), submit.getMessage());

        ApiException draft = assertThrows(ApiException.class,
                () -> service.requireSoleComponentStockAvailable(ORDER_ID));
        assertEquals(ErrorCode.CONFLICT, draft.getCode());
        assertTrue(draft.getMessage().contains("仓里还一件都没有"), draft.getMessage());
        // Exact order provenance controls the component quantity; SKU-only stock cannot unlock it.
        verify(jdbc, org.mockito.Mockito.atLeastOnce()).query(
                ArgumentMatchers.<String>argThat(sql -> sql != null
                        && sql.contains("fn_subcontract_component_available_stock")),
                ArgumentMatchers.<RowMapper<Object[]>>any(),
                eq(SOLE_ITEM_ID));
    }

    /** ADR-103：子件入库了 (不管多少) 就解锁——同一夹具给一点现货, 送审与建单都放行。 */
    @Test
    void soleLeafComponentWithAnyChildStockUnlocksSubmitAndDraft() {
        stageSoleComponentOrder();
        onHandForOutbound = new BigDecimal("0.5");

        service.requireNoMakeThenShortage(ORDER_ID);
        service.requireSoleComponentStockAvailable(ORDER_ID);

        verify(jdbc, org.mockito.Mockito.atLeastOnce()).query(
                ArgumentMatchers.<String>argThat(sql -> sql != null
                        && sql.contains("fn_subcontract_component_available_stock")),
                ArgumentMatchers.<RowMapper<Object[]>>any(),
                eq(SOLE_ITEM_ID));
    }

    /** 单一子件委外件夹具：订货 10 x 换算率 2, BOM 单耗 3, 主档含父件与子件 (文案要用名称/编码)。 */
    private void stageSoleComponentOrder() {
        BigDecimal bomQty = new BigDecimal("3");
        orderRows = rows(new Object[]{ORDER_ID, "EO-SOLE-LOCK", SUPPLIER_ID, null});
        orderItemRows = rows(new Object[]{
                SOLE_ITEM_ID, SOLE_GOODS_ID, null, new BigDecimal("10"), 1,
                new BigDecimal("2"), DOCUMENT_UNIT_ID, null});
        goodsRows = List.of(
                new Object[]{SOLE_GOODS_ID, "FG-S", "单一子件委外件", SOLE_BASE_UNIT_ID, "C-01"},
                new Object[]{COMPONENT_GOODS_ID, "COMP-1", "委外子件", COMPONENT_UNIT_ID, "C-02"});
        bomRowsByGoods = Map.of(SOLE_GOODS_ID, rows(new Object[]{
                UUID.randomUUID(), COMPONENT_GOODS_ID, null, bomQty}));
        soleComponentRowsByGoods = Map.of(SOLE_GOODS_ID, rows(new Object[]{
                COMPONENT_GOODS_ID, null, COMPONENT_UNIT_ID, bomQty}));
    }

    private void stubNativeQueriesBySql() {
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            Query query = mock(Query.class);
            Map<String, Object> parameters = new HashMap<>();
            when(query.setParameter(anyString(), any())).thenAnswer(parameterInvocation -> {
                parameters.put(parameterInvocation.getArgument(0),
                        parameterInvocation.getArgument(1));
                return query;
            });
            when(query.getResultList()).thenAnswer(ignored -> nativeRows(sql, parameters));
            return query;
        });
    }

    private List<Object[]> nativeRows(String sql, Map<String, Object> parameters) {
        if (sql.contains("FROM subcontract_order_items inventory_item")) {
            return orderItemRows.stream().map(row -> new Object[]{row[1],row[2]}).toList();
        }
        if (sql.contains("FROM subcontract_orders WHERE id")) {
            return orderRows;
        }
        if (sql.contains("preplan_subcontract_make_task_batches")) {
            // V458：本用例订货行不来自前置自制账本，谱系查询应返回空。
            return List.of();
        }
        if (sql.contains("SELECT child.analysis_id,child.id,SUM(reservation.qty-reservation.released_qty)")
                && sql.contains("reservation.owner_type='SUBCONTRACT_ORDER_PREPARATION'")
                && sql.contains("reservation.owner_id=:orderItem")
                && sql.contains("fn_subcontract_preparation_reservation_has_qualified_origin(reservation.id)")) {
            assertTrue(orderItemRows.stream()
                    .anyMatch(row -> row[0].equals(parameters.get("orderItem"))),
                    "direct preparation must be looked up by this order's exact item UUID");
            // These ordinary approval fixtures have no prior original-order FG holder.
            return List.of();
        }
        if (sql.contains("FROM subcontract_order_items item")) {
            return orderItemRows;
        }
        if (sql.contains("FROM goods WHERE id IN")) {
            return goodsRows;
        }
        if (sql.contains("fn_subcontract_sole_component_goods")) {
            // V581：判据本体在数据库函数里，聚焦单测按夹具给「是/不是」。
            return soleComponentRowsByGoods.getOrDefault(
                    parameters.get("goodsId"), List.of());
        }
        if (sql.contains("FROM goods_bom_items bom")) {
            return bomRowsByGoods.getOrDefault(parameters.get("goodsId"), List.of());
        }
        if (sql.contains("SELECT issue_item.id, issue_item.plan_item_id, issue_item.qty")) {
            // ADR-101 起草稿带着建议仓建出来，于是 createDraftForLines 末尾真的会走进
            // reserveDraft。本文件是「批准时怎么排计划、建什么草稿、通知谁」的聚焦单测，
            // 预留与库存占用由 SubcontractMaterialPlanStateMachineTest 和真库全链
            // SubcontractSoleComponentUnlockEndToEndTest 覆盖；这里返回空行让它提前返回，
            // 不把整套预留 SQL 搬进来。
            return List.of();
        }
        if (sql.contains("FROM subcontract_material_issue_items")
                && sql.contains("WHERE issue_id")) {
            return issueRows;
        }
        throw new AssertionError("unexpected native SQL in focused test: " + sql);
    }

    private static String planItemInsertSql() {
        return ArgumentMatchers.argThat(sql -> sql != null
                && sql.contains("INSERT INTO subcontract_material_plan_items"));
    }

    private static String fingerprint() {
        return ArgumentMatchers.argThat(value -> value != null
                && value.matches("[0-9a-f]{64}"));
    }

    private static List<Object[]> rows(Object[] row) {
        return List.<Object[]>of(row);
    }
}
