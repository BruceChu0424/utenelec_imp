package com.uten.imp.features.org.department.staffpermission;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.support.MigratedProjectionSchema;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import static org.assertj.core.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class DepartmentPermissionStaffHeaderPostgresTest {
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    private static JdbcTemplate db;
    @BeforeAll static void start() {
        PG.start();db=new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword()));
        MigratedProjectionSchema.createCurrentTables(db,"departments","positions","employees","users","employee_vehicles");
    }
    @AfterAll static void stop(){PG.stop();}
    @BeforeEach void clean(){db.execute("TRUNCATE users,employees,positions,departments");}
    @Test void allTextHeadersAndLiveAccountStatesRemainInsideManagerScopeBeforeCountAndPaging() {
        UUID department=department("销售%_部"),outside=department("范围外"),position=position();
        UUID manager=employee(department,position,"M","经理","active");
        db.update("UPDATE departments SET manager_id=? WHERE id=?",manager,department);
        UUID first=employee(department,position,"A","人员%_甲","probation");
        UUID second=employee(department,position,"B","人员%_乙","probation");
        UUID hidden=employee(outside,position,"Z","人员%_外部","probation");
        UUID resigned=employee(department,position,"C","人员%_离职","resigned");
        UUID deleted=employee(department,position,"D","人员%_删除","probation");
        db.update("UPDATE employees SET is_deleted=true WHERE id=?",deleted);
        for(UUID employee:java.util.List.of(manager,first,second,hidden,resigned,deleted))account(employee,"active",false);
        var query=new DepartmentPermissionStaffQuery(db);var authority=authority(manager);
        var headers=PagePermissionStaffHeaderQuery.read(Map.of("search.name","人员%_","search.employeeCode","",
                "search.department","销售%_部","search.position","业务%_员","accountStatus","active",
                "employmentStatus","probation","sort","employeeCode","order","desc"));
        var one=query.query(authority,department,manager,"人员",1,1,headers);
        var two=query.query(authority,department,manager,"人员",2,1,headers);
        assertThat(one.total()).isEqualTo(2);
        assertThat(one.totalPages()).isEqualTo(2);
        assertThat(one.staff()).extracting(DepartmentPermissionStaffQuery.StaffProjection::employeeId).containsExactly(second);
        assertThat(two.staff()).extracting(DepartmentPermissionStaffQuery.StaffProjection::employeeId).containsExactly(first);
        assertThat(query.query(authority,department,manager,null,1,20,
                PagePermissionStaffHeaderQuery.read(Map.of("search.name","人员__"))).total()).isZero();
        assertThat(query.query(authority,department,manager,null,1,20,
                PagePermissionStaffHeaderQuery.read(Map.of("search.employeeCode","B"))).staff())
                .extracting(DepartmentPermissionStaffQuery.StaffProjection::employeeId).containsExactly(second);
    }
    @Test void deletedAccountsRemainUnprovisionedAndStatusChoicesNeverWidenCurrentEmploymentEligibility() {
        UUID department=department("销售部"),position=position();
        UUID manager=employee(department,position,"M","经理","active");
        db.update("UPDATE departments SET manager_id=? WHERE id=?",manager,department);
        UUID absent=employee(department,position,"A","未开通","probation");
        UUID deleted=employee(department,position,"B","旧账号已删","probation");account(deleted,"active",true);
        UUID disabled=employee(department,position,"C","停用","onLeave");account(disabled,"disabled",false);
        var query=new DepartmentPermissionStaffQuery(db);var authority=authority(manager);
        assertThat(query.query(authority,department,manager,null,1,20,PagePermissionStaffHeaderQuery.read(
                Map.of("accountStatus","notProvisioned","employmentStatus","probation"))).staff())
                .extracting(DepartmentPermissionStaffQuery.StaffProjection::employeeId).containsExactlyInAnyOrder(absent,deleted);
        assertThat(query.query(authority,department,manager,null,1,20,PagePermissionStaffHeaderQuery.read(
                Map.of("accountStatus","disabled","employmentStatus","onLeave"))).staff())
                .extracting(DepartmentPermissionStaffQuery.StaffProjection::employeeId).containsExactly(disabled);
        assertThatThrownBy(()->PagePermissionStaffHeaderQuery.read(Map.of("employmentStatus","resigned"))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->PagePermissionStaffHeaderQuery.read(Map.of("sort","employee.id;DROP TABLE users"))).isInstanceOf(ApiException.class);
    }
    @Test void employeeRelationshipPickerSharesHeaderSemanticsWithoutReplacingItsFixedStatusesOrDepartmentMembership() {
        UUID department=department("选择范围"),outside=department("范围外"),position=position();
        UUID first=employee(department,position,"A","员工%_甲","active");account(first,"disabled",false);
        UUID second=employee(department,position,"B","员工%_乙","active");account(second,"disabled",false);
        UUID probation=employee(department,position,"C","员工%_试用","probation");account(probation,"disabled",false);
        UUID hidden=employee(outside,position,"Z","员工%_外部","active");account(hidden,"disabled",false);
        var query=new com.uten.imp.features.org.employee.EmployeeListQuery(db);
        var eligible=java.util.Set.of("active","probation","onLeave");
        var headers=Map.of("search.name","员工%_","search.department","选择范围","accountStatus","disabled","employmentStatus","active");
        var one=query.query(1,1,"员工",eligible,java.util.List.of(department),true,"employeeCode","desc",headers);
        var two=query.query(2,1,"员工",eligible,java.util.List.of(department),true,"employeeCode","desc",headers);
        assertThat(one.total()).isEqualTo(2);
        assertThat(one.items()).extracting(com.uten.imp.features.org.employee.dto.EmployeeListItem::getId).containsExactly(second);
        assertThat(two.items()).extracting(com.uten.imp.features.org.employee.dto.EmployeeListItem::getId).containsExactly(first);
        assertThat(one.items().getFirst().getAccountStatus()).isEqualTo("disabled");
        assertThat(query.query(1,20,null,eligible,java.util.List.of(department),true,null,null,
                Map.of("employmentStatus","resigned")).total()).isZero();
    }
    private static OrganizationPermissionManagementScopeService.StaffSearchAuthority authority(UUID manager) {
        return new OrganizationPermissionManagementScopeService.StaffSearchAuthority(
                OrganizationPermissionManagementScopeService.StaffSearchScope.MANAGER_SUBTREES,manager);
    }
    private UUID department(String name) {
        UUID id=UUID.randomUUID();db.update("INSERT INTO departments(id,code,name,level,is_deleted) VALUES(?,?,?,'一级部门',false)",id,"D-"+id,name);return id;
    }
    private UUID position() {
        UUID id=UUID.randomUUID();db.update("INSERT INTO positions(id,code,name,is_deleted) VALUES(?,?,'业务%_员',false)",id,"P-"+id);return id;
    }
    private UUID employee(UUID department,UUID position,String code,String name,String status) {
        UUID id=UUID.randomUUID();db.update("INSERT INTO employees(id,code,full_name,department_id,position_id,status,is_deleted) VALUES(?,?,?,?,?,?,false)",id,code,name,department,position,status);return id;
    }
    private void account(UUID employee,String status,boolean deleted) {
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash,status,is_deleted) VALUES(?,?,?,'not-a-real-secret',?,?)",UUID.randomUUID(),employee,"U-"+employee,status,deleted);
    }
}
