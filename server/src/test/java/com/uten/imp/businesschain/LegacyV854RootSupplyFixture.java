package com.uten.imp.businesschain;

import com.uten.imp.application.port.ProcurementOrderApprovalPort.OrderSnapshot;
import com.uten.imp.application.port.PreplanAnalysisPegPort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.finance.ProcurementQuantities;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.HashUtil;
import com.uten.imp.features.purchase.receipt.PurchaseReceiptAmountAuthority;
import com.uten.imp.features.production.fulfillment.PlanningPackageFingerprint;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInService;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import org.springframework.test.util.AopTestUtils;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Historical fixture, not a second application workflow. V854 has contract tax and
 * V835 finance FX, but no V865 finance-tax column/function. Native historical order,
 * approval and expectation rows obey the installed constraints/triggers. Analysis
 * and request facts are versioned native V854 fixtures, not modern preview/detail
 * commands against an old schema. Versioned JDBC facts retain real custody/value,
 * AP, IQC and exact entitlement guards. Current receipt reversal runs only after forward.
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

        UUID receiptId=seedHistoricalReceipt(world,leaf,settlement,order);
        var fixture=new RootSupplyActualWarehouseEndToEndTest.Fixture(world,leaf,leaf,analysis,receiptId,goods);
        seedHistoricalStockAndHandoffs(world,fixture);
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
            createHistoricalRoots(analysis,world.superAdminUserId());
            assertThat(support.db.update("""
                    UPDATE production_material_analysis_materials SET source_suggestion='BUY',confirmed_route='BUY',route_confirmed_by=?,route_confirmed_at=now()
                    WHERE analysis_id=? AND node_role='ROOT_SUPPLY'
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
            OrderSnapshot snapshot=historicalOrderSnapshot(id);
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
            // Historical source counters are written explicitly, not by a current command.
            for (var source : sources) {
                UUID request = (UUID) source.get("id");
                support.db.update("UPDATE purchase_request_items SET ordered_qty=COALESCE(ordered_qty,0)+?,gift_ordered_qty=COALESCE(gift_ordered_qty,0) WHERE id=?",
                        source.get("qty"), request);
                support.db.update("UPDATE purchase_requests SET is_closed=NOT EXISTS(SELECT 1 FROM purchase_request_items line WHERE line.request_id=purchase_requests.id AND NOT line.is_deleted AND line.qty>line.ordered_qty) WHERE id=(SELECT request_id FROM purchase_request_items WHERE id=?)",request);
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
        assertThat(support.db.queryForObject("SELECT to_regprocedure('public.fn_imported_business_document(text,uuid)') IS NULL",Boolean.class)).isTrue();
        assertThat(support.db.queryForObject("SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='purchase_orders' AND column_name='termination_case_id'",Integer.class)).isZero();
    }

    private List<String> guardSnapshot() {
        String tables = "'production_material_analyses','production_material_analysis_items','production_material_analysis_materials','preplan_supply_actions','preplan_supply_action_allocations','purchase_requests','purchase_request_items','purchase_orders','purchase_order_items','purchase_order_item_sources','procurement_order_approval_cases','procurement_order_approval_events','purchase_receipts','purchase_receipt_items','preplan_root_output_events'";
        assertThat(support.db.queryForObject("SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND NOT t.tgisinternal AND c.relname IN ("+tables+") AND t.tgenabled NOT IN ('O','A')", Integer.class)).isZero();
        return support.db.queryForList("SELECT c.relname::text||':'||t.tgname::text||':'||t.tgenabled::text||':'||pg_get_triggerdef(t.oid) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND NOT t.tgisinternal UNION ALL SELECT c.relname::text||':'||k.conname::text||':'||k.convalidated::text||':'||pg_get_constraintdef(k.oid) FROM pg_constraint k JOIN pg_class c ON c.oid=k.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' UNION ALL SELECT 'FUNCTION:'||p.oid::text||':'||pg_get_functiondef(p.oid) FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.prokind IN('f','p') ORDER BY 1", String.class);
    }


    /** The only two root DML statements are pinned to the actual pre-V855 source. */
    private void createHistoricalRoots(UUID analysis,UUID actor) {
        assertThat(support.db.queryForObject("SELECT count(*) FROM production_material_analysis_items item JOIN goods ON goods.id=item.goods_id WHERE item.analysis_id=? AND (goods.unit_id IS NULL OR item.unit_id IS DISTINCT FROM goods.unit_id)",Integer.class,analysis)).isZero();
        try(var input=LegacyV854RootSupplyFixture.class.getResourceAsStream("/legacy-v854-root-coverage/approved-root-supply-facts.sql")) {
            assertThat(input).isNotNull();
            String sql=new String(input.readAllBytes(),StandardCharsets.UTF_8).replace("\r\n","\n");
            assertThat(HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(sql.getBytes(StandardCharsets.UTF_8))))
                    .isEqualTo("492cb3e131747cbd8198c5bdc2dae9c132f3cf2bb73f7ce7a581bd00fa4cafb2");
            var jdbc=new org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate(support.db);
            var statements=sql.split(";\\s*(?:\\r?\\n|$)");assertThat(statements).hasSize(2);
            for(String statement:statements)jdbc.update(statement,Map.of("analysisId",analysis,"actorId",actor));
        } catch(java.io.IOException|java.security.NoSuchAlgorithmException failure) { throw new IllegalStateException(failure); }
    }

    /** Actual historical columns, never a current ORM entity or a synthesized ORM result. */
    private OrderSnapshot historicalOrderSnapshot(UUID order) {
        var items=support.db.query("SELECT id,line_no,request_item_id,goods_id,color_id,unit_id,unit_rate,qty,price,amount_original,amount_local,deliver_date,gift_qty,quantity_semantics FROM purchase_order_items WHERE order_id=? AND NOT is_deleted ORDER BY line_no,id",
                (row,index)->new com.uten.imp.application.port.ProcurementOrderApprovalPort.ItemSnapshot(
                        row.getObject("id",UUID.class),row.getInt("line_no"),row.getObject("request_item_id",UUID.class),
                        row.getObject("goods_id",UUID.class),row.getObject("color_id",UUID.class),row.getObject("unit_id",UUID.class),
                        row.getBigDecimal("unit_rate"),row.getBigDecimal("qty"),row.getBigDecimal("price"),
                        row.getBigDecimal("amount_original"),row.getBigDecimal("amount_local"),row.getObject("deliver_date",java.time.LocalDate.class),
                        null,null,row.getBigDecimal("gift_qty"),row.getString("quantity_semantics")),order);
        return support.db.queryForObject("SELECT * FROM purchase_orders WHERE id=?",(row,index)->new OrderSnapshot(
                "PURCHASE",order,row.getString("bill_no"),row.getObject("bill_date",java.time.LocalDate.class),
                row.getObject("supplier_id",UUID.class),row.getObject("warehouse_id",UUID.class),row.getObject("currency_id",UUID.class),
                row.getBigDecimal("exchange_rate"),row.getObject("settlement_method_id",UUID.class),row.getBigDecimal("tax_rate"),
                row.getObject("purchaser_id",UUID.class),row.getObject("maker_id",UUID.class),row.getObject("deliver_date",java.time.LocalDate.class),
                row.getBigDecimal("total_original"),row.getBigDecimal("total_local"),items),order);
    }

    private UUID seedHistoricalReceipt(FullChainEndToEndTest.World world,UUID leaf,UUID settlement,LegacyOrder order) {
        return support.transactions.execute(ignored->{
            support.beans.getBean(TxSessionVars.class).bind();
            UUID receipt=UUID.randomUUID();String no=support.beans.getBean(DocNumberService.class).nextNumber(DocNumberPrefix.PURCHASE_RECEIPT);
            support.db.update("INSERT INTO purchase_receipts(id,bill_no,bill_date,supplier_id,warehouse_id,currency_id,exchange_rate,tax_rate,settlement_method_id,maker_id,total_original,total_local,status,quantity_semantics,created_by,updated_by) VALUES(?,?,?,?,?,?,1,0,?,?,?,?,1,?,?,?)",
                    receipt,no,BusinessTime.today(),world.supplierId(),leaf,world.currencyId(),settlement,world.employeeId(),order.snapshot().totalOriginal(),order.snapshot().totalLocal(),ProcurementQuantities.EXTRA_GIFT,world.superAdminUserId(),world.superAdminUserId());
            support.db.update("""
                    INSERT INTO purchase_receipt_items(id,receipt_id,bill_no,bill_date,line_no,order_item_id,goods_id,color_id,unit_id,unit_rate,qty,price,amount_original,amount_local,gift_qty,quantity_semantics,replacement_intent,goods_code_snapshot,goods_name_snapshot,goods_snapshot_source,goods_snapshot_locked_at)
                    SELECT gen_random_uuid(),?,?,?,line_no,id,goods_id,color_id,unit_id,unit_rate,qty,price,amount_original,amount_local,0,quantity_semantics,'NORMAL',goods_code_snapshot,goods_name_snapshot,'ORDER_ITEM_AT_APPROVAL',now()
                    FROM purchase_order_items WHERE order_id=? AND NOT is_deleted
                    """,receipt,no,BusinessTime.today(),order.id());
            support.db.update("UPDATE purchase_order_items SET received_qty=qty WHERE order_id=?",order.id());
            support.db.update("UPDATE purchase_orders SET is_closed=true WHERE id=?",order.id());
            withHistoricalConnection(connection->{
                com.uten.imp.support.ProcurementReceiptFixtureSupport.postOriginalReceiptPayable(connection,"PURCHASE",receipt,world.superAdminUserId());
                com.uten.imp.support.ProcurementReceiptFixtureSupport.appendStandardReceipt(connection,"PURCHASE",receipt,world.superAdminUserId());
            });
            for(var item:support.db.queryForList("SELECT * FROM purchase_receipt_items WHERE receipt_id=? ORDER BY id",receipt)) {
                UUID inspection=UUID.randomUUID();
                support.db.update("""
                        INSERT INTO procurement_inspection_items(id,receipt_type,receipt_id,receipt_item_id,warehouse_id,goods_id,color_id,unit_id,unit_rate,received_base_qty,received_amount_local,status,passed_base_qty)
                        VALUES(?,'PURCHASE',?,?,?,?,?,?,1,500,25000,'RESOLVED',500)
                        """,inspection,receipt,item.get("id"),leaf,item.get("goods_id"),item.get("color_id"),world.unitId());
                support.db.update("INSERT INTO procurement_inspection_events(id,inspection_item_id,action,base_qty,reason,actor_employee_id,requires_warehouse_stock_in,released_amount_local) VALUES(?,?,'PASS',500,'Actual priced V854 fixture quality decision',?,true,25000)",UUID.randomUUID(),inspection,world.employeeId());
            }
            withHistoricalConnection(connection->com.uten.imp.support.ProcurementReceiptFixtureSupport.appendExistingQualityConsideration(connection,"PURCHASE",receipt,world.superAdminUserId()));
            return receipt;
        });
    }

    /** Guarded custody/value JDBC writes use V517/V527 structures, with no mapped business entity. */
    private void seedHistoricalStockAndHandoffs(FullChainEndToEndTest.World world,RootSupplyActualWarehouseEndToEndTest.Fixture fixture) {
        List<UUID> inspections=support.db.queryForList("SELECT id FROM procurement_inspection_items WHERE receipt_id=? ORDER BY id",UUID.class,fixture.receipt());
        try(var connection=java.util.Objects.requireNonNull(support.db.getDataSource()).getConnection()) {
            com.uten.imp.support.ProcurementReceiptFixtureSupport.stockPricedPasses(connection,inspections);
        } catch(java.sql.SQLException failure) { throw new IllegalStateException(failure); }
        support.transactions.executeWithoutResult(ignored->{
            support.beans.getBean(TxSessionVars.class).bind();
            for(var stock:support.db.queryForList("""
                    SELECT stock.id stock_id,stock.pass_event_id,inspection.goods_id,allocation.id allocation_id,allocation.external_item_id,
                           allocation.analysis_material_id,material.analysis_item_id
                    FROM procurement_iqc_stock_in_batch_items stock
                    JOIN procurement_inspection_items inspection ON inspection.id=stock.inspection_item_id
                    JOIN preplan_supply_action_allocations allocation ON allocation.analysis_id=?
                    JOIN production_material_analysis_materials material ON material.id=allocation.analysis_material_id AND material.goods_id=inspection.goods_id
                    WHERE inspection.receipt_id=? ORDER BY stock.id
                    """,fixture.analysis(),fixture.receipt())) {
                UUID reservation=UUID.randomUUID(),exact=UUID.randomUUID(),origin=UUID.randomUUID(),release=UUID.randomUUID();
                support.db.update("""
                        INSERT INTO stock_reservations(id,goods_id,warehouse_id,qty,consumed_qty,released_qty,status,source,source_doc_type,source_doc_id,owner_type,owner_id,purpose,supply_type,supply_id,idempotency_key,created_by,updated_by)
                        VALUES(?,?,?,500,0,0,0,3,'PURCHASE_RECEIPT',?,'PREPLAN_ANALYSIS',?,'PREPLAN_MATERIAL','PURCHASE_REQUEST_ITEM',?,?,?,?)
                        """,reservation,stock.get("goods_id"),fixture.leaf(),fixture.receipt(),fixture.analysis(),stock.get("external_item_id"),"V854-RESERVE:"+reservation,world.superAdminUserId(),world.superAdminUserId());
                support.db.update("""
                        INSERT INTO preplan_analysis_stock_exact_pegs(id,stock_reservation_id,supply_action_allocation_id,origin_analysis_id,origin_analysis_material_id,beneficiary_analysis_id,beneficiary_analysis_material_id,qty,source_receipt_type,source_receipt_id,source_disposition_event_id,idempotency_key,created_by,updated_by)
                        VALUES(?,?,?,?,?,?,?,500,'PURCHASE',?,?,?,?,?)
                        """,exact,reservation,stock.get("allocation_id"),fixture.analysis(),stock.get("analysis_material_id"),fixture.analysis(),stock.get("analysis_material_id"),fixture.receipt(),stock.get("pass_event_id"),"V854-EXACT:"+exact,world.superAdminUserId(),world.superAdminUserId());
                support.db.update("""
                        INSERT INTO preplan_stock_entitlement_events(id,event_group_id,stock_reservation_id,beneficiary_analysis_id,beneficiary_analysis_material_id,event_type,qty,source_exact_peg_id,source_receipt_type,source_receipt_id,source_disposition_event_id,idempotency_key,created_by)
                        VALUES(?,?,?,?,?,'ORIGIN_IQC',500,?,'PURCHASE',?,?,?,?)
                        """,origin,stock.get("stock_id"),reservation,fixture.analysis(),stock.get("analysis_material_id"),exact,fixture.receipt(),stock.get("pass_event_id"),"V854-ORIGIN:"+origin,world.superAdminUserId());
                assertThat(support.db.queryForObject("SELECT fn_preplan_reservation_has_qualified_origin(?)",Boolean.class,reservation)).isTrue();
                support.db.update("""
                        INSERT INTO preplan_stock_entitlement_events(id,event_group_id,stock_reservation_id,beneficiary_analysis_id,beneficiary_analysis_material_id,event_type,qty,source_entitlement_event_id,idempotency_key,created_by)
                        VALUES(?,?,?,?,?,'RELEASE',500,?,?,?)
                        """,release,release,reservation,fixture.analysis(),stock.get("analysis_material_id"),origin,"V854-RELEASE:"+release,world.superAdminUserId());
                support.db.update("UPDATE stock_reservations SET released_qty=500,status=1,release_reason='ROOT_SUPPLY_HANDOFF' WHERE id=?",reservation);
                support.db.update("""
                        INSERT INTO preplan_root_output_events(analysis_id,analysis_item_id,root_material_id,event_kind,warehouse_id,goods_id,qty_base,source_reservation_id,release_entitlement_event_id,source_receipt_type,source_receipt_id,idempotency_key,created_by,route)
                        VALUES(?,?,?,'FULFILL',?,?,500,?,?,'PURCHASE',?,?,?,'BUY')
                        """,fixture.analysis(),stock.get("analysis_item_id"),stock.get("analysis_material_id"),fixture.leaf(),stock.get("goods_id"),reservation,release,fixture.receipt(),"V854-ROOT:"+origin,world.superAdminUserId());
            }
        });
        assertThat(support.db.queryForObject("SELECT sum(qty) FROM stock_balances WHERE goods_id IN (?,?)",BigDecimal.class,fixture.goods().get(0),fixture.goods().get(1))).isEqualByComparingTo("1000");
        assertThat(support.db.queryForObject("SELECT sum(amount_local) FROM stock_balances WHERE goods_id IN (?,?)",BigDecimal.class,fixture.goods().get(0),fixture.goods().get(1))).isEqualByComparingTo("50000");
        assertThat(support.db.queryForObject("SELECT sum(amount_original) FROM ar_ap_ledger WHERE source_doc_id=? AND direction='AP'",BigDecimal.class,fixture.receipt())).isEqualByComparingTo("50000");
    }

    @FunctionalInterface private interface HistoricalSqlWork { void run(java.sql.Connection connection) throws java.sql.SQLException; }
    private void withHistoricalConnection(HistoricalSqlWork work) {
        var connection=org.springframework.jdbc.datasource.DataSourceUtils.getConnection(java.util.Objects.requireNonNull(support.db.getDataSource()));
        try { work.run(connection); }
        catch(java.sql.SQLException failure) { throw new IllegalStateException(failure); }
    }

    private record LegacyOrder(UUID id, UUID approval, OrderSnapshot snapshot, String hash) { }
}
