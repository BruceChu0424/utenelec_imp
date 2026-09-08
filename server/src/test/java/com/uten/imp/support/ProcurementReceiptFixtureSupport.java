package com.uten.imp.support;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.SQLException;
import java.util.UUID;

/** Actual current-schema receipt facts; callers own transactions and explicit commercial snapshots. */
public final class ProcurementReceiptFixtureSupport {
    private ProcurementReceiptFixtureSupport() {}

    public static void appendStandardReceipt(Connection connection, String type, UUID receipt)
            throws SQLException {
        appendStandardReceipt(connection, type, receipt, createActor(connection));
    }

    public static void appendStandardReceipt(Connection connection, String type, UUID receipt, UUID actor)
            throws SQLException {
        requireTransaction(connection);
        String prefix = prefix(type);
        int items = 0;
        try (var query = connection.prepareStatement("SELECT id,qty*unit_rate base_qty,price,amount_original,amount_local,replacement_intent "
                + "FROM " + prefix + "_receipt_items WHERE receipt_id=? AND is_deleted=FALSE ORDER BY id")) {
            query.setObject(1, receipt);
            try (var rows = query.executeQuery()) {
                while (rows.next()) {
                    BigDecimal qty = rows.getBigDecimal("base_qty");
                    BigDecimal price = rows.getBigDecimal("price");
                    BigDecimal original = rows.getBigDecimal("amount_original");
                    BigDecimal local = rows.getBigDecimal("amount_local");
                    if (qty == null || qty.signum() <= 0 || price == null || price.signum() < 0
                            || original == null || original.signum() < 0 || local == null || local.signum() < 0
                            || !"NORMAL".equals(rows.getString("replacement_intent"))) {
                        throw new SQLException("Receipt fixture must declare its real NORMAL quantity, price and both amounts; unknown is not zero");
                    }
                    execute(connection, """
                            INSERT INTO procurement_receipt_consideration_parts(
                                id,receipt_type,receipt_id,receipt_item_id,billing_mode,base_qty,
                                nominal_original,nominal_local,payable_original,payable_local,created_by)
                            VALUES(?,?,?,?,'STANDARD',?,?,?,?,?,?)
                            """, UUID.randomUUID(), type, receipt, rows.getObject("id", UUID.class), qty,
                            original, local, original, local, actor);
                    items++;
                }
            }
        }
        if (items == 0) throw new SQLException("Receipt fixture has no actual receipt items");
        // Nonzero receipts require the same real source AP in this transaction; never invent a zero AP.
        execute(connection, "SELECT fn_assert_procurement_consideration_receipt(?,?)", type, receipt);
    }

    /** The caller has already written the complete original receipt snapshot; no monetary defaults are inferred. */
    public static void postOriginalReceiptPayable(Connection connection, String type, UUID receipt, UUID actor)
            throws SQLException {
        requireTransaction(connection);
        String table=prefix(type)+"_receipts";
        try(var statement=connection.prepareStatement("SELECT * FROM "+table+" WHERE id=?")) {
            statement.setObject(1,receipt);
            try(var row=statement.executeQuery()) {
                if(!row.next()) throw new SQLException("Missing actual receipt header");
                BigDecimal original=row.getBigDecimal("total_original"),local=row.getBigDecimal("total_local"),rate=row.getBigDecimal("exchange_rate");
                if(original==null||local==null||original.signum()<0||local.signum()<0)throw new SQLException("Explicit original receipt amounts are required");
                if(original.signum()==0&&local.signum()==0)return;
                if(row.getObject("supplier_id")==null||row.getObject("currency_id")==null||rate==null||rate.signum()<=0)
                    throw new SQLException("A priced receipt requires its actual supplier, currency and rate");
                execute(connection,"""
                        INSERT INTO ar_ap_ledger(id,direction,business_type,open_item_kind,source_doc_type,source_doc_id,source_doc_no,
                            bill_no,bill_date,supplier_id,currency_id,exchange_rate,settlement_type_id,
                            amount_original,amount_original_local,amount_received_original,amount_received_local,
                            amount_write_off_original,amount_write_off_local,amount_balance_original,amount_settled,amount_balance,
                            is_settled,status,is_deleted,created_by)
                        VALUES(?,'AP',?,'PAYABLE',?,?,?,?,?,?,?,?,?,?,?,0,0,0,0,?,0,?,FALSE,1,FALSE,?)
                        """,UUID.randomUUID(),type,type+"_RECEIPT",receipt,row.getString("bill_no"),row.getString("bill_no"),row.getObject("bill_date"),
                        row.getObject("supplier_id"),row.getObject("currency_id"),rate,row.getObject("settlement_method_id"),
                        original,local,original,local,actor);
            }
        }
    }

    public static void appendExistingQualityConsideration(Connection connection,String type,UUID receipt,UUID actor)
            throws SQLException {
        requireTransaction(connection);prefix(type);
        execute(connection,"""
                INSERT INTO procurement_iqc_quality_consideration_parts(id,inspection_event_id,consideration_part_id,
                    base_qty,amount_original,amount_local,created_by)
                SELECT gen_random_uuid(),event.id,part.id,event.base_qty,
                    part.nominal_original*event.base_qty/part.base_qty,part.nominal_local*event.base_qty/part.base_qty,?
                FROM procurement_inspection_items inspection JOIN procurement_inspection_events event ON event.inspection_item_id=inspection.id
                JOIN procurement_receipt_consideration_parts part ON part.receipt_type=inspection.receipt_type AND part.receipt_item_id=inspection.receipt_item_id
                WHERE inspection.receipt_type=? AND inspection.receipt_id=? AND event.action IN ('PASS','FAIL')
                  AND part.billing_mode='STANDARD' AND NOT EXISTS(SELECT 1 FROM procurement_iqc_quality_consideration_parts existing
                    WHERE existing.inspection_event_id=event.id AND existing.consideration_part_id=part.id)
                """,actor,type,receipt);
    }

    private static final java.util.concurrent.atomic.AtomicInteger FIXTURE_NUMBERS=new java.util.concurrent.atomic.AtomicInteger(800000);

    public static void seedZeroPriceQualifiedStock(Connection connection,UUID warehouse,UUID goods,UUID unit,
            UUID supplier,UUID currency,UUID settlement,BigDecimal qty,UUID actor,java.time.LocalDate date) throws SQLException {
        if(!connection.getAutoCommit())throw new IllegalStateException("Initial stock fixture owns its receipt transaction");
        int sequence=FIXTURE_NUMBERS.incrementAndGet();String digits=date.toString().replace("-","")+"%06d".formatted(sequence);
        UUID order=UUID.randomUUID(),orderItem=UUID.randomUUID(),receipt=UUID.randomUUID(),item=UUID.randomUUID(),inspection=UUID.randomUUID();
        connection.setAutoCommit(false);
        try {
            execute(connection,"INSERT INTO purchase_orders(id,bill_no,bill_date,supplier_id,warehouse_id,currency_id,settlement_method_id,exchange_rate,total_original,total_local,status) VALUES(?,?,?,?,?,?,?,1,0,0,1)",order,"CD"+digits,date,supplier,warehouse,currency,settlement);
            execute(connection,"INSERT INTO purchase_order_items(id,bill_no,bill_date,order_id,line_no,goods_id,unit_id,unit_rate,qty,price,amount_original,amount_local,received_qty,goods_snapshot_source) VALUES(?,?,?,?,1,?,?,1,?,0,0,0,?,'MASTER_AT_SAVE')",orderItem,"CD"+digits,date,order,goods,unit,qty,qty);
            execute(connection,"INSERT INTO purchase_receipts(id,bill_no,bill_date,supplier_id,warehouse_id,currency_id,settlement_method_id,exchange_rate,total_original,total_local,status) VALUES(?,?,?,?,?,?,?,1,0,0,1)",receipt,"CJ"+digits,date,supplier,warehouse,currency,settlement);
            execute(connection,"INSERT INTO purchase_receipt_items(id,bill_no,bill_date,receipt_id,order_item_id,line_no,goods_id,unit_id,unit_rate,qty,price,amount_original,amount_local,replacement_intent,goods_snapshot_source) VALUES(?,?,?,?,?,1,?,?,1,?,0,0,0,'NORMAL','MASTER_AT_SAVE')",item,"CJ"+digits,date,receipt,orderItem,goods,unit,qty);
            appendStandardReceipt(connection,"PURCHASE",receipt,actor);
            execute(connection,"INSERT INTO procurement_inspection_items(id,receipt_type,receipt_id,receipt_item_id,warehouse_id,goods_id,unit_id,unit_rate,received_base_qty,received_amount_local,status) VALUES(?,'PURCHASE',?,?,?,?,?,1,?,0,'PENDING')",inspection,receipt,item,warehouse,goods,unit,qty);
            recordZeroPriceQualityDecision(connection,inspection,"PASS",qty,actor);
            connection.commit();
        } catch(SQLException|RuntimeException failure) { connection.rollback();throw failure; }
        finally { connection.setAutoCommit(true); }
        stockZeroPricePasses(connection,java.util.List.of(inspection));
    }

    public static void postSubcontractIssueFixture(Connection connection,UUID issue,UUID issueItem,UUID orderItem,UUID planItem,
            UUID warehouse,UUID goods,UUID unit,BigDecimal qty,UUID actor,String billNo,java.time.LocalDate date) {
        withValueWriter(connection,writer -> {
            var pool=new com.uten.imp.application.port.InventoryValuationPort.PoolKey(warehouse,goods,null);
            writer.mutex().lock(new com.uten.imp.features.stock.InventoryKey(goods,null));
            var balance=writer.db().queryForMap("SELECT id,qty FROM stock_balances WHERE warehouse_id=:warehouse AND goods_id=:goods AND color_id IS NULL",java.util.Map.of("warehouse",warehouse,"goods",goods));
            execute(connection,"INSERT INTO subcontract_material_issues(id,bill_no,bill_date,warehouse_id,status,created_by) VALUES(?,?,?,?,1,?)",issue,billNo,date,warehouse,actor);
            execute(connection,"""
                    INSERT INTO subcontract_material_issue_items(id,bill_no,bill_date,issue_id,order_item_id,line_no,goods_id,unit_id,
                        unit_rate,qty,at_supplier_qty,consumed_qty,plan_item_id,frozen_unit_qty,goods_code_snapshot,goods_name_snapshot,goods_snapshot_source,goods_snapshot_locked_at)
                    SELECT ?,?,?,?,?,1,id,?,1,?,?,0,?,1,code,name,'MASTER_AT_APPROVAL',now() FROM goods WHERE id=?
                    """,issueItem,billNo,date,issue,orderItem,unit,qty,qty,planItem,goods);
            UUID reservation=UUID.randomUUID();
            execute(connection,"""
                    INSERT INTO stock_reservations(id,order_item_id,goods_id,warehouse_id,qty,consumed_qty,released_qty,status,source,
                        source_doc_type,source_doc_id,owner_type,owner_id,purpose,supply_type,supply_id,idempotency_key,created_by,updated_by)
                    VALUES(?,NULL,?,?,?,?,0,1,0,'SUBCONTRACT_OUTBOUND_DRAFT',?,'SUBCONTRACT_OUTBOUND',?,'SUBCONTRACT_OUTBOUND','STOCK_BALANCE',?,?,?,?)
                    """,reservation,goods,warehouse,qty,qty,issue,planItem,balance.get("id"),"fixture-reservation-"+reservation,actor,actor);
            execute(connection,"INSERT INTO subcontract_outbound_issue_reservation_allocations(id,issue_id,issue_item_id,plan_item_id,reservation_id,allocated_qty,status,idempotency_key,created_by) VALUES(?,?,?,?,?,?,'EFFECTIVE',?,?)",UUID.randomUUID(),issue,issueItem,planItem,reservation,qty,"fixture-issue-"+issueItem,actor);
            UUID movement=UUID.randomUUID();var values=new com.uten.imp.features.stock.valuation.InventoryValuationService(writer.db(),writer.mutex());
            var value=values.issue(new com.uten.imp.application.port.InventoryValuationPort.Issue(
                    context(writer.db(),"SUBCONTRACT_MATERIAL_ISSUE",movement,issue,issueItem,actor),movement,pool,qty,(BigDecimal)balance.get("qty"),
                    com.uten.imp.application.port.InventoryValuationPort.Destination.SUBCONTRACT_WIP,issueItem));
            execute(connection,"INSERT INTO stock_movements(id,transaction_date,movement_type,source_doc_type,source_doc_id,source_item_id,goods_id,warehouse_id,direction,qty,unit_id,unit_rate,amount_local) VALUES(?,now(),15,'SUBCONTRACT_MATERIAL_ISSUE',?,?,?,?,-1,?,?,1,?)",movement,issue,issueItem,goods,warehouse,qty,unit,value.knownValueLocal());
            execute(connection,"UPDATE stock_balances SET qty=qty-?,amount_local=amount_local-? WHERE id=?",qty,value.knownValueLocal(),balance.get("id"));
            execute(connection,"UPDATE subcontract_material_plan_items SET issued_qty=? WHERE id=?",qty,planItem);
        });
    }

    public static UUID appendFailureFunding(Connection connection,UUID caseId,UUID actor) throws SQLException {
        requireTransaction(connection);UUID funding=UUID.randomUUID();
        try(var statement=connection.prepareStatement("""
                INSERT INTO procurement_iqc_funding_slices(id,case_id,quality_part_id,root_funding_slice_id,root_case_id,
                    root_receipt_item_id,source_ap_ledger_id,base_qty,amount_original,amount_local,created_by)
                SELECT ?,rejection.id,quality.id,?,rejection.id,part.receipt_item_id,ledger.id,
                    quality.base_qty,quality.amount_original,quality.amount_local,?
                FROM procurement_iqc_rejection_cases rejection JOIN procurement_inspection_events event
                    ON event.inspection_item_id=rejection.inspection_item_id AND event.action='FAIL'
                JOIN procurement_iqc_quality_consideration_parts quality ON quality.inspection_event_id=event.id
                JOIN procurement_receipt_consideration_parts part ON part.id=quality.consideration_part_id AND part.billing_mode='STANDARD'
                LEFT JOIN ar_ap_ledger ledger ON ledger.source_doc_type=part.receipt_type||'_RECEIPT' AND ledger.source_doc_id=part.receipt_id
                    AND ledger.direction='AP' AND ledger.status=1 AND ledger.is_deleted=FALSE
                WHERE rejection.id=?
                """)) {
            statement.setObject(1,funding);statement.setObject(2,funding);statement.setObject(3,actor);statement.setObject(4,caseId);
            if(statement.executeUpdate()!=1)throw new SQLException("Fixture needs one actual failure source for this returned case");
        }
        execute(connection,"""
                INSERT INTO procurement_iqc_rejection_events(id,case_id,event_type,command_id,actor_user_id,reference,event_date,reason)
                SELECT gen_random_uuid(),id,'RETURN_RECORDED',gen_random_uuid(),return_recorded_by,return_reference,return_date,return_note
                FROM procurement_iqc_rejection_cases WHERE id=?
                """,caseId);
        return funding;
    }

    public static void appendNoChargeReplacement(Connection connection,String type,UUID receipt,UUID allocation,UUID funding,UUID actor)
            throws SQLException {
        requireTransaction(connection);
        execute(connection,"""
                INSERT INTO procurement_receipt_consideration_parts(id,receipt_type,receipt_id,receipt_item_id,billing_mode,
                    replacement_allocation_id,funding_slice_id,base_qty,nominal_original,nominal_local,payable_original,payable_local,created_by)
                SELECT gen_random_uuid(),?,?,id,'NO_CHARGE',?,?,qty*unit_rate,amount_original,amount_local,0,0,?
                FROM %s WHERE receipt_id=? AND is_deleted=FALSE
                """.formatted(prefix(type)+"_receipt_items"),type,receipt,allocation,funding,actor,receipt);
        execute(connection,"SELECT fn_assert_procurement_consideration_receipt(?,?)",type,receipt);
    }

    public static void appendReceiptReversal(Connection connection, String type, UUID receipt)
            throws SQLException {
        requireTransaction(connection);
        prefix(type);
        execute(connection, """
                INSERT INTO procurement_iqc_consideration_reversals(
                    id,target_kind,target_id,command_id,reason,created_by)
                SELECT gen_random_uuid(),'CONSIDERATION',part.id,?,
                    'Quantity fixture reverses its original approved receipt',part.created_by
                FROM procurement_receipt_consideration_parts part
                WHERE part.receipt_type=? AND part.receipt_id=?
                  AND fn_procurement_consideration_active('CONSIDERATION',part.id)
                """, UUID.randomUUID(), type, receipt);
    }

    public static UUID recordZeroPriceQualityDecision(Connection connection, UUID inspection, String action,
            BigDecimal qty, UUID actor) throws SQLException {
        requireTransaction(connection);
        if (!java.util.Set.of("PASS", "FAIL").contains(action) || qty.signum() <= 0)
            throw new IllegalArgumentException("Fixture quality decision needs a positive PASS or FAIL quantity");
        try (var query=connection.prepareStatement("SELECT part.nominal_original,part.nominal_local FROM procurement_inspection_items inspection JOIN procurement_receipt_consideration_parts part ON part.receipt_type=inspection.receipt_type AND part.receipt_item_id=inspection.receipt_item_id WHERE inspection.id=? AND part.billing_mode='STANDARD' AND fn_procurement_consideration_active('CONSIDERATION',part.id)")) {
            query.setObject(1,inspection);
            try(var rows=query.executeQuery()) {
                if(!rows.next() || rows.getBigDecimal(1)==null || rows.getBigDecimal(2)==null
                        || rows.getBigDecimal(1).signum()!=0 || rows.getBigDecimal(2).signum()!=0 || rows.next())
                    throw new SQLException("Zero-price quality fixture requires one explicit zero-valued STANDARD source");
            }
        }
        UUID event = UUID.randomUUID();
        execute(connection, """
                UPDATE procurement_inspection_items SET
                    passed_base_qty=passed_base_qty+CASE WHEN ?='PASS' THEN ? ELSE 0 END,
                    failed_base_qty=failed_base_qty+CASE WHEN ?='FAIL' THEN ? ELSE 0 END,
                    status=CASE WHEN passed_base_qty+failed_base_qty+?=received_base_qty THEN 'RESOLVED' ELSE 'PARTIAL' END
                WHERE id=?
                """, action, qty, action, qty, qty, inspection);
        execute(connection, """
                INSERT INTO procurement_inspection_events(id,inspection_item_id,action,base_qty,reason,
                    actor_employee_id,requires_warehouse_stock_in,released_amount_local)
                SELECT ?,?,?,?,'Recorded fixture quality decision',employee_id,?='PASS',
                    CASE WHEN ?='PASS' THEN 0 ELSE NULL END FROM users WHERE id=?
                """, event, inspection, action, qty, action, action, actor);
        execute(connection, """
                INSERT INTO procurement_iqc_quality_consideration_parts(id,inspection_event_id,
                    consideration_part_id,base_qty,amount_original,amount_local,created_by)
                SELECT gen_random_uuid(),?,part.id,?,part.nominal_original*?/part.base_qty,
                    part.nominal_local*?/part.base_qty,?
                FROM procurement_inspection_items inspection JOIN procurement_receipt_consideration_parts part
                    ON part.receipt_type=inspection.receipt_type AND part.receipt_item_id=inspection.receipt_item_id
                WHERE inspection.id=? AND part.billing_mode='STANDARD'
                    AND fn_procurement_consideration_active('CONSIDERATION',part.id)
                """, event, qty, qty, qty, actor, inspection);
        if("FAIL".equals(action)) execute(connection,"""
                INSERT INTO business_outbox(id,event_type,aggregate_type,aggregate_id,payload,dedupe_key,created_by)
                SELECT gen_random_uuid(),'PROCUREMENT_IQC_REJECTION_DETECTED','PROCUREMENT_INSPECTION_ITEM',id,
                    jsonb_build_object('receiptType',receipt_type,'receiptId',receipt_id,'inspectionEventId',CAST(? AS text)),?,?
                FROM procurement_inspection_items WHERE id=?
                """,event,"PROCUREMENT_IQC_REJECTION_DETECTED:"+event,actor,inspection);
        return event;
    }

    /** Real value writer and immutable physical facts for the explicit zero-price quantity fixture. */
    public static void stockZeroPricePasses(Connection connection, java.util.List<UUID> inspections) {
        stockPasses(connection,inspections,true);
    }

    public static void stockPricedPasses(Connection connection, java.util.List<UUID> inspections) {
        stockPasses(connection,inspections,false);
    }

    private static void stockPasses(Connection connection,java.util.List<UUID> inspections,boolean zeroPriceOnly) {
        withValueWriter(connection, writer -> {
            var db=writer.db();var mutex=writer.mutex();var positions=writer.positions();
            UUID warehouseActor = createActor(connection);
            UUID warehouseEmployee = employee(db, warehouseActor);
            for (UUID inspection : inspections) {
                var rows = db.queryForList("""
                        SELECT inspection.receipt_type,inspection.receipt_id,inspection.warehouse_id,inspection.goods_id,inspection.color_id,inspection.unit_id,
                            event.id pass_event_id,event.base_qty pass_qty,event.released_amount_local released_local,quality.id quality_part_id,quality.amount_original quality_original,quality.amount_local quality_local,
                            part.id consideration_part_id,part.created_by source_actor,part.nominal_original,part.nominal_local
                        FROM procurement_inspection_items inspection
                        JOIN procurement_inspection_events event ON event.inspection_item_id=inspection.id AND event.action='PASS'
                        JOIN procurement_iqc_quality_consideration_parts quality ON quality.inspection_event_id=event.id
                        JOIN procurement_receipt_consideration_parts part ON part.id=quality.consideration_part_id
                        WHERE inspection.id=:id AND part.billing_mode='STANDARD'
                        """, java.util.Map.of("id", inspection));
                if (rows.size()!=1) throw new IllegalStateException("Fixture requires one real PASS and STANDARD source per receipt item");
                var row=rows.getFirst();
                if (zeroPriceOnly && (((BigDecimal)row.get("nominal_original")).signum()!=0 || ((BigDecimal)row.get("nominal_local")).signum()!=0))
                    throw new IllegalStateException("Zero-price warehouse fixture must not lower a priced source");
                var pool=new com.uten.imp.application.port.InventoryValuationPort.PoolKey(
                        (UUID)row.get("warehouse_id"),(UUID)row.get("goods_id"),(UUID)row.get("color_id"));
                mutex.lock(new com.uten.imp.features.stock.InventoryKey(pool.goodsId(),pool.colorId()));
                var dimensions=new java.util.HashMap<String,Object>();
                dimensions.put("warehouse",pool.warehouseId());dimensions.put("goods",pool.goodsId());dimensions.put("color",pool.colorId());
                var balances=db.queryForList("SELECT id,qty,amount_local FROM stock_balances WHERE warehouse_id=:warehouse AND goods_id=:goods AND color_id IS NOT DISTINCT FROM CAST(:color AS uuid)",dimensions);
                if(balances.isEmpty()) {
                    execute(connection,"INSERT INTO stock_balances(id,warehouse_id,goods_id,color_id,qty,amount_local) VALUES(?,?,?,?,0,0)",UUID.randomUUID(),pool.warehouseId(),pool.goodsId(),pool.colorId());
                    balances=db.queryForList("SELECT id,qty,amount_local FROM stock_balances WHERE warehouse_id=:warehouse AND goods_id=:goods AND color_id IS NOT DISTINCT FROM CAST(:color AS uuid)",dimensions);
                }
                if(balances.size()!=1 || balances.getFirst().get("amount_local")==null
                        || (zeroPriceOnly && ((BigDecimal)balances.getFirst().get("amount_local")).signum()!=0))
                    throw new IllegalStateException("Quantity fixture needs an explicit zero-value physical pool");
                String type=(String)row.get("receipt_type");
                UUID receipt=(UUID)row.get("receipt_id"),part=(UUID)row.get("consideration_part_id"),quality=(UUID)row.get("quality_part_id");
                UUID originalActor=(UUID)row.get("source_actor");
                BigDecimal qty=(BigDecimal)row.get("pass_qty"),before=(BigDecimal)balances.getFirst().get("qty");
                var acquired=positions.acquire(new com.uten.imp.application.port.InventoryPositionPort.Acquire(
                        context(db,"PROCUREMENT_ACQUIRE",part,receipt,part,originalActor),pool,part,1,
                        com.uten.imp.application.port.InventoryPositionPort.Owner.QUALITY_PENDING,part,java.util.List.of()));
                var passed=positions.move(new com.uten.imp.application.port.InventoryPositionPort.Move(
                        context(db,"PROCUREMENT_QUALITY",quality,(UUID)row.get("pass_event_id"),quality,originalActor),pool,
                        com.uten.imp.application.port.InventoryPositionPort.Owner.QUALITY_PASSED,quality,
                        java.util.List.of(new com.uten.imp.application.port.InventoryPositionPort.Slice(acquired.positionRootId(),qty,quality))));
                UUID batch=UUID.randomUUID(),item=UUID.randomUUID(),movement=UUID.randomUUID(),stockPart=UUID.randomUUID();
                execute(connection,"""
                        INSERT INTO procurement_iqc_stock_in_batches(id,actor_user_id,actor_employee_id,receipt_type,receipt_id,idempotency_key,request_hash,confirmed_count)
                        VALUES(?,?,?,?,?,?,?,1)
                        """,batch,warehouseActor,warehouseEmployee,type,receipt,"fixture-stock-"+batch,"f".repeat(64));
                execute(connection,"""
                        INSERT INTO procurement_iqc_stock_in_batch_items(id,batch_id,position,inspection_item_id,pass_event_id,stock_movement_id,
                            warehouse_id,goods_id,color_id,expected_remaining_base_qty,base_qty,amount_local,place_snapshot)
                        VALUES(?,?,1,?,?,?,?,?,?,?,?,?,'FIXTURE-A1')
                        """,item,batch,inspection,row.get("pass_event_id"),movement,pool.warehouseId(),pool.goodsId(),pool.colorId(),qty,qty,row.get("released_local"));
                execute(connection,"INSERT INTO procurement_iqc_stock_consideration_parts(id,stock_in_item_id,quality_part_id,base_qty,amount_original,amount_local,created_by) VALUES(?,?,?,?,?,?,?)",
                        stockPart,item,quality,qty,row.get("quality_original"),row.get("quality_local"),warehouseActor);
                var stored=positions.store(new com.uten.imp.application.port.InventoryPositionPort.Store(
                        context(db,type+"_RECEIPT",movement,receipt,item,warehouseActor),movement,pool,before,
                        java.util.List.of(new com.uten.imp.application.port.InventoryPositionPort.Slice(passed.positionRootId(),qty,stockPart)),"SUBCONTRACT".equals(type)));
                execute(connection,"""
                        INSERT INTO stock_movements(id,transaction_date,movement_type,source_doc_type,source_doc_id,source_item_id,
                            goods_id,color_id,warehouse_id,direction,qty,unit_id,unit_rate,amount_local)
                        VALUES(?,now(),?,?,?,?,?,?,?,1,?,?,1,?)
                        """,movement,"PURCHASE".equals(type)?1:17,type+"_RECEIPT",receipt,item,pool.goodsId(),pool.colorId(),pool.warehouseId(),qty,row.get("unit_id"),stored.knownValueLocal());
                execute(connection,"UPDATE stock_balances SET qty=qty+?,amount_local=amount_local+? WHERE id=?",qty,stored.knownValueLocal(),balances.getFirst().get("id"));
                execute(connection,"UPDATE procurement_inspection_items SET warehouse_stocked_base_qty=warehouse_stocked_base_qty+?,warehouse_stocked_amount_local=warehouse_stocked_amount_local+? WHERE id=?",qty,row.get("released_local"),inspection);
            }
        });
    }

    /** Reverse an unused STANDARD fixture through actual custody, physical and consideration facts. */
    public static void reverseStoredReceipt(Connection connection,String type,UUID receipt,UUID actor) {
        prefix(type);
        withValueWriter(connection,writer -> {
            var db=writer.db();var positions=writer.positions();
            var items=db.queryForList("""
                    SELECT item.id,item.stock_movement_id,item.base_qty,item.inspection_item_id,item.warehouse_id,item.goods_id,item.color_id,
                        movement.unit_id,movement.unit_rate
                    FROM procurement_iqc_stock_in_batch_items item JOIN procurement_inspection_items inspection ON inspection.id=item.inspection_item_id
                    JOIN stock_movements movement ON movement.id=item.stock_movement_id
                    JOIN stock_value_events event ON event.movement_id=movement.id AND event.operation='POSITION_STORE'
                    WHERE inspection.receipt_type=:type AND inspection.receipt_id=:receipt ORDER BY event.created_at DESC,event.id DESC
                    """,java.util.Map.of("type",type,"receipt",receipt));
            for(var item:items) {
                var pool=new com.uten.imp.application.port.InventoryValuationPort.PoolKey((UUID)item.get("warehouse_id"),(UUID)item.get("goods_id"),(UUID)item.get("color_id"));
                writer.mutex().lock(new com.uten.imp.features.stock.InventoryKey(pool.goodsId(),pool.colorId()));
                var dimensions=new java.util.HashMap<String,Object>();dimensions.put("warehouse",pool.warehouseId());dimensions.put("goods",pool.goodsId());dimensions.put("color",pool.colorId());
                var balance=db.queryForMap("SELECT id,qty FROM stock_balances WHERE warehouse_id=:warehouse AND goods_id=:goods AND color_id IS NOT DISTINCT FROM CAST(:color AS uuid)",dimensions);
                UUID movement=UUID.randomUUID();
                var result=positions.reverseStore(new com.uten.imp.application.port.InventoryPositionPort.ReverseStore(
                        context(db,type+"_RECEIPT",movement,receipt,(UUID)item.get("id"),actor),movement,pool,(BigDecimal)balance.get("qty"),(UUID)item.get("stock_movement_id")));
                execute(connection,"""
                        INSERT INTO stock_movements(id,transaction_date,movement_type,source_doc_type,source_doc_id,source_item_id,
                            goods_id,color_id,warehouse_id,direction,qty,unit_id,unit_rate,amount_local)
                        VALUES(?,now(),?,?,?,?,?,?,?,-1,?,?,?,?)
                        """,movement,"PURCHASE".equals(type)?1:17,type+"_RECEIPT",receipt,item.get("id"),pool.goodsId(),pool.colorId(),pool.warehouseId(),item.get("base_qty"),item.get("unit_id"),item.get("unit_rate"),result.knownValueLocal());
                execute(connection,"UPDATE stock_balances SET qty=qty-?,amount_local=amount_local-? WHERE id=?",item.get("base_qty"),result.knownValueLocal(),balance.get("id"));
            }
            var quality=db.queryForList("""
                    SELECT quality.id,quality.consideration_part_id,quality.base_qty,event.id event_id,event.action,
                        inspection.warehouse_id,inspection.goods_id,inspection.color_id
                    FROM procurement_iqc_quality_consideration_parts quality JOIN procurement_inspection_events event ON event.id=quality.inspection_event_id
                    JOIN procurement_inspection_items inspection ON inspection.id=event.inspection_item_id
                    WHERE inspection.receipt_type=:type AND inspection.receipt_id=:receipt
                    """,java.util.Map.of("type",type,"receipt",receipt));
            for(var part:quality) {
                var pool=new com.uten.imp.application.port.InventoryValuationPort.PoolKey((UUID)part.get("warehouse_id"),(UUID)part.get("goods_id"),(UUID)part.get("color_id"));
                writer.mutex().lock(new com.uten.imp.features.stock.InventoryKey(pool.goodsId(),pool.colorId()));
                positions.move(new com.uten.imp.application.port.InventoryPositionPort.Move(
                        context(db,"PROCUREMENT_QUALITY_REVERSE",(UUID)part.get("id"),(UUID)part.get("event_id"),(UUID)part.get("id"),actor),pool,
                        com.uten.imp.application.port.InventoryPositionPort.Owner.QUALITY_PENDING,(UUID)part.get("consideration_part_id"),
                        ownedSlices(db,"PASS".equals(part.get("action"))?"QUALITY_PASSED":"REJECTED_HOLD",(UUID)part.get("id"),(BigDecimal)part.get("base_qty"))));
            }
            execute(connection,"""
                    INSERT INTO procurement_iqc_consideration_reversals(id,target_kind,target_id,command_id,reason,created_by)
                    SELECT gen_random_uuid(),'STOCK',part.id,?,'Fixture actual receipt reversal',?
                    FROM procurement_iqc_stock_consideration_parts part JOIN procurement_iqc_stock_in_batch_items item ON item.id=part.stock_in_item_id
                    JOIN procurement_inspection_items inspection ON inspection.id=item.inspection_item_id WHERE inspection.receipt_type=? AND inspection.receipt_id=?
                    UNION ALL
                    SELECT gen_random_uuid(),'QUALITY',part.id,?,'Fixture actual receipt reversal',?
                    FROM procurement_iqc_quality_consideration_parts part JOIN procurement_inspection_events event ON event.id=part.inspection_event_id
                    JOIN procurement_inspection_items inspection ON inspection.id=event.inspection_item_id WHERE inspection.receipt_type=? AND inspection.receipt_id=?
                    """,UUID.randomUUID(),actor,type,receipt,UUID.randomUUID(),actor,type,receipt);
            execute(connection,"UPDATE procurement_inspection_items SET passed_base_qty=0,failed_base_qty=0,status='REVERSED',warehouse_stocked_base_qty=0,warehouse_stocked_amount_local=0,warehouse_stocked_weight=NULL WHERE receipt_type=? AND receipt_id=?",type,receipt);
            execute(connection,"UPDATE "+prefix(type)+"_receipts SET status=-1 WHERE id=?",receipt);
            execute(connection,"UPDATE ar_ap_ledger SET status=-1,is_deleted=TRUE,deleted_at=now() WHERE source_doc_type=? AND source_doc_id=? AND amount_settled=0 AND amount_offset_original=0 AND amount_offset_local=0",type+"_RECEIPT",receipt);
            appendReceiptReversal(connection,type,receipt);
            for(var part:db.queryForList("""
                    SELECT part.id,part.base_qty,receipt.warehouse_id,item.goods_id,item.color_id
                    FROM procurement_receipt_consideration_parts part JOIN %s receipt ON receipt.id=part.receipt_id
                    JOIN %s item ON item.id=part.receipt_item_id WHERE part.receipt_type=:type AND part.receipt_id=:receipt
                    """.formatted(prefix(type)+"_receipts",prefix(type)+"_receipt_items"),java.util.Map.of("type",type,"receipt",receipt))) {
                var pool=new com.uten.imp.application.port.InventoryValuationPort.PoolKey((UUID)part.get("warehouse_id"),(UUID)part.get("goods_id"),(UUID)part.get("color_id"));
                writer.mutex().lock(new com.uten.imp.features.stock.InventoryKey(pool.goodsId(),pool.colorId()));
                positions.move(new com.uten.imp.application.port.InventoryPositionPort.Move(
                        context(db,"PROCUREMENT_RECEIPT_REVERSE",(UUID)part.get("id"),receipt,(UUID)part.get("id"),actor),pool,
                        com.uten.imp.application.port.InventoryPositionPort.Owner.EXTERNAL,(UUID)part.get("id"),
                        ownedSlices(db,"QUALITY_PENDING",(UUID)part.get("id"),(BigDecimal)part.get("base_qty"))));
            }
        });
    }

    private static java.util.List<com.uten.imp.application.port.InventoryPositionPort.Slice> ownedSlices(
            org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate db,String owner,UUID ownerId,BigDecimal required) {
        var result=new java.util.ArrayList<com.uten.imp.application.port.InventoryPositionPort.Slice>();BigDecimal remaining=required;
        for(var row:db.queryForList("""
                SELECT root.id,head.range_to-head.range_from qty FROM stock_value_nodes root
                JOIN stock_value_nodes head ON head.id=root.return_head_id
                WHERE root.root_issue_id=root.id AND head.owner_kind=:owner AND head.owner_id=:id
                    AND head.range_to>head.range_from ORDER BY root.created_at,root.id
                """,java.util.Map.of("owner",owner,"id",ownerId))) {
            if(remaining.signum()==0)break;BigDecimal take=remaining.min((BigDecimal)row.get("qty"));
            result.add(new com.uten.imp.application.port.InventoryPositionPort.Slice((UUID)row.get("id"),take,(UUID)row.get("id")));remaining=remaining.subtract(take);
        }
        if(remaining.signum()!=0)throw new IllegalStateException("Fixture reversal cannot invent missing source custody");
        return result.size()==1?java.util.List.of(new com.uten.imp.application.port.InventoryPositionPort.Slice(result.getFirst().positionRootId(),required,ownerId)):java.util.List.copyOf(result);
    }

    public static void recordZeroPriceFailure(Connection connection, UUID inspection, BigDecimal qty, UUID actor) {
        withValueWriter(connection, writer -> {
            UUID event=recordZeroPriceQualityDecision(connection,inspection,"FAIL",qty,actor);
            var row=writer.db().queryForMap("""
                    SELECT inspection.receipt_id,inspection.warehouse_id,inspection.goods_id,inspection.color_id,
                        quality.id quality_part_id,acquired.result_node_id
                    FROM procurement_iqc_quality_consideration_parts quality
                    JOIN procurement_inspection_items inspection ON inspection.id=:inspection
                    JOIN stock_value_acquisition_sources source ON source.evidence_id=quality.consideration_part_id
                    JOIN stock_value_events acquired ON acquired.id=source.event_id
                    WHERE quality.inspection_event_id=:event
                    """,java.util.Map.of("inspection",inspection,"event",event));
            var pool=new com.uten.imp.application.port.InventoryValuationPort.PoolKey(
                    (UUID)row.get("warehouse_id"),(UUID)row.get("goods_id"),(UUID)row.get("color_id"));
            UUID quality=(UUID)row.get("quality_part_id");
            writer.mutex().lock(new com.uten.imp.features.stock.InventoryKey(pool.goodsId(),pool.colorId()));
            writer.positions().move(new com.uten.imp.application.port.InventoryPositionPort.Move(
                    context(writer.db(),"PROCUREMENT_QUALITY",quality,event,quality,actor),pool,
                    com.uten.imp.application.port.InventoryPositionPort.Owner.REJECTED_HOLD,quality,
                    java.util.List.of(new com.uten.imp.application.port.InventoryPositionPort.Slice((UUID)row.get("result_node_id"),qty,quality))));
        });
    }

    private record ValueWriter(org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate db,
            com.uten.imp.features.stock.InventoryMutationLock mutex,
            com.uten.imp.features.stock.valuation.InventoryPositionService positions) {}
    @FunctionalInterface private interface ValueWork { void run(ValueWriter writer) throws SQLException; }

    private static void withValueWriter(Connection connection, ValueWork work) {
        try {
            if(!connection.getAutoCommit()) throw new IllegalStateException("Value fixture owns its actual acceptance transaction");
        } catch(SQLException failure) { throw new IllegalStateException(failure); }
        var source=new org.springframework.jdbc.datasource.SingleConnectionDataSource(connection,true);
        var factory=new org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean();
        factory.setDataSource(source);
        factory.setPackagesToScan("com.uten.imp.support.receiptfixture.noentities");
        factory.setJpaVendorAdapter(new org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter());
        factory.setJpaPropertyMap(java.util.Map.of("hibernate.hbm2ddl.auto","none"));
        factory.afterPropertiesSet();
        try {
            var transactions=new org.springframework.transaction.support.TransactionTemplate(
                    new org.springframework.orm.jpa.JpaTransactionManager(factory.getObject()));
            var entityManager=org.springframework.orm.jpa.SharedEntityManagerCreator.createSharedEntityManager(factory.getObject());
            var db=new org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate(source);
            var mutex=new com.uten.imp.features.stock.InventoryMutationLock(entityManager);
            var evidence=new com.uten.imp.features.stock.valuation.ProcurementCostSourceEvidenceService(db);
            var positions=new com.uten.imp.features.stock.valuation.InventoryPositionService(db,mutex,java.util.Optional.of(evidence::approved));
            transactions.executeWithoutResult(transaction -> {
                try { work.run(new ValueWriter(db,mutex,positions)); }
                catch(SQLException failure) { throw new IllegalStateException(failure); }
            });
        } finally { factory.destroy(); }
    }

    private static UUID employee(org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate db, UUID actor) {
        return db.queryForObject("SELECT employee_id FROM users WHERE id=:id",java.util.Map.of("id",actor),UUID.class);
    }

    private static com.uten.imp.application.port.InventoryValuationPort.EventContext context(
            org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate db,String kind,UUID event,UUID document,UUID item,UUID actor) {
        UUID sourceEvent=kind.endsWith("_REVERSE")
                ?UUID.nameUUIDFromBytes((kind+":"+event).getBytes(java.nio.charset.StandardCharsets.UTF_8)):event;
        return new com.uten.imp.application.port.InventoryValuationPort.EventContext(sourceEvent,kind,document,item,1,actor,employee(db,actor),kind+":"+sourceEvent,java.time.OffsetDateTime.now());
    }

    public static UUID createActor(Connection connection) throws SQLException {
        requireTransaction(connection);
        UUID department;
        try (var statement = connection.createStatement(); var rows = statement.executeQuery(
                "SELECT id FROM departments WHERE is_deleted=FALSE ORDER BY code LIMIT 1")) {
            if (!rows.next()) throw new SQLException("Fixture needs an actual department");
            department = rows.getObject(1, UUID.class);
        }
        UUID employee = UUID.randomUUID(), actor = UUID.randomUUID();
        execute(connection, """
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                VALUES(?,?,'Receipt fixture actor',(SELECT id_type FROM employees ORDER BY id LIMIT 1),
                    ?,DATE '2026-01-01','active','regular')
                """, employee, "RF-E-" + employee, department);
        execute(connection, "INSERT INTO users(id,employee_id,login_account,password_hash,status) VALUES(?,?,?,'test-only-hash','active')",
                actor, employee, "receipt-fixture-" + actor);
        return actor;
    }

    private static void requireTransaction(Connection connection) throws SQLException {
        if (connection.getAutoCommit()) throw new IllegalStateException("Receipt, consideration and source AP must share the caller's transaction");
    }

    private static String prefix(String type) {
        return switch (type) {
            case "PURCHASE" -> "purchase";
            case "SUBCONTRACT" -> "subcontract";
            default -> throw new IllegalArgumentException("Unsupported receipt type");
        };
    }

    private static void execute(Connection connection, String sql, Object... values) throws SQLException {
        try (var statement = connection.prepareStatement(sql)) {
            for (int index = 0; index < values.length; index++) statement.setObject(index + 1, values[index]);
            statement.execute();
        }
    }
}
