/// Data-scope, edit and analysis grants do not authorize commercial fields.
bool canViewCommercialPrice(Iterable<String> grants, String? pricePermission) =>
    pricePermission != null && grants.contains(pricePermission);
