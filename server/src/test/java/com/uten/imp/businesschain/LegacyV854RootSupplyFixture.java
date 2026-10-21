package com.uten.imp.businesschain;

import com.uten.imp.application.port.ProcurementOrderApprovalPort.OrderSnapshot;
import com.uten.imp.application.port.ProductionSupplyTransitionPort;
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
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import org.springframework.aop.framework.Advised;
import org.springframework.aop.framework.ProxyFactory;
import org.springframework.test.util.AopTestUtils;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.assertj.core.api.Assertions.assertThat;

/**
 * Historical fixture, not a second application workflow. V854 has contract tax and
 * V835 finance FX, but no V865 finance-tax column/function. Native historical order,
 * approval and expectation rows obey the installed constraints/triggers. Real
 * analysis/request, receipt, IQC, stock and root commands are retained.
 */
final class LegacyV854RootSupplyFixture {
    private final RootSupplyActualWarehouseEndToEndTest support;
    private final FullChainEndToEndTest harness = new FullChainEndToEndTest();

    LegacyV854RootSupplyFixture(RootSupplyActualWarehouseEndToEndTest support) {
        this.support = support;
        support.beans.autowireBean(harness);
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
        var preview = support.analyses.preview(new PreviewRequest(null, null, null, leaf,
                "root-v854-preview-" + tag,
                goods.stream().map(id -> new PreviewItem("STOCK", null, id, null, world.unitId(), "ROOT-" + id,
                        "Historical same-leaf stock root", BusinessTime.today(), new BigDecimal("500"))).toList()));
        var roots = preview.flatMaterials().stream().filter(row -> "ROOT_SUPPLY".equals(row.nodeRole())).toList();
        assertThat(roots).hasSize(2);
        var routed = support.analyses.saveRoutes(preview.analysisId(), new RouteRequest(preview.version(), preview.fingerprint(),
                "root-v854-route-" + tag,
                roots.stream().map(row -> new RouteDecision(row.materialLineId(), row.actionGroupKey(), "BUY", null)).toList()));
        support.commands.notifySupply(routed.analysisId(), new NotifyRequest(routed.version(), routed.fingerprint(),
                "root-v854-notify-" + tag, "BUY", roots.stream().map(MaterialView::materialLineId).toList(), List.of(), null, true));
        List<Map<String, Object>> sources = support.db.queryForList("""
                SELECT item.id,item.goods_id,item.qty FROM preplan_supply_actions action
                JOIN purchase_requests request ON request.id=action.external_document_id
                JOIN preplan_supply_action_allocations allocation ON allocation.action_id=action.id
                JOIN purchase_request_items item ON item.id=allocation.external_item_id AND item.request_id=request.id AND NOT item.is_deleted
                WHERE action.analysis_id=? AND action.route='BUY' AND action.status='CREATED' ORDER BY item.id
                """, preview.analysisId());
        assertThat(sources).hasSize(2);
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
        try (var ignored = new HistoricalReceiptAmounts()) {
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
            fixture = new RootSupplyActualWarehouseEndToEndTest.Fixture(world, leaf, leaf, preview.analysisId(), receiptId, goods);
            support.passManual(fixture);
        }
        assertHistoricalSchema();
        assertThat(guardSnapshot()).containsExactlyElementsOf(guards);
        assertThat(support.db.queryForObject("SELECT warehouse_id FROM production_material_analyses WHERE id=?", UUID.class, preview.analysisId())).isEqualTo(leaf);
        return fixture;
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
    }

    private List<String> guardSnapshot() {
        String tables = "'purchase_orders','purchase_order_items','purchase_order_item_sources','procurement_order_approval_cases','procurement_order_approval_events','purchase_receipts','purchase_receipt_items','preplan_root_output_events'";
        assertThat(support.db.queryForObject("SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND NOT t.tgisinternal AND c.relname IN ("+tables+") AND t.tgenabled NOT IN ('O','A')", Integer.class)).isZero();
        return support.db.queryForList("SELECT c.relname::text||':'||t.tgname::text||':'||t.tgenabled::text||':'||pg_get_triggerdef(t.oid) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND NOT t.tgisinternal AND c.relname IN ("+tables+") UNION ALL SELECT c.relname::text||':'||k.conname::text||':'||k.convalidated::text||':'||pg_get_constraintdef(k.oid) FROM pg_constraint k JOIN pg_class c ON c.oid=k.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname IN ("+tables+") ORDER BY 1", String.class);
    }

    private final class HistoricalReceiptAmounts implements AutoCloseable {
        private final Object receiptTarget = AopTestUtils.<Object>getUltimateTargetObject(support.receipts);
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
