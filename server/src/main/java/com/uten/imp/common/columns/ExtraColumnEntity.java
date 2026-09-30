package com.uten.imp.common.columns;

import com.uten.imp.common.domain.BaseEntity;
import jakarta.persistence.Column;
import jakarta.persistence.MappedSuperclass;
import lombok.Getter;
import lombok.Setter;
import org.hibernate.annotations.JdbcTypeCode;
import org.hibernate.type.SqlTypes;
import java.util.List;

@Getter
@Setter
@MappedSuperclass
public abstract class ExtraColumnEntity extends BaseEntity {
    @JdbcTypeCode(SqlTypes.JSON)
    @Column(name = "extra_columns", nullable = false, columnDefinition = "jsonb")
    private List<ExtraColumnSnapshot> extraColumns = List.of();
}
