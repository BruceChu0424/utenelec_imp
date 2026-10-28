package com.uten.imp.features.org.employee;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.org.employee.dto.ArchiveEmployeeDuplicateRequest;
import com.uten.imp.responsibility.DataHandoverService;
import com.uten.imp.responsibility.dto.DataHandoverAction;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.util.List;
import java.util.UUID;

/** Reviewed duplicate archival. Never guesses identity from a person's name. */
@Service
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('employee:view') and hasAuthority('employee:edit') and hasAuthority('employee:pii:edit') and hasAuthority('employee:offboard')")
public class EmployeeDuplicateArchiveService {
    private final EmployeeRepository employees;
    private final EmployeeSensitiveRepository sensitive;
    private final EmployeeIdentityDirectory identities;
    private final DataHandoverService responsibilities;
    private final JdbcTemplate jdbc;
    private final TxSessionVars tx;

    public record Preview(UUID sourceId,String sourceCode,String sourceName,int sourceVersion,
                          UUID retainedId,String retainedCode,String retainedName,int retainedVersion,
                          boolean documentConflict,List<String> blockers) { }

    @Transactional(readOnly=true)
    public Preview preview(UUID sourceId,String retainedCode) {
        Employee retained=employees.findByCode(retainedCode.strip()).filter(row->!row.isDeleted())
                .orElseThrow(()->new ApiException(ErrorCode.NOT_FOUND,"保留工号不存在，请核对"));
        Employee source=require(sourceId);
        return inspect(source,retained,false);
    }

    @Transactional
    public UUID archive(UUID sourceId,ArchiveEmployeeDuplicateRequest request) {
        tx.bind();
        if(!request.identityVerified()) throw new ApiException(ErrorCode.VALIDATION_FAILED,"请先核实两份档案属于同一人");
        jdbc.queryForObject("SELECT 1 FROM pg_advisory_xact_lock(1431586126,937)",Integer.class);
        employees.findAllByIdForUpdate(List.of(sourceId,request.retainedEmployeeId()));
        Employee source=require(sourceId),retained=require(request.retainedEmployeeId());
        if(!source.getVersion().equals(request.sourceVersion()) || !retained.getVersion().equals(request.retainedVersion()))
            throw new ApiException(ErrorCode.CONFLICT,"档案已变化，请重新核对后归档");
        Preview checked=inspect(source,retained,true);
        if(!checked.blockers().isEmpty()) throw new ApiException(ErrorCode.CONFLICT,String.join("；",checked.blockers()));
        if(checked.documentConflict() && !request.documentConflictVerified())
            throw new ApiException(ErrorCode.CONFLICT,"两份档案证件号码不同，请对照证件原件核验差异并单独确认，不能仅按同名归档");
        return jdbc.queryForObject("SELECT fn_archive_verified_employee_duplicate(?,?,?,?,?,?,?)",UUID.class,
                sourceId,retained.getId(),source.getVersion(),retained.getVersion(),request.reason(),
                "employee-duplicate-review:"+UUID.randomUUID(),request.documentConflictVerified());
    }

    private Employee require(UUID id) {
        return employees.findById(id).filter(row->!row.isDeleted())
                .orElseThrow(()->new ApiException(ErrorCode.NOT_FOUND,"员工档案不存在或已归档"));
    }

    private Preview inspect(Employee source,Employee retained,boolean locking) {
        if(source.getId().equals(retained.getId())) throw new ApiException(ErrorCode.VALIDATION_FAILED,"保留工号不能是当前档案");
        if(!identities.canonicalEmployeeId(retained.getId()).equals(retained.getId())
                || identities.employeeIdentityMembers(source.getId()).size()>1)
            throw new ApiException(ErrorCode.CONFLICT,"此档案已有核验关联，请从保留的主档案查看历史资料");
        var blockers=new java.util.ArrayList<String>();
        if("resigned".equals(retained.getStatus()) && !"resigned".equals(source.getStatus()))
            blockers.add("保留档案已离职，请保留当前在职档案，不能把在职身份归入离职主档");
        if(Boolean.TRUE.equals(jdbc.queryForObject("SELECT EXISTS(SELECT 1 FROM users WHERE employee_id=? AND NOT is_deleted)",Boolean.class,source.getId())))
            blockers.add("当前档案仍有登录账号，请保留有账号的档案，将无账号的重复档案归档；不要删除或转绑账号");
        var sourcePii=sensitive.findByEmployeeId(source.getId()).orElse(null);
        var retainedPii=sensitive.findByEmployeeId(retained.getId()).orElse(null);
        boolean documentConflict=sourcePii!=null && retainedPii!=null && sourcePii.getIdCardHash()!=null
                && retainedPii.getIdCardHash()!=null && !sourcePii.getIdCardHash().equals(retainedPii.getIdCardHash());
        var impact=locking ? responsibilities.inspectDuplicateArchive(source.getId(),retained.getId())
                : responsibilities.previewDuplicateArchive(source.getId(),retained.getId());
        impact.items().stream().filter(item->item.count()>0 && item.action()!=DataHandoverAction.HISTORY_ACCESS)
                .forEach(item->blockers.add(item.label()+"（"+item.count()+"项），请先通过人员交接处理"));
        return new Preview(source.getId(),source.getCode(),source.getFullName(),source.getVersion(),
                retained.getId(),retained.getCode(),retained.getFullName(),retained.getVersion(),documentConflict,List.copyOf(blockers));
    }
}
