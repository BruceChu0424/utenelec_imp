package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.support.MigratedProjectionSchema;
import com.uten.imp.support.MigratedSchemaBaseline;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.persistenceunit.PersistenceManagedTypes;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import static org.assertj.core.api.Assertions.assertThat;

/** Native record, count, metric and candidate queries over the current catalog's event-grain projections. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ProcurementInspectionRecordHeaderPostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private static jakarta.persistence.EntityManagerFactory emf;
    private static JdbcTemplate db;
    @BeforeAll static void setup() throws Exception {
        database=MigratedSchemaBaseline.openDatabase("iqc_record_headers");
        try(var connection=database.openConnection();var sql=connection.createStatement()) {
            sql.execute("CREATE SCHEMA iqc_record_oracle");sql.execute("SET search_path=iqc_record_oracle,public");
            MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(connection,"procurement_inspection_events","procurement_inspection_items",
                    "purchase_receipts","purchase_receipt_items","purchase_order_items","purchase_orders","subcontract_receipts",
                    "subcontract_receipt_items","subcontract_order_items","subcontract_orders","suppliers","warehouses","goods","colors","units","employees");
        }
        var source=new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword());
        var properties=new java.util.Properties();properties.setProperty("currentSchema","iqc_record_oracle,public");source.setConnectionProperties(properties);db=new JdbcTemplate(source);
        var factory=new LocalContainerEntityManagerFactoryBean();factory.setDataSource(source);factory.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        factory.setManagedTypes(PersistenceManagedTypes.of());factory.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto","none"));factory.afterPropertiesSet();emf=factory.getObject();
    }
    @AfterAll static void close() throws Exception { if(emf!=null)emf.close();if(database!=null)database.close(); }
    @Test void ordinaryHeadersKeepEventEffectChineseDayAndExactNumbersBeforeCountMetricsAndPages() {
        UUID receipt=UUID.randomUUID(),supplier=UUID.randomUUID(),goods=UUID.randomUUID(),color=UUID.randomUUID(),employee=UUID.randomUUID();
        db.update("INSERT INTO suppliers(id,name) VALUES(?,'供应%_商')",supplier);
        db.update("INSERT INTO goods(id,code,name) VALUES(?,'WL%_01','盒装物料')",goods);
        db.update("INSERT INTO colors(id,name) VALUES(?,'蓝%_色')",color);
        db.update("INSERT INTO employees(id,full_name) VALUES(?,'检验%_员')",employee);
        db.update("INSERT INTO purchase_receipts(id,bill_no,bill_date,supplier_id) VALUES(?,'RECEIPT%_01','2026-10-28',?)",receipt,supplier);
        UUID first=event(receipt,goods,color,employee,"PARTIAL","12.3456","2026-10-27T16:00:00Z");
        UUID second=event(receipt,goods,color,employee,"PARTIAL","24","2026-10-28T15:59:59Z");
        event(receipt,goods,color,employee,"PARTIAL","99","2026-10-28T16:00:00Z");
        event(receipt,goods,color,employee,"REVERSED","100","2026-10-28T01:00:00Z");
        try(var em=emf.createEntityManager()) {
            var service=new ProcurementInspectionRecordQueryService(em);
            var columns=Map.of("sourceNo","RECEIPT%_","partnerName","供应%_", "goodsName","盒装", "goodsCode","WL%_",
                    "colorName","蓝%_", "inspectorName","检验%_", "passQty",">=12", "failQty","0", "decidedAt","2026-10-28");
            var page1=service.list("PASS","",null,null,"PURCHASE","ACTIVE",null,1,1,"passQty","desc",null,null,columns);
            var page2=service.list("PASS","",null,null,"PURCHASE","ACTIVE",null,2,1,"passQty","desc",null,null,columns);
            assertThat(page1.total()).isEqualTo(2);
            assertThat(page1.items().getFirst().recordId()).isEqualTo(second);
            assertThat(page2.items().getFirst().recordId()).isEqualTo(first);
            assertThat(page2.items().getFirst().passQty()).isEqualByComparingTo("12.3456");
            assertThat(page1.metrics().get("ALL")).isEqualTo(2L);
            assertThat(service.facets("PASS","",null,null,"PURCHASE","ACTIVE",null,columns).get("sourceNo")).hasSize(1);
            assertThat(service.list("PASS","",null,null,"PURCHASE","EXPIRED",null,1,20,null,null,null,null,columns).total()).isEqualTo(1);
            assertThat(service.list("PASS","",null,null,null,null,null,1,20,null,null,null,null,Map.of("goodsCode","WL__")).total()).isZero();
        }
    }
    private UUID event(UUID receipt,UUID goods,UUID color,UUID employee,String status,String qty,String at) {
        UUID inspection=UUID.randomUUID(),event=UUID.randomUUID();
        db.update("INSERT INTO procurement_inspection_items(id,receipt_type,receipt_id,receipt_item_id,goods_id,color_id,status,received_base_qty,passed_base_qty,failed_base_qty) VALUES(?,'PURCHASE',?,?,?,?,?,200,100,0)",inspection,receipt,UUID.randomUUID(),goods,color,status);
        db.update("INSERT INTO procurement_inspection_events(id,inspection_item_id,action,base_qty,actor_employee_id,occurred_at) VALUES(?,?,'PASS',?::numeric,?,?::timestamptz)",event,inspection,qty,employee,at);return event;
    }
}
