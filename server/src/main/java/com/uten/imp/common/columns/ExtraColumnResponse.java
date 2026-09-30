package com.uten.imp.common.columns;

import lombok.Getter;
import lombok.Setter;
import java.util.List;

@Getter
@Setter
public abstract class ExtraColumnResponse {
    private List<ExtraColumnSnapshot> extraColumns = List.of();
}
