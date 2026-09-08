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
  String get appName => 'UTEN IMP';

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
  String get connectionReconnecting => 'The network is unstable. Reconnecting…';

  @override
  String get connectionDisconnected =>
      'The server is temporarily unavailable. Reconnecting automatically';

  @override
  String get connectionRestored => 'Connection restored. You can continue.';

  @override
  String get connectionRetryNow => 'Retry now';

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
  String get loginAccountHint => 'Employee code or phone number';

  @override
  String get loginAccountRequired => 'Please enter your account';

  @override
  String get loginPasswordHint => 'Enter your password';

  @override
  String get loginPasswordRequired => 'Please enter your password';

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
  String get loginServerRecoveryAction => 'Restore automatic server selection';

  @override
  String get loginServerRecoveryHint =>
      'Use this after changing networks or if sign-in fails. Only the trusted office and cloud addresses built into this app are used.';

  @override
  String get loginServerRecoverySuccess =>
      'Automatic server selection restored. Please sign in again.';

  @override
  String get loginServerRecoveryFailed =>
      'Could not restore server selection. Try again or contact an administrator.';

  @override
  String get loginFooter => '© 2026 Uten Integrated Management Platform';

  @override
  String get navDashboard => 'Dashboard';

  @override
  String get navNotice => 'Notices';

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
  String get settingsFontMedium => 'Standard';

  @override
  String get settingsFontLarge => 'Large';

  @override
  String get settingsFontXLarge => 'Extra large';

  @override
  String get settingsFontXXLarge => 'Extra extra large';

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
  String get entrySubtitle => 'Choose how to sign in';

  @override
  String get entryStaff => 'Staff Sign In';

  @override
  String get entryVisitor => 'Visitor Sign In';

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
  String get visitorSettingsTitle => 'Visitor Settings';

  @override
  String get visitorSettingsTooltip => 'Settings';

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
  String get visitorApplyValidateIdCard =>
      'Please enter a valid 18-digit resident ID number';

  @override
  String get visitorApplyValidatePurpose => 'Please fill in the purpose';

  @override
  String get visitorApplyValidateHost => 'Please select a host';

  @override
  String get visitorApplyValidateVisitTime => 'Please select visit time';

  @override
  String get visitorApplyValidateVisitTimeFuture =>
      'Visit time must be later than now';

  @override
  String get visitorApplyDuplicateTime =>
      'You already have an active visit at this time';

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

  @override
  String get navHrGroup => 'HR Management';

  @override
  String get navHrEmployees => 'Employees';

  @override
  String get navHrDepartments => 'Departments';

  @override
  String get navHrOnboarding => 'Onboarding';

  @override
  String get navHrPayrollGenerate => 'Payslip Generation';

  @override
  String get navHrNoticePublish => 'Publish Notice';

  @override
  String get employeeTitle => 'Employees';

  @override
  String get employeeFabOnboard => 'Onboard';

  @override
  String get employeeSearchHint => 'Search by code, name or plate';

  @override
  String get employeeEmpty => 'No employees yet';

  @override
  String get employeeEmptyHint => 'Tap the Onboard button to add';

  @override
  String get employeeLoadMore => 'Load more';

  @override
  String get employeeDetailTitle => 'Employee Detail';

  @override
  String get employeeDetailBasic => 'Basic info';

  @override
  String get employeeDetailContact => 'Contact & address';

  @override
  String get employeeDetailOrg => 'Organization';

  @override
  String get employeeDetailContract => 'Contract & Pay (role-restricted)';

  @override
  String get employeeDetailEmergency => 'Emergency contacts';

  @override
  String get employeeDetailHistory => 'Employment history';

  @override
  String get employeeFieldCode => 'Employee code';

  @override
  String get employeeFieldName => 'Full name';

  @override
  String get employeeFieldGender => 'Gender';

  @override
  String get employeeFieldIdType => 'ID type';

  @override
  String get employeeFieldIdNumber => 'ID number';

  @override
  String get employeeFieldBirthDate => 'Date of birth';

  @override
  String get employeeFieldEthnicity => 'Ethnicity';

  @override
  String get employeeFieldPoliticalStatus => 'Political status';

  @override
  String get employeeFieldMaritalStatus => 'Marital status';

  @override
  String get employeeFieldPhone => 'Mobile';

  @override
  String get employeeFieldOfficePhone => 'Office phone';

  @override
  String get employeeFieldEmail => 'Company email';

  @override
  String get employeeFieldHujiAddress => 'Hukou address';

  @override
  String get employeeFieldResidenceAddress => 'Current address';

  @override
  String get employeeFieldDepartment => 'Department';

  @override
  String get employeeFieldPosition => 'Position';

  @override
  String get employeeFieldSupervisor => 'Supervisor';

  @override
  String get employeeFieldHireDate => 'Hire date';

  @override
  String get employeeFieldWorkYears => 'Seniority';

  @override
  String employeeWorkYearsYandM(int years, int months) {
    return '$years yr $months mo';
  }

  @override
  String employeeWorkYearsMonths(int months) {
    return '$months mo';
  }

  @override
  String get employeeWorkYearsUnderOneMonth => 'Under 1 month';

  @override
  String get employeeFieldConfirmedDate => 'Confirmed date';

  @override
  String get employeeFieldStatus => 'Status';

  @override
  String get employeeFieldEmploymentType => 'Employment type';

  @override
  String get employeeFieldWorkLocation => 'Work location';

  @override
  String get employeeFieldSeatNo => 'Seat';

  @override
  String get employeeFieldContractType => 'Contract type';

  @override
  String get employeeFieldContractPeriod => 'Contract period';

  @override
  String get employeeFieldProbation => 'Probation';

  @override
  String get employeeFieldRenewCount => 'Renewals';

  @override
  String get employeeFieldBaseSalary => 'Base salary';

  @override
  String get employeeFieldPerfSalary => 'Bonus/Allowance';

  @override
  String get employeeFieldSocialBase => 'Social base';

  @override
  String get employeeFieldHousingBase => 'Housing fund base';

  @override
  String get employeeFieldBankBranch => 'Bank branch';

  @override
  String get employeeFieldBankAccount => 'Bank account';

  @override
  String employeeContractPeriodValue(Object end, Object start) {
    return '$start ~ $end';
  }

  @override
  String employeeProbationValue(Object end, Object months) {
    return '$months months (until $end)';
  }

  @override
  String employeeRenewCountValue(Object count) {
    return '$count';
  }

  @override
  String get employeeFieldAccountStatus => 'Login account';

  @override
  String get accountStatusActive => 'Active';

  @override
  String get accountStatusLocked => 'Locked';

  @override
  String get accountStatusDisabled => 'Disabled';

  @override
  String get accountStatusNone => 'Not provisioned';

  @override
  String employeeProbationExpiring(Object date, Object days) {
    return 'Probation ends on $date ($days days left) — confirm employment in time';
  }

  @override
  String employeeProbationExpired(Object date) {
    return 'Probation ended on $date — please confirm employment or offboard';
  }

  @override
  String employeeContractExpiring(Object date, Object days) {
    return 'Contract ends on $date ($days days left) — please renew in time';
  }

  @override
  String employeeContractExpired(Object date) {
    return 'Contract expired on $date — please handle it';
  }

  @override
  String get employeeEditTitle => 'Edit employee';

  @override
  String get employeeEditBasic => 'Basic info';

  @override
  String get employeeEditOrg => 'Organization';

  @override
  String get employeeEditContact => 'Contact';

  @override
  String get employeeEditSalary => 'Salary & Bank';

  @override
  String get employeeEditFieldPhone => 'Mobile';

  @override
  String get employeeEditFieldDepartment => 'Department';

  @override
  String get employeeEditFieldPosition => 'Position';

  @override
  String get employeeEditFieldEmploymentType => 'Employment type';

  @override
  String get employeeEditFieldStatus => 'Status';

  @override
  String get employeeEditSaved => 'Saved';

  @override
  String get employeeEditSaveFailed => 'Save failed, please try again';

  @override
  String employeeEditLoadFailed(Object error) {
    return 'Failed to load: $error';
  }

  @override
  String get employeeEditNotFound => 'Employee not found';

  @override
  String get employeeEditRequired => 'Required';

  @override
  String get employeeOnboardTitle => 'New Employee Onboarding';

  @override
  String get employeeOnboardGroupProfile => 'Profile';

  @override
  String get employeeOnboardGroupOrg => 'Organization';

  @override
  String get employeeOnboardGroupPay => 'Pay & Bank (optional, HR/admin only)';

  @override
  String get employeeOnboardSubmit => 'Submit Onboarding';

  @override
  String get employeeOnboardSuccess =>
      'Onboarding completed and the one-time password was delivered';

  @override
  String get employeeOnboardSubmitFailed => 'Submit failed, please try again';

  @override
  String get employeeOnboardNote =>
      'Submitting auto-generates the employee code (UT prefix), uses the phone number as the login account, and issues a one-time password (last 6 digits of the ID number). It must be changed at first sign-in.';

  @override
  String get employeeOnboardCodeAutoNote =>
      'Employee code is auto-generated on submit (UT prefix, unique and incremental)';

  @override
  String get positionPickerTitle => 'Select or enter a position';

  @override
  String get positionPickerHint => 'Select or enter a position';

  @override
  String get positionPickerDepartmentFirst => 'Select a department first';

  @override
  String get positionPickerSearchHint =>
      'Search by position name, code, or level';

  @override
  String positionPickerUseCustom(Object name) {
    return 'Use “$name” as a new position';
  }

  @override
  String get positionPickerCustomDescription =>
      'It will be saved under the selected department after confirmation';

  @override
  String get positionPickerNoPositions =>
      'This department has no positions; enter a new one directly';

  @override
  String get positionPickerLoadFailed =>
      'Positions could not be loaded; retry or enter a new one directly';

  @override
  String get positionPickerClear => 'Clear';

  @override
  String get employeeOnboardCredentialTitle => 'Account created';

  @override
  String get employeeOnboardCredentialWarning =>
      'This temporary password is shown only once. Deliver it securely now; the plaintext cannot be retrieved after closing.';

  @override
  String get employeeOnboardAccountLabel => 'Login account';

  @override
  String get employeeOnboardTemporaryPasswordLabel =>
      'One-time temporary password';

  @override
  String get employeeOnboardCopyTemporaryPassword => 'Copy password';

  @override
  String get employeeOnboardTemporaryPasswordCopied =>
      'Temporary password copied';

  @override
  String get employeeOnboardCredentialSaved => 'I saved it securely';

  @override
  String get employeeOnboardHintName => 'Full name';

  @override
  String get employeeOnboardHintIdNumber => 'Enter ID number';

  @override
  String get employeeOnboardIdNumberInvalid => 'Invalid ID number format';

  @override
  String get employeeOnboardHintPhone => '11-digit phone';

  @override
  String get employeeOnboardPhoneRequired => 'Phone is required';

  @override
  String get employeeOnboardPhoneInvalid => 'Invalid phone format';

  @override
  String get employeeOnboardEmailOptional => 'Optional';

  @override
  String get employeeOnboardHireDateHint => 'yyyy-MM-dd';

  @override
  String get employeeOnboardPickHireDate => 'Please pick a hire date';

  @override
  String get employeeOnboardPickDepartment => 'Please select a department';

  @override
  String employeeOnboardFieldRequired(Object field) {
    return '$field is required';
  }

  @override
  String get employeeOnboardLoadFailed => 'Failed to load';

  @override
  String get idTypeIdCard => 'ID card';

  @override
  String get idTypePassport => 'Passport';

  @override
  String get idTypeHmtPermit => 'HK/Macao/Taiwan permit';

  @override
  String get idTypeOther => 'Other';

  @override
  String get employeeOffboardTitle => 'Offboarding';

  @override
  String get employeeOffboardFieldType => 'Resign type';

  @override
  String get employeeOffboardFieldDate => 'Last day';

  @override
  String get employeeOffboardPickDate => 'Pick a date';

  @override
  String get employeeOffboardFieldReason => 'Reason';

  @override
  String get employeeOffboardPickDateRequired => 'Please pick the last day';

  @override
  String get employeeOffboardChecksRequired =>
      'Please confirm all recovery items';

  @override
  String get employeeOffboardConfirmTitle => 'Confirm offboarding?';

  @override
  String get employeeOffboardConfirmBody =>
      'This employee account will be disabled.';

  @override
  String get employeeOffboardConfirmAction => 'Confirm offboarding';

  @override
  String get employeeOffboardNext => 'Next';

  @override
  String get employeeOffboardBack => 'Back';

  @override
  String get employeeOffboardCompleted => 'Offboarding completed';

  @override
  String get employeeOffboardLoadFailed => 'Failed to load';

  @override
  String get employeeActions => 'More actions';

  @override
  String get employeeActionTransfer => 'Transfer';

  @override
  String get employeeActionConfirm => 'Confirm employment';

  @override
  String get employeeActionOffboard => 'Offboard';

  @override
  String get employeeActionRehire => 'Rehire';

  @override
  String get employeeActionDelete => 'Delete record';

  @override
  String get employeeActionProvision => 'Provision login account';

  @override
  String get employeeActionLockAccount => 'Lock account';

  @override
  String get employeeActionUnlockAccount => 'Unlock account';

  @override
  String get employeeLockAccountSuccess => 'Account locked';

  @override
  String get employeeUnlockAccountSuccess => 'Account unlocked';

  @override
  String get employeeProvisionConfirm =>
      'This creates a login account for the employee. The account defaults to the phone number, the initial password is the last 6 digits of the ID number, and it must be changed on first login. Continue?';

  @override
  String get employeeTransferTitle => 'Employee transfer';

  @override
  String get employeeTransferFieldDate => 'Effective date';

  @override
  String get employeeTransferPickDate => 'Pick a date';

  @override
  String get employeeTransferFieldRemark => 'Remark';

  @override
  String get employeeTransferDateRequired => 'Please pick the effective date';

  @override
  String get employeeTransferSuccess => 'Transfer completed';

  @override
  String get employeeConfirmTitle => 'Confirm regular employment?';

  @override
  String get employeeConfirmBody => 'The employee status will become Active.';

  @override
  String get employeeConfirmSuccess => 'Employment confirmed';

  @override
  String get employeeRehireTitle => 'Confirm rehire?';

  @override
  String get employeeRehireBody =>
      'The employee will become Active again and the login account will be re-enabled (re-login required).';

  @override
  String get employeeRehireSuccess => 'Rehired';

  @override
  String get employeeDeleteTitle => 'Delete this employee record?';

  @override
  String get employeeDeleteBody =>
      'The login account will be disabled. This cannot be undone.';

  @override
  String get employeeDeleteSuccess => 'Employee record deleted';

  @override
  String get resignTypeVoluntary => 'Voluntary';

  @override
  String get resignTypeDismissed => 'Dismissed';

  @override
  String get resignTypeContractEnd => 'Contract ended';

  @override
  String get resignTypeRetire => 'Retirement';

  @override
  String get resignCheckAccess => 'Return access card';

  @override
  String get resignCheckAssets => 'Recover company assets';

  @override
  String get resignCheckAccount => 'Disable system account';

  @override
  String get resignCheckSocial => 'Stop social insurance & housing fund';

  @override
  String get employeeStatusActive => 'Active';

  @override
  String get employeeStatusProbation => 'Probation';

  @override
  String get employeeStatusOnLeave => 'On leave';

  @override
  String get employeeStatusResigned => 'Resigned';

  @override
  String get employeeStatusUnknown => 'Unknown';

  @override
  String get genderMale => 'Male';

  @override
  String get genderFemale => 'Female';

  @override
  String get employmentTypeRegular => 'Regular';

  @override
  String get employmentTypeDispatch => 'Dispatch';

  @override
  String get employmentTypeIntern => 'Intern';

  @override
  String get employmentTypeOutsource => 'Outsource';

  @override
  String get contractTypeFixed => 'Fixed-term';

  @override
  String get contractTypeOpen => 'Open-ended';

  @override
  String get contractTypeTask => 'Task-based';

  @override
  String get contractTypeIntern => 'Intern';

  @override
  String get historyEventOnboard => 'Onboard';

  @override
  String get historyEventTransfer => 'Transfer';

  @override
  String get historyEventResign => 'Resign';

  @override
  String get historyEventRehire => 'Rehire';

  @override
  String get departmentTitle => 'Departments';

  @override
  String get departmentTreeTitle => 'Organization';

  @override
  String get departmentEmpty => 'Select a department';

  @override
  String get departmentEmptyHint => 'Tap the icon to open the org tree';

  @override
  String get departmentEmptySelect => 'Pick a department on the left';

  @override
  String get departmentTooltipAdd => 'Add department';

  @override
  String get departmentTooltipRefresh => 'Refresh';

  @override
  String get departmentTooltipTree => 'Tree';

  @override
  String get departmentDialogAddTitle => 'New department';

  @override
  String get departmentDialogDeleteTitle => 'Delete department';

  @override
  String get departmentFieldCode => 'Department code';

  @override
  String get departmentFieldCodeHint => 'e.g. DEPT-XX';

  @override
  String get departmentFieldName => 'Department name';

  @override
  String get departmentFieldLevel => 'Level';

  @override
  String get departmentCreate => 'Create';

  @override
  String get departmentDelete => 'Delete';

  @override
  String get departmentRequireCodeAndName => 'Code and name are required';

  @override
  String get departmentCreated => 'Created';

  @override
  String get departmentDeleted => 'Deleted';

  @override
  String departmentDeleteConfirm(Object name) {
    return 'Delete \"$name\"? Only leaf departments without sub-departments or employees can be removed.';
  }

  @override
  String departmentLevelAndCode(Object level, Object code) {
    return '$level · Code $code';
  }

  @override
  String get departmentStatEmployees => 'Employees';

  @override
  String get departmentStatChildren => 'Sub-departments';

  @override
  String get departmentStatManager => 'Manager';

  @override
  String get departmentStatParent => 'Parent';

  @override
  String departmentEmployeesHeader(Object count) {
    return 'Employees ($count)';
  }

  @override
  String get departmentEmployeesEmpty =>
      'No employees in this department (or its sub-departments)';

  @override
  String departmentStatValue(Object label, Object value) {
    return '$label: $value';
  }

  @override
  String get departmentLoadFailed => 'Failed to load';

  @override
  String get departmentLevelCompany => 'Company';

  @override
  String get departmentLevelDecision => 'Decision layer';

  @override
  String get departmentLevelManagement => 'Management center';

  @override
  String get departmentLevelPrimary => 'Primary department';

  @override
  String get departmentLevelSecondary => 'Secondary team';

  @override
  String get departmentLevelTertiary => 'Tertiary unit';

  @override
  String get payrollGenerateTitle => 'Payslip Generation';

  @override
  String get payrollStepScope => 'Scope';

  @override
  String get payrollStepItems => 'Pay items';

  @override
  String get payrollStepPreview => 'Preview';

  @override
  String get payrollStepSubmit => 'Submit for review';

  @override
  String get payrollFieldMonth => 'Pay month';

  @override
  String get payrollFieldScope => 'Scope';

  @override
  String get payrollItemOvertime => 'Overtime (+15%)';

  @override
  String get payrollItemBonus => 'Performance bonus (+10%)';

  @override
  String get payrollItemSocial => 'Social & housing (-10.5%)';

  @override
  String get payrollItemTax => 'Income tax (-5%)';

  @override
  String get payrollSubmitNote =>
      'After submission it enters finance review. Once approved, HR releases the slips to employees.';

  @override
  String get payrollSubmitButton => 'Submit for review';

  @override
  String get payrollSubmitted => 'Submitted for finance review';

  @override
  String payrollLoadFailed(Object error) {
    return 'Failed to load: $error';
  }

  @override
  String get payrollEmptyPreview => 'No employees in this scope';

  @override
  String get payrollTableTotalLabel => 'Total';

  @override
  String payrollTableTotalValue(Object total, Object count) {
    return '¥ $total · $count';
  }

  @override
  String get payrollTableHeaderName => 'Code/Name';

  @override
  String get payrollTableHeaderNet => 'Net';

  @override
  String payrollTableRowName(Object name, Object code) {
    return '$name ($code)';
  }

  @override
  String payrollTableRowNet(Object net) {
    return '¥ $net';
  }

  @override
  String get payrollNext => 'Next';

  @override
  String get payrollBack => 'Back';

  @override
  String get payrollDeptAll => 'All employees';

  @override
  String get payrollDeptProduction => 'Production';

  @override
  String get payrollDeptQuality => 'Quality';

  @override
  String get payrollDeptHr => 'HR';

  @override
  String get payrollDeptFinance => 'Finance';

  @override
  String get noticePublishTitle => 'Publish Notice';

  @override
  String get noticePublishSaveDraft => 'Save draft';

  @override
  String get noticePublishDraftSaved => 'Draft saved';

  @override
  String get noticePublishPublishButton => 'Publish';

  @override
  String get noticePublishTopPriority => 'Pin to top';

  @override
  String get noticePublishTitleHint => 'Notice title (required)';

  @override
  String get noticePublishContentHint => 'Notice body…';

  @override
  String get noticePublishScopeTitle => 'Audience';

  @override
  String get noticePublishScopeAll => 'Everyone';

  @override
  String get noticePublishScopeDept => 'By department';

  @override
  String get noticePublishFieldDept => 'Department';

  @override
  String get noticePublishScopeAllHint =>
      'Notify every employee in the company';

  @override
  String noticePublishScopeDeptHint(Object dept) {
    return 'Notify everyone in \"$dept\"';
  }

  @override
  String get noticePublishValidateTitle => 'Please enter a title';

  @override
  String get noticePublishValidateContent => 'Please enter the body';

  @override
  String get noticePublishConfirmTitle => 'Confirm publish?';

  @override
  String get noticePublishConfirmBodyAll => 'Notify all employees';

  @override
  String noticePublishConfirmBodyDept(Object dept) {
    return 'Notify \"$dept\"';
  }

  @override
  String get noticePublishPublished => 'Notice published';

  @override
  String get noticePublishPublishing => 'Publishing…';

  @override
  String get noticePublishContentSection => 'Notice content';

  @override
  String get noticePublishTypeLabel => 'Notice type';

  @override
  String get noticePublishTitleLabel => 'Title';

  @override
  String get noticePublishContentLabel => 'Body';

  @override
  String get noticePublishUrgentHint =>
      'Urgent notices use a high-priority alert. Use this only for items requiring immediate attention.';

  @override
  String get noticePublishTopPriorityHint =>
      'Pinned notices appear first and alert recipients as important.';

  @override
  String get noticePublishScopeSelected => 'Selected audience';

  @override
  String get noticePublishScopeSelectedHint =>
      'Departments and people can be combined. Departments include descendants and duplicate recipients are removed.';

  @override
  String get noticePublishDepartmentsLabel => 'Departments (multiple)';

  @override
  String get noticePublishDepartmentsHint => 'Choose one or more departments';

  @override
  String get noticePublishEmployeesLabel => 'Add individual people';

  @override
  String get noticePublishEmployeesHint => 'Choose specific people (multiple)';

  @override
  String get noticePublishEmployeePickerTitle => 'Choose recipients';

  @override
  String get noticePublishEmployeeSearchHint => 'Search name / employee code';

  @override
  String get noticePublishEmployeeEmpty => 'No active recipient account found';

  @override
  String noticePublishEmployeeSelectedCount(int count) {
    return '$count selected';
  }

  @override
  String get noticePublishEmployeeClear => 'Clear';

  @override
  String get noticePublishEmployeeConfirm => 'Done';

  @override
  String get noticePublishValidateAudience =>
      'Choose at least one department or person';

  @override
  String noticePublishAudienceSummary(
    Object departmentCount,
    Object employeeCount,
  ) {
    return '$departmentCount departments and $employeeCount people selected';
  }

  @override
  String get noticePublishAudienceRecalculateHint =>
      'The server recalculates the actual recipient count from the current organisation and account status before publishing.';

  @override
  String noticePublishConfirmAudience(Object summary, Object count) {
    return 'Send to $summary; $count actual recipients.';
  }

  @override
  String noticePublishPublishedTo(Object count) {
    return 'Notice published to $count people';
  }

  @override
  String get noticeTypeAnnouncement => 'Announcement';

  @override
  String get noticeTypePolicy => 'Policy';

  @override
  String get noticeTypeBenefit => 'Benefit';

  @override
  String get noticeTypeSystem => 'System';

  @override
  String get noticeTypeUrgent => 'Urgent';

  @override
  String get noticeTypeBirthday => 'Birthday';

  @override
  String get noticeTypeAnniversary => 'Anniversary';

  @override
  String get noticeTypeWedding => 'Wedding';

  @override
  String get noticeTypeNewborn => 'Newborn';

  @override
  String get noticeTypeAnnouncementDesc =>
      'Company announcement; everyone can tap “Acknowledge”';

  @override
  String get noticeTypePolicyDesc =>
      'Policy release; everyone can tap “Acknowledge”';

  @override
  String get noticeTypeBenefitDesc =>
      'Benefit notice; everyone can tap “Acknowledge”';

  @override
  String get noticeTypeSystemDesc =>
      'System notice; everyone can tap “Acknowledge”';

  @override
  String get noticeTypeUrgentDesc => 'Urgent notice with high-priority alert';

  @override
  String get noticeTypeBirthdayDesc =>
      'Celebrate a birthday; everyone can “Send blessing”';

  @override
  String get noticeTypeAnniversaryDesc =>
      'Work anniversary; everyone can “Send blessing”';

  @override
  String get noticeTypeWeddingDesc =>
      'Wedding blessing; everyone can “Send blessing”';

  @override
  String get noticeTypeNewbornDesc =>
      'Newborn blessing; everyone can “Send blessing”';

  @override
  String get noticeGroupBroadcast => 'Broadcast';

  @override
  String get noticeGroupCelebration => 'Celebration';

  @override
  String get noticeInteractionReceive => 'Acknowledge';

  @override
  String get noticeInteractionReceived => 'Acknowledged';

  @override
  String get noticeClickToReceive => 'Tap to acknowledge';

  @override
  String noticeAckCount(int count) {
    return '$count acknowledged';
  }

  @override
  String noticeAckYouAndCount(int count) {
    return 'You acknowledged · $count total';
  }

  @override
  String get noticeAckRecent => 'Recent';

  @override
  String get noticeSendBlessing => 'Send blessing';

  @override
  String get noticeBlessingSent => 'Blessing sent';

  @override
  String noticeBlessingCount(int count) {
    return '$count blessings';
  }

  @override
  String get noticeBlessingWall => 'Blessing Wall';

  @override
  String noticeBlessingReceivedCount(int count) {
    return '$count blessings received';
  }

  @override
  String get noticeBlessingWallEmpty => 'No blessings yet — send the first one';

  @override
  String get noticeBlessingPlaceholder => 'Write your blessing…';

  @override
  String get noticeBlessingSendButton => 'Send blessing';

  @override
  String get noticeBlessingSending => 'Sending…';

  @override
  String get noticeBlessingWithdraw => 'Withdraw';

  @override
  String noticeBlessingViewAll(int count) {
    return 'View all $count';
  }

  @override
  String get noticeBlessingTemplatesTitle => 'Pick a blessing';

  @override
  String get noticeBlessingValidateEmpty => 'Please enter a blessing';

  @override
  String get noticeCelebrationSubjectLabel => 'Honoree';

  @override
  String get noticeCelebrationSubjectHint =>
      'Choose the colleague to celebrate';

  @override
  String get noticeCelebrationSubjectRequired => 'Please choose an honoree';

  @override
  String get noticeCelebrationSubjectIsYou => 'You';

  @override
  String noticeCelebrationFor(Object name, Object event) {
    return '$name · $event';
  }

  @override
  String get noticeQuickCelebrationTitle => 'Quick celebration';

  @override
  String get noticeQuickCelebrationSubtitle =>
      'Pick a type; the template fills automatically';

  @override
  String get noticeQuickPublish => 'New notice';

  @override
  String get noticeQuickBirthday => 'Birthday';

  @override
  String get noticeQuickAnniversary => 'Anniversary';

  @override
  String get noticeQuickWedding => 'Wedding';

  @override
  String get noticeQuickNewborn => 'Newborn';

  @override
  String celebrationPopupBirthday(Object name) {
    return '$name, today is your birthday!\nXiao You wishes you a happy birthday!';
  }

  @override
  String celebrationPopupAnniversary(Object name, Object label) {
    return '$name, today is your work anniversary!\nXiao You wishes you $label!';
  }

  @override
  String celebrationPopupWedding(Object name) {
    return '$name, congratulations on your wedding!\nXiao You wishes you a lifetime of happiness!';
  }

  @override
  String celebrationPopupNewborn(Object name) {
    return '$name, congratulations on the new baby!\nXiao You wishes your little one health and joy!';
  }

  @override
  String get celebrationDismiss => 'Thanks, Xiao You';

  @override
  String celebrationCardBirthday(Object name) {
    return 'Today is $name\'s birthday';
  }

  @override
  String celebrationCardAnniversary(Object name, Object label) {
    return 'Today is $name\'s $label';
  }

  @override
  String celebrationCardWedding(Object name) {
    return 'Today is $name\'s wedding day';
  }

  @override
  String celebrationCardNewborn(Object name) {
    return '$name welcomes a new baby';
  }

  @override
  String get celebrationCardCta => 'Send blessings';

  @override
  String get celebrationCardWall => 'View blessing wall';

  @override
  String get noticeAutoCelebrationTitle => 'Auto celebration notices';

  @override
  String get noticeAutoCelebrationEnabled =>
      'Auto-publish a company-wide blessing daily for birthdays and anniversaries';

  @override
  String get noticeAutoCelebrationTypes => 'Auto types';

  @override
  String get noticeAutoCelebrationPublisher => 'Publisher name';

  @override
  String get profileChangeEditTitle => 'Edit profile';

  @override
  String get profileChangeEditCta => 'Edit my profile';

  @override
  String get profileChangeEditHrOnlyHint =>
      'Please contact HR to change the fields below';

  @override
  String get profileChangeSectionBasic =>
      'Basic info (changes apply immediately)';

  @override
  String get profileChangeSectionReview =>
      'Contact & important fields (require HR review)';

  @override
  String get profileChangeSectionIdentity =>
      'Name & emergency contacts (require HR review)';

  @override
  String get profileChangeFieldDirect => 'Direct edit';

  @override
  String get profileChangeFieldReview => 'Requires HR review';

  @override
  String get profileChangeFieldHrOnly => 'Contact HR';

  @override
  String get profileChangePasswordHint =>
      'For your safety, please enter your current password';

  @override
  String get profileChangePasswordLabel => 'Current password';

  @override
  String get profileChangePasswordWrong => 'Incorrect password';

  @override
  String get profileChangeSubmitSuccess => 'Submitted, pending HR review';

  @override
  String get profileChangeSubmitApplied => 'Changes saved';

  @override
  String get profileChangeSubmitFailed => 'Submit failed, please retry';

  @override
  String get profileChangeConflict =>
      'Profile has been updated by someone else, please refresh';

  @override
  String get profileChangeRateLimited =>
      'You already submitted a change for this field in the last 24 hours';

  @override
  String get profileChangeListTitle => 'My change requests';

  @override
  String get profileChangeListCta => 'View my requests';

  @override
  String get profileChangeListEmpty => 'No change requests yet';

  @override
  String get profileChangeFilterAll => 'All';

  @override
  String get profileChangeFilterPending => 'Pending';

  @override
  String get profileChangeFilterApplied => 'Applied';

  @override
  String get profileChangeFilterApproved => 'Approved';

  @override
  String get profileChangeFilterRejected => 'Rejected';

  @override
  String get profileChangeFilterCancelled => 'Cancelled';

  @override
  String get profileChangeStatusPending => 'Pending HR review';

  @override
  String get profileChangeStatusApplied => 'Applied';

  @override
  String get profileChangeStatusApproved => 'Approved';

  @override
  String get profileChangeStatusRejected => 'Rejected';

  @override
  String get profileChangeStatusCancelled => 'Cancelled';

  @override
  String get profileChangeCancel => 'Cancel';

  @override
  String get profileChangeCancelledByMe => 'Cancelled by me';

  @override
  String get profileChangeFieldLabel => 'Field';

  @override
  String get profileChangeBefore => 'Before';

  @override
  String get profileChangeAfter => 'After';

  @override
  String get profileChangeSubmittedAt => 'Submitted at';

  @override
  String get profileChangeReviewer => 'Reviewer';

  @override
  String get profileChangeReviewComment => 'Review comment';

  @override
  String get profileChangeDiffTitle => 'Changes in this request';

  @override
  String profileChangeBatchItems(Object count) {
    return '$count field(s)';
  }

  @override
  String get profileChangeHrQueueTitle => 'Profile change reviews';

  @override
  String get profileChangeHrQueueEmpty => 'No pending reviews';

  @override
  String get profileChangeReviewApprove => 'Approve';

  @override
  String get profileChangeReviewReject => 'Reject';

  @override
  String get profileChangeRejectDialogTitle => 'Reject request';

  @override
  String get profileChangeRejectReasonRequired =>
      'Rejection reason is required';

  @override
  String get profileChangeRejectReasonHint =>
      'Explain why; the employee will see this';

  @override
  String get profileChangeApproveDialogTitle => 'Confirm approval?';

  @override
  String get profileChangeApproveDialogBody =>
      'Changes will be merged into the employee profile immediately';

  @override
  String get profileChangeConfirm => 'Confirm';

  @override
  String get profileChangeCancel2 => 'Cancel';

  @override
  String get profileChangeRejectSuccess => 'Rejected';

  @override
  String get profileChangeApproveSuccess => 'Approved';

  @override
  String get profileChangeFieldPhone => 'Mobile';

  @override
  String get profileChangeFieldFullName => 'Full name';

  @override
  String get profileChangeFieldHujiAddress => 'Hukou address';

  @override
  String get profileChangeFieldEmergencyName => 'Emergency contact name';

  @override
  String get profileChangeFieldEmergencyPhone => 'Emergency contact phone';

  @override
  String get profileChangeFieldEmergencyRelationship => 'Relationship';

  @override
  String profilePendingBadge(Object count) {
    return '$count pending';
  }

  @override
  String get profilePendingSectionTitle => 'Pending profile change reviews';

  @override
  String get profilePendingSectionEmpty =>
      'No pending reviews for this employee';

  @override
  String get profilePendingSectionViewAll => 'All →';

  @override
  String get profileFieldPhoneMask => '138****1234';

  @override
  String get profileFieldIdCardMask => '****';

  @override
  String get profileFieldBankAccountMask => '****1234';

  @override
  String get profileFieldGroupIdentity => 'Identity';

  @override
  String get profileFieldGroupContact => 'Contact';

  @override
  String get profileFieldGroupAddress => 'Address';

  @override
  String get profileFieldGroupEmergency => 'Emergency contacts';

  @override
  String get profileFieldGroupOrganization => 'Organization';

  @override
  String get profileEditPolicyHint =>
      'Green \"direct edit\" fields apply immediately; yellow fields take effect after HR review; all other fields are maintained by HR.';

  @override
  String profileEditPendingConflictHint(int count) {
    return 'You have $count pending request(s); editing the same fields again before approval may conflict with them.';
  }

  @override
  String get profileEditFieldAction => 'Edit';

  @override
  String get profileFieldGroupOrg => 'Organization';

  @override
  String get profileFieldGroupCompensation => 'Compensation & bank';

  @override
  String get profileFieldWorkLocation => 'Work location';

  @override
  String get profileFieldSeatNo => 'Seat';

  @override
  String get profileFieldOfficePhone => 'Office phone';

  @override
  String get profileFieldMobile => 'Mobile';

  @override
  String get profileFieldEmail => 'Email';

  @override
  String get profileFieldResidenceAddress => 'Residence address';

  @override
  String get profileFieldHujiAddress => 'Hukou address';

  @override
  String get profileFieldEthnicity => 'Ethnicity';

  @override
  String get profileFieldPoliticalStatus => 'Political status';

  @override
  String get profileFieldMaritalStatus => 'Marital status';

  @override
  String get profileFieldBirthDate => 'Birth date';

  @override
  String get profileFieldGender => 'Gender';

  @override
  String get profileFieldIdType => 'ID type';

  @override
  String get profileFieldIdNumber => 'ID number';

  @override
  String get profileFieldSupervisor => 'Supervisor';

  @override
  String get profileFieldHireDate => 'Hire date';

  @override
  String get profileFieldConfirmedAt => 'Confirmed at';

  @override
  String get profileFieldEmploymentType => 'Employment type';

  @override
  String get profileFieldAttendanceGroup => 'Attendance group';

  @override
  String get profileFieldPaperArchiveNo => 'Paper archive no.';

  @override
  String get profileFieldBaseSalary => 'Base salary';

  @override
  String get profileFieldPerfSalary => 'Performance salary';

  @override
  String get profileFieldSocialInsuranceBase => 'Social insurance base';

  @override
  String get profileFieldSocialInsuranceLocation => 'Social insurance location';

  @override
  String get profileFieldHousingFundBase => 'Housing fund base';

  @override
  String get profileFieldAllowanceStandard => 'Allowance standard';

  @override
  String get profileFieldBankBranch => 'Bank branch';

  @override
  String get profileFieldBankAccount => 'Bank account';

  @override
  String get profileFieldContractType => 'Contract type';

  @override
  String get profileFieldContractStart => 'Contract start';

  @override
  String get profileFieldContractEnd => 'Contract end';

  @override
  String get profileFieldProbationMonths => 'Probation (months)';

  @override
  String get profileFieldRenewCount => 'Renewal count';

  @override
  String get hubDisabledChip => 'Not enabled';

  @override
  String get hubSectionTaskCenter => 'Task center';

  @override
  String get hubDisabledDocNotice =>
      'This document type is not yet enabled (no legacy data)';

  @override
  String get hubSubDetailPerItem => 'Line-by-item details';

  @override
  String get hubSubSummaryPerDoc => 'Per-document totals';

  @override
  String get hubSubPendingReturnQty => 'Pending stock-in returns';

  @override
  String get hubSubReadOnlyPlan => 'Read-only plan';

  @override
  String get salesHubTitle => 'Sales';

  @override
  String get salesHubSectionReports => 'Sales reports';

  @override
  String get salesHubSectionScarcity => 'Stock arbitration';

  @override
  String get salesHubTaskOrderProgress => 'Order progress';

  @override
  String get salesHubTaskOrderProgressSub => 'Ship & completion status';

  @override
  String get salesHubDocQuote => 'Sales quote';

  @override
  String get salesHubDocQuoteSub => 'Pricing & validity';

  @override
  String get salesHubDocOrder => 'Sales order';

  @override
  String get salesHubDocOrderSub => 'Customer orders';

  @override
  String get salesHubDocShipment => 'Sales shipment';

  @override
  String get salesHubDocShipmentSub => 'Ship out, post A/R';

  @override
  String get salesHubDocOtherShipment => 'Other shipment';

  @override
  String get salesHubDocOtherShipmentSub => 'Direct stock-out';

  @override
  String get salesHubDocReturn => 'Sales return';

  @override
  String get salesHubDocReturnSub => 'Return & red-credit';

  @override
  String get salesHubReportDetail => 'Sales detail report';

  @override
  String get salesHubReportSummary => 'Sales summary report';

  @override
  String get salesHubScarcity => 'Scarcity reallocation';

  @override
  String get salesHubScarcitySub => 'Free low-priority stock';

  @override
  String get purchaseHubTitle => 'Purchasing';

  @override
  String get purchaseHubSectionReports => 'Purchase reports';

  @override
  String get purchaseHubTaskCenter => 'Purchasing tasks';

  @override
  String get purchaseHubTaskCenterSub => 'Split orders by supplier';

  @override
  String get purchaseHubReturnVendor => 'Returns to supplier';

  @override
  String get purchaseHubDocRequest => 'Planned purchase request';

  @override
  String get purchaseHubDocOrder => 'Purchase order';

  @override
  String get purchaseHubDocOrderSub => 'Order & track delivery';

  @override
  String get purchaseHubDocReceipt => 'Purchase receipt';

  @override
  String get purchaseHubDocReceiptSub => 'Receive into stock';

  @override
  String get purchaseHubDocReturn => 'Purchase return';

  @override
  String get purchaseHubDocReturnSub => 'Return out of stock';

  @override
  String get purchaseHubReportDetail => 'Purchase detail report';

  @override
  String get purchaseHubReportSummary => 'Purchase summary report';

  @override
  String get purchaseHubReportExpediting => 'Purchase expediting';

  @override
  String get purchaseHubReportExpeditingSub => 'Shortfalls & stock';

  @override
  String get subcontractHubTitle => 'Subcontracting';

  @override
  String get subcontractHubSectionReports => 'Subcontract reports';

  @override
  String get subcontractHubTaskCenter => 'Subcontracting tasks';

  @override
  String get subcontractHubTaskCenterSub => 'Split orders by vendor';

  @override
  String get subcontractHubReturnVendor => 'Returns to vendor';

  @override
  String get subcontractHubReportDetail => 'Subcontract detail report';

  @override
  String get subcontractHubReportSummary => 'Subcontract summary report';

  @override
  String get subcontractHubReportInOut => 'In-out status';

  @override
  String get subcontractHubReportInOutSub => 'Overall in/out status';

  @override
  String get productionHubTitle => 'Production';

  @override
  String get productionHubSectionReports => 'Production reports';

  @override
  String get productionHubSchedule => 'Scheduling & progress';

  @override
  String get productionHubScheduleSub => 'Plan, WIP, completion';

  @override
  String get productionHubPlan => 'New production plan';

  @override
  String get productionHubPlanSub =>
      'Reference a sales order or create manually; history';

  @override
  String get productionHubPlanHistory => 'Production plan history';

  @override
  String get productionHubPlanHistorySub =>
      'View plans, approvals, and batch records';

  @override
  String get productionHubMaterialAnalysis => 'Material readiness analysis';

  @override
  String get productionHubMaterialAnalysisSub =>
      'Readiness, route confirmation, batch planning';

  @override
  String get productionHubDaily => 'Production daily';

  @override
  String get productionHubDailySub => 'Daily output & reversal';

  @override
  String get productionHubReportPlanDetail => 'Plan detail';

  @override
  String get productionHubReportPlanDetailSub => 'Date, item, status';

  @override
  String get productionHubReportPlanSummary => 'Plan summary';

  @override
  String get productionHubReportPlanSummarySub => 'Doc, maker, approver';

  @override
  String get productionHubWhereUsed => 'Where-used';

  @override
  String get productionHubWhereUsedSub => 'Where a material is used';

  @override
  String get financeHubTitle => 'Finance';

  @override
  String get financeHubSectionReports => 'Finance reports';

  @override
  String get financeHubApprovalOwners => 'Approval owners';

  @override
  String get financeHubTaskApproval => 'Order approval tasks';

  @override
  String get financeSalesAllQueueLabel => 'sales order finance confirmations';

  @override
  String get financeSalesInitialQueueLabel =>
      'initial sales order finance approvals';

  @override
  String get financeSalesChangesQueueLabel => 'sales order changes';

  @override
  String financeSalesQueueCountLoading(String queue) {
    return 'Loading pending $queue';
  }

  @override
  String financeSalesQueueCountFailed(String queue) {
    return 'Could not load pending $queue. Open the task page to retry.';
  }

  @override
  String financeSalesQueueCountEmpty(String queue) {
    return 'No pending $queue';
  }

  @override
  String financeSalesQueueCountPending(String queue, int count) {
    return 'Pending $queue: $count';
  }

  @override
  String get financeHubTaskApprovalSub =>
      'Purchase and subcontract order approvals';

  @override
  String get financeHubTaskOverDelivery => 'Over-delivery approval';

  @override
  String get financeHubTaskOverDeliverySub => 'Approve excess arrivals';

  @override
  String get financeHubDocReceipt => 'Sales receipt';

  @override
  String get financeHubDocReceiptSub => 'Settle or direct receipt';

  @override
  String get financeHubDocPayment => 'Purchase payment';

  @override
  String get financeHubDocPaymentSub => 'Settle or direct payment';

  @override
  String get financeHubDocExpense => 'General expense';

  @override
  String get financeHubSubAllocatedByDept => 'Allocated by department';

  @override
  String get financeHubDocIncome => 'Other income';

  @override
  String get financeHubDocBankTransfer => 'Bank transfer';

  @override
  String get financeHubDocBankTransferSub => 'Between accounts';

  @override
  String get financeHubDocCheck => 'Check management';

  @override
  String get financeHubDocCheckSub => 'Check account view';

  @override
  String get financeHubDocAssets => 'Assets & prepaids';

  @override
  String get financeHubDocAssetsSub => 'Sub-ledger, depreciation';

  @override
  String get financeHubReportArAp => 'A/R & A/P';

  @override
  String get financeHubReportArApSub => 'Customer/vendor balance';

  @override
  String get financeHubReportDetail => 'Detail report';

  @override
  String get financeHubReportDetailSub => 'Receipts, payments, costs';

  @override
  String get financeHubReportSummary => 'Summary report';

  @override
  String get financeHubReportSummarySub => 'Receipt & payment totals';

  @override
  String get financeHubReportStatement => 'Account statement';

  @override
  String get financeHubReportStatementSub => 'Customer/vendor account';

  @override
  String get financeHubReportAccountFlow => 'Account ledger';

  @override
  String get financeHubReportAccountFlowSub => 'Account in/out ledger';

  @override
  String get financeHubReportRecon => 'Reconciliation';

  @override
  String get financeHubReportReconSub => 'Monthly reconciliation';

  @override
  String get financeHubReportCost => 'Cost accounting';

  @override
  String get financeHubReportCostSub => 'Product & sales cost';

  @override
  String get financeHubReportGl => 'General ledger';

  @override
  String get financeHubReportGlSub => 'Accounts, assets, P&L';

  @override
  String get warehouseHubTitle => 'Warehouse';

  @override
  String get warehouseHubSectionDocs => 'Stock documents';

  @override
  String get warehouseHubSectionDocsDesc =>
      'Transfer, in/out, picking, finished goods, stocktake';

  @override
  String get warehouseHubSectionInventory => 'Inventory queries';

  @override
  String get warehouseHubSectionInventoryDesc =>
      'Live stock, balances, movements';

  @override
  String get warehouseHubSectionReports => 'Warehouse reports';

  @override
  String get warehouseHubSectionReportsDesc =>
      'Detail (per item) & summary (per doc)';

  @override
  String get warehouseHubTaskExpected => 'Expected arrivals';

  @override
  String get warehouseHubTaskExpectedSub => 'Register actual arrivals';

  @override
  String get warehouseHubTaskException => 'Arrival exceptions';

  @override
  String get warehouseHubTaskExceptionSub => 'Hold over-deliveries';

  @override
  String get warehouseHubTaskPicking => 'Picking tasks';

  @override
  String get warehouseHubTaskPickingSub => 'Prep & track picking';

  @override
  String get warehouseHubDocTransfer => 'Stock transfer';

  @override
  String get warehouseHubDocTransferSub => 'Between warehouses';

  @override
  String get warehouseHubDocOtherIn => 'Other stock-in';

  @override
  String get warehouseHubDocOtherInSub => 'No-source stock-in';

  @override
  String get warehouseHubDocOtherOut => 'Other stock-out';

  @override
  String get warehouseHubDocOtherOutSub => 'No-source stock-out';

  @override
  String get warehouseHubDocDraw => 'Material picking';

  @override
  String get warehouseHubDocDrawSub => 'Picking for production';

  @override
  String get warehouseHubDocWdraw => 'Material return';

  @override
  String get warehouseHubDocWdrawSub => 'Return to stores';

  @override
  String get warehouseHubDocFinishedIn => 'Finished goods in';

  @override
  String get warehouseHubDocFinishedInSub => 'Finished goods inbound';

  @override
  String get warehouseHubDocFinishedOut => 'Finished goods out';

  @override
  String get warehouseHubDocFinishedOutSub => 'Finished goods outbound';

  @override
  String get warehouseHubDocCheck => 'Stocktake';

  @override
  String get warehouseHubDocCheckSub => 'Count & adjustment';

  @override
  String get warehouseHubInventoryLive => 'Live stock';

  @override
  String get warehouseHubInventoryLiveSub => 'Real-time on-hand';

  @override
  String get warehouseHubInventoryBalance => 'Stock balance';

  @override
  String get warehouseHubInventoryBalanceSub => 'Balances by item';

  @override
  String get warehouseHubInventoryMovement => 'Stock movements';

  @override
  String get warehouseHubInventoryMovementSub => 'In/out movement log';

  @override
  String get warehouseHubReportDetail => 'Warehouse detail report';

  @override
  String get warehouseHubReportSummary => 'Warehouse summary report';

  @override
  String get basicDataHubTitle => 'Master data';

  @override
  String get basicDataHubGoods => 'Items';

  @override
  String get basicDataHubGoodsSub => 'Item categories & master';

  @override
  String get basicDataHubMould => 'Molds';

  @override
  String get basicDataHubMouldSub => 'Mold series & master';

  @override
  String get basicDataHubClient => 'Customers';

  @override
  String get basicDataHubClientSub => 'Customer groups & master';

  @override
  String get basicDataHubSupplier => 'Suppliers';

  @override
  String get basicDataHubSupplierSub => 'Supplier groups & master';

  @override
  String get basicDataHubColor => 'Colors';

  @override
  String get basicDataHubColorSub => 'Color master';

  @override
  String get basicDataHubUnit => 'Units';

  @override
  String get basicDataHubUnitSub => 'Unit of measure master';

  @override
  String get basicDataHubCurrency => 'Currencies';

  @override
  String get basicDataHubCurrencySub => 'Currency & FX rates';

  @override
  String get basicDataHubWarehouse => 'Warehouses';

  @override
  String get basicDataHubWarehouseSub => 'Warehouse master';

  @override
  String get basicDataHubAccount => 'Accounts';

  @override
  String get basicDataHubAccountSub => 'Account & balances';

  @override
  String get basicDataHubPaymentStyle => 'Payment categories';

  @override
  String get basicDataHubPaymentStyleSub => 'Six accounting classes';

  @override
  String get basicDataHubSettlementMethod => 'Settlement methods';

  @override
  String get basicDataHubSettlementMethodSub =>
      'Terms dictionary and payment-term rules';

  @override
  String get impersonationSwitchPerson => 'Switch person';

  @override
  String get impersonationEnterPasswordTitle => 'Confirm switch person';

  @override
  String get impersonationEnterPasswordHint =>
      'For security, enter your login password. After that you can switch freely for 15 minutes without re-entering.';

  @override
  String get impersonationPasswordLabel => 'Login password';

  @override
  String get impersonationConfirm => 'Confirm';

  @override
  String get impersonationTargetPickerTitle => 'Select an employee to view';

  @override
  String get impersonationSearchHint => 'Search name / employee code';

  @override
  String impersonationBannerTitle(String name) {
    return 'Viewing as $name (read-only)';
  }

  @override
  String get impersonationBannerSwitch => 'Switch';

  @override
  String get impersonationBannerExit => 'Exit';

  @override
  String impersonationRemainingMinutes(int count) {
    return '$count min left';
  }

  @override
  String get impersonationWrongPassword => 'Wrong password';

  @override
  String get impersonationExited => 'Exited impersonation';

  @override
  String get impersonationWindowExpired => 'Impersonation window expired';

  @override
  String get impersonationRecent => 'Recent';

  @override
  String get impersonationNoTargets => 'No employees available to switch';

  @override
  String get impersonationStartFailed => 'Switch failed';

  @override
  String get exportDialogTitle => 'Export Excel';

  @override
  String get exportPasswordOptionalHint =>
      'A password is optional. Leave it blank for a regular Excel file, or enter 1–128 characters to encrypt it.';

  @override
  String get exportPasswordOptionalLabel =>
      'Opening password (optional, 1–128)';

  @override
  String get exportPasswordConfirmLabel => 'Confirm password';

  @override
  String get exportPasswordTooLong => 'Password cannot exceed 128 characters';

  @override
  String get exportPasswordMismatch => 'Passwords do not match';

  @override
  String get exportDownloadPlain => 'Download';

  @override
  String get exportDownloadEncrypted => 'Download encrypted';

  @override
  String get exportFailed => 'Export failed. Try again later.';

  @override
  String exportDownloadStarted(String name) {
    return 'Download started: $name';
  }

  @override
  String exportDownloadSaved(String path) {
    return 'Saved to $path';
  }

  @override
  String get profileLoadingMessage => 'Loading employee record…';

  @override
  String get profileLoadFailed => 'Employee record failed to load';

  @override
  String get profileUnboundTitle =>
      'This account is not linked to an employee record';

  @override
  String get profileUnboundDescription =>
      'Contact an administrator or HR to link this account to an employee record.';

  @override
  String get profileSessionUnavailable =>
      'You are not signed in or the session is unavailable';

  @override
  String get profileValueNotProvided => 'Not provided';

  @override
  String get profileValueNotRegistered => 'Not registered';

  @override
  String get profileAlternatePhoneLabel => 'Alternate phone';

  @override
  String get profileContractSummaryTitle => 'Contract summary';

  @override
  String get profileTabOrgContract => 'Org & contract';

  @override
  String get profileTabContactVehicle => 'Contact & vehicles';

  @override
  String get profileTabMyDocuments => 'My documents';

  @override
  String get profileEmploymentHistoryTitle => 'Employment history';

  @override
  String get profileScopeNoticeTitle => 'Information scope';

  @override
  String get profileCompensationBoundaryDescription =>
      'Salary and bank information are intentionally not shown on My Profile. Check monthly income in Payslips, or contact authorized HR for other questions.';

  @override
  String get profileMissingEmergencyContact =>
      'No emergency contact is registered. Ask HR to register one before requesting changes here.';

  @override
  String profileAlternatePhoneCount(int count) {
    return '$count alternate phone(s) registered';
  }

  @override
  String get profileVehiclesPhonesEmptyHint =>
      'Register vehicles and alternate phones for quick plate lookup';

  @override
  String get historyEventConfirm => 'Confirmation';

  @override
  String get accountProvisionPermissionDenied =>
      'You do not have permission to provision accounts. Contact account support.';

  @override
  String get accountProvisionAlreadyExists =>
      'This employee already has an account or the account is inactive; it cannot be provisioned again.';

  @override
  String get accountProvisionConfirmTitle => 'Confirm account provisioning';

  @override
  String get accountProvisionFailed =>
      'Account provisioning failed. Try again later.';

  @override
  String get accountProvisionInProgress => 'Provisioning';

  @override
  String get accountStatusNotProvisioned => 'Not provisioned';

  @override
  String get accountStatusInactive => 'Account inactive';

  @override
  String get pagePermissionAccountNotProvisionedTitle =>
      'This person does not have an account, so permissions cannot be configured yet';

  @override
  String get pagePermissionAccountNotProvisionedCanProvision =>
      'Provision the account first. After the one-time credentials are saved, this person\'s permissions will load automatically.';

  @override
  String get pagePermissionAccountNotProvisionedNoAccess =>
      'Contact someone with Account Support permission to provision the login account.';

  @override
  String get employeePermissionSettingsTooltip =>
      'Configure employee permissions';

  @override
  String get employeeAccountNotProvisionedTooltip =>
      'Employee account not provisioned';

  @override
  String get employeeResignedCannotProvision =>
      'A resigned employee cannot be given a login account';

  @override
  String get employeeAccountNotProvisionedContactSupport =>
      'This employee does not have an account. Contact account support.';

  @override
  String get materialMainWarehouse => 'Main warehouse';

  @override
  String get materialIssueWarehouseSettings => 'Issue warehouse settings';

  @override
  String get materialWarehouseScopeExplanation =>
      'The main warehouse includes its subwarehouses. Kit readiness, reservations and issues use the selected physical warehouse. Stock elsewhere is a transfer reference until received here.';

  @override
  String get materialSearchHint => 'Search products or materials';

  @override
  String get materialByProduct => 'By product';

  @override
  String get materialByMaterial => 'By material';

  @override
  String get materialIdentityByMaterial => 'Material / source';

  @override
  String get materialIdentityByProduct => 'Product / BOM hierarchy';

  @override
  String get materialRoute => 'Supply method';

  @override
  String get materialRequired => 'Qty needed';

  @override
  String get materialAllocated => 'Prepared quantity';

  @override
  String get materialPreparedQuantityHint =>
      'Qualified material allocated to this batch, including its formal reservations and material already issued. Qualified receipts are included once; pending inspection and future supply are excluded. This is batch coverage, not the current warehouse balance.';

  @override
  String get materialShortage => 'Still short';

  @override
  String get materialPhysicalShortageHint =>
      'Batch demand still lacking qualified material. Issuing purchase, subcontract or workshop work does not reduce this shortage; qualified stock-in allocated to this batch does. Additional supply separately deducts incoming supply to prevent duplicate requests.';

  @override
  String get materialSupplyProgressHint =>
      'Track ordering, finance approval, arrival, inspection and stock-in. Double-click for details. Physical shortage remains after issue and updates after qualified stock-in.';

  @override
  String get materialToSupply => 'Suggested order';

  @override
  String get materialFutureSupply => 'In transit';

  @override
  String get materialProgress => 'Progress / next step';

  @override
  String get materialMixedRoutes => 'Mixed routes';

  @override
  String materialAggregateSources(int products, int paths) {
    return '$products products · $paths paths';
  }

  @override
  String materialCreateRoutes(int count) {
    return 'Confirm routes ($count)';
  }

  @override
  String get materialRouteReasonTitle => 'Route reason (optional)';

  @override
  String get materialRouteChangedRetry =>
      'Analysis updated. Review the selected routes and try again.';

  @override
  String get materialWarehouseFacts => 'Warehouse and supply details';

  @override
  String get materialExactStock => 'Qualified stock pegged here';

  @override
  String get materialPublicStock => 'Public stock';

  @override
  String get materialScopeStock => 'Scope availability (reference)';

  @override
  String get materialTransferStock => 'Transferable from other warehouses';

  @override
  String get materialClaimedSupply => 'Claimed for this task';

  @override
  String get materialTaskBuy => 'Issue purchasing';

  @override
  String get materialTaskSubcontract => 'Issue subcontracting';

  @override
  String get materialTaskWorkshop => 'Issue to workshop';

  @override
  String get materialTaskIssued => 'Issued';

  @override
  String get materialTaskBlocked => 'Needs attention';

  @override
  String get materialTaskEmpty => 'No tasks match this filter';

  @override
  String get materialTaskBuyHint =>
      'Issue remaining purchasing demand and track orders, receipts and inspections.';

  @override
  String get materialTaskSubcontractHint =>
      'Issue remaining subcontracting demand; components first create workshop preparation tasks.';

  @override
  String get materialTaskWorkshopHint =>
      'Set quantity, workshop and owner before issuing. Material-short tasks wait until materials are ready and issued.';

  @override
  String get materialTaskSectionHint =>
      'Manage preparation by route and review pending, issued and blocked tasks.';

  @override
  String get materialWarehouseLimit =>
      'An analysis supports at most 100 physical warehouses. Adjust the warehouse scope before analyzing.';

  @override
  String materialRoutesNext(int count) {
    return 'Next: review $count routes, select them and confirm. Each row keeps its selected route.';
  }

  @override
  String get materialIssueNext =>
      'Next: open purchasing, subcontracting or workshop tasks to issue remaining demand and track issued work.';

  @override
  String materialWorkshopNext(int count) {
    return 'Next: $count products can be issued to workshops. Set quantity, workshop and owner; material-short batches wait for complete kits and material issues.';
  }

  @override
  String materialPreparedChildCreated(int count) {
    return 'Created $count preparation tasks; they have not been issued to a workshop yet.';
  }

  @override
  String get materialPreparedChildNext =>
      'Check quantity, workshop and owner in the selected rows, then generate the production plan. Approval is required before release.';

  @override
  String get materialPreparedChildNeedPlanner =>
      'A planner with production-plan generation permission must set quantity, workshop and owner and submit the plan.';

  @override
  String get materialRouteMemoryLoading =>
      'Loading previous routes. Confirm after they are ready.';

  @override
  String get materialRouteMemoryUnavailable =>
      'Previous routes could not be loaded. Review the displayed routes before confirming.';

  @override
  String get materialRootSupply => 'Top-level supply task';

  @override
  String get materialRootRoutePending => 'Route pending';

  @override
  String get materialRootExternalRoute =>
      'Issue this top-level product from its purchasing or subcontracting entry';

  @override
  String materialRootExistingStock(String quantity) {
    return 'Allocated stock of $quantity will be handed over first. Enter only additional supply below.';
  }

  @override
  String get materialRootSupplyCompleted => 'Supply demand fulfilled';

  @override
  String get materialRootOutputHistory => 'Top-level supply handovers';

  @override
  String get materialRootStockAllocation => 'Existing stock allocation';

  @override
  String get materialRootReceivedSupply => 'Qualified receipt handover';

  @override
  String get materialRootOutputReversed => 'Handover reversed';

  @override
  String get materialSupplyTasksAndReversals => 'Supply tasks and reversals';

  @override
  String get materialNotificationReversalReconcile => 'Reconcile reversal';

  @override
  String get materialRevokeRootStock => 'Reverse stock allocation';

  @override
  String get materialRootRevokeFailed =>
      'Stock allocation could not be reversed. Refresh and review it.';

  @override
  String get materialRootSupplyProcessed =>
      'Supply processed. Review the stock handovers and additional demand records.';

  @override
  String get orderChangeQtyButton => 'Change Qty';

  @override
  String get orderChangeQtyTitle => 'Order Qty Change';

  @override
  String get orderChangeQtyWarning =>
      'Changes after approval take effect immediately and automatically re-enter finance review; finance will see the change list (before → after). Rejection does not restore quantities.';

  @override
  String orderChangeQtyCurrent(String qty) {
    return 'Now $qty';
  }

  @override
  String get orderChangeQtyNewQty => 'New qty';

  @override
  String get orderChangeQtyConfirm => 'Confirm Change';

  @override
  String get orderChangeQtyInvalid =>
      'Some quantities are invalid (must be greater than 0). Please check.';

  @override
  String get orderChangeQtySuccess =>
      'Quantities changed; the order has re-entered finance review';

  @override
  String get orderChangeQtyFailed =>
      'Failed to change quantities. Please try again later.';

  @override
  String orderQtyChangeOld(String value) {
    return 'Before $value';
  }

  @override
  String orderQtyChangeNew(String value) {
    return 'After $value';
  }

  @override
  String get procurementApprovalStatusPending => 'Awaiting finance review';

  @override
  String procurementApprovalStatusChanged(int count) {
    return 'Re-review after change · $count qty changes';
  }

  @override
  String procurementApprovalQtyChangesTitle(int count) {
    return 'Change list · $count qty changes';
  }

  @override
  String get procurementApprovalQtyChangesHint =>
      'Quantities were changed after finance approval and the order has automatically re-entered review; please verify each line (before → after) before reviewing.';

  @override
  String get productionMaterialRecheck => 'Recheck materials';

  @override
  String get productionMaterialRecheckReady =>
      'Materials are ready. Draw orders were created for the actual warehouses. Start after all materials have been issued.';

  @override
  String get productionMaterialRecheckWaiting =>
      'Materials are still short. Check completed stock receipts and reservations for other tasks.';

  @override
  String get fieldAutofilledReview =>
      'Filled from a previous record or default. Please review before use.';

  @override
  String get workflowQuantityHint =>
      'Enter this quantity in the row unit. Do not mix boxes, pieces or kilograms; a linked source must have enough available quantity.';

  @override
  String get workflowOrderQuantityHint =>
      'Enter the ordered quantity in the row unit. Editing is locked during finance review; changes after approval require a new review.';

  @override
  String get workflowReturnQuantityHint =>
      'Use the original shipment line unit for the actual returned quantity. Do not exceed the remaining returnable quantity. Approved returns await inspection before becoming saleable stock.';

  @override
  String get workflowPriceHint =>
      'Enter the price per row unit in its currency. The line amount follows quantity; do not enter the line total as a unit price.';

  @override
  String get workflowReturnPriceHint =>
      'Return credit is calculated at approval from the original shipment and prior returns. A reference price cannot increase the refundable amount.';

  @override
  String get workflowDiscountHint =>
      'Use a decimal multiplier: 1 is full price and 0.9 means 10% off. Do not enter 9 or 90.';

  @override
  String get workflowExchangeRateHint =>
      'Enter the base-currency value of one unit of the original currency, with up to 6 decimals. Check any prefilled rate for this transaction.';

  @override
  String get workflowTaxRateHint =>
      'Enter a percentage: 13 means 13%. Do not enter 0.13.';

  @override
  String get workflowCurrencyHint =>
      'The currency defines this line’s prices and amounts. Check the source document before changing it.';

  @override
  String get workflowSettlementHint =>
      'Select the agreed supplier settlement terms. Different suppliers, currencies or terms may produce separate orders.';

  @override
  String get workflowPlanningQuantityHint =>
      'This is the quantity to arrange now, not the received quantity. Incoming supply is not stock, and issuing a task does not make it ready to start.';

  @override
  String get workflowWorkshopQuantityHint =>
      'Enter the quantity assigned to the workshop now. Dispatch can happen first; starting and material issue still require the necessary materials and state.';

  @override
  String get workflowReportQuantityHint =>
      'Enter the output completed this time in the plan-line unit, not cumulative output. Approved reporting still requires warehouse registration, quality inspection and stock-in.';

  @override
  String get workflowArrivalQuantityHint =>
      'Enter the actual quantity received now in the row unit, including shortages or excess. Quantity above approval enters exception handling rather than available stock.';

  @override
  String get workflowIqcPassHint =>
      'Enter only the quantity passed this time. Passed plus failed quantity must not exceed the uninspected balance; warehouse confirmation is still needed for stock-in.';

  @override
  String get workflowIqcFailHint =>
      'Enter only the quantity failed this time. It does not become available stock and still needs return, rework or another disposition.';

  @override
  String get workflowPrepaymentAmountHint =>
      'Enter the advance payment actually received in the order currency. Receipt is recorded once; later applying it to receivables does not record another cash receipt.';

  @override
  String get workflowReceiptAllocationHint =>
      'Allocate this receipt to the receivable in its original currency, up to its collectible balance. Do not allocate the same received money twice.';

  @override
  String get workflowBankFeeHint =>
      'Enter the actual bank fee. A fee deducted from the receipt must not also be recorded as a separate payment.';

  @override
  String get workflowOtherFeeHint =>
      'Enter only other fees for this receipt and select their expense category. Do not record a fee twice.';

  @override
  String get workflowReturnReasonHint =>
      'Describe the return reason and original shipment. Approval creates a credit awaiting disposition and quarantines the goods; refund or replacement decisions are separate.';

  @override
  String get workflowPrepaymentOrderHint =>
      'Select the sales order for this advance payment. Its customer and currency are inherited; change the order if the source is wrong.';

  @override
  String get workflowPrepaymentApplyHint =>
      'Explain which advance payment covers which receivables and why. Applying it adjusts balances without recording another cash receipt.';

  @override
  String get workflowFinanceReviewHint =>
      'Record your review. Compare before and after values for changed orders. Finance approval does not mean payment, shipment or production has occurred.';

  @override
  String get workflowFinanceRejectHint =>
      'State what is wrong and what must change. Sales receives this reason and can resubmit after correction.';

  @override
  String get workflowOptionalDetails => 'Additional details (optional)';

  @override
  String get workflowReceiptEvidence => 'Rate and receipt evidence';

  @override
  String get workflowReceiptNoFees => 'No fees: no fee details are needed';

  @override
  String get workflowUnitUnknown => 'Inspection unit needs review';

  @override
  String workflowIqcUnitHint(String sourceUnit, String rate, String baseUnit) {
    return 'One $sourceUnit on the source equals $rate $baseUnit. Inspect in $baseUnit, not the original package count.';
  }

  @override
  String get moneySummaryCustomerPaid => 'Customer paid';

  @override
  String get moneySummaryGrossShipped => 'Gross shipped amount';

  @override
  String get moneySummaryReturned => 'Returned amount';

  @override
  String get moneySummaryUnusedReturns => 'Unapplied return balance';

  @override
  String get moneySummaryNetReceivable => 'Current amount to collect';

  @override
  String get moneySummaryPendingBalance => 'Customer balance to resolve';

  @override
  String get moneySummaryFutureShipment => 'Future shipment amount';

  @override
  String get moneySummaryExpectedNewCash => 'Estimated new payment needed';

  @override
  String get moneySummaryBalanceHint =>
      'Finance must confirm how this balance is applied or refunded. It does not mean a refund has been paid.';

  @override
  String get moneySummaryCollectionHint =>
      'Estimated from current receivables, future shipments and unused advances. No credit or refund is applied automatically.';

  @override
  String get moneySummarySourceHint =>
      'Amounts come from approved documents. Customer payments may include deducted fees; bank cash received is shown in account transactions.';

  @override
  String get moneySummaryUnallocatedHint =>
      'Some payments have not been matched to this order. Finance needs to reconcile them.';

  @override
  String get warehouseArrivalSourceLabel => 'Arrival source';

  @override
  String get warehouseArrivalSourceAutomatic => 'Automatic';

  @override
  String get warehouseArrivalSourceNormal => 'Normal arrival';

  @override
  String get warehouseArrivalSourceReplacement => 'Replace returns first';

  @override
  String get warehouseArrivalSourceHint =>
      'The system identifies the source when only one is available. If both normal arrivals and returned goods are outstanding, select the source of this batch. Replace returns first fills the returned quantity first; any remainder is a normal arrival. Whether replacement is free or billed follows the original return resolution.';

  @override
  String get subcontractPreparationWarehouse => 'Internal production warehouse';

  @override
  String get subcontractPreparationWarehouseHint =>
      'For a direct subcontract order with components and insufficient stock, select the warehouse for internal production receipts. Planning receives the shortage; finance submission becomes available after actual receipt. Optional when there are no components or stock is sufficient.';

  @override
  String get subcontractInternalProduction => 'Internal production';

  @override
  String get subcontractPreparedQuantity => 'Prepared';

  @override
  String get subcontractPreparationShortage => 'Still to produce';

  @override
  String get subcontractOpenPreparation => 'View production plan';

  @override
  String get subcontractDraftPreparationHint =>
      'Planning arranges internal production first. Submit to finance after the goods are received into stock.';

  @override
  String get subcontractWaitingPlan => 'Waiting for planning';

  @override
  String get subcontractReadyForFinance => 'Ready for finance submission';
}
