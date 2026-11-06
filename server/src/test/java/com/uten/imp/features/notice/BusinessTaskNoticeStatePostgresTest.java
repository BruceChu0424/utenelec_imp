package com.uten.imp.features.notice;

import com.uten.imp.support.MigratedProjectionSchema;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** Executes the actual notification projection; source quantities/state remain owned by their business projections. */
@Testcontainers
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS", matches="(?i)true")
class BusinessTaskNoticeStatePostgresTest {
    @Container static final PostgreSQLContainer DB=new PostgreSQLContainer("postgres:16-alpine");
    private JdbcTemplate db;
    private UUID user,employee;

    @BeforeEach void schema() throws Exception {
        db=new JdbcTemplate(new DriverManagerDataSource(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword()));
        db.execute("DROP SCHEMA public CASCADE; CREATE SCHEMA public");
        MigratedProjectionSchema.createCurrentColumns(db,
                "users", "employees", "departments", "employee_secondary_departments", "production_plans", "production_execution_segments", "stock_documents", "stock_document_items", "sales_orders", "sales_quotes", "sales_order_items", "goods", "production_material_analysis_items", "production_plan_items", "production_material_analysis_plan_links");
        db.execute("""
                -- Existing registered oracle controls model function outcomes, not business document fields.
                ALTER TABLE stock_documents ADD COLUMN requested boolean DEFAULT TRUE, ADD COLUMN pending boolean DEFAULT TRUE;
                ALTER TABLE sales_orders ALTER COLUMN manager_review_state SET NOT NULL;
                ALTER TABLE sales_quotes ALTER COLUMN manager_review_state SET NOT NULL;
                CREATE FUNCTION fn_production_draw_pending(uuid) RETURNS boolean LANGUAGE sql AS 'SELECT pending FROM stock_documents WHERE id=$1';
                """);
        db.execute(Files.readString(Path.of("src/main/resources/db/migration/V876__business_task_notice_scope.sql")));
        user=UUID.randomUUID(); employee=UUID.randomUUID();
        db.update("INSERT INTO employees(id,status) VALUES(?,'active')",employee);
        db.update("INSERT INTO users(id,employee_id,status) VALUES(?,?,'active')",user,employee);
    }

    @Test void requestedButFullyIssuedDrawNoLongerAdvertisesAnAction() {
        UUID draw=UUID.randomUUID();
        db.update("INSERT INTO stock_documents(id,status,doc_type,warehouse_id) VALUES(?,1,'DRAW',?)",draw,UUID.randomUUID());
        assertThat(visible("PRODUCTION_DRAW_PENDING","STOCK_DOCUMENT",draw)).isTrue();
        db.update("UPDATE stock_documents SET pending=FALSE WHERE id=?",draw);
        assertThat(db.queryForObject("SELECT requested FROM stock_documents WHERE id=?",Boolean.class,draw)).isTrue();
        assertThat(visible("PRODUCTION_DRAW_PENDING","STOCK_DOCUMENT",draw)).isFalse();
    }

    @Test void inProgressWorkshopCanReceiveFurtherMaterialsUntilTheTaskOrPlanEnds() {
        UUID plan=UUID.randomUUID(),segment=UUID.randomUUID();
        db.update("INSERT INTO production_plans(id,status) VALUES(?,1)",plan);
        db.update("INSERT INTO production_execution_segments(id,plan_id,status) VALUES(?,?,'IN_PROGRESS')",segment,plan);
        assertThat(visible("PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED","PRODUCTION_EXECUTION_SEGMENT",segment)).isTrue();
        db.update("UPDATE production_execution_segments SET status='COMPLETED' WHERE id=?",segment);
        assertThat(visible("PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED","PRODUCTION_EXECUTION_SEGMENT",segment)).isFalse();
    }

    @Test void initialPlanningHandoffStopsAfterSourceAcquisitionOrWhenDemandIsCovered() {
        UUID order=UUID.randomUUID(),item=UUID.randomUUID(),goods=UUID.randomUUID();
        db.update("INSERT INTO goods(id) VALUES(?)",goods);
        db.update("INSERT INTO sales_orders(id,status,finance_confirmed) VALUES(?,1,true)",order);
        db.update("INSERT INTO sales_order_items(id,order_id,goods_id,qty) VALUES(?,?,?,10)",item,order,goods);
        assertThat(visible("SALES_ORDER_APPROVED","SALES_ORDER",order)).isTrue();
        db.update("UPDATE sales_order_items SET reserved_qty=10 WHERE id=?",item);
        assertThat(visible("SALES_ORDER_APPROVED","SALES_ORDER",order)).isFalse();
        db.update("UPDATE sales_order_items SET reserved_qty=0 WHERE id=?",item);
        db.update("INSERT INTO production_material_analysis_items(sales_order_item_id,source_type) VALUES(?,'SALES_ORDER_ITEM')",item);
        assertThat(visible("SALES_ORDER_APPROVED","SALES_ORDER",order)).isFalse();
    }

    @Test void confirmedQuoteUsesActualCustomerAcceptanceAndDoesNotOfferAnotherConversionAfterDeletion() {
        UUID quote=UUID.randomUUID();
        db.update("INSERT INTO sales_quotes(id,maker_id,status,finance_confirmed_at,customer_accepted_revision,review_revision) VALUES(?,?,1,now(),2,2)",quote,employee);
        String event="SALES_QUOTE_FINANCE_CONFIRMED";
        String owner="{\"sales\":{\"all\":false,\"read\":[],\"write\":[\""+employee+"\"]}}";
        String convert="notice:read,sales_quote:view,sales_quote:convert,sales_order:create";
        String edit="notice:read,sales_quote:view,sales_quote:edit";
        assertThat(visible(event,"SALES_QUOTE_ACTION",quote,convert,owner)).isFalse();
        assertThat(visible(event,"SALES_QUOTE_ACTION",quote,edit,owner)).isTrue();
        db.update("UPDATE sales_quotes SET customer_accepted_at=now() WHERE id=?",quote);
        assertThat(visible(event,"SALES_QUOTE_ACTION",quote,convert,owner)).isTrue();
        assertThat(visible(event,"SALES_QUOTE_ACTION",quote,edit,owner)).isFalse();
        db.update("INSERT INTO sales_orders(id,status,is_deleted,source_quote_id) VALUES(?,0,TRUE,?)",UUID.randomUUID(),quote);
        assertThat(visible(event,"SALES_QUOTE_ACTION",quote,convert,owner)).isFalse();
    }

    private boolean visible(String event,String kind,UUID id) {
        return visible(event,kind,id,"notice:read","{}");
    }
    private boolean visible(String event,String kind,UUID id,String permissions,String scopes) {
        return Boolean.TRUE.equals(db.queryForObject("SELECT fn_notice_business_action_visible(?,?,?,?,?,?,?,?,?,?)",Boolean.class,
                user,event,kind,id,"/notice",permissions,event,event,scopes,"{}"));
    }
}
