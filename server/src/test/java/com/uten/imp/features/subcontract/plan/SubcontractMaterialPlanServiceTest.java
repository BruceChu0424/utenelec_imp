package com.uten.imp.features.subcontract.plan;

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
    private static final UUID SUPPLIER_ID = UUID.randomUUID();
    private static final UUID ACTOR_ID = UUID.randomUUID();
    private static final UUID DIRECT_ITEM_ID = UUID.randomUUID();
    private static final UUID MAKE_ITEM_ID = UUID.randomUUID();
    private static final UUID DIRECT_GOODS_ID = UUID.randomUUID();
    private static final UUID MAKE_GOODS_ID = UUID.randomUUID();
    private static final UUID COMPONENT_GOODS_ID = UUID.randomUUID();
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
        stubNativeQueriesBySql();
        when(jdbc.query(
                ArgumentMatchers.<String>argThat(sql -> sql != null
                        && sql.contains("FROM subcontract_material_plan_items pi")),
                ArgumentMatchers.<RowMapper<Object[]>>any(), any(Object.class)))
                .thenAnswer(invocation -> remainingRows);

        DocNumberService docNumber = mock(DocNumberService.class);
        when(docNumber.nextNumber(eq(DocNumberPrefix.SUB_MATERIAL_ISSUE)))
                .thenReturn("EC-TEST-0001");
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.requireId()).thenReturn(ACTOR_ID);
        service = new SubcontractMaterialPlanService(
                em, jdbc, docNumber, issueRepo, issueItemRepo, currentUser,
                chainNotice, inventoryLock);
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
                eq(WAREHOUSE_ID), eq(false), fingerprint(), eq(ACTOR_ID), eq(ACTOR_ID));
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
                eq(WAREHOUSE_ID), eq(true), fingerprint(), eq(ACTOR_ID), eq(ACTOR_ID));
        verify(issueRepo, never()).save(any());
        verify(issueItemRepo, never()).save(any());
        verify(chainNotice).notifySubcontractPreparationRequired(insertedPlanItemId.getValue());
        verify(chainNotice, never()).notifySubcontractOutboundReady(any());
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
                eq(WAREHOUSE_ID), eq(false), fingerprint(), eq(ACTOR_ID), eq(ACTOR_ID));
        verify(jdbc).update(
                planItemInsertSql(),
                any(UUID.class), any(UUID.class), eq(MAKE_ITEM_ID), eq(2),
                eq(MAKE_GOODS_ID), ArgumentMatchers.<UUID>isNull(),
                eq(MAKE_GOODS_ID), ArgumentMatchers.<UUID>isNull(),
                eq(MAKE_BASE_UNIT_ID), eq(BigDecimal.ONE), eq(new BigDecimal("4.0000")),
                eq("MAKE_THEN_OUTBOUND"), eq("ACTION_REQUIRED"), eq(BigDecimal.ZERO),
                eq(WAREHOUSE_ID), eq(true), fingerprint(), eq(ACTOR_ID), eq(ACTOR_ID));
        verify(issueItemRepo).save(ArgumentMatchers.argThat(item ->
                directPlanItemId.equals(item.getPlanItemId())
                        && DIRECT_GOODS_ID.equals(item.getGoodsId())
                        && item.getQty().compareTo(new BigDecimal("3.0000")) == 0));
        verify(chainNotice).notifySubcontractOutboundReady(any());
        verify(chainNotice).notifySubcontractPreparationRequired(any());
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
        if (sql.contains("FROM subcontract_orders WHERE id")) {
            return orderRows;
        }
        if (sql.contains("FROM subcontract_order_items item")) {
            return orderItemRows;
        }
        if (sql.contains("FROM goods WHERE id IN")) {
            return goodsRows;
        }
        if (sql.contains("FROM goods_bom_items bom")) {
            return bomRowsByGoods.getOrDefault(parameters.get("goodsId"), List.of());
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
