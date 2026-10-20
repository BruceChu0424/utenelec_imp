package com.uten.imp.features.notice;

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
        db.execute("""
                DROP SCHEMA public CASCADE; CREATE SCHEMA public;
                CREATE TABLE users(id uuid,employee_id uuid,status text,is_deleted boolean DEFAULT FALSE);
                CREATE TABLE employees(id uuid,department_id uuid,status text,is_deleted boolean DEFAULT FALSE);
                CREATE TABLE departments(id uuid,parent_id uuid,manager_id uuid,is_deleted boolean DEFAULT FALSE);
                CREATE TABLE employee_secondary_departments(employee_id uuid,department_id uuid);
                CREATE TABLE production_plans(id uuid,status int,is_deleted boolean DEFAULT FALSE,is_closed boolean DEFAULT FALSE,
                    is_stopped boolean DEFAULT FALSE,is_canceled boolean DEFAULT FALSE,material_analysis_id uuid,material_analysis_item_id uuid);
                CREATE TABLE production_execution_segments(id uuid,plan_id uuid,status text,is_deleted boolean DEFAULT FALSE);
                CREATE TABLE stock_documents(id uuid,warehouse_id uuid,status int,doc_type text,is_deleted boolean DEFAULT FALSE,
                    requested boolean DEFAULT TRUE,pending boolean DEFAULT TRUE);
                CREATE TABLE stock_document_items(id uuid,doc_id uuid,warehouse_id uuid,is_deleted boolean DEFAULT FALSE);
                CREATE FUNCTION fn_production_draw_pending(uuid) RETURNS boolean LANGUAGE sql AS
                    'SELECT pending FROM stock_documents WHERE id=$1';
                CREATE TABLE sales_orders(id uuid,status int,is_deleted boolean DEFAULT FALSE,is_closed boolean DEFAULT FALSE,
                    is_stopped boolean DEFAULT FALSE,finance_confirmed boolean DEFAULT TRUE,finance_rejected boolean DEFAULT FALSE,requoted_to_id uuid,source_quote_id uuid);
                CREATE TABLE sales_quotes(id uuid,maker_id uuid,status int,is_deleted boolean DEFAULT FALSE,is_closed boolean DEFAULT FALSE,
                    finance_confirmed_at timestamptz,finance_return_reason text,customer_accepted_at timestamptz,
                    customer_accepted_revision int,review_revision int);
                CREATE TABLE sales_order_items(id uuid,order_id uuid,goods_id uuid,qty numeric,shipped_qty numeric DEFAULT 0,
                    returned_qty numeric DEFAULT 0,flag_qty numeric DEFAULT 0,reserved_qty numeric DEFAULT 0,
                    planned_qty numeric DEFAULT 0,produced_qty numeric DEFAULT 0,is_deleted boolean DEFAULT FALSE);
                CREATE TABLE goods(id uuid,is_deleted boolean DEFAULT FALSE);
                CREATE TABLE production_material_analysis_items(sales_order_item_id uuid,source_type text);
                CREATE TABLE production_plan_items(id uuid,plan_id uuid,sales_order_item_id uuid,qty numeric,is_deleted boolean DEFAULT FALSE);
                CREATE TABLE production_material_analysis_plan_links(id uuid,plan_id uuid,analysis_id uuid,analysis_item_id uuid,submitted_qty numeric);
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
        db.update("INSERT INTO sales_orders(id,status) VALUES(?,1)",order);
        db.update("INSERT INTO sales_order_items(id,order_id,goods_id,qty) VALUES(?,?,?,10)",item,order,goods);
        assertThat(visible("SALES_ORDER_APPROVED","SALES_ORDER",order)).isTrue();
        db.update("UPDATE sales_order_items SET reserved_qty=10 WHERE id=?",item);
        assertThat(visible("SALES_ORDER_APPROVED","SALES_ORDER",order)).isFalse();
        db.update("UPDATE sales_order_items SET reserved_qty=0 WHERE id=?",item);
        db.update("INSERT INTO production_material_analysis_items VALUES(?,'SALES_ORDER_ITEM')",item);
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
