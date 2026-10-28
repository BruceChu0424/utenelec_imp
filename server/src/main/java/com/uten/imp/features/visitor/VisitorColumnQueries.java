package com.uten.imp.features.visitor;

import com.uten.imp.common.util.JpaColumnSearch;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.features.org.employee.Employee;
import java.util.LinkedHashMap;
import java.util.Map;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;

/** The visible application columns share one read contract across visitor, host and HR views. */
final class VisitorColumnQueries {
    private VisitorColumnQueries() { }
    static final Map<String, JpaColumnSearch.Field> APPLICATION = Map.of(
            "visitorName", JpaColumnSearch.Field.text("visitorName"),
            "company", JpaColumnSearch.Field.text("company"),
            "visitPurpose", JpaColumnSearch.Field.text("visitPurpose"),
            "hostName", JpaColumnSearch.Field.referenceText("hostEmployeeId", Employee.class, "fullName"),
            "hostDepartment", JpaColumnSearch.Field.text((root, query, cb) -> {
                var employee = query.subquery(String.class);
                var target = employee.from(Employee.class);
                employee.select(target.get("department").get("name"))
                        .where(cb.equal(target.get("id"), root.get("hostEmployeeId")));
                return employee;
            }),
            "plannedVisitAt", JpaColumnSearch.Field.instant("plannedVisitAt"));

    static Map<String, JpaColumnSearch.Field> mine() {
        var result = new LinkedHashMap<>(APPLICATION);
        result.put("hostName", JpaColumnSearch.Field.referenceText(
                "hostEmployeeId", Employee.class, "fullName", "company"));
        return Map.copyOf(result);
    }

    static Pageable page(int page, int size, String sort, String order) {
        return Pageables.of(page, size, TableSort.resolve(sort, order,
                Sort.by(Sort.Order.desc("createdAt"), Sort.Order.desc("id")),
                Map.of("plannedVisitAt", "plannedVisitAt")));
    }
}
