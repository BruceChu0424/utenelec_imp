package com.uten.imp.features.org.hrtask;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;

import java.sql.Date;
import java.sql.ResultSet;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** 证件核对任务 (V807)：只读已存的校验结果，只给能改证件的人列出并计红。 */
class HrTaskServiceIdentityReviewTest {

    private JdbcTemplate jdbc;
    private HrTaskClaimService claims;
    private SecurityContextCurrentUser current;
    private HrTaskService service;
    private final List<ResultSet> rows = new ArrayList<>();
    private final UUID me = UUID.randomUUID();
    private UUID invalidEmployee;
    private UUID missingEmployee;

    @BeforeEach
    @SuppressWarnings({"rawtypes", "unchecked"})
    void setUp() throws Exception {
        jdbc = mock(JdbcTemplate.class);
        claims = mock(HrTaskClaimService.class);
        current = mock(SecurityContextCurrentUser.class);
        when(claims.activeClaimsByTaskKey()).thenReturn(Map.of());
        when(current.employeeId()).thenReturn(Optional.of(me));
        LocalDate hired = BusinessTime.today().minusYears(2).plusDays(3);
        invalidEmployee = row("UT0003", hired, false, "check_digit", false);
        missingEmployee = row("UT0001", hired, true, null, false);
        row("UT0002", hired, false, "unchecked", false);
        row("UT0004", hired, false, "valid", false);
        row("UT0005", hired, true, null, true);            // 超管：人事改不了，不列
        row("UT0006", hired, false, "length:17", true);    // 超管
        when(jdbc.query(anyString(), any(RowMapper.class))).thenAnswer(invocation -> {
            RowMapper mapper = invocation.getArgument(1);
            List<Object> mapped = new ArrayList<>();
            for (int i = 0; i < rows.size(); i++) {
                mapped.add(mapper.mapRow(rows.get(i), i));
            }
            return mapped;
        });
        service = new HrTaskService(jdbc, claims, current);
    }

    @Test
    void invalidMissingAndUncheckedProduceTasksWithTheSpecificReason() {
        signIn(Set.of("employee:view", "employee:pii:view", "employee:pii:edit"), false);

        HrTaskSummary summary = service.summary();

        assertThat(summary.identityReview()).extracting(HrTaskSummary.Item::code)
                .containsExactly("UT0001", "UT0002", "UT0003");
        assertThat(summary.identityReview()).extracting(HrTaskSummary.Item::note).containsExactly(
                "档案里没有证件号码",
                "证件号码来自历史资料导入，系统还没有完成校验",
                "身份证号第18位校验码与前17位不符，通常是某一位数字录错或相邻两位颠倒，请对照证件逐位核对");
        assertThat(summary.identityReview()).allSatisfy(item -> {
            assertThat(item.days()).isZero();
            assertThat(item.date()).isEqualTo(BusinessTime.today().minusYears(2).plusDays(3));
        });
        assertThat(summary.badgeCount()).isEqualTo(3);
    }

    @Test
    void usersWhoCannotEditIdentityGetAnEmptyListAndNoCount() {
        signIn(Set.of("employee:view", "employee:pii:view"), false);

        HrTaskSummary summary = service.summary();

        assertThat(summary.identityReview()).isEmpty();
        assertThat(summary.badgeCount()).isZero();
    }

    @Test
    void superAdminSeesAndCountsTheTasks() {
        signIn(Set.of(), true);

        HrTaskSummary summary = service.summary();

        assertThat(summary.identityReview()).hasSize(3);
        assertThat(summary.badgeCount()).isEqualTo(3);
    }

    @Test
    void claimsAreMatchedByTheIdentityKeyAndStillCountRed() {
        signIn(Set.of("employee:view", "employee:pii:edit"), false);
        HrTaskClaim mine = claim("identity", invalidEmployee, me);
        HrTaskClaim confirmClaim = claim("confirm", missingEmployee, UUID.randomUUID());
        when(claims.activeClaimsByTaskKey()).thenReturn(Map.of(
                "identity:" + invalidEmployee, mine,
                "confirm:" + missingEmployee, confirmClaim));
        when(claims.claimantName(me)).thenReturn("人事专员");

        HrTaskSummary summary = service.summary();

        HrTaskSummary.Item claimed = summary.identityReview().stream()
                .filter(item -> item.employeeId().equals(invalidEmployee)).findFirst().orElseThrow();
        assertThat(claimed.claimedByMe()).isTrue();
        assertThat(claimed.claimedByName()).isEqualTo("人事专员");
        HrTaskSummary.Item other = summary.identityReview().stream()
                .filter(item -> item.employeeId().equals(missingEmployee)).findFirst().orElseThrow();
        assertThat(other.claimedByName()).as("a confirm claim is not an identity claim").isNull();
        assertThat(summary.badgeCount()).isEqualTo(3);
    }

    @Test
    void serializedSummaryCarriesNoIdentityDigits() throws Exception {
        signIn(Set.of("employee:view", "employee:pii:view", "employee:pii:edit"), false);

        String json = new ObjectMapper().registerModule(new JavaTimeModule())
                .writeValueAsString(service.summary());

        // 去掉员工 UUID 后，不允许出现任何像证件号的连续数字；也不带号码、后四位或存储码。
        String withoutIds = json.replaceAll(
                "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", "<id>");
        assertThat(withoutIds).contains("\"identityReview\"")
                .doesNotContainPattern("[0-9]{6,}")
                .doesNotContain("idNumber", "idCardLast4", "last4", "id_card_check", "check_digit");
    }

    private void signIn(Set<String> permissions, boolean superAdmin) {
        when(current.get()).thenReturn(Optional.of(new AuthUser(
                UUID.randomUUID(), me, "hr-identity-test", permissions, false, true, superAdmin)));
    }

    private UUID row(String code, LocalDate hired, boolean missing, String check, boolean superAdmin)
            throws Exception {
        UUID id = UUID.randomUUID();
        ResultSet row = mock(ResultSet.class);
        when(row.getObject("id", UUID.class)).thenReturn(id);
        when(row.getString("code")).thenReturn(code);
        when(row.getString("full_name")).thenReturn("证件测试" + code);
        when(row.getString("dept_name")).thenReturn("生产部");
        when(row.getDate("hire_date")).thenReturn(Date.valueOf(hired));
        when(row.getDate("confirmed_at")).thenReturn(Date.valueOf(hired.plusMonths(3)));
        when(row.getBoolean("id_card_missing")).thenReturn(missing);
        when(row.getString("id_card_check")).thenReturn(check);
        when(row.getBoolean("super_admin_account")).thenReturn(superAdmin);
        rows.add(row);
        return id;
    }

    private static HrTaskClaim claim(String type, UUID employeeId, UUID owner) {
        HrTaskClaim claim = new HrTaskClaim();
        claim.setTaskType(type);
        claim.setEmployeeId(employeeId);
        claim.setClaimedBy(owner);
        claim.setClaimedAt(OffsetDateTime.now().minusMinutes(5));
        claim.setLeaseUntil(OffsetDateTime.now().plusHours(1));
        return claim;
    }
}
