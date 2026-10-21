package com.uten.imp.businesschain;

import com.uten.imp.application.port.ProcurementOrderApprovalPort.OrderSnapshot;
import com.uten.imp.application.port.ProductionSupplyTransitionPort;
import com.uten.imp.application.port.PreplanAnalysisPegPort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.finance.ProcurementIqcReplacementAllocationService;
import com.uten.imp.common.finance.ProcurementQuantities;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.HashUtil;
import com.uten.imp.features.purchase.receipt.LegacyV854PurchaseReceiptAmountAuthority;
import com.uten.imp.features.purchase.receipt.PurchaseReceiptAmountAuthority;
import com.uten.imp.features.purchase.receipt.PurchaseReceiptItemRepository;
import com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine;
import com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest;
import com.uten.imp.features.production.analysis.LegacyV854PreplanAnalysisStockPegService;
import com.uten.imp.features.production.analysis.PreplanOriginEntitlementHook;
import com.uten.imp.features.production.analysis.PreplanStockEntitlementService;
import com.uten.imp.features.production.fulfillment.PlanningPackageFingerprint;
import com.uten.imp.features.stock.InventoryMutationLock;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import org.springframework.aop.framework.Advised;
import org.springframework.aop.framework.ProxyFactory;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.test.util.AopTestUtils;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Proxy;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Historical fixture, not a second application workflow. V854 has contract tax and
 * V835 finance FX, but no V865 finance-tax column/function. Native historical order,
 * approval and expectation rows obey the installed constraints/triggers. Analysis
 * and request facts are versioned native V854 fixtures, not modern preview/detail
 * commands against an old schema. Receipt, IQC, stock and root commands remain real.
 * The ordinary current-schema analysis workflow is covered by its separate E2E.
 */
final class LegacyV854RootSupplyFixture {
    private final RootSupplyActualWarehouseEndToEndTest support;
    private final FullChainEndToEndTest harness = new FullChainEndToEndTest();
    private final Object stockInTarget;
    private final PreplanAnalysisPegPort currentPegging;
    private final Object receiptTarget;
    private final PurchaseReceiptAmountAuthority currentReceiptAmounts;
    private final Object analysisTarget;
    private final EntityManager currentAnalysisEntityManager;

    LegacyV854RootSupplyFixture(RootSupplyActualWarehouseEndToEndTest support) {
        this.support = support;
        support.beans.autowireBean(harness);
        stockInTarget = AopTestUtils.getUltimateTargetObject(support.beans.getBean(ProcurementIqcStockInService.class));
        currentPegging = (PreplanAnalysisPegPort) ReflectionTestUtils.getField(stockInTarget, "preplanAnalysisPeg");
        receiptTarget = AopTestUtils.getUltimateTargetObject(support.receipts);
        currentReceiptAmounts = (PurchaseReceiptAmountAuthority) ReflectionTestUtils.getField(receiptTarget, "receiptAmountAuthority");
        analysisTarget = AopTestUtils.getUltimateTargetObject(support.analyses);
        currentAnalysisEntityManager = (EntityManager) ReflectionTestUtils.getField(analysisTarget, "em");
    }

    RootSupplyActualWarehouseEndToEndTest.Fixture createAndPass() {
        assertHistoricalSchema();
        List<String> guards = guardSnapshot();
        String tag = "root-v854-" + UUID.randomUUID();
        var world = harness.seedWorld(tag);
        harness.loginAs(world.superAdminUserId());
        UUID leaf = UUID.randomUUID();
        support.db.update("INSERT INTO warehouses(id,parent_id,code,name,status,is_accountable) VALUES(?,?,?,?,'使用',TRUE)",
                leaf, world.warehouseId(), "ROOT-V854-" + leaf, "Historical V854 actual leaf");
        UUID second = UUID.randomUUID();
        harness.insertGoods(second, "ROOT-V854-GOODS-" + second, "Historical second root material", "采购", world.unitId(), world.unitLegacy());
        List<UUID> goods = List.of(world.goodsD(), second);
        support.db.update("UPDATE goods SET default_supplier_id=?,owning_warehouse_id=? WHERE id IN (?,?)",
                world.supplierId(), leaf, goods.get(0), goods.get(1));
        UUID analysis = seedHistoricalAnalysisAndRequests(world, leaf, goods, tag);
        List<Map<String, Object>> sources = support.db.queryForList("""
                SELECT item.id,item.goods_id,item.qty FROM preplan_supply_actions action
                JOIN purchase_requests request ON request.id=action.external_document_id
                JOIN preplan_supply_action_allocations allocation ON allocation.action_id=action.id
                JOIN purchase_request_items item ON item.id=allocation.external_item_id AND item.request_id=request.id AND NOT item.is_deleted
                WHERE action.analysis_id=? AND action.route='BUY' AND action.status='CREATED' ORDER BY item.id
                """, analysis);
        assertThat(sources).hasSize(2);
        assertThat(sources).allSatisfy(source -> assertThat((BigDecimal) source.get("qty")).isEqualByComparingTo("500"));
        UUID reviewer = ReflectionTestUtils.invokeMethod(harness, "createApprover", world);
        UUID reviewerEmployee = support.db.queryForObject("SELECT employee_id FROM users WHERE id=?", UUID.class, reviewer);
        UUID settlement = ReflectionTestUtils.invokeMethod(harness, "activeSettlementMethodId");
        var order = seedDraftAndSubmission(world, leaf, settlement, reviewer, reviewerEmployee, sources);
        harness.loginAs(reviewer);
        approveHistoricalOrder(reviewer, reviewerEmployee, order, sources);
        harness.loginAs(world.superAdminUserId());

        RootSupplyActualWarehouseEndToEndTest.Fixture fixture;
        // The sole V865 receipt-authority difference is tax-source projection.
        // Use the complete frozen pre-V865 real implementation, not mocked rows,
        // and retain the original transaction advisor. Always restore before Flyway.
        try (var ignored = new HistoricalReceiptAmounts(); var historicalPegging = new HistoricalInspectionPegging();
             var historicalCoverage = new HistoricalIqcCoverageReads()) {
            historicalPegging.assertInstalled();
            var receipt = new ReceiptSaveRequest();
            receipt.setBillDate(BusinessTime.today());
            receipt.setSupplierId(world.supplierId());
            receipt.setWarehouseId(leaf);
            receipt.setCurrencyId(world.currencyId());
            receipt.setExchangeRate(BigDecimal.ONE);
            receipt.setTaxRate(BigDecimal.ZERO);
            receipt.setSettlementMethodId(settlement);
            receipt.setItems(support.db.query("""
                    SELECT id,goods_id,color_id,unit_id,unit_rate,qty,price
                    FROM purchase_order_items WHERE order_id=? AND NOT is_deleted ORDER BY line_no,id
                    """, (rs, row) -> {
                var line = new ReceiptItemLine();
                line.setOrderItemId(rs.getObject("id", UUID.class));
                line.setGoodsId(rs.getObject("goods_id", UUID.class));
                line.setColorId(rs.getObject("color_id", UUID.class));
                line.setUnitId(rs.getObject("unit_id", UUID.class));
                line.setUnitRate(rs.getBigDecimal("unit_rate"));
                line.setQty(rs.getBigDecimal("qty"));
                line.setPrice(rs.getBigDecimal("price"));
                return line;
            }, order.id()));
            assertThat(receipt.getItems()).hasSize(2);
            UUID receiptId = support.receipts.create(receipt).getId();
            support.receipts.approve(receiptId);
            fixture = new RootSupplyActualWarehouseEndToEndTest.Fixture(world, leaf, leaf, analysis, receiptId, goods);
            support.passManual(fixture);
            historicalCoverage.assertUsed();
        } finally {
            assertCurrentComponentsRestored();
        }
        assertCurrentComponentsRestored();
        assertHistoricalSchema();
        assertThat(guardSnapshot()).containsExactlyElementsOf(guards);
        assertThat(support.db.queryForObject("SELECT warehouse_id FROM production_material_analyses WHERE id=?", UUID.class, analysis)).isEqualTo(leaf);
        assertThat(support.db.queryForList("SELECT root_fulfilled_qty FROM production_material_analysis_items WHERE analysis_id=? ORDER BY id", BigDecimal.class, analysis))
                .allSatisfy(qty -> assertThat(qty).isEqualByComparingTo("500"));
        return fixture;
    }

    /** Native V854 facts; no trigger, constraint or historical function is replaced. */
    private UUID seedHistoricalAnalysisAndRequests(FullChainEndToEndTest.World world, UUID leaf, List<UUID> goods, String tag) {
        return support.transactions.execute(ignored -> {
            support.beans.getBean(TxSessionVars.class).bind();
            UUID analysis = UUID.randomUUID(), request = UUID.randomUUID();
            var numbers = support.beans.getBean(DocNumberService.class);
            String analysisNo = numbers.nextNumber(DocNumberPrefix.MATERIAL_ANALYSIS);
            String requestNo = numbers.nextNumber(DocNumberPrefix.PURCHASE_REQUEST);
            support.db.update("""
                    INSERT INTO production_material_analyses(id,analysis_no,warehouse_id,participating_warehouse_ids,
                        status,fingerprint,initial_idempotency_key,maker_id,created_by,updated_by)
                    VALUES(?,?,?,ARRAY[CAST(? AS uuid)],'ACTIVE',?,?,?,?,?)
                    """, analysis, analysisNo, leaf, leaf, PlanningPackageFingerprint.sha256(List.of("V854_ROOT_ANALYSIS", tag)), tag, world.employeeId(), world.superAdminUserId(), world.superAdminUserId());
            for (UUID good : goods) {
                support.db.update("""
                        INSERT INTO production_material_analysis_items(id,analysis_id,source_type,goods_id,unit_id,
                            source_ref,source_reason,requested_qty,line_priority,delivery_date,created_by,updated_by)
                        VALUES(?,?,'STOCK',?,?,?,'Historical V854 same-leaf stock root',500,1,?,?,?)
                        """, UUID.randomUUID(), analysis, good, world.unitId(), "ROOT-V854-" + good,
                        BusinessTime.today(), world.superAdminUserId(), world.superAdminUserId());
            }
            // This real root creation/validation boundary is unchanged from the
            // frozen pre-V895 source. It applies the V478 root identity rules.
            support.roots.ensureRootNodes(analysis);
            assertThat(support.db.update("""
                    UPDATE production_material_analysis_materials SET confirmed_route='BUY',route_confirmed_by=?,route_confirmed_at=now()
                    WHERE analysis_id=? AND node_role='ROOT_SUPPLY' AND source_suggestion='BUY'
                    """, world.superAdminUserId(), analysis)).isEqualTo(2);
            support.db.update("""
                    INSERT INTO purchase_requests(id,bill_no,bill_date,warehouse_id,applicant_id,maker_id,status,
                        source_doc_no,quantity_semantics,created_by,updated_by)
                    VALUES(?,?,?,?,?,?,1,?,?,?,?)
                    """, request, requestNo, BusinessTime.today(), leaf, world.employeeId(), world.employeeId(),
                    analysisNo, ProcurementQuantities.EXTRA_GIFT, world.superAdminUserId(), world.superAdminUserId());
            int line = 0;
            for (UUID good : goods) {
                UUID requestItem = UUID.randomUUID(), action = UUID.randomUUID();
                UUID material = support.db.queryForObject("SELECT id FROM production_material_analysis_materials WHERE analysis_id=? AND goods_id=? AND node_role='ROOT_SUPPLY'", UUID.class, analysis, good);
                support.db.update("""
                        INSERT INTO purchase_request_items(id,request_id,bill_no,bill_date,line_no,goods_id,unit_id,unit_rate,
                            qty,price,amount_original,amount_local,ordered_qty,gift_qty,quantity_semantics,
                            goods_code_snapshot,goods_name_snapshot,goods_snapshot_source,goods_snapshot_locked_at,
                            deliver_date,source_doc_no,production_plan_no)
                        SELECT ?,?,?,?,?,id,?,1,500,0,0,0,0,0,?,code,name,'MASTER_AT_APPROVAL',now(),?,?,?
                        FROM goods WHERE id=?
                        """, requestItem, request, requestNo, BusinessTime.today(), ++line, world.unitId(),
                        ProcurementQuantities.EXTRA_GIFT, BusinessTime.today(), analysisNo, analysisNo, good);
                String identity = PlanningPackageFingerprint.sha256(List.of("V854_ROOT_ACTION", tag, good.toString()));
                support.db.update("""
                        INSERT INTO preplan_supply_actions(id,analysis_id,warehouse_id,goods_id,unit_id,need_date,route,
                            requested_qty,status,external_document_type,external_document_id,external_document_no,
                            operation_type,idempotency_key,action_group_key,request_business_key,request_hash,created_by)
                        VALUES(?,?,?,?,?,?,'BUY',500,'CREATED','PURCHASE_REQUEST',?,?,'SUPPLY',?,?,?,?,?)
                        """, action, analysis, leaf, good, world.unitId(), BusinessTime.today(), request, requestNo,
                        "v854-action-" + action, identity, identity, identity, world.superAdminUserId());
                support.db.update("""
                        INSERT INTO preplan_supply_action_allocations(id,analysis_id,action_id,analysis_material_id,
                            allocated_qty,external_item_id,created_by) VALUES(?,?,?,?,500,?,?)
                        """, UUID.randomUUID(), analysis, action, material, requestItem, world.superAdminUserId());
            }
            return analysis;
        });
    }

    void assertCurrentComponentsRestored() {
        assertThat(ReflectionTestUtils.getField(stockInTarget, "preplanAnalysisPeg")).isSameAs(currentPegging);
        assertThat(ReflectionTestUtils.getField(receiptTarget, "receiptAmountAuthority")).isSameAs(currentReceiptAmounts);
        assertThat(ReflectionTestUtils.getField(analysisTarget, "em")).isSameAs(currentAnalysisEntityManager);
    }

    private LegacyOrder seedDraftAndSubmission(FullChainEndToEndTest.World world, UUID leaf, UUID settlement,
            UUID reviewer, UUID reviewerEmployee, List<Map<String, Object>> sources) {
        return support.transactions.execute(ignored -> {
            support.beans.getBean(TxSessionVars.class).bind();
            UUID id = UUID.randomUUID(), approval = UUID.randomUUID();
            String no = support.beans.getBean(DocNumberService.class).nextNumber(DocNumberPrefix.PURCHASE_ORDER);
            BigDecimal total = sources.stream().map(row -> ((BigDecimal) row.get("qty")).multiply(new BigDecimal("50")))
                    .reduce(BigDecimal.ZERO, BigDecimal::add);
            support.db.update("""
                    INSERT INTO purchase_orders(id,bill_no,bill_date,supplier_id,warehouse_id,currency_id,
                        exchange_rate,tax_rate,settlement_method_id,maker_id,total_original,total_local,status,
                        quantity_semantics,created_by,updated_by)
                    VALUES(?,?,?,?,?,?,1,0,?,?,?,?,0,?,?,?)
                    """, id, no, BusinessTime.today(), world.supplierId(), leaf, world.currencyId(), settlement,
                    world.employeeId(), total, total, ProcurementQuantities.EXTRA_GIFT,
                    world.superAdminUserId(), world.superAdminUserId());
            int number = 0;
            for (var source : sources) {
                UUID item = UUID.randomUUID(), request = (UUID) source.get("id");
                support.db.update("""
                        INSERT INTO purchase_order_items(id,bill_no,bill_date,order_id,line_no,goods_id,unit_id,unit_rate,
                            qty,price,amount_original,amount_local,request_item_id,quantity_semantics,gift_qty,
                            goods_code_snapshot,goods_name_snapshot,goods_snapshot_source,goods_snapshot_locked_at,
                            source_doc_no,production_plan_no,sales_order_no,deliver_date)
                        SELECT ?,?,?,?,?,request.goods_id,request.unit_id,1,request.qty,50,request.qty*50,request.qty*50,
                            request.id,?,0,COALESCE(request.goods_code_snapshot,goods.code),
                            COALESCE(request.goods_name_snapshot,goods.name),
                            CASE WHEN request.goods_code_snapshot IS NOT NULL AND request.goods_name_snapshot IS NOT NULL
                                THEN 'REQUEST_ITEM_AT_SAVE' ELSE 'MASTER_AT_SAVE' END,NULL,
                            request.source_doc_no,request.production_plan_no,request.sales_order_no,request.deliver_date
                        FROM purchase_request_items request JOIN goods ON goods.id=request.goods_id WHERE request.id=?
                        """, item, no, BusinessTime.today(), id, ++number, ProcurementQuantities.EXTRA_GIFT, request);
                support.db.update("""
                        INSERT INTO purchase_order_item_sources(id,order_item_id,request_item_id,alloc_qty,line_no,created_by,allocated_gift_qty)
                        VALUES(?,?,?,?,1,?,0)
                        """, UUID.randomUUID(), item, request, source.get("qty"), world.superAdminUserId());
            }
            Object defaults = ReflectionTestUtils.getField(AopTestUtils.<Object>getUltimateTargetObject(support.orders), "masterDefaultsSync");
            ReflectionTestUtils.invokeMethod(defaults, "syncFromPurchaseOrder", id);
            OrderSnapshot snapshot = support.orders.lockAndValidateFinanceSubmission(id);
            String json = ReflectionTestUtils.invokeMethod(AopTestUtils.<Object>getUltimateTargetObject(support.finance), "canonicalSnapshotJson", snapshot);
            String hash = HashUtil.sha256(json);
            support.db.update("""
                    INSERT INTO procurement_order_approval_cases(id,order_type,order_id,attempt,bill_no_snapshot,
                        amount_snapshot,submission_snapshot,snapshot_hash,submitted_by_user_id,submitted_by_employee_id,
                        assignee_user_id,assignee_employee_id,assignee_name_snapshot,status,version)
                    VALUES(?,'PURCHASE',?,1,?,?,CAST(? AS jsonb),?,?,?,?,?,?,'PENDING',1)
                    """, approval, id, no, total, json, hash, world.superAdminUserId(), world.employeeId(),
                    reviewer, reviewerEmployee,
                    support.db.queryForObject("SELECT full_name FROM employees WHERE id=?", String.class, reviewerEmployee));
            appendEvent(approval, "SUBMITTED", world.superAdminUserId(), world.employeeId(), hash);
            return new LegacyOrder(id, approval, snapshot, hash);
        });
    }

    private void approveHistoricalOrder(UUID reviewer, UUID reviewerEmployee, LegacyOrder order, List<Map<String, Object>> sources) {
        support.transactions.executeWithoutResult(ignored -> {
            support.beans.getBean(TxSessionVars.class).bind();
            support.db.update("""
                    UPDATE purchase_order_items SET goods_snapshot_source=CASE
                        WHEN goods_snapshot_source='REQUEST_ITEM_AT_SAVE' THEN 'REQUEST_ITEM_AT_APPROVAL'
                        ELSE 'MASTER_AT_APPROVAL' END,goods_snapshot_locked_at=now()
                    WHERE order_id=? AND NOT is_deleted
                    """, order.id());
            support.beans.getBean(ProductionSupplyTransitionPort.class).onPurchaseOrderApproved(order.id());
            for (var source : sources) {
                UUID request = (UUID) source.get("id");
                support.db.update("UPDATE purchase_request_items SET ordered_qty=COALESCE(ordered_qty,0)+?,gift_ordered_qty=COALESCE(gift_ordered_qty,0) WHERE id=?",
                        source.get("qty"), request);
                ReflectionTestUtils.invokeMethod(AopTestUtils.<Object>getUltimateTargetObject(support.orders), "recalcRequestClosed", request);
            }
            support.db.update("UPDATE purchase_orders SET status=1,approver_id=?,updated_at=now() WHERE id=? AND status=0", reviewerEmployee, order.id());
            // V835 FX exists at V854. Deliberately no V865 finance_tax_rate write.
            assertThat(support.db.update("""
                    UPDATE procurement_order_approval_cases SET status='APPROVED',decided_by_user_id=?,decided_by_employee_id=?,
                        decided_at=now(),updated_at=now(),version=2,finance_exchange_rate=1,finance_total_local=? WHERE id=? AND status='PENDING'
                    """, reviewer, reviewerEmployee, order.snapshot().totalOriginal(), order.approval())).isEqualTo(1);
            appendEvent(order.approval(), "APPROVED", reviewer, reviewerEmployee, order.hash());
            UUID expectation = UUID.randomUUID();
            var s = order.snapshot();
            support.db.update("""
                    INSERT INTO inbound_expectations(id,order_type,order_id,approval_case_id,bill_no_snapshot,supplier_id,
                        warehouse_id,expected_date,owner_employee_id,status,created_by)
                    VALUES(?,'PURCHASE',?,?,?,?,?,?,?,'OPEN',?)
                    """, expectation, order.id(), order.approval(), s.billNo(), s.supplierId(), s.warehouseId(), s.deliverDate(), s.makerEmployeeId(), reviewer);
            for (var item : s.items()) {
                support.db.update("""
                        INSERT INTO inbound_expectation_items(id,expectation_id,order_item_id,line_no,goods_id,color_id,unit_id,
                            unit_rate,ordered_qty,accepted_qty,expected_date) VALUES(?,?,?,?,?,?,?,?,?,0,?)
                        """, UUID.randomUUID(), expectation, item.itemId(), item.lineNo(), item.goodsId(), item.colorId(),
                        item.unitId(), item.unitRate(), item.qty(), item.deliverDate());
            }
        });
    }

    private void appendEvent(UUID approval, String type, UUID actor, UUID employee, String hash) {
        support.db.update("""
                INSERT INTO procurement_order_approval_events(id,case_id,event_type,actor_user_id,actor_employee_id,event_snapshot)
                VALUES(?,?,?,?,?,jsonb_build_object('snapshotHash',CAST(? AS text))
                    ||CASE WHEN CAST(? AS text)='SUBMITTED' THEN jsonb_build_object('attempt',1) ELSE '{}'::jsonb END)
                """, UUID.randomUUID(), approval, type, actor, employee, hash, type);
    }

    private void assertHistoricalSchema() {
        assertThat(ProcurementQuantities.EXTRA_GIFT).isEqualTo("CHARGED_PLUS_GIFT_V1");
        assertThat(support.db.queryForObject("SELECT max(version::int) FROM flyway_schema_history WHERE success", Integer.class)).isEqualTo(854);
        assertThat(support.db.queryForObject("SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='procurement_order_approval_cases' AND column_name='finance_tax_rate'", Integer.class)).isZero();
        assertThat(support.db.queryForObject("SELECT to_regprocedure('public.fn_procurement_approved_tax_rate(text,uuid,numeric)') IS NULL", Boolean.class)).isTrue();
        assertThat(support.db.queryForObject("SELECT to_regprocedure('public.fn_preplan_aggregate_retained_private_sources(uuid)') IS NULL", Boolean.class)).isTrue();
        assertThat(support.db.queryForObject("SELECT to_regprocedure('public.fn_preplan_aggregate_cancelled_parent_receipt_blocks(uuid)') IS NULL", Boolean.class)).isTrue();
    }

    private List<String> guardSnapshot() {
        String tables = "'production_material_analyses','production_material_analysis_items','production_material_analysis_materials','preplan_supply_actions','preplan_supply_action_allocations','purchase_requests','purchase_request_items','purchase_orders','purchase_order_items','purchase_order_item_sources','procurement_order_approval_cases','procurement_order_approval_events','purchase_receipts','purchase_receipt_items','preplan_root_output_events'";
        assertThat(support.db.queryForObject("SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND NOT t.tgisinternal AND c.relname IN ("+tables+") AND t.tgenabled NOT IN ('O','A')", Integer.class)).isZero();
        return support.db.queryForList("SELECT c.relname::text||':'||t.tgname::text||':'||t.tgenabled::text||':'||pg_get_triggerdef(t.oid) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND NOT t.tgisinternal AND c.relname IN ("+tables+") UNION ALL SELECT c.relname::text||':'||k.conname::text||':'||k.convalidated::text||':'||pg_get_constraintdef(k.oid) FROM pg_constraint k JOIN pg_class c ON c.oid=k.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname IN ("+tables+") ORDER BY 1", String.class);
    }

    /** Full pre-V895 command and helpers, with the original transaction advisors. */
    private final class HistoricalInspectionPegging implements AutoCloseable {
        private final PreplanAnalysisPegPort historical;
        @SuppressWarnings("unchecked")
        HistoricalInspectionPegging() {
            Object target = AopTestUtils.getUltimateTargetObject(currentPegging);
            var legacy = new LegacyV854PreplanAnalysisStockPegService(
                    (EntityManager) ReflectionTestUtils.getField(target, "em"),
                    (TxSessionVars) ReflectionTestUtils.getField(target, "tx"),
                    (SecurityContextCurrentUser) ReflectionTestUtils.getField(target, "currentUser"),
                    (InventoryMutationLock) ReflectionTestUtils.getField(target, "inventoryLock"),
                    (PreplanStockEntitlementService) ReflectionTestUtils.getField(target, "entitlement"),
                    (ObjectProvider<PreplanOriginEntitlementHook>) ReflectionTestUtils.getField(target, "originHooks"));
            support.beans.autowireBean(legacy);
            assertThat(currentPegging).isInstanceOf(Advised.class);
            var proxy = new ProxyFactory(legacy);
            proxy.setProxyTargetClass(true);
            for (var advisor : ((Advised) currentPegging).getAdvisors()) proxy.addAdvisor(advisor);
            historical = (PreplanAnalysisPegPort) proxy.getProxy();
            assertThat(((Advised) historical).getAdvisors()).containsExactly(((Advised) currentPegging).getAdvisors());
            ReflectionTestUtils.setField(stockInTarget, "preplanAnalysisPeg", historical);
        }
        void assertInstalled() { assertThat(ReflectionTestUtils.getField(stockInTarget, "preplanAnalysisPeg")).isSameAs(historical); }
        @Override public void close() {
            ReflectionTestUtils.setField(stockInTarget, "preplanAnalysisPeg", currentPegging);
            assertThat(ReflectionTestUtils.getField(stockInTarget, "preplanAnalysisPeg")).isSameAs(currentPegging);
        }
    }

    /**
     * IQC's real synchronous wakeup still refreshes the analysis. Only its two
     * complete read statements use the actual pre-V895 projection. Parameters,
     * transaction, locks and returned quantities remain the real JPA results.
     * SQL resources are exact Java-evaluated statements from Git source
     * 0bdab31f1784018f854a3954eef898c09ce3c90b (see provenance.json).
     */
    private final class HistoricalIqcCoverageReads implements AutoCloseable {
        private final Map<String, HistoricalSelect> selects = new LinkedHashMap<>();
        private int mappedReads;
        HistoricalIqcCoverageReads() {
            assertHistoricalSchema();
            add("active-future-coverage", 3,
                    "6c6d33546130daf01b7ab232a3dc2bef724c021e5cd41f12262c18bd1c0e4b49",
                    "5ea9172ad5e72053588f712d10c42713c872cd9ef6ced0c07019f91aee2474ad");
            add("parent-supply-commitments", 2,
                    "44e31cd2b831051c10b36bc1085713f47b601fb6c0826de810cd506b019510f7",
                    "57e2118eb4db8080419470e71de0366426569e14007c438497a01969b4479096");
            var scoped = Proxy.newProxyInstance(EntityManager.class.getClassLoader(), new Class<?>[]{EntityManager.class},
                    (proxy, method, args) -> {
                        if (method.getName().equals("createNativeQuery") && args != null && args[0] instanceof String sql) {
                            HistoricalSelect select = selects.get(sql);
                            if (select != null) {
                                Object[] actual = args.clone(); actual[0] = select.sql();
                                var query = (jakarta.persistence.Query) invoke(method, currentAnalysisEntityManager, actual);
                                return checkedQuery(query, select.columns());
                            }
                            if (sql.contains("fn_preplan_aggregate_retained_private_sources")
                                    || sql.contains("fn_preplan_aggregate_cancelled_parent_receipt_blocks")) {
                                throw new IllegalStateException("Unreviewed modern projection entered historical IQC preparation");
                            }
                        }
                        return invoke(method, currentAnalysisEntityManager, args);
                    });
            ReflectionTestUtils.setField(analysisTarget, "em", scoped);
        }
        private void add(String name, int columns, String currentHash, String historicalHash) {
            String current = sql("current." + name, currentHash);
            String historical = sql("historical." + name, historicalHash);
            assertThat(selects.put(current, new HistoricalSelect(historical, columns))).isNull();
        }
        private jakarta.persistence.Query checkedQuery(jakarta.persistence.Query actual, int columns) {
            return (jakarta.persistence.Query) Proxy.newProxyInstance(jakarta.persistence.Query.class.getClassLoader(),
                    new Class<?>[]{jakarta.persistence.Query.class}, (proxy, method, args) -> {
                        Object result = invoke(method, actual, args);
                        if (method.getName().equals("getResultList")) {
                            mappedReads++;
                            for (Object row : (List<?>) result) assertThat((Object[]) row).hasSize(columns);
                        }
                        return result == actual ? proxy : result;
                    });
        }
        void assertUsed() { assertThat(mappedReads).isPositive(); }
        @Override public void close() {
            ReflectionTestUtils.setField(analysisTarget, "em", currentAnalysisEntityManager);
            assertThat(ReflectionTestUtils.getField(analysisTarget, "em")).isSameAs(currentAnalysisEntityManager);
        }
        private String sql(String name, String hash) {
            try (var input = LegacyV854RootSupplyFixture.class.getResourceAsStream("/legacy-v854-root-coverage/" + name + ".sql")) {
                assertThat(input).isNotNull();
                // Git source and Java text blocks are LF; accept only checkout
                // CRLF normalization, with every resulting SQL byte hash pinned.
                String sql = new String(input.readAllBytes(), StandardCharsets.UTF_8).replace("\r\n", "\n");
                assertThat(HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(sql.getBytes(StandardCharsets.UTF_8)))).isEqualTo(hash);
                return sql;
            } catch (java.io.IOException | java.security.NoSuchAlgorithmException failure) {
                throw new IllegalStateException("Frozen historical SQL resource is unavailable", failure);
            }
        }
        private Object invoke(java.lang.reflect.Method method, Object target, Object[] args) throws Throwable {
            try { return method.invoke(target, args); }
            catch (InvocationTargetException failure) { throw failure.getCause(); }
        }
    }

    private record HistoricalSelect(String sql, int columns) { }

    private final class HistoricalReceiptAmounts implements AutoCloseable {
        private final PurchaseReceiptAmountAuthority original = (PurchaseReceiptAmountAuthority) ReflectionTestUtils.getField(receiptTarget, "receiptAmountAuthority");
        HistoricalReceiptAmounts() {
            Object target = AopTestUtils.<Object>getUltimateTargetObject(original);
            var legacy = new LegacyV854PurchaseReceiptAmountAuthority(
                    (EntityManager) ReflectionTestUtils.getField(target, "em"),
                    (PurchaseReceiptItemRepository) ReflectionTestUtils.getField(target, "itemRepo"),
                    (ProcurementIqcReplacementAllocationService) ReflectionTestUtils.getField(target, "replacementAllocation"));
            var proxy = new ProxyFactory(legacy);
            proxy.setProxyTargetClass(true);
            assertThat(original).isInstanceOf(Advised.class);
            for (var advisor : ((Advised) original).getAdvisors()) proxy.addAdvisor(advisor);
            ReflectionTestUtils.setField(receiptTarget, "receiptAmountAuthority", proxy.getProxy());
        }
        @Override public void close() {
            ReflectionTestUtils.setField(receiptTarget, "receiptAmountAuthority", original);
            assertThat(ReflectionTestUtils.getField(receiptTarget, "receiptAmountAuthority")).isSameAs(original);
        }
    }

    private record LegacyOrder(UUID id, UUID approval, OrderSnapshot snapshot, String hash) { }
}
