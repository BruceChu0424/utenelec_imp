package com.uten.imp.features.org.department.dto;

import jakarta.validation.constraints.NotBlank;
import com.fasterxml.jackson.annotation.JsonSetter;
import lombok.Getter;
import lombok.Setter;

import java.util.UUID;

@Getter
@Setter
public class DepartmentUpdateRequest {
    @NotBlank
    private String name;

    private UUID parentId;   // 改上级会做防成环校验

    private UUID managerId;

    private Integer sortOrder;

    private boolean managerIdSpecified;

    @JsonSetter("managerId")
    public void setManagerId(UUID managerId) {
        this.managerId = managerId;
        this.managerIdSpecified = true;
    }
}
