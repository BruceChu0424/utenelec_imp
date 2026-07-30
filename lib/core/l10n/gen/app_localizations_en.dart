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
  String get employeeSearchHint => 'Search by code or name';

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
      'Submitting creates a login account (employee code as username) and a high-entropy one-time password. It must be changed at first sign-in.';

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
  String get employeeOnboardHintCode => 'e.g. E1001';

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
  String get employeeOffboardStepStart => 'Start';

  @override
  String get employeeOffboardStepHandover => 'Handover';

  @override
  String get employeeOffboardStepCheck => 'Recovery confirmation';

  @override
  String get employeeOffboardFieldType => 'Resign type';

  @override
  String get employeeOffboardFieldDate => 'Last day';

  @override
  String get employeeOffboardPickDate => 'Pick a date';

  @override
  String get employeeOffboardFieldReason => 'Reason';

  @override
  String get employeeOffboardFieldHandover =>
      'Handover notes (docs/projects/access)';

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
}
