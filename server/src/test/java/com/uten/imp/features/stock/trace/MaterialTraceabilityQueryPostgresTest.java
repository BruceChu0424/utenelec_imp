package com.uten.imp.features.stock.trace;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.ActiveOperatorPort;
import com.uten.imp.application.port.MaterialTraceabilityReadPort.Result;
import com.uten.imp.application.port.MaterialTraceabilityReadPort;
import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.purchase.PurchaseDocumentAccessPolicy;
import com.uten.imp.features.stock.StockDocAccessPolicy;
import com.uten.imp.features.stock.allocation.ProductionMaterialTaskAccessPolicy;
import com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy;
import com.uten.imp.security.*;
import com.uten.imp.support.MigratedSchemaBaseline;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;

import java.math.BigDecimal;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.features.stock.trace.GoodsProductionTraceContracts.TraceRow;
import static com.uten.imp.features.stock.trace.MaterialTraceabilityQueryFixture.DAY;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Formal query SQL and DTOs against a migrated PostgreSQL projection, not a stock/production command test. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class MaterialTraceabilityQueryPostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private MaterialTraceabilityQueryFixture f;
    private MaterialTraceabilityQueryService query;
    private GoodsProductionTraceQueryService canonical;
    private WarehouseTaskScopePort warehouses;
    private Set<UUID> visibleOwners;
    private WarehouseTaskScope warehouseScope;
    private boolean warehouseParticipant;
    private static final Set<String> FULL = Set.of("production_where_used:view", "stock:view", "production_plan:view",
            "production_daily_report:view", "stock_doc:view", "purchase_order:view", "purchase_receipt:view",
            "subcontract_order:view", "subcontract_receipt:view", "subcontract_material_issue:view", "supplier:view");

    @BeforeAll static void migrate() throws Exception {
        database = MigratedSchemaBaseline.openDatabase("material_trace_query");
    }
    @AfterAll static void closeDatabase() throws Exception { if (database != null) database.close(); }

    @BeforeEach void prepare() throws Exception {
        f = new MaterialTraceabilityQueryFixture(database.openConnection());
        visibleOwners = Set.of(f.owner);
        warehouseScope = WarehouseTaskScope.ALL;
        warehouseParticipant = false;
        login(FULL);
        var actor = new SecurityContextCurrentUser();
        var owners = mock(OwnerVisibility.class);
        when(owners.evaluate(anyString(), anyString())).thenAnswer(call -> {
            boolean all = actor.get().map(user -> user.isSuperAdmin() || user.getPermissions().contains(call.getArgument(1))).orElse(false);
            return new OwnerVisibility.OwnerScope(all, visibleOwners, visibleOwners);
        });
        warehouses = mock(WarehouseTaskScopePort.class, CALLS_REAL_METHODS);
        when(warehouses.current(nullable(UUID.class))).thenAnswer(ignored -> warehouseScope);
        when(warehouses.access()).thenAnswer(ignored -> new WarehouseTaskScopePort.WarehouseAccess(
                warehouseParticipant ? WarehouseTaskScopePort.Role.KEEPER : WarehouseTaskScopePort.Role.OTHER,
                List.of(), warehouseScope, false));
        var em = mock(EntityManager.class);
        var pool = new ProductionStockTaskAccessPolicy(actor, warehouses);
        var legacy = new ProductionMaterialReadAccessPolicy(em, actor, owners, pool);
        var material = new ProductionMaterialTaskAccessPolicy(em, actor, owners, legacy, mock(ActiveOperatorPort.class));
        var stock = new StockDocAccessPolicy(owners, actor);
        var production = new ProductionDocumentAccessPolicy(owners, actor);
        var purchase = new PurchaseDocumentAccessPolicy(owners, actor);
        var subcontract = new SubcontractDocumentAccessPolicy(owners, actor);
        canonical = new GoodsProductionTraceQueryService(f.db, material, stock, pool, production, purchase, actor);
        query = new MaterialTraceabilityQueryService(f.db, canonical, material, stock, production, purchase,
                subcontract, warehouses, actor);
    }

    @AfterEach void rollback() throws Exception {
        SecurityContextHolder.clearContext();
        if (f != null) f.close();
    }

    @Test void traceHeadersUseTheSameScopedFactsBeforeCountAndPagingIncludingCompoundEvidence() {
        var first=f.segment("HEADER-A",f.owner,f.warehouse,f.product,"8");
        var second=f.segment("HEADER-B",f.owner,f.warehouse,f.product,"12");
        f.segment("HEADER-HIDDEN",f.otherOwner,f.otherWarehouse,f.product,"999");
        var firstReport=f.report(first,"HEADER-REPORT-A","2","2",true);
        f.report(second,"HEADER-REPORT-B","3","3",true);
        f.allocate(f.purchase("HEADER-SOURCE-A",f.owner,f.warehouse,"8"),first,"8");
        f.allocate(f.purchase("HEADER-SOURCE-B",f.owner,f.warehouse,"12"),second,"12");
        var headers=Map.ofEntries(Map.entry("goods","Finished product"),Map.entry("code","PRODUCT-TRACE"),
                Map.entry("workshop","Injection workshop"),Map.entry("plan","PLAN-HEADER"),Map.entry("basis","ORDER"),
                Map.entry("issued",">=8"),Map.entry("returned","0"),Map.entry("consumed","2..3"),
                Map.entry("reports",DAY.toString()),Map.entry("workers","Visible owner"),
                Map.entry("productionBatches","HEADER-REPORT"),Map.entry("sources","RECEIPT-HEADER-SOURCE"));
        var page1=query.trace("GOODS",f.material,"usage",null,null,1,1,headers,"issued","desc");
        var page2=query.trace("GOODS",f.material,"usage",null,null,2,1,headers,"issued","desc");
        assertThat(page1.total()).isEqualTo(2);
        assertThat(page1.items()).extracting(MaterialTraceabilityReadPort.TraceItem::id).containsExactly("ORDER:"+second.demand());
        assertThat(page2.items()).extracting(MaterialTraceabilityReadPort.TraceItem::id).containsExactly("ORDER:"+first.demand());
        assertThat(((TraceRow)page1.items().getFirst()).issuedQty()).isEqualByComparingTo("12");
        assertThat(((TraceRow)page2.items().getFirst()).consumedQty()).isEqualByComparingTo("2");
        assertThat(canonical.query(f.product,"materials",1,20,Map.of("goods","Raw material","issued",">=8"),"issued","asc").getItems())
                .extracting(TraceRow::id).containsExactly("ORDER:"+first.demand(),"ORDER:"+second.demand());
        assertThat(query.trace("GOODS",f.material,"usage",null,null,1,20,Map.of("plan","HEADER-HIDDEN"),null,null).total()).isZero();
        assertThat(query.trace("GOODS",f.material,"usage",null,null,1,20,Map.of("allocated","0"),null,null).total()).isZero();
        assertThat(query.trace("PRODUCTION_REPORT",firstReport.report(),"materials",null,null,1,20,Map.of("issued",">=0"),null,null).total()).isZero();
        Set<String> restricted=new java.util.HashSet<>(FULL);restricted.remove("purchase_receipt:view");restricted.remove("production_daily_report:view");
        login(restricted);
        assertThat(query.trace("GOODS",f.material,"usage",null,null,1,20,Map.of("sources","HEADER-SOURCE"),null,null).total()).isZero();
        assertThat(query.trace("GOODS",f.material,"usage",null,null,1,20,Map.of("workers","Visible owner"),null,null).total()).isZero();
    }

    @Test void independentGoodsPickerDoesNotGrantPhysicalOrDocumentTraceAccess() {
        login(Set.of("production_where_used:view"));
        var goods = query.subjects("goods", "RAW-TRACE", true, 1, 1);
        assertThat(goods.getTotal()).isEqualTo(1);
        assertThat(goods.getItems()).singleElement().satisfies(subject -> {
            assertThat(subject.id()).isEqualTo(f.material);
            assertThat(subject.traceable()).isFalse();
            assertThat(subject.reason()).isNotBlank();
        });
        forbidden(() -> query.subjects("document", "ORDER", false, 1, 20));
        forbidden(() -> query.subjects("batch", "REPORT", false, 1, 20));
        forbidden(() -> trace("GOODS", f.material));
    }

    @Test void warehouseMemberMaySeeAnUnassignedDraftPlanButNotKnownForbiddenWarehouseFacts() {
        warehouseParticipant = true;
        warehouseScope = new WarehouseTaskScope(true, List.of(f.warehouse), true);
        when(warehouses.access()).thenAnswer(ignored -> new WarehouseTaskScopePort.WarehouseAccess(
                WarehouseTaskScopePort.Role.OTHER, List.of(), warehouseScope, true));
        UUID draft = draftPlan("PLAN-DRAFT-UNASSIGNED");
        assertThat(query.subjects("document", "PLAN-DRAFT-UNASSIGNED", true, 1, 1).getTotal()).isEqualTo(1);
        var result = trace("PRODUCTION_PLAN", draft);
        assertThat(result.items()).isEmpty();
        assertThat(result.sources()).singleElement().satisfies(source -> {
            assertThat(source.basis()).isEqualTo("ORDERED_QUANTITY");
            assertThat(source.qty()).isEqualByComparingTo("2");
            assertThat(source.status()).isEqualTo("DRAFT");
        });
        warehouseScope = new WarehouseTaskScope(true, List.of(f.warehouse), false);
        assertThat(query.subjects("document", "PLAN-DRAFT-UNASSIGNED", true, 1, 1).getTotal()).isZero();
        notFound(() -> trace("PRODUCTION_PLAN", draft));
        warehouseScope = new WarehouseTaskScope(true, List.of(f.warehouse), true);
        UUID knownPackage = draftPlan("PLAN-DRAFT-FORBIDDEN-PACKAGE");
        f.insert("production_planning_packages", "plan_id", knownPackage, "warehouse_id", f.otherWarehouse,
                "status", "CONFIRMED", "is_deleted", false);
        assertThat(query.subjects("document", "PLAN-DRAFT-FORBIDDEN-PACKAGE", true, 1, 1).getTotal()).isZero();
        notFound(() -> trace("PRODUCTION_PLAN", knownPackage));
        UUID knownDemand = draftPlan("PLAN-DRAFT-FORBIDDEN-DEMAND");
        f.insert("production_material_demands", "plan_id", knownDemand, "warehouse_id", f.otherWarehouse,
                "goods_id", f.material, "unit_id", f.materialUnit, "required_qty", BigDecimal.ONE,
                "supply_route", "BUY", "status", "OPEN", "is_deleted", false);
        assertThat(query.subjects("document", "PLAN-DRAFT-FORBIDDEN-DEMAND", true, 1, 1).getTotal()).isZero();
        notFound(() -> trace("PRODUCTION_PLAN", knownDemand));
    }

    @Test void sameNumberAcrossDocumentTypesRemainsTypedAndPagingPreservesTheAuthorizedTotal() {
        var purchase = f.purchase("SAME-NUMBER", f.owner, f.warehouse, "3");
        UUID subcontract = subcontractOrder("SAME-NUMBER", f.owner, f.warehouse, "4");
        var first = query.subjects("document", "SAME-NUMBER", true, 1, 1);
        var second = query.subjects("document", "SAME-NUMBER", true, 2, 1);
        assertThat(first.getTotal()).isEqualTo(2);
        assertThat(second.getTotal()).isEqualTo(2);
        assertThat(List.of(first.getItems().getFirst().id(), second.getItems().getFirst().id()))
                .containsExactlyInAnyOrder(purchase.order(), subcontract);
        assertThat(List.of(first.getItems().getFirst().type(), second.getItems().getFirst().type()))
                .containsExactlyInAnyOrder("PURCHASE_ORDER", "SUBCONTRACT_ORDER");
        var outside = query.subjects("document", "SAME-NUMBER", true, 3, 1);
        assertThat(outside.getItems()).isEmpty();
        assertThat(outside.getTotal()).isEqualTo(2);
        f.segment("APPROVAL", f.otherOwner, f.warehouse, f.product, "2");
        assertThat(query.subjects("document", "PLAN-APPROVAL", true, 1, 1).getTotal()).isZero();
        var planReviewer = new java.util.HashSet<>(FULL); planReviewer.add("production_plan:approve");
        login(planReviewer);
        assertThat(query.subjects("document", "PLAN-APPROVAL", true, 1, 1).getTotal()).isEqualTo(1);
    }

    @Test void ownerAndWarehousePoliciesFilterSubjectsBeforeCountAndLimitAndProtectKnownIds() {
        var hiddenOwner = f.purchase("ORDER-A-HIDDEN", f.otherOwner, f.warehouse, "11");
        var visible = f.purchase("ORDER-B-VISIBLE", f.owner, f.warehouse, "12");
        var hiddenWarehouse = f.purchase("ORDER-C-HIDDEN", f.owner, f.otherWarehouse, "13");
        warehouseParticipant = true;
        warehouseScope = new WarehouseTaskScope(true, List.of(f.warehouse), false);
        var page = query.subjects("document", "ORDER-", false, 1, 1);
        assertThat(page.getTotal()).isEqualTo(1);
        assertThat(page.getItems()).singleElement().satisfies(subject -> assertThat(subject.id()).isEqualTo(visible.order()));
        notFound(() -> trace("PURCHASE_ORDER", hiddenOwner.order()));
        notFound(() -> trace("PURCHASE_ORDER", hiddenWarehouse.order()));
        notFound(() -> trace("PURCHASE_ORDER", UUID.randomUUID()));
        visibleOwners = Set.of();
        assertThat(query.subjects("document", "ORDER-", false, 1, 1).getTotal()).isZero();
    }

    @Test void purchaseOrderWithoutAnyProductionUseStillShowsItsKnownOrderedAndReceivedSources() {
        var source = f.purchase("ORDER-NO-USE", f.owner, f.warehouse, "3.125");
        var result = trace("PURCHASE_ORDER", source.order());
        assertThat(result.items()).isEmpty();
        assertThat(result.subject().id()).isEqualTo(source.order());
        assertThat(result.sources()).anySatisfy(row -> {
            assertThat(row.basis()).isEqualTo("ORDERED_QUANTITY");
            assertThat(row.qty()).isEqualByComparingTo("3.125");
        }).anySatisfy(row -> assertThat(row.basis()).isEqualTo("RECEIPT_QUANTITY"));
    }

    @Test void twoReceiptAllocationsShareOneDrawWithoutDuplicatingThePhysicalIssueOrInventingBatchConsumption() {
        var target = f.segment("TWO-SOURCES", f.owner, f.warehouse, f.product, "8");
        var first = f.purchase("FIRST", f.owner, f.warehouse, "3");
        var second = f.purchase("SECOND", f.owner, f.warehouse, "5");
        f.allocate(first, target, "3"); f.allocate(second, target, "5");
        var actual = rows(trace("GOODS", f.material));
        assertThat(actual).singleElement().satisfies(row -> {
            assertThat(row.issuedQty()).isEqualByComparingTo("8");
            assertThat(row.consumedQty()).isNull();
            assertThat(row.receiptSources()).hasSize(2);
            assertThat(row.receiptSources()).extracting(source -> source.qty().stripTrailingZeros())
                    .containsExactlyInAnyOrder(new BigDecimal("3"), new BigDecimal("5"));
            assertThat(row.receiptSources()).allSatisfy(source -> assertThat(source.sourceBasis()).contains("非逐批实耗"));
        });
        var report = f.report(target, "TWO-SOURCES-USE", "2", "4", true);
        assertThat(rows(trace("GOODS", f.material))).singleElement().satisfies(row -> {
            assertThat(row.consumedQty()).isEqualByComparingTo("4");
            assertThat(row.receiptSources()).extracting(source -> source.qty().stripTrailingZeros())
                    .containsExactlyInAnyOrder(new BigDecimal("3"), new BigDecimal("5"));
        });
        UUID returned = f.stockPosting(target.demand(), target.reservation(), target.draw(), target.drawItem(), "GOOD_RETURN", "2", target.issue());
        assertThat(rows(trace("GOODS", f.material)).getFirst().returnedQty()).isEqualByComparingTo("2");
        f.stockPosting(target.demand(), target.reservation(), target.draw(), target.drawItem(), "GOOD_RETURN_REVERSE", "2", returned);
        UUID reversal = f.insert("production_material_settlement_events", "plan_id", target.plan(),
                "daily_report_id", report.report(), "event_type", "REVERSE");
        f.insert("production_material_settlement_postings", "event_id", reversal, "demand_id", target.demand(),
                "issue_posting_id", target.issue(), "source_posting_id", report.settlement(), "settlement_type", "CONSUMED", "qty_base", new BigDecimal("4"));
        f.db.update("UPDATE production_daily_reports SET status=-1 WHERE id=:id", Map.of("id", report.report()));
        f.stockPosting(target.demand(), target.reservation(), target.draw(), target.drawItem(), "ISSUE_REVERSE", "8", target.issue());
        assertThat(rows(trace("GOODS", f.material))).singleElement().satisfies(row -> {
            assertThat(row.issuedQty()).isZero(); assertThat(row.returnedQty()).isZero();
            assertThat(row.consumedQty()).isZero();
        });
    }

    @Test void reportAndOutputLotQueriesKeepBatchOutputsButNeverRelabelTaskCumulativeMaterialAsBatchUsage() {
        var target = f.segment("REPORTS", f.owner, f.warehouse, f.product, "20");
        var first = f.report(target, "REPORT-FIRST", "7", "3", true);
        var second = f.report(target, "REPORT-SECOND", "11", "5", true);
        f.report(target, "REPORT-DRAFT", "999", "9", false);
        var report = rows(trace("PRODUCTION_REPORT", first.report()));
        assertThat(report).singleElement().satisfies(row -> {
            assertThat(row.issuedQty()).isNull(); assertThat(row.returnedQty()).isNull();
            assertThat(row.consumedQty()).isNull(); assertThat(row.lossQty()).isNull();
            assertThat(row.reports()).singleElement().satisfies(output -> {
                assertThat(output.id()).isEqualTo(first.report());
                assertThat(output.productQty()).isEqualByComparingTo("7");
                assertThat(output.batches()).singleElement().satisfies(batch -> assertThat(batch.id()).isEqualTo(first.lot()));
            });
        });
        var lot = rows(query.trace("PRODUCTION_OUTPUT_LOT", first.lot(), "materials", null, null, 1, 50));
        assertThat(lot).singleElement().satisfies(row -> {
            assertThat(row.consumedQty()).isNull();
            assertThat(row.reports()).singleElement().satisfies(output -> assertThat(output.id()).isEqualTo(first.report()));
        });
        var wholeTask = rows(trace("GOODS", f.material)).getFirst();
        assertThat(wholeTask.consumedQty()).isEqualByComparingTo("8");
        assertThat(wholeTask.reports()).extracting(output -> output.id()).containsExactlyInAnyOrder(first.report(), second.report());
    }

    @Test void independentDocumentViewScopesMaskUnreachableReceiptsReportsAndSupplierIdentities() {
        var target = f.segment("MASK", f.owner, f.warehouse, f.product, "5");
        var source = f.purchase("MASK-SOURCE", f.owner, f.warehouse, "5");
        f.allocate(source, target, "5"); f.report(target, "MASK-REPORT", "2", "1", true);
        login(Set.of("production_where_used:view", "stock:view", "production_plan:view"));
        assertThat(rows(trace("GOODS", f.material))).singleElement().satisfies(row -> {
            assertThat(row.issuedQty()).isEqualByComparingTo("5");
            assertThat(row.reports()).isEmpty(); assertThat(row.receiptSources()).isEmpty(); assertThat(row.drawDocuments()).isEmpty();
        });
        login(Set.of("production_where_used:view", "stock:view", "production_plan:view", "stock_doc:view"));
        var limited = rows(trace("GOODS", f.material)).getFirst();
        assertThat(limited.reports()).isEmpty(); assertThat(limited.receiptSources()).isEmpty(); assertThat(limited.drawDocuments()).hasSize(1);
        login(FULL.stream().filter(permission -> !permission.equals("supplier:view")).collect(java.util.stream.Collectors.toSet()));
        assertThat(rows(trace("GOODS", f.material)).getFirst().receiptSources()).singleElement().satisfies(receipt -> {
            assertThat(receipt.supplierId()).isNull(); assertThat(receipt.supplierName()).isNull();
        });
    }

    @Test void oneReportWithTwoOutputLotsDoesNotDuplicateItsMaterialUseAcrossLots() {
        var target = f.segment("TWO-LOTS", f.owner, f.warehouse, f.product, "10");
        var first = f.report(target, "REPORT-TWO-LOTS", "7", "3", true);
        UUID secondBatch = UUID.randomUUID();
        UUID secondLot = f.db.queryForObject("SELECT fn_production_output_lot_id(:report,:batch,'WAREHOUSE',NULL)",
                Map.of("report", first.report(), "batch", secondBatch), UUID.class);
        f.insert("production_daily_report_items", "report_id", first.report(), "execution_segment_id", target.segment(),
                "goods_id", f.product, "unit_id", f.productUnit, "unit_rate", BigDecimal.ONE, "qty", new BigDecimal("4"),
                "output_batch_id", secondBatch, "output_lot_id", secondLot, "destination", "WAREHOUSE", "is_deleted", false);
        // Another product shares this report and has its own real consumption.
        // A report-level settlement cannot associate its material with either
        // of the first product's output lots.
        UUID otherProduct = f.goods("OTHER-PRODUCT", "Unrelated output", f.productUnit);
        UUID otherMaterial = f.goods("OTHER-MATERIAL", "Unrelated raw material", f.materialUnit);
        var other = f.segment("UNRELATED-REPORT-PRODUCT", f.owner, f.warehouse, otherProduct, "9");
        f.db.update("UPDATE production_material_demands SET goods_id=:goods WHERE id=:id", Map.of("goods", otherMaterial, "id", other.demand()));
        f.db.update("UPDATE stock_document_items SET goods_id=:goods WHERE id=:id", Map.of("goods", otherMaterial, "id", other.drawItem()));
        f.db.update("UPDATE stock_reservations SET goods_id=:goods WHERE id=:id", Map.of("goods", otherMaterial, "id", other.reservation()));
        UUID otherBatch = UUID.randomUUID();
        UUID otherLot = f.db.queryForObject("SELECT fn_production_output_lot_id(:report,:batch,'WAREHOUSE',NULL)",
                Map.of("report", first.report(), "batch", otherBatch), UUID.class);
        f.insert("production_daily_report_items", "report_id", first.report(), "execution_segment_id", other.segment(),
                "goods_id", otherProduct, "unit_id", f.productUnit, "unit_rate", BigDecimal.ONE, "qty", new BigDecimal("99"),
                "output_batch_id", otherBatch, "output_lot_id", otherLot, "destination", "WAREHOUSE", "is_deleted", false);
        f.insert("production_daily_report_material_usages", "report_id", first.report(), "line_no", 2, "plan_id", other.plan(),
                "demand_id", other.demand(), "material_execution_segment_id", other.segment(), "qty_base", new BigDecimal("5"));
        UUID otherEvent = f.insert("production_material_settlement_events", "plan_id", other.plan(),
                "daily_report_id", first.report(), "event_type", "POST");
        f.insert("production_material_settlement_postings", "event_id", otherEvent, "demand_id", other.demand(),
                "issue_posting_id", other.issue(), "settlement_type", "CONSUMED", "qty_base", new BigDecimal("5"));
        var whole = rows(trace("GOODS", f.material)).getFirst();
        assertThat(whole.consumedQty()).isEqualByComparingTo("3");
        assertThat(whole.reports()).singleElement().satisfies(report -> {
            assertThat(report.productQty()).isEqualByComparingTo("11");
            assertThat(report.batches()).extracting(batch -> batch.id()).containsExactlyInAnyOrder(first.lot(), secondLot);
        });
        assertThat(rows(query.trace("PRODUCTION_OUTPUT_LOT", first.lot(), "materials", null, null, 1, 50))).singleElement().satisfies(row -> {
            assertThat(row.consumedQty()).isNull();
            assertThat(row.reports()).singleElement().satisfies(report -> {
                assertThat(report.productQty()).isEqualByComparingTo("7");
                assertThat(report.batches()).singleElement().satisfies(batch -> assertThat(batch.id()).isEqualTo(first.lot()));
            });
        });
        assertThat(rows(query.trace("PRODUCTION_OUTPUT_LOT", otherLot, "materials", null, null, 1, 50))).singleElement().satisfies(row -> {
            assertThat(row.material().goodsId()).isEqualTo(otherMaterial);
            assertThat(row.product().goodsId()).isEqualTo(otherProduct);
            assertThat(row.consumedQty()).isNull();
            assertThat(row.reports()).singleElement().satisfies(report -> {
                assertThat(report.productQty()).isEqualByComparingTo("99");
                assertThat(report.batches()).singleElement().satisfies(batch -> assertThat(batch.id()).isEqualTo(otherLot));
            });
        });
    }

    @Test void subcontractSourcesRetainTheFrozenBomEstimateAndExactIssuedDocumentIdentity() {
        UUID order = subcontractOrder("SUB-ESTIMATE", f.owner, f.warehouse, "10");
        UUID orderItem = f.db.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=:order", Map.of("order", order), UUID.class);
        UUID planItem = f.insert("subcontract_material_plan_items", "order_item_id", orderItem, "goods_id", f.material,
                "unit_id", f.materialUnit, "bom_unit_qty", new BigDecimal("2"), "is_deleted", false);
        UUID issue = f.insert("subcontract_material_issues", "bill_no", "ISSUE-ESTIMATE", "bill_date", DAY,
                "maker_id", f.owner, "warehouse_id", f.warehouse, "status", 1, "is_deleted", false);
        UUID issueItem = f.insert("subcontract_material_issue_items", "issue_id", issue, "order_item_id", orderItem,
                "plan_item_id", planItem, "goods_id", f.material, "parent_goods_id", f.product,
                "parent_goods_code_snapshot", "PRODUCT-TRACE", "parent_goods_name_snapshot", "Frozen finished product",
                "unit_id", f.materialUnit, "unit_rate", BigDecimal.ONE, "qty", new BigDecimal("8"),
                "at_supplier_qty", new BigDecimal("8"), "consumed_qty", new BigDecimal("6"), "frozen_unit_qty", new BigDecimal("2"),
                "returned_qty", BigDecimal.ZERO, "wasted_qty", BigDecimal.ZERO, "is_deleted", false);
        UUID receipt = f.insert("subcontract_receipts", "bill_no", "RECEIPT-ESTIMATE", "bill_date", DAY,
                "maker_id", f.owner, "warehouse_id", f.warehouse, "status", 1, "is_deleted", false);
        UUID receiptItem = f.insert("subcontract_receipt_items", "receipt_id", receipt, "order_item_id", orderItem,
                "goods_id", f.product, "unit_id", f.productUnit, "unit_rate", BigDecimal.ONE, "qty", new BigDecimal("3"), "is_deleted", false);
        f.insert("subcontract_receipt_material_consumptions", "receipt_item_id", receiptItem, "issue_item_id", issueItem,
                "qty_doc", new BigDecimal("6"), "qty_base", new BigDecimal("6"), "consumption_basis", "FROZEN_BOM_ESTIMATE");
        var result = trace("SUBCONTRACT_ORDER", order);
        assertThat(result.sources()).allSatisfy(source -> assertThat(source.docType()).isNull());
        assertThat(result.sources()).anySatisfy(source -> {
            assertThat(source.id()).isEqualTo(issue);
            assertThat(source.basis()).isEqualTo("ACTUAL_MATERIAL_ISSUE");
            assertThat(source.qty()).isEqualByComparingTo("8");
            assertThat(source.goods().goodsId()).isEqualTo(f.material);
            assertThat(source.relatedProduct().goodsId()).isEqualTo(f.product);
            assertThat(source.relatedOrderId()).isEqualTo(order);
            assertThat(source.relatedOrderCode()).isEqualTo("SUB-ESTIMATE");
        }).anySatisfy(source -> {
            assertThat(source.basis()).isEqualTo("FROZEN_BOM_ESTIMATE");
            assertThat(source.qty()).isEqualByComparingTo("6");
            assertThat(source.goods().goodsId()).isEqualTo(f.material);
            assertThat(source.relatedProduct().goodsId()).isEqualTo(f.product);
            assertThat(source.relatedOrderId()).isEqualTo(order);
        });
        var productMaterials = query.trace("GOODS", f.product, "materials", null, null, 1, 50);
        assertThat(productMaterials.sources().stream()
                .filter(source -> Set.of("ACTUAL_MATERIAL_ISSUE", "FROZEN_BOM_ESTIMATE").contains(source.basis())))
                .hasSize(2).allSatisfy(source -> {
                    assertThat(source.goods().goodsId()).isEqualTo(f.material);
                    assertThat(source.relatedProduct().goodsId()).isEqualTo(f.product);
                    assertThat(source.relatedOrderId()).isEqualTo(order);
                }).anySatisfy(source -> {
                    assertThat(source.basis()).isEqualTo("ACTUAL_MATERIAL_ISSUE");
                    assertThat(source.qty()).isEqualByComparingTo("8");
                }).anySatisfy(source -> {
                    assertThat(source.basis()).isEqualTo("FROZEN_BOM_ESTIMATE");
                    assertThat(source.qty()).isEqualByComparingTo("6");
                });
        f.db.update("UPDATE subcontract_material_issue_items SET parent_goods_id=:goods WHERE id=:id",
                Map.of("goods", f.material, "id", issueItem));
        assertThat(trace("SUBCONTRACT_ORDER", order).sources().stream()
                .filter(source -> Set.of("ACTUAL_MATERIAL_ISSUE", "FROZEN_BOM_ESTIMATE").contains(source.basis())))
                .hasSize(2).allSatisfy(source -> {
                    assertThat(source.relatedProduct()).isNull();
                    assertThat(source.relatedOrderId()).isNull(); assertThat(source.relatedOrderCode()).isNull();
                });
        f.db.update("UPDATE subcontract_material_issue_items SET parent_goods_id=:goods WHERE id=:id",
                Map.of("goods", f.product, "id", issueItem));
        login(FULL.stream().filter(permission -> !permission.equals("subcontract_order:view")).collect(java.util.stream.Collectors.toSet()));
        var issueOnly = trace("GOODS", f.material);
        assertThat(issueOnly.sources()).hasSize(2).allSatisfy(source -> {
            assertThat(source.goods().goodsId()).isEqualTo(f.material);
            assertThat(source.relatedProduct()).isNull();
            assertThat(source.relatedOrderId()).isNull(); assertThat(source.relatedOrderCode()).isNull();
        });
        var maskedProductMaterials = query.trace("GOODS", f.product, "materials", null, null, 1, 50);
        assertThat(maskedProductMaterials.sources())
                .noneMatch(source -> Set.of("ACTUAL_MATERIAL_ISSUE", "FROZEN_BOM_ESTIMATE").contains(source.basis()))
                .anySatisfy(source -> {
                    assertThat(source.id()).isEqualTo(receipt);
                    assertThat(source.basis()).isEqualTo("RECEIPT_QUANTITY");
                    assertThat(source.goods().goodsId()).isEqualTo(f.product);
                });
        f.db.update("UPDATE subcontract_material_issues SET maker_id=NULL,owner_pool='WAREHOUSE_SUBCONTRACT_OUTBOUND' WHERE id=:id",
                Map.of("id", issue));
        assertThat(trace("GOODS", f.material).sources()).isEmpty();
        var poolPermissions = new java.util.HashSet<>(FULL);
        poolPermissions.remove("subcontract_order:view"); poolPermissions.add("subcontract_outbound:view");
        login(poolPermissions);
        assertThat(trace("GOODS", f.material).sources()).hasSize(2).allSatisfy(source -> {
            assertThat(source.goods().goodsId()).isEqualTo(f.material);
            assertThat(source.relatedProduct()).isNull();
            assertThat(source.relatedOrderId()).isNull(); assertThat(source.relatedOrderCode()).isNull();
        });
    }

    @Test void realWarehouseTaskCapabilityStillIntersectsItsExactWarehousePredicateBeforePaging() {
        f.segment("OUTSIDE", f.otherOwner, f.otherWarehouse, f.product, "3");
        var allowed = f.segment("INSIDE", f.otherOwner, f.warehouse, f.product, "4");
        warehouseParticipant = true;
        warehouseScope = new WarehouseTaskScope(true, List.of(f.warehouse), false);
        login(Set.of("production_where_used:view", "stock:view", "stock_doc:view"));
        var result = query.trace("GOODS", f.material, "usage", null, null, 1, 1);
        assertThat(result.total()).isEqualTo(1);
        assertThat(rows(result)).singleElement().satisfies(row -> assertThat(row.planId()).isEqualTo(allowed.plan()));
        login(Set.of("stock:view", "stock_doc:view"));
        var legacy = canonical.query(f.material, "usage", 1, 1);
        assertThat(legacy.getTotal()).isEqualTo(result.total());
        assertThat(legacy.getItems()).singleElement().satisfies(row -> assertThat(row.planId()).isEqualTo(allowed.plan()));
        forbidden(() -> trace("GOODS", f.material));
    }

    @Test void reportDateFiltersCannotUseUnreadableDraftOrCancelledReportsToRevealAResultCount() {
        var target = f.segment("DATE-SCOPE", f.owner, f.warehouse, f.product, "5");
        var report = f.report(target, "PRIVATE-DATE-REPORT", "2", "1", true);
        login(Set.of("production_where_used:view", "stock:view", "production_plan:view", "stock_doc:view"));
        assertThat(query.trace("GOODS", f.material, "usage", DAY, DAY, 1, 1).total()).isZero();
        login(FULL);
        f.db.update("UPDATE production_daily_reports SET maker_id=:owner WHERE id=:id", Map.of("owner", f.otherOwner, "id", report.report()));
        assertThat(query.trace("GOODS", f.material, "usage", DAY, DAY, 1, 1).total()).isZero();
        var reportReviewer = new java.util.HashSet<>(FULL); reportReviewer.add("production_daily_report:approve");
        login(reportReviewer);
        assertThat(query.trace("GOODS", f.material, "usage", DAY, DAY, 1, 1).total()).isEqualTo(1);
        login(FULL);
        f.db.update("UPDATE production_daily_reports SET maker_id=:owner,status=0 WHERE id=:id", Map.of("owner", f.owner, "id", report.report()));
        assertThat(query.trace("GOODS", f.material, "usage", DAY, DAY, 1, 1).total()).isZero();
        f.db.update("UPDATE production_daily_reports SET status=1,is_canceled=true WHERE id=:id", Map.of("id", report.report()));
        assertThat(query.trace("GOODS", f.material, "usage", DAY, DAY, 1, 1).total()).isZero();
        f.db.update("UPDATE production_daily_reports SET is_canceled=false WHERE id=:id", Map.of("id", report.report()));
        var dated = query.trace("GOODS", f.material, "usage", DAY, DAY, 1, 1);
        assertThat(dated.total()).isEqualTo(1);
        assertThat(rows(dated)).singleElement().satisfies(row -> {
            assertThat(row.issuedQty()).isNull(); assertThat(row.returnedQty()).isNull();
            assertThat(row.consumedQty()).isNull(); assertThat(row.lossQty()).isNull();
        });
        assertThat(query.trace("GOODS", f.material, "usage", DAY.plusDays(1), DAY.plusDays(1), 1, 1).total()).isZero();
    }

    @Test void realWorkshopAssignmentScopeAllowsOnlyTheActiveEmployeesWorkshopBeforeCountAndPaging() {
        var assigned = f.segment("ASSIGNED", f.otherOwner, f.warehouse, f.product, "4");
        var hidden = f.segment("OTHER-WORKSHOP", f.otherOwner, f.warehouse, f.product, "5");
        UUID otherWorkshop = f.insert("departments", "name", "Other workshop", "is_deleted", false);
        f.db.update("UPDATE production_execution_segments SET workshop_department_id=:department WHERE id=:id",
                Map.of("department", otherWorkshop, "id", hidden.segment()));
        f.db.update("UPDATE employees SET department_id=:department,status='active' WHERE id=:id",
                Map.of("department", f.workshop, "id", f.owner));
        // An ordinary worker's OTHER warehouse-task fallback cannot narrow a
        // separately authorized assigned production task in a keeper warehouse.
        warehouseScope = new WarehouseTaskScope(true, List.of(f.otherWarehouse), false);
        login(Set.of("production_where_used:view", "stock:view", "production_execution:view"));
        var result = query.trace("GOODS", f.material, "usage", null, null, 1, 1);
        assertThat(result.total()).isEqualTo(1);
        assertThat(rows(result)).singleElement().satisfies(row -> {
            assertThat(row.segmentId()).isEqualTo(assigned.segment());
            assertThat(row.drawDocuments()).isEmpty();
        });
        login(Set.of("stock:view", "production_execution:view"));
        assertThat(canonical.query(f.material, "usage", 1, 1).getTotal()).isEqualTo(result.total());
        f.db.update("UPDATE employees SET status='terminated' WHERE id=:id", Map.of("id", f.owner));
        assertThat(canonical.query(f.material, "usage", 1, 1).getTotal()).isZero();
        login(Set.of("production_where_used:view", "stock:view", "production_execution:view"));
        assertThat(query.trace("GOODS", f.material, "usage", null, null, 1, 1).total()).isZero();
    }

    @Test void quantitiesRemainExactPlainDecimalJsonTextWithTheGoodsBasicUnit() throws Exception {
        String exact = "12345678901234.0001";
        f.segment("EXACT", f.owner, f.warehouse, f.product, exact);
        var result = trace("GOODS", f.material);
        var json = new ObjectMapper().findAndRegisterModules().valueToTree(result);
        assertThat(json.path("items").get(0).path("issuedQty").isTextual()).isTrue();
        assertThat(json.path("items").get(0).path("issuedQty").asText()).isEqualTo(exact);
        assertThat(rows(result).getFirst().material().unitName()).isEqualTo("千克");
    }

    @Test void mixedWarehouseDocumentRemainsDiscoverableButNeverIncludesItsForbiddenItemOrQuantities() throws Exception {
        var visible = f.segment("MIXED-DOC", f.owner, f.warehouse, f.product, "4");
        var hidden = f.segment("HIDDEN-LINE", f.owner, f.otherWarehouse, f.product, "9876");
        UUID hiddenMaterial = f.goods("SECRET-MATERIAL", "Forbidden material", f.materialUnit);
        f.db.update("UPDATE stock_document_items SET doc_id=:document,warehouse_id=:warehouse,goods_id=:goods WHERE id=:item",
                Map.of("document", visible.draw(), "warehouse", f.otherWarehouse, "goods", hiddenMaterial, "item", hidden.drawItem()));
        f.db.update("UPDATE stock_document_items SET warehouse_id=:warehouse WHERE id=:item", Map.of("warehouse", f.warehouse, "item", visible.drawItem()));
        f.db.update("UPDATE production_material_stock_events SET stock_document_id=:document WHERE stock_document_id=:old",
                Map.of("document", visible.draw(), "old", hidden.draw()));
        f.db.update("UPDATE production_material_demands SET goods_id=:goods WHERE id=:id", Map.of("goods", hiddenMaterial, "id", hidden.demand()));
        warehouseParticipant = true;
        warehouseScope = new WarehouseTaskScope(true, List.of(f.warehouse), false);
        var candidates = query.subjects("document", "DRAW-MIXED-DOC", true, 1, 1);
        assertThat(candidates.getTotal()).isEqualTo(1);
        assertThat(candidates.getItems()).singleElement().satisfies(subject -> assertThat(subject.id()).isEqualTo(visible.draw()));
        var result = query.trace("STOCK_DOC", visible.draw(), "usage", null, null, 1, 1);
        assertThat(result.total()).isEqualTo(1);
        assertThat(rows(result)).singleElement().satisfies(row -> {
            assertThat(row.material().goodsId()).isEqualTo(f.material);
            assertThat(row.issuedQty()).isNull(); assertThat(row.consumedQty()).isNull();
        });
        assertThat(result.sources()).singleElement().satisfies(source -> {
            assertThat(source.itemId()).isEqualTo(visible.drawItem());
            assertThat(source.docType()).isEqualTo("DRAW");
            assertThat(source.goods().goodsId()).isEqualTo(f.material);
            assertThat(source.qty()).isEqualByComparingTo("4");
        });
        String json = new ObjectMapper().findAndRegisterModules().writeValueAsString(result);
        // 编号/名称是受控字符串, 子串检查安全; 数量改按「任意字段的完整值」判定——
        // 响应里大量随机 UUID, 裸子串检查会被 UUID 中恰含 "9876" 的片段误伤(2026-10-30 CI 实发)。
        assertThat(json).doesNotContain("SECRET-MATERIAL", "Forbidden material", "DRAW-HIDDEN-LINE");
        var tree = new ObjectMapper().readTree(json);
        Set<String> scalarValues = new HashSet<>();
        collectScalarValues(tree, scalarValues);
        assertThat(scalarValues).as("任何字段都不携带被隐藏行的数量").doesNotContain("9876");
        assertThat(query.trace("GOODS", hiddenMaterial, "usage", null, null, 1, 1).total()).isZero();
    }

    private static void collectScalarValues(JsonNode node, Set<String> into) {
        if (node.isValueNode()) {
            into.add(node.asText());
        } else {
            node.forEach(child -> collectScalarValues(child, into));
        }
    }

    @Test void explicitZeroApprovedMaterialUsageRemainsKnownZeroWithoutFabricatingASettlementPosting() {
        var target = f.segment("ZERO-USE", f.owner, f.warehouse, f.product, "5");
        var report = f.report(target, "REPORT-ZERO-USE", "2", "0", true);
        assertThat(report.settlement()).isNull();
        assertThat(rows(trace("GOODS", f.material))).singleElement().satisfies(row -> assertThat(row.consumedQty()).isZero());
        assertThat(rows(query.trace("PRODUCTION_REPORT", report.report(), "materials", null, null, 1, 50)))
                .singleElement().satisfies(row -> assertThat(row.consumedQty()).isNull());
    }

    private Result trace(String type, UUID id) { return query.trace(type, id, "usage", null, null, 1, 50); }
    private static List<TraceRow> rows(Result result) {
        List<TraceRow> rows = new java.util.ArrayList<>();
        for (var item : result.items()) rows.add((TraceRow) item);
        return List.copyOf(rows);
    }
    private UUID subcontractOrder(String code, UUID owner, UUID warehouse, String quantity) {
        UUID order = f.insert("subcontract_orders", "bill_no", code, "bill_date", DAY, "maker_id", owner,
                "warehouse_id", warehouse, "status", 1, "is_deleted", false);
        f.insert("subcontract_order_items", "order_id", order, "goods_id", f.product, "unit_id", f.productUnit,
                "goods_code_snapshot", "PRODUCT-TRACE", "goods_name_snapshot", "Frozen finished product",
                "unit_rate", BigDecimal.ONE, "qty", new BigDecimal(quantity), "is_deleted", false);
        return order;
    }
    private UUID draftPlan(String code) {
        UUID plan = f.insert("production_plans", "bill_no", code, "bill_date", DAY, "maker_id", f.owner,
                "status", 0, "is_deleted", false, "is_canceled", false, "is_stopped", false, "is_closed", false);
        f.insert("production_plan_items", "plan_id", plan, "goods_id", f.product, "unit_id", f.productUnit,
                "unit_rate", BigDecimal.ONE, "qty", new BigDecimal("2"), "is_deleted", false);
        return plan;
    }
    private void login(Set<String> permissions) {
        var actor = new AuthUser(UUID.randomUUID(), f.owner, "trace-query-test", permissions, false, true, false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(actor, "unused", actor.getAuthorities()));
    }
    private static void forbidden(org.assertj.core.api.ThrowableAssert.ThrowingCallable read) {
        assertThatThrownBy(read).isInstanceOfSatisfying(ApiException.class, failure -> assertThat(failure.getCode()).isEqualTo(ErrorCode.FORBIDDEN));
    }
    private static void notFound(org.assertj.core.api.ThrowableAssert.ThrowingCallable read) {
        assertThatThrownBy(read).isInstanceOfSatisfying(ApiException.class, failure -> assertThat(failure.getCode()).isEqualTo(ErrorCode.NOT_FOUND));
    }
}
