package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.UtenImpApplication;
import com.uten.imp.features.purchase.common.ProcurementReferencePricePolicyService;
import org.springframework.boot.WebApplicationType;
import org.springframework.boot.builder.SpringApplicationBuilder;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Primary;
import org.springframework.beans.factory.config.BeanPostProcessor;
import org.springframework.test.util.ReflectionTestUtils;
import jakarta.persistence.EntityManager;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import javax.sql.DataSource;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.*;

import static org.assertj.core.api.Assertions.*;

/** Genuine1032 public commands with a versioned persistence/price-policy transport.
 * No result/status mock, fake column, disabled validator or business arithmetic copy.
 * Its context must close before applying1033 and booting the ordinary current app. */
final class HistoricalSubcontract1032Context {
    private HistoricalSubcontract1032Context() { }
    static ConfigurableApplicationContext open(DataSource source,String jdbcUrl,String username,String password)throws Exception {
        if(!jdbcUrl.matches("jdbc:postgresql://(?:localhost|127[.]0[.]0[.]1):[0-9]+/[^?]+(?:[?].*)?"))
            throw new IllegalArgumentException("Historical commands require this task's loopback PostgreSQL");
        var db=new JdbcTemplate(source);requireOriginalCatalog(db);String guards=guardDefinitions(db);
        Path storage=Files.createTempDirectory("uten-subcontract-original1032-");
        var args=new ArrayList<>(List.of("--spring.profiles.active=dev","--server.address=127.0.0.1","--server.port=0",
                "--spring.datasource.url="+jdbcUrl,"--spring.datasource.username="+username,"--spring.datasource.password="+password,
                "--spring.flyway.url="+jdbcUrl,"--spring.flyway.user="+username,"--spring.flyway.password="+password,
                "--spring.flyway.target=1032","--spring.flyway.validate-on-migrate=true","--spring.flyway.clean-disabled=true",
                "--spring.flyway.baseline-on-migrate=false","--spring.jpa.hibernate.ddl-auto=validate",
                "--spring.jpa.mapping-resources=finance/orm-schema1032.xml","--uten.tests.original-schema=1032",
                "--uten.jwt.secret="+FullChainEndToEndTest.SHARED_JWT_SECRET,
                "--uten.crypto.pgp-master-key="+FullChainEndToEndTest.SHARED_PGP_KEY,"--uten.crypto.hmac-key="+FullChainEndToEndTest.SHARED_HMAC_KEY,
                "--uten.bootstrap.admin-login="+FullChainEndToEndTest.SHARED_ADMIN_LOGIN,"--uten.bootstrap.admin-password="+FullChainEndToEndTest.SHARED_ADMIN_PASSWORD,
                "--uten.audit.retention.enabled=false","--uten.reporting.materialized-view-refresh.enabled=false",
                "--uten.production.readiness-reconcile.enabled=false","--uten.inventory.value-work.enabled=false",
                "--uten.read-summary.compaction-enabled=false",
                "--uten.features.goods-owner-scope-enabled=false","--uten.storage.provider=local","--uten.storage.uploads-enabled=true",
                "--uten.storage.malware-scan.provider=test-only","--uten.storage.local-dir="+storage,"--uten.policy-intelligence.enabled=false"));
        var context=new SpringApplicationBuilder(UtenImpApplication.class,OriginalPriceTransport.class)
                .web(WebApplicationType.SERVLET).run(args.toArray(String[]::new));
        try {
            requireOriginalCatalog(context.getBean(JdbcTemplate.class));
            assertThat(guardDefinitions(db)).as("Historical transport cannot change any installed DB guard").isEqualTo(guards);
            return context;
        } catch(RuntimeException|Error failure) {context.close();throw failure;}
    }
    static void requireOriginalCatalog(JdbcTemplate db) {
        assertThat(db.queryForObject("SELECT version FROM flyway_schema_history WHERE success AND version IS NOT NULL ORDER BY installed_rank DESC LIMIT 1",String.class)).isEqualTo("1032");
        assertThat(db.queryForObject("SELECT to_regprocedure('public.fn_procurement_reference_price(numeric,numeric)') IS NOT NULL",Boolean.class)).isTrue();
        assertThat(db.queryForObject("SELECT to_regprocedure('public.fn_procurement_reference_price_matches(jsonb)') IS NULL",Boolean.class)).isTrue();
        assertThat(db.queryForObject("SELECT to_regprocedure('public.fn_adopt_procurement_reference_price_policy(text,uuid,jsonb)') IS NULL",Boolean.class)).isTrue();
        assertThat(db.queryForObject("SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name IN('purchase_order_items','subcontract_order_items') AND column_name='reference_price_precision_policy'",Integer.class)).isZero();
        for(var entry:Map.of("subcontract_receipt_items",List.of("quantity_adoption_version","quantity_precision_policy","adopted_base_qty","material_consumption_version"),
                "subcontract_material_return_items",List.of("quantity_adoption_version","quantity_precision_policy","adopted_base_qty"),
                "sales_order_items",List.of("delivery_plan","delivery_bom_snapshot"),
                "finance_receipt_lines",List.of("requested_sales_order_id","applied_source_doc_type","applied_source_doc_id","applied_source_doc_no"),
                "finance_receipts",List.of("order_selection_version")).entrySet())
            for(String column:entry.getValue())assertThat(db.queryForObject("SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name=? AND column_name=?",Integer.class,entry.getKey(),column)).isZero();
    }
    static String guardDefinitions(JdbcTemplate db) {
        return db.queryForObject("SELECT jsonb_build_object('triggers',(SELECT jsonb_agg(jsonb_build_array(c.relname,t.tgname,t.tgenabled,pg_get_triggerdef(t.oid)) ORDER BY c.relname,t.tgname) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid WHERE c.relnamespace='public'::regnamespace AND NOT t.tgisinternal),'functionsSha256',(SELECT encode(digest(string_agg(p.oid::regprocedure::text||E'\n'||pg_get_functiondef(p.oid),E'\n' ORDER BY p.oid::regprocedure::text),'sha256'),'hex') FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.prokind IN('f','p')),'constraints',(SELECT jsonb_agg(jsonb_build_array(c.relname,k.conname,pg_get_constraintdef(k.oid)) ORDER BY c.relname,k.conname) FROM pg_constraint k JOIN pg_class c ON c.oid=k.conrelid WHERE c.relnamespace='public'::regnamespace))::text",String.class);
    }
    @TestConfiguration(proxyBeanMethods=false)
    @org.springframework.boot.autoconfigure.condition.ConditionalOnProperty(name="uten.tests.original-schema",havingValue="1032")
    static class OriginalPriceTransport {
        @Bean static BeanPostProcessor original1032NativeSqlTransport() {
            return new BeanPostProcessor() {
                @Override public Object postProcessBeforeInitialization(Object bean,String beanName) {
                    if(bean instanceof DataSource source)return HistoricalSubcontract1032SqlTransport.dataSource(source);
                    if(bean instanceof com.uten.imp.features.subcontract.receipt.SubcontractReceiptService) {
                        var actual=(EntityManager)Objects.requireNonNull(ReflectionTestUtils.getField(bean,"em"));
                        ReflectionTestUtils.setField(bean,"em",HistoricalSubcontract1032SqlTransport.entityManager(actual));
                    }
                    return bean;
                }
            };
        }
        @Bean @Primary ProcurementReferencePricePolicyService original1032PricePolicy(JdbcTemplate db,ObjectMapper json) {
            return new OriginalReferencePrice(db,json);
        }
    }
    /** V760's actual verifier, before a saved-policy column/owner existed.
     * Current order/service and DB commercial guards still own every amount and approval. */
    static class OriginalReferencePrice extends ProcurementReferencePricePolicyService {
        private final JdbcTemplate db;
        OriginalReferencePrice(JdbcTemplate db,ObjectMapper json){super(db,json);this.db=db;}
        @Override @Transactional(propagation=Propagation.MANDATORY)
        public void adoptSavedOrder(String kind,UUID order){requireSavedOrder(kind,order);}
        @Override @Transactional(propagation=Propagation.MANDATORY,readOnly=true)
        public void requireSavedOrder(String kind,UUID order) {
            requireOriginalCatalog(db);
            String table=switch(kind){case "PURCHASE"->"purchase_order_items";case "SUBCONTRACT"->"subcontract_order_items";default->throw new IllegalArgumentException("Unsupported original order owner");};
            Boolean verified=db.queryForObject("SELECT count(*)>0 AND COALESCE(bool_and(total_amount_input IS NULL OR price IS NOT DISTINCT FROM fn_procurement_reference_price(total_amount_input,qty)),false) FROM "+table+" WHERE order_id=? AND NOT is_deleted",Boolean.class,order);
            if(!Boolean.TRUE.equals(verified))throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED,"Historical original reference price does not match its installed V760 authority");
        }
    }
}
