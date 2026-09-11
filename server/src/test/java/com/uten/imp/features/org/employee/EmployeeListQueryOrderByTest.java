package com.uten.imp.features.org.employee;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * 员工列表排序白名单契约：sort 只认 code / hireDate / workYears，
 * 其余输入一律回落默认「负责人优先 + 工号」；workYears 映射 hire_date 且方向翻转
 * （工龄从小到大 ⇔ 入职日期从新到远）。
 */
class EmployeeListQueryOrderByTest {

    // orderBy 为纯字符串拼装，不触 JDBC，注入 null 即可。
    private final EmployeeListQuery query = new EmployeeListQuery(null);

    @Test
    void unknownOrMissingSortFallsBackToLeaderFirstDefault() {
        String fallback = query.orderBy(null, null);
        assertTrue(fallback.contains("CASE"), "默认序应为负责人优先 CASE + 工号");
        assertEquals(fallback, query.orderBy("", "asc"));
        assertEquals(fallback, query.orderBy("fullName; DROP TABLE employees", "desc"));
        assertEquals(fallback, query.orderBy("hire_date", "asc"), "列名直传不在白名单");
    }

    @Test
    void codeSortsAscDesc() {
        assertEquals("ORDER BY e.code ASC, e.code", query.orderBy("code", null));
        assertEquals("ORDER BY e.code ASC, e.code", query.orderBy("code", "asc"));
        assertEquals("ORDER BY e.code DESC, e.code", query.orderBy("code", "DESC"));
    }

    @Test
    void hireDateSortsAscDescWithNullsLast() {
        assertEquals(
                "ORDER BY e.hire_date ASC NULLS LAST, e.code",
                query.orderBy("hireDate", "asc"));
        assertEquals(
                "ORDER BY e.hire_date DESC NULLS LAST, e.code",
                query.orderBy("hireDate", "desc"));
    }

    @Test
    void workYearsFlipsHireDateDirection() {
        // 工龄从小到大 = 入职日期从新到远（desc）；工龄从大到小 = asc。
        assertEquals(
                "ORDER BY e.hire_date DESC NULLS LAST, e.code",
                query.orderBy("workYears", "asc"));
        assertEquals(
                "ORDER BY e.hire_date ASC NULLS LAST, e.code",
                query.orderBy("workYears", "desc"));
    }
}
