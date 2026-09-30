package com.uten.imp.common.columns;

import jakarta.validation.Valid;
import jakarta.validation.constraints.Size;
import lombok.Getter;
import lombok.Setter;
import java.util.List;

@Getter
@Setter
public abstract class ExtraColumnRequest {
    /** null preserves the old snapshot; an empty array explicitly removes its columns. */
    @Valid
    @Size(max = 32)
    private List<ExtraColumnInput> extraColumns;
}
