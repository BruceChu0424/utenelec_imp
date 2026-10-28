package com.uten.imp.features.stock;

import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.common.web.HeaderColumnFilter;
import com.uten.imp.features.stock.dto.StockDocQueryFilter;
import com.uten.imp.security.OwnerVisibility.OwnerScope;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import com.uten.imp.support.MigratedProjectionSchema;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.hibernate.cfg.Configuration;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.data.jpa.repository.support.JpaRepositoryFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class StockDocHeaderPostgresTest {
    @Test void typedDateAndReferenceHeadersKeepTheOwnerPredicateBeforeAllPagesAndFacets() throws Exception {
        try(var database=MigratedSchemaBaseline.openDatabase("stock_document_headers");var connection=database.openConnection()) {
            connection.setAutoCommit(false);
            try(var statement=connection.createStatement()) {
                statement.execute("CREATE SCHEMA stock_header_oracle");statement.execute("SET search_path=stock_header_oracle,public");statement.execute("SET jit=off");
            }
            MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(connection,"stock_documents","stock_document_items",
                    "warehouses","departments","employees","positions","production_planning_package_documents",
                    "production_execution_segment_events","production_material_stock_postings","production_planning_package_document_items","plan_draw_links");
            var source=new SingleConnectionDataSource(connection,true);var db=new JdbcTemplate(source);
            UUID owner=UUID.randomUUID(),parent=UUID.randomUUID(),from=UUID.randomUUID(),to=UUID.randomUUID();
            db.update("INSERT INTO warehouses(id,name,is_deleted) VALUES(?,'主仓',false),(?,'成品仓',false)",parent,to);
            db.update("INSERT INTO warehouses(id,name,parent_id,is_deleted) VALUES(?,'原料%_仓',?,false)",from,parent);
            UUID first=document(db,owner,from,to,"HEADER-NEAR","2026-10-01");
            document(db,owner,from,to,"HEADER","2026-10-28");
            document(db,UUID.randomUUID(),from,to,"HEADER-SECRET","2026-10-28");
            document(db,owner,to,from,"HEADER-WRONG-WAREHOUSE","2026-10-28");
            var configuration=new Configuration().addAnnotatedClass(StockDocument.class).addAnnotatedClass(StockDocumentItem.class)
                    .addAnnotatedClass(com.uten.imp.features.master.warehouse.Warehouse.class)
                    .addAnnotatedClass(com.uten.imp.features.org.department.Department.class)
                    .addAnnotatedClass(com.uten.imp.features.org.employee.Employee.class)
                    .addAnnotatedClass(com.uten.imp.features.org.position.Position.class);
            configuration.getProperties().put("hibernate.connection.datasource",source);
            configuration.setProperty("hibernate.hbm2ddl.auto","none");configuration.setProperty("hibernate.show_sql","false");
            try(var factory=configuration.buildSessionFactory();var em=factory.createEntityManager()) {
                em.getTransaction().begin();
                var repo=new JpaRepositoryFactory(em).getRepository(StockDocumentRepository.class);
                var access=mock(StockDocAccessPolicy.class);var scope=new OwnerScope(false,Set.of(owner));
                when(access.scope()).thenReturn(scope);
                when(access.readablePredicate(any(jakarta.persistence.criteria.Root.class),any(jakarta.persistence.criteria.CriteriaBuilder.class),anyString(),any(OwnerScope.class)))
                        .thenAnswer(call->call.getArgument(1,jakarta.persistence.criteria.CriteriaBuilder.class).equal(
                                call.getArgument(0,jakarta.persistence.criteria.Root.class).get("makerId"),owner));
                var service=StockDocToWarehouseFilterTest.service(repo,access,mock(ProductionStockTaskAccessPolicy.class));
                new com.uten.imp.support.ImportedDocumentFixture().documents("stock_documents",repo::findAll).wire(service,em);
                var filter=new StockDocQueryFilter("TRANSFER","HEADER",null,null,null,null,null,null,null,null,WarehouseTaskScope.ALL,null,false)
                        .withHeaders(new HeaderColumnFilter(Map.of("search.billDate","2026-10-01..2026-10-28",
                                "search.warehouse","主仓 原料%_仓","search.toWarehouse","成品仓")));
                var one=service.list(filter,1,1,"billDate","asc");
                var two=service.list(filter,2,1,"billDate","asc");
                assertThat(one.getTotal()).isEqualTo(2);
                assertThat(one.getItems().getFirst().getId()).isEqualTo(first);
                assertThat(two.getItems().getFirst().getId()).isNotEqualTo(first);
                assertThat(service.facets(filter).get("billNo")).hasSize(2);
                assertThatThrownBy(()->service.list(filter.withHeaders(new HeaderColumnFilter(Map.of("search.department","车间"))),1,20,null,null))
                        .isInstanceOf(com.uten.imp.common.web.ApiException.class);
                UUID department=UUID.randomUUID(),draw=UUID.randomUUID(),item=UUID.randomUUID(),segment=UUID.randomUUID();
                db.update("INSERT INTO departments(id,name,is_deleted) VALUES(?,'一车间%_',false)",department);
                db.update("INSERT INTO stock_documents(id,doc_type,bill_no,bill_date,maker_id,warehouse_id,department_id,status,issue_status,is_closed,is_deleted)"
                        +" VALUES(?,'DRAW','DRAW-HEADER','2026-10-28',?,?,?,1,0,false,false)",draw,owner,from,department);
                db.update("INSERT INTO stock_document_items(id,doc_id,qty,issued_qty,is_deleted) VALUES(?,?,2,0,false)",item,draw);
                db.update("INSERT INTO production_planning_package_documents(document_id,document_type,execution_segment_id) VALUES(?,'DRAW',?)",draw,segment);
                db.update("INSERT INTO production_execution_segment_events(execution_segment_id,action,draw_document_ids,draw_item_quantities)"
                        +" VALUES(?,'DRAW_REQUEST',ARRAY[CAST(? AS uuid)],jsonb_build_object(CAST(? AS text),2))",segment,draw,item);
                var drawFilter=new StockDocQueryFilter("DRAW",null,null,null,null,null,null,null)
                        .withHeaders(new HeaderColumnFilter(Map.of("search.department","车间%_","search.billDate","2026-10")));
                assertThat(service.list(drawFilter,1,20,null,null).getItems()).extracting(value->value.getId()).containsExactly(draw);
                em.getTransaction().rollback();
            }
            connection.rollback();
        }
    }

    @Test void warehouseMoneyQueriesAreRejectedBeforeRepositoryOrDecimalParsing() {
        var repo=mock(StockDocumentRepository.class);
        var service=StockDocToWarehouseFilterTest.service(repo,mock(StockDocAccessPolicy.class),mock(ProductionStockTaskAccessPolicy.class));
        var filter=new StockDocQueryFilter("OTHER_IN",null,null,null,null,null,null,null)
                .withHeaders(new HeaderColumnFilter(Map.of("search.amountLocal","NaN")));
        assertThatThrownBy(()->service.list(filter,1,20,null,null)).isInstanceOf(com.uten.imp.common.web.ApiException.class)
                .hasMessageContaining("无权");
        assertThatThrownBy(()->service.facets(filter)).isInstanceOf(com.uten.imp.common.web.ApiException.class)
                .hasMessageContaining("无权");
        verifyNoInteractions(repo);
    }

    private static UUID document(JdbcTemplate db,UUID owner,UUID from,UUID to,String bill,String date) {
        UUID id=UUID.randomUUID();
        db.update("INSERT INTO stock_documents(id,doc_type,bill_no,bill_date,maker_id,warehouse_id,to_warehouse_id,status,issue_status,is_closed,is_deleted)"
                +" VALUES(?,'TRANSFER',?,?::date,?,?,?,0,0,false,false)",id,bill,date,owner,from,to);return id;
    }
}
