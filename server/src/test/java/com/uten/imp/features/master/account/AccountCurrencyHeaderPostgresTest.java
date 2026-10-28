package com.uten.imp.features.master.account;

import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.features.master.account.dto.AccountQueryFilter;
import com.uten.imp.features.master.currency.*;
import com.uten.imp.features.master.currency.dto.CurrencyQueryFilter;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.support.MigratedProjectionSchema;
import com.uten.imp.support.MigratedSchemaBaseline;
import jakarta.persistence.EntityManager;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.persistenceunit.PersistenceManagedTypes;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.data.jpa.repository.support.JpaRepositoryFactory;
import org.springframework.security.authentication.TestingAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;

/** Actual Hibernate predicates over the migrated catalog, including values above double's exact range. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class AccountCurrencyHeaderPostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private static jakarta.persistence.EntityManagerFactory emf;
    private static JdbcTemplate db;
    private EntityManager em;
    private JpaRepositoryFactory repositories;
    @BeforeAll static void baseline() throws Exception {
        database=MigratedSchemaBaseline.openDatabase("account_currency_headers");
        try(var connection=database.openConnection();var statement=connection.createStatement()) {
            statement.execute("CREATE SCHEMA account_header_oracle");
            statement.execute("SET search_path=account_header_oracle,public");
            MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(connection,"accounts","currencies");
        }
        var source=new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword());
        var properties=new java.util.Properties();properties.setProperty("currentSchema","account_header_oracle,public");
        source.setConnectionProperties(properties);db=new JdbcTemplate(source);
        var factory=new LocalContainerEntityManagerFactoryBean();factory.setDataSource(source);
        factory.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        factory.setManagedTypes(PersistenceManagedTypes.of(Account.class.getName(),Currency.class.getName()));
        factory.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto","none","hibernate.jdbc.time_zone","UTC"));
        factory.afterPropertiesSet();emf=factory.getObject();
    }
    @AfterAll static void close() throws Exception { if(emf!=null)emf.close();if(database!=null)database.close(); }
    @BeforeEach void clean() {
        db.execute("TRUNCATE accounts,currencies");em=emf.createEntityManager();repositories=new JpaRepositoryFactory(em);
        SecurityContextHolder.getContext().setAuthentication(new TestingAuthenticationToken("reader","n/a","account:view","account:balance:view"));
    }
    @AfterEach void closeEntityManager() { if(em!=null)em.close();SecurityContextHolder.clearContext(); }

    @Test void accountHeadersKeepExactOriginalCurrencyValuesAndCountBeforePagingAndExport() {
        UUID first=account("A-01","90071992547409.1234",false),second=account("A-02","90071992547409.1235",false);
        account("A-03","90071992547409.1236",true);
        var service=new AccountService(repositories.getRepository(AccountRepository.class),mock(TxSessionVars.class),em,mock(MasterCodeService.class));
        var filter=new AccountQueryFilter("银行",null,null,null,null,null,null).withColumnSearch(
                Map.of("name","银行%_账户","bankAccountNo","6222%_","balanceCurrent","90071992547409.1234..90071992547409.1235"));
        var one=service.list(filter,1,1,"balanceCurrent","desc");
        var two=service.list(filter,2,1,"balanceCurrent","desc");
        assertThat(one.getTotal()).isEqualTo(2);
        assertThat(one.getItems().getFirst().getId()).isEqualTo(second);
        assertThat(two.getItems().getFirst().getId()).isEqualTo(first);
        assertThat(two.getItems().getFirst().getBalanceCurrentText()).isEqualTo("90071992547409.1234");
        assertThat(service.list(filter.withColumnSearch(Map.of("balanceCurrent","90071992547409.1234")),1,20,null,null).getItems())
                .extracting(com.uten.imp.features.master.account.dto.AccountListItem::getId).containsExactly(first);
        assertThat(service.export(filter,"balanceCurrent","desc",20).rows()).hasSize(2);
    }
    @Test void currencyHeadersKeepSixDecimalRatesAndUseTheSameExportScopeWithoutSummingRates() {
        UUID first=currency("C-01","123456789012.123456",false),second=currency("C-02","123456789012.123457",false);
        currency("C-03","123456789012.123458",true);
        var service=new CurrencyService(repositories.getRepository(CurrencyRepository.class),mock(TxSessionVars.class),em,mock(MasterCodeService.class));
        var filter=new CurrencyQueryFilter("币种",null,null,null,null).withColumnSearch(
                Map.of("name","币种%_","exchangeRate","123456789012.123456..123456789012.123457"));
        assertThat(service.list(filter,1,1,"exchangeRate","desc").getItems().getFirst().getId()).isEqualTo(second);
        var page=service.list(filter,2,1,"exchangeRate","desc");
        assertThat(page.getTotal()).isEqualTo(2);
        assertThat(page.getItems().getFirst().getId()).isEqualTo(first);
        assertThat(page.getItems().getFirst().getExchangeRateText()).isEqualTo("123456789012.123456");
        assertThat(service.list(filter.withColumnSearch(Map.of("exchangeRate","123456789012.123456")),1,20,null,null).getTotal()).isEqualTo(1);
        assertThat(service.export(filter,"exchangeRate","desc",20).rows()).hasSize(2);
    }
    @Test void accountCurrencyCandidatesAreCompleteAndKeepDeletedReferencedCurrencyNames() {
        UUID last=null;
        for(int index=0;index<51;index++) {
            UUID currency=currency("C-"+index,"1.000000",index==50);
            UUID account=account("A-"+index,"0",false);
            db.update("UPDATE accounts SET currency_id=? WHERE id=?",currency,account);
            last=currency;
        }
        var service=new AccountService(repositories.getRepository(AccountRepository.class),mock(TxSessionVars.class),em,mock(MasterCodeService.class));
        var facets=service.facets();
        assertThat(facets.getCurrencyId()).hasSize(51);
        UUID deletedReference=last;
        assertThat(facets.getCurrencyId()).anySatisfy(bucket->{
            assertThat(bucket.getValue()).isEqualTo(deletedReference.toString());
            assertThat(bucket.getLabel()).contains("币种%_测试");
        });
    }
    private UUID account(String code,String balance,boolean deleted) {
        UUID id=UUID.randomUUID();
        db.update("INSERT INTO accounts(id,code,name,bank_account_no,account_type,status,balance_current,is_deleted,auto_created) VALUES(?,?,'银行%_账户','6222%_999','BANK','使用',?::numeric,?,false)",id,code,balance,deleted);return id;
    }
    private UUID currency(String code,String rate,boolean deleted) {
        UUID id=UUID.randomUUID();
        db.update("INSERT INTO currencies(id,code,name,exchange_rate,status,is_deleted,is_base_currency,auto_created) VALUES(?,?,'币种%_测试',?::numeric,'使用',?,false,false)",id,code,rate,deleted);return id;
    }
}
