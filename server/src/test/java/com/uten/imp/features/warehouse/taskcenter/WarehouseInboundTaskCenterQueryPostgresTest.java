package com.uten.imp.features.warehouse.taskcenter;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.stock.StockDocAccessPolicy;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalRegistrationService;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedInboundTaskService;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInPermissions;
import com.uten.imp.features.warehouse.taskcenter.WarehouseTaskCenterContracts.Filter;
import com.uten.imp.features.warehouse.taskcenter.WarehouseTaskCenterContracts.Row;
import com.uten.imp.features.warehouse.taskcenter.WarehouseTaskCenterContracts.TaskView;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;
import com.uten.imp.security.OwnerVisibility.OwnerScope;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.support.MigratedProjectionSchema;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;

import java.sql.Connection;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.doCallRealMethod;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** SQL read-model oracles use real migrated column shapes, never fabricated business-command success. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class WarehouseInboundTaskCenterQueryPostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private Connection connection;
    private NamedParameterJdbcTemplate jdbc;
    private final ObjectMapper mapper=new ObjectMapper().findAndRegisterModules();

    @BeforeAll static void baseline() throws Exception { database=MigratedSchemaBaseline.openDatabase("warehouse_inbound_query"); }
    @AfterAll static void closeBaseline() throws Exception { if(database!=null) database.close(); }

    @BeforeEach void projection() throws Exception {
        connection=database.openConnection();
        connection.setAutoCommit(false);
        try(var statement=connection.createStatement()) {
            statement.execute("CREATE SCHEMA inbound_query_oracle");
            statement.execute("SET LOCAL search_path=inbound_query_oracle,public");
            statement.execute("SET LOCAL jit=off");
        }
        // Private rollback-only projection facts retain real types. Business FK/trigger proofs belong to command tests.
        MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(connection,
                "purchase_receipts","purchase_receipt_items","subcontract_receipts","subcontract_receipt_items",
                "stock_documents","stock_document_items","production_daily_reports","production_daily_report_items",
                "production_finished_arrival_registrations","production_finished_arrival_registration_items",
                "production_finished_arrival_registration_reversals","production_fqc_inspections",
                "production_fqc_inspection_sheets","production_fqc_inspection_sheet_items",
                "production_finished_in_confirmations","procurement_arrival_exceptions","goods",
                "inbound_expectations","inbound_expectation_items","production_fqc_legacy_exemptions",
                "procurement_inspection_items","procurement_inspection_events","procurement_iqc_stock_in_batch_items","procurement_iqc_stock_in_batches",
                "procurement_iqc_rejection_cases","production_material_return_requests");
        // PostgreSQL views bind source relation OIDs. Rebind the actual migrated
        // predicate to these rollback-only facts instead of accidentally reading
        // public reports when exercising a populated FINISHED_REGISTER detail.
        try(var statement=connection.createStatement();var rows=statement.executeQuery(
                "SELECT pg_get_viewdef('public.v_production_report_items_pending_registration'::regclass,true)")) {
            rows.next();
            String definition=rows.getString(1).replace("public.","");
            try(var create=connection.createStatement()) {
                create.execute("CREATE VIEW v_production_report_items_pending_registration AS "+definition);
            }
        }
        jdbc=new NamedParameterJdbcTemplate(new SingleConnectionDataSource(connection,true));
    }
    @AfterEach void rollback() throws Exception { if(connection!=null) { connection.rollback(); connection.close(); } }

    @Test void everyRealSourceProjectionParsesWithNullFiltersAgainstMigratedHead() {
        var service=service(Set.of("stock_doc:view","warehouse_inbound:view","warehouse_iqc_stock_in:view",
                "warehouse_purchase_receipt_history:view","warehouse_subcontract_receipt_history:view"),WarehouseTaskScope.ALL,true);
        var page=service.list(new Filter("ALL","","no-such-physical-task-3c46a94",null,null,null,null,1,30));
        assertThat(page.items()).isEmpty();
        assertThat(page.total()).isZero();
        assertThat(page.facets()).containsKeys("status","billNo");
    }

    @Test void searchRanksGoodsNamesBeforeBillsAndPagingAndKeepsCountsFacetsAndScope() {
        UUID warehouse=UUID.randomUUID(), outside=UUID.randomUUID();
        UUID near=searchStock("Z-NEAR","X-METRIC","Metric Screw extra","2026-10-15",warehouse);
        UUID name=searchStock("Y-NAME","CODE-NAME","Metric Screw","2026-10-10",warehouse);
        UUID bill=searchStock("Metric Screw","CODE-BILL","other","2026-10-01",warehouse);
        searchStock("Metric Screw","HIDDEN","Metric Screw","2026-10-16",outside);
        var service=service(Set.of("stock_doc:view"),new WarehouseTaskScope(true,List.of(warehouse),false),false);
        var first=service.list(new Filter("OTHER","","Metric Screw",null,null,null,null,1,1));
        assertThat(first.items()).extracting(Row::id).containsExactly(name);
        assertThat(first.total()).isEqualTo(3);
        assertThat(first.totalPages()).isEqualTo(3);
        assertThat(first.facets().get("status").getFirst().count()).isEqualTo(3);
        assertThat(service.list(new Filter("OTHER","","Metric Screw",null,null,null,null,2,1)).items())
                .extracting(Row::id).containsExactly(near);
        assertThat(service.list(new Filter("OTHER","","Metric Screw",null,null,null,null,3,1)).items())
                .extracting(Row::id).containsExactly(bill);
        assertThat(service.list(new Filter("OTHER","","Y-NAME Screw",null,null,null,null,1,20)).items())
                .extracting(Row::id).containsExactly(name);
        UUID literal=searchStock("LITERAL","A%_B","special","2026-10-01",warehouse);
        searchStock("WILDCARD","AxYB","special","2026-10-16",warehouse);
        assertThat(service.list(new Filter("OTHER","","A%_B",null,null,null,null,1,20)).items())
                .extracting(Row::id).containsExactly(literal);
    }

    @Test void goodsLinesAreExpandedBeforePagingAndSearchAndKeepSameDocumentItemsDistinct() {
        UUID document=UUID.randomUUID(),goods=UUID.randomUUID(),first=UUID.randomUUID(),second=UUID.randomUUID();
        stock(document,"OTHER_IN","ITEM-ROWS","2026-10-12",null);
        execute("INSERT INTO goods(id,code,name,spec) VALUES(:id,'SAME-CODE','Current goods','M10')","id",goods);
        execute("INSERT INTO stock_document_items(id,doc_id,line_no,goods_id,goods_name_snapshot,qty,weight,is_deleted)"
                +" VALUES(:id,:document,1,:goods,'First snapshot',2.5000,1.2500,FALSE)",
                "id",first,"document",document,"goods",goods);
        execute("INSERT INTO stock_document_items(id,doc_id,line_no,goods_id,goods_name_snapshot,qty,is_deleted)"
                +" VALUES(:id,:document,2,:goods,'Second snapshot',4.5000,FALSE)",
                "id",second,"document",document,"goods",goods);
        var service=service(Set.of("stock_doc:view"),WarehouseTaskScope.ALL,false);
        var firstPage=service.list(filter("OTHER","",1,1));
        var secondPage=service.list(filter("OTHER","",2,1));
        assertThat(firstPage.total()).isEqualTo(2);
        assertThat(firstPage.totalPages()).isEqualTo(2);
        assertThat(firstPage.facets().get("status")).singleElement().satisfies(facet->assertThat(facet.count()).isEqualTo(2));
        assertThat(firstPage.items().getFirst().rowKey()).isNotEqualTo(secondPage.items().getFirst().rowKey());
        assertThat(firstPage.items().getFirst().id()).isEqualTo(document);
        assertThat(secondPage.items().getFirst().id()).isEqualTo(document);
        var search=service.list(new Filter("OTHER","","First snapshot",null,null,null,null,1,20));
        assertThat(search.total()).isEqualTo(1);
        assertThat(search.items()).singleElement().satisfies(row->{
            assertThat(row.line().itemId()).isEqualTo(first);
            assertThat(row.line().goodsName()).isEqualTo("First snapshot");
            assertThat(row.line().specification()).isEqualTo("M10");
            assertThat(row.line().quantity()).isEqualByComparingTo("2.5000");
            assertThat(row.line().weight()).isEqualByComparingTo("1.2500");
            assertThat(service.detail(row.rowKey(),null).get("total")).isEqualTo(1L);
        });
        assertThat(service.detail("OTHER:STOCK_DOCUMENT:"+document,null).get("total")).isEqualTo(2L);
    }

    @Test void sameDocumentOtherWarehouseItemsCannotLeakThroughRowsSearchFacetsOrDetails() {
        UUID document=UUID.randomUUID(),warehouse=UUID.randomUUID(),outside=UUID.randomUUID();
        UUID shown=UUID.randomUUID(),hidden=UUID.randomUUID();
        stock(document,"OTHER_IN","MIXED-WAREHOUSES","2026-10-12",null);
        execute("UPDATE stock_documents SET warehouse_id=:warehouse WHERE id=:id","warehouse",warehouse,"id",document);
        execute("INSERT INTO stock_document_items(id,doc_id,line_no,warehouse_id,goods_name_snapshot,qty,is_deleted)"
                +" VALUES(:id,:document,1,:warehouse,'Visible physical item',2,FALSE)",
                "id",shown,"document",document,"warehouse",warehouse);
        execute("INSERT INTO stock_document_items(id,doc_id,line_no,warehouse_id,goods_name_snapshot,qty,is_deleted)"
                +" VALUES(:id,:document,2,:warehouse,'Outside physical item',3,FALSE)",
                "id",hidden,"document",document,"warehouse",outside);
        var service=service(Set.of("stock_doc:view"),new WarehouseTaskScope(true,List.of(warehouse),false),false);
        var page=service.list(filter("OTHER","",1,20));
        assertThat(page.total()).isEqualTo(1);
        assertThat(page.items()).singleElement().satisfies(row->assertThat(row.line().itemId()).isEqualTo(shown));
        assertThat(page.facets().get("billNo")).singleElement().satisfies(facet->assertThat(facet.count()).isEqualTo(1));
        assertThat(service.list(new Filter("OTHER","","Outside",null,null,null,null,1,20)).total()).isZero();
        assertThat(service.detail("OTHER:STOCK_DOCUMENT:"+document,null).get("total")).isEqualTo(1L);
        assertThatThrownBy(()->service.detail("OTHER:STOCK_DOCUMENT:"+document+":"+hidden,null)).isInstanceOf(ApiException.class);
        var otherScope=service(Set.of("stock_doc:view"),new WarehouseTaskScope(true,List.of(outside),false),false);
        assertThat(otherScope.list(filter("OTHER","",1,20)).items()).singleElement()
                .satisfies(row->assertThat(row.line().itemId()).isEqualTo(hidden));
        execute("UPDATE stock_document_items SET is_deleted=TRUE WHERE id=:id","id",shown);
        assertThat(service.list(filter("OTHER","",1,20)).total()).isZero();
        assertThat(otherScope.list(filter("OTHER","",1,20)).total()).isEqualTo(1);
    }

    @Test void finishedRegistrationScopesSharesBeforeSummingAndRetainsEachPhysicalRowQuantity() {
        UUID report=UUID.randomUUID(),warehouse=UUID.randomUUID(),outside=UUID.randomUUID();
        UUID goods=UUID.randomUUID(),hiddenGoods=UUID.randomUUID(),lot=UUID.randomUUID();
        UUID normal=UUID.randomUUID(),publicShare=UUID.randomUUID(),surplus=UUID.randomUUID(),hidden=UUID.randomUUID(),workshop=UUID.randomUUID();
        execute("INSERT INTO goods(id,code,name,owning_warehouse_id) VALUES(:id,'VISIBLE-FINISHED','本仓成品',:warehouse)",
                "id",goods,"warehouse",warehouse);
        execute("INSERT INTO goods(id,code,name,owning_warehouse_id) VALUES(:id,'HIDDEN-FINISHED','别仓成品',:warehouse)",
                "id",hiddenGoods,"warehouse",outside);
        report(report,"TWO-WAREHOUSE-REPORT");
        reportItem(normal,report,goods,100);
        reportItem(publicShare,report,goods,20);
        reportItem(surplus,report,goods,10);
        reportItem(hidden,report,hiddenGoods,200);
        reportItem(workshop,report,goods,300);
        execute("UPDATE production_daily_report_items SET destination='WORKSHOP' WHERE id=:id","id",workshop);
        execute("UPDATE production_daily_report_items SET output_lot_id=:lot,"
                +" is_public_output=(id<>:normal),is_actual_surplus=(id=:surplus) WHERE id IN(:normal,:public,:surplus)",
                "lot",lot,"normal",normal,"public",publicShare,"surplus",surplus);

        var scope=new WarehouseTaskScope(true,List.of(warehouse),false);
        var service=service(Set.of("stock_doc:view"),scope,true);
        var page=service.list(new Filter("FINISHED","","",null,null,null,warehouse,1,20));
        assertThat(page.total()).isEqualTo(3);
        assertThat(taskRowCounts().finishedInbound(scope)).isEqualTo(page.total());
        assertThat(taskRowCounts().finishedInbound(WarehouseTaskScope.ALL)).isEqualTo(4);
        assertThat(page.items()).extracting(row->row.line().itemId()).containsExactlyInAnyOrder(normal,publicShare,surplus);
        assertThat(page.facets().get("status")).singleElement().satisfies(facet->assertThat(facet.count()).isEqualTo(3));
        assertThat(page.facets().get("billNo")).singleElement().satisfies(facet->assertThat(facet.count()).isEqualTo(3));
        assertThat(service.list(new Filter("FINISHED","","别仓成品",null,null,null,warehouse,1,20)).total()).isZero();
        assertThat(service.detail("FINISHED:FINISHED_REGISTER:"+report,warehouse).get("total")).isEqualTo(3L);
        assertThatThrownBy(()->service.detail("FINISHED:FINISHED_REGISTER:"+report+":"+hidden,warehouse))
                .isInstanceOf(ApiException.class);
        assertThat(page.items()).allSatisfy(row->{
            assertThat(new java.math.BigDecimal(row.actionData().get("pendingQty").toString()))
                    .isEqualByComparingTo(row.line().quantity());
            assertThat(new java.math.BigDecimal(row.actionData().get("publicQty").toString()))
                    .isEqualByComparingTo(row.line().itemId().equals(publicShare)?"20":"0");
            assertThat(new java.math.BigDecimal(row.actionData().get("actualSurplusQty").toString()))
                    .isEqualByComparingTo(row.line().itemId().equals(surplus)?"10":"0");
        });

        var access=mock(ProductionStockTaskAccessPolicy.class);
        when(access.canAccessWarehouseTasks()).thenReturn(true);
        var legacy=new ProductionFinishedInboundTaskService(executingEntityManager(),access);
        var scoped=legacy.list("","ARRIVAL_REGISTRATION",null,1,20,scope);
        assertThat(scoped.getTotal()).isEqualTo(1);
        assertThat(scoped.getItems()).singleElement().satisfies(task->{
            assertThat(task.goodsSummary()).contains("本仓成品").doesNotContain("别仓成品");
            assertThat(task.lineCount()).isEqualTo(1);
            assertThat(task.pendingQty()).isEqualByComparingTo("130");
            assertThat(task.publicQty()).isEqualByComparingTo("20");
            assertThat(task.actualSurplusQty()).isEqualByComparingTo("10");
        });
        assertThat(legacy.list("别仓成品","",null,1,20,scope).getTotal()).isZero();
        assertThat(legacy.facets("别仓成品","",null,scope).get("taskNo")).isEmpty();
        assertThat(legacy.countPending(scope)).isEqualTo(scoped.getTotal());
        assertThat(legacy.list("","ARRIVAL_REGISTRATION",null,1,20,WarehouseTaskScope.ALL).getItems())
                .singleElement().satisfies(task->{
                    assertThat(task.lineCount()).isEqualTo(2);
                    assertThat(task.pendingQty()).isEqualByComparingTo("330");
                });
        var outsideScope=new WarehouseTaskScope(true,List.of(outside),false);
        assertThat(legacy.list("","ARRIVAL_REGISTRATION",null,1,20,outsideScope).getItems())
                .singleElement().satisfies(task->{
                    assertThat(task.goodsSummary()).contains("别仓成品").doesNotContain("本仓成品");
                    assertThat(task.pendingQty()).isEqualByComparingTo("200");
                });
    }

    @Test void receiptItemLifecycleAndInspectionWarehouseDoNotMergeAcrossSiblingGoods() {
        for(String type:List.of("PURCHASE","SUBCONTRACT")) {
            String table=type.equals("PURCHASE")?"purchase_receipts":"subcontract_receipts";
            UUID receipt=UUID.randomUUID(),waiting=UUID.randomUUID(),finished=UUID.randomUUID();
            UUID warehouse=UUID.randomUUID(),outside=UUID.randomUUID();
            receipt(table,receipt,"LINE-"+type,"2026-10-12",warehouse);
            execute("UPDATE "+table+" SET status=1 WHERE id=:id","id",receipt);
            for(UUID item:List.of(waiting,finished)) {
                execute("INSERT INTO "+table.replace("receipts","receipt_items")+"(id,receipt_id,line_no,qty,goods_name_snapshot,is_deleted)"
                        +" VALUES(:id,:receipt,:line,5,:name,FALSE)","id",item,"receipt",receipt,
                        "line",item.equals(waiting)?1:2,"name",item.equals(waiting)?"Waiting goods":"Completed goods");
                execute("INSERT INTO procurement_inspection_items(id,receipt_type,receipt_id,receipt_item_id,warehouse_id,status,received_base_qty,"
                        +" passed_base_qty,failed_base_qty,warehouse_stocked_base_qty) VALUES(:id,:type,:receipt,:item,:warehouse,:status,5,:passed,0,:passed)",
                        "id",UUID.randomUUID(),"type",type,"receipt",receipt,"item",item,
                        "warehouse",item.equals(waiting)?warehouse:outside,"status",item.equals(waiting)?"PENDING":"RESOLVED",
                        "passed",item.equals(waiting)?0:5);
            }
            var all=service(Set.of("warehouse_purchase_receipt_history:view","warehouse_subcontract_receipt_history:view"),WarehouseTaskScope.ALL,false);
            assertThat(all.list(filter(type,"",1,20)).items()).singleElement().satisfies(row->{
                assertThat(row.line().itemId()).isEqualTo(waiting);
                assertThat(row.status()).isEqualTo(type+"_WAITING_INSPECTION");
            });
            assertThat(all.list(new Filter(type,"","",null,null,null,null,1,20,null,null,TaskView.HISTORY)).items())
                    .singleElement().satisfies(row->assertThat(row.line().itemId()).isEqualTo(finished));
            var scoped=service(Set.of("warehouse_purchase_receipt_history:view","warehouse_subcontract_receipt_history:view"),
                    new WarehouseTaskScope(true,List.of(warehouse),false),false);
            assertThat(scoped.list(new Filter(type,"","",null,null,null,null,1,20,null,null,TaskView.HISTORY)).total()).isZero();
            assertThat(scoped.detail(type+":"+type+"_RECEIPT:"+receipt,null).get("total")).isEqualTo(1L);
            var quality=new com.uten.imp.features.warehouse.inbound.WarehouseQualityResultService(
                    executingEntityManager(),mock(SecurityContextCurrentUser.class));
            var qualityPage=quality.list("",type,"",null,null,1,20,null,null,null,WarehouseTaskScope.ALL,TaskView.ACTIVE);
            assertThat(qualityPage.getTotal()).isEqualTo(1);
            assertThat(qualityPage.getItems()).singleElement().satisfies(row->{
                assertThat(row.line()).isNotNull();
                assertThat(row.workStatus()).isEqualTo("WAITING_INSPECTION");
                assertThat(row.line().quantity()).isEqualByComparingTo("5");
            });
            assertThat(quality.list("",type,"",null,null,1,20,null,null,null,
                    new WarehouseTaskScope(true,List.of(warehouse),false),TaskView.HISTORY).getTotal()).isZero();
        }
    }

    /** ADR-184: badge counts only leave zero for callers without real warehouse operations. */
    private void loginWarehouseOperator() {
        var actor=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"warehouse",Set.of(
                ProcurementIqcStockInPermissions.VIEW,ProcurementIqcStockInPermissions.CONFIRM,
                com.uten.imp.features.warehouse.inbound.WarehouseQualityResultPermissions.RETURN_VIEW,
                com.uten.imp.features.warehouse.inbound.WarehouseQualityResultPermissions.RECORD_RETURN),false,true,false);
        org.springframework.security.core.context.SecurityContextHolder.getContext().setAuthentication(
                new org.springframework.security.authentication.UsernamePasswordAuthenticationToken(actor,"",actor.getAuthorities()));
    }

    @Test void qualityResultGoodsSearchPagingAndCountsUseIndividualInspectionRows() {
        UUID receipt=UUID.randomUUID(),goods=UUID.randomUUID(),completedGoods=UUID.randomUUID();
        UUID warehouse=UUID.randomUUID(),outside=UUID.randomUUID();
        receipt("purchase_receipts",receipt,"QUALITY-ITEMS","2026-10-12",warehouse);
        execute("UPDATE purchase_receipts SET status=1 WHERE id=:id","id",receipt);
        execute("INSERT INTO goods(id,code,name,spec) VALUES(:id,'SAME-GOODS','Repeat goods','M8')","id",goods);
        execute("INSERT INTO goods(id,code,name,spec) VALUES(:id,'OTHER-GOODS','Completed outside goods','M10')","id",completedGoods);
        for(int i=0;i<2;i++) execute("INSERT INTO procurement_inspection_items(id,receipt_type,receipt_id,goods_id,status,"
                +" received_base_qty,passed_base_qty,failed_base_qty,warehouse_stocked_base_qty,warehouse_id)"
                +" VALUES(:id,'PURCHASE',:receipt,:goods,'PENDING',3,0,0,0,:warehouse)",
                "id",UUID.randomUUID(),"receipt",receipt,"goods",goods,"warehouse",warehouse);
        execute("INSERT INTO procurement_inspection_items(id,receipt_type,receipt_id,goods_id,status,"
                +" received_base_qty,passed_base_qty,failed_base_qty,warehouse_stocked_base_qty,warehouse_id)"
                +" VALUES(:id,'PURCHASE',:receipt,:goods,'RESOLVED',7,7,0,7,:warehouse)",
                "id",UUID.randomUUID(),"receipt",receipt,"goods",completedGoods,"warehouse",outside);
        var quality=new com.uten.imp.features.warehouse.inbound.WarehouseQualityResultService(
                executingEntityManager(),mock(SecurityContextCurrentUser.class));
        loginWarehouseOperator();
        try {
        var first=quality.list("Repeat goods","PURCHASE","",null,null,1,1,null,null,null,WarehouseTaskScope.ALL,TaskView.ACTIVE);
        var second=quality.list("Repeat goods","PURCHASE","",null,null,2,1,null,null,null,WarehouseTaskScope.ALL,TaskView.ACTIVE);
        assertThat(first.getTotal()).isEqualTo(2);
        assertThat(first.getTotalPages()).isEqualTo(2);
        assertThat(first.getItems().getFirst().line().key()).isNotEqualTo(second.getItems().getFirst().line().key());
        assertThat(first.getItems().getFirst().line().goodsName()).isEqualTo("Repeat goods");
        assertThat(first.getItems().getFirst().line().specification()).isEqualTo("M8");
        assertThat(quality.statusCounts("PURCHASE","Repeat goods",WarehouseTaskScope.ALL)).containsEntry("WAITING_INSPECTION",2L);
        assertThat(quality.statusCounts("PURCHASE","",WarehouseTaskScope.ALL))
                .containsEntry("WAITING_INSPECTION",2L).containsEntry("COMPLETED",1L);
        assertThat(quality.typeCounts(WarehouseTaskScope.ALL).inProgress()).containsEntry("PURCHASE",2L);
        assertThat(quality.facets("Repeat goods","PURCHASE","",null,null,WarehouseTaskScope.ALL).get("billNo"))
                .singleElement().satisfies(bucket->assertThat(((Number)bucket.get("count")).longValue()).isEqualTo(2));
        var history=quality.list("Completed outside goods","PURCHASE","",null,null,1,1,null,null,"QUALITY-ITEMS",
                WarehouseTaskScope.ALL,TaskView.HISTORY);
        assertThat(history.getTotal()).isEqualTo(1);
        assertThat(history.getItems()).singleElement().satisfies(row->{
            assertThat(row.workStatus()).isEqualTo("COMPLETED");
            assertThat(row.line().goodsName()).isEqualTo("Completed outside goods");
            assertThat(row.line().quantity()).isEqualByComparingTo("7");
            assertThat(row.warehouseId()).isEqualTo(outside);
        });
        var scoped=new WarehouseTaskScope(true,List.of(warehouse),false);
        assertThat(quality.list("","PURCHASE","",null,null,1,20,null,null,null,scoped,TaskView.ACTIVE).getTotal()).isEqualTo(2);
        assertThat(quality.list("Completed outside goods","PURCHASE","",null,null,1,20,null,null,null,scoped,TaskView.HISTORY).getTotal()).isZero();
        assertThat(quality.statusCounts("PURCHASE","",scoped)).containsEntry("WAITING_INSPECTION",2L).containsEntry("COMPLETED",0L);
        assertThat(quality.facets("Completed outside goods","PURCHASE","",null,null,scoped,TaskView.HISTORY).get("billNo")).isEmpty();
        } finally { org.springframework.security.core.context.SecurityContextHolder.clearContext(); }
    }

    @Test void qualityBadgesCountVisibleInspectionReleaseAndReturnRowsIndividually() {
        UUID receipt=UUID.randomUUID(),warehouseA=UUID.randomUUID(),warehouseB=UUID.randomUUID();
        UUID waiting=UUID.randomUUID(),released=UUID.randomUUID(),rejected=UUID.randomUUID();
        receipt("purchase_receipts",receipt,"SCOPED-QUALITY-BADGE","2026-10-12",warehouseA);
        execute("UPDATE purchase_receipts SET status=1 WHERE id=:id","id",receipt);
        execute("INSERT INTO procurement_inspection_items(id,receipt_type,receipt_id,warehouse_id,status,received_base_qty,"
                +" passed_base_qty,failed_base_qty,warehouse_stocked_base_qty) VALUES(:id,'PURCHASE',:receipt,:warehouse,'PENDING',5,0,0,0)",
                "id",waiting,"receipt",receipt,"warehouse",warehouseA);
        execute("INSERT INTO procurement_inspection_items(id,receipt_type,receipt_id,warehouse_id,status,received_base_qty,"
                +" passed_base_qty,failed_base_qty,warehouse_stocked_base_qty) VALUES(:id,'PURCHASE',:receipt,:warehouse,'RESOLVED',5,5,0,0)",
                "id",released,"receipt",receipt,"warehouse",warehouseB);
        execute("INSERT INTO procurement_inspection_events(id,inspection_item_id,action,requires_warehouse_stock_in,base_qty,occurred_at)"
                +" VALUES(:id,:inspection,'PASS',TRUE,5,now())","id",UUID.randomUUID(),"inspection",released);
        var quality=new com.uten.imp.features.warehouse.inbound.WarehouseQualityResultService(
                executingEntityManager(),mock(SecurityContextCurrentUser.class));
        var scopeA=new WarehouseTaskScope(true,List.of(warehouseA),false);
        var scopeB=new WarehouseTaskScope(true,List.of(warehouseB),false);
        loginWarehouseOperator();
        try {
        assertThat(quality.list("","PURCHASE","",null,null,1,20,null,null,null,scopeA,TaskView.ACTIVE).getItems())
                .singleElement().satisfies(row->assertThat(row.workStatus()).isEqualTo("WAITING_INSPECTION"));
        assertThat(quality.list("","PURCHASE","",null,null,1,20,null,null,null,scopeB,TaskView.ACTIVE).getItems())
                .singleElement().satisfies(row->assertThat(row.workStatus()).isEqualTo("ALL_PASSED"));
        assertThat(quality.typeCounts(scopeA).inProgress()).containsEntry("PURCHASE",1L);
        assertThat(quality.typeCounts(scopeA).actionable()).containsEntry("PURCHASE",0L);
        assertThat(quality.typeCounts(scopeB).inProgress()).containsEntry("PURCHASE",0L);
        assertThat(quality.typeCounts(scopeB).actionable()).containsEntry("PURCHASE",1L);
        assertThat(quality.typeCounts(WarehouseTaskScope.ALL).actionable()).containsEntry("PURCHASE",1L);

        // A sibling warehouse's rejection must not turn the waiting warehouse's badge red either.
        execute("UPDATE procurement_inspection_items SET warehouse_stocked_base_qty=5 WHERE id=:id","id",released);
        execute("INSERT INTO procurement_inspection_items(id,receipt_type,receipt_id,warehouse_id,status,received_base_qty,"
                +" passed_base_qty,failed_base_qty,warehouse_stocked_base_qty) VALUES(:id,'PURCHASE',:receipt,:warehouse,'RESOLVED',2,0,2,0)",
                "id",rejected,"receipt",receipt,"warehouse",warehouseB);
        execute("INSERT INTO procurement_iqc_rejection_cases(id,inspection_item_id,receipt_type,receipt_id,status,is_deleted)"
                +" VALUES(:id,:inspection,'PURCHASE',:receipt,'OPEN',FALSE)",
                "id",UUID.randomUUID(),"inspection",rejected,"receipt",receipt);
        assertThat(quality.typeCounts(scopeA).inProgress()).containsEntry("PURCHASE",1L);
        assertThat(quality.typeCounts(scopeA).actionable()).containsEntry("PURCHASE",0L);
        assertThat(quality.typeCounts(scopeB).actionable()).containsEntry("PURCHASE",1L);
        UUID secondReturn=UUID.randomUUID();
        execute("INSERT INTO procurement_inspection_items(id,receipt_type,receipt_id,warehouse_id,status,received_base_qty,"
                +" passed_base_qty,failed_base_qty,warehouse_stocked_base_qty) VALUES(:id,'PURCHASE',:receipt,:warehouse,'RESOLVED',2,0,2,0)",
                "id",secondReturn,"receipt",receipt,"warehouse",warehouseB);
        execute("INSERT INTO procurement_iqc_rejection_cases(id,inspection_item_id,receipt_type,receipt_id,status,is_deleted)"
                +" VALUES(:id,:inspection,'PURCHASE',:receipt,'OPEN',FALSE)",
                "id",UUID.randomUUID(),"inspection",secondReturn,"receipt",receipt);
        assertThat(quality.typeCounts(scopeB).actionable()).containsEntry("PURCHASE",2L);
        assertThat(quality.typeCounts(WarehouseTaskScope.ALL).inProgress()).containsEntry("PURCHASE",1L);
        assertThat(quality.typeCounts(WarehouseTaskScope.ALL).actionable()).containsEntry("PURCHASE",2L);
        } finally { org.springframework.security.core.context.SecurityContextHolder.clearContext(); }
    }

    @Test void qualityDetailAndBatchReadsKeepOnlyVisibleInspectionSlicesHistoryAndRejections() {
        UUID warehouseA=UUID.randomUUID(),warehouseB=UUID.randomUUID(),outside=UUID.randomUUID();
        var scopeA=new WarehouseTaskScope(true,List.of(warehouseA),false);
        var scopeB=new WarehouseTaskScope(true,List.of(warehouseB),false);
        var scopes=mock(WarehouseTaskScopePort.class);
        when(scopes.current(null)).thenReturn(scopeA);
        when(scopes.current(warehouseB)).thenReturn(scopeB);
        var quality=new com.uten.imp.features.warehouse.inbound.WarehouseQualityResultService(
                executingEntityManager(),mock(SecurityContextCurrentUser.class));
        org.springframework.test.util.ReflectionTestUtils.setField(quality,"warehouseScopes",scopes);
        var controller=new com.uten.imp.features.warehouse.inbound.WarehouseQualityResultController(quality,scopes);
        var actor=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"warehouse",Set.of(
                "warehouse_iqc_stock_in:view","warehouse_iqc_stock_in:confirm","warehouse_iqc_stock_in:before_inspection",
                "warehouse_iqc_return:view","procurement_iqc_rejection:record_return"),false,true,false);
        org.springframework.security.core.context.SecurityContextHolder.getContext().setAuthentication(
                new org.springframework.security.authentication.UsernamePasswordAuthenticationToken(actor,"",actor.getAuthorities()));
        try {
            // Batch forms call this same detail read once per receipt. Check both independently.
            for(int index=0;index<2;index++) {
                UUID receipt=UUID.randomUUID(),waiting=UUID.randomUUID(),handled=UUID.randomUUID(),event=UUID.randomUUID(),batch=UUID.randomUUID();
                UUID goodsA=UUID.randomUUID(),goodsB=UUID.randomUUID();
                receipt("purchase_receipts",receipt,"DETAIL-SCOPE-"+index,"2026-10-12",warehouseA);
                execute("UPDATE purchase_receipts SET status=1 WHERE id=:id","id",receipt);
                execute("INSERT INTO goods(id,code,name) VALUES(:id,:code,'Local waiting goods')","id",goodsA,"code","LOCAL-"+index);
                execute("INSERT INTO goods(id,code,name) VALUES(:id,:code,'Other warehouse goods')","id",goodsB,"code","OTHER-"+index);
                execute("INSERT INTO procurement_inspection_items(id,receipt_type,receipt_id,warehouse_id,goods_id,status,received_base_qty,"
                        +" passed_base_qty,failed_base_qty,warehouse_stocked_base_qty) VALUES(:id,'PURCHASE',:receipt,:warehouse,:goods,'PENDING',5,0,0,0)",
                        "id",waiting,"receipt",receipt,"warehouse",warehouseA,"goods",goodsA);
                execute("INSERT INTO procurement_inspection_items(id,receipt_type,receipt_id,warehouse_id,goods_id,status,received_base_qty,"
                        +" passed_base_qty,failed_base_qty,warehouse_stocked_base_qty) VALUES(:id,'PURCHASE',:receipt,:warehouse,:goods,'RESOLVED',5,3,2,1)",
                        "id",handled,"receipt",receipt,"warehouse",warehouseB,"goods",goodsB);
                execute("INSERT INTO procurement_inspection_events(id,inspection_item_id,action,requires_warehouse_stock_in,base_qty,occurred_at)"
                        +" VALUES(:id,:inspection,'PASS',TRUE,3,now())","id",event,"inspection",handled);
                execute("INSERT INTO procurement_iqc_stock_in_batches(id,receipt_type,receipt_id,confirmed_at,origin)"
                        +" VALUES(:id,'PURCHASE',:receipt,now(),'MANUAL')","id",batch,"receipt",receipt);
                execute("INSERT INTO procurement_iqc_stock_in_batch_items(id,batch_id,inspection_item_id,pass_event_id,goods_id,base_qty,warehouse_id,position)"
                        +" VALUES(:id,:batch,:inspection,:event,:goods,1,:warehouse,1)","id",UUID.randomUUID(),"batch",batch,
                        "inspection",handled,"event",event,"goods",goodsB,"warehouse",warehouseB);
                execute("INSERT INTO procurement_iqc_rejection_cases(id,inspection_item_id,receipt_type,receipt_id,goods_id,failed_qty,status,is_deleted,row_version)"
                        +" VALUES(:id,:inspection,'PURCHASE',:receipt,:goods,2,'PENDING_RETURN',FALSE,1)",
                        "id",UUID.randomUUID(),"inspection",handled,"receipt",receipt,"goods",goodsB);
                var local=controller.detail("PURCHASE",receipt,null);
                assertThat(local.lines()).singleElement().satisfies(line->assertThat(line.inspectionItemId()).isEqualTo(waiting));
                assertThat(local.items()).isEmpty();
                assertThat(local.history()).isEmpty();
                assertThat(local.rejections()).isEmpty();
                assertThat(local.pendingSliceCount()).isZero();
                assertThat(local.pendingReturnCount()).isZero();
                assertThat(local.workStatus()).isEqualTo("WAITING_INSPECTION");
                assertThat(local.allowedActions()).containsExactly("PRE_STOCK_IN");
                assertThat(quality.detail("PURCHASE",receipt).lines()).hasSize(1);
                var selected=controller.detail("PURCHASE",receipt,warehouseB);
                assertThat(selected.lines()).singleElement().satisfies(line->assertThat(line.inspectionItemId()).isEqualTo(handled));
                assertThat(selected.items()).hasSize(1);
                assertThat(selected.history()).hasSize(1);
                assertThat(selected.rejections()).hasSize(1);
                assertThat(selected.pendingSliceCount()).isEqualTo(1);
                assertThat(selected.pendingReturnCount()).isEqualTo(1);
                assertThat(selected.allowedActions()).containsExactly("CONFIRM");
                assertThatThrownBy(()->quality.detail("PURCHASE",receipt,new WarehouseTaskScope(true,List.of(outside),false)))
                        .isInstanceOf(ApiException.class);
            }
        } finally { org.springframework.security.core.context.SecurityContextHolder.clearContext(); }
    }

    private UUID searchStock(String bill,String code,String name,String date,UUID warehouse) {
        UUID document=UUID.randomUUID(), goods=UUID.randomUUID();
        execute("INSERT INTO goods(id,code,name) VALUES(:id,:code,:name)","id",goods,"code",code,"name",name);
        stock(document,"OTHER_IN",bill,date,null);
        execute("UPDATE stock_documents SET warehouse_id=:warehouse WHERE id=:id","warehouse",warehouse,"id",document);
        execute("INSERT INTO stock_document_items(id,doc_id,goods_id,is_deleted) VALUES(:id,:document,:goods,FALSE)",
                "id",UUID.randomUUID(),"document",document,"goods",goods);
        return document;
    }

    @Test void completedReversedAndClosedDocumentsLeaveActiveBeforePagingAndRetainScopedHistory() {
        UUID warehouse=UUID.randomUUID(),outside=UUID.randomUUID();
        UUID draft=UUID.randomUUID(),posted=UUID.randomUUID(),reversed=UUID.randomUUID(),closed=UUID.randomUUID();
        stock(draft,"OTHER_IN","ACTIVE","2026-10-12",null);
        stock(posted,"FINISHED_IN","POSTED","2026-10-12",null);
        stock(reversed,"OTHER_IN","REVERSED","2026-10-12",null);
        stock(closed,"WDRAW","CLOSED","2026-10-12",null);
        execute("UPDATE stock_documents SET warehouse_id=:warehouse","warehouse",warehouse);
        execute("UPDATE stock_documents SET status=1 WHERE id=:id","id",posted);
        execute("UPDATE stock_documents SET status=-1 WHERE id=:id","id",reversed);
        execute("UPDATE stock_documents SET is_closed=TRUE WHERE id=:id","id",closed);
        UUID hidden=UUID.randomUUID();
        stock(hidden,"OTHER_IN","HIDDEN","2026-10-12",null);
        execute("UPDATE stock_documents SET warehouse_id=:warehouse,status=1 WHERE id=:id","warehouse",outside,"id",hidden);
        var service=service(Set.of("stock_doc:view"),new WarehouseTaskScope(true,List.of(warehouse),false),false);
        var active=service.list(filter("ALL","",99,1));
        assertThat(active.total()).isEqualTo(1);
        assertThat(active.page()).isEqualTo(1);
        assertThat(active.items()).extracting(Row::id).containsExactly(draft);
        assertThat(active.facets().get("status")).extracting(WarehouseTaskCenterContracts.StatusFacet::value)
                .containsExactly("OTHER_DRAFT");
        var history=service.list(new Filter("ALL","","",null,null,null,null,1,2,"billNo","asc",TaskView.HISTORY));
        assertThat(history.total()).isEqualTo(3);
        assertThat(history.totalPages()).isEqualTo(2);
        assertThat(history.items()).extracting(Row::billNo).containsExactly("CLOSED","POSTED");
        assertThat(history.facets().get("billNo")).extracting(WarehouseTaskCenterContracts.StatusFacet::value)
                .containsExactly("CLOSED","POSTED","REVERSED");
        assertThat(((Row)service.detail("FINISHED:STOCK_DOCUMENT:"+posted,null).get("row")).id()).isEqualTo(posted);
        assertThatThrownBy(()->service.detail("OTHER:STOCK_DOCUMENT:"+hidden,null)).isInstanceOf(ApiException.class);
        execute("UPDATE stock_documents SET status=0 WHERE id=:id","id",posted);
        assertThat(service.list(filter("ALL","",1,20)).items()).extracting(Row::id).containsExactlyInAnyOrder(draft,posted);
        assertThat(service.list(new Filter("ALL","","",null,null,null,null,1,20,null,null,TaskView.HISTORY)).total())
                .isEqualTo(2);
    }

    @Test void qualityResultsUseTheSameLifecycleForRowsTotalsAndBillNumberFacets() {
        UUID warehouse=UUID.randomUUID(),outside=UUID.randomUUID();
        UUID waiting=UUID.randomUUID(),completed=UUID.randomUUID(),hidden=UUID.randomUUID();
        receipt("purchase_receipts",waiting,"Q-WAITING","2026-10-12",warehouse);
        receipt("purchase_receipts",completed,"Q-COMPLETED","2026-10-12",warehouse);
        receipt("purchase_receipts",hidden,"Q-HIDDEN","2026-10-12",outside);
        execute("UPDATE purchase_receipts SET status=1");
        for(UUID receipt:List.of(waiting,completed,hidden)) {
            execute("INSERT INTO procurement_inspection_items(id,receipt_type,receipt_id,status,received_base_qty,"
                    +" passed_base_qty,failed_base_qty,warehouse_stocked_base_qty)"
                    +" VALUES(:id,'PURCHASE',:receipt,:status,5,:passed,0,:passed)","id",UUID.randomUUID(),
                    "receipt",receipt,"status",receipt.equals(waiting)?"PENDING":"RESOLVED",
                    "passed",receipt.equals(waiting)?0:5);
        }
        var em=executingEntityManager();
        var service=new com.uten.imp.features.warehouse.inbound.WarehouseQualityResultService(em,mock(SecurityContextCurrentUser.class));
        var scope=new WarehouseTaskScope(true,List.of(warehouse),false);
        var active=service.list("","ALL","",null,null,1,1,null,null,null,scope,TaskView.ACTIVE);
        assertThat(active.getTotal()).isEqualTo(1);
        assertThat(active.getItems()).extracting(com.uten.imp.features.warehouse.inbound.WarehouseQualityResultContracts.TaskSummary::billNo)
                .containsExactly("Q-WAITING");
        var history=service.list("","ALL","",null,null,1,1,null,null,null,scope,TaskView.HISTORY);
        assertThat(history.getTotal()).isEqualTo(1);
        assertThat(history.getItems()).extracting(com.uten.imp.features.warehouse.inbound.WarehouseQualityResultContracts.TaskSummary::billNo)
                .containsExactly("Q-COMPLETED");
        assertThat(service.facets("","ALL","",null,null,scope,TaskView.ACTIVE).get("billNo"))
                .singleElement().satisfies(bucket->assertThat(bucket.get("value")).isEqualTo("Q-WAITING"));
        assertThat(service.facets("","ALL","",null,null,scope,TaskView.HISTORY).get("billNo"))
                .singleElement().satisfies(bucket->assertThat(bucket.get("value")).isEqualTo("Q-COMPLETED"));
    }

    /** Executes the service's unmodified native SQL and bindings against this migrated PostgreSQL fixture. */
    private jakarta.persistence.EntityManager executingEntityManager() {
        var em=mock(jakarta.persistence.EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation->{
            String sql=invocation.getArgument(0);
            var bindings=new MapSqlParameterSource();
            var query=mock(jakarta.persistence.Query.class);
            when(query.setParameter(anyString(),any())).thenAnswer(binding->{
                bindings.addValue(binding.getArgument(0),binding.getArgument(1));
                return query;
            });
            when(query.setMaxResults(org.mockito.ArgumentMatchers.anyInt())).thenReturn(query);
            when(query.getSingleResult()).thenAnswer(result->jdbc.query(sql,bindings,(rows,index)->{
                if(rows.getMetaData().getColumnCount()==1) return rows.getObject(1);
                Object[] values=new Object[rows.getMetaData().getColumnCount()];
                for(int column=0;column<values.length;column++) values[column]=rows.getObject(column+1);
                return values;
            }).getFirst());
            when(query.getResultList()).thenAnswer(result->jdbc.query(sql,bindings,(rows,index)->{
                Object[] values=new Object[rows.getMetaData().getColumnCount()];
                for(int column=0;column<values.length;column++) values[column]=rows.getObject(column+1);
                return values;
            }));
            return query;
        });
        return em;
    }

    @Test void mixedSourcesWithSameUuidAreGloballyPagedSortedAndFilteredWithoutLostIdentity() throws Exception {
        UUID id=UUID.randomUUID();
        receipt("purchase_receipts",id,"PQ-03","2026-10-12",null);
        receipt("subcontract_receipts",id,"PQ-02","2026-10-11",null);
        stock(id,"OTHER_IN","PQ-01","2026-10-10",null);
        var service=service(Set.of("stock_doc:view","warehouse_purchase_receipt_history:view",
                "warehouse_subcontract_receipt_history:view"),WarehouseTaskScope.ALL,false);
        var first=service.list(filter("ALL","",1,2));
        var second=service.list(filter("ALL","",2,2));
        assertThat(first.total()).isEqualTo(3);
        assertThat(first.items()).extracting(Row::billNo).containsExactly("PQ-03","PQ-02");
        assertThat(second.items()).extracting(Row::billNo).containsExactly("PQ-01");
        assertThat(java.util.stream.Stream.concat(first.items().stream(),second.items().stream()).map(Row::rowKey).distinct().count())
                .isEqualTo(3);
        assertThat(first.facets().get("status")).hasSize(3);
        var filtered=service.list(filter("ALL","SUBCONTRACT_RECEIPT_DRAFT",1,2));
        assertThat(filtered.total()).isEqualTo(1);
        assertThat(filtered.items().getFirst().sourceType()).isEqualTo("SUBCONTRACT");
        var ascending=service.list(new Filter("ALL","","",null,null,null,null,1,2,"billNo","asc"));
        assertThat(ascending.items()).extracting(Row::billNo).containsExactly("PQ-01","PQ-02");
        var exact=service.list(new Filter("ALL","","","PQ-02",null,null,null,1,2));
        assertThat(exact.items()).hasSize(1);
        assertThat(exact.facets().get("billNo")).hasSize(3);
        assertThat(service.list(filter("ALL","",99,2)).page()).isEqualTo(2);
        execute("UPDATE stock_documents SET is_deleted=TRUE WHERE id=:id","id",id);
        var reduced=service.list(filter("ALL","",99,2));
        assertThat(reduced.page()).isEqualTo(1);
        assertThat(reduced.total()).isEqualTo(2);
        assertThat(reduced.items()).hasSize(2);
        String json=mapper.writeValueAsString(first);
        assertThat(json).doesNotContain("unitPrice","amountOriginal","amountLocal","currencyId","exchangeRate");
        var detail=service.detail("SUBCONTRACT:SUBCONTRACT_RECEIPT:"+id,null);
        assertThat(((Row)detail.get("row")).sourceType()).isEqualTo("SUBCONTRACT");
        assertThat(detail).containsKeys("items","page","size","total","totalPages");
        assertThat(mapper.writeValueAsString(detail)).doesNotContain("unitPrice","amountOriginal","currencyId","exchangeRate");
    }

    @Test void authorizedHistorySubsetAndWarehouseScopeAlsoConstrainTotalsFacetsAndDetails() {
        UUID warehouse=UUID.randomUUID();
        UUID hiddenWarehouse=UUID.randomUUID();
        UUID shown=UUID.randomUUID();
        UUID hidden=UUID.randomUUID();
        receipt("purchase_receipts",shown,"VISIBLE","2026-10-12",warehouse);
        receipt("purchase_receipts",hidden,"HIDDEN","2026-10-12",hiddenWarehouse);
        receipt("subcontract_receipts",shown,"SC-HIDDEN","2026-10-12",warehouse);
        var service=service(Set.of("warehouse_purchase_receipt_history:view"),
                new WarehouseTaskScope(true,List.of(warehouse),false),false);
        var page=service.list(filter("ALL","",1,30));
        assertThat(page.total()).isEqualTo(1);
        assertThat(page.items()).extracting(Row::billNo).containsExactly("VISIBLE");
        assertThat(page.facets().get("billNo")).extracting(WarehouseTaskCenterContracts.StatusFacet::value).containsExactly("VISIBLE");
        assertThat(page.items().getFirst().canHandle()).isFalse();
        assertThatThrownBy(()->service.list(filter("SUBCONTRACT","",1,30))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->service.detail("PURCHASE:PURCHASE_RECEIPT:"+hidden,null)).isInstanceOf(ApiException.class);
    }

    @Test void registeredWaitingFqcRemainsVisibleAndResidualFinalCountDoesNotDuplicateStockDraft() {
        UUID report=UUID.randomUUID(),sourceItem=UUID.randomUUID(),registration=UUID.randomUUID(),inspection=UUID.randomUUID();
        execute("INSERT INTO production_daily_reports(id,bill_no,bill_date,status,is_deleted) VALUES(:id,'REPORT','2026-10-12',1,FALSE)","id",report);
        execute("INSERT INTO production_daily_report_items(id,report_id,qty,destination,is_deleted) VALUES(:id,:report,5,'WAREHOUSE',FALSE)",
                "id",sourceItem,"report",report);
        execute("INSERT INTO production_finished_arrival_registrations(id,source_report_id,warehouse_name_snapshot,receiver_name_snapshot,stock_in_before_inspection,created_at)"
                +" VALUES(:id,:report,'成品仓','仓管',FALSE,now())","id",registration,"report",report);
        execute("INSERT INTO production_finished_arrival_registration_items(id,registration_id,source_report_item_id,place_snapshot) VALUES(:id,:registration,:item,'A-01')",
                "id",UUID.randomUUID(),"registration",registration,"item",sourceItem);
        execute("INSERT INTO production_fqc_inspections(id,source_report_item_id,status,passed_qty,failed_qty) VALUES(:id,:item,'PENDING',0,0)",
                "id",inspection,"item",sourceItem);
        var service=service(Set.of("stock_doc:view"),WarehouseTaskScope.ALL,true);
        var waiting=service.list(filter("FINISHED","",1,30));
        assertThat(waiting.items()).anySatisfy(row->{
            assertThat(row.status()).isEqualTo("FINISHED_WAITING_FQC");
            assertThat(row.targetId()).isEqualTo(registration);
            assertThat(row.actionData()).containsEntry("reportId",report.toString());
        });
        UUID document=UUID.randomUUID();
        stock(document,"FINISHED_IN","FINISHED","2026-10-12",report);
        execute("INSERT INTO stock_document_items(id,doc_id,qty,is_deleted,source_daily_report_item_id) VALUES(:id,:document,2,FALSE,:item)",
                "id",UUID.randomUUID(),"document",document,"item",sourceItem);
        execute("INSERT INTO production_finished_in_confirmations(id,residual_stock_document_id) VALUES(:id,:document)",
                "id",UUID.randomUUID(),"document",document);
        execute("UPDATE production_fqc_inspections SET status='PARTIAL',passed_qty=2 WHERE id=:id","id",inspection);
        var partial=service.list(filter("FINISHED","",1,30));
        assertThat(partial.items().stream().filter(row->row.id().equals(document))).hasSize(1);
        assertThat(partial.items()).anySatisfy(row->assertThat(row.status()).isEqualTo("FINISHED_RESIDUAL_COUNT"));
        assertThat(partial.items()).anySatisfy(row->assertThat(row.status()).isEqualTo("FINISHED_FQC_PARTIAL"));
        execute("UPDATE production_fqc_inspections SET status='RESOLVED',passed_qty=5 WHERE id=:id","id",inspection);
        execute("UPDATE stock_documents SET status=1 WHERE id=:id","id",document);
        assertThat(service.list(filter("FINISHED","",1,30)).items()).noneMatch(row->row.id().equals(registration));
        var history=service.list(new Filter("FINISHED","","",null,null,null,null,1,30,null,null,TaskView.HISTORY));
        assertThat(history.items()).anySatisfy(row->{
            assertThat(row.id()).isEqualTo(registration);
            assertThat(row.status()).isEqualTo("FINISHED_REGISTRATION_CLOSED");
        });
    }

    @Test void beforeInspectionCapabilityRequiresCurrentSpecialAuthorityAndOriginalRegistrationAction() {
        UUID goods=UUID.randomUUID(),report=UUID.randomUUID(),expectation=UUID.randomUUID();
        execute("INSERT INTO goods(id,code,name) VALUES(:id,'CAPABILITY-GOODS','能力实物')","id",goods);
        report(report,"CAPABILITY-REPORT");
        reportItem(UUID.randomUUID(),report,goods,5);
        execute("INSERT INTO inbound_expectations(id,order_type,order_id,supplier_id,bill_no_snapshot,status,created_at)"
                +" VALUES(:id,'PURCHASE',:order,:supplier,'CAPABILITY-EXPECTATION','OPEN',now())",
                "id",expectation,"order",UUID.randomUUID(),"supplier",UUID.randomUUID());
        execute("INSERT INTO inbound_expectation_items(id,expectation_id,order_item_id,line_no,goods_id,ordered_qty,accepted_qty,unit_rate)"
                +" VALUES(:id,:expectation,:orderItem,1,:goods,5,0,1)",
                "id",UUID.randomUUID(),"expectation",expectation,"orderItem",UUID.randomUUID(),"goods",goods);
        UUID ordinary=UUID.randomUUID();
        stock(ordinary,"OTHER_IN","CAPABILITY-OTHER","2026-10-12",null);
        var currentGrants=new java.util.HashSet<>(Set.of("stock_doc:view","stock_doc:approve","stock_doc:edit",
                "warehouse_inbound:view","warehouse_inbound:stock_in",
                ProductionFinishedArrivalRegistrationService.BEFORE_INSPECTION_AUTHORITY,
                ProcurementIqcStockInPermissions.BEFORE_INSPECTION));
        var actor=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"warehouse",currentGrants,false,true,false);
        var service=service(actor,WarehouseTaskScope.ALL,true);
        var permitted=service.list(filter("ALL","",1,30));
        assertThat(registrationRow(permitted,"FINISHED_REGISTER").actionData())
                .containsEntry("canRegisterBeforeInspection",true);
        assertThat(registrationRow(permitted,"ARRIVAL_REGISTER").actionData())
                .containsEntry("canRegisterBeforeInspection",true);
        assertThat(permitted.items().stream().filter(row->row.id().equals(ordinary)).toList()).singleElement()
                .satisfies(row->assertThat(row.actionData()).containsEntry("canRegisterBeforeInspection",false));
        assertThat(mapper.valueToTree(permitted).toString()).contains("\"canRegisterBeforeInspection\":true");

        currentGrants.remove(ProductionFinishedArrivalRegistrationService.BEFORE_INSPECTION_AUTHORITY);
        var arrivalOnly=service.list(filter("ALL","",1,30));
        assertThat(registrationRow(arrivalOnly,"FINISHED_REGISTER").canHandle()).isTrue();
        assertThat(registrationRow(arrivalOnly,"FINISHED_REGISTER").actionData())
                .containsEntry("canRegisterBeforeInspection",false);
        assertThat(registrationRow(arrivalOnly,"ARRIVAL_REGISTER").actionData())
                .containsEntry("canRegisterBeforeInspection",true);
        currentGrants.add(ProductionFinishedArrivalRegistrationService.BEFORE_INSPECTION_AUTHORITY);
        currentGrants.remove(ProcurementIqcStockInPermissions.BEFORE_INSPECTION);
        var finishedOnly=service.list(filter("ALL","",1,30));
        assertThat(registrationRow(finishedOnly,"FINISHED_REGISTER").actionData())
                .containsEntry("canRegisterBeforeInspection",true);
        assertThat(registrationRow(finishedOnly,"ARRIVAL_REGISTER").actionData())
                .containsEntry("canRegisterBeforeInspection",false);

        var specialOnly=service(Set.of("stock_doc:view","warehouse_inbound:view",
                ProductionFinishedArrivalRegistrationService.BEFORE_INSPECTION_AUTHORITY,
                ProcurementIqcStockInPermissions.BEFORE_INSPECTION),WarehouseTaskScope.ALL,true)
                .list(filter("ALL","",1,30));
        assertThat(specialOnly.items()).isNotEmpty().allSatisfy(row->{
            assertThat(row.canHandle()).isFalse();
            assertThat(row.actionData()).containsEntry("canRegisterBeforeInspection",false);
        });
        currentGrants.add(ProcurementIqcStockInPermissions.BEFORE_INSPECTION);
        var impersonated=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"warehouse",currentGrants,
                false,true,false,false,UUID.randomUUID());
        assertThat(service(impersonated,WarehouseTaskScope.ALL,true).list(filter("ALL","",1,30)).items())
                .isNotEmpty().allSatisfy(row->{
                    assertThat(row.canHandle()).isFalse();
                    assertThat(row.actionData()).containsEntry("canRegisterBeforeInspection",false);
                });
        assertThat(service(actor,WarehouseTaskScope.ALL,false).list(filter("FINISHED","",1,30)).items())
                .noneSatisfy(row->assertThat(row.actionData()).containsEntry("canRegisterBeforeInspection",true));
        var sparseAdmin=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"admin",
                Set.of("stock_doc:view","stock_doc:approve","warehouse_inbound:view","warehouse_inbound:stock_in"),
                false,true,true);
        assertThat(service(sparseAdmin,WarehouseTaskScope.ALL,true).list(filter("ALL","",1,30)).items())
                .isNotEmpty().allSatisfy(row->assertThat(row.actionData()).containsEntry("canRegisterBeforeInspection",false));
        var explicitAdmin=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"admin",currentGrants,false,true,true);
        var adminPage=service(explicitAdmin,WarehouseTaskScope.ALL,true).list(filter("ALL","",1,30));
        assertThat(registrationRow(adminPage,"ARRIVAL_REGISTER").actionData())
                .containsEntry("canRegisterBeforeInspection",true);
        assertThat(registrationRow(adminPage,"FINISHED_REGISTER").actionData())
                .containsEntry("canRegisterBeforeInspection",true);
        for(String missingBase:List.of("warehouse_inbound:view","warehouse_inbound:stock_in","stock_doc:view","stock_doc:approve")) {
            var sparseGrants=new java.util.HashSet<>(currentGrants);
            sparseGrants.remove(missingBase);
            var missingBaseAdmin=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"admin",sparseGrants,false,true,true);
            var missingBasePage=service(missingBaseAdmin,WarehouseTaskScope.ALL,true).list(filter("ALL","",1,30));
            String blockedAction=missingBase.startsWith("warehouse_inbound:")?"ARRIVAL_REGISTER":"FINISHED_REGISTER";
            Row blocked=registrationRow(missingBasePage,blockedAction);
            assertThat(blocked.canHandle()).as("General capability retains its original policy for %s",missingBase).isTrue();
            assertThat(blocked.actionData()).as("Native base authority missing: %s",missingBase)
                    .containsEntry("canRegisterBeforeInspection",false);
        }
        var extraOnlyAdmin=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"admin",Set.of(
                "warehouse_iqc_return:view",ProductionFinishedArrivalRegistrationService.BEFORE_INSPECTION_AUTHORITY,
                ProcurementIqcStockInPermissions.BEFORE_INSPECTION),false,true,true);
        assertThat(service(extraOnlyAdmin,WarehouseTaskScope.ALL,true).list(filter("ALL","",1,30)).items())
                .isNotEmpty().allSatisfy(row->assertThat(row.actionData()).containsEntry("canRegisterBeforeInspection",false));
    }

    private static Row registrationRow(WarehouseTaskCenterContracts.Page page,String action) {
        return page.items().stream().filter(row->row.action().equals(action)).findFirst().orElseThrow();
    }

    @Test void detailUsesRealSqlPaginationAndDoesNotTurnOneVisibleDocumentIntoUnboundedLines() {
        UUID document=UUID.randomUUID();
        stock(document,"OTHER_IN","DETAIL","2026-10-12",null);
        for(int line=1;line<=3;line++) execute("INSERT INTO stock_document_items(id,doc_id,line_no,qty,is_deleted,goods_name_snapshot)"
                +" VALUES(:id,:document,:line,1,FALSE,:name)","id",UUID.randomUUID(),"document",document,
                "line",line,"name","物料"+line);
        var service=service(Set.of("stock_doc:view"),WarehouseTaskScope.ALL,false);
        var detail=service.detail("OTHER:STOCK_DOCUMENT:"+document,null,2,2);
        assertThat(detail.get("total")).isEqualTo(3L);
        assertThat(detail.get("totalPages")).isEqualTo(2);
        assertThat((List<?>)detail.get("items")).hasSize(1);
    }

    @Test void populatedPhysicalDetailQueriesCoverEveryRecordAndKeepSourceSpecificColumns() throws Exception {
        UUID goods=UUID.randomUUID();
        execute("INSERT INTO goods(id,code,name) VALUES(:id,'DETAIL-GOODS','实物明细')","id",goods);
        UUID purchase=UUID.randomUUID(),subcontract=UUID.randomUUID();
        receipt("purchase_receipts",purchase,"DETAIL-PURCHASE","2026-10-12",null);
        receipt("subcontract_receipts",subcontract,"DETAIL-SUBCONTRACT","2026-10-12",null);
        execute("INSERT INTO purchase_receipt_items(id,receipt_id,line_no,goods_id,qty,gift_qty,is_deleted,goods_name_snapshot)"
                +" VALUES(:id,:receipt,1,:goods,10.1250,1.2500,FALSE,'采购实物快照')",
                "id",UUID.randomUUID(),"receipt",purchase,"goods",goods);
        // Migrated subcontract items have neither gift_qty nor charged+gift
        // semantics. Its physical quantity must stay separate from purchase gifts.
        execute("INSERT INTO subcontract_receipt_items(id,receipt_id,line_no,goods_id,qty,is_deleted,goods_name_snapshot)"
                +" VALUES(:id,:receipt,1,:goods,7.5000,FALSE,'委外实物快照')",
                "id",UUID.randomUUID(),"receipt",subcontract,"goods",goods);
        UUID expectation=UUID.randomUUID();
        execute("INSERT INTO inbound_expectations(id,order_type,order_id,bill_no_snapshot,status,created_at)"
                +" VALUES(:id,'PURCHASE',:order,'DETAIL-EXPECTATION','OPEN',now())",
                "id",expectation,"order",UUID.randomUUID());
        execute("INSERT INTO inbound_expectation_items(id,expectation_id,order_item_id,line_no,goods_id,ordered_qty,accepted_qty,unit_rate)"
                +" VALUES(:id,:expectation,:orderItem,1,:goods,5,1,1)",
                "id",UUID.randomUUID(),"expectation",expectation,"orderItem",UUID.randomUUID(),"goods",goods);
        UUID exception=arrivalException("PURCHASE","RECEIPT_ADJUSTED",null,goods);
        execute("UPDATE procurement_arrival_exceptions SET declared_qty=5,approved_remaining_qty=3,accepted_qty=2,"
                +" unaccepted_qty=3,version=4,receipt_bill_no_snapshot='DETAIL-EXCEPTION' WHERE id=:id","id",exception);

        UUID pendingReport=UUID.randomUUID(),pendingItem=UUID.randomUUID();
        report(pendingReport,"DETAIL-PENDING-REPORT");
        reportItem(pendingItem,pendingReport,goods,5);
        UUID registeredReport=UUID.randomUUID(),registeredItem=UUID.randomUUID(),registration=UUID.randomUUID();
        report(registeredReport,"DETAIL-REGISTERED-REPORT");
        reportItem(registeredItem,registeredReport,goods,8);
        execute("INSERT INTO production_finished_arrival_registrations(id,source_report_id,warehouse_name_snapshot,"
                +" receiver_name_snapshot,stock_in_before_inspection,created_at) VALUES(:id,:report,'成品仓','仓管',FALSE,now())",
                "id",registration,"report",registeredReport);
        execute("INSERT INTO production_finished_arrival_registration_items(id,registration_id,source_report_item_id,place_snapshot)"
                +" VALUES(:id,:registration,:item,'F-01')","id",UUID.randomUUID(),"registration",registration,"item",registeredItem);
        execute("INSERT INTO production_fqc_inspections(id,source_report_item_id,status,passed_qty,failed_qty)"
                +" VALUES(:id,:item,'PENDING',0,0)","id",UUID.randomUUID(),"item",registeredItem);
        UUID finalCount=UUID.randomUUID();
        stock(finalCount,"FINISHED_IN","DETAIL-COUNT","2026-10-12",registeredReport);
        execute("INSERT INTO stock_document_items(id,doc_id,line_no,goods_id,qty,is_deleted,source_daily_report_item_id,goods_name_snapshot)"
                +" VALUES(:id,:doc,1,:goods,2,FALSE,:source,'最终点收实物')",
                "id",UUID.randomUUID(),"doc",finalCount,"goods",goods,"source",registeredItem);
        UUID other=UUID.randomUUID();
        stock(other,"OTHER_IN","DETAIL-OTHER","2026-10-12",null);
        execute("INSERT INTO stock_document_items(id,doc_id,line_no,goods_id,qty,is_deleted,goods_name_snapshot)"
                +" VALUES(:id,:doc,1,:goods,3,FALSE,'其它入库实物')","id",UUID.randomUUID(),"doc",other,"goods",goods);

        var service=service(Set.of("stock_doc:view","warehouse_inbound:view","warehouse_purchase_receipt_history:view",
                "warehouse_subcontract_receipt_history:view"),WarehouseTaskScope.ALL,true);
        var purchaseLine=populatedDetail(service,"PURCHASE","PURCHASE_RECEIPT",purchase);
        assertThat((java.math.BigDecimal)purchaseLine.get("giftQty")).isEqualByComparingTo("1.2500");
        assertThat(purchaseLine).containsEntry("goodsName","采购实物快照");
        var subcontractLine=populatedDetail(service,"SUBCONTRACT","SUBCONTRACT_RECEIPT",subcontract);
        assertThat(subcontractLine).containsKey("giftQty");
        assertThat(subcontractLine.get("giftQty")).isNull();
        assertThat((java.math.BigDecimal)subcontractLine.get("quantity")).isEqualByComparingTo("7.5000");
        assertThat(subcontractLine).containsEntry("goodsName","委外实物快照");
        var expectationLine=populatedDetail(service,"PURCHASE","EXPECTATION",expectation);
        assertThat((java.math.BigDecimal)expectationLine.get("remainingQty")).isEqualByComparingTo("4");
        var exceptionLine=populatedDetail(service,"PURCHASE","ARRIVAL_EXCEPTION",exception);
        assertThat((java.math.BigDecimal)exceptionLine.get("acceptedQty")).isEqualByComparingTo("2");
        assertThat((Number)exceptionLine.get("version")).isNotNull();
        assertThat(((Number)exceptionLine.get("version")).intValue()).isEqualTo(4);
        populatedDetail(service,"FINISHED","FINISHED_REGISTER",pendingReport);
        var registrationLine=populatedDetail(service,"FINISHED","FINISHED_REGISTRATION",registration);
        assertThat(registrationLine).containsEntry("registrationId",registration).containsEntry("sourceReportItemId",registeredItem);
        populatedDetail(service,"FINISHED","FINISHED_COUNT",finalCount);
        populatedDetail(service,"OTHER","STOCK_DOCUMENT",other);
    }

    @SuppressWarnings("unchecked")
    private java.util.Map<String,Object> populatedDetail(WarehouseInboundTaskCenterQueryService service,
            String source,String record,UUID id) throws Exception {
        var detail=service.detail(source+":"+record+":"+id,null,1,1);
        assertThat(((Row)detail.get("row")).recordType()).isEqualTo(record);
        assertThat(detail.get("total")).isEqualTo(1L);
        assertThat(detail.get("page")).isEqualTo(1);
        assertThat(detail.get("size")).isEqualTo(1);
        assertThat(detail.get("totalPages")).isEqualTo(1);
        var lines=(List<java.util.Map<String,Object>>)detail.get("items");
        assertThat(lines).hasSize(1);
        assertThat(lines.getFirst().get("goodsName")).isNotNull();
        assertThat(mapper.writeValueAsString(detail)).doesNotContain("unitPrice","amountOriginal","amountLocal","currencyId","exchangeRate");
        return lines.getFirst();
    }

    private void report(UUID id,String billNo) {
        execute("INSERT INTO production_daily_reports(id,bill_no,bill_date,status,is_deleted,created_at)"
                +" VALUES(:id,:bill,'2026-10-12',1,FALSE,now())","id",id,"bill",billNo);
    }

    private void reportItem(UUID id,UUID report,UUID goods,int quantity) {
        execute("INSERT INTO production_daily_report_items(id,report_id,goods_id,qty,destination,is_deleted,execution_segment_id,output_lot_id)"
                +" VALUES(:id,:report,:goods,:qty,'WAREHOUSE',FALSE,:segment,:lot)",
                "id",id,"report",report,"goods",goods,"qty",quantity,"segment",UUID.randomUUID(),"lot",UUID.randomUUID());
    }

    @Test void typedArrivalExceptionCountComesFromTheSameScopedQueueIncludingBothDomains() {
        UUID warehouse=UUID.randomUUID(),outside=UUID.randomUUID(),goods=UUID.randomUUID();
        execute("INSERT INTO goods(id,code,name) VALUES(:id,'PHYSICAL','实物')","id",goods);
        arrivalException("PURCHASE","PENDING_FINANCE",warehouse,goods);
        arrivalException("SUBCONTRACT","RECEIPT_ADJUSTED",warehouse,goods);
        arrivalException("SUBCONTRACT","RETURN_REQUIRED",warehouse,goods);
        arrivalException("PURCHASE","CLOSED",warehouse,goods);
        arrivalException("PURCHASE","PENDING_FINANCE",outside,goods);
        var actual=new com.uten.imp.features.warehouse.inbound.ProcurementArrivalControlService(
                new org.springframework.jdbc.core.JdbcTemplate(new SingleConnectionDataSource(connection,true)),mapper,
                mock(com.uten.imp.application.port.BusinessEventPublisher.class),mock(SecurityContextCurrentUser.class),
                mock(com.uten.imp.security.TxSessionVars.class),mock(com.uten.imp.application.port.FinanceReviewerEligibilityPort.class),
                mock(com.uten.imp.features.purchase.receipt.ReceiptPriceMasker.class),
                mock(com.uten.imp.common.concurrency.ProcurementMutationLocks.class));
        var scope=new WarehouseTaskScope(true,List.of(warehouse),false);
        var scopes=mock(WarehouseTaskScopePort.class);
        when(scopes.current(warehouse)).thenReturn(scope);
        var controller=new com.uten.imp.features.warehouse.inbound.WarehouseInboundController(actual,
                mock(com.uten.imp.features.purchase.receipt.PurchaseReceiptService.class),
                mock(com.uten.imp.features.subcontract.receipt.SubcontractReceiptService.class),
                mock(com.uten.imp.features.warehouse.inbound.WarehouseArrivalRegistrationService.class),
                mock(com.uten.imp.features.warehouse.inbound.WarehouseArrivalExceptionStockInBatchService.class),scopes,
                mock(com.uten.imp.application.port.WarehouseTaskRowCountPort.class));
        assertThat(controller.arrivalExceptionCount(warehouse)).containsEntry("count",3L)
                .containsEntry("PURCHASE",1L).containsEntry("SUBCONTRACT",2L);
        assertThat(actual.countWarehouseExceptions(scope)).isEqualTo(3L);
    }

    private UUID arrivalException(String type,String status,UUID warehouse,UUID goods) {
        UUID id=UUID.randomUUID();
        execute("INSERT INTO procurement_arrival_exceptions(id,order_type,status,warehouse_id,goods_id)"
                +" VALUES(:id,:type,:status,:warehouse,:goods)","id",id,"type",type,
                "status",status,"warehouse",warehouse,"goods",goods);
        return id;
    }

    @Test void inboundBadgeCountsRepeatGoodsOnOneOrderAndKeepTheSamePhysicalWarehouseScope() {
        UUID warehouse=UUID.randomUUID(),outside=UUID.randomUUID(),expectation=UUID.randomUUID();
        UUID goods=UUID.randomUUID(),hiddenGoods=UUID.randomUUID();
        execute("INSERT INTO goods(id,code,name,owning_warehouse_id) VALUES(:id,'BADGE-VISIBLE','Visible purchase line',:warehouse)",
                "id",goods,"warehouse",warehouse);
        execute("INSERT INTO goods(id,code,name,owning_warehouse_id) VALUES(:id,'BADGE-HIDDEN','Outside purchase line',:warehouse)",
                "id",hiddenGoods,"warehouse",outside);
        execute("INSERT INTO inbound_expectations(id,order_type,order_id,bill_no_snapshot,status,created_at)"
                +" VALUES(:id,'PURCHASE',:order,'BADGE-TWO-LINES','OPEN',now())",
                "id",expectation,"order",UUID.randomUUID());
        for(int line=1;line<=4;line++) execute("INSERT INTO inbound_expectation_items(id,expectation_id,order_item_id,line_no,goods_id,ordered_qty,accepted_qty,unit_rate)"
                +" VALUES(:id,:expectation,:orderItem,:line,:goods,5,:accepted,1)",
                "id",UUID.randomUUID(),"expectation",expectation,"orderItem",UUID.randomUUID(),
                "line",line,"goods",line==3?hiddenGoods:goods,"accepted",line==4?5:0);
        var scope=new WarehouseTaskScope(true,List.of(warehouse),false);
        var physical=service(Set.of("warehouse_inbound:view"),scope,false);
        var first=physical.list(new Filter("PURCHASE","","Visible purchase",null,null,null,warehouse,1,1));
        assertThat(first.total()).isEqualTo(2);
        assertThat(first.totalPages()).isEqualTo(2);
        assertThat(first.facets().get("billNo")).singleElement().satisfies(facet->assertThat(facet.count()).isEqualTo(2));
        assertThat(physical.list(new Filter("PURCHASE","","Outside",null,null,null,warehouse,1,20)).total()).isZero();
        assertThat(taskRowCounts().inboundExpectations(scope)).containsEntry("PURCHASE",2L).containsEntry("SUBCONTRACT",0L);
        assertThat(taskRowCounts().inboundExpectations(WarehouseTaskScope.ALL)).containsEntry("PURCHASE",3L);
        assertThat(taskRowCounts().inboundExpectations(WarehouseTaskScope.NONE)).containsEntry("PURCHASE",0L);
        assertThat(taskRowCounts().finishedInbound(WarehouseTaskScope.NONE)).isZero();
        assertThat(taskRowCounts().productionReturn(WarehouseTaskScope.NONE)).isZero();
        assertThat(taskRowCounts().finishedInbound(scope)).isZero();
        assertThat(taskRowCounts().productionReturn(scope)).isZero();
    }

    private WarehouseTaskRowCountService taskRowCounts() {
        var access=mock(ProductionStockTaskAccessPolicy.class);
        when(access.canAccessWarehouseTasks()).thenReturn(true);
        return new WarehouseTaskRowCountService(jdbc,access,mock(SecurityContextCurrentUser.class));
    }

    @Test void productionReturnBadgesUseVisiblePhysicalLinesInsteadOfRequestHeaders() {
        UUID document=UUID.randomUUID(),warehouse=UUID.randomUUID(),outside=UUID.randomUUID();
        stock(document,"WDRAW","TWO-RETURN-LINES","2026-10-12",null);
        execute("INSERT INTO production_material_return_requests(id) VALUES(:id)","id",document);
        for(int line=1;line<=3;line++) execute("INSERT INTO stock_document_items(id,doc_id,line_no,warehouse_id,qty,is_deleted)"
                +" VALUES(:id,:document,:line,:warehouse,2,FALSE)","id",UUID.randomUUID(),
                "document",document,"line",line,"warehouse",line==3?outside:warehouse);
        var scope=new WarehouseTaskScope(true,List.of(warehouse),false);
        var page=service(Set.of("stock_doc:view"),scope,true).list(new Filter("RETURN","","",null,null,null,warehouse,1,20));
        assertThat(page.total()).isEqualTo(2);
        assertThat(taskRowCounts().productionReturn(scope)).isEqualTo(page.total());
        assertThat(taskRowCounts().productionReturn(WarehouseTaskScope.ALL)).isEqualTo(3);
        execute("UPDATE stock_documents SET status=1 WHERE id=:id","id",document);
        assertThat(taskRowCounts().productionReturn(scope)).isZero();
    }

    private WarehouseInboundTaskCenterQueryService service(Set<String> permissions,WarehouseTaskScope scope,boolean pool) {
        return service(new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"warehouse",permissions,false,true,false),scope,pool);
    }

    private WarehouseInboundTaskCenterQueryService service(AuthUser actor,WarehouseTaskScope scope,boolean pool) {
        var current=mock(SecurityContextCurrentUser.class);
        when(current.get()).thenReturn(Optional.of(actor));
        var scopes=mock(WarehouseTaskScopePort.class);
        when(scopes.current(any())).thenReturn(scope);
        doCallRealMethod().when(scopes).withQueryScopeCache(any());
        var stock=mock(StockDocAccessPolicy.class);
        OwnerScope owner=new OwnerScope(true,Set.of());
        when(stock.scope()).thenReturn(owner);
        when(stock.nativeReadScope(anyString(),anyString(),any(OwnerScope.class))).thenReturn(new NativeReadScope("1=1",null,Set.of()));
        var production=mock(ProductionStockTaskAccessPolicy.class);
        when(production.canAccessWarehouseTasks()).thenReturn(pool);
        return new WarehouseInboundTaskCenterQueryService(jdbc,mapper,current,scopes,stock,production);
    }

    private static Filter filter(String source,String status,int page,int size) { return new Filter(source,status,"",null,null,null,null,page,size); }
    private void receipt(String table,UUID id,String billNo,String date,UUID warehouse) {
        execute("INSERT INTO "+table+"(id,bill_no,bill_date,status,is_closed,is_deleted,warehouse_id,created_at)"
                +" VALUES(:id,:bill,CAST(:date AS date),0,FALSE,FALSE,:warehouse,now())",
                "id",id,"bill",billNo,"date",date,"warehouse",warehouse);
    }
    private void stock(UUID id,String type,String billNo,String date,UUID report) {
        execute("INSERT INTO stock_documents(id,doc_type,bill_no,bill_date,status,is_closed,is_deleted,source_daily_report_id,created_at)"
                +" VALUES(:id,:type,:bill,CAST(:date AS date),0,FALSE,FALSE,:report,now())",
                "id",id,"type",type,"bill",billNo,"date",date,"report",report);
    }
    @Test void malformedFixtureBindingsFailBeforeAnyDatabaseWrite() {
        assertThatThrownBy(() -> execute("SELECT 1", "missingValue"))
                .isInstanceOf(IllegalArgumentException.class).hasMessage("SQL fixture parameters must be key/value pairs");
    }

    private void execute(String sql,Object... parameters) {
        if(parameters.length%2!=0) throw new IllegalArgumentException("SQL fixture parameters must be key/value pairs");
        MapSqlParameterSource values=new MapSqlParameterSource();
        for(int index=0;index+1<parameters.length;index+=2) values.addValue((String)parameters[index],parameters[index+1]);
        jdbc.update(sql,values);
    }
}
