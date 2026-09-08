package com.uten.imp.features.production.analysis;

import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.InventoryDimension;
import com.uten.imp.application.port.ProductionMutationFootprintPort.WarehouseDimension;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.List;
import java.util.Properties;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;

/** Real Hibernate SQL and directed-source evidence, separate from transaction/write-chain tests. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS", matches="(?i)true")
class ProductionMutationFootprintPostgresTest {
    private static final PostgreSQLContainer<?> DATABASE = new PostgreSQLContainer<>("postgres:16-alpine");
    private static final AtomicInteger DOCUMENT_NUMBER = new AtomicInteger(810000);
    private static JdbcTemplate jdbc;
    private static EntityManagerFactory factory;
    private static EntityManager em;
    private static ProductionMutationFootprintService footprints;

    @BeforeAll
    static void start() {
        DATABASE.start();
        Flyway.configure().dataSource(DATABASE.getJdbcUrl(),DATABASE.getUsername(),DATABASE.getPassword())
                .locations("classpath:db/migration").load().migrate();
        var dataSource = new DriverManagerDataSource(DATABASE.getJdbcUrl(),DATABASE.getUsername(),DATABASE.getPassword());
        jdbc = new JdbcTemplate(dataSource);
        var builder = new LocalContainerEntityManagerFactoryBean();
        builder.setDataSource(dataSource); builder.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        builder.setPackagesToScan("com.uten.imp.features.production.fulfillment");
        var properties = new Properties(); properties.setProperty("hibernate.hbm2ddl.auto","none");
        builder.setJpaProperties(properties); builder.afterPropertiesSet();
        factory=builder.getObject(); assertThat(factory).isNotNull(); em=factory.createEntityManager();
        footprints=new ProductionMutationFootprintService(em);
    }

    @AfterAll
    static void stop() { if(em!=null)em.close();if(factory!=null)factory.close();DATABASE.stop(); }

    @Test
    void actualSupplyDimensionExpandsOnlyItsTargetsNotEveryNewLockDimension() {
        UUID unit=unit(), main=warehouse(null), childWarehouse=warehouse(main), other=warehouse(null);
        UUID product=goods(unit), material=goods(unit), sibling=goods(unit), unrelated=goods(unit);
        UUID blue=UUID.randomUUID();
        jdbc.update("INSERT INTO colors(id,code,name) VALUES (?,?,'footprint blue')",blue,"FP-C-"+blue);
        var target=analysis(main,product,unit,"ACTIVE");
        material(target,material,null,unit,"first");
        material(target,sibling,null,unit,"second");
        var unrelatedTarget=analysis(main,unrelated,unit,"ACTIVE");
        material(unrelatedTarget,sibling,null,unit,"only-extra-lock-dimension");
        var otherWarehouse=analysis(other,unrelated,unit,"ACTIVE");
        material(otherWarehouse,material,null,unit,"different-main");
        var colored=analysis(main,unrelated,unit,"ACTIVE");
        material(colored,material,blue,unit,"different-color");
        var exactClosed=analysis(other,unrelated,unit,"COMPLETED");

        var result=footprints.forInventoryChange(
                List.of(new WarehouseDimension(childWarehouse,material,null)),List.of(exactClosed.id()));

        assertThat(result.analysisIds()).containsExactlyInAnyOrder(target.id(),exactClosed.id());
        assertThat(result.analysisIds()).doesNotContain(unrelatedTarget.id(),otherWarehouse.id(),colored.id());
        assertThat(result.inventoryDimensions()).contains(new InventoryDimension(sibling,null));
        assertThat(result.mainWarehouseIds()).containsExactlyInAnyOrder(main,other);
        assertThat(result.commercialSources()).isEmpty();
    }

    @Test
    void previewAndStockDocumentIncludeCurrentBomAndDetectChangedSources() {
        UUID unit=unit(), warehouse=warehouse(null), root=goods(unit), child=goods(unit), leaf=goods(unit);
        UUID direct=UUID.randomUUID(), nested=UUID.randomUUID();
        jdbc.update("INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty,sort_order) VALUES (?,?,?,2,1)",direct,root,child);
        jdbc.update("INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty,sort_order) VALUES (?,?,?,3,1)",nested,child,leaf);
        var analysis=analysis(warehouse,root,unit,"ACTIVE");
        material(analysis,child,null,unit,"current-child");
        var result=footprints.forPreview(List.of(),List.of(),
                List.of(new WarehouseDimension(warehouse,root,null)),List.of(warehouse),List.of(analysis.id()));
        assertThat(result.inventoryDimensions()).containsExactlyInAnyOrder(
                new InventoryDimension(root,null),new InventoryDimension(child,null),new InventoryDimension(leaf,null));
        assertThat(result.analysisIds()).containsExactly(analysis.id());
        assertThat(result.mainWarehouseIds()).containsExactly(warehouse);
        assertThat(footprints.forAnalyses(List.of(analysis.id())).inventoryDimensions()).isEqualTo(result.inventoryDimensions());
        jdbc.update("UPDATE goods_bom_items SET qty=4 WHERE id=?",nested);
        var changed=footprints.forPreview(List.of(),List.of(),
                List.of(new WarehouseDimension(warehouse,root,null)),List.of(warehouse),List.of(analysis.id()));
        assertThat(changed.fingerprint()).isNotEqualTo(result.fingerprint());

        UUID doc=UUID.randomUUID(),item=UUID.randomUUID();
        String number="CR20260907"+DOCUMENT_NUMBER.incrementAndGet();
        jdbc.update("INSERT INTO stock_documents(id,doc_type,bill_no,bill_date,warehouse_id,status) VALUES (?,'FINISHED_IN',?,'2026-09-07',?,0)",doc,number,warehouse);
        jdbc.update("""
                INSERT INTO stock_document_items(id,doc_id,bill_type,bill_no,bill_date,line_no,goods_id,unit_id,unit_rate,qty,base_qty,goods_snapshot_source)
                VALUES (?,?,'FINISHED_IN',?,'2026-09-07',1,?,?,1,5,5,'MASTER_AT_SAVE')
                """,item,doc,number,child,unit);
        var document=footprints.forStockDocuments(List.of(doc));
        assertThat(document.analysisIds()).containsExactly(analysis.id());
        assertThat(document.inventoryDimensions()).contains(new InventoryDimension(leaf,null));
        jdbc.update("UPDATE stock_document_items SET qty=6,base_qty=6 WHERE id=?",item);
        assertThat(footprints.forStockDocuments(List.of(doc)).fingerprint()).isNotEqualTo(document.fingerprint());
        assertThat(jdbc.queryForObject("SELECT count(*) FROM stock_movements",Integer.class)).isZero();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM stock_balances",Integer.class)).isZero();
    }

    private static UUID unit() {
        UUID id=UUID.randomUUID();jdbc.update("INSERT INTO units(id,code,name) VALUES (?,?,'footprint piece')",id,"FP-U-"+id);return id;
    }
    private static UUID goods(UUID unit) {
        UUID id=UUID.randomUUID();jdbc.update("INSERT INTO goods(id,code,name,unit_id,code_sequence) VALUES (?,?,'footprint goods',?,(SELECT coalesce(max(code_sequence),0)+1 FROM goods))",id,"FP-G-"+id,unit);return id;
    }
    private static UUID warehouse(UUID parent) {
        UUID id=UUID.randomUUID();jdbc.update("INSERT INTO warehouses(id,code,name,parent_id) VALUES (?,?,'footprint warehouse',?)",id,"FP-W-"+id,parent);return id;
    }
    private static Analysis analysis(UUID warehouse,UUID goods,UUID unit,String status) {
        UUID id=UUID.randomUUID(),item=UUID.randomUUID();
        UUID employee=jdbc.queryForObject("SELECT id FROM employees ORDER BY id LIMIT 1",UUID.class);
        jdbc.update("INSERT INTO production_material_analyses(id,warehouse_id,status,fingerprint,initial_idempotency_key,maker_id) VALUES (?,?,?,?,?,?)",id,warehouse,status,"a".repeat(64),"footprint-"+id,employee);
        jdbc.update("INSERT INTO production_material_analysis_items(id,analysis_id,source_type,goods_id,unit_id,source_ref,source_reason,requested_qty) VALUES (?,?,'OTHER',?, ?,?,'footprint query fixture',10)",item,id,goods,unit,"FP-SOURCE-"+item);
        return new Analysis(id,item);
    }
    private static void material(Analysis analysis,UUID goods,UUID color,UUID unit,String key) {
        jdbc.update("""
                INSERT INTO production_material_analysis_materials(id,analysis_id,analysis_item_id,node_key,
                    goods_id,color_id,unit_id,depth,path,per_product_qty,required_qty,available_qty,allocated_available_qty,shortage_qty,source_suggestion)
                VALUES (gen_random_uuid(),?,?,?,?,?,?,1,?,1,10,0,0,10,'BUY')
                """,analysis.id(),analysis.item(),key,goods,color,unit,key);
    }
    private record Analysis(UUID id,UUID item) {}
}
