package com.uten.imp.features.subcontract.plan;

import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.InventoryMutationLock;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssue;
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
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.function.BiFunction;
import java.util.function.Consumer;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.atLeastOnce;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class SubcontractMaterialPlanStateMachineTest {

    private static final UUID ACTOR_ID = UUID.randomUUID();

    private EntityManager em;
    private JdbcTemplate jdbc;
    private SubcontractMaterialIssueRepository issueRepo;
    private SubcontractMaterialIssueItemRepository issueItemRepo;
    private ChainNoticeService chainNotice;
    private InventoryMutationLock inventoryLock;
    private SubcontractMaterialPlanService service;
    private List<NativeCall> nativeCalls;
    private BiFunction<String, Map<String, Object>, List<?>> listAnswer;
    private BiFunction<String, Map<String, Object>, Object> singleAnswer;
    private NativeUpdateAnswer updateAnswer;

    @BeforeEach
    void setUp() {
        em = mock(EntityManager.class);
        jdbc = mock(JdbcTemplate.class);
        issueRepo = mock(SubcontractMaterialIssueRepository.class);
        issueItemRepo = mock(SubcontractMaterialIssueItemRepository.class);
        chainNotice = mock(ChainNoticeService.class);
        inventoryLock = mock(InventoryMutationLock.class);
        nativeCalls = new ArrayList<>();
        listAnswer = (sql, parameters) -> List.of();
        singleAnswer = (sql, parameters) -> 0L;
        updateAnswer = (sql, parameters) -> 1;
        stubNativeQueries();

        DocNumberService numbers = mock(DocNumberService.class);
        when(numbers.nextNumber(eq(DocNumberPrefix.SUB_MATERIAL_ISSUE)))
                .thenReturn("EC-STATE-1", "EC-STATE-2", "EC-STATE-3");
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.requireId()).thenReturn(ACTOR_ID);
        service = new SubcontractMaterialPlanService(
                em, jdbc, numbers, issueRepo, issueItemRepo, currentUser,
                chainNotice, inventoryLock,
                mock(com.uten.imp.application.port.SubcontractOrderPreparationPort.class));
    }

    @Test
    void directDraftLocksInventoryReadsAvailableViewAndCreatesOwnedReservation()
            throws Exception {
        UUID issueId = UUID.randomUUID();
        UUID issueItemId = UUID.randomUUID();
        UUID planItemId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID colorId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID balanceId = UUID.randomUUID();
        BigDecimal qty = new BigDecimal("6.0000");
        String fingerprint = emptyBomFingerprint(goodsId);
        listAnswer = (sql, parameters) -> {
            if (sql.contains("from subcontract_material_issue_items issue_item")
                    && sql.contains("for update of plan_item")) {
                return rows(new Object[]{
                        issueItemId, planItemId, qty, goodsId, colorId,
                        "DIRECT_OUTBOUND", "READY_OUTBOUND", null,
                        false, fingerprint});
            }
            if (sql.contains("from goods_bom_items bom")) {
                return List.of();
            }
            if (sql.contains("join v_stock_available available")) {
                return rows(new Object[]{balanceId, new BigDecimal("9.0000")});
            }
            return List.of();
        };

        service.reserveDraft(issueId, warehouseId);

        verify(inventoryLock).lockAll(ArgumentMatchers.argThat(keys ->
                keys.size() == 1
                        && keys.contains(new InventoryKey(goodsId, colorId))));
        NativeCall available = oneCall("join v_stock_available available");
        assertThat(available.parameters())
                .containsEntry("warehouseId", warehouseId)
                .containsEntry("goodsId", goodsId)
                .containsEntry("colorId", colorId);
        NativeCall inserted = oneCall("insert into stock_reservations");
        assertThat(inserted.sql())
                .contains("'subcontract_outbound', :planitemid")
                .contains("'stock_balance', :balanceid");
        assertThat(inserted.parameters())
                .containsEntry("issueId", issueId)
                .containsEntry("planItemId", planItemId)
                .containsEntry("balanceId", balanceId)
                .containsEntry("key", "SC-OUT-DRAFT:" + issueItemId);
    }

    @Test
    void approvalConsumesOnlyPlanOwnedReservationAndReverseRestoresAllocation() {
        UUID issueId = UUID.randomUUID();
        UUID issueItemId = UUID.randomUUID();
        UUID planItemId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID reservationId = UUID.randomUUID();
        UUID allocationId = UUID.randomUUID();
        BigDecimal qty = new BigDecimal("5.0000");
        listAnswer = (sql, parameters) -> {
            if (sql.contains("select issue_item.id, issue_item.plan_item_id")
                    && !sql.contains("for update of plan_item")) {
                return rows(new Object[]{issueItemId, planItemId, qty});
            }
            if (sql.contains("from stock_reservations")
                    && sql.contains("owner_id = :planitemid")
                    && sql.contains("for update")) {
                return rows(new Object[]{reservationId, qty});
            }
            if (sql.contains("from subcontract_outbound_issue_reservation_allocations")
                    && sql.contains("status = 'effective'")) {
                return rows(new Object[]{allocationId, reservationId, qty});
            }
            return List.of();
        };

        service.consumeOutboundReservations(issueId, warehouseId);
        service.reverseOutboundReservations(issueId);

        NativeCall ownerSelection = oneCall("owner_id = :planitemid");
        assertThat(ownerSelection.parameters())
                .containsEntry("planItemId", planItemId)
                .containsEntry("warehouseId", warehouseId);
        NativeCall allocation = oneCall(
                "insert into subcontract_outbound_issue_reservation_allocations");
        assertThat(allocation.parameters())
                .containsEntry("issueItemId", issueItemId)
                .containsEntry("planItemId", planItemId)
                .containsEntry("reservationId", reservationId)
                .containsEntry("qty", qty);
        assertThat(oneCall("set consumed_qty = consumed_qty - :qty").parameters())
                .containsEntry("id", reservationId)
                .containsEntry("qty", qty);
        assertThat(oneCall("set status = 'reversed'").parameters())
                .containsEntry("id", allocationId);
    }

    @Test
    void restoredDirectReservationIsReplacedWhenRegeneratedDraftIsSaved()
            throws Exception {
        UUID planId = UUID.randomUUID();
        UUID orderItemId = UUID.randomUUID();
        UUID planItemId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        UUID supplierId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID balanceId = UUID.randomUUID();
        UUID reservationId = UUID.randomUUID();
        UUID allocationId = UUID.randomUUID();
        BigDecimal qty = new BigDecimal("8.0000");
        List<Object[]> remaining = rows(new Object[]{
                planItemId, orderItemId, goodsId, null, goodsId, unitId,
                BigDecimal.ONE, qty, qty, null, null, "DIRECT_OUTBOUND"});
        stubOpenPlanAndRemaining(planId, remaining);
        String fingerprint = emptyBomFingerprint(goodsId);
        listAnswer = (sql, parameters) -> {
            if (sql.contains("from subcontract_outbound_issue_reservation_allocations")) {
                return rows(new Object[]{allocationId, reservationId, qty});
            }
            if (sql.contains("from subcontract_material_plans p")
                    && sql.contains("join subcontract_orders o")) {
                return rows(new Object[]{
                        "EO-REGEN", supplierId, LocalDate.of(2026, 8, 30)});
            }
            if (sql.contains("from goods where id in")) {
                return rows(new Object[]{
                        goodsId, "FG-R", "红冲后补发目标件", unitId, "A-01"});
            }
            if (sql.contains("from subcontract_material_issue_items issue_item")
                    && sql.contains("for update of plan_item")) {
                return rows(new Object[]{
                        UUID.randomUUID(), planItemId, qty, goodsId, null,
                        "DIRECT_OUTBOUND", "READY_OUTBOUND", null,
                        false, fingerprint});
            }
            if (sql.contains("from goods_bom_items bom")) {
                return List.of();
            }
            if (sql.contains("join v_stock_available available")) {
                return rows(new Object[]{balanceId, qty});
            }
            return List.of();
        };

        service.reverseOutboundReservations(UUID.randomUUID());
        UUID regeneratedIssueId = service.regenerateDraft(planId);
        service.reserveDraft(regeneratedIssueId, warehouseId);

        int restoreIndex = callIndex("set consumed_qty = consumed_qty - :qty");
        int replacementIndex = callIndex(
                "release_reason = 'subcontract_outbound_draft_replaced'");
        int insertionIndex = lastCallIndex("insert into stock_reservations");
        assertThat(restoreIndex).isLessThan(replacementIndex);
        assertThat(replacementIndex).isLessThan(insertionIndex);
        assertThat(oneCall("source_doc_type = 'subcontract_outbound_draft'")
                .parameters()).containsEntry("issueId", regeneratedIssueId);
        assertThat(nativeCalls.get(insertionIndex).parameters())
                .containsEntry("planItemId", planItemId)
                .containsEntry("balanceId", balanceId);
    }

    @Test
    void makePreparationReleasesOutboundOnFirstSliceAndDraftsFullBatchAtCompletion() {
        UUID planId = UUID.randomUUID();
        UUID planItemId = UUID.randomUUID();
        UUID orderItemId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID supplierId = UUID.randomUUID();
        UUID analysisId = UUID.randomUUID();
        UUID analysisItemId = UUID.randomUUID();
        List<Object[]> inboundRows = new ArrayList<>();
        listAnswer = (sql, parameters) -> {
            if (sql.contains("from stock_document_items stock_item")) {
                return List.copyOf(inboundRows);
            }
            if (sql.contains("from goods where id in")) {
                return rows(new Object[]{
                        goodsId, "FG-M", "前置自制目标件", unitId, "M-01"});
            }
            return List.of();
        };
        inboundRows.add(finishedInboundRow(
                planItemId, planId, UUID.randomUUID(), goodsId,
                new BigDecimal("2"), warehouseId, new BigDecimal("10"),
                BigDecimal.ZERO, supplierId, analysisId, analysisItemId, unitId));
        inboundRows.add(finishedInboundRow(
                planItemId, planId, UUID.randomUUID(), goodsId,
                new BigDecimal("3"), warehouseId, new BigDecimal("10"),
                BigDecimal.ZERO, supplierId, analysisId, analysisItemId, unitId));

        service.afterFinishedInboundApproved(UUID.randomUUID(), warehouseId);

        // V458：首片实收即释放可出仓并通知仓库一次；中间追加片不再打扰。
        verify(chainNotice, times(1)).notifySubcontractOutboundReady(planItemId);
        verify(issueRepo, never()).save(any());
        inboundRows.clear();
        inboundRows.add(finishedInboundRow(
                planItemId, planId, UUID.randomUUID(), goodsId,
                new BigDecimal("5"), warehouseId, new BigDecimal("10"),
                new BigDecimal("5"), supplierId, analysisId, analysisItemId, unitId));
        List<Object[]> ready = rows(new Object[]{
                planItemId, orderItemId, goodsId, null, goodsId, unitId,
                BigDecimal.ONE, new BigDecimal("10"), new BigDecimal("10"),
                null, warehouseId, "MAKE_THEN_OUTBOUND"});
        stubRemaining(planId, ready);

        service.afterFinishedInboundApproved(UUID.randomUUID(), warehouseId);

        verify(issueRepo, times(1)).save(any());
        verify(issueItemRepo, times(1)).save(ArgumentMatchers.argThat(item ->
                planItemId.equals(item.getPlanItemId())
                        && item.getQty().compareTo(new BigDecimal("10")) == 0));
        verify(chainNotice, times(2)).notifySubcontractOutboundReady(planItemId);
        assertThat(callsContaining("insert into stock_reservations"))
                .hasSize(3)
                .allSatisfy(call -> {
                    assertThat(call.sql()).contains(
                            "'subcontract_outbound', :planitemid",
                            "'production_finished_in', :stockitemid");
                    assertThat(call.parameters()).containsEntry("planItemId", planItemId);
                });
    }

    @Test
    void finishedInboundCandidateMismatchesFailClosedBeforeReservation() {
        UUID planItemId = UUID.randomUUID();
        UUID planId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID supplierId = UUID.randomUUID();
        UUID analysisId = UUID.randomUUID();
        UUID analysisItemId = UUID.randomUUID();
        Object[] exact = finishedInboundRow(
                planItemId, planId, UUID.randomUUID(), goodsId,
                new BigDecimal("5"), warehouseId, new BigDecimal("5"),
                BigDecimal.ZERO, supplierId, analysisId, analysisItemId, unitId);
        AtomicReference<Object[]> candidate = new AtomicReference<>(exact);
        listAnswer = (sql, parameters) ->
                sql.contains("from stock_document_items stock_item")
                        ? rows(candidate.get()) : List.of();
        Map<String, Consumer<Object[]>> mismatches = new LinkedHashMap<>();
        mismatches.put("upstream analysis", row -> row[12] = UUID.randomUUID());
        mismatches.put("analysis link", row -> row[14] = UUID.randomUUID());
        mismatches.put("analysis link status", row -> row[16] = "SUBMITTED");
        mismatches.put("goods", row -> row[3] = UUID.randomUUID());
        mismatches.put("color", row -> row[4] = UUID.randomUUID());
        mismatches.put("unit", row -> row[21] = UUID.randomUUID());
        mismatches.put("rate", row -> row[22] = new BigDecimal("2"));
        mismatches.put("production status", row -> row[28] = (short) 0);

        mismatches.forEach((label, mutation) -> {
            Object[] mismatched = exact.clone();
            mutation.accept(mismatched);
            candidate.set(mismatched);

            ApiException error = assertThrows(ApiException.class,
                    () -> service.afterFinishedInboundApproved(
                            UUID.randomUUID(), warehouseId), label);
            assertThat(error.getMessage())
                    .as(label)
                    .contains("UUID、货色、单位或换算率不一致");
        });
        assertThat(callsContaining("insert into stock_reservations")).isEmpty();
        verify(issueRepo, never()).save(any());
    }

    @Test
    void regenerateGroupsMakeLinesIntoSeparateDraftsPerFrozenWarehouse() {
        UUID planId = UUID.randomUUID();
        UUID supplierId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        UUID warehouseA = UUID.randomUUID();
        UUID warehouseB = UUID.randomUUID();
        List<Object[]> remaining = List.of(
                readyRow(UUID.randomUUID(), UUID.randomUUID(), goodsId, unitId, warehouseA),
                readyRow(UUID.randomUUID(), UUID.randomUUID(), goodsId, unitId, warehouseA),
                readyRow(UUID.randomUUID(), UUID.randomUUID(), goodsId, unitId, warehouseB));
        stubOpenPlanAndRemaining(planId, remaining);
        listAnswer = (sql, parameters) -> {
            if (sql.contains("from subcontract_material_plans p")
                    && sql.contains("join subcontract_orders o")) {
                return rows(new Object[]{
                        "EO-WH", supplierId, LocalDate.of(2026, 8, 30)});
            }
            if (sql.contains("from goods where id in")) {
                return rows(new Object[]{
                        goodsId, "FG-W", "跨仓目标件", unitId, "W-01"});
            }
            return List.of();
        };

        service.regenerateDraft(planId);

        ArgumentCaptor<SubcontractMaterialIssue> drafts =
                ArgumentCaptor.forClass(SubcontractMaterialIssue.class);
        verify(issueRepo, times(2)).save(drafts.capture());
        assertThat(drafts.getAllValues())
                .extracting(SubcontractMaterialIssue::getWarehouseId)
                .containsExactlyInAnyOrder(warehouseA, warehouseB);
        verify(issueItemRepo, times(3)).save(any());
    }

    @Test
    void finishedInboundReverseRejectsAlreadyConsumedTarget() {
        UUID reservationId = UUID.randomUUID();
        UUID planItemId = UUID.randomUUID();
        listAnswer = (sql, parameters) -> sql.contains("from stock_reservations reservation")
                ? rows(new Object[]{
                        reservationId, planItemId, new BigDecimal("5"),
                        BigDecimal.ONE, BigDecimal.ZERO})
                : List.of();

        ApiException error = assertThrows(ApiException.class,
                () -> service.beforeFinishedInboundReversed(UUID.randomUUID()));

        assertThat(error.getMessage()).contains("已经委外出仓");
    }

    @Test
    void finishedInboundReverseRejectsPendingOutboundDraft() {
        UUID reservationId = UUID.randomUUID();
        UUID planItemId = UUID.randomUUID();
        listAnswer = (sql, parameters) -> sql.contains("from stock_reservations reservation")
                ? rows(new Object[]{
                        reservationId, planItemId, new BigDecimal("5"),
                        BigDecimal.ZERO, BigDecimal.ZERO})
                : List.of();
        singleAnswer = (sql, parameters) ->
                sql.contains("from subcontract_material_issue_items issue_item")
                        ? 1L : 0L;

        ApiException error = assertThrows(ApiException.class,
                () -> service.beforeFinishedInboundReversed(UUID.randomUUID()));

        assertThat(error.getMessage()).contains("已有委外出仓草稿");
    }

    @Test
    void orderReversalRejectsRunningMakePreparation() {
        when(jdbc.queryForObject(
                ArgumentMatchers.<String>argThat(sql -> sql != null
                        && sql.contains("preparation_status IN")),
                eq(Long.class), any(UUID.class))).thenReturn(1L);

        ApiException error = assertThrows(ApiException.class,
                () -> service.requireOrderReversalAllowed(UUID.randomUUID()));

        assertThat(error.getMessage()).contains("进行中的前置自制链");
    }

    @Test
    void fullIssueReverseRestoresReadyOutboundStatus() {
        UUID planItemId = UUID.randomUUID();
        BigDecimal qty = new BigDecimal("12.0000");
        listAnswer = (sql, parameters) ->
                sql.contains("select issue_item.plan_item_id, issue_item.qty")
                        ? rows(new Object[]{planItemId, qty, "DIRECT_OUTBOUND"}) : List.of();
        when(jdbc.update(anyString(), any(), any(), any())).thenReturn(1);

        UUID issueId = UUID.randomUUID();
        service.syncAfterIssueReversed(issueId);

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(jdbc).update(sql.capture(), eq(qty), eq(qty), eq(planItemId));
        assertThat(compact(sql.getValue()))
                .contains("preparation_status = case")
                .contains("preparation_status = 'outbound_complete'")
                .contains("then 'ready_outbound'")
                .contains("greatest(issued_qty - ?, 0) < planned_qty");
        verify(chainNotice).notifySubcontractOutboundReversed(issueId);
    }

    private void stubNativeQueries() {
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = compact(invocation.getArgument(0));
            Map<String, Object> parameters = new HashMap<>();
            NativeCall call = new NativeCall(sql, parameters);
            nativeCalls.add(call);
            Query query = mock(Query.class);
            when(query.setParameter(anyString(), any())).thenAnswer(parameter -> {
                parameters.put(parameter.getArgument(0), parameter.getArgument(1));
                return query;
            });
            when(query.getResultList()).thenAnswer(
                    ignored -> listAnswer.apply(sql, parameters));
            when(query.getSingleResult()).thenAnswer(
                    ignored -> singleAnswer.apply(sql, parameters));
            when(query.executeUpdate()).thenAnswer(
                    ignored -> updateAnswer.apply(sql, parameters));
            return query;
        });
    }

    private void stubOpenPlanAndRemaining(
            UUID planId, List<Object[]> remaining) {
        when(jdbc.query(
                ArgumentMatchers.<String>argThat(sql -> sql != null
                        && sql.contains("SELECT status FROM subcontract_material_plans")),
                ArgumentMatchers.<RowMapper<String>>any(), eq(planId)))
                .thenReturn(List.of("OPEN"));
        stubRemaining(planId, remaining);
    }

    private void stubRemaining(UUID planId, List<Object[]> remaining) {
        when(jdbc.query(
                ArgumentMatchers.<String>argThat(sql -> sql != null
                        && sql.contains("FROM subcontract_material_plan_items pi")),
                ArgumentMatchers.<RowMapper<Object[]>>any(), eq(planId)))
                .thenReturn(remaining);
    }

    private Object[] finishedInboundRow(
            UUID planItemId, UUID planId, UUID stockItemId, UUID goodsId,
            BigDecimal qty, UUID warehouseId, BigDecimal planned,
            BigDecimal prepared, UUID supplierId,
            UUID analysisId, UUID analysisItemId, UUID unitId) {
        return new Object[]{
                planItemId, planId, stockItemId, goodsId, null, qty,
                warehouseId, planned, prepared, "EO-MAKE", supplierId,
                LocalDate.of(2026, 8, 30),
                analysisId, analysisItemId,
                analysisId, analysisItemId, "APPROVED",
                goodsId, null, unitId, BigDecimal.ONE,
                unitId, BigDecimal.ONE,
                goodsId, null, unitId,
                analysisId, analysisItemId, (short) 1};
    }

    private Object[] readyRow(
            UUID planItemId, UUID orderItemId, UUID goodsId,
            UUID unitId, UUID warehouseId) {
        BigDecimal qty = new BigDecimal("4.0000");
        return new Object[]{
                planItemId, orderItemId, goodsId, null, goodsId, unitId,
                BigDecimal.ONE, qty, qty, null, warehouseId,
                "MAKE_THEN_OUTBOUND"};
    }

    private NativeCall oneCall(String fragment) {
        List<NativeCall> matches = callsContaining(fragment);
        assertThat(matches).as("native SQL containing %s", fragment).hasSize(1);
        return matches.getFirst();
    }

    private List<NativeCall> callsContaining(String fragment) {
        return nativeCalls.stream()
                .filter(call -> call.sql().contains(fragment.toLowerCase()))
                .toList();
    }

    private int callIndex(String fragment) {
        for (int i = 0; i < nativeCalls.size(); i++) {
            if (nativeCalls.get(i).sql().contains(fragment)) return i;
        }
        throw new AssertionError("missing native SQL fragment: " + fragment);
    }

    private int lastCallIndex(String fragment) {
        for (int i = nativeCalls.size() - 1; i >= 0; i--) {
            if (nativeCalls.get(i).sql().contains(fragment)) return i;
        }
        throw new AssertionError("missing native SQL fragment: " + fragment);
    }

    private static String emptyBomFingerprint(UUID goodsId) throws Exception {
        byte[] hash = MessageDigest.getInstance("SHA-256")
                .digest(("GOODS|" + goodsId + "\n").getBytes(StandardCharsets.UTF_8));
        return HexFormat.of().formatHex(hash);
    }

    private static String compact(String sql) {
        return sql.replaceAll("\\s+", " ").trim().toLowerCase();
    }

    private static List<Object[]> rows(Object[]... rows) {
        return Arrays.asList(rows);
    }

    private record NativeCall(String sql, Map<String, Object> parameters) {
    }

    @FunctionalInterface
    private interface NativeUpdateAnswer {
        int apply(String sql, Map<String, Object> parameters);
    }
}
