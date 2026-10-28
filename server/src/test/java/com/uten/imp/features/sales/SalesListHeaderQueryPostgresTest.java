package com.uten.imp.features.sales;

import com.uten.imp.common.web.HeaderColumnFilter;
import com.uten.imp.features.sales.order.*;
import com.uten.imp.features.sales.order.dto.OrderQueryFilter;
import com.uten.imp.features.sales.quote.*;
import com.uten.imp.features.sales.quote.dto.QuoteQueryFilter;
import com.uten.imp.features.sales.shipment.*;
import com.uten.imp.features.sales.shipment.dto.ShipmentQueryFilter;
import com.uten.imp.features.sales.ret.*;
import com.uten.imp.features.sales.ret.dto.ReturnQueryFilter;
import com.uten.imp.features.sales.other_shipment.*;
import com.uten.imp.features.sales.other_shipment.dto.OtherShipmentQueryFilter;
import com.uten.imp.security.*;
import com.uten.imp.support.MigratedProjectionSchema;
import com.uten.imp.support.MigratedSchemaBaseline;
import jakarta.persistence.EntityManager;
import java.util.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.persistenceunit.PersistenceManagedTypes;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.web.context.request.*;
import org.springframework.test.util.ReflectionTestUtils;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Owning service Specifications (not a test copy) executed by Hibernate against migrated document columns. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class SalesListHeaderQueryPostgresTest {
    enum Feature {
        ORDER(SalesOrder.class,SalesOrderService.class,OrderQueryFilter.class,"sales_orders","orderSpec","owner_employee_id"),
        QUOTE(SalesQuote.class,SalesQuoteService.class,QuoteQueryFilter.class,"sales_quotes","quoteSpec","maker_id"),
        SHIPMENT(SalesShipment.class,SalesShipmentService.class,ShipmentQueryFilter.class,"sales_shipments","shipmentSpec","owner_employee_id"),
        CUSTOMER(SalesShipment.class,SalesShipmentService.class,ShipmentQueryFilter.class,"sales_shipments","shipmentSpec","owner_employee_id"),
        RETURN(SalesReturn.class,SalesReturnService.class,ReturnQueryFilter.class,"sales_returns","returnSpec","owner_employee_id"),
        HISTORICAL_OTHER(SalesOtherShipment.class,SalesOtherShipmentService.class,OtherShipmentQueryFilter.class,"sales_other_shipments","otherShipmentSpec","owner_employee_id");
        final Class<?> entity,service,filter;final String table,method,owner;
        Feature(Class<?> entity,Class<?> service,Class<?> filter,String table,String method,String owner) {
            this.entity=entity;this.service=service;this.filter=filter;this.table=table;this.method=method;this.owner=owner;
        }
        boolean delivery() {return this==ORDER||this==QUOTE;}
    }
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private static jakarta.persistence.EntityManagerFactory emf;
    private static JdbcTemplate db;
    private EntityManager em;
    private SecurityContextCurrentUser users;
    private SalesDocumentAccessPolicy access;
    private final UUID owner=UUID.randomUUID(),currency=UUID.randomUUID();
    private static final String AMOUNT="12345678901234.1234";
    @BeforeAll static void setup() throws Exception {
        database=MigratedSchemaBaseline.openDatabase("sales_list_headers");
        try(var connection=database.openConnection();var sql=connection.createStatement()) {
            sql.execute("CREATE SCHEMA sales_header_oracle");sql.execute("SET search_path=sales_header_oracle,public");
            MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(connection,"sales_orders","sales_quotes","sales_shipments","sales_returns","sales_other_shipments");
        }
        var source=new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword());
        var props=new Properties();props.setProperty("currentSchema","sales_header_oracle,public");source.setConnectionProperties(props);db=new JdbcTemplate(source);
        var factory=new LocalContainerEntityManagerFactoryBean();factory.setDataSource(source);factory.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        factory.setManagedTypes(PersistenceManagedTypes.of(SalesOrder.class.getName(),SalesQuote.class.getName(),SalesShipment.class.getName(),SalesReturn.class.getName(),SalesOtherShipment.class.getName()));
        factory.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto","none"));factory.afterPropertiesSet();emf=factory.getObject();
    }
    @AfterAll static void close() throws Exception {
        if (emf != null) {
            emf.close();
        }
        if (database != null) {
            database.close();
        }
    }
    @BeforeEach void session() {
        db.execute("TRUNCATE sales_orders,sales_quotes,sales_shipments,sales_returns,sales_other_shipments");
        em=emf.createEntityManager();users=mock(SecurityContextCurrentUser.class);permissions(Set.of(SalesPriceMasker.PERM));
        var owners=mock(OwnerVisibility.class);when(owners.evaluate(anyString(),anyString())).thenReturn(new OwnerVisibility.OwnerScope(false,Set.of(owner)));
        access=new SalesDocumentAccessPolicy(owners,users);
        // Isolate the header/owner read contract from the separately tested imported-history function.
        var request=new MockHttpServletRequest();request.setParameter("originScope","ALL");RequestContextHolder.setRequestAttributes(new ServletRequestAttributes(request));
    }
    @AfterEach void end() {RequestContextHolder.resetRequestAttributes();if(em!=null)em.close();}

    @ParameterizedTest @EnumSource(Feature.class)
    void typedHeadersStayInsideTheOwningScopeBeforeCountAndTwoPages(Feature feature) throws Exception {
        UUID first=row(feature,"H-01",owner,currency,"2026-10-28",AMOUNT,false);
        UUID second=row(feature,"H-02",owner,currency,"2026-10-28","12345678901234.1235",false);
        row(feature,"H-HIDDEN",UUID.randomUUID(),currency,"2026-10-28",AMOUNT,false);
        row(feature,"H-DELETED",owner,currency,"2026-10-28",AMOUNT,true);
        row(feature,"H-LATER",owner,currency,"2026-10-29",AMOUNT,false);
        if(feature==Feature.ORDER)row(feature,"H-OTHER-CURRENCY",owner,UUID.randomUUID(),"2026-10-28",AMOUNT,false);
        var terms=new LinkedHashMap<String,String>();terms.put("search.billDate","2026-10-28..2026-10-28");terms.put("search.total",">="+AMOUNT);
        if(feature.delivery())terms.put("search.deliver","2026-11");
        var spec=spec(feature,new HeaderColumnFilter(terms),feature==Feature.ORDER?currency:null);
        assertThat(count(feature,spec)).isEqualTo(2);
        assertThat(page(feature,spec,0)).containsExactly(first);
        assertThat(page(feature,spec,1)).containsExactly(second);
        terms.put("search.total",AMOUNT);
        assertThat(count(feature,spec(feature,new HeaderColumnFilter(terms),feature==Feature.ORDER?currency:null))).isEqualTo(1);
    }

    @Test void originalOrderAmountRequiresCurrencyAndHiddenMoneyFailsBeforeParsing() throws Exception {
        var valid=new HeaderColumnFilter(Map.of("search.total",">=1"));
        assertThatThrownBy(()->count(Feature.ORDER,spec(Feature.ORDER,valid,null)))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageContaining("先选择币种");
        permissions(Set.of());
        for(var feature:List.of(Feature.ORDER,Feature.QUOTE,Feature.SHIPMENT,Feature.CUSTOMER)) {
            assertThatThrownBy(()->count(feature,spec(feature,new HeaderColumnFilter(Map.of("search.total","not a number")),currency)))
                    .isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageContaining("隐藏的商业金额");
            Object service=service(feature);
            Object filter=filter(feature,HeaderColumnFilter.EMPTY,currency);
            assertThatThrownBy(()->ReflectionTestUtils.invokeMethod(service,"list",filter,1,20,"total","asc"))
                    .isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageContaining("隐藏的商业金额");
        }
        permissions(Set.of("sales_quote_finance:view"));
        row(Feature.QUOTE,"FINANCE-QUOTE",owner,currency,"2026-10-28","12",false);
        assertThat(count(Feature.QUOTE,spec(Feature.QUOTE,new HeaderColumnFilter(Map.of("search.total","12")),null))).isEqualTo(1);
    }

    @SuppressWarnings("unchecked") private Specification<Object> spec(Feature feature,HeaderColumnFilter headers,UUID selectedCurrency) throws Exception {
        Object filter=filter(feature,headers,selectedCurrency),service=service(feature);
        return feature==Feature.ORDER?ReflectionTestUtils.invokeMethod(service,feature.method,filter,false)
                :ReflectionTestUtils.invokeMethod(service,feature.method,filter);
    }
    private Object service(Feature feature) {
        Object service=mock(feature.service,CALLS_REAL_METHODS);ReflectionTestUtils.setField(service,"accessPolicy",access);
        if(feature==Feature.ORDER||feature==Feature.QUOTE)ReflectionTestUtils.setField(service,"priceMasker",new SalesPriceMasker(users));
        if(feature==Feature.SHIPMENT||feature==Feature.CUSTOMER) {
            var policy=mock(CustomerShipmentPolicy.class);when(policy.can(anyString(),eq("view"))).thenReturn(true);
            ReflectionTestUtils.setField(service,"customerShipmentPolicy",policy);
        }
        return service;
    }
    private Object filter(Feature feature,HeaderColumnFilter headers,UUID selectedCurrency) throws Exception {
        var components=feature.filter.getRecordComponents();Object[] args=new Object[components.length];
        for(int i=0;i<components.length;i++) {
            var component=components[i];if(component.getType()==boolean.class)args[i]=false;
            if(component.getName().equals("headerFilters"))args[i]=headers;
            if(component.getName().equals("currencyId"))args[i]=selectedCurrency;
            if(feature==Feature.CUSTOMER&&component.getName().equals("shipmentKind"))args[i]="DIRECT";
        }
        return feature.filter.getDeclaredConstructor(Arrays.stream(components).map(java.lang.reflect.RecordComponent::getType).toArray(Class<?>[]::new)).newInstance(args);
    }
    @SuppressWarnings({"rawtypes","unchecked"}) private long count(Feature feature,Specification<Object> spec) {
        var cb=em.getCriteriaBuilder();var query=cb.createQuery(Long.class);var root=query.from((Class)feature.entity);
        query.select(cb.count(root)).where(spec.toPredicate(root,query,cb));return em.createQuery(query).getSingleResult();
    }
    @SuppressWarnings({"rawtypes","unchecked"}) private List<UUID> page(Feature feature,Specification<Object> spec,int offset) {
        var cb=em.getCriteriaBuilder();var query=cb.createQuery(UUID.class);var root=query.from((Class)feature.entity);
        query.select(root.get("id")).where(spec.toPredicate(root,query,cb)).orderBy(cb.asc(root.get("billNo")),cb.asc(root.get("id")));
        return em.createQuery(query).setFirstResult(offset).setMaxResults(1).getResultList();
    }
    private void permissions(Set<String> values) {when(users.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(),owner,"reader",values,false,true,false)));}
    private UUID row(Feature feature,String bill,UUID holder,UUID denomination,String day,String amount,boolean deleted) {
        UUID id=UUID.randomUUID();boolean order=feature==Feature.ORDER;
        db.update("INSERT INTO "+feature.table+"(id,bill_no,bill_date,total_original,total_local,"+feature.owner+",is_deleted,currency_id"
                +(feature.delivery()?",deliver_date":"")+(feature==Feature.SHIPMENT||feature==Feature.CUSTOMER?",shipment_kind":"")+") VALUES(?,?,?::date,?::numeric,?::numeric,?,?,?"
                +(feature.delivery()?",DATE '2026-11-02'":"")+(feature==Feature.SHIPMENT||feature==Feature.CUSTOMER?",'"+(feature==Feature.CUSTOMER?"DIRECT":"ORDER")+"'":"")+")",
                id,bill,day,order?amount:"9",order?"9":amount,holder,deleted,denomination);return id;
    }
}
