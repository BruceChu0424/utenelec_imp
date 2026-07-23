// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Uten Integrated Management Platform';

  @override
  String get appName => 'Uten IMP';

  @override
  String get commonConfirm => 'Confirm';

  @override
  String get commonCancel => 'Cancel';

  @override
  String get commonSave => 'Save';

  @override
  String get commonDelete => 'Delete';

  @override
  String get commonEdit => 'Edit';

  @override
  String get commonAdd => 'Add';

  @override
  String get commonSearch => 'Search';

  @override
  String get commonRefresh => 'Refresh';

  @override
  String get commonRetry => 'Retry';

  @override
  String get commonClose => 'Close';

  @override
  String get commonBack => 'Back';

  @override
  String get commonLoading => 'Loading…';

  @override
  String get commonNoData => 'No data';

  @override
  String get commonError => 'Something went wrong, please try again';

  @override
  String get commonSuccess => 'Success';

  @override
  String get commonFailed => 'Failed';

  @override
  String get commonMore => 'More';

  @override
  String get commonViewAll => 'View all';

  @override
  String get commonAction => 'Action';

  @override
  String get loginTitle => 'Welcome back';

  @override
  String get loginSubtitle => 'Sign in to Uten Integrated Management Platform';

  @override
  String get loginAccountLabel => 'Account';

  @override
  String get loginAccountHint => 'Employee code or phone number';

  @override
  String get loginAccountRequired => 'Please enter your account';

  @override
  String get loginPasswordLabel => 'Password';

  @override
  String get loginPasswordHint => 'Enter your password';

  @override
  String get loginPasswordRequired => 'Please enter your password';

  @override
  String get loginRememberMe => 'Remember this device';

  @override
  String get loginForgotPassword => 'Forgot password?';

  @override
  String get loginButton => 'Sign In';

  @override
  String get loginLoggingIn => 'Signing in…';

  @override
  String get loginSuccess => 'Signed in';

  @override
  String get loginFailed => 'Invalid account or password';

  @override
  String get loginWelcomeHint => 'Demo mode: any account/password works';

  @override
  String get loginFooter => '© 2026 Uten Integrated Management Platform';

  @override
  String get navDashboard => 'Dashboard';

  @override
  String get navProfile => 'Me';

  @override
  String get navSettings => 'Settings';

  @override
  String dashboardWelcome(Object name) {
    return 'Welcome, $name';
  }

  @override
  String get dashboardWelcomeSubtitle => 'Let\'s make today productive';

  @override
  String get dashboardTodayStats => 'Today\'s overview';

  @override
  String get dashboardQuickActions => 'Quick actions';

  @override
  String get statTodayOutput => 'Today\'s output';

  @override
  String get statOutputUnit => 'units';

  @override
  String get statInventory => 'Inventory';

  @override
  String get statOnlineEmployees => 'Online employees';

  @override
  String get statPendingTodos => 'Pending todos';

  @override
  String statTrendUp(Object percent) {
    return '+$percent% vs yesterday';
  }

  @override
  String statTrendDown(Object percent) {
    return '$percent% vs yesterday';
  }

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsSectionAppearance => 'Appearance';

  @override
  String get settingsThemeMode => 'Theme mode';

  @override
  String get settingsThemeLight => 'Light';

  @override
  String get settingsThemeDark => 'Dark';

  @override
  String get settingsThemeSystem => 'System';

  @override
  String get settingsLanguage => 'Language';

  @override
  String get settingsLanguageZh => '简体中文';

  @override
  String get settingsLanguageEn => 'English';

  @override
  String get settingsFontSize => 'Font size';

  @override
  String get settingsFontSmall => 'Small';

  @override
  String get settingsFontMedium => 'Medium';

  @override
  String get settingsFontLarge => 'Large';

  @override
  String get settingsFontXLarge => 'Extra large';

  @override
  String get settingsSectionPerformance => 'Performance';

  @override
  String get settingsPerformanceTier => 'Performance mode';

  @override
  String get settingsPerformanceAuto => 'Auto';

  @override
  String get settingsPerformanceLite => 'Lite';

  @override
  String get settingsPerformanceStandard => 'Standard';

  @override
  String get settingsPerformanceRich => 'Rich';

  @override
  String get settingsPerformanceHint => 'Choose Lite for low-end devices';

  @override
  String get settingsSectionAbout => 'About';

  @override
  String get settingsVersion => 'Version';

  @override
  String get settingsLogout => 'Sign out';

  @override
  String get settingsLogoutConfirm => 'Are you sure you want to sign out?';

  @override
  String get profileTitle => 'Me';

  @override
  String get profileEditProfile => 'Edit profile';

  @override
  String get profileChangePassword => 'Change password';

  @override
  String get profileEmployeeCode => 'Employee code';

  @override
  String get profileDepartment => 'Department';

  @override
  String get profilePosition => 'Position';

  @override
  String get entryTitle => 'Welcome to Uten';

  @override
  String get entrySubtitle => 'Choose how to sign in';

  @override
  String get entryStaff => 'Staff Sign In';

  @override
  String get entryStaffDesc => 'Employee / HR / Finance / Manager / Security';

  @override
  String get entryVisitor => 'Visitor Sign In';

  @override
  String get entryVisitorDesc => 'Visitor appointment registration';

  @override
  String get entryStaffHint =>
      'You are a Uten employee, please use staff sign in';

  @override
  String get visitorLoginTitle => 'Visitor Sign In';

  @override
  String get visitorLoginSubtitle => 'Enter your phone to get a code';

  @override
  String get visitorPhoneLabel => 'Phone';

  @override
  String get visitorPhoneHint => 'Enter your phone number';

  @override
  String get visitorCodeLabel => 'Code';

  @override
  String get visitorCodeHint => 'Enter the verification code';

  @override
  String get visitorCodeRequired => 'Please enter the verification code';

  @override
  String get visitorGetCode => 'Get code';

  @override
  String visitorCodeCountdown(Object seconds) {
    return 'Resend in ${seconds}s';
  }

  @override
  String get visitorLoginButton => 'Sign In';

  @override
  String get visitorLoggingIn => 'Signing in…';

  @override
  String get visitorCodeSent => 'Code sent';

  @override
  String visitorCodeSentDev(Object code) {
    return 'Code: $code (dev)';
  }

  @override
  String get visitorIsEmployee =>
      'This phone is a Uten employee account, please use staff sign in';

  @override
  String get visitorPhoneInvalid => 'Please enter a valid phone number';

  @override
  String get visitorHomeTitle => 'My Appointments';

  @override
  String get visitorApplyNew => 'New Visit';

  @override
  String get visitorFilterAll => 'All';

  @override
  String get visitorFilterPending => 'Pending';

  @override
  String get visitorFilterApproved => 'Approved';

  @override
  String get visitorFilterRejected => 'Rejected';

  @override
  String get visitorApplyTitle => 'Visit Appointment';

  @override
  String get visitorApplyName => 'Name';

  @override
  String get visitorApplyNameHint => 'Enter your full name';

  @override
  String get visitorApplyIdCard => 'ID Number';

  @override
  String get visitorApplyIdCardHint => 'Optional';

  @override
  String get visitorApplyCompany => 'Company';

  @override
  String get visitorApplyCompanyHint => 'Optional';

  @override
  String get visitorApplyPurpose => 'Purpose';

  @override
  String get visitorApplyPurposeHint => 'State your visit purpose';

  @override
  String get visitorApplyVehicle => 'Driving';

  @override
  String get visitorApplyPlate => 'Plate No.';

  @override
  String get visitorApplyPlateHint => 'Enter plate number';

  @override
  String get visitorApplyHost => 'Host';

  @override
  String get visitorApplyHostHint => 'Select the person to visit';

  @override
  String get visitorApplyDept => 'Department';

  @override
  String get visitorApplyVisitTime => 'Planned visit time';

  @override
  String get visitorApplySubmit => 'Submit';

  @override
  String get visitorApplySubmitting => 'Submitting…';

  @override
  String get visitorApplyValidateName => 'Please enter your name';

  @override
  String get visitorApplyValidatePurpose => 'Please fill in the purpose';

  @override
  String get visitorApplyValidateHost => 'Please select a host';

  @override
  String get visitorApplyValidateVisitTime => 'Please select visit time';

  @override
  String get visitorApplySuccess => 'Submitted, awaiting approval';

  @override
  String get visitorStatusPending => 'Pending';

  @override
  String get visitorStatusHostReviewing => 'Awaiting host confirm';

  @override
  String get visitorStatusApproved => 'Approved';

  @override
  String get visitorStatusRejected => 'Rejected';

  @override
  String get visitorStatusCheckedIn => 'Checked in';

  @override
  String get visitorStatusCancelled => 'Cancelled';

  @override
  String get visitorDetailTitle => 'Appointment Detail';

  @override
  String get visitorDetailHost => 'Host';

  @override
  String get visitorDetailPurpose => 'Purpose';

  @override
  String get visitorDetailVisitTime => 'Visit time';

  @override
  String get visitorDetailVehicle => 'Vehicle';

  @override
  String get visitorDetailAppliedAt => 'Submitted';

  @override
  String get visitorDetailApprovedAt => 'Approved';

  @override
  String get visitorDetailRejectReason => 'Reject reason';

  @override
  String get visitorDetailQr => 'Entry Pass';

  @override
  String get visitorDetailQrHint => 'Show this QR to the security guard';

  @override
  String get visitorDetailTimeline => 'Timeline';

  @override
  String get visitorLogout => 'Sign out';

  @override
  String get visitorApprovalTitle => 'Visitor Approval';

  @override
  String get visitorApprovalPending => 'Pending';

  @override
  String get visitorApprovalProcessed => 'Processed';

  @override
  String get visitorApprovalApprove => 'Approve';

  @override
  String get visitorApprovalReject => 'Reject';

  @override
  String get visitorApprovalForward => 'Forward to host';

  @override
  String get visitorApprovalRejectReason => 'Reject reason';

  @override
  String get visitorApprovalRejectReasonHint => 'Optional';

  @override
  String get visitorApprovalConfirmApprove => 'Approve this visitor?';

  @override
  String get visitorApprovalConfirmReject => 'Reject this visitor?';

  @override
  String get visitorApprovalHostConfirmed => 'Host confirmed';

  @override
  String get visitorApprovalEmpty => 'No visitors to approve';

  @override
  String get myVisitorsTitle => 'My Visitors';

  @override
  String get myVisitorsEmpty => 'No visitors need your confirmation';

  @override
  String get myVisitorsConfirm => 'Accept';

  @override
  String get myVisitorsReject => 'Decline';

  @override
  String get myVisitorsConfirmHint => 'Confirm to host this visitor?';

  @override
  String get securityTitle => 'Visitor Check';

  @override
  String get securityScanHint => 'Point the visitor QR at the frame';

  @override
  String get securityScanManual => 'Enter code manually';

  @override
  String get securityManualInputHint => 'Paste or enter the QR content';

  @override
  String get securityPasscodeHint => 'Enter the 6-digit pass code';

  @override
  String get visitorPasscodeLabel => 'Pass code';

  @override
  String get securityVerifying => 'Verifying…';

  @override
  String get securityPass => 'Allow entry';

  @override
  String get securityReject => 'Deny entry';

  @override
  String get securityReasonOk => 'Valid pass';

  @override
  String get securityReasonInvalid => 'Invalid QR';

  @override
  String get securityReasonExpired => 'Pass expired';

  @override
  String get securityReasonUsed => 'Pass already used';

  @override
  String get securityReasonRejected => 'Visitor rejected';

  @override
  String get securityCheckIn => 'Check in';

  @override
  String get securityCheckInDone => 'Checked in';

  @override
  String get securityVisitor => 'Visitor';

  @override
  String get securityPurpose => 'Purpose';

  @override
  String get securityHost => 'Host';

  @override
  String get securityPlate => 'Plate';

  @override
  String get securityVisitTime => 'Visit time';
}
