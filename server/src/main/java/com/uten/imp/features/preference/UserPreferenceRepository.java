package com.uten.imp.features.preference;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.UUID;

public interface UserPreferenceRepository extends JpaRepository<UserPreference, UserPreferenceId> {

    /** 某用户的全部偏好。 */
    List<UserPreference> findByIdUserId(UUID userId);
}
