package com.uten.imp.features.org.employee;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.util.IdCardUtil;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import java.sql.*;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

/** Real V948 data/guards, reusing the component suite's owned-role database fixture. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class EmployeeIdentityMergeDataPostgresTest {
    static final String DOC="11010519491231002X",OTHER_DOC="11010519860101001X";
    static final ObjectMapper JSON=new ObjectMapper();
    String name,url;JdbcTemplate db;
    @BeforeAll static void template() throws Exception {EmployeeCodeReuseExtensionPostgresTest.template();}
    @AfterAll static void stop(){EmployeeCodeReuseExtensionPostgresTest.stop();}
    @BeforeEach void fresh() throws Exception {
        name="employee_merge_data_"+UUID.randomUUID().toString().replace("-","");
        try(var c=base();var s=c.createStatement()){s.execute("CREATE DATABASE \""+name+"\" TEMPLATE employee_code_948");}
        url=EmployeeCodeReuseExtensionPostgresTest.postgres.getJdbcUrl().replace("/employee_code_template","/"+name);
        db=new JdbcTemplate(new DriverManagerDataSource(url,EmployeeCodeReuseExtensionPostgresTest.postgres.getUsername(),EmployeeCodeReuseExtensionPostgresTest.postgres.getPassword()));
    }
    @AfterEach void drop() throws Exception {try(var c=base();var s=c.createStatement()){s.execute("DROP DATABASE \""+name+"\" WITH(FORCE)");}}
    static Connection base() throws Exception {var p=EmployeeCodeReuseExtensionPostgresTest.postgres;return DriverManager.getConnection(p.getJdbcUrl(),p.getUsername(),p.getPassword());}
    Connection connection() throws Exception {var p=EmployeeCodeReuseExtensionPostgresTest.postgres;return DriverManager.getConnection(url,p.getUsername(),p.getPassword());}
    void install() throws Exception {
        try(var c=connection()){c.setAutoCommit(false);try(var s=c.createStatement()){s.execute("SET LOCAL ROLE uten_migrator");}
            try(var q=c.prepareStatement("SELECT set_config('app.employee_identity_merge_install_sha',?,true)")){q.setString(1,EmployeeCodeReuseExtensionPostgresTest.parentSha);q.execute();}
            try(var s=c.createStatement()){s.execute(EmployeeCodeReuseExtensionPostgresTest.parentInstaller);s.execute(EmployeeCodeReuseExtensionPostgresTest.codeInstaller);}c.commit();}
    }
    UUID employee(String code,String fullName,Integer legacy) {
        UUID id=UUID.randomUUID();db.update("""
            INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,confirmed_at,status,employment_type,legacy_id)
            SELECT ?,?,?,'身份证',department_id,DATE '2020-01-01',DATE '2020-01-01','active','regular',? FROM employees WHERE code='ADMIN'
            """,id,code,fullName,legacy);return id;
    }
    String hash(String value){return db.queryForObject("SELECT encode(hmac(?,'synthetic-identity-key','sha256'),'hex')",String.class,value);}
    String cipher(String value){return db.queryForObject("SELECT 'v1:'||encode(pgp_sym_encrypt(?,'synthetic-identity-key'),'base64')",String.class,value);}
    String merge(UUID source,UUID retained,Map<String,Object> options) throws Exception {
        String query="""
            WITH scope AS MATERIALIZED(SELECT fn_employee_merge_source_snapshot(?) AS data),
            envelope AS MATERIALIZED(SELECT 'v1:'||encode(pgp_sym_encrypt(data::text,'synthetic-private-preservation-key'),'base64') AS cipher FROM scope)
            SELECT (jsonb_build_object('protocol','employee-identity-merge-v1','database_identity',fn_employee_merge_database_identity(),
              'captured_at',clock_timestamp(),'paired_backup_verified',true,'paired_backup_reference','synthetic-paired-backup','paired_backup_manifest_sha256',repeat('c',64),
              'source_employee_id',source.id,'canonical_employee_id',retained.id,'source_code',source.code,'source_version',source.version,'canonical_version',retained.version,
              'canonical_row_sha256',encode(digest(to_jsonb(retained)::text,'sha256'),'hex'),'source_scope_sha256',encode(digest(scope.data::text,'sha256'),'hex'),
              'snapshot_enc',envelope.cipher,'snapshot_ciphertext_sha256',encode(digest(envelope.cipher,'sha256'),'hex'),
              'human_same_person_confirmed',true,'preservation_verified',true,'preservation_reference','synthetic-private-preimage','preservation_sha256',repeat('a',64),
              'evidence_reference','synthetic-person-field-review','evidence_sha256',repeat('b',64),'actor','ops:synthetic-data-test',
              'reason','Explicit synthetic same-person identity evidence','expected_stock_worker_count',0,'claims','[]'::jsonb)||CAST(? AS jsonb))::text
            FROM employees source CROSS JOIN employees retained CROSS JOIN scope CROSS JOIN envelope WHERE source.id=? AND retained.id=?
            """;
        try(var c=connection()){c.setAutoCommit(false);try(var s=c.createStatement()){s.execute("SET LOCAL ROLE uten_migrator");}
            String plan;try(var q=c.prepareStatement(query)){q.setObject(1,source);q.setString(2,JSON.writeValueAsString(options));q.setObject(3,source);q.setObject(4,retained);try(var r=q.executeQuery()){assertThat(r.next()).isTrue();plan=r.getString(1);}}
            String result;try(var q=c.prepareStatement("SELECT fn_merge_employee_identity(CAST(? AS jsonb))::text")){q.setString(1,plan);try(var r=q.executeQuery()){assertThat(r.next()).isTrue();result=r.getString(1);}}
            c.commit();return result;}
    }

    @Test void encryptedNullHashHistoryEducationAndIdentifierEvidenceSurvivePhysicalRemoval() throws Exception {
        assertThat(IdCardUtil.isValid(DOC)).isTrue();
        UUID retained=employee("UT8801","Historical merged person",null),source=employee("UT8802","Historical merged person",509);
        UUID primaryEducation=UUID.randomUUID(),sameEducation=UUID.randomUUID(),otherEducation=UUID.randomUUID();
        db.update("INSERT INTO employee_education(id,employee_id,school,degree) VALUES(?,?,'Synthetic school','本科'),(?,?,'Synthetic school','本科'),(?,?,'Other synthetic school','专科')",primaryEducation,retained,sameEducation,source,otherEducation,source);
        db.update("INSERT INTO employee_sensitive(employee_id,id_card_enc,id_card_check,id_card_hash,phone_enc,phone_hash) VALUES(?,?,'valid',NULL,?,?)",source,cipher(DOC),cipher("13812340001"),hash("13812340001"));
        install();
        String result=merge(source,retained,Map.of("fill_missing_legacy",true,"claims",List.of(
            Map.of("kind","DOCUMENT","hash",hash(DOC),"ownership_verified",true),Map.of("kind","PHONE","hash",hash("13812340001"),"ownership_verified",false))));
        assertThat(result).contains("MERGED","verified_equal");
        assertThat(db.queryForObject("SELECT count(*) FROM employees WHERE id=?",Long.class,source)).isZero();
        assertThat(db.queryForObject("SELECT legacy_id FROM employees WHERE id=?",Integer.class,retained)).isEqualTo(509);
        assertThat(db.queryForObject("SELECT count(*) FROM employee_education WHERE employee_id=?",Long.class,retained)).isEqualTo(2);
        assertThat(db.queryForObject("SELECT employee_id FROM employee_education WHERE id=?",UUID.class,primaryEducation)).isEqualTo(retained);
        assertThat(db.queryForObject("SELECT count(*) FROM business_record_history WHERE source_table='employee_education' AND source_id IN(?,?) AND operation='DELETE'",Long.class,sameEducation.toString(),otherEducation.toString())).isEqualTo(2);
        assertThat(db.queryForObject("SELECT fn_canonical_employee_identity(?)",UUID.class,source)).isEqualTo(retained);
        assertThat(db.queryForObject("SELECT count(*) FROM employee_identity_historical_claims WHERE canonical_employee_id=?",Long.class,retained)).isEqualTo(2);
        UUID stranger=employee("UT8803","Another unique person",null);
        assertThatThrownBy(()->db.update("INSERT INTO employee_sensitive(employee_id,id_card_enc,id_card_check,id_card_hash) VALUES(?,?,'valid',?)",stranger,cipher(DOC),hash(DOC))).rootCause().satisfies(cause->{
            assertThat(cause).isInstanceOf(org.postgresql.util.PSQLException.class);
            var rejected=(org.postgresql.util.PSQLException)cause;
            assertThat(rejected.getSQLState()).isEqualTo("23505");
            assertThat(rejected.getServerErrorMessage().getConstraint()).isEqualTo("employee_historical_identity_claim");
        });
        assertThatThrownBy(()->db.update("INSERT INTO employee_sensitive(employee_id,phone_enc,phone_hash) VALUES(?,?,?)",stranger,cipher("13812340001"),hash("13812340001"))).hasMessageContaining("待核验");
        assertThatThrownBy(()->employeeWithId(source,"UT8804","Retired UUID must not return",null)).hasMessageContaining("retired employee UUID");
        assertThatThrownBy(()->employee("UT8805","Retired worker identity must not return",509)).hasMessageContaining("B_WORKER identity");
    }

    @Test void sameNameNeedsOwnedReviewButUniqueMissingPiiAndExistingUpdatesRemainAllowed() throws Exception {
        String shared="Same name actual distinct persons";UUID first=employee("UT8811",shared,null);install();
        db.update("INSERT INTO employee_sensitive(employee_id,id_card_enc,id_card_check,id_card_hash) VALUES(?,?,'valid',?)",first,cipher(DOC),hash(DOC));
        assertThatThrownBy(()->employee("UT8812",shared,null)).hasMessageContaining("同名");
        UUID unique=employee("UT8813","Unique controlled record without identity",null);
        db.update("INSERT INTO employee_sensitive(employee_id,email_enc) VALUES(?,?)",unique,cipher("synthetic@example.invalid"));
        db.update("UPDATE employees SET status='resigned' WHERE id=?",unique);
        db.update("UPDATE employees SET status='active' WHERE id=?",unique);
        UUID second=UUID.randomUUID();assertThat(IdCardUtil.isValid(OTHER_DOC)).isTrue();
        db.update("INSERT INTO employee_identity_review_certificates(review_kind,new_employee_id,normalized_name,new_document_hash,existing_snapshot_sha256,evidence_reference,evidence_sha256,reviewed_by,expires_at) VALUES('NAME_DISTINCT',?,?,?,fn_employee_merge_name_snapshot_sha(?),'synthetic-distinct-original-documents',repeat('f',64),'synthetic-owner',clock_timestamp()+interval '1 hour')",second,shared,hash(OTHER_DOC),shared);
        try(var c=connection()){c.setAutoCommit(false);try(var s=c.createStatement()){s.execute("SET LOCAL ROLE uten");}
            employeeWithId(c,second,"UT8814",shared,null);
            try(var q=c.prepareStatement("INSERT INTO employee_sensitive(employee_id,id_card_enc,id_card_check,id_card_hash) VALUES(?,?,'valid',?)")){q.setObject(1,second);q.setString(2,cipher(OTHER_DOC));q.setString(3,hash(OTHER_DOC));q.executeUpdate();}c.commit();}
        assertThat(db.queryForObject("SELECT count(*) FROM employees WHERE full_name=?",Long.class,shared)).isEqualTo(2);
    }

    @Test void actualRuntimeCannotCallRawSnapshotOrApplyOrForgeReviewCertificate() throws Exception {
        install();
        for(String sql:List.of("SELECT fn_employee_merge_source_snapshot('00000000-0000-0000-0000-000000000001')",
            "SELECT fn_merge_employee_identity('{}'::jsonb)","INSERT INTO employee_identity_review_certificates(id,review_kind,new_employee_id,evidence_reference,evidence_sha256,reviewed_by,expires_at) VALUES(gen_random_uuid(),'IDENTIFIER',gen_random_uuid(),'untrusted',repeat('a',64),'untrusted',now()+interval '1 hour')")) {
            try(var c=connection()){c.setAutoCommit(false);try(var s=c.createStatement()){s.execute("SET LOCAL ROLE uten");}
                assertThatThrownBy(()->{try(var s=c.createStatement()){s.execute(sql);}}).isInstanceOf(SQLException.class).extracting(e->((SQLException)e).getSQLState()).isEqualTo("42501");c.rollback();}
        }
    }

    @Test void aRetiredWorkerIntegerCannotBeReusedWhenRetainedPrimaryKeepsAnotherLegacyId() throws Exception {
        UUID source=employee("UT8831","Retired worker source",362),retained=employee("UT8832","Retained worker primary",231);
        install();merge(source,retained,Map.of());
        assertThat(db.queryForObject("SELECT legacy_id FROM employees WHERE id=?",Integer.class,retained)).isEqualTo(231);
        assertThat(db.queryForObject("SELECT fn_employee_identity_from_legacy_worker(362)",UUID.class)).isEqualTo(retained);
        assertThatThrownBy(()->employee("UT8833","Unrelated new worker",362)).hasMessageContaining("B_WORKER identity");
        assertThat(db.queryForObject("SELECT count(*) FROM employees WHERE legacy_id=362",Long.class)).isZero();
    }

    @Test void typedApplicantProjectionAndStockActorPreserveEveryOtherNumericAndLifecycleField() throws Exception {
        UUID source=employee("UT8821","Projection same-person source",509),retained=employee("UT8822","Projection retained person",null);
        UUID stock=UUID.randomUUID();
        db.update("INSERT INTO stock_documents(id,legacy_id,doc_type,bill_no,bill_date,worker_id,worker_legacy_id,total_original,total_local,status) VALUES(?,987001,'OTHER_OUT','QC20261028008821',DATE '2026-10-28',?,509,9007199254740.1234,9007199254740.1234,1)",stock,source);
        for(int i=0;i<4;i++)db.update("INSERT INTO purchase_requests(id,legacy_id,bill_no,bill_date,applicant_legacy_id,total_original,total_local,status,is_deleted) VALUES(?,? ,?,DATE '2026-10-28',509,9007199254740.1234,9007199254740.1234,?,?)",UUID.randomUUID(),987101+i,"CS2026102800882"+i,(short)(i==2?0:i==3?-1:1),i==1);
        String stockBefore=db.queryForObject("SELECT encode(digest((to_jsonb(s)-ARRAY['worker_id','updated_at','updated_by','version','row_version','lock_version'])::text,'sha256'),'hex') FROM stock_documents s WHERE id=?",String.class,stock);
        String requestsBefore=db.queryForObject("SELECT encode(digest(jsonb_agg(to_jsonb(r)-ARRAY['applicant_id','updated_at','updated_by','version','row_version','lock_version'] ORDER BY id)::text,'sha256'),'hex') FROM purchase_requests r WHERE applicant_legacy_id=509",String.class);
        install();String result=merge(source,retained,Map.of("fill_missing_legacy",true,"expected_stock_worker_count",1,"legacy_projections",List.of(Map.of("table","purchase_requests","column","applicant_id","expected_null_count",4))));
        assertThat(result).contains("\"legacy_projection_rows\": 4","\"stock_worker_rows\": 1","verified_equal");
        assertThat(db.queryForObject("SELECT worker_id FROM stock_documents WHERE id=?",UUID.class,stock)).isEqualTo(retained);
        assertThat(db.queryForObject("SELECT count(*) FROM purchase_requests WHERE applicant_legacy_id=509 AND applicant_id=?",Long.class,retained)).isEqualTo(4);
        assertThat(db.queryForObject("SELECT encode(digest((to_jsonb(s)-ARRAY['worker_id','updated_at','updated_by','version','row_version','lock_version'])::text,'sha256'),'hex') FROM stock_documents s WHERE id=?",String.class,stock)).isEqualTo(stockBefore);
        assertThat(db.queryForObject("SELECT encode(digest(jsonb_agg(to_jsonb(r)-ARRAY['applicant_id','updated_at','updated_by','version','row_version','lock_version'] ORDER BY id)::text,'sha256'),'hex') FROM purchase_requests r WHERE applicant_legacy_id=509",String.class)).isEqualTo(requestsBefore);
    }

    void employeeWithId(UUID id,String code,String fullName,Integer legacy) {try(var c=connection()){employeeWithId(c,id,code,fullName,legacy);}catch(Exception e){throw new RuntimeException(e);}}
    void employeeWithId(Connection c,UUID id,String code,String fullName,Integer legacy) throws Exception {
        try(var q=c.prepareStatement("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,confirmed_at,status,employment_type,legacy_id) SELECT ?,?,?,'身份证',department_id,DATE '2020-01-01',DATE '2020-01-01','active','regular',? FROM employees WHERE code='ADMIN'")){q.setObject(1,id);q.setString(2,code);q.setString(3,fullName);q.setObject(4,legacy);q.executeUpdate();}
    }
}
