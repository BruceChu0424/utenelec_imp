package com.uten.imp.features.finance.application;

import com.uten.imp.audit.AuditDeviceContext;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.config.Jackson2ObjectMapperAutoConfiguration;
import com.uten.imp.config.props.CryptoProperties;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.expenseclaim.ExpenseApplicationSourceAdapter;
import com.uten.imp.features.expenseclaim.ExpenseClaimService;
import com.uten.imp.features.expenseclaim.HistoricalExpenseSourceJdbc;
import com.uten.imp.testsupport.HistoricalJdbcNativeSql;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.features.finance.statement.FinanceAuxiliaryService;
import com.uten.imp.security.*;
import org.springframework.aop.framework.ProxyFactory;
import org.springframework.beans.factory.support.StaticListableBeanFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.annotation.AnnotationTransactionAttributeSource;
import org.springframework.transaction.interceptor.TransactionInterceptor;

import javax.sql.DataSource;
import java.util.*;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Original-schema JDBC adapters for existing canonical logic. No Hibernate factory or fake money source is used. */
final class JdbcHistoricalFinanceServices {
    record Wiring(FinanceApplicationService applications,FinanceApplicationRoles roles,
            DocNumberService numbers,FinanceAuxiliaryService auxiliaries,ExpenseClaimService expenseSnapshots,
            TxSessionVars identity,PlatformTransactionManager transactions) { }

    static Wiring create(DataSource source) {
        var db=new JdbcTemplate(source);var json=Jackson2ObjectMapperAutoConfiguration.domainObjectMapper();
        var manager=new DataSourceTransactionManager(source);var current=new SecurityContextCurrentUser();
        var entityQueries=HistoricalJdbcNativeSql.statements(db);
        var crypto=new CryptoProperties();crypto.setPgpMasterKey("application-test-only-pgp-key-0123456789-0123456789");crypto.setHmacKey("application-test-only-hmac-key-0123456789");
        var identity=new TxSessionVars(crypto,current,new AuditDeviceContext(json));ReflectionTestUtils.setField(identity,"em",entityQueries);
        var users=mock(UserAccountRepository.class);
        when(users.findById(any(UUID.class))).thenAnswer(call->{
            UUID id=call.getArgument(0);var rows=db.queryForList("SELECT id,employee_id,login_account,status,is_super_admin,is_deleted FROM users WHERE id=?",id);
            if(rows.isEmpty())return Optional.empty();var row=rows.getFirst();var account=new UserAccount();account.setId(id);
            account.setEmployeeId((UUID)row.get("employee_id"));account.setLoginAccount((String)row.get("login_account"));account.setStatus((String)row.get("status"));
            account.setSuperAdmin(Boolean.TRUE.equals(row.get("is_super_admin")));account.setDeleted(Boolean.TRUE.equals(row.get("is_deleted")));return Optional.of(account);
        });
        var permissions=mock(PermissionResolver.class);
        when(permissions.grantedPermsOf(any(UserAccount.class))).thenAnswer(call->{
            UserAccount account=call.getArgument(0);
            assertThat(db.queryForObject("SELECT count(*) FROM user_permission_overrides WHERE user_id=? AND effect<>'grant'",Integer.class,account.getId())).isZero();
            return new HashSet<>(db.queryForList("SELECT p.code FROM user_permission_overrides o JOIN permissions p ON p.id=o.permission_id WHERE o.user_id=? AND o.effect='grant'",String.class,account.getId()));
        });
        var roles=new FinanceApplicationRoles(db,users,permissions,current,identity,null);
        var nativeSnapshots=mock(ExpenseClaimService.class,call->{throw new IllegalStateException("Historical bootstrap may only read its actual JDBC expense snapshot: "+call.getMethod().getName());});
        doAnswer(call->{
            // This original fixture deliberately has no platform definitions or
            // values; do not synthesize historical fields through a current ORM.
            assertThat(db.queryForObject("SELECT count(*) FROM platform_column_definitions WHERE scope IN('expense_claim','expense_claim_item')",Integer.class)).isZero();
            assertThat(db.queryForObject("SELECT count(*) FROM platform_record_fields WHERE scope IN('expense_claim','expense_claim_item')",Integer.class)).isZero();
            return HistoricalExpenseSourceJdbc.snapshot(db,call.getArgument(0));
        }).when(nativeSnapshots).applicationBusinessSnapshot(any(UUID.class));
        var providers=new StaticListableBeanFactory();providers.addBean("originalExpenseSnapshots",nativeSnapshots);
        var expenseSource=new ExpenseApplicationSourceAdapter(db,json,providers.getBeanProvider(ExpenseClaimService.class));
        var numbers=transactional(new DocNumberService(entityQueries),manager,DocNumberService.class);
        var auxiliary=transactional(new FinanceAuxiliaryService(db,current,identity,
                new FinanceDocumentAccessPolicy(new OwnerVisibility(current,entityQueries,null),current)),manager,FinanceAuxiliaryService.class);
        var applications=new FinanceApplicationService(db,json,roles,current,identity,numbers,expenseSource,
                null,null,null,null,null,null,new FinanceApplicationLegacyPolicy(db),null);
        return new Wiring(applications,roles,numbers,auxiliary,nativeSnapshots,identity,manager);
    }

    private static <T> T transactional(T target,PlatformTransactionManager manager,Class<T> type){
        var interceptor=new TransactionInterceptor();interceptor.setTransactionManager(manager);interceptor.setTransactionAttributeSource(new AnnotationTransactionAttributeSource());
        var proxy=new ProxyFactory(target);proxy.setProxyTargetClass(true);proxy.addAdvice(interceptor);return type.cast(proxy.getProxy());
    }
}
