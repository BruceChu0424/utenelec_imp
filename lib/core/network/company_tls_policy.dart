import 'api_exception.dart';

const companyCaAsset = 'assets/security/uten-imp-root-ca.crt';
const companyCaPemSha256 =
    'e8479fe7113e0efd5d877cb5a35611454d8fd641728fedd8840e1501deb23763';

bool isApprovedCompanyTlsOrigin(Uri uri) =>
    uri.scheme == 'https' &&
    uri.userInfo.isEmpty &&
    uri.port == 443 &&
    const {'192.168.1.13', 'imp.utenelec'}.contains(uri.host.toLowerCase());

/// A certificate failure is not evidence that another server should receive
/// the user's credentials. Keep the ordinary account/password authentication.
class CompanyTlsException extends ApiException {
  CompanyTlsException() : super('COMPANY_TLS_INVALID', '内网证书验证失败，请联系管理员');
}
