package com.uten.imp.features.master.platformcolumns;

import com.uten.imp.common.platformcolumns.PlatformColumnResourceAdapter;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

@Testcontainers(disabledWithoutDocker=true)
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class GoodsRelatedColumnAdapterPostgresTest {
    @Container static final PostgreSQLContainer<?> POSTGRES=new PostgreSQLContainer<>("postgres:16-alpine");

    @Test void followsUuidRelationBatchesMissingRelationsAndNeverGuessesFromMatchingCodes() {
        var source=new DriverManagerDataSource(POSTGRES.getJdbcUrl(),POSTGRES.getUsername(),POSTGRES.getPassword());
        var db=new JdbcTemplate(source);
        // Domain adapter SQL fixture; full migration and definition ownership are tested by PlatformColumnServicePostgresTest.
        db.execute("CREATE TABLE moulds(id uuid PRIMARY KEY,name text,code text,qty text,tqty numeric(18,4),manufacturer text,place text,mstatus text,is_deleted boolean DEFAULT false)");
        db.execute("CREATE TABLE goods(id uuid PRIMARY KEY,mould_id uuid,code text,is_deleted boolean DEFAULT false)");
        UUID first=UUID.randomUUID(),second=UUID.randomUUID(),bound=UUID.randomUUID(),unbound=UUID.randomUUID();
        db.update("INSERT INTO moulds(id,name,code,qty,tqty,manufacturer) VALUES(?, '模具甲','00012','1+1',2,'厂家甲'),(?, '模具乙','00013','2',3,'厂家乙')",first,second);
        db.update("INSERT INTO goods(id,mould_id,code) VALUES(?,?,'00012'),(?,null,'00012')",bound,first,unbound);
        var current=mock(SecurityContextCurrentUser.class);
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"viewer",Set.of("goods:view","mould:view"),false,true,false,false,null)));
        var delegate=mock(PlatformColumnResourceAdapter.class);
        var adapter=new GoodsRelatedColumnAdapter(delegate,current,new NamedParameterJdbcTemplate(source));
        assertThat(adapter.canDefineRelatedColumns()).isTrue(); // A private read-only projection does not require goods:edit.
        var values=adapter.relatedValues(Set.of(bound,unbound),Set.of("mouldName","mouldCode","mouldManufacturer"));
        assertThat(values.get(bound)).containsEntry("mouldName","模具甲").containsEntry("mouldCode","00012").containsEntry("mouldManufacturer","厂家甲");
        assertThat(values.get(unbound)).isEmpty();
        db.update("UPDATE goods SET mould_id=? WHERE id=?",second,bound);
        assertThat(adapter.relatedValues(Set.of(bound),Set.of("mouldName")).get(bound)).containsEntry("mouldName","模具乙");
        db.update("UPDATE moulds SET is_deleted=true WHERE id=?",second);
        assertThat(adapter.relatedValues(Set.of(bound),Set.of("mouldName")).get(bound)).isEmpty();
        assertThatThrownBy(()->adapter.relatedValues(Set.of(bound),Set.of("unregistered"))).isInstanceOf(ApiException.class);
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"viewer",Set.of("goods:view"),false,true,false,false,null)));
        assertThat(adapter.relations()).isEmpty();
        assertThat(adapter.canDefineRelatedColumns()).isFalse();
        assertThatThrownBy(()->adapter.relatedValues(Set.of(bound),Set.of("mouldName"))).isInstanceOf(ApiException.class).hasMessageContaining("查看权限");
    }
}
