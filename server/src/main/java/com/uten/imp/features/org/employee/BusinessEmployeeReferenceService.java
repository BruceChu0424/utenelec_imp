package com.uten.imp.features.org.employee;

import com.uten.imp.common.util.KeywordSearch;
import com.uten.imp.common.util.TaskKeywordSearch;
import com.uten.imp.common.util.DepartmentSearchSql;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.department.DepartmentService;
import com.uten.imp.application.port.DepartmentPickerNode;
import com.uten.imp.features.org.employee.dto.BusinessEmployeeReference;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.util.*;

@Service
@RequiredArgsConstructor
@Transactional(readOnly=true)
public class BusinessEmployeeReferenceService {
    private static final String SELECT="""
            SELECT e.id,e.code,e.full_name,e.department_id,d.name AS department_name,
              p.name AS position_name,e.status,COALESCE(account.status,'notProvisioned') AS account_status
            """;
    private static final String FROM="""
            FROM employees e JOIN departments d ON d.id=e.department_id
            LEFT JOIN positions p ON p.id=e.position_id
            LEFT JOIN users account ON account.employee_id=e.id AND NOT account.is_deleted
            """;
    private static final Set<String> STATUSES=Set.of("active","probation","onLeave","resigned");
    private static final EmployeeHeaderQuery.Columns HEADERS=new EmployeeHeaderQuery.Columns(
            Map.of("name","e.full_name","employeeCode","e.code","department","d.name","position","p.name"),
            "COALESCE(account.status,'notProvisioned')","e.status","e.id",STATUSES);
    private final BusinessEmployeeReferenceAccess access;
    private final JdbcTemplate jdbc;
    private final DepartmentRepository departments;
    private final DepartmentService departmentService;

    public PageResponse<BusinessEmployeeReference> candidates(String purpose,int page,int requestedSize,String search,
            Set<String> statuses,UUID departmentId,boolean includeSubtree,String accountStatus,String employmentStatus) {
        access.require(purpose);
        int safePage=Math.max(1,page),size=Math.min(Pageables.MAX_PAGE_SIZE,Math.max(1,requestedSize));
        boolean searched=!KeywordSearch.terms(search).isEmpty();
        String prefix=DepartmentSearchSql.prefix(searched);
        String from=FROM+DepartmentSearchSql.joins(searched,"e.department_id");
        List<Object> parameters=new ArrayList<>();
        StringBuilder where=new StringBuilder(" WHERE NOT e.is_deleted\n");
        for(String term:KeywordSearch.terms(search)) {
            where.append(" AND (LOWER(e.code) LIKE ? ESCAPE '\\' OR LOWER(e.full_name) LIKE ? ESCAPE '\\' OR LOWER(")
                    .append(DepartmentSearchSql.name("d.name")).append(") LIKE ? ESCAPE '\\' OR LOWER(p.name) LIKE ? ESCAPE '\\')\n");
            for(int field=0;field<4;field++) {parameters.add(KeywordSearch.containsPattern(term));}
        }
        if(statuses!=null&&!statuses.isEmpty()) {
            if(!STATUSES.containsAll(statuses)) throw invalid("人员任职状态无效");
            where.append(" AND e.status IN (").append(placeholders(statuses.size())).append(")\n");parameters.addAll(statuses);
        }
        if(departmentId!=null) {
            List<UUID> ids=includeSubtree?departments.findSubtree(departmentId).stream().map(Department::getId).toList():List.of(departmentId);
            if(ids.isEmpty()) {where.append(" AND false\n");}
            else {where.append(" AND e.department_id IN (").append(placeholders(ids.size())).append(")\n");parameters.addAll(ids);}
        }
        var filters=new LinkedHashMap<String,String>();
        if(accountStatus!=null) {filters.put("accountStatus",accountStatus);}
        if(employmentStatus!=null) {filters.put("employmentStatus",employmentStatus);}
        EmployeeHeaderQuery.read(filters,HEADERS).append(where,parameters);
        Long count=jdbc.queryForObject(prefix+"SELECT count(*) "+from+where,Long.class,parameters.toArray());
        long total=count==null?0:count;
        List<Object> paged=new ArrayList<>(parameters);
        String ranking=searched?TaskKeywordSearch.rankNamesFirstPositional(search,paged,new String[]{"e.full_name"},
                "e.code",DepartmentSearchSql.name("d.name"),"p.name")+", ":"";
        paged.add(size);paged.add(((long)safePage-1)*size);
        var items=jdbc.query(prefix+SELECT+from+where+" ORDER BY "+ranking+"e.code ASC NULLS LAST,e.id LIMIT ? OFFSET ?",BusinessEmployeeReferenceService::map,paged.toArray());
        return new PageResponse<>(items,safePage,size,total,total==0?0:(int)((total+size-1)/size));
    }

    /** Exact bounded echo, never an unrestricted search or a source of new selectable candidates. */
    public List<BusinessEmployeeReference> byIds(String purpose,List<UUID> rawIds) {
        access.requireEcho(purpose);
        if(rawIds==null||rawIds.isEmpty()||rawIds.size()>100||rawIds.stream().anyMatch(Objects::isNull)) throw invalid("人员回显须提供1至100个标识");
        List<UUID> ids=new ArrayList<>(new LinkedHashSet<>(rawIds));
        var found=jdbc.query(SELECT+FROM+" WHERE NOT e.is_deleted AND e.id IN ("+placeholders(ids.size())+")",BusinessEmployeeReferenceService::map,ids.toArray());
        Map<UUID,BusinessEmployeeReference> index=new HashMap<>();found.forEach(item->index.put(item.id(),item));
        return ids.stream().map(index::get).filter(Objects::nonNull).toList();
    }

    public List<DepartmentPickerNode> departments(String purpose) {access.require(purpose);return departmentService.employeePickerTree();}
    private static BusinessEmployeeReference map(java.sql.ResultSet r,int row) throws java.sql.SQLException {
        return new BusinessEmployeeReference(r.getObject("id",UUID.class),r.getString("code"),r.getString("full_name"),r.getObject("department_id",UUID.class),
                r.getString("department_name"),r.getString("position_name"),r.getString("status"),r.getString("account_status"));
    }
    private static String placeholders(int count) {return String.join(",",Collections.nCopies(count,"?"));}
    private static ApiException invalid(String message) {return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
