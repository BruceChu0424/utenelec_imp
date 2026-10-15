package com.uten.imp.features.stock;

import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.common.web.TableFacets;
import com.uten.imp.features.stock.dto.StockDocQueryFilter;
import com.uten.imp.security.OwnerVisibility.OwnerScope;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import com.uten.imp.support.MigratedProjectionSchema;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.hibernate.cfg.Configuration;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.data.jpa.repository.support.JpaRepositoryFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.springframework.test.util.ReflectionTestUtils;

import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** Executes the service's exact JPA predicate on migrated read facts, without claiming command success. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class StockDocumentLifecyclePostgresTest {
    @Test
    void issuedRequestSliceDoesNotHideTheRemainingFutureInstructionAndFullyIssuedDrawIsHistory() throws Exception {
        try(var database=MigratedSchemaBaseline.openDatabase("stock_instruction_lifecycle");var connection=database.openConnection()) {
            connection.setAutoCommit(false);
            try(var statement=connection.createStatement()) {
                statement.execute("CREATE SCHEMA stock_instruction_oracle");
                statement.execute("SET search_path=stock_instruction_oracle,public");
                statement.execute("SET jit=off");
            }
            MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(connection,"stock_documents","stock_document_items",
                    "warehouses","production_planning_package_documents","production_execution_segment_events",
                    "production_material_stock_postings","production_planning_package_document_items","plan_draw_links");
            var source=new SingleConnectionDataSource(connection,true);
            var jdbc=new JdbcTemplate(source);
            UUID warehouse=UUID.randomUUID(),future=UUID.randomUUID(),finished=UUID.randomUUID();
            jdbc.update("INSERT INTO warehouses(id,name,is_line_side) VALUES(?,'实际仓',FALSE)",warehouse);
            draw(jdbc,future,warehouse,"FUTURE",4,2,1,false);
            draw(jdbc,finished,warehouse,"FINISHED",2,2,2,true);
            assertThat(jdbc.queryForObject("SELECT fn_production_draw_pending(?)",Boolean.class,future)).isFalse();
            assertThat(jdbc.queryForObject("SELECT fn_production_draw_requested(?)",Boolean.class,future)).isTrue();
            var configuration=new Configuration().addAnnotatedClass(StockDocument.class).addAnnotatedClass(StockDocumentItem.class);
            configuration.getProperties().put("hibernate.connection.datasource",source);
            configuration.setProperty("hibernate.hbm2ddl.auto","none");
            configuration.setProperty("hibernate.show_sql","false");
            try(var factory=configuration.buildSessionFactory();var em=factory.createEntityManager()) {
                em.getTransaction().begin();
                var repository=new JpaRepositoryFactory(em).getRepository(StockDocumentRepository.class);
                var access=mock(StockDocAccessPolicy.class);
                when(access.scope()).thenReturn(new OwnerScope(true,Set.of()));
                when(access.readablePredicate(any(jakarta.persistence.criteria.Root.class),
                        any(jakarta.persistence.criteria.CriteriaBuilder.class),anyString(),any(OwnerScope.class))).thenAnswer(call->
                        call.getArgument(1,jakarta.persistence.criteria.CriteriaBuilder.class).conjunction());
                var service=StockDocToWarehouseFilterTest.service(repository,access,mock(ProductionStockTaskAccessPolicy.class));
                var active=spec(service,"ACTIVE",null);
                var history=spec(service,"HISTORY",null);
                var page=repository.findAll(active,PageRequest.of(0,1,Sort.by("billNo")));
                assertThat(page.getTotalElements()).isEqualTo(1);
                assertThat(page.getContent()).extracting(StockDocument::getId).containsExactly(future);
                assertThat(repository.findAll(spec(service,"ACTIVE",(short)1))).extracting(StockDocument::getId).containsExactly(future);
                assertThat(repository.findAll(history)).extracting(StockDocument::getId).containsExactly(finished);
                assertThat(TableFacets.groupCount(em,StockDocument.class,active,"billNo"))
                        .singleElement().satisfies(bucket->assertThat(bucket.get("value")).isEqualTo("FUTURE"));
                assertThat(TableFacets.groupCount(em,StockDocument.class,history,"billNo"))
                        .singleElement().satisfies(bucket->assertThat(bucket.get("value")).isEqualTo("FINISHED"));
                em.getTransaction().rollback();
            }
            connection.rollback();
        }
    }

    private static void draw(JdbcTemplate jdbc,UUID id,UUID warehouse,String bill,int total,int issued,int progress,boolean closed) {
        UUID item=UUID.randomUUID(),segment=UUID.randomUUID();
        jdbc.update("""
                INSERT INTO stock_documents(id,doc_type,bill_no,bill_date,status,issue_status,is_closed,is_deleted,warehouse_id)
                VALUES(?,'DRAW',?,'2026-10-14',1,?,?,FALSE,?)
                """,id,bill,progress,closed,warehouse);
        jdbc.update("""
                INSERT INTO stock_document_items(id,doc_id,qty,issued_qty,is_deleted)
                VALUES(?,?,?,?,FALSE)
                """,item,id,total,issued);
        jdbc.update("INSERT INTO production_planning_package_documents(document_id,document_type,execution_segment_id) VALUES(?,'DRAW',?)",id,segment);
        jdbc.update("""
                INSERT INTO production_execution_segment_events(execution_segment_id,action,draw_document_ids,draw_item_quantities)
                VALUES(?,'DRAW_REQUEST',ARRAY[CAST(? AS uuid)],jsonb_build_object(CAST(? AS text),?))
                """,segment,id,item,issued);
    }

    private static Specification<StockDocument> spec(StockDocService service,String view,Short progress) {
        var filter=new StockDocQueryFilter("DRAW",null,null,null,null,null,null,progress,null,null,
                WarehouseTaskScope.ALL,null,false,null,view);
        return ReflectionTestUtils.invokeMethod(service,"docSpec",filter,false,false);
    }
}
