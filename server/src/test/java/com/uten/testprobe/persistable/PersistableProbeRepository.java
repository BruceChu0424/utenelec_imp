package com.uten.testprobe.persistable;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.UUID;

public interface PersistableProbeRepository extends JpaRepository<PersistableProbe, UUID> {
}
