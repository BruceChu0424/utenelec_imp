package com.uten.imp.features.master.mould.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 模具主档新建/编辑请求（mould:edit）。
 *
 * <p>字段集 = 可编辑的核心业务字段（全量覆盖式更新）；legacy_id/审计/软删不可改。
 * code 留空时按所属分类的有效前缀生成，手工改码也由 V279 全局终身预约；定位和关系只用 UUID id。
 * 新建与编辑共用本 DTO——主档没有「创建后不可改」字段，也无父子防环约束，故不拆 Save/Update。
 */
@Getter
@Setter
public class MouldSaveRequest {

    @NotNull
    private UUID categoryId;     // 所属模具分类 UUID（必填；编号不能代替）

    @NotBlank
    private String name;         // MouldName（模具名称）
    private String code;         // 显示编号；留空按分类前缀生成，手填也全局唯一且终身占用
    private String mnumber;      // Mnumber（备用编号）
    private String qty;          // QTY（varchar，如 "1+1"）
    private BigDecimal tqty;     // TQTY（总数量）
    private String mstatus;      // MStatus（制造年月，如 2018年7月）
    private String status;       // [Status]（生命周期：使用/禁用）
    private String place;        // Place（车间/位置；picker 落 departmentId 时后端按 id 补名）
    private String keeper;       // summary（保管人；picker 落 keeperId 时后端按 id 补名）
    private UUID departmentId;   // 车间部门 id（departments.id，picker 落）
    private UUID keeperId;       // 保管人员工 id（employees.id，picker 落）
    private String remark;       // Remark（备注）
}
