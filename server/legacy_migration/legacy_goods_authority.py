"""Shared database-first value selection for legacy goods migration.

Zero is a fact for prices, discounts and weights. Only reference identities
have the reviewed zero-as-unset sentinel; callers must opt into that rule.
"""


def is_missing_legacy_value(value, *, reference=False):
    if value is None or (isinstance(value, str) and not value.strip()):
        return True
    return reference and str(value).strip() == "0"


def prefer_legacy_value(legacy_value, supplemental_value, *, reference=False):
    return (supplemental_value if is_missing_legacy_value(legacy_value, reference=reference)
            else legacy_value)
