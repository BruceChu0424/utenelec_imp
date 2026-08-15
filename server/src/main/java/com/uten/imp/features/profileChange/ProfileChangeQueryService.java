package com.uten.imp.features.profilechange;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.profilechange.dto.ProfileChangeDto;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** 员工侧查询/撤销 + HR 队列/详情（myList 与 hrList 共用批次折叠逻辑）。 */
@Service
@RequiredArgsConstructor
public class ProfileChangeQueryService {

    private final ProfileChangeRepository repo;
    private final ProfileChangeMapper mapper;
    private final ProfileChangeSnapshotCodec snapshotCodec;
    private final ProfileChangeAccess access;
    private final TxSessionVars tx;

    /** 当前登录人绑定的员工档案 id。submitted_by 的 FK 指向 employees(id)，不能用 users.id 查。 */
    private UUID requireEmployeeId() {
        UUID employeeId = access.requireStaff().getEmployeeId();
        if (employeeId == null) {
            throw new ApiException(ErrorCode.FORBIDDEN, "当前账号未绑定员工档案");
        }
        return employeeId;
    }

    /** 员工自查列表。 */
    @Transactional(readOnly = true)
    public ProfileChangeDto.Page<ProfileChangeDto.MyListItem> myList(int page, int size, String status) {
        UUID employeeId = requireEmployeeId();
        Pageable pageable = Pageables.of(page, size);
        Page<ProfileChangeRequest> p = (status == null || status.isBlank())
                ? repo.findBySubmittedByOrderBySubmittedAtDesc(employeeId, pageable)
                : repo.findBySubmittedByAndStatusOrderBySubmittedAtDesc(employeeId, status, pageable);
        List<ProfileChangeDto.MyListItem> items = new ArrayList<>();
        for (var e : foldByBatch(p.getContent()).entrySet()) {
            List<ProfileChangeRequest> rs = e.getValue();
            ProfileChangeRequest first = rs.get(0);
            String s = mapper.aggregateStatus(rs);
            items.add(new ProfileChangeDto.MyListItem(
                    e.getKey(), s, rs.size(),
                    first.getSubmittedAt(),
                    first.getReviewedAt(),
                    first.getReviewComment(),
                    rs.stream().map(ProfileChangeRequest::getFieldCode).toList(),
                    rs.stream().map(ProfileChangeRequest::getFieldLabel).toList()
            ));
        }
        return new ProfileChangeDto.Page<>(items, page, size, p.getTotalElements(), p.getTotalPages());
    }

    /** 员工自查单批详情。 */
    @Transactional(readOnly = true)
    public ProfileChangeDto.BatchDetail myBatchDetail(UUID batchId) {
        UUID employeeId = requireEmployeeId();
        List<ProfileChangeRequest> rs = repo.findByBatchId(batchId);
        if (rs.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "申请不存在");
        boolean mine = rs.stream().allMatch(r -> r.getSubmittedBy().equals(employeeId));
        if (!mine) throw new ApiException(ErrorCode.FORBIDDEN);
        return mapper.toBatchDetail(rs);
    }

    /** 员工撤销未审批次。 */
    @Transactional
    public void cancelBatch(UUID batchId) {
        snapshotCodec.bindWriteCapability();
        UUID employeeId = requireEmployeeId();
        List<ProfileChangeRequest> rs = repo.findByBatchIdAndStatus(batchId, "pending");
        if (rs.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "无 pending 批次可撤销");
        boolean mine = rs.stream().allMatch(r -> r.getSubmittedBy().equals(employeeId));
        if (!mine) throw new ApiException(ErrorCode.FORBIDDEN);
        OffsetDateTime now = OffsetDateTime.now();
        for (ProfileChangeRequest r : rs) {
            r.setStatus("cancelled");
            r.setReviewedAt(now);
            r.setReviewComment("EMPLOYEE_CANCELLED");
        }
        tx.bind();
        repo.saveAll(rs);
    }

    /** HR 队列。 */
    @Transactional(readOnly = true)
    public ProfileChangeDto.Page<ProfileChangeDto.HrListItem> hrList(int page, int size, String status, UUID employeeId) {
        access.requireHr();
        Pageable pageable = Pageables.of(page, size);
        Page<ProfileChangeRequest> p;
        if (employeeId != null) {
            p = (status == null || status.isBlank())
                    ? repo.findByEmployeeIdOrderBySubmittedAtDesc(employeeId, pageable)
                    : repo.findByEmployeeIdAndStatusOrderBySubmittedAtDesc(employeeId, status, pageable);
        } else if (status == null || status.isBlank()) {
            // 默认待审队列
            p = repo.findByStatusOrderBySubmittedAtDesc("pending", pageable);
        } else {
            // 指定状态筛选（applied/rejected/cancelled）——之前误用 findAll 导致筛选失效（混合全部状态）
            p = repo.findByStatusOrderBySubmittedAtDesc(status, pageable);
        }
        Map<UUID, List<ProfileChangeRequest>> byBatch = foldByBatch(p.getContent());
        // 员工姓名/部门批量回填（避免逐批 findById 的 N+1）
        Map<UUID, Employee> emps = mapper.employeesById(
                byBatch.values().stream().map(rs -> rs.get(0).getEmployeeId()).toList());
        List<ProfileChangeDto.HrListItem> items = new ArrayList<>();
        for (var e : byBatch.entrySet()) {
            List<ProfileChangeRequest> rs = e.getValue();
            ProfileChangeRequest first = rs.get(0);
            Employee emp = emps.get(first.getEmployeeId());
            items.add(new ProfileChangeDto.HrListItem(
                    e.getKey(),
                    first.getEmployeeId(),
                    emp == null ? null : emp.getFullName(),
                    emp == null ? null : emp.getCode(),
                    emp == null || emp.getDepartment() == null ? null : emp.getDepartment().getName(),
                    mapper.aggregateStatus(rs),
                    rs.size(),
                    rs.stream().map(ProfileChangeRequest::getFieldCode).toList(),
                    first.getSubmittedAt(),
                    first.getReviewedAt(),
                    null
            ));
        }
        return new ProfileChangeDto.Page<>(items, page, size, p.getTotalElements(), p.getTotalPages());
    }

    /** HR 单批详情（含完整 diff）。 */
    @Transactional(readOnly = true)
    public ProfileChangeDto.BatchDetail hrBatchDetail(UUID batchId) {
        access.requireHr();
        List<ProfileChangeRequest> rs = repo.findByBatchId(batchId);
        if (rs.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "申请不存在");
        return mapper.toBatchDetail(rs);
    }

    /** 按 batchId 折叠（保持提交顺序）。 */
    private Map<UUID, List<ProfileChangeRequest>> foldByBatch(List<ProfileChangeRequest> rows) {
        Map<UUID, List<ProfileChangeRequest>> byBatch = new LinkedHashMap<>();
        for (ProfileChangeRequest r : rows) {
            byBatch.computeIfAbsent(r.getBatchId(), k -> new ArrayList<>()).add(r);
        }
        return byBatch;
    }
}
