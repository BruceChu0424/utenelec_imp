package com.uten.imp.common.web;

import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.features.finance.receipt.*;
import com.uten.imp.features.finance.payment.*;
import com.uten.imp.features.finance.expense.*;
import com.uten.imp.features.finance.other_income.*;
import com.uten.imp.features.finance.bank_transfer.*;
import com.uten.imp.security.*;
import com.uten.imp.support.MigratedProjectionSchema;
import jakarta.persistence.EntityManager;
import jakarta.persistence.criteria.Root;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;
import java.util.stream.Stream;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.persistenceunit.PersistenceManagedTypes;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;
import org.testcontainers.postgresql.PostgreSQLContainer;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Financial native lists retain owner scope and the real imported-origin function through typed columns. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class FinanceNativeHeaderPostgresTest {
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    private static JdbcTemplate db;private static jakarta.persistence.EntityManagerFactory emf;
    private EntityManager em;private static final UUID OWNER=UUID.randomUUID(),HIDDEN=UUID.randomUUID();
    record Document(String table,Class<?> entity,Class<?> service,String specification,Class<?> filter) {
        @Override public String toString(){return table;}
    }
    static Stream<Document> documents(){return Stream.of(
        new Document("finance_receipts",FinanceReceipt.class,FinanceReceiptService.class,"receiptSpec",com.uten.imp.features.finance.receipt.dto.FinanceReceiptQueryFilter.class),
        new Document("finance_payments",FinancePayment.class,FinancePaymentService.class,"paymentSpec",com.uten.imp.features.finance.payment.dto.FinancePaymentQueryFilter.class),
        new Document("finance_expenses",FinanceExpense.class,FinanceExpenseService.class,"expenseSpec",com.uten.imp.features.finance.expense.dto.FinanceExpenseQueryFilter.class),
        new Document("finance_other_incomes",FinanceOtherIncome.class,FinanceOtherIncomeService.class,"incomeSpec",com.uten.imp.features.finance.other_income.dto.FinanceOtherIncomeQueryFilter.class),
        new Document("finance_bank_transfers",FinanceBankTransfer.class,FinanceBankTransferService.class,"transferSpec",com.uten.imp.features.finance.bank_transfer.dto.FinanceBankTransferQueryFilter.class));}
    @BeforeAll static void start(){
        PG.start();var source=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());db=new JdbcTemplate(source);
        String[] tables=documents().map(Document::table).toArray(String[]::new);
        MigratedProjectionSchema.createCurrentTables(db,tables);MigratedProjectionSchema.installImportedDocumentPolicy(db,tables);
        var factory=new LocalContainerEntityManagerFactoryBean();factory.setDataSource(source);factory.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        factory.setManagedTypes(PersistenceManagedTypes.of(documents().map(document->document.entity().getName()).toArray(String[]::new)));
        factory.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto","none"));factory.afterPropertiesSet();emf=factory.getObject();
    }
    @AfterAll static void stop(){if(emf!=null)emf.close();PG.stop();}
    @BeforeEach void prepare(){
        db.execute("TRUNCATE "+documents().map(Document::table).collect(java.util.stream.Collectors.joining(",")));
        em=emf.createEntityManager();origin("ALL");
    }
    @AfterEach void close(){RequestContextHolder.resetRequestAttributes();if(em!=null)em.close();}
    @ParameterizedTest(name="{0}: exact fields and same-scope count/page/facets") @MethodSource("documents")
    void eachNativeFinancialServiceQueriesItsRealDateAndBookAmountBeforePaging(Document document) throws Exception {
        UUID first=seed(document,"1",OWNER,"2026-10-28","90071992547409.1234",false);
        UUID second=seed(document,"2",OWNER,"2026-10-31","90071992547409.1235",false);
        seed(document,"3",OWNER,"2026-10-29",null,false);seed(document,"4",OWNER,"2026-09-30","90071992547409.1234",false);
        seed(document,"5",HIDDEN,"2026-10-28","90071992547409.1234",false);seed(document,"6",OWNER,"2026-10-28","90071992547409.1234",true);
        Object service=service(document);
        Map<String,String> values=new LinkedHashMap<>(Map.of("search.billNo","FX%_","search.billDate","2026-10",
                "search.amountLocal","90071992547409.1234..90071992547409.1235","recordOrigin","CURRENT"));
        Object filter=filter(document,new HeaderColumnFilter(values));var spec=specification(document,service,filter);
        assertThat(count(document,spec)).isEqualTo(2);
        assertThat(page(document,spec,0)).containsExactly(first);assertThat(page(document,spec,1)).containsExactly(second);
        @SuppressWarnings("unchecked") var facets=(Map<String,List<Map<String,Object>>>)ReflectionTestUtils.invokeMethod(service,"facets",filter);
        assertThat(facets.get("billNo")).hasSize(2);
        values.put("search.billDate","2026-10-28..2026-10-30");
        assertThat(count(document,specification(document,service,filter(document,new HeaderColumnFilter(values))))).isEqualTo(1);
        values.put("search.billDate","2026-10");values.put("search.amountLocal","!=90071992547409.1234");
        assertThat(count(document,specification(document,service,filter(document,new HeaderColumnFilter(values))))).isEqualTo(1);
    }
    @Test void provenanceOnlyFinancialHistoryUsesTheSameOriginFactAndNativeStatusNeverReinterpretsIt() throws Exception {
        Document receipt=documents().findFirst().orElseThrow();Object service=service(receipt);
        UUID nativeDraft=seed(receipt,"draft",OWNER,"2026-10-28","10",false);
        UUID nativeApproved=seed(receipt,"approved",OWNER,"2026-10-28","10",false);
        db.update("UPDATE finance_receipts SET status=1 WHERE id=?",nativeApproved);
        UUID imported=UUID.randomUUID();
        db.update("INSERT INTO finance_receipts(id,bill_no,bill_date,maker_id,is_deleted,status,receipt_kind,legacy_import_run_id) VALUES(?,?,'2026-10-28',?,false,1,'AR_SETTLEMENT',?)",
                imported,"FX%_imported",OWNER,UUID.randomUUID());
        assertThat(db.queryForObject("SELECT legacy_id FROM finance_receipts WHERE id=?",Integer.class,imported)).isNull();
        Object legacyFilter=filter(receipt,new HeaderColumnFilter(Map.of("recordOrigin","LEGACY")));
        assertThat(all(receipt,specification(receipt,service,legacyFilter))).containsExactly(imported);
        Object currentFilter=filter(receipt,new HeaderColumnFilter(Map.of("recordOrigin","CURRENT")));
        assertThat(all(receipt,specification(receipt,service,currentFilter))).containsExactlyInAnyOrder(nativeDraft,nativeApproved);
        origin("CURRENT");
        var approved=new com.uten.imp.features.finance.receipt.dto.FinanceReceiptQueryFilter(null,null,null,(short)1,null,null,null,null)
                .withHeaders(new HeaderColumnFilter(Map.of("recordOrigin","CURRENT")));
        assertThat(all(receipt,specification(receipt,service,approved))).containsExactly(nativeApproved);
        assertThat(db.queryForObject("SELECT status FROM finance_receipts WHERE id=?",Short.class,imported)).isEqualTo((short)1);
    }
    private void origin(String value){var request=new MockHttpServletRequest();request.addParameter("originScope",value);RequestContextHolder.setRequestAttributes(new ServletRequestAttributes(request));}
    private Object service(Document document){
        Object service=mock(document.service(),CALLS_REAL_METHODS);
        var actor=mock(SecurityContextCurrentUser.class);when(actor.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(),OWNER,"finance-reader",Set.of(),false,true,false)));
        var owners=mock(OwnerVisibility.class);when(owners.evaluate(anyString(),anyString())).thenReturn(new OwnerVisibility.OwnerScope(false,Set.of(OWNER)));
        ReflectionTestUtils.setField(service,"access",new FinanceDocumentAccessPolicy(owners,actor));ReflectionTestUtils.setField(service,"em",em);return service;
    }
    private Object filter(Document document,HeaderColumnFilter headers) throws Exception {
        var components=document.filter().getRecordComponents();Object[] values=new Object[components.length];
        for(int index=0;index<components.length;index++){
            var type=components[index].getType();values[index]=type==HeaderColumnFilter.class?headers:type.isPrimitive()?java.lang.reflect.Array.get(java.lang.reflect.Array.newInstance(type,1),0):null;
        }
        return document.filter().getDeclaredConstructor(Arrays.stream(components).map(java.lang.reflect.RecordComponent::getType).toArray(Class<?>[]::new)).newInstance(values);
    }
    @SuppressWarnings("unchecked") private Specification<Object> specification(Document document,Object service,Object filter){return ReflectionTestUtils.invokeMethod(service,document.specification(),filter);}
    @SuppressWarnings("unchecked") private long count(Document document,Specification<Object> spec){var cb=em.getCriteriaBuilder();var query=cb.createQuery(Long.class);Root<Object> root=(Root<Object>)query.from(document.entity());query.select(cb.count(root)).where(spec.toPredicate(root,query,cb));return em.createQuery(query).getSingleResult();}
    @SuppressWarnings("unchecked") private List<UUID> all(Document document,Specification<Object> spec){var cb=em.getCriteriaBuilder();var query=cb.createQuery(UUID.class);Root<Object> root=(Root<Object>)query.from(document.entity());query.select(root.get("id")).where(spec.toPredicate(root,query,cb));return em.createQuery(query).getResultList();}
    @SuppressWarnings("unchecked") private List<UUID> page(Document document,Specification<Object> spec,int offset){var cb=em.getCriteriaBuilder();var query=cb.createQuery(UUID.class);Root<Object> root=(Root<Object>)query.from(document.entity());query.select(root.get("id")).where(spec.toPredicate(root,query,cb)).orderBy(cb.asc(root.get("billNo")));return em.createQuery(query).setFirstResult(offset).setMaxResults(1).getResultList();}
    private UUID seed(Document document,String suffix,UUID maker,String date,String amount,boolean deleted){
        UUID id=UUID.randomUUID();String extra=document.table().equals("finance_receipts")?",receipt_kind":"";
        db.update("INSERT INTO "+document.table()+"(id,bill_no,bill_date,maker_id,amount_local,is_deleted,status"+extra+") VALUES(?,?,?,?,?,?,0"+(extra.isEmpty()?"":",'AR_SETTLEMENT'")+")",
                id,"FX%_"+suffix,LocalDate.parse(date),maker,amount==null?null:new BigDecimal(amount),deleted);return id;
    }
}
