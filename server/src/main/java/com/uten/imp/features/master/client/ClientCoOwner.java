package com.uten.imp.features.master.client;

import jakarta.persistence.Entity;
import jakarta.persistence.Column;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import java.util.UUID;

/** Additional customer responsibility; the first owner remains on clients for compatibility. */
@Entity
@Table(name = "client_co_owners")
@Getter
@NoArgsConstructor
public class ClientCoOwner {
    @Id private UUID id;
    @Column(name="client_id",nullable=false) private UUID clientId;
    @Column(name="employee_id",nullable=false) private UUID employeeId;
    @Column(name="sort_order",nullable=false) private int sortOrder;
}
