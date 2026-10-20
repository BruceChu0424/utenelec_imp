package com.uten.imp.features.master.mould;

import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.util.DepartmentNameResolver;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.master.mouldcategory.MouldCategoryRepository;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.support.MigratedProjectionSchema;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

@Testcontainers(disabledWithoutDocker=true)
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class MouldManufacturerSuggestionsPostgresTest {
    @Container static final PostgreSQLContainer POSTGRES=new PostgreSQLContainer("postgres:16-alpine");
    @Test void emptyInputReturnsHistoryAndSearchRanksNearestManufacturersExcludingDeletedOrBlank() {
        var source=new DriverManagerDataSource(POSTGRES.getJdbcUrl(),POSTGRES.getUsername(),POSTGRES.getPassword());
        var db=new JdbcTemplate(source);var named=new NamedParameterJdbcTemplate(source);
        MigratedProjectionSchema.createCurrentTables(db, "moulds");
        db.update("INSERT INTO moulds(manufacturer,is_deleted) VALUES(' 厂家甲 ',false),('厂家甲',false),('厂家乙',false),('甲方模具公司',false),('',false),(null,false),('已删除厂家',true)");
        var em=mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(call->{
            String sql=call.getArgument(0);var query=mock(Query.class);var parameters=new HashMap<String,Object>();
            when(query.setParameter(anyString(),any())).thenAnswer(bind->{parameters.put(bind.getArgument(0),bind.getArgument(1));return query;});
            when(query.getResultList()).thenAnswer(read->named.query(sql,parameters,(rs,index)->new Object[]{rs.getString(1),rs.getLong(2)}));
            return query;
        });
        var service=new MouldService(mock(MouldRepository.class),mock(MouldCategoryRepository.class),mock(TxSessionVars.class),em,
            mock(CategoryDrivenCodeService.class),mock(DepartmentNameResolver.class),mock(EmployeeNameResolver.class));
        assertThat(service.manufacturerSuggestions("")).containsExactly("厂家甲","厂家乙","甲方模具公司");
        assertThat(service.manufacturerSuggestions(" 厂家乙 ")).first().isEqualTo("厂家乙");
        assertThat(service.manufacturerSuggestions("厂家")).containsExactly("厂家甲","厂家乙");
        assertThat(service.manufacturerSuggestions("甲方公司")).contains("甲方模具公司");
        assertThat(service.manufacturerSuggestions("不存在")).isEmpty();
        assertThatThrownBy(()->service.manufacturerSuggestions("字".repeat(201))).hasMessageContaining("200");
    }
}
