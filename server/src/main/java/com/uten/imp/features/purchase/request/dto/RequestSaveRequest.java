package com.uten.imp.features.purchase.request.dto;

import com.fasterxml.jackson.annotation.JsonIgnore;
import com.fasterxml.jackson.annotation.JsonSetter;
import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import lombok.Getter;
import lombok.Setter;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

@Getter @Setter
public class RequestSaveRequest {
    private String billNo;
    @NotNull private LocalDate billDate;
    private UUID warehouseId;
    private UUID departmentId;
    @JsonIgnore
    private boolean departmentReferencePresent;

    @JsonSetter("departmentId")
    public void setDepartmentId(UUID value) {
        departmentId = value;
        departmentReferencePresent = true;
    }

    public boolean hasDepartmentReference() {
        return departmentReferencePresent;
    }
    private UUID applicantId;
    private LocalDate needDate;
    private String remark;
    @Valid
    @NotNull
    @Size(max = RequestLimits.DOCUMENT_LINES)
    private List<RequestItemLine> items;
}
