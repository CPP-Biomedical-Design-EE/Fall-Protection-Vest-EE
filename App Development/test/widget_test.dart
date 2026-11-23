import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fall_protection_vest_app/account_auth.dart';
import 'package:fall_protection_vest_app/account_page.dart';
import 'package:fall_protection_vest_app/app_colors.dart';
import 'package:fall_protection_vest_app/help_and_safety.dart';
import 'package:fall_protection_vest_app/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('decodes ESP32 Bluetooth status flags and rejects malformed data', () {
    final parser = Esp32BleStatusParser();
    final reading = parser.parse(Uint8List.fromList([0x07]));

    expect(reading.connected, isTrue);
    expect(reading.fallCandidate, isTrue);
    expect(reading.battery, isNull);
    expect(reading.sampleRateHz, 100);
    expect(reading.sensor['detector_calibrated'], isTrue);
    expect(
      () => parser.parse(Uint8List.fromList([0x08])),
      throwsFormatException,
    );
    expect(
      () => parser.parse(Uint8List.fromList([0x01, 0x02])),
      throwsFormatException,
    );
  });

  testWidgets('shows the vest home screen without simulated connection data', (
    tester,
  ) async {
    await tester.pumpWidget(const VestApp());
    final theme = Theme.of(tester.element(find.byType(Scaffold).first));
    expect(theme.brightness, Brightness.light);
    expect(theme.scaffoldBackgroundColor, AppColors.canvas);
    expect(find.text('Your safety, at a glance'), findsOneWidget);
    expect(
      find.text(
        'Review the vest status available on this device. Remote sharing is not set up.',
      ),
      findsNothing,
    );
    expect(find.text('Waiting for your vest'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);
    expect(find.text('Reset vest'), findsNothing);
    expect(find.text('Vest inflated — reset needed'), findsNothing);
    await tester.drag(find.byType(ListView), const Offset(0, -450));
    await tester.pumpAndSettle();
    expect(find.text('No fall candidate is currently reported.'), findsNothing);
    await tester.drag(find.byType(ListView), const Offset(0, -450));
    await tester.pumpAndSettle();
    expect(find.text('Not reported'), findsOneWidget);
  });

  testWidgets('opens the animated safety guide from Settings', (tester) async {
    await tester.pumpWidget(const VestApp());
    final helpPage = find.byType(HelpAndSafetyPage);
    final helpScrollable = find.descendant(
      of: helpPage,
      matching: find.byType(Scrollable),
    );
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();

    expect(find.text('Personalize your companion app.'), findsOneWidget);
    expect(find.text('Guest profile'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Help & safety'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Help & safety'));
    await tester.pumpAndSettle();

    expect(find.text('20-SECOND WALKTHROUGH'), findsOneWidget);
    expect(find.text('Connect your vest'), findsOneWidget);
    await tester.tap(find.byTooltip('Pause walkthrough'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Play walkthrough'), findsOneWidget);
    await tester.tap(find.byTooltip('Play walkthrough'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Read the live status'), findsOneWidget);
    await tester.tap(find.byTooltip('Pause walkthrough'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Alerts are experimental'),
      350,
      scrollable: helpScrollable,
    );
    expect(find.text('Alerts are experimental'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('No vest hardware controls'),
      350,
      scrollable: helpScrollable,
    );
    expect(find.text('No vest hardware controls'), findsOneWidget);
    expect(find.text('Feedback shaping future design'), findsNothing);
  });

  testWidgets('clarifies that the app does not contact family', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: HelpAndSafetyPage()));
    await tester.scrollUntilVisible(
      find.text('No calls or family notifications are sent'),
      300,
      scrollable: find.byType(Scrollable),
    );
    expect(
      find.text('No calls or family notifications are sent'),
      findsOneWidget,
    );
  });

  testWidgets('saves and shows the local connection name', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const VestApp());
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set connection name'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Family Caregiver');
    await tester.tap(find.text('Save name'));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('connection_display_name'), 'Family Caregiver');
    expect(find.text('Family Caregiver'), findsOneWidget);
    await tester.tap(find.byType(VestIcon).last);
    await tester.pumpAndSettle();
    expect(find.text('Verified account required'), findsOneWidget);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
  });

  testWidgets('uses one app experience without an app-mode selector', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'app_role': 'caregiver'});
    await tester.pumpWidget(const VestApp());
    await tester.pumpAndSettle();
    expect(find.text('Your safety, at a glance'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(find.text('App mode'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('Text size'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('High contrast'), findsNothing);
    expect(find.text('Language'), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('app_role'), isNull);
  });

  testWidgets('notification bell opens notification options', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const VestApp());
    await tester.tap(
      find.byKey(const ValueKey('notification-settings-button')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Notifications'), findsOneWidget);
    expect(find.text('System notifications'), findsOneWidget);
    expect(
      tester
          .widget<SwitchListTile>(
            find.ancestor(
              of: find.text('System notifications'),
              matching: find.byType(SwitchListTile),
            ),
          )
          .value,
      isFalse,
    );
  });

  testWidgets('notifications setting can be turned off', (tester) async {
    SharedPreferences.setMockInitialValues({'notifications_enabled': true});
    await tester.pumpWidget(const VestApp());
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('System notifications'),
      300,
      scrollable: find.byType(Scrollable).last,
    );

    final notificationSwitch = find.ancestor(
      of: find.text('System notifications'),
      matching: find.byType(SwitchListTile),
    );
    expect(tester.widget<SwitchListTile>(notificationSwitch).value, isTrue);
    await tester.tap(notificationSwitch);
    await tester.pumpAndSettle();

    expect(tester.widget<SwitchListTile>(notificationSwitch).value, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('notifications_enabled'), isFalse);
  });

  testWidgets('switches between Wi-Fi gateway and direct Bluetooth modes', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final auth = _MemoryAccountAuthService(
      const AccountUser(
        uid: 'verified-test-user',
        email: 'caregiver@example.test',
        displayName: 'Caregiver',
        emailVerified: true,
        isAnonymous: false,
      ),
    );
    await tester.pumpWidget(VestApp(authService: auth));
    await tester.tap(find.byType(VestIcon).last);
    await tester.pumpAndSettle();
    expect(find.text('Gateway connection'), findsOneWidget);

    await tester.tap(find.text('Bluetooth'));
    await tester.pumpAndSettle();
    expect(find.text('ESP32 Bluetooth connection'), findsOneWidget);
    expect(find.text('Scan for vest'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('vest_connection_mode'), 'bluetooth');

    await tester.tap(find.text('Wi-Fi'));
    await tester.pumpAndSettle();
    expect(find.text('Gateway connection'), findsOneWidget);
    expect(prefs.getString('vest_connection_mode'), 'wifi');
    await tester.pumpWidget(const SizedBox.shrink());
    await auth.dispose();
  });

  testWidgets('sign-up validates fields and requires email verification', (
    tester,
  ) async {
    final auth = _MemoryAccountAuthService();
    await tester.pumpWidget(
      MaterialApp(home: AccountPage(auth: auth, initialUser: null)),
    );

    expect(find.text('Who are you using the app as?'), findsNothing);
    expect(find.text('New here? Create an account'), findsOneWidget);
    await tester.tap(find.text('New here? Create an account'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Caregiver');
    await tester.enterText(fields.at(1), 'caregiver@example.test');
    await tester.enterText(fields.at(2), 'securepass123');
    await tester.enterText(fields.at(3), 'different');
    await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
    await tester.pumpAndSettle();
    expect(find.text('Passwords do not match.'), findsOneWidget);
    expect(auth.verificationEmailCount, 0);

    await tester.enterText(fields.at(3), 'securepass123');
    await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
    await tester.pumpAndSettle();
    expect(find.text('Verify your email'), findsOneWidget);
    expect(
      find.text(
        'Account created. Check your inbox and verify your email before using caregiver features.',
      ),
      findsOneWidget,
    );
    expect(auth.currentUser?.emailVerified, isFalse);
    expect(auth.verificationEmailCount, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await auth.dispose();
  });

  testWidgets('guest mode cannot open caregiver-only history', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const VestApp());

    await tester.tap(find.text('History').last);
    await tester.pumpAndSettle();

    expect(find.text('Verified account required'), findsOneWidget);
    expect(find.text('Event History'), findsNothing);
  });

  testWidgets('find vest never routes to a sample location', (tester) async {
    SharedPreferences.setMockInitialValues({'location_enabled': false});
    await tester.pumpWidget(const VestApp());
    await tester.tap(find.text('Find vest'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Vest GPS is unavailable. Connect a GPS-enabled gateway before requesting directions.',
      ),
      findsOneWidget,
    );
    expect(find.text('No live vest coordinates received'), findsOneWidget);
    expect(find.text('Get directions'), findsNothing);
  });

  testWidgets('fall candidate opens the map with demo direction preview', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'location_enabled': false,
      'last_phone_latitude': 37.7749,
      'last_phone_longitude': -122.4194,
    });
    await tester.pumpWidget(const VestApp());
    await tester.scrollUntilVisible(
      find.text('Test alert'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Test alert'));
    await tester.pumpAndSettle();
    expect(find.text('FALL CANDIDATE'), findsNWidgets(2));
    final alertIcon = find.descendant(
      of: find.byType(Dialog),
      matching: find.byType(FallSlipIcon),
    );
    expect(tester.getSize(alertIcon), const Size.square(72));
    await tester.tap(find.text('Open map'));
    await tester.pumpAndSettle();

    expect(find.text('VEST DEMO'), findsOneWidget);
    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    expect(map.options.initialCenter.latitude, closeTo(37.7749, 0.00001));
    expect(map.options.initialCenter.longitude, closeTo(-122.4194, 0.00001));
    expect(find.text('Get directions'), findsNothing);
    await tester.tap(find.text('Preview directions'));
    await tester.pumpAndSettle();
    expect(find.text('Preview directions'), findsWidgets);
    expect(find.text('Preview Apple Maps'), findsOneWidget);
    expect(find.text('Preview Google Maps'), findsOneWidget);
  });

  testWidgets('clears legacy care-planning settings', (tester) async {
    SharedPreferences.setMockInitialValues({
      'care_alert_recipient': 'family_first',
      'care_emergency_response': 'caregiver_decides',
      'care_battery_threshold': '25',
    });
    await tester.pumpWidget(const VestApp());
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Care preferences'), findsNothing);
    expect(find.text('Alert recipients'), findsNothing);
    expect(find.text('Planning only.'), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().where((key) => key.startsWith('care_')), isEmpty);
  });

  testWidgets('saves hospital-informed preferences locally', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const VestApp());
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Hospital-informed preferences'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Hospital-informed preferences'));
    await tester.pumpAndSettle();

    expect(find.textContaining('This app never calls 911.'), findsOneWidget);
    final recipients = find.byKey(const ValueKey('hospital_alert_recipients'));
    await tester.tap(recipients);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Caregiver, then family').last);
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('hospital_alert_recipients'),
      'caregiver_then_family',
    );
    await tester.scrollUntilVisible(
      find.text('Detector research note'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Detector research note'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('does not test live or pre-impact detection'),
      findsOneWidget,
    );
  });

  testWidgets('shows backend-dependent Settings features as unavailable', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const VestApp());
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -700));
    await tester.pumpAndSettle();
    expect(find.text('Notifications'), findsOneWidget);
    expect(find.text('System notifications'), findsOneWidget);
    expect(
      find.text('Saved on this device only; no calls or messages are sent.'),
      findsOneWidget,
    );
    expect(find.text('Family and caregiver sharing'), findsNothing);
  });

  testWidgets('simplified Settings removes duplicate alert and sharing rows', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const VestApp());
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(find.text('In-app fall alerts'), findsNothing);
    expect(find.text('Family and caregiver sharing'), findsNothing);
  });

  testWidgets('text size setting applies app-wide and persists', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const VestApp());
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byType(Slider),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    tester.widget<Slider>(find.byType(Slider)).onChanged!(1.2);
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('app_text_scale'), 1.2);
    expect(appTextScale.value, 1.2);
    final settingsElement = tester.element(find.text('Settings'));
    expect(
      MediaQuery.textScalerOf(settingsElement).scale(16),
      closeTo(19.2, 0.01),
    );
  });

  testWidgets('clears saved event history only after confirmation', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'vest_events': [
        '{"fall_candidate":true,"battery":null,"connected":true,'
            '"timestamp":"2025-01-02T03:04:05.000"}',
      ],
    });
    await tester.pumpWidget(const VestApp());
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Clear event history'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.ensureVisible(find.text('Clear event history'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Clear event history'));
    await tester.pumpAndSettle();
    expect(find.text('Clear event history?'), findsOneWidget);
    await tester.tap(find.text('Clear history'));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('vest_events'), isNull);
  });

  test('parses the ESP32 JSON message', () {
    final reading = Esp32MessageParser().parse(
      '{"fall_detected":true,"battery":76,"connected":true}',
    );

    expect(reading.fallCandidate, isTrue);
    expect(reading.battery, 76);
    expect(reading.connected, isTrue);
  });

  test('parses live gateway sensor status with unavailable battery', () {
    final reading = Esp32MessageParser().parse(
      '{"fall_candidate":false,"battery":null,"connected":true,'
      '"sample_rate_hz":100.0,"acceleration_g":1.0,'
      '"sensor":{"ax":0.1,"ay":0.2,"az":9.8}}',
    );

    expect(reading.fallCandidate, isFalse);
    expect(reading.battery, isNull);
    expect(reading.sampleRateHz, 100.0);
    expect(reading.sensor['ax'], 0.1);
  });

  test('parses live connected-device count from gateway status', () {
    final status = VestGatewayStatus.fromJson(
      '{"fall_candidate":false,"battery":null,"connected":true,'
      '"connected_devices":3}',
    );

    expect(status.reading.connected, isTrue);
    expect(status.connectedDevices, 3);
  });

  test('normalizes gateway addresses and rejects non-local HTTP schemes', () {
    expect(
      VestGatewayClient.statusUri('192.168.1.25').toString(),
      'http://192.168.1.25:8765/api/status',
    );
    expect(VestGatewayClient.statusUri('http://192.168.1.25:9000').port, 9000);
    expect(
      () => VestGatewayClient.statusUri('https://gateway.example'),
      throwsFormatException,
    );
  });

  test('rejects an invalid battery value', () {
    expect(
      () => Esp32MessageParser().parse(
        '{"fall_detected":false,"battery":140,"connected":true}',
      ),
      throwsFormatException,
    );
  });

  test(
    'loads legacy saved fall events with their original data types',
    () async {
      SharedPreferences.setMockInitialValues({
        'vest_events': [
          'fall_candidate=true&battery=76&connected=true&'
              'timestamp=2025-01-02T03%3A04%3A05.000&sample_rate_hz=null&'
              'sensor=%7B%22ax%22%3A0.1%7D&deflation_progress=0&'
              'vest_status=Inflated&location=Test%20location&'
              'latitude=37.7749&longitude=-122.4194',
        ],
      });

      final events = await VestEventStore().loadEvents();

      expect(events, hasLength(1));
      expect(events.single.fallCandidate, isTrue);
      expect(events.single.battery, 76);
      expect(events.single.connected, isTrue);
      expect(events.single.sensor['ax'], 0.1);
      expect(events.single.latitude, 37.7749);
    },
  );

  test('saves new fall events as JSON and reloads them', () async {
    SharedPreferences.setMockInitialValues({});
    final event = VestReading(
      fallCandidate: true,
      battery: 76,
      connected: true,
      timestamp: DateTime.utc(2025, 1, 2, 3, 4, 5),
      vestStatus: 'Ready',
      location: 'Test location',
      latitude: 37.7749,
      longitude: -122.4194,
    );
    final store = VestEventStore();

    await store.saveFall(event);
    final events = await store.loadEvents();

    expect(events, hasLength(1));
    expect(events.single.toJson(), event.toJson());
  });
}

class _MemoryAccountAuthService implements AccountAuthService {
  _MemoryAccountAuthService([AccountUser? initialUser]) : _user = initialUser;

  AccountUser? _user;
  final StreamController<AccountUser?> _changes =
      StreamController<AccountUser?>.broadcast(sync: true);
  int verificationEmailCount = 0;

  @override
  AccountUser? get currentUser => _user;

  @override
  Stream<AccountUser?> get userChanges => _changes.stream;

  @override
  Future<AccountUser> createAccount({
    required String name,
    required String email,
    required String password,
  }) async {
    final user = AccountUser(
      uid: 'new-test-user',
      email: email,
      displayName: name,
      emailVerified: false,
      isAnonymous: false,
    );
    _updateUser(user);
    verificationEmailCount++;
    return user;
  }

  @override
  Future<AccountUser?> signIn({
    required String email,
    required String password,
  }) async => _user;

  @override
  Future<AccountUser?> refreshCurrentUser() async => _user;

  @override
  Future<void> resendVerificationEmail() async {
    verificationEmailCount++;
  }

  @override
  Future<void> sendPasswordResetEmail(String email) async {}

  @override
  Future<void> signOut() async => _updateUser(null);

  void _updateUser(AccountUser? user) {
    _user = user;
    _changes.add(user);
  }

  Future<void> dispose() => _changes.close();
}
