/// Returns whether [location] belongs to the external visitor portal.
///
/// Match a complete path segment instead of a raw `/visitor` prefix so
/// employee routes such as `/visitor-approval` stay in the employee area.
bool isVisitorPortalLocation(String location) =>
    location == '/visitor' || location.startsWith('/visitor/');
