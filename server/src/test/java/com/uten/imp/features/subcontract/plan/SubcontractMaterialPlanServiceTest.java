package com.uten.imp.features.subcontract.plan;

import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssue;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueItem;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueItemRepository;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentMatchers;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;

import java.math.BigDecimal;
import java.util.List;
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
 * 委外发料计划服务（V304）定向单测：
 * BOM 展开建计划+自动全量草稿 / 无 BOM 不建 / 出仓审核 CAS 防超 / 关闭计划必填原因。
 */
class SubcontractMaterialPlanServiceTest {

    private EntityManager em;
    private JdbcTemplate jdbc;
    private SubcontractMaterialIssueRepository issueRepo;
    private SubcontractMaterialIssueItemRepository issueItemRepo;
    private SubcontractMaterialPlanService service;

    private static final UUID ORDER_ID = UUID.randomUUID();
    private static final UUID SUPPLIER_ID = UUID.randomUUID();
    private static final UUID ORDER_ITEM_ID = UUID.randomUUID();
    private static final UUID PARENT_GOODS = UUID.randomUUID();
    private static final UUID CHILD_GOODS = UUID.randomUUID();
    private static final UUID CHILD_COLOR = UUID.randomUUID();
    private static final UUID CHILD_UNIT = UUID.randomUUID();

    @BeforeEach
    void setUp() {
        em = mock(EntityManager.class);
        jdbc = mock(JdbcTemplate.class);
        issueRepo = mock(SubcontractMaterialIssueRepository.class);
        issueItemRepo = mock(SubcontractMaterialIssueItemRepository.class);
        DocNumberService docNumber = mock(DocNumberService.class);
        when(docNumber.nextNumber(eq(DocNumberPrefix.SUB_MATERIAL_ISSUE)))
                .thenReturn("EC-TEST-0001");
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.requireId()).thenReturn(UUID.randomUUID());
        service = new SubcontractMaterialPlanService(
                em, jdbc, docNumber, issueRepo, issueItemRepo, currentUser);
    }

    /** 财务批准时：BOM 一级子件展开 → 计划行(100×2=200) + 自动全量出仓草稿。 */
    @Test
    void approvalExpandsBomAndCreatesFullDraft() {
        Query orderQuery = mock(Query.class);
        when(orderQuery.setParameter(anyString(), any())).thenReturn(orderQuery);
        when(orderQuery.getResultList()).thenReturn(java.util.Arrays.<Object[]>asList(new Object[]{ORDER_ID, "EO-1", SUPPLIER_ID, null}));
        // em.createNativeQuery 依次：订单头 / 订货明细 / BOM / 子件主档 /（草稿）子件主档
        Query q1 = mock(Query.class);
        when(q1.setParameter(anyString(), any())).thenReturn(q1);
        when(q1.getResultList()).thenAnswer(inv -> java.util.Arrays.<Object[]>asList(
                new Object[]{ORDER_ID, "EO-1", SUPPLIER_ID, null}));
        Query q2 = mock(Query.class);
        when(q2.setParameter(anyString(), any())).thenReturn(q2);
        when(q2.getResultList()).thenAnswer(inv -> java.util.Arrays.<Object[]>asList(
                new Object[]{ORDER_ITEM_ID, PARENT_GOODS, null, new BigDecimal("100"), 1}));
        Query q3 = mock(Query.class);
        when(q3.setParameter(anyString(), any())).thenReturn(q3);
        when(q3.getResultList()).thenAnswer(inv -> java.util.Arrays.<Object[]>asList(
                new Object[]{PARENT_GOODS, CHILD_GOODS, new BigDecimal("2"), CHILD_COLOR}));
        Query q4 = mock(Query.class);
        when(q4.setParameter(anyString(), any())).thenReturn(q4);
        when(q4.getResultList()).thenAnswer(inv -> java.util.Arrays.<Object[]>asList(
                new Object[]{CHILD_GOODS, "M-1", "材料", CHILD_UNIT, "B-02"}));
        when(em.createNativeQuery(anyString())).thenReturn(q1, q2, q3, q4, q4);

        // remainingLines（createDraftForPlan 内）：计划行剩余 = 200
        UUID planItemId = UUID.randomUUID();
        when(jdbc.query(anyString(), ArgumentMatchers.<RowMapper<Object[]>>any(), any(Object.class)))
                .thenAnswer(inv -> {
                    // 取出刚写入的计划行 id：测试里直接给一个固定行（planned=200, remaining=200）
                    return java.util.Arrays.<Object[]>asList(new Object[]{
                            planItemId, ORDER_ITEM_ID, PARENT_GOODS, null,
                            CHILD_GOODS, CHILD_UNIT, new BigDecimal("2"),
                            new BigDecimal("200"), new BigDecimal("200"), CHILD_COLOR});
                });

        service.createPlanOnApproval(ORDER_ID);

        // 计划头落库（status='OPEN' 为 SQL 字面量，参数：planId/orderId/billNo/supplier/actor/actor）
        verify(jdbc).update(
                ArgumentMatchers.<String>argThat(
                        sql -> sql != null && sql.contains("INSERT INTO subcontract_material_plans")),
                any(UUID.class), eq(ORDER_ID), eq("EO-1"), eq(SUPPLIER_ID),
                any(UUID.class), any(UUID.class));
        verify(jdbc).update(
                ArgumentMatchers.<String>argThat(
                        sql -> sql != null && sql.contains("INSERT INTO subcontract_material_plan_items")),
                any(UUID.class), any(UUID.class), eq(ORDER_ITEM_ID), eq(1),
                eq(PARENT_GOODS), ArgumentMatchers.<UUID>isNull(),
                eq(CHILD_GOODS), eq(CHILD_COLOR), eq(CHILD_UNIT),
                eq(new BigDecimal("2")),
                ArgumentMatchers.<BigDecimal>argThat(qty -> qty.compareTo(new BigDecimal("200")) == 0),
                any(UUID.class), any(UUID.class));
        // 草稿：委外商随订货单、数量=计划全量、planItemId 挂接
        verify(issueRepo).save(ArgumentMatchers.argThat(draft ->
                draft.getStatus() == 0
                        && SUPPLIER_ID.equals(draft.getSupplierId())
                        && draft.getMakerId() == null
                        && "EC-TEST-0001".equals(draft.getBillNo())));
        verify(issueItemRepo).save(ArgumentMatchers.argThat(item ->
                item.getQty().compareTo(new BigDecimal("200")) == 0
                        && planItemId.equals(item.getPlanItemId())
                        && ORDER_ITEM_ID.equals(item.getOrderItemId())
                        && CHILD_GOODS.equals(item.getGoodsId())
                        && CHILD_COLOR.equals(item.getColorId())
                        && CHILD_UNIT.equals(item.getUnitId())));
    }

    /** 订货货品无 BOM 子件 → 不建计划、不生草稿（委外商自备料）。 */
    @Test
    void approvalWithoutBomCreatesNothing() {
        Query q1 = mock(Query.class);
        when(q1.setParameter(anyString(), any())).thenReturn(q1);
        when(q1.getResultList()).thenAnswer(inv -> java.util.Arrays.<Object[]>asList(
                new Object[]{ORDER_ID, "EO-2", SUPPLIER_ID, null}));
        Query q2 = mock(Query.class);
        when(q2.setParameter(anyString(), any())).thenReturn(q2);
        when(q2.getResultList()).thenAnswer(inv -> java.util.Arrays.<Object[]>asList(
                new Object[]{ORDER_ITEM_ID, PARENT_GOODS, null, new BigDecimal("100"), 1}));
        Query q3 = mock(Query.class);
        when(q3.setParameter(anyString(), any())).thenReturn(q3);
        when(q3.getResultList()).thenAnswer(inv -> java.util.Arrays.<Object[]>asList());
        when(em.createNativeQuery(anyString())).thenReturn(q1, q2, q3);

        service.createPlanOnApproval(ORDER_ID);

        verify(jdbc, never()).update(anyString(), any(Object[].class));
        verify(issueRepo, never()).save(any());
    }

    /** 出仓审核回写：CAS 未命中（超计划/并发）→ 409 且不生下一批草稿。 */
    @Test
    void issueApprovalBeyondPlanIsRejected() {
        Query lineQuery = mock(Query.class);
        when(lineQuery.setParameter(anyString(), any())).thenReturn(lineQuery);
        when(lineQuery.getResultList()).thenAnswer(inv -> java.util.Arrays.<Object[]>asList(
                new Object[]{UUID.randomUUID(), UUID.randomUUID(), new BigDecimal("50")}));
        when(em.createNativeQuery(anyString())).thenReturn(lineQuery);
        when(jdbc.update(anyString(), any(), any(), any())).thenReturn(0); // CAS 未命中

        ApiException error = assertThrows(ApiException.class,
                () -> service.syncAfterIssueApproved(UUID.randomUUID()));
        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertTrue(error.getMessage().contains("计划余量"));
    }

    /** 「不再出仓」必须填原因。 */
    @Test
    void closePlanRequiresReason() {
        ApiException error = assertThrows(ApiException.class,
                () -> service.closePlan(UUID.randomUUID(), "  "));
        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
    }
}
