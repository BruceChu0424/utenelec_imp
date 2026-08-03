package com.uten.imp.features.org.department;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.org.department.dto.*;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.*;

@Service
@RequiredArgsConstructor
public class DepartmentService {

    private static final Set<String> CURRENT_EMPLOYEE_STATUSES =
            Set.of("active", "probation", "onLeave");

    private static final String ACQUIRE_HIERARCHY_LOCK_SQL =
            "SELECT pg_advisory_xact_lock(hashtextextended('DEPARTMENT_HIERARCHY',0))";

    private final DepartmentRepository deptRepo;
    private final EmployeeRepository empRepo;
    private final EntityManager em;
    private final TxSessionVars tx;

    @Transactional(readOnly = true)
    public List<DepartmentNode> tree() {
        return buildTree(deptRepo.findByDeletedFalseOrderBySortOrderAscNameAsc(), null);
    }

    @Transactional(readOnly = true)
    public List<DepartmentNode> subtree(UUID rootId) {
        requireDept(rootId);
        return buildTree(deptRepo.findSubtree(rootId), rootId);
    }

    @Transactional(readOnly = true)
    public DepartmentDetail detail(UUID id) {
        Department d = requireDept(id);
        UUID parentId = d.getParent() == null ? null : d.getParent().getId();
        String parentName = d.getParent() == null ? null : d.getParent().getName();
        UUID managerId = d.getManager() == null ? null : d.getManager().getId();
        String managerName = d.getManager() == null ? null : d.getManager().getFullName();
        long childCount = deptRepo.findByParentIdOrderBySortOrderAscNameAsc(id).size();
        long empCount = empRepo.countByDepartmentIdAndDeletedFalseAndStatusIn(
                id, CURRENT_EMPLOYEE_STATUSES);
        return new DepartmentDetail(d.getId(), d.getCode(), d.getName(), d.getLevel(),
                parentId, parentName, managerId, managerName, d.getSortOrder(), d.getHeadcount(),
                d.getPath(), childCount, empCount);
    }

    @Transactional
    public DepartmentDetail create(DepartmentSaveRequest req) {
        tx.bind();
        if (deptRepo.existsByCode(req.getCode())) {
            throw new ApiException(ErrorCode.CONFLICT, "部门编码已存在");
        }
        Department d = new Department();
        d.setCode(req.getCode());
        d.setName(req.getName());
        d.setLevel(req.getLevel());
        d.setSortOrder(req.getSortOrder() == null ? 0 : req.getSortOrder());
        if (req.getParentId() != null) {
            d.setParent(requireDept(req.getParentId()));
        }
        if (req.getManagerId() != null) {
            rejectNonOperatingNodeManager(req.getLevel());
            Employee manager = requireCurrentEmployee(req.getManagerId());
            requireDirectManager(d.getId(), manager);
            d.setManager(manager);
        }
        d = deptRepo.save(d); // UUID 构造时赋值→isNew=false→save 走 merge 返回托管副本；用返回值，否则 em.refresh(游离 d) 报 "Entity not managed"
        em.flush();
        em.refresh(d);   // 触发器计算 path 后刷新
        return detail(d.getId());
    }

    @Transactional
    public DepartmentDetail update(UUID id, DepartmentUpdateRequest req) {
        tx.bind();
        if (req.getParentId() != null) {
            lockDepartmentHierarchy();
        }
        Department d = requireDept(id);
        d.setName(req.getName());
        if (req.getSortOrder() != null) {
            d.setSortOrder(req.getSortOrder());
        }
        if (req.isManagerIdSpecified()) {
            if (req.getManagerId() == null) {
                d.setManager(null);
            } else {
                rejectNonOperatingNodeManager(d.getLevel());
                Employee manager = requireCurrentEmployee(req.getManagerId());
                requireDirectManager(id, manager);
                d.setManager(manager);
            }
        }
        UUID currentParentId = d.getParent() == null ? null : d.getParent().getId();
        UUID requestedParentId = req.getParentId();
        boolean parentChanged = requestedParentId != null
                && !requestedParentId.equals(currentParentId);
        if (parentChanged) {
            if (DepartmentLevelPolicy.hasImmutableParent(d.getLevel())) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "公司、决策层和管理中心等组织骨架节点不可修改上级");
            }
            if (requestedParentId.equals(id)) {
                throw new ApiException(ErrorCode.CONFLICT, "上级不能是自己");
            }
            if (deptRepo.isDescendant(id, requestedParentId)) {
                throw new ApiException(ErrorCode.CONFLICT, "不能将部门挂到其子部门下（会成环）");
            }
            d.setParent(requireDept(requestedParentId));
        }
        deptRepo.save(d);
        em.flush();
        em.refresh(d);
        if (parentChanged) {
            relevelSubtree(id);   // level 是有语义的层级标签，移动后按新父级重算整棵子树
        }
        return detail(id);
    }

    /** 移动后按 parent 关系递归重算整棵子树 level/path，不依赖移动前的旧 path 排序。 */
    private void relevelSubtree(UUID rootId) {
        if (deptRepo.rebuildSubtreeHierarchy(rootId) == 0) {
            throw new ApiException(ErrorCode.CONFLICT, "部门子树结构异常，无法安全移动");
        }
    }

    private void lockDepartmentHierarchy() {
        em.createNativeQuery(ACQUIRE_HIERARCHY_LOCK_SQL).getSingleResult();
    }

    private void rejectNonOperatingNodeManager(String level) {
        if (!DepartmentLevelPolicy.canHostEmployees(level)) {
            throw new ApiException(ErrorCode.CONFLICT, "公司和决策层节点不能设置部门负责人");
        }
    }

    private void requireDirectManager(UUID departmentId, Employee manager) {
        if (manager.getDepartment() == null
                || !departmentId.equals(manager.getDepartment().getId())) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "部门负责人必须是该部门的直属在岗员工");
        }
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        Department d = requireDept(id);
        if (!deptRepo.findByParentIdOrderBySortOrderAscNameAsc(id).isEmpty()) {
            throw new ApiException(ErrorCode.CONFLICT, "请先删除该部门的子部门");
        }
        if (empRepo.countByDepartmentIdAndDeletedFalse(id) > 0) {
            throw new ApiException(ErrorCode.CONFLICT, "请先转移该部门的员工");
        }
        d.setDeleted(true);
        d.setDeletedAt(OffsetDateTime.now());
        deptRepo.save(d);
    }

    private Department requireDept(UUID id) {
        return deptRepo.findById(id)
                .filter(d -> !d.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "部门不存在"));
    }

    private Employee requireCurrentEmployee(UUID id) {
        Employee employee = empRepo.findById(id)
                .filter(row -> !row.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "负责人员工不存在"));
        if (!CURRENT_EMPLOYEE_STATUSES.contains(employee.getStatus())) {
            throw new ApiException(ErrorCode.CONFLICT, "离职员工不能设置为部门负责人");
        }
        return employee;
    }

    /** 把扁平部门列表组装为树；rootId 非 null 时仅返回以该节点为根的子树。 */
    private List<DepartmentNode> buildTree(List<Department> all, UUID rootId) {
        Map<UUID, DepartmentNode> map = new LinkedHashMap<>();
        for (Department d : all) {
            map.put(d.getId(), toNode(d));
        }
        List<DepartmentNode> roots = new ArrayList<>();
        for (Department d : all) {
            DepartmentNode node = map.get(d.getId());
            Department parent = d.getParent();
            if (parent == null || !map.containsKey(parent.getId())) {
                if (rootId == null || d.getId().equals(rootId)) {
                    roots.add(node);
                }
            } else {
                map.get(parent.getId()).getChildren().add(node);
            }
        }
        return roots;
    }

    private DepartmentNode toNode(Department d) {
        DepartmentNode n = new DepartmentNode();
        n.setId(d.getId());
        n.setCode(d.getCode());
        n.setName(d.getName());
        n.setLevel(d.getLevel());
        n.setParentId(d.getParent() == null ? null : d.getParent().getId());
        n.setManagerId(d.getManager() == null ? null : d.getManager().getId());
        n.setManagerName(d.getManager() == null ? null : d.getManager().getFullName());
        n.setSortOrder(d.getSortOrder());
        n.setHeadcount(d.getHeadcount());
        return n;
    }
}
