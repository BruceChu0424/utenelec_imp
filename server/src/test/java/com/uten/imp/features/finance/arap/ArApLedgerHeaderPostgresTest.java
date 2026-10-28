package com.uten.imp.features.finance.arap;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.arap.dto.ArApLedgerQueryFilter;
import com.uten.imp.features.master.client.Client;
import com.uten.imp.features.master.clientcategory.ClientCategory;
import com.uten.imp.features.master.supplier.Supplier;
import com.uten.imp.features.master.suppliercategory.SupplierCategory;
import com.uten.imp.features.master.currency.Currency;
import com.uten.imp.support.MigratedProjectionSchema;
import jakarta.persistence.EntityManager;
import java.math.BigDecimal;
import java.util.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.data.jpa.repository.support.JpaRepositoryFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.persistenceunit.PersistenceManagedTypes;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ArApLedgerHeaderPostgresTest {
    private static final org.testcontainers.postgresql.PostgreSQLContainer PG=new org.testcontainers.postgresql.PostgreSQLContainer("postgres:16-alpine");
    private static JdbcTemplate db;private static jakarta.persistence.EntityManagerFactory emf;
    private EntityManager em;private ArApLedgerQueryService service;private UUID currency,client,supplier;
    @BeforeAll static void start(){
        PG.start();var source=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());db=new JdbcTemplate(source);
        MigratedProjectionSchema.createCurrentTables(db,"ar_ap_ledger","ar_ap_source_refs","clients","client_categories","suppliers","supplier_categories","currencies");
        var factory=new LocalContainerEntityManagerFactoryBean();factory.setDataSource(source);factory.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        factory.setManagedTypes(PersistenceManagedTypes.of(ArApLedger.class.getName(),ArApSourceRef.class.getName(),
                Client.class.getName(),ClientCategory.class.getName(),Supplier.class.getName(),SupplierCategory.class.getName(),Currency.class.getName()));
        factory.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto","none"));factory.afterPropertiesSet();emf=factory.getObject();
    }
    @AfterAll static void stop() {
        if (emf != null) {
            emf.close();
        }
        PG.stop();
    }
    @BeforeEach void prepare(){
        db.execute("TRUNCATE ar_ap_ledger,ar_ap_source_refs,clients,suppliers,currencies");
        currency=UUID.randomUUID();client=UUID.randomUUID();supplier=UUID.randomUUID();
        db.update("INSERT INTO currencies(id,code,name,is_deleted,is_base_currency,auto_created) VALUES(?,'USD','美元历史币种',true,false,false)",currency);
        db.update("INSERT INTO clients(id,name,is_deleted,version,access_version,code_managed) VALUES(?,'客户%_快照',true,0,0,false)",client);
        db.update("INSERT INTO suppliers(id,name,is_deleted,version,code_managed) VALUES(?,'供应商%_快照',true,0,false)",supplier);
        em=emf.createEntityManager();service=new ArApLedgerQueryService(new JpaRepositoryFactory(em).getRepository(ArApLedgerRepository.class),em);
    }
    @AfterEach void close(){if(em!=null)em.close();}
    @Test void fullScopeTypedHeadersRetainGroupedSourceEvidenceAndAuthoritativeReadFacts(){
        UUID first=seed("AR","A","2026-10-01","2026-11-01","90071992547409.1234","EXACT_SOURCE",(short)6);
        UUID second=seed("AR","B","2026-10-31","2026-11-30","90071992547409.1234","EXACT_SOURCE",(short)6);
        seed("AR","OUTSIDE","2026-11-01","2026-12-01","90071992547409.1234","EXACT_SOURCE",(short)6);
        seed("AP","AP","2026-10-15","2026-11-15","90071992547409.1234","EXACT_SOURCE",(short)6);
        seed("AR","NULL","2026-10-15",null,null,null,null);
        for(UUID id:List.of(first,second)){reference(id,"SO%_A",1);reference(id,"SO-B",2);reference(id,"UNMATCHED-EVIDENCE",3);}
        var columns=new LinkedHashMap<>(Map.of("search.billDate","2026-10","search.dueDate","2026-11",
                "search.amountOriginal",">=90071992547409.1234","search.party","客户%_","search.salesOrderNos","SO%_A SO-B",
                "search.settlementStyleLegacy","月结","search.legacySourceResolution","唯一","openItemKind","CUSTOMER_PREPAYMENT"));
        var filter=filter("AR",currency).withColumns(columns);
        var page=service.list(filter,1,1,"billNo","asc");
        assertThat(page.getTotal()).isEqualTo(2);assertThat(page.getTotalPages()).isEqualTo(2);
        var item=page.getItems().getFirst();assertThat(item.getId()).isEqualTo(first);
        assertThat(item.getSalesOrderNos()).containsExactly("SO%_A","SO-B","UNMATCHED-EVIDENCE");
        assertThat(item.getAuthoritativeSalesOrderId()).isNull();assertThat(item.getOpenItemKind()).isEqualTo("CUSTOMER_PREPAYMENT");
        assertThat(item.getLegacySourceResolution()).containsExactlyEntriesOf(Map.of("status","EXACT_SOURCE"));
        assertThat(item.getSettlementStyleLabel()).isEqualTo("月结");
        assertThat(item.getAmountOriginalExact()).isEqualTo("90071992547409.1234");
        assertThat(item.getPrepaymentAppliedOriginalExact()).isEqualTo("-12.3456");
        assertThat(service.list(filter,2,1,"billNo","asc").getItems()).extracting(value->value.getId()).containsExactly(second);
        assertThat(service.detail(first).getOpenItemKind()).isEqualTo("CUSTOMER_PREPAYMENT");
        var facets=service.facets(filter);assertThat(facets.get("billNo")).hasSize(2);
        assertThat(facets.get("currency")).anySatisfy(value->{assertThat(value.get("value")).isEqualTo(currency.toString());assertThat(value.get("label")).isEqualTo("美元历史币种");});
        assertThat(service.facets(new ArApLedgerQueryFilter(null,"AR",null,null,null,null,currency,null,null,null,null,null,"NO-SUCH-BILL",null).withColumns(columns)).get("billNo")).hasSize(2);
        columns.put("search.salesOrderNos","SOXA");assertThat(service.list(filter("AR",currency).withColumns(columns),1,20,null,null).getTotal()).isZero();
    }
    @Test void apOffsetsAndUnknownValuesNeverBecomeCustomerPrepaymentsOrZero(){
        seed("AP","AP","2026-10-15",null,"10.0000",null,(short)99);
        seed("AR","UNKNOWN","2026-10-15",null,null,null,null);
        var ap=service.list(filter("AP",currency).withColumns(Map.of("search.party","供应商%_","settlementStyleLegacy","UNSET","legacySourceResolution","UNSET")),1,20,null,null);
        assertThat(ap.getItems()).hasSize(1);assertThat(ap.getItems().getFirst().getPrepaymentAppliedOriginalExact()).isNull();
        assertThat(ap.getItems().getFirst().getSettlementStyleLabel()).isEqualTo("未设置");
        assertThat(service.list(filter("AR",currency).withColumns(Map.of("search.amountOriginal","!=0")),1,20,null,null).getTotal()).isZero();
        assertThat(service.list(filter("AR",null).withColumns(Map.of("search.amountBalance",">0")),1,20,null,null).getTotal()).isEqualTo(1);
    }
    @Test void monetaryScopeIsCheckedBeforeParsingAndBeforeAnyRepositoryAccess(){
        var repo=mock(ArApLedgerRepository.class);var manager=mock(EntityManager.class);var guarded=new ArApLedgerQueryService(repo,manager);
        assertThatThrownBy(()->guarded.list(filter(null,null).withColumns(Map.of("search.amountOriginal","NaN")),1,20,null,null)).isInstanceOf(ApiException.class).hasMessageContaining("选择币种");
        assertThatThrownBy(()->guarded.list(filter(null,null),1,20,"amountOriginal","asc")).isInstanceOf(ApiException.class).hasMessageContaining("选择币种");
        assertThatThrownBy(()->guarded.facets(filter("AP",currency).withColumns(Map.of("search.prepaymentAppliedOriginal",">0")))).isInstanceOf(ApiException.class).hasMessageContaining("只适用于应收");
        verifyNoInteractions(repo,manager);
    }
    private ArApLedgerQueryFilter filter(String direction,UUID unit){return new ArApLedgerQueryFilter(null,direction,null,null,null,null,unit,null,null,null,null,null,null,null);}
    private UUID seed(String direction,String number,String date,String due,String original,String resolution,Short style){
        UUID id=UUID.randomUUID();db.update("""
            INSERT INTO ar_ap_ledger(id,direction,business_type,open_item_kind,source_doc_type,source_doc_no,bill_no,bill_date,due_date,
             client_id,supplier_id,currency_id,exchange_rate,amount_original,amount_original_local,amount_settled,amount_balance,
             amount_received_original,amount_received_local,amount_write_off_original,amount_write_off_local,amount_offset_original,
             amount_offset_local,amount_balance_original,is_settled,status,is_deleted,settlement_style_legacy,legacy_source_resolution,remark)
            VALUES(?,?,'DIRECT','CUSTOMER_PREPAYMENT','DIRECT_RECEIPT',?,?,?::date,?::date,?,?,?,1.234567,?,20,0,20,
             NULL,0,NULL,0,-12.3456,-15.1234,NULL,false,1,false,?,?::jsonb,'备注%_原始快照')
            """,id,direction,"SOURCE-"+number,number,date,due,"AR".equals(direction)?client:null,"AP".equals(direction)?supplier:null,currency,
                original==null?null:new BigDecimal(original),style,resolution==null?null:"{\"status\":\""+resolution+"\",\"privateEvidence\":\"detail-only\"}");return id;
    }
    private void reference(UUID ledger,String number,int sequence){db.update("INSERT INTO ar_ap_source_refs(id,ledger_id,source_type,source_id,source_no,source_sequence,amount_original,amount_local) VALUES(?,?,'SALES_ORDER',?,?,?,0,0)",UUID.randomUUID(),ledger,UUID.randomUUID(),number,sequence);}
}
