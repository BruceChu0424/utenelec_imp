package com.uten.imp.migration;

import com.uten.imp.testsupport.TestFlyway;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.core.io.ClassPathResource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.nio.charset.StandardCharsets;
import java.sql.*;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

/** Real forward upgrade; the historical V892 predecessor test stays on V892. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class WarehouseNoticeSupervisorUnionPostgresTest {
    static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    static JdbcTemplate db;
    static UUID root,a,b;
    static Actor supervisor,mainKeeper,keeperA,keeperB,ordinary,implicitAdmin,disabled;
    static String before,after,customBefore,customAfter;
    static boolean unknownRefused;
    record Actor(UUID employee,UUID user) { }

    @BeforeAll static void prepare() throws Exception {
        PG.start();
        TestFlyway.configure().dataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword())
                .locations("classpath:db/migration").target("981").load().migrate();
        db=new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword()));
        String migration=new ClassPathResource("db/migration/V982__warehouse_notice_supervisor_keeper_union.sql")
                .getContentAsString(StandardCharsets.UTF_8);
        before=attributes(db);
        try(Connection c=connection()) {
            c.setAutoCommit(false);
            try(Statement s=c.createStatement()) {
                s.execute("CREATE ROLE notice_union_owner NOLOGIN");
                s.execute("CREATE ROLE notice_union_reader NOLOGIN");
                s.execute("ALTER FUNCTION public.fn_warehouse_notice_recipients(uuid[],uuid[]) OWNER TO notice_union_owner");
                s.execute("GRANT EXECUTE ON FUNCTION public.fn_warehouse_notice_recipients(uuid[],uuid[]) TO notice_union_reader");
                s.execute("ALTER FUNCTION public.fn_warehouse_notice_recipients(uuid[],uuid[]) SECURITY DEFINER STRICT PARALLEL RESTRICTED COST 17 SET search_path TO public,pg_temp");
                customBefore=attributes(c);s.execute(migration);customAfter=attributes(c);
            } finally {c.rollback();}
        }
        try(Connection c=connection()) {
            c.setAutoCommit(false);
            try(Statement s=c.createStatement()) {
                String definition=db.queryForObject("SELECT pg_get_functiondef('public.fn_warehouse_notice_recipients(uuid[],uuid[])'::regprocedure)",String.class);
                s.execute(definition.replace("ELSE ARRAY(SELECT id FROM pool ORDER BY id)","ELSE ARRAY(SELECT id FROM pool WHERE id IS NOT NULL ORDER BY id)"));
                Savepoint prior=c.setSavepoint();
                try {s.execute(migration);}catch(SQLException expected) {unknownRefused=true;c.rollback(prior);}
            } finally {c.rollback();}
        }
        TestFlyway.configure().dataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword())
                .locations("classpath:db/migration").target("982").load().migrate();
        after=attributes(db);
        UUID dept=department("UNION-ORDINARY");
        UUID wh=db.queryForList("SELECT id FROM departments WHERE code='SUB_WH' AND NOT is_deleted",UUID.class).getFirst();
        root=db.queryForObject("SELECT fn_warehouse_root_id()",UUID.class);
        if(root==null)root=warehouse("001",null);
        a=warehouse("UNION-A",root);b=warehouse("UNION-B",root);
        supervisor=actor("supervisor",wh,false);mainKeeper=actor("root-keeper",dept,false);
        keeperA=actor("a",dept,false);keeperB=actor("b",dept,false);
        ordinary=actor("ordinary",dept,false);implicitAdmin=actor("implicit-admin",dept,true);disabled=actor("disabled",dept,false);
        db.update("UPDATE departments SET manager_id=? WHERE id=?",supervisor.employee(),wh);
        keeper(root,mainKeeper);keeper(a,keeperA);keeper(b,keeperB);keeper(a,disabled);
        db.update("UPDATE users SET status='disabled' WHERE id=?",disabled.user());
    }
    @AfterAll static void stop(){PG.stop();}

    @Test void forwardUpgradePreservesIdentityGrantsAndAllExecutionAttributesAndRefusesUnknownBody() {
        assertThat(after).isEqualTo(before);assertThat(customAfter).isEqualTo(customBefore);assertThat(unknownRefused).isTrue();
    }
    @Test void qualifiedSupervisorsAndOnlyRelevantChildKeepersAreAUnion() throws Exception {
        var pool=List.of(ordinary.user(),keeperA.user(),supervisor.user(),mainKeeper.user(),keeperB.user(),implicitAdmin.user(),disabled.user());
        assertThat(recipients(List.of(a),pool)).containsExactlyElementsOf(sorted(supervisor.user(),mainKeeper.user(),keeperA.user()));
        assertThat(recipients(List.of(b),pool)).containsExactlyElementsOf(sorted(supervisor.user(),mainKeeper.user(),keeperB.user()));
        assertThat(recipients(List.of(a,b,a),pool)).containsExactlyElementsOf(sorted(supervisor.user(),mainKeeper.user(),keeperA.user(),keeperB.user()));
        keeper(a,supervisor);
        try {assertThat(recipients(List.of(a),pool)).containsExactlyElementsOf(sorted(supervisor.user(),mainKeeper.user(),keeperA.user()));}
        finally {db.update("DELETE FROM warehouse_keepers WHERE warehouse_id=? AND employee_id=?",a,supervisor.employee());}
    }
    @Test void noActorEscapesTheExactPermissionPoolAndImplicitAdminIsNotADesignatedSupervisor() throws Exception {
        assertThat(recipients(List.of(a),List.of(keeperA.user(),keeperB.user(),implicitAdmin.user()))).containsExactly(keeperA.user());
        assertThat(recipients(List.of(a),List.of(supervisor.user(),keeperB.user()))).containsExactly(supervisor.user());
        assertThat(recipients(List.of(a),List.of(disabled.user(),supervisor.user()))).containsExactly(supervisor.user());
        assertThat(recipients(List.of(a),List.of(ordinary.user(),implicitAdmin.user()))).containsExactlyElementsOf(sorted(ordinary.user(),implicitAdmin.user()));
    }
    @Test void nullEmptyUnknownAndDuplicateInputsPreserveTheOriginalFallback() throws Exception {
        assertThat(recipients(null,List.of(supervisor.user(),ordinary.user()))).containsExactly(supervisor.user());
        assertThat(recipients(List.of(UUID.randomUUID()),List.of(supervisor.user(),ordinary.user()))).containsExactly(supervisor.user());
        assertThat(recipients(List.of(a),null)).isEmpty();assertThat(recipients(List.of(a),List.of())).isEmpty();
        assertThat(recipients(Arrays.asList(null,a,a),Arrays.asList(null,supervisor.user(),keeperA.user(),keeperA.user())))
                .containsExactlyElementsOf(sorted(supervisor.user(),keeperA.user()));
        assertThat(recipients(List.of(b),Arrays.asList(null,ordinary.user(),ordinary.user())))
                .containsExactly(ordinary.user(),null);
    }
    @Test void eachResponsibilityHelperRunsOnceForOneEvaluationIndependentOfPoolSize() throws Exception {
        try(Connection c=connection()) {
            c.setAutoCommit(false);
            try(Statement s=c.createStatement()) {s.execute("SET LOCAL track_functions='all'");}
            var pool=new ArrayList<UUID>();for(int i=0;i<128;i++)pool.add(UUID.randomUUID());pool.add(supervisor.user());
            recipients(c,List.of(a),pool);
            try(Statement s=c.createStatement();ResultSet r=s.executeQuery("SELECT funcname,calls FROM pg_stat_xact_user_functions WHERE funcname IN ('fn_warehouse_keeper_user_ids','fn_warehouse_designated_supervisor_user_ids')")) {
                Map<String,Long> calls=new HashMap<>();while(r.next())calls.put(r.getString(1),r.getLong(2));
                assertThat(calls).containsEntry("fn_warehouse_keeper_user_ids",1L).containsEntry("fn_warehouse_designated_supervisor_user_ids",1L);
            } finally {c.rollback();}
        }
    }
    static Connection connection() throws Exception{return DriverManager.getConnection(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());}
    static String attributes(JdbcTemplate jdbc){return jdbc.queryForObject("SELECT (to_jsonb(p)-'prosrc'-'prosqlbody')::text FROM pg_proc p WHERE oid='public.fn_warehouse_notice_recipients(uuid[],uuid[])'::regprocedure",String.class);}
    static String attributes(Connection c)throws Exception {try(Statement s=c.createStatement();ResultSet r=s.executeQuery("SELECT (to_jsonb(p)-'prosrc'-'prosqlbody')::text FROM pg_proc p WHERE oid='public.fn_warehouse_notice_recipients(uuid[],uuid[])'::regprocedure")){r.next();return r.getString(1);}}
    static List<UUID> recipients(List<UUID> warehouses,List<UUID> pool)throws Exception {try(Connection c=connection()){return recipients(c,warehouses,pool);}}
    static List<UUID> recipients(Connection c,List<UUID> warehouses,List<UUID> pool)throws Exception {
        try(PreparedStatement p=c.prepareStatement("SELECT public.fn_warehouse_notice_recipients(CAST(? AS uuid[]),CAST(? AS uuid[]))")) {
            Array w=warehouses==null?null:c.createArrayOf("uuid",warehouses.toArray());Array a=pool==null?null:c.createArrayOf("uuid",pool.toArray());
            try {p.setArray(1,w);p.setArray(2,a);try(ResultSet r=p.executeQuery()){r.next();Array value=r.getArray(1);if(value==null)return List.of();try{return Arrays.stream((Object[])value.getArray()).map(id->id==null?null:UUID.fromString(id.toString())).toList();}finally{value.free();}}}
            finally {if(w!=null)w.free();if(a!=null)a.free();}
        }
    }
    static List<UUID> sorted(UUID... ids){return Arrays.stream(ids).sorted(Comparator.comparing(UUID::toString)).toList();}
    static UUID department(String code){UUID id=UUID.randomUUID();db.update("INSERT INTO departments(id,code,name,level) VALUES(?,?,?,'一级部门')",id,code,code);return id;}
    static UUID warehouse(String code,UUID parent){UUID id=UUID.randomUUID();db.update("INSERT INTO warehouses(id,code,name,status,is_accountable,parent_id) VALUES(?,?,?,'使用',true,?)",id,code,code,parent);return id;}
    static Actor actor(String tag,UUID dept,boolean admin){var actor=new Actor(UUID.randomUUID(),UUID.randomUUID());db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,?,'其他',?,current_date,'active','regular')",actor.employee(),"UNION-"+tag,"Union "+tag,dept);db.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,is_super_admin,status) VALUES(?,?,?,'synthetic-notice-only',false,?,'active')",actor.user(),actor.employee(),"notice-union-"+tag,admin);return actor;}
    static void keeper(UUID warehouse,Actor actor){db.update("INSERT INTO warehouse_keepers(warehouse_id,employee_id) VALUES(?,?)",warehouse,actor.employee());}
}
