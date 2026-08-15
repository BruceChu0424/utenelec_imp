package com.uten.imp.features.master;

import com.uten.imp.common.domain.BaseEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.util.UUID;

/** Immutable UUID relations for the protected uncategorized category roots. */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "system_master_category_registry")
public class SystemMasterCategoryRegistryEntry extends BaseEntity {

    @Column(name = "material_category_id", nullable = false, updatable = false)
    private UUID materialCategoryId;

    @Column(name = "client_category_id", nullable = false, updatable = false)
    private UUID clientCategoryId;

    @Column(name = "mould_category_id", nullable = false, updatable = false)
    private UUID mouldCategoryId;

    @Column(name = "supplier_category_id", nullable = false, updatable = false)
    private UUID supplierCategoryId;
}
