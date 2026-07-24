package com.uten.imp.features.preference;

import jakarta.persistence.Column;
import jakarta.persistence.Embeddable;
import lombok.AllArgsConstructor;
import lombok.EqualsAndHashCode;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.io.Serializable;
import java.util.UUID;

/** user_preferences 复合主键（user_id + pref_key）。 */
@Embeddable
@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@EqualsAndHashCode
public class UserPreferenceId implements Serializable {

    @Column(name = "user_id")
    private UUID userId;

    @Column(name = "pref_key", length = 100)
    private String prefKey;
}
