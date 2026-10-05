package com.uten.imp.features.org.employee;

import com.uten.imp.features.org.employee.dto.IdNumberIssue;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class EmployeeIdentityCheckTest {

    private static final String VALID_ID = "11010519491231002X";
    private static final String BAD_CHECK_DIGIT = "110105194912310021";

    @Test
    void classifyStoresValidOrTheSpecificProblemCode() {
        assertThat(EmployeeIdentityCheck.classify("身份证", VALID_ID)).isEqualTo("valid");
        assertThat(EmployeeIdentityCheck.classify("身份证", " 11010519491231002x "))
                .as("lowercase x is normalized before checking").isEqualTo("valid");
        assertThat(EmployeeIdentityCheck.classify("身份证", BAD_CHECK_DIGIT)).isEqualTo("check_digit");
        assertThat(EmployeeIdentityCheck.classify("身份证", "11010519491231002")).isEqualTo("length:17");
        assertThat(EmployeeIdentityCheck.classify("身份证", "110105A9491231002X")).isEqualTo("character:7");
        assertThat(EmployeeIdentityCheck.classify("身份证", null)).isEqualTo("empty");
        assertThat(EmployeeIdentityCheck.classify("身份证", "1".repeat(1200)))
                .as("stored length code stays within the CHECK pattern").isEqualTo("length:999");
    }

    @Test
    void nonResidentDocumentsAreValidWhenPresent() {
        assertThat(EmployeeIdentityCheck.classify("护照", "P1234567")).isEqualTo("valid");
        assertThat(EmployeeIdentityCheck.classify("港澳台通行证", "H12")).isEqualTo("valid");
        assertThat(EmployeeIdentityCheck.classify("其他", BAD_CHECK_DIGIT)).isEqualTo("valid");
        assertThat(EmployeeIdentityCheck.classify("护照", "  ")).isEqualTo("empty");
    }

    @Test
    void issueCoversEveryStoredStateAndSkipsSuperAdmins() {
        assertThat(EmployeeIdentityCheck.issueOf(true, "valid", false)).isNull();
        assertThat(EmployeeIdentityCheck.issueOf(false, null, false))
                .isEqualTo(new IdNumberIssue("missing", "档案里没有证件号码"));
        assertThat(EmployeeIdentityCheck.issueOf(true, "unchecked", false))
                .isEqualTo(new IdNumberIssue("unchecked", "证件号码来自历史资料导入，系统还没有完成校验"));
        assertThat(EmployeeIdentityCheck.issueOf(true, null, false).kind())
                .as("a cipher without a stored result is treated as not yet checked").isEqualTo("unchecked");
        assertThat(EmployeeIdentityCheck.issueOf(true, "length:17", false))
                .isEqualTo(new IdNumberIssue("invalid", "身份证号应为18位，当前为17位"));
        assertThat(EmployeeIdentityCheck.issueOf(true, "check_digit", false).reason())
                .startsWith("身份证号第18位校验码与前17位不符");
        assertThat(EmployeeIdentityCheck.issueOf(true, "character:18", false).reason())
                .isEqualTo("身份证号第18位只能是数字或X");
        assertThat(EmployeeIdentityCheck.issueOf(true, "not-a-code", false))
                .isEqualTo(new IdNumberIssue("invalid", "证件号码没有通过校验，请对照证件核对"));
        for (String stored : new String[] {null, "valid", "unchecked", "unreadable", "check_digit"}) {
            assertThat(EmployeeIdentityCheck.issueOf(true, stored, true)).isNull();
            assertThat(EmployeeIdentityCheck.issueOf(false, stored, true)).isNull();
        }
    }

    /**
     * 有密文却解不开 (回填任务存的 unreadable，或详情读取时解不开传进来的同一个值)：按「尚未校验」提醒
     * (前端认识的三种之一)，原因说清楚是读取不出来，和历史导入未校验的原因不同。
     */
    @Test
    void unreadableCipherIsReportedAsUncheckedWithItsOwnReasonExceptForSuperAdmins() {
        assertThat(EmployeeIdentityCheck.UNREADABLE).isEqualTo("unreadable");
        IdNumberIssue issue = EmployeeIdentityCheck.issueOf(true, EmployeeIdentityCheck.UNREADABLE, false);
        assertThat(issue).isEqualTo(new IdNumberIssue(
                "unchecked", "档案里的证件号码读取不出来，系统无法校验，请人事对照证件重新登记"));
        assertThat(issue.reason()).doesNotContainPattern("[0-9]").doesNotContain("\uFF08", "\uFF09");
        assertThat(issue.reason())
                .isNotEqualTo(EmployeeIdentityCheck.issueOf(true, "unchecked", false).reason());
        assertThat(EmployeeIdentityCheck.issueOf(true, EmployeeIdentityCheck.UNREADABLE, true)).isNull();
        assertThat(EmployeeIdentityCheck.issueOf(false, EmployeeIdentityCheck.UNREADABLE, false).kind())
                .as("no cipher at all is still reported as missing").isEqualTo("missing");
    }

    /** unchecked 与 unreadable 只由迁移和启动回填任务写；写入口按号码判定，永远不会产生这两个值。 */
    @Test
    void classifyNeverProducesTheRunnerOnlyStates() {
        for (String number : new String[] {null, "", "11010519491231002X", "110105194912310021", "x"}) {
            assertThat(EmployeeIdentityCheck.classify("身份证", number))
                    .isNotIn(EmployeeIdentityCheck.UNCHECKED, EmployeeIdentityCheck.UNREADABLE);
            assertThat(EmployeeIdentityCheck.classify("护照", number))
                    .isNotIn(EmployeeIdentityCheck.UNCHECKED, EmployeeIdentityCheck.UNREADABLE);
        }
    }

    @Test
    void reasonsCarryPositionsOnlyNeverIdentityDigits() {
        for (String stored : new String[] {
                "empty", "length:17", "character:7", "character:18", "birth_date",
                "birth_too_early", "birth_future", "region_code", "sequence_code",
                "check_digit", "unchecked", "unreadable"}) {
            IdNumberIssue issue = EmployeeIdentityCheck.issueOf(true, stored, false);
            assertThat(issue).as(stored).isNotNull();
            assertThat(issue.reason())
                    .doesNotContain("002X", "0021", "110105", "1949")
                    .doesNotContain("\uFF08", "\uFF09");
        }
        assertThat(EmployeeIdentityCheck.issueOf(false, null, false).reason()).doesNotContainPattern("[0-9]");
    }
}
