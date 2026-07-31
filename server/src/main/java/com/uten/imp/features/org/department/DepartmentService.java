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

    private final DepartmentRepository deptRepo;
    private final EmployeeRepository empRepo;
    private final EntityManager em;
    private final TxSessionVars tx;

    @Transactional(readOnly = true)
    public List<DepartmentNode> tree() {
        return buildTree(deptRepo.findByDeletedFalseOrderById(), null);
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
            d.setManager(requireCurrentEmployee(req.getManagerId()));
        }
        deptRepo.save(d);
        em.flush();
        em.refresh(d);   // 触发器计算 path 后刷新
        return detail(d.getId());
    }

    @Transactional
    public DepartmentDetail update(UUID id, DepartmentUpdateRequest req) {
        tx.bind();
        Department d = requireDept(id);
        d.setName(req.getName());
        if (req.getSortOrder() != null) {
            d.setSortOrder(req.getSortOrder());
        }
        if (req.isManagerIdSpecified()) {
            if (req.getManagerId() == null) {
                d.setManager(null);
            } else {
                Employee manager = requireCurrentEmployee(req.getManagerId());
                if (manager.getDepartment() == null
                        || !id.equals(manager.getDepartment().getId())) {
                    throw new ApiException(
                            ErrorCode.CONFLICT,
                            "部门负责人必须是该部门的直属在岗员工");
                }
                d.setManager(manager);
            }
        }
        boolean parentChanged = false;
        if (req.getParentId() != null) {
            if (req.getParentId().equals(id)) {
                throw new ApiException(ErrorCode.CONFLICT, "上级不能是自己");
            }
            if (deptRepo.isDescendant(id, req.getParentId())) {
                throw new ApiException(ErrorCode.CONFLICT, "不能将部门挂到其子部门下（会成环）");
            }
            d.setParent(requireDept(req.getParentId()));
            parentChanged = true;
        }
        deptRepo.save(d);
        em.flush();
        em.refresh(d);
        if (parentChanged) {
            relevelSubtree(id);   // level 是有语义的层级标签，移动后按新父级重算整棵子树
        }
        return detail(id);
    }

    /** 父部门层级 → 子部门层级（公司/骨架→一级；一级→二级；二级→三级；三级封顶）。 */
    private String childDeptLevel(String parentLevel) {
        if (parentLevel == null) return "一级部门";
        return switch (parentLevel) {
            case "公司", "决策层", "管理中心" -> "一级部门";
            case "一级部门" -> "二级班组";
            case "二级班组" -> "三级科室";
            case "三级科室" -> "三级科室";
            default -> "二级班组";
        };
    }

    /** 移动后重算子树 level：findSubtree 按 path 排序（根先于后代），根的 level 由其新父级决定。 */
    private void relevelSubtree(UUID rootId) {
        List<Department> nodes = deptRepo.findSubtree(rootId);
        Department root = nodes.stream().filter(d -> d.getId().equals(rootId)).findFirst().orElse(null);
        if (root == null) return;
        String rootParentLevel = root.getParent() == null ? null : root.getParent().getLevel();
        Map<UUID, String> levelById = new HashMap<>();
        for (Department d : nodes) {
            String lvl = d.getId().equals(rootId)
                    ? childDeptLevel(rootParentLevel)
                    : childDeptLevel(levelById.get(d.getParent().getId()));
            d.setLevel(lvl);
            levelById.put(d.getId(), lvl);
        }
        deptRepo.saveAll(nodes);
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
