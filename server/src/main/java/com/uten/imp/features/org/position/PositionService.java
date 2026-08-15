package com.uten.imp.features.org.position;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.department.DepartmentLevelPolicy;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.position.dto.PositionCreateRequest;
import com.uten.imp.features.org.position.dto.PositionItem;
import com.uten.imp.features.org.position.dto.PositionUpdateRequest;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/**
 * 部门岗位服务：CRUD；仅运营级部门可设岗位（公司/决策层等骨架节点拒绝）。
 * 服务层先检查同部门重复，V279 数据库预约再保证完整岗位编码全局、终身不复用；部门关联使用 UUID。
 */
@Service
@RequiredArgsConstructor
public class PositionService {

    private final PositionRepository positionRepo;
    private final DepartmentRepository deptRepo;
    private final TxSessionVars tx;

    @Transactional(readOnly = true)
    public List<PositionItem> list(UUID deptId) {
        requirePositionHostDepartment(deptId);
        return positionRepo.findByDepartmentIdAndDeletedFalseOrderBySortOrderAscIdAsc(deptId)
                .stream().map(this::toItem).toList();
    }

    @Transactional
    public PositionItem create(UUID deptId, PositionCreateRequest req) {
        tx.bind();
        Department dept = requirePositionHostDepartment(deptId);
        if (positionRepo.existsByCodeAndDepartmentId(req.code(), deptId)) {
            throw new ApiException(ErrorCode.CONFLICT, "该部门下岗位编码已存在");
        }
        Position p = new Position();
        p.setCode(req.code());
        p.setName(req.name());
        p.setLevel(req.level());
        p.setSortOrder(req.sortOrder() == null ? 0 : req.sortOrder());
        p.setDepartment(dept);
        positionRepo.save(p);
        return toItem(p);
    }

    @Transactional
    public PositionItem update(UUID id, PositionUpdateRequest req) {
        tx.bind();
        Position p = requirePosition(id);
        p.setName(req.name());
        if (req.level() != null) {
            p.setLevel(req.level());
        }
        if (req.sortOrder() != null) {
            p.setSortOrder(req.sortOrder());
        }
        positionRepo.save(p);
        return toItem(p);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        Position p = requirePosition(id);
        p.setDeleted(true);
        p.setDeletedAt(OffsetDateTime.now());
        positionRepo.save(p);
    }

    private Department requireDept(UUID id) {
        return deptRepo.findById(id)
                .filter(d -> !d.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "部门不存在"));
    }

    private Department requirePositionHostDepartment(UUID id) {
        Department department = requireDept(id);
        if (!DepartmentLevelPolicy.canHostEmployees(department.getLevel())) {
            throw new ApiException(ErrorCode.CONFLICT, "公司和决策层节点不能设置岗位");
        }
        return department;
    }

    private Position requirePosition(UUID id) {
        return positionRepo.findById(id)
                .filter(p -> !p.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "岗位不存在"));
    }

    private PositionItem toItem(Position p) {
        return new PositionItem(p.getId(), p.getCode(), p.getName(), p.getLevel(), p.getSortOrder());
    }
}
