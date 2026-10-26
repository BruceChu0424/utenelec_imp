package com.uten.imp.features.master.goods;

import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.dto.MasterStatusChangeRequest;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.features.master.mould.MouldRepository;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.*;
import com.uten.imp.support.MigratedSchemaBaseline;
import jakarta.persistence.*;
import java.util.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.util.ReflectionTestUtils;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Real stale managed snapshots and a separate committed writer, followed by the service's row lock. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS", matches="(?i)true")
class GoodsNarrowWritePostgresTest {
    static MigratedSchemaBaseline.ScopedDatabase database;
    static EntityManagerFactory factory;
    static JdbcTemplate sql;
    EntityManager em;
    GoodsRepository repo;
    GoodsService service;
    UUID id, firstOwner, secondOwner;

    @BeforeAll static void start() throws Exception {
        database=MigratedSchemaBaseline.openDatabase("goods_narrow_write");
        var source=new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword());
        sql=new JdbcTemplate(source);
        var bean=new LocalContainerEntityManagerFactoryBean();bean.setDataSource(source);
        bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());bean.setPackagesToScan("com.uten.imp");
        bean.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto","none"));bean.afterPropertiesSet();factory=bean.getObject();
    }
    @AfterAll static void stop() throws Exception {
        if(factory!=null) factory.close();
        if(database!=null) database.close();
    }
    @BeforeEach void prepare() {
        em=factory.createEntityManager();repo=mock(GoodsRepository.class);
        firstOwner=employee();secondOwner=employee();id=UUID.randomUUID();
        sql.update("INSERT INTO goods(id,code,name,status,name_en,name_en_source,owner_employee_id,code_sequence) VALUES(?,?,'narrow','使用','OLD NAME','MANUAL',?,(SELECT COALESCE(max(code_sequence),0)+1 FROM goods))",
                id,"LOCK-"+id,firstOwner);
        var permissions=Set.of("goods:view","goods:name_en:edit","goods:status");
        var user=new AuthUser(UUID.randomUUID(),firstOwner,"narrow-test",permissions,false,true,false);
        var current=mock(SecurityContextCurrentUser.class);when(current.get()).thenReturn(Optional.of(user));
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user,null,user.getAuthorities()));
        var visibility=mock(OwnerVisibility.class);
        when(visibility.evaluate("goods","goods:view:all"))
                .thenReturn(new OwnerVisibility.OwnerScope(false,Set.of(firstOwner),Set.of(firstOwner)));
        service=new GoodsService(repo,mock(MaterialCategoryRepository.class),mock(ColorRepository.class),mock(UnitRepository.class),
                mock(MouldRepository.class),mock(TxSessionVars.class),em,mock(CategoryDrivenCodeService.class),visibility,current,
                mock(GoodsCostMasker.class),mock(GoodsMasterRelationshipResolver.class));
        ReflectionTestUtils.setField(service,"goodsOwnerScopeEnabled",true);
        when(repo.findById(id)).thenAnswer(call->Optional.ofNullable(em.find(Goods.class,id)));
        when(repo.save(any(Goods.class))).thenAnswer(call->{em.flush();return call.getArgument(0);});
        when(repo.saveAndFlush(any(Goods.class))).thenAnswer(call->{em.flush();return call.getArgument(0);});
    }
    @AfterEach void close() {
        if(em.getTransaction().isActive()) em.getTransaction().rollback();
        em.close();SecurityContextHolder.clearContext();
    }
    @Test void ownerHandoverCommittedAfterInitialReadCannotBeOverwrittenByVersionlessManualNameEdit() {
        afterInitialRead(()->sql.update("UPDATE goods SET owner_employee_id=?,version=version+1 WHERE id=?",secondOwner,id));
        em.getTransaction().begin();
        var error=assertThrows(ApiException.class,()->service.updateNameEn(id,"forbidden",null));
        assertEquals(ErrorCode.NOT_FOUND,error.getCode());em.getTransaction().rollback();assertUnchangedName();
        assertEquals(secondOwner,sql.queryForObject("SELECT owner_employee_id FROM goods WHERE id=?",UUID.class,id));
    }
    @Test void nameLearningSkipsAHandoverCommittedAfterItsInitialScopeCheck() {
        afterInitialRead(()->sql.update("UPDATE goods SET owner_employee_id=?,version=version+1 WHERE id=?",secondOwner,id));
        em.getTransaction().begin();assertFalse(service.learnNameEn(id,"forbidden"));em.getTransaction().commit();assertUnchangedName();
    }
    @Test void deletionCommittedAfterTheInitialReadBlocksAnOtherwiseAuthorizedStatusCommand() {
        afterInitialRead(()->sql.update("UPDATE goods SET is_deleted=true,version=version+1 WHERE id=?",id));
        em.getTransaction().begin();
        var error=assertThrows(ApiException.class,()->service.changeStatus(id,new MasterStatusChangeRequest("禁用",null)));
        assertEquals(ErrorCode.NOT_FOUND,error.getCode());em.getTransaction().rollback();
        assertEquals("使用",sql.queryForObject("SELECT status FROM goods WHERE id=?",String.class,id));
        assertTrue(sql.queryForObject("SELECT is_deleted FROM goods WHERE id=?",Boolean.class,id));
    }
    @Test void canonicalStatusCommandsStillWorkAndInvalidStatesLeaveTheDatabaseUnchanged() {
        em.getTransaction().begin();
        var error=assertThrows(ApiException.class,()->service.changeStatus(id,new MasterStatusChangeRequest("unknown",null)));
        assertEquals(ErrorCode.VALIDATION_FAILED,error.getCode());em.getTransaction().rollback();
        assertEquals("使用",sql.queryForObject("SELECT status FROM goods WHERE id=?",String.class,id));
        em.getTransaction().begin();service.changeStatus(id,new MasterStatusChangeRequest("禁用",null));em.getTransaction().commit();
        assertEquals("禁用",sql.queryForObject("SELECT status FROM goods WHERE id=?",String.class,id));
        em.getTransaction().begin();service.changeStatus(id,new MasterStatusChangeRequest("使用",null));em.getTransaction().commit();
        assertEquals("使用",sql.queryForObject("SELECT status FROM goods WHERE id=?",String.class,id));
    }
    private void afterInitialRead(Runnable concurrentCommit) {
        when(repo.findById(id)).thenAnswer(call->{Goods stale=em.find(Goods.class,id);concurrentCommit.run();return Optional.of(stale);});
    }
    private void assertUnchangedName() {
        assertEquals("OLD NAME",sql.queryForObject("SELECT name_en FROM goods WHERE id=?",String.class,id));
        assertEquals("MANUAL",sql.queryForObject("SELECT name_en_source FROM goods WHERE id=?",String.class,id));
        assertEquals(1L,sql.queryForObject("SELECT version FROM goods WHERE id=?",Long.class,id));
    }
    private UUID employee() {
        UUID employee=UUID.randomUUID();
        sql.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,'范围测试','其他',(SELECT id FROM departments WHERE NOT is_deleted ORDER BY id LIMIT 1),current_date,'active','regular')",
                employee,"NARROW-"+employee);
        return employee;
    }
}
