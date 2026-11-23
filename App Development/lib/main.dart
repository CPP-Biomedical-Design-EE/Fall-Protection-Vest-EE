import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:fall_protection_vest_app/account_auth.dart';
import 'package:fall_protection_vest_app/account_page.dart';
import 'package:fall_protection_vest_app/ai_assistant.dart';
import 'package:fall_protection_vest_app/ai_assistant_page.dart';
import 'package:fall_protection_vest_app/app_colors.dart';
import 'package:fall_protection_vest_app/care_preferences.dart';
import 'package:fall_protection_vest_app/emergency_contacts.dart';
import 'package:fall_protection_vest_app/firebase_options.dart';
import 'package:fall_protection_vest_app/help_and_safety.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_ble/universal_ble.dart';
import 'package:url_launcher/url_launcher.dart';

final ValueNotifier<double> appTextScale = ValueNotifier<double>(1);

const _appVersion = '1.0.3+4';
// Keep App Check off for the student prototype while it is signed by an Apple
// Personal Team. Turn this on only after moving to an Apple Developer Program
// team that supports App Attest and registering the production app in Firebase.
const _enableFirebaseAppCheck = bool.fromEnvironment(
  'VEST_ENABLE_FIREBASE_APP_CHECK',
);
const _connectionNameKey = 'connection_display_name';
const _connectionModeKey = 'vest_connection_mode';
const _gatewayAddressKey = 'vest_gateway_address';
const _gatewayClientIdKey = 'vest_gateway_client_id';
const _gatewayClientHeader = 'X-Vest-Client-Id';
const _textScaleKey = 'app_text_scale';
const _notificationsEnabledKey = 'notifications_enabled';
const _notificationDescription =
    'Fall candidates and connection issues. Alerts require the app to receive data; no push service runs while it is fully closed.';
const _bleServiceUuid = '6E400001-B5A3-F393-E0A9-E50E24DCCA9E';
const _bleStatusUuid = '6E400003-B5A3-F393-E0A9-E50E24DCCA9E';
const _bleControlUuid = '6E400002-B5A3-F393-E0A9-E50E24DCCA9E';

/// On-device alert only. This does not contact a caregiver or emergency service.
class VestNotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static Future<void> initialize() async {
    if (kIsWeb || _initialized) return;
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
      macOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );
    try {
      await _plugin.initialize(settings: settings);
      _initialized = true;
    } on Object catch (error) {
      // The notification platform is unavailable in widget tests and on
      // unsupported platforms. The in-app fall alert still remains available.
      debugPrint('Local notifications unavailable: $error');
    }
  }

  static Future<bool> _requestPermissionIfNeeded() async {
    if (kIsWeb) return false;
    var allowed = true;
    final ios = _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    final macos = _plugin
        .resolvePlatformSpecificImplementation<
          MacOSFlutterLocalNotificationsPlugin
        >();
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (ios != null) {
      allowed =
          await ios.requestPermissions(alert: true, badge: true, sound: true) ??
          false;
    }
    if (macos != null) {
      allowed =
          allowed &&
          (await macos.requestPermissions(
                alert: true,
                badge: true,
                sound: true,
              ) ??
              false);
    }
    final androidAllowed = await android?.requestNotificationsPermission();
    if (androidAllowed != null) allowed = allowed && androidAllowed;
    return allowed;
  }

  static Future<bool> requestPermission() async {
    await initialize();
    if (!_initialized) return false;
    try {
      return await _requestPermissionIfNeeded();
    } on Object catch (error) {
      debugPrint('Notification permission unavailable: $error');
      return false;
    }
  }

  static Future<void> showFallCandidate() => showIssue(
    id: 1001,
    title: 'Fall candidate reported',
    body: 'Check the wearer and verify the vest location.',
  );

  static Future<void> showConnectionIssue(String body) =>
      showIssue(id: 1002, title: 'Vest connection issue', body: body);

  static Future<void> showIssue({
    required int id,
    required String title,
    required String body,
  }) async {
    if (kIsWeb || !_initialized) return;
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'vest_fall_alerts',
        'Vest alerts',
        channelDescription: 'Fall and connection issues reported by the app.',
        importance: Importance.max,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        threadIdentifier: 'vest-fall-alerts',
      ),
      macOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        threadIdentifier: 'vest-fall-alerts',
      ),
    );
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: details,
    );
  }

  static Future<void> cancelAll() async {
    if (kIsWeb || !_initialized) return;
    await _plugin.cancelAll();
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AccountAuthService? authService;
  String? appCheckError;
  if (!kIsWeb) {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    if (_enableFirebaseAppCheck) {
      try {
        await FirebaseAppCheck.instance.activate(
          providerAndroid: kDebugMode
              ? const AndroidDebugProvider()
              : const AndroidPlayIntegrityProvider(),
          providerApple: kDebugMode
              ? const AppleDebugProvider()
              : const AppleAppAttestWithDeviceCheckFallbackProvider(),
        );
      } on FirebaseException catch (error) {
        appCheckError =
            'App Check could not be initialized: ${error.message ?? error.code}';
        debugPrint(appCheckError);
      }
    }
    authService = FirebaseAccountAuthService(FirebaseAuth.instance);
  }
  final prefs = await SharedPreferences.getInstance();
  await VestNotificationService.initialize();
  // The app uses one warm palette so status colors stay consistent everywhere.
  await prefs.remove('app_accent_color');
  appTextScale.value = (prefs.getDouble(_textScaleKey) ?? 1)
      .clamp(0.9, 1.3)
      .toDouble();
  runApp(
    VestApp(
      authService: authService,
      assistantService: appCheckError == null && authService != null
          ? FirebaseAssistantService()
          : null,
      assistantSetupError: appCheckError,
    ),
  );
}

class VestReading {
  const VestReading({
    required this.fallCandidate,
    required this.battery,
    required this.connected,
    required this.timestamp,
    this.sampleRateHz,
    this.sensor = const <String, dynamic>{},
    this.vestStatus = 'Ready',
    this.location = 'Location unavailable',
    this.latitude,
    this.longitude,
  });
  final bool fallCandidate;
  final int? battery;
  final bool connected;
  final DateTime timestamp;
  final double? sampleRateHz;
  final Map<String, dynamic> sensor;
  final String vestStatus;
  final String location;
  final double? latitude;
  final double? longitude;

  bool get fallDetected => fallCandidate;

  VestReading copyWith({
    bool? fallCandidate,
    int? battery,
    bool? connected,
    DateTime? timestamp,
    double? sampleRateHz,
    Map<String, dynamic>? sensor,
    String? vestStatus,
    String? location,
    double? latitude,
    double? longitude,
  }) => VestReading(
    fallCandidate: fallCandidate ?? this.fallCandidate,
    battery: battery ?? this.battery,
    connected: connected ?? this.connected,
    timestamp: timestamp ?? this.timestamp,
    sampleRateHz: sampleRateHz ?? this.sampleRateHz,
    sensor: sensor ?? this.sensor,
    vestStatus: vestStatus ?? this.vestStatus,
    location: location ?? this.location,
    latitude: latitude ?? this.latitude,
    longitude: longitude ?? this.longitude,
  );

  factory VestReading.fromJson(Map<String, dynamic> json) => VestReading(
    fallCandidate:
        (json['fall_candidate'] ?? json['fall_detected']) as bool? ?? false,
    battery: (json['battery'] as num?)?.round(),
    connected: json['connected'] as bool? ?? false,
    timestamp:
        DateTime.tryParse(json['timestamp'] as String? ?? '') ?? DateTime.now(),
    sampleRateHz: (json['sample_rate_hz'] as num?)?.toDouble(),
    sensor: json['sensor'] is Map
        ? Map<String, dynamic>.from(json['sensor'] as Map)
        : const <String, dynamic>{},
    vestStatus: json['vest_status'] as String? ?? 'Ready',
    location: json['location'] as String? ?? 'Location unavailable',
    latitude: (json['latitude'] as num?)?.toDouble(),
    longitude: (json['longitude'] as num?)?.toDouble(),
  );

  Map<String, dynamic> toJson() => {
    'fall_candidate': fallCandidate,
    'battery': battery,
    'connected': connected,
    'timestamp': timestamp.toIso8601String(),
    'sample_rate_hz': sampleRateHz,
    'sensor': sensor,
    'vest_status': vestStatus,
    'location': location,
    'latitude': latitude,
    'longitude': longitude,
  };
}

/// Decodes the ESP32's one-byte Nordic UART status notification.
class Esp32BleStatusParser {
  VestReading parse(Uint8List value) {
    if (value.length != 1) {
      throw const FormatException('Vest Bluetooth status must be one byte.');
    }
    final flags = value.first;
    if ((flags & ~0x07) != 0) {
      throw const FormatException('Vest Bluetooth status has unknown flags.');
    }
    final calibrated = (flags & 0x02) != 0;
    return VestReading(
      fallCandidate: (flags & 0x01) != 0,
      battery: null,
      connected: (flags & 0x04) != 0,
      timestamp: DateTime.now(),
      sampleRateHz: 100,
      sensor: {'source': 'Bluetooth LE', 'detector_calibrated': calibrated},
      vestStatus: calibrated
          ? 'Monitoring (experimental)'
          : 'Calibrating (experimental)',
    );
  }
}

/// Converts one ESP32 JSON message into the reading used by the app.
/// Bluetooth or Wi-Fi code should call this parser after receiving a message.
class Esp32MessageParser {
  VestReading parse(String message) {
    final decoded = jsonDecode(message);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('ESP32 message must be a JSON object');
    }
    if (!decoded.containsKey('fall_candidate') &&
        !decoded.containsKey('fall_detected')) {
      throw const FormatException(
        'ESP32 message needs fall_candidate or fall_detected',
      );
    }
    if (!decoded.containsKey('battery') || !decoded.containsKey('connected')) {
      throw const FormatException(
        'ESP32 message needs fall_detected, battery, and connected',
      );
    }
    final battery = decoded['battery'];
    if (battery != null && (battery is! num || battery < 0 || battery > 100)) {
      throw const FormatException('battery must be a number from 0 to 100');
    }
    final candidate = decoded['fall_candidate'] ?? decoded['fall_detected'];
    if (candidate is! bool || decoded['connected'] is! bool) {
      throw const FormatException(
        'fall_detected and connected must be true or false',
      );
    }
    return VestReading.fromJson({
      ...decoded,
      'battery': battery is num ? battery.round() : null,
      'timestamp': decoded['timestamp'] ?? DateTime.now().toIso8601String(),
    });
  }
}

class VestGatewayStatus {
  const VestGatewayStatus({
    required this.reading,
    required this.connectedDevices,
  });

  final VestReading reading;
  final int connectedDevices;

  factory VestGatewayStatus.fromJson(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Gateway status must be a JSON object');
    }
    final count = decoded['connected_devices'];
    if (count is! int || count < 0) {
      throw const FormatException(
        'Gateway status needs a non-negative connected_devices count',
      );
    }
    return VestGatewayStatus(
      reading: Esp32MessageParser().parse(body),
      connectedDevices: count,
    );
  }
}

class VestGatewayClient {
  static Uri statusUri(String address) {
    final value = address.trim();
    final parsed = Uri.tryParse(
      value.contains('://') ? value : 'http://$value',
    );
    if (parsed == null ||
        parsed.scheme != 'http' ||
        parsed.host.isEmpty ||
        parsed.userInfo.isNotEmpty ||
        !{'', '/', '/api/status'}.contains(parsed.path)) {
      throw const FormatException(
        'Enter the gateway computer IP address and optional port.',
      );
    }
    final port = parsed.hasPort ? parsed.port : 8765;
    if (port < 1 || port > 65535) {
      throw const FormatException('Gateway port must be between 1 and 65535.');
    }
    return Uri(
      scheme: 'http',
      host: parsed.host,
      port: port,
      path: '/api/status',
    );
  }

  static Future<VestGatewayStatus> fetchStatus({
    required String address,
    required String clientId,
  }) async {
    final response = await http
        .get(statusUri(address), headers: {_gatewayClientHeader: clientId})
        .timeout(const Duration(seconds: 4));
    if (response.statusCode != 200) {
      throw StateError(
        'Gateway returned HTTP ${response.statusCode}. Check its address and try again.',
      );
    }
    return VestGatewayStatus.fromJson(response.body);
  }
}

/// Replace this source with a Bluetooth or Wi-Fi stream when the ESP32 is ready.
class VestDataSource {
  final parser = Esp32MessageParser();

  VestReading currentReading() => VestReading(
    fallCandidate: false,
    battery: null,
    connected: false,
    timestamp: DateTime.now(),
    vestStatus: 'Ready',
  );
  VestReading simulateFall() => VestReading(
    fallCandidate: true,
    battery: 76,
    connected: true,
    timestamp: DateTime.now(),
    vestStatus: 'Fall candidate',
    location: 'Test location',
    latitude: 37.7749,
    longitude: -122.4194,
  );

  VestReading readingFromEsp32(String message) => parser.parse(message);
}

class VestEventStore {
  static const _key = 'vest_events';

  Future<void> clearEvents() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  Future<List<VestReading>> loadEvents() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_key) ?? <String>[])
        .map((item) => VestReading.fromJson(_decode(item)))
        .toList();
  }

  Future<void> saveFall(VestReading event) async {
    final prefs = await SharedPreferences.getInstance();
    final items = prefs.getStringList(_key) ?? <String>[];
    await prefs.setStringList(
      _key,
      [jsonEncode(event.toJson()), ...items].take(20).toList(),
    );
  }

  Map<String, dynamic> _decode(String value) {
    if (value.trimLeft().startsWith('{')) {
      final decoded = jsonDecode(value);
      if (decoded is Map<String, dynamic>) return decoded;
      throw const FormatException('Stored vest event must be a JSON object');
    }

    final result = <String, dynamic>{};
    for (final part in value.split('&')) {
      final separator = part.indexOf('=');
      if (separator <= 0) {
        throw const FormatException('Stored vest event has an invalid field');
      }
      final key = Uri.decodeComponent(part.substring(0, separator));
      final fieldValue = Uri.decodeComponent(part.substring(separator + 1));
      result[key] = _decodeLegacyEventValue(key, fieldValue);
    }
    return result;
  }

  Object? _decodeLegacyEventValue(String key, String value) {
    if (value == 'null') return null;
    switch (key) {
      case 'fall_candidate':
      case 'fall_detected':
      case 'connected':
        if (value == 'true') return true;
        if (value == 'false') return false;
        throw FormatException('Stored vest event field "$key" must be boolean');
      case 'battery':
        final parsed = int.tryParse(value);
        if (parsed == null) {
          throw FormatException(
            'Stored vest event field "$key" must be an integer',
          );
        }
        return parsed;
      case 'sample_rate_hz':
      case 'latitude':
      case 'longitude':
        final parsed = double.tryParse(value);
        if (parsed == null) {
          throw FormatException(
            'Stored vest event field "$key" must be numeric',
          );
        }
        return parsed;
      case 'sensor':
        final decoded = jsonDecode(value);
        if (decoded is! Map) {
          throw const FormatException(
            'Stored vest event sensor must be an object',
          );
        }
        return Map<String, dynamic>.from(decoded);
      default:
        return value;
    }
  }
}

class VestApp extends StatelessWidget {
  const VestApp({
    super.key,
    this.authService,
    this.assistantService,
    this.assistantSetupError,
  });
  final AccountAuthService? authService;
  final AssistantService? assistantService;
  final String? assistantSetupError;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Fall Protection Vest',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.primary,
        brightness: Brightness.light,
      ),
      scaffoldBackgroundColor: AppColors.canvas,
      useMaterial3: true,
      cardTheme: CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: AppColors.border),
          borderRadius: BorderRadius.circular(20),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.surface,
        indicatorColor: AppColors.goldSoft,
        labelTextStyle: const WidgetStatePropertyAll(
          TextStyle(color: AppColors.ink, fontWeight: FontWeight.w600),
        ),
        iconTheme: const WidgetStatePropertyAll(
          IconThemeData(color: AppColors.muted),
        ),
        elevation: 0,
        height: 72,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.canvas,
        surfaceTintColor: Colors.transparent,
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.border,
        thickness: 1,
      ),
    ),
    home: VestHomePage(
      authService: authService,
      assistantService: assistantService,
      assistantSetupError: assistantSetupError,
    ),
    builder: (context, child) => ValueListenableBuilder<double>(
      valueListenable: appTextScale,
      builder: (context, textScale, _) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child ?? const SizedBox.shrink(),
      ),
    ),
  );
}

class VestHomePage extends StatefulWidget {
  const VestHomePage({
    super.key,
    this.authService,
    this.assistantService,
    this.assistantSetupError,
  });
  final AccountAuthService? authService;
  final AssistantService? assistantService;
  final String? assistantSetupError;

  @override
  State<VestHomePage> createState() => _VestHomePageState();
}

class _VestHomePageState extends State<VestHomePage> {
  final _source = VestDataSource();
  final _store = VestEventStore();
  VestReading? _reading;
  List<VestReading> _events = <VestReading>[];
  int _tab = 0;
  AccountUser? _accountUser;
  StreamSubscription<AccountUser?>? _accountSubscription;
  StreamSubscription<Position>? _positionSubscription;
  Position? _phonePosition;
  LatLng? _lastPhonePoint;
  bool _locationPromptShown = false;
  bool _locationEnabled = true;
  bool _notificationsEnabled = false;
  bool _showDirectionsOnMapOpen = false;
  String _connectionMode = 'wifi';
  String _profileName = 'Guest';
  String _localConnectionName = 'Guest';
  String? _gatewayAddress;
  String? _gatewayClientId;
  int? _connectedDeviceCount;
  bool _gatewayConnecting = false;
  bool _gatewayReachable = false;
  bool _gatewayPolling = false;
  bool _fallCandidateHandled = false;
  bool _bluetoothCandidateDismissed = false;
  bool _bluetoothIssueNotified = false;
  String? _gatewayError;
  Timer? _gatewayPollTimer;
  final List<BleDevice> _bluetoothDevices = <BleDevice>[];
  String? _bluetoothDeviceId;
  String? _bluetoothDeviceName;
  String? _bluetoothError;
  bool _bluetoothScanning = false;
  bool _bluetoothConnecting = false;
  Timer? _bluetoothScanTimer;
  StreamSubscription<BleDevice>? _bluetoothScanSubscription;
  StreamSubscription<Uint8List>? _bluetoothStatusSubscription;
  StreamSubscription<bool>? _bluetoothConnectionSubscription;

  bool get _hasVerifiedAccount =>
      _accountUser != null &&
      !_accountUser!.isAnonymous &&
      _accountUser!.emailVerified;
  String get _accountLabel {
    if (widget.authService == null) return 'Guest mode · testing only';
    if (_hasVerifiedAccount) return 'Verified caregiver account';
    if (_accountUser != null && !_accountUser!.isAnonymous) {
      return 'Email verification required';
    }
    return 'Guest mode · limited testing';
  }

  @override
  void initState() {
    super.initState();
    _reading = _source.currentReading();
    _accountUser = widget.authService?.currentUser;
    _accountSubscription = widget.authService?.userChanges.listen(
      _onAuthUserChanged,
      onError: (Object error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Firebase account status failed: $error')),
          );
        }
      },
    );
    _loadEvents();
    _loadProfile();
    _bluetoothScanSubscription = UniversalBle.scanStream.listen(
      _onBluetoothDeviceFound,
      onError: (Object error) {
        if (mounted) {
          setState(() => _bluetoothError = 'Bluetooth scan failed: $error');
        }
        _notifyBluetoothIssue(
          'Bluetooth scanning failed. Check Bluetooth permissions and try again.',
        );
      },
    );
  }

  void _onAuthUserChanged(AccountUser? user) {
    final wasVerified = _hasVerifiedAccount;
    final isVerified = user != null && !user.isAnonymous && user.emailVerified;
    if (!mounted) return;
    setState(() {
      _accountUser = user;
      _profileName = _localConnectionName;
      if (!isVerified && _tab >= 1 && _tab <= 3) _tab = 0;
    });

    if (!isVerified) {
      _gatewayPollTimer?.cancel();
      unawaited(_stopBluetoothScan());
      unawaited(_disconnectBluetooth());
      setState(() {
        _gatewayConnecting = false;
        _gatewayReachable = false;
        _connectedDeviceCount = null;
        _reading = (_reading ?? _source.currentReading()).copyWith(
          connected: false,
        );
      });
    } else if (!wasVerified &&
        _connectionMode == 'wifi' &&
        _gatewayAddress != null) {
      unawaited(_connectToGateway(_gatewayAddress!));
    }
  }

  Future<void> _openAccountPage() async {
    final authService = widget.authService;
    if (authService == null) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Account unavailable'),
          content: const Text(
            'Firebase Authentication is not initialized in this build. You can continue in limited guest testing mode.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Okay'),
            ),
          ],
        ),
      );
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            AccountPage(auth: authService, initialUser: _accountUser),
      ),
    );
  }

  Future<void> _openAssistant() => Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => AIAssistantPage(
        service: widget.assistantService,
        setupError: widget.assistantSetupError,
      ),
    ),
  );

  bool _requireVerifiedAccount(String feature) {
    if (_hasVerifiedAccount) return true;
    final account = _accountUser;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Verified account required'),
        content: Text(
          account != null && !account.isAnonymous
              ? 'Verify your email before using $feature. You can resend the verification email from Account.'
              : 'Guest mode is limited to demonstration and testing. Log in with a verified email before using $feature.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              unawaited(_openAccountPage());
            },
            child: const Text('Open account'),
          ),
        ],
      ),
    );
    return false;
  }

  Future<void> _startPhoneLocation() async {
    if (!_locationEnabled || _positionSubscription != null) return;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Turn on Location Services to show your position on the map.',
              ),
            ),
          );
        }
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Allow location access to center the map on your position.',
              ),
            ),
          );
        }
        return;
      }
      final position = await Geolocator.getCurrentPosition();
      if (!mounted) return;
      await _savePhonePosition(position);
      if (!mounted) return;
      setState(() => _phonePosition = position);
      _positionSubscription =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 10,
            ),
          ).listen((position) {
            if (mounted) {
              _savePhonePosition(position);
              setState(() => _phonePosition = position);
            }
          });
    } on Exception catch (error) {
      debugPrint('Could not get phone location: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not get your location: $error')),
        );
      }
    }
  }

  Future<void> _savePhonePosition(Position position) async {
    final point = LatLng(position.latitude, position.longitude);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('last_phone_latitude', point.latitude);
    await prefs.setDouble('last_phone_longitude', point.longitude);
    if (mounted) setState(() => _lastPhonePoint = point);
  }

  Future<void> _askForPhoneLocation() async {
    if (!_locationEnabled) return;
    if (_phonePosition != null || _locationPromptShown) {
      await _startPhoneLocation();
      return;
    }
    _locationPromptShown = true;
    if (!mounted) return;
    final allow = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Use phone location?'),
        content: const Text(
          'Your phone location helps show where you are and give directions to the vest after an alert.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Allow location'),
          ),
        ],
      ),
    );
    if (allow == true) await _startPhoneLocation();
  }

  Future<void> _loadProfile() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('care_alert_recipient');
    await prefs.remove('care_emergency_response');
    await prefs.remove('care_battery_threshold');
    await prefs.remove('app_role');
    if (!mounted) return;
    appTextScale.value = (prefs.getDouble(_textScaleKey) ?? 1)
        .clamp(0.9, 1.3)
        .toDouble();
    final gatewayAddress = prefs.getString(_gatewayAddressKey);
    final connectionMode = prefs.getString(_connectionModeKey) == 'bluetooth'
        ? 'bluetooth'
        : 'wifi';
    final localConnectionName =
        prefs.getString(_connectionNameKey) ??
        prefs.getString('profile_name') ??
        'Guest';
    setState(() {
      _connectionMode = connectionMode;
      _localConnectionName = localConnectionName;
      _profileName = localConnectionName;
      _gatewayAddress = gatewayAddress;
      _gatewayClientId = prefs.getString(_gatewayClientIdKey);
      _locationEnabled = prefs.getBool('location_enabled') ?? true;
      _notificationsEnabled = prefs.getBool(_notificationsEnabledKey) ?? false;
      final latitude = prefs.getDouble('last_phone_latitude');
      final longitude = prefs.getDouble('last_phone_longitude');
      if (latitude != null && longitude != null) {
        _lastPhonePoint = LatLng(latitude, longitude);
      }
    });
    if (gatewayAddress != null &&
        connectionMode == 'wifi' &&
        _hasVerifiedAccount) {
      await _connectToGateway(gatewayAddress);
    }
  }

  Future<void> _persistConnectionMode(String mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_connectionModeKey, mode);
    } on Exception catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save connection mode: $error')),
      );
    }
  }

  void _selectConnectionMode(String mode) {
    if (mode == _connectionMode || !{'wifi', 'bluetooth'}.contains(mode)) {
      return;
    }
    _gatewayPollTimer?.cancel();
    setState(() {
      _connectionMode = mode;
      _gatewayConnecting = false;
      _gatewayReachable = false;
      _connectedDeviceCount = null;
      _gatewayError = null;
      _bluetoothError = null;
    });
    unawaited(_persistConnectionMode(mode));
    unawaited(_stopBluetoothScan());
    unawaited(_disconnectBluetooth());
    if (mode == 'wifi' && _gatewayAddress != null) {
      unawaited(_connectToGateway(_gatewayAddress!));
    }
  }

  Future<void> _setConnectionName(String value) async {
    final name = value.trim();
    if (name.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_connectionNameKey, name);
    if (!mounted) return;
    setState(() {
      _localConnectionName = name;
      _profileName = name;
    });
  }

  String _createGatewayClientId() {
    final random = math.Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Future<void> _connectToGateway(String address) async {
    if (!_requireVerifiedAccount('live vest monitoring') ||
        _connectionMode != 'wifi') {
      return;
    }
    final normalizedAddress = address.trim();
    if (normalizedAddress.isEmpty) {
      setState(() {
        _gatewayError = 'Enter the gateway computer IP address.';
      });
      return;
    }
    try {
      VestGatewayClient.statusUri(normalizedAddress);
    } on FormatException catch (error) {
      setState(() {
        _gatewayError = error.message.toString();
        _gatewayReachable = false;
        _connectedDeviceCount = null;
      });
      return;
    }
    _gatewayPollTimer?.cancel();
    setState(() {
      _gatewayConnecting = true;
      _gatewayError = null;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final clientId =
          prefs.getString(_gatewayClientIdKey) ?? _createGatewayClientId();
      final status = await VestGatewayClient.fetchStatus(
        address: normalizedAddress,
        clientId: clientId,
      );
      await prefs.setString(_gatewayAddressKey, normalizedAddress);
      await prefs.setString(_gatewayClientIdKey, clientId);
      if (!mounted) return;
      setState(() {
        _gatewayAddress = normalizedAddress;
        _gatewayClientId = clientId;
        _gatewayConnecting = false;
      });
      await _applyGatewayStatus(status);
      _gatewayPollTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => _pollGateway(),
      );
    } on TimeoutException {
      _setGatewayFailure('The gateway did not respond within 4 seconds.');
    } on http.ClientException catch (error) {
      _setGatewayFailure('Could not reach the gateway: ${error.message}');
    } on FormatException catch (error) {
      _setGatewayFailure('Invalid gateway status: ${error.message}');
    } on StateError catch (error) {
      _setGatewayFailure(error.message.toString());
    }
  }

  Future<void> _pollGateway() async {
    final address = _gatewayAddress;
    final clientId = _gatewayClientId;
    if (!_hasVerifiedAccount ||
        _connectionMode != 'wifi' ||
        _gatewayPolling ||
        address == null ||
        clientId == null) {
      return;
    }
    _gatewayPolling = true;
    try {
      final status = await VestGatewayClient.fetchStatus(
        address: address,
        clientId: clientId,
      );
      await _applyGatewayStatus(status);
    } on TimeoutException {
      _setGatewayFailure('The gateway stopped responding.');
    } on http.ClientException catch (error) {
      _setGatewayFailure('Gateway connection lost: ${error.message}');
    } on FormatException catch (error) {
      _setGatewayFailure('Invalid gateway status: ${error.message}');
    } on StateError catch (error) {
      _setGatewayFailure(error.message.toString());
    } finally {
      _gatewayPolling = false;
    }
  }

  Future<void> _applyGatewayStatus(VestGatewayStatus status) async {
    if (!_hasVerifiedAccount || _connectionMode != 'wifi') return;
    final vestConnectionLost =
        _gatewayReachable &&
        _reading?.connected == true &&
        !status.reading.connected;
    final fallCandidateStarted =
        status.reading.fallCandidate && !_fallCandidateHandled;
    if (fallCandidateStarted) {
      _fallCandidateHandled = true;
      await _store.saveFall(status.reading);
    }
    if (!status.reading.fallCandidate) _fallCandidateHandled = false;
    if (!mounted) return;
    setState(() {
      _reading = status.reading;
      _connectedDeviceCount = status.connectedDevices;
      _gatewayReachable = true;
      _gatewayError = null;
      if (fallCandidateStarted) {
        _events = [status.reading, ..._events].take(20).toList();
      }
    });
    if (vestConnectionLost) {
      unawaited(
        _deliverNotification(
          () => VestNotificationService.showConnectionIssue(
            'The gateway reports that the vest is disconnected.',
          ),
        ),
      );
    }
    if (fallCandidateStarted) _showFallAlert(status.reading);
  }

  void _setGatewayFailure(String message) {
    if (_gatewayReachable || _gatewayConnecting) {
      unawaited(
        _deliverNotification(
          () => VestNotificationService.showConnectionIssue(message),
        ),
      );
    }
    if (!mounted) return;
    setState(() {
      _reading = _source.currentReading();
      _connectedDeviceCount = null;
      _gatewayConnecting = false;
      _gatewayReachable = false;
      _gatewayError = message;
    });
  }

  Future<void> _disconnectGateway() async {
    _gatewayPollTimer?.cancel();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_gatewayAddressKey);
    if (!mounted) return;
    setState(() {
      _gatewayAddress = null;
      _reading = _source.currentReading();
      _connectedDeviceCount = null;
      _gatewayConnecting = false;
      _gatewayReachable = false;
      _gatewayError = null;
    });
  }

  void _onBluetoothDeviceFound(BleDevice device) {
    if (!_bluetoothScanning ||
        !device.services.any(
          (service) => service.toLowerCase() == _bleServiceUuid.toLowerCase(),
        ) ||
        _bluetoothDevices.any(
          (existing) => existing.deviceId == device.deviceId,
        )) {
      return;
    }
    if (mounted) setState(() => _bluetoothDevices.add(device));
  }

  Future<void> _startBluetoothScan() async {
    if (!_requireVerifiedAccount('Bluetooth vest monitoring') ||
        _connectionMode != 'bluetooth' ||
        _bluetoothScanning ||
        _bluetoothConnecting) {
      return;
    }
    _bluetoothIssueNotified = false;
    setState(() {
      _bluetoothScanning = true;
      _bluetoothDevices.clear();
      _bluetoothError = null;
    });
    try {
      final availability = await UniversalBle.getBluetoothAvailabilityState();
      if (availability != AvailabilityState.poweredOn) {
        throw StateError(
          'Bluetooth is ${availability.name}. Turn it on and allow Bluetooth access.',
        );
      }
      await UniversalBle.requestPermissions();
      await UniversalBle.startScan(
        scanFilter: ScanFilter(withServices: [_bleServiceUuid]),
        platformConfig: PlatformConfig(android: AndroidOptions(legacy: true)),
        skipDuplicates: true,
      );
      _bluetoothScanTimer?.cancel();
      _bluetoothScanTimer = Timer(
        const Duration(seconds: 15),
        () => unawaited(_stopBluetoothScan()),
      );
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _bluetoothScanning = false;
        _bluetoothError = 'Could not scan for the vest: $error';
      });
      _notifyBluetoothIssue(
        'Could not scan for the vest. Check Bluetooth permissions and try again.',
      );
    }
  }

  Future<void> _stopBluetoothScan() async {
    _bluetoothScanTimer?.cancel();
    _bluetoothScanTimer = null;
    if (!_bluetoothScanning) return;
    try {
      await UniversalBle.stopScan();
    } on Exception catch (error) {
      if (mounted) {
        setState(
          () => _bluetoothError = 'Could not stop Bluetooth scan: $error',
        );
      }
    }
    if (mounted) setState(() => _bluetoothScanning = false);
  }

  Future<void> _connectToBluetooth(BleDevice device) async {
    await _stopBluetoothScan();
    if (!_requireVerifiedAccount('Bluetooth vest monitoring') ||
        _connectionMode != 'bluetooth' ||
        _bluetoothConnecting) {
      return;
    }
    setState(() {
      _bluetoothConnecting = true;
      _bluetoothError = null;
    });
    _bluetoothIssueNotified = false;
    var connected = false;
    try {
      await UniversalBle.requestPermissions();
      await UniversalBle.connect(
        device.deviceId,
        timeout: const Duration(seconds: 20),
      );
      connected = true;
      final services = await UniversalBle.discoverServices(device.deviceId);
      final hasStatusService = services.any(
        (service) =>
            service.uuid.toLowerCase() == _bleServiceUuid.toLowerCase() &&
            service.characteristics.any(
              (characteristic) =>
                  characteristic.uuid.toLowerCase() ==
                  _bleStatusUuid.toLowerCase(),
            ) &&
            service.characteristics.any(
              (characteristic) =>
                  characteristic.uuid.toLowerCase() ==
                  _bleControlUuid.toLowerCase(),
            ),
      );
      if (!hasStatusService) {
        throw StateError(
          'This Bluetooth device does not provide the supported vest service.',
        );
      }

      _bluetoothDeviceId = device.deviceId;
      _bluetoothDeviceName = device.name?.isNotEmpty == true
          ? device.name
          : 'ESP32 Vest';
      _bluetoothStatusSubscription =
          UniversalBle.characteristicValueStream(
            device.deviceId,
            _bleStatusUuid,
          ).listen(
            (value) => unawaited(_applyBluetoothStatus(device.deviceId, value)),
            onError: (Object error) {
              if (mounted) {
                setState(
                  () =>
                      _bluetoothError = 'Bluetooth data stream failed: $error',
                );
              }
              _notifyBluetoothIssue(
                'Bluetooth data from the vest stopped unexpectedly.',
              );
            },
          );
      _bluetoothConnectionSubscription =
          UniversalBle.connectionStream(device.deviceId).listen((isConnected) {
            if (!isConnected && _bluetoothDeviceId == device.deviceId) {
              unawaited(_handleBluetoothDisconnect(device.deviceId));
            }
          });
      setState(() {
        _bluetoothConnecting = false;
        _reading = (_reading ?? _source.currentReading()).copyWith(
          connected: true,
          battery: null,
        );
      });
      await UniversalBle.subscribeNotifications(
        device.deviceId,
        _bleServiceUuid,
        _bleStatusUuid,
      );
    } on Exception catch (error) {
      await _bluetoothStatusSubscription?.cancel();
      await _bluetoothConnectionSubscription?.cancel();
      _bluetoothStatusSubscription = null;
      _bluetoothConnectionSubscription = null;
      _bluetoothDeviceId = null;
      _bluetoothDeviceName = null;
      if (connected) {
        try {
          await UniversalBle.disconnect(device.deviceId);
        } on Exception catch (disconnectError) {
          debugPrint('Bluetooth cleanup failed: $disconnectError');
        }
      }
      if (!mounted) return;
      setState(() {
        _bluetoothConnecting = false;
        _reading = (_reading ?? _source.currentReading()).copyWith(
          connected: false,
        );
        _bluetoothError = 'Could not connect to the vest: $error';
      });
      _notifyBluetoothIssue('Could not connect to the vest over Bluetooth.');
    }
  }

  Future<void> _applyBluetoothStatus(String deviceId, Uint8List value) async {
    if (_bluetoothDeviceId != deviceId) return;
    late final VestReading reading;
    try {
      reading = Esp32BleStatusParser().parse(value);
    } on FormatException catch (error) {
      if (mounted) {
        setState(
          () => _bluetoothError = 'Invalid status from vest: ${error.message}',
        );
      }
      _notifyBluetoothIssue('The vest sent invalid status data.');
      return;
    }
    _bluetoothIssueNotified = false;
    final vestConnectionLost =
        _reading?.connected == true && !reading.connected;
    final fallCandidateStarted =
        reading.fallCandidate && !_fallCandidateHandled;
    if (fallCandidateStarted) {
      _fallCandidateHandled = true;
      try {
        await _store.saveFall(reading);
      } on Exception catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not save fall event: $error')),
          );
        }
      }
    }
    if (!reading.fallCandidate) {
      _fallCandidateHandled = false;
      _bluetoothCandidateDismissed = false;
    }
    final visibleReading = _bluetoothCandidateDismissed
        ? reading.copyWith(fallCandidate: false)
        : reading;
    if (!mounted) return;
    setState(() {
      _reading = visibleReading;
      _bluetoothError = null;
      if (fallCandidateStarted) {
        _events = [reading, ..._events].take(20).toList();
      }
    });
    if (vestConnectionLost) {
      _notifyBluetoothIssue(
        'The vest reported that its sensor connection was lost.',
      );
    }
    if (fallCandidateStarted) _showFallAlert(reading);
  }

  Future<void> _handleBluetoothDisconnect(String deviceId) async {
    if (_bluetoothDeviceId != deviceId) return;
    await _bluetoothStatusSubscription?.cancel();
    await _bluetoothConnectionSubscription?.cancel();
    _bluetoothStatusSubscription = null;
    _bluetoothConnectionSubscription = null;
    _bluetoothDeviceId = null;
    _bluetoothDeviceName = null;
    if (!mounted) return;
    setState(() {
      _reading = (_reading ?? _source.currentReading()).copyWith(
        connected: false,
      );
      _bluetoothError = 'Bluetooth connection to the vest was lost.';
    });
    _notifyBluetoothIssue('Bluetooth connection to the vest was lost.');
  }

  Future<void> _disconnectBluetooth() async {
    final deviceId = _bluetoothDeviceId;
    await _bluetoothStatusSubscription?.cancel();
    await _bluetoothConnectionSubscription?.cancel();
    _bluetoothStatusSubscription = null;
    _bluetoothConnectionSubscription = null;
    _bluetoothDeviceId = null;
    _bluetoothDeviceName = null;
    if (deviceId != null) {
      try {
        await UniversalBle.disconnect(deviceId);
      } on Exception catch (error) {
        if (mounted) {
          setState(
            () => _bluetoothError = 'Could not disconnect Bluetooth: $error',
          );
        } else {
          debugPrint('Bluetooth disconnect failed: $error');
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _bluetoothConnecting = false;
      _reading = (_reading ?? _source.currentReading()).copyWith(
        connected: false,
      );
    });
  }

  Future<void> _acknowledgeBluetoothFall() async {
    final deviceId = _bluetoothDeviceId;
    if (deviceId == null) return;
    try {
      await UniversalBle.write(
        deviceId,
        _bleServiceUuid,
        _bleControlUuid,
        Uint8List.fromList(utf8.encode('ACK_CANDIDATE')),
      );
      _bluetoothCandidateDismissed = true;
      if (mounted) {
        setState(() {
          _reading = (_reading ?? _source.currentReading()).copyWith(
            fallCandidate: false,
          );
        });
      }
    } on Exception catch (error) {
      if (!mounted) return;
      setState(
        () => _bluetoothError = 'Could not acknowledge the fall status: $error',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not acknowledge the vest alert: $error')),
      );
    }
  }

  Future<void> _setLocationEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('location_enabled', enabled);
    if (!enabled) {
      await _positionSubscription?.cancel();
      _positionSubscription = null;
    }
    if (!mounted) return;
    setState(() {
      _locationEnabled = enabled;
      if (!enabled) _phonePosition = null;
    });
    if (enabled) await _askForPhoneLocation();
  }

  Future<void> _setNotificationsEnabled(bool enabled) async {
    if (enabled) {
      final allowed = await VestNotificationService.requestPermission();
      if (!mounted) return;
      if (!allowed) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Notifications are blocked. Allow them in your phone settings, then try again.',
            ),
          ),
        );
        return;
      }
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = await prefs.setBool(_notificationsEnabledKey, enabled);
      if (!saved) throw StateError('Notification setting was not saved.');
      if (!mounted) return;
      setState(() => _notificationsEnabled = enabled);
    } on Exception catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not update notifications: $error')),
      );
      return;
    }

    if (!enabled) {
      try {
        await VestNotificationService.cancelAll();
      } on Exception catch (error) {
        debugPrint('Could not clear pending notifications: $error');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Notifications are off, but an existing alert could not be cleared: $error',
              ),
            ),
          );
        }
      }
    }
  }

  void _showNotificationOptions() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Notifications'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('System notifications'),
                value: _notificationsEnabled,
                onChanged: (enabled) async {
                  await _setNotificationsEnabled(enabled);
                  if (dialogContext.mounted) setDialogState(() {});
                },
              ),
              const Text(
                _notificationDescription,
                style: TextStyle(color: Color(0xFF687076), height: 1.4),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deliverNotification(Future<void> Function() show) async {
    if (!_notificationsEnabled) return;
    try {
      await show();
    } on Exception catch (error) {
      debugPrint('Could not show system notification: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not show system notification: $error')),
        );
      }
    }
  }

  void _notifyBluetoothIssue(String message) {
    if (!_notificationsEnabled || _bluetoothIssueNotified) return;
    _bluetoothIssueNotified = true;
    unawaited(
      _deliverNotification(
        () => VestNotificationService.showConnectionIssue(message),
      ),
    );
  }

  void _findVest() {
    final hasLiveLocation = _hasLiveVestLocation(_reading!);
    if (hasLiveLocation &&
        !_requireVerifiedAccount('live vest location and directions')) {
      return;
    }
    _openMap(showDirections: hasLiveLocation);
    if (!hasLiveLocation) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Vest GPS is unavailable. Connect a GPS-enabled gateway before requesting directions.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _editConnectionName() async {
    var enteredName = _profileName == 'Guest' ? '' : _profileName;
    final savedName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Connection name'),
        content: TextFormField(
          initialValue: enteredName,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          onChanged: (value) => enteredName = value,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final name = enteredName.trim();
              if (name.isEmpty) return;
              Navigator.pop(context, name);
            },
            child: const Text('Save name'),
          ),
        ],
      ),
    );
    if (savedName != null) await _setConnectionName(savedName);
  }

  void _openMap({bool showDirections = false}) {
    if (showDirections &&
        !_requireVerifiedAccount('live vest location and directions')) {
      return;
    }
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    setState(() {
      _tab = 3;
      _showDirectionsOnMapOpen = showDirections;
    });
    if (!showDirections) _askForPhoneLocation();
  }

  bool _hasLiveVestLocation(VestReading reading) =>
      reading.latitude != null &&
      reading.longitude != null &&
      reading.location != 'Test location' &&
      reading.location != 'Vest Location Received';

  Future<void> _loadEvents() async {
    final events = await _store.loadEvents();
    if (mounted) setState(() => _events = events);
  }

  Future<void> _clearEventHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear event history?'),
        content: const Text(
          'This removes the saved vest events from this phone. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep events'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear history'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _store.clearEvents();
    if (!mounted) return;
    setState(_events.clear);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Saved event history cleared.')),
    );
  }

  void _setTextScale(double value) {
    appTextScale.value = value;
    unawaited(_persistTextScale(value));
  }

  Future<void> _persistTextScale(double value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_textScaleKey, value);
    } on Exception catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save text size: $error')),
      );
    }
  }

  Future<void> _simulateFall() async {
    final reading = _source.simulateFall();
    await _store.saveFall(reading);
    if (!mounted) return;
    _fallCandidateHandled = true;
    setState(() {
      _reading = reading;
      _events = [reading, ..._events];
    });
    _showFallAlert(reading);
  }

  void _showFallAlert(VestReading reading) {
    unawaited(_deliverNotification(VestNotificationService.showFallCandidate));
    final hasLiveLocation = _hasLiveVestLocation(reading);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(28),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(18, 24, 18, 20),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [AppColors.danger, Color(0xFF913127)],
                  ),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Column(
                  children: [
                    const FallSlipIcon(color: Colors.white, size: 72),
                    const SizedBox(height: 10),
                    const Text(
                      'FALL CANDIDATE',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 23,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.6,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Experimental alert · check on the wearer',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        children: [
                          _FallAlertDetailRow(
                            icon: Icons.access_time_rounded,
                            value: _formatTime(reading.timestamp),
                          ),
                          const SizedBox(height: 10),
                          _FallAlertDetailRow(
                            icon: Icons.location_on_rounded,
                            value: hasLiveLocation
                                ? 'Location received'
                                : 'Location unavailable',
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () {
                          Navigator.pop(dialogContext);
                          _openMap(showDirections: hasLiveLocation);
                        },
                        icon: const Icon(Icons.location_on_rounded),
                        label: Text(
                          hasLiveLocation ? 'View location' : 'Open map',
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.primaryDeep,
                          foregroundColor: Colors.white,
                          minimumSize: const Size.fromHeight(48),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.primaryDeep,
                    minimumSize: const Size.fromHeight(48),
                    side: const BorderSide(color: AppColors.primaryDeep),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: const Text('Dismiss'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _dismissAlert() {
    if (_connectionMode == 'bluetooth' && _bluetoothDeviceId != null) {
      unawaited(_acknowledgeBluetoothFall());
      return;
    }
    final current = _reading!;
    setState(() {
      _reading = current.copyWith(fallCandidate: false);
    });
  }

  void _showEmergencyMessage() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Emergency contact'),
        content: const Text(
          'This prototype cannot contact emergency contacts or emergency services. Follow your established safety and emergency procedures.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Okay'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _gatewayPollTimer?.cancel();
    _accountSubscription?.cancel();
    _bluetoothScanTimer?.cancel();
    _bluetoothScanSubscription?.cancel();
    _bluetoothStatusSubscription?.cancel();
    _bluetoothConnectionSubscription?.cancel();
    unawaited(_cleanupBluetoothOnDispose());
    _positionSubscription?.cancel();
    super.dispose();
  }

  Future<void> _cleanupBluetoothOnDispose() async {
    if (_bluetoothScanning) {
      try {
        await UniversalBle.stopScan();
      } on Exception catch (error) {
        debugPrint('Bluetooth scan cleanup failed: $error');
      }
    }
    final deviceId = _bluetoothDeviceId;
    if (deviceId != null) {
      try {
        await UniversalBle.disconnect(deviceId);
      } on Exception catch (error) {
        debugPrint('Bluetooth connection cleanup failed: $error');
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: IndexedStack(
        index: _tab,
        children: [
          _HomeView(
            reading: _reading!,
            caregiverAccess: _hasVerifiedAccount,
            accountLabel: _accountLabel,
            onOpenAccount: _openAccountPage,
            onOpenAssistant: _openAssistant,
            onOpenNotifications: _showNotificationOptions,
            onHistory: () {
              if (_requireVerifiedAccount('event history')) {
                setState(() => _tab = 1);
              }
            },
            onDevice: () {
              if (_requireVerifiedAccount('vest connection settings')) {
                setState(() => _tab = 2);
              }
            },
            onSimulateFall: _simulateFall,
            onDismissAlert: _dismissAlert,
            onEmergencyContact: _showEmergencyMessage,
            onMap: _openMap,
            onFindVest: _findVest,
          ),
          _HistoryView(events: _events),
          _DeviceView(
            reading: _reading!,
            profileName: _profileName,
            connectionMode: _connectionMode,
            gatewayAddress: _gatewayAddress,
            connectedDeviceCount: _connectedDeviceCount,
            gatewayConnecting: _gatewayConnecting,
            gatewayReachable: _gatewayReachable,
            gatewayError: _gatewayError,
            bluetoothDevices: _bluetoothDevices,
            bluetoothDeviceId: _bluetoothDeviceId,
            bluetoothDeviceName: _bluetoothDeviceName,
            bluetoothError: _bluetoothError,
            bluetoothScanning: _bluetoothScanning,
            bluetoothConnecting: _bluetoothConnecting,
            onConnect: _connectToGateway,
            onDisconnect: _disconnectGateway,
            onConnectionModeChanged: _selectConnectionMode,
            onBluetoothScan: _startBluetoothScan,
            onBluetoothStopScan: _stopBluetoothScan,
            onBluetoothConnect: _connectToBluetooth,
            onBluetoothDisconnect: _disconnectBluetooth,
          ),
          _tab == 3
              ? _MapView(
                  reading: _reading!,
                  phonePosition: _phonePosition,
                  lastPhonePoint: _lastPhonePoint,
                  locationEnabled: _locationEnabled,
                  showDirectionsOnOpen: _showDirectionsOnMapOpen,
                  onDirectionsRequestHandled: () {
                    if (mounted) {
                      setState(() => _showDirectionsOnMapOpen = false);
                    }
                  },
                  onFindVest: _findVest,
                )
              : const SizedBox.shrink(),
          _SettingsView(
            profileName: _profileName,
            eventCount: _events.length,
            accountLabel: _accountLabel,
            accountEmail: _accountUser?.email ?? '',
            caregiverAccess: _hasVerifiedAccount,
            firebaseAvailable: widget.authService != null,
            locationEnabled: _locationEnabled,
            notificationsEnabled: _notificationsEnabled,
            gatewayAddress: _gatewayAddress,
            connectedDeviceCount: _connectedDeviceCount,
            gatewayReachable: _gatewayReachable,
            onOpenAccount: _openAccountPage,
            onOpenAssistant: _openAssistant,
            onNotificationsChanged: _setNotificationsEnabled,
            onOpenDeviceSettings: () {
              if (_requireVerifiedAccount('vest connection settings')) {
                setState(() => _tab = 2);
              }
            },
            onEditConnectionName: _editConnectionName,
            onLocationChanged: _setLocationEnabled,
            onClearEventHistory: _clearEventHistory,
            onTextScaleChanged: _setTextScale,
          ),
        ],
      ),
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: _tab,
      onDestinationSelected: (value) {
        if (value == 1 && !_requireVerifiedAccount('event history')) return;
        if (value == 2 &&
            !_requireVerifiedAccount('vest connection settings')) {
          return;
        }
        if (value == 3 && !_hasVerifiedAccount) {
          _openMap();
          return;
        }
        setState(() => _tab = value);
        if (value == 3) _askForPhoneLocation();
      },
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home),
          label: 'Home',
        ),
        NavigationDestination(icon: Icon(Icons.history), label: 'History'),
        NavigationDestination(
          icon: VestIcon(size: 25),
          selectedIcon: VestIcon(size: 25, filled: true),
          label: 'Device',
        ),
        NavigationDestination(
          icon: Icon(Icons.map_outlined),
          selectedIcon: Icon(Icons.map),
          label: 'Map',
        ),
        NavigationDestination(
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings),
          label: 'Settings',
        ),
      ],
    ),
  );
}

class _FallAlertDetailRow extends StatelessWidget {
  const _FallAlertDetailRow({required this.icon, required this.value});

  final IconData icon;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, color: const Color(0xFF8A4B1D), size: 20),
      const SizedBox(width: 10),
      Expanded(
        child: Text(
          value,
          style: const TextStyle(
            color: Color(0xFF2F241C),
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    ],
  );
}

class _HomeView extends StatelessWidget {
  const _HomeView({
    required this.reading,
    required this.caregiverAccess,
    required this.accountLabel,
    required this.onOpenAccount,
    required this.onOpenAssistant,
    required this.onOpenNotifications,
    required this.onHistory,
    required this.onDevice,
    required this.onSimulateFall,
    required this.onDismissAlert,
    required this.onEmergencyContact,
    required this.onMap,
    required this.onFindVest,
  });
  final VestReading reading;
  final bool caregiverAccess;
  final String accountLabel;
  final VoidCallback onOpenAccount;
  final VoidCallback onOpenAssistant;
  final VoidCallback onOpenNotifications;
  final VoidCallback onHistory;
  final VoidCallback onDevice;
  final VoidCallback onSimulateFall;
  final VoidCallback onDismissAlert;
  final VoidCallback onEmergencyContact;
  final VoidCallback onMap;
  final VoidCallback onFindVest;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(20, 18, 20, 30),
    children: [
      Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFE7EAE6)),
            ),
            child: const VestIcon(size: 30, color: Color(0xFF111214)),
          ),
          const SizedBox(width: 11),
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'INFLATEBODY',
                style: TextStyle(
                  color: Color(0xFF202124),
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.1,
                ),
              ),
              SizedBox(height: 3),
              Text(
                'VEST COMPANION',
                style: TextStyle(
                  color: Color(0xFF687076),
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const Spacer(),
          Material(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              onTap: onOpenAssistant,
              borderRadius: BorderRadius.circular(14),
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFFE7EAE6)),
                ),
                child: const Icon(
                  Icons.chat_bubble_outline_rounded,
                  color: Color(0xFF343A40),
                ),
              ),
            ),
          ),
          const SizedBox(width: 9),
          InkWell(
            key: const ValueKey('notification-settings-button'),
            onTap: onOpenNotifications,
            borderRadius: BorderRadius.circular(14),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFFE7EAE6)),
                  ),
                  child: Icon(
                    Icons.notifications_none_rounded,
                    color: const Color(0xFF343A40),
                  ),
                ),
                if (reading.fallDetected)
                  Positioned(
                    right: 2,
                    top: 1,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: const BoxDecoration(
                        color: Color(0xFFD92D20),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
      if (!caregiverAccess) ...[
        const SizedBox(height: 14),
        Card(
          child: ListTile(
            leading: const Icon(
              Icons.lock_outline_rounded,
              color: Color(0xFF8A4B08),
            ),
            title: Text(
              accountLabel,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: const Text(
              'Sign in and verify your email to unlock caregiver features.',
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: onOpenAccount,
          ),
        ),
      ],
      const SizedBox(height: 24),
      const Text(
        'Your safety, at a glance',
        style: TextStyle(
          color: Color(0xFF202124),
          fontWeight: FontWeight.w800,
          fontSize: 29,
          letterSpacing: -0.8,
        ),
      ),
      const SizedBox(height: 6),
      const Text(
        'A clear view of your vest and sensor status.',
        style: TextStyle(color: Color(0xFF687076), fontSize: 14),
      ),
      const SizedBox(height: 20),
      _SystemStatusCard(connected: reading.connected),
      const SizedBox(height: 25),
      const Text(
        'Quick actions',
        style: TextStyle(
          color: Color(0xFF202124),
          fontWeight: FontWeight.w700,
          fontSize: 18,
        ),
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: _HomeShortcut(
              icon: Icons.location_searching_rounded,
              label: 'Find vest',
              onTap: onFindVest,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _HomeShortcut(
              icon: Icons.map_outlined,
              label: 'Map',
              onTap: onMap,
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          Expanded(
            child: _HomeShortcut(
              icon: Icons.history_rounded,
              label: 'History',
              onTap: onHistory,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _HomeShortcut(
              iconWidget: const VestIcon(size: 22),
              label: 'Device',
              onTap: onDevice,
            ),
          ),
        ],
      ),
      const SizedBox(height: 25),
      Row(
        children: [
          const Text(
            'Vest status',
            style: TextStyle(
              color: Color(0xFF202124),
              fontWeight: FontWeight.w700,
              fontSize: 18,
            ),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
            decoration: BoxDecoration(
              color: reading.connected
                  ? const Color(0xFF173321)
                  : const Color(0xFFF0F2EF),
              borderRadius: BorderRadius.circular(30),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: reading.connected
                        ? const Color(0xFF16804A)
                        : const Color(0xFF7A847D),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 7),
                Text(
                  reading.connected ? 'Connected' : 'Offline',
                  style: TextStyle(
                    color: reading.connected
                        ? const Color(0xFF6EE7A0)
                        : const Color(0xFF687076),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      reading.fallDetected
          ? _AlertCard(
              time: reading.timestamp,
              onDismiss: onDismissAlert,
              onEmergencyContact: onEmergencyContact,
              onMap: onMap,
            )
          : reading.connected
          ? const _NormalCard()
          : const SizedBox.shrink(),
      const SizedBox(height: 15),
      Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 17),
          child: Row(
            children: [
              Expanded(
                child: _HomeMetric(
                  icon: Icons.battery_charging_full_rounded,
                  label: 'Battery',
                  value: reading.battery == null
                      ? 'Not reported'
                      : '${reading.battery}%',
                ),
              ),
              Container(width: 1, height: 42, color: const Color(0xFFE7EAE6)),
              const SizedBox(width: 14),
              Expanded(
                child: _HomeMetric(
                  iconWidget: const VestIcon(size: 28),
                  label: 'Vest',
                  value: reading.vestStatus,
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 14),
      OutlinedButton.icon(
        onPressed: onSimulateFall,
        icon: const Icon(Icons.bolt_rounded, size: 19),
        label: const Text('Test alert'),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          foregroundColor: Theme.of(context).colorScheme.primary,
          side: BorderSide(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.4),
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
        ),
      ),
    ],
  );
}

class _SystemStatusCard extends StatelessWidget {
  const _SystemStatusCard({required this.connected});
  final bool connected;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(19),
    decoration: BoxDecoration(
      color: AppColors.monitoring,
      borderRadius: BorderRadius.circular(22),
    ),
    child: Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(15),
          ),
          child: Icon(
            connected ? Icons.sensors_rounded : Icons.portable_wifi_off_rounded,
            color: AppColors.gold,
            size: 24,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'LIVE MONITORING',
                      style: TextStyle(
                        color: AppColors.monitoringMuted,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      connected ? 'Connected' : 'Offline',
                      style: const TextStyle(
                        color: AppColors.surface,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                connected ? 'Sensor feed active' : 'Waiting for your vest',
                style: const TextStyle(
                  color: AppColors.surface,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                connected
                    ? 'Status updates are coming from your device.'
                    : 'Connect your device to enable live monitoring.',
                style: const TextStyle(
                  color: AppColors.monitoringMuted,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _HomeShortcut extends StatelessWidget {
  const _HomeShortcut({
    this.icon,
    this.iconWidget,
    required this.label,
    required this.onTap,
  }) : assert(icon != null || iconWidget != null);

  final IconData? icon;
  final Widget? iconWidget;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    borderRadius: BorderRadius.circular(17),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(17),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 14),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFFE7EAE6)),
          borderRadius: BorderRadius.circular(17),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: iconWidget == null
                    ? Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.12)
                    : Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child:
                  iconWidget ??
                  Icon(
                    icon,
                    color: Theme.of(context).colorScheme.primary,
                    size: 20,
                  ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF343A40),
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _HomeMetric extends StatelessWidget {
  const _HomeMetric({
    this.icon,
    this.iconWidget,
    required this.label,
    required this.value,
  }) : assert(icon != null || iconWidget != null);

  final IconData? icon;
  final Widget? iconWidget;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      iconWidget ??
          Icon(icon, color: Theme.of(context).colorScheme.primary, size: 27),
      const SizedBox(width: 9),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(color: Color(0xFF687076))),
            const SizedBox(height: 2),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    ],
  );
}

class _NormalCard extends StatelessWidget {
  const _NormalCard();
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: const Color(0xFF14251B),
      borderRadius: BorderRadius.circular(20),
    ),
    child: const Row(
      children: [
        CircleAvatar(
          radius: 22,
          backgroundColor: Color(0xFF1E8E53),
          child: Icon(Icons.check_rounded, color: Colors.white, size: 26),
        ),
        SizedBox(width: 13),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Sensor feed connected',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFFB4F0C8),
                ),
              ),
              SizedBox(height: 4),
              Text(
                'No fall candidate is currently reported.',
                style: TextStyle(fontSize: 13, color: Color(0xFF9BD8AE)),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _AlertCard extends StatelessWidget {
  const _AlertCard({
    required this.time,
    required this.onDismiss,
    required this.onEmergencyContact,
    required this.onMap,
  });
  final DateTime time;
  final VoidCallback onDismiss;
  final VoidCallback onEmergencyContact;
  final VoidCallback onMap;
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: const Color(0xFFFFE6E3),
      border: Border.all(color: const Color(0xFFE08A83), width: 2),
      borderRadius: BorderRadius.circular(15),
    ),
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              CircleAvatar(
                radius: 25,
                backgroundColor: Color(0xFFB42318),
                child: FallSlipIcon(size: 32, color: Colors.white),
              ),
              SizedBox(width: 13),
              Text(
                'FALL CANDIDATE',
                style: TextStyle(
                  fontSize: 23,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFB42318),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Time: ${_formatTime(time)}',
            style: const TextStyle(color: Color(0xFF2F241C), fontSize: 17),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: onEmergencyContact,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFB42318),
              ),
              child: const Text('Emergency Contact'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onMap,
              icon: const Icon(Icons.map_outlined),
              label: const Text('View map'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: onDismiss,
              child: const Text('Dismiss alert'),
            ),
          ),
        ],
      ),
    ),
  );
}

class _HistoryView extends StatelessWidget {
  const _HistoryView({required this.events});
  final List<VestReading> events;
  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      Text(
        'Event History',
        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.bold,
          color: const Color(0xFF202124),
        ),
      ),
      const SizedBox(height: 8),
      const Text(
        'Recent vest activity',
        style: TextStyle(fontSize: 16, color: Color(0xFF687076)),
      ),
      const SizedBox(height: 20),
    ];
    if (events.isEmpty) {
      children.add(
        const Card(
          child: Padding(
            padding: EdgeInsets.all(22),
            child: Text(
              'No events recorded yet.',
              style: TextStyle(fontSize: 18),
            ),
          ),
        ),
      );
    } else {
      children.addAll(
        events.map(
          (event) => Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: ListTile(
              leading: const CircleAvatar(
                backgroundColor: Color(0xFFFFE6E3),
                child: FallSlipIcon(size: 22, color: Color(0xFFB42318)),
              ),
              title: const Text(
                'Fall Detected',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
              ),
              subtitle: Text(_formatDate(event.timestamp)),
              trailing: const Text(
                'Alert',
                style: TextStyle(
                  color: Color(0xFFB42318),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 24),
      children: children,
    );
  }
}

class _DeviceView extends StatefulWidget {
  const _DeviceView({
    required this.reading,
    required this.profileName,
    required this.connectionMode,
    required this.gatewayAddress,
    required this.connectedDeviceCount,
    required this.gatewayConnecting,
    required this.gatewayReachable,
    required this.gatewayError,
    required this.bluetoothDevices,
    required this.bluetoothDeviceId,
    required this.bluetoothDeviceName,
    required this.bluetoothError,
    required this.bluetoothScanning,
    required this.bluetoothConnecting,
    required this.onConnect,
    required this.onDisconnect,
    required this.onConnectionModeChanged,
    required this.onBluetoothScan,
    required this.onBluetoothStopScan,
    required this.onBluetoothConnect,
    required this.onBluetoothDisconnect,
  });

  final VestReading reading;
  final String profileName;
  final String connectionMode;
  final String? gatewayAddress;
  final int? connectedDeviceCount;
  final bool gatewayConnecting;
  final bool gatewayReachable;
  final String? gatewayError;
  final List<BleDevice> bluetoothDevices;
  final String? bluetoothDeviceId;
  final String? bluetoothDeviceName;
  final String? bluetoothError;
  final bool bluetoothScanning;
  final bool bluetoothConnecting;
  final ValueChanged<String> onConnect;
  final VoidCallback onDisconnect;
  final ValueChanged<String> onConnectionModeChanged;
  final VoidCallback onBluetoothScan;
  final VoidCallback onBluetoothStopScan;
  final ValueChanged<BleDevice> onBluetoothConnect;
  final VoidCallback onBluetoothDisconnect;

  @override
  State<_DeviceView> createState() => _DeviceViewState();
}

class _DeviceViewState extends State<_DeviceView> {
  late final TextEditingController _addressController;

  @override
  void initState() {
    super.initState();
    _addressController = TextEditingController(
      text: widget.gatewayAddress ?? '',
    );
  }

  @override
  void didUpdateWidget(covariant _DeviceView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gatewayAddress != widget.gatewayAddress &&
        widget.gatewayAddress != null) {
      _addressController.text = widget.gatewayAddress!;
    }
  }

  @override
  void dispose() {
    _addressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(20, 22, 20, 24),
    children: [
      Text(
        'Vest Device',
        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.bold,
          color: const Color(0xFF202124),
        ),
      ),
      const SizedBox(height: 20),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: 'wifi',
                icon: Icon(Icons.wifi_rounded),
                label: Text('Wi-Fi'),
              ),
              ButtonSegment(
                value: 'bluetooth',
                icon: Icon(Icons.bluetooth_rounded),
                label: Text('Bluetooth'),
              ),
            ],
            selected: {widget.connectionMode},
            onSelectionChanged: widget.bluetoothConnecting
                ? null
                : (selection) =>
                      widget.onConnectionModeChanged(selection.first),
          ),
        ),
      ),
      const SizedBox(height: 14),
      if (widget.connectionMode == 'wifi')
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Gateway connection',
                  style: TextStyle(
                    color: Color(0xFF202124),
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Enter the computer IP running the vest gateway.',
                  style: TextStyle(color: Color(0xFF687076)),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _addressController,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.go,
                  onSubmitted: widget.onConnect,
                  decoration: const InputDecoration(
                    labelText: 'Gateway IP address',
                    hintText: '192.168.1.25',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.lan_outlined),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: widget.gatewayConnecting
                        ? null
                        : () => widget.onConnect(_addressController.text),
                    icon: widget.gatewayConnecting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.link_rounded),
                    label: Text(
                      widget.gatewayConnecting ? 'Connecting…' : 'Connect',
                    ),
                  ),
                ),
                if (widget.gatewayReachable) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: widget.onDisconnect,
                      child: const Text('Disconnect'),
                    ),
                  ),
                ],
                if (widget.gatewayError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    widget.gatewayError!,
                    style: const TextStyle(color: Color(0xFFB42318)),
                  ),
                ],
              ],
            ),
          ),
        ),
      if (widget.connectionMode == 'wifi') const SizedBox(height: 14),
      if (widget.connectionMode == 'wifi')
        Card(
          child: Column(
            children: [
              _DeviceRow(
                icon: Icons.devices_rounded,
                label: 'Phones connected',
                value:
                    widget.gatewayReachable &&
                        widget.connectedDeviceCount != null
                    ? '${widget.connectedDeviceCount}'
                    : 'Unavailable',
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                child: Text(
                  widget.gatewayReachable
                      ? 'Counts app installations reporting to this gateway in the last 30 seconds; it is not a count of vest sensors.'
                      : 'Connect to the gateway to see how many phones are currently reporting.',
                  style: const TextStyle(color: Color(0xFF687076), height: 1.4),
                ),
              ),
              _DeviceRow(
                icon: Icons.person_outline_rounded,
                label: 'Connection name',
                value: widget.profileName,
              ),
              _DeviceRow(
                icon: Icons.sensors_outlined,
                label: 'Vest sensor',
                value: widget.reading.connected ? 'Connected' : 'Disconnected',
              ),
              _DeviceRow(
                icon: Icons.battery_6_bar,
                label: 'Battery',
                value: widget.reading.battery == null
                    ? 'Unavailable'
                    : '${widget.reading.battery}%',
              ),
              _DeviceRow(
                icon: Icons.location_on_outlined,
                label: 'Location',
                value: widget.reading.location,
              ),
              _DeviceRow(
                icon: Icons.shield_outlined,
                label: 'Vest status',
                value: widget.reading.vestStatus,
              ),
            ],
          ),
        ),
      if (widget.connectionMode == 'bluetooth') ...[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'ESP32 Bluetooth connection',
                  style: TextStyle(
                    color: Color(0xFF202124),
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Scan nearby devices and connect directly to a supported vest.',
                  style: TextStyle(color: Color(0xFF687076)),
                ),
                const SizedBox(height: 14),
                if (widget.bluetoothDeviceId != null) ...[
                  _DeviceRow(
                    icon: Icons.bluetooth_connected_rounded,
                    label: 'Connected vest',
                    value: widget.bluetoothDeviceName ?? 'ESP32 Vest',
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: widget.onBluetoothDisconnect,
                      icon: const Icon(Icons.link_off_rounded),
                      label: const Text('Disconnect'),
                    ),
                  ),
                ] else ...[
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed:
                          widget.bluetoothScanning || widget.bluetoothConnecting
                          ? null
                          : widget.onBluetoothScan,
                      icon: widget.bluetoothConnecting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.bluetooth_searching_rounded),
                      label: Text(
                        widget.bluetoothConnecting
                            ? 'Connecting…'
                            : 'Scan for vest',
                      ),
                    ),
                  ),
                  if (widget.bluetoothScanning) ...[
                    const SizedBox(height: 10),
                    const LinearProgressIndicator(),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: widget.onBluetoothStopScan,
                        child: const Text('Stop scan'),
                      ),
                    ),
                  ],
                  if (widget.bluetoothDevices.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    ...widget.bluetoothDevices.map(
                      (device) => ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.bluetooth_rounded),
                        title: Text(
                          device.name?.isNotEmpty == true
                              ? device.name!
                              : 'ESP32 Vest',
                        ),
                        subtitle: Text(
                          device.rssi == null
                              ? 'Tap to connect'
                              : 'Signal ${device.rssi} dBm · tap to connect',
                        ),
                        onTap: widget.bluetoothConnecting
                            ? null
                            : () => widget.onBluetoothConnect(device),
                      ),
                    ),
                  ] else if (!widget.bluetoothScanning) ...[
                    const SizedBox(height: 10),
                    const Text(
                      'No vest found yet. Keep it powered on and nearby, then scan again.',
                      style: TextStyle(color: Color(0xFF687076), height: 1.4),
                    ),
                  ],
                ],
                if (widget.bluetoothError != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    widget.bluetoothError!,
                    style: const TextStyle(color: Color(0xFFB42318)),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        Card(
          child: Column(
            children: [
              _DeviceRow(
                icon: Icons.sensors_outlined,
                label: 'Vest sensor',
                value: widget.reading.connected ? 'Connected' : 'Disconnected',
              ),
              _DeviceRow(
                icon: Icons.battery_6_bar,
                label: 'Battery',
                value: widget.reading.battery == null
                    ? 'Unavailable'
                    : '${widget.reading.battery}%',
              ),
              _DeviceRow(
                icon: Icons.shield_outlined,
                label: 'Detector status',
                value: widget.reading.vestStatus,
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Text(
                  'Bluetooth sends experimental fall-candidate status only. Battery, location, and inflation status are not available over this connection. The detector is not clinically validated and does not activate the vest.',
                  style: TextStyle(color: Color(0xFF687076), height: 1.4),
                ),
              ),
            ],
          ),
        ),
      ],
    ],
  );
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label, value;
  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
    title: Text(label, style: const TextStyle(color: Color(0xFF687076))),
    trailing: Text(
      value,
      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
    ),
  );
}

class _SettingsView extends StatelessWidget {
  const _SettingsView({
    required this.profileName,
    required this.eventCount,
    required this.accountLabel,
    required this.accountEmail,
    required this.caregiverAccess,
    required this.firebaseAvailable,
    required this.locationEnabled,
    required this.notificationsEnabled,
    required this.gatewayAddress,
    required this.connectedDeviceCount,
    required this.gatewayReachable,
    required this.onOpenAccount,
    required this.onOpenAssistant,
    required this.onNotificationsChanged,
    required this.onOpenDeviceSettings,
    required this.onEditConnectionName,
    required this.onLocationChanged,
    required this.onClearEventHistory,
    required this.onTextScaleChanged,
  });
  final String profileName;
  final int eventCount;
  final String accountLabel;
  final String accountEmail;
  final bool caregiverAccess;
  final bool firebaseAvailable;
  final bool locationEnabled;
  final bool notificationsEnabled;
  final String? gatewayAddress;
  final int? connectedDeviceCount;
  final bool gatewayReachable;
  final VoidCallback onOpenAccount;
  final VoidCallback onOpenAssistant;
  final ValueChanged<bool> onNotificationsChanged;
  final VoidCallback onOpenDeviceSettings;
  final VoidCallback onEditConnectionName;
  final ValueChanged<bool> onLocationChanged;
  final VoidCallback onClearEventHistory;
  final ValueChanged<double> onTextScaleChanged;

  @override
  Widget build(BuildContext context) {
    final connectionSummary = gatewayReachable && connectedDeviceCount != null
        ? '$connectedDeviceCount phones active in the last 30 seconds'
        : gatewayAddress == null
        ? 'Gateway not set up'
        : 'Gateway offline or unavailable';
    final primary = Theme.of(context).colorScheme.primary;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
      children: [
        Text(
          'Settings',
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w800,
            color: const Color(0xFF202124),
            letterSpacing: -0.6,
          ),
        ),
        const SizedBox(height: 5),
        const Text(
          'Personalize your companion app.',
          style: TextStyle(color: Color(0xFF687076), fontSize: 14),
        ),
        const SizedBox(height: 18),
        Card(
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 17,
              vertical: 7,
            ),
            leading: CircleAvatar(
              radius: 24,
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              child: Icon(
                caregiverAccess
                    ? Icons.verified_user_rounded
                    : Icons.person_add_alt_1_rounded,
                color: primary,
              ),
            ),
            title: Text(
              caregiverAccess
                  ? 'Verified account'
                  : firebaseAvailable
                  ? 'Log in or create account'
                  : 'Guest testing mode',
              style: const TextStyle(
                color: Color(0xFF202124),
                fontWeight: FontWeight.w700,
              ),
            ),
            subtitle: Text(
              caregiverAccess ? '$accountEmail · email verified' : accountLabel,
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: onOpenAccount,
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 17,
              vertical: 7,
            ),
            leading: CircleAvatar(
              radius: 24,
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              child: Icon(Icons.person_outline_rounded, color: primary),
            ),
            title: Text(
              profileName == 'Guest' ? 'Guest profile' : profileName,
              style: const TextStyle(
                color: Color(0xFF202124),
                fontWeight: FontWeight.w700,
              ),
            ),
            subtitle: const Text('Connection name · saved only on this phone'),
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFFF0F2EF),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                'LOCAL',
                style: TextStyle(
                  color: Color(0xFF687076),
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        OutlinedButton.icon(
          onPressed: onEditConnectionName,
          icon: const Icon(Icons.edit_outlined),
          label: const Text('Set connection name'),
        ),
        const SizedBox(height: 22),
        const Text(
          'Vest connection',
          style: TextStyle(
            color: Color(0xFF202124),
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: ListTile(
            leading: Icon(Icons.phone_iphone_outlined, color: primary),
            title: const Text(
              'Vest and connected phones',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(connectionSummary),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: onOpenDeviceSettings,
          ),
        ),
        const SizedBox(height: 14),
        Material(
          color: const Color(0xFF1F3028),
          borderRadius: BorderRadius.circular(20),
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const HelpAndSafetyPage(),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.play_circle_outline_rounded,
                      color: Color(0xFFFFC56A),
                    ),
                  ),
                  const SizedBox(width: 13),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Help & safety',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Setup tips and a 20-second animated guide',
                          style: TextStyle(
                            color: Color(0xFFD0D8D3),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(
                    Icons.arrow_forward_rounded,
                    color: Colors.white70,
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: Icon(Icons.tune_rounded, color: primary),
            title: const Text(
              'Hospital-informed preferences',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: const Text(
              'Choose alert, battery, readiness, and vest preferences.',
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const CarePreferencesPage(),
              ),
            ),
          ),
        ),
        const SizedBox(height: 22),
        const Text(
          'Notifications',
          style: TextStyle(
            color: Color(0xFF202124),
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              SwitchListTile(
                secondary: Icon(Icons.notifications_outlined, color: primary),
                title: const Text('System notifications'),
                subtitle: const Text(_notificationDescription),
                value: notificationsEnabled,
                onChanged: onNotificationsChanged,
                activeThumbColor: primary,
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: Icon(Icons.contact_phone_outlined, color: primary),
                title: const Text('Emergency contacts'),
                subtitle: const Text(
                  'Saved on this device only; no calls or messages are sent.',
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => showEmergencyContactsSheet(context),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        const Text(
          'Accessibility',
          style: TextStyle(
            color: Color(0xFF202124),
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              ValueListenableBuilder<double>(
                valueListenable: appTextScale,
                builder: (context, textScale, _) => Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.text_fields_rounded, color: primary),
                          const SizedBox(width: 16),
                          const Expanded(
                            child: Text(
                              'Text size',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                          Text('${(textScale * 100).round()}%'),
                        ],
                      ),
                      Slider(
                        value: textScale,
                        min: 0.9,
                        max: 1.3,
                        divisions: 4,
                        label: '${(textScale * 100).round()}%',
                        onChanged: onTextScaleChanged,
                      ),
                      const Text(
                        'Adjust text throughout the app.',
                        style: TextStyle(color: Color(0xFF687076)),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        const Text(
          'Location',
          style: TextStyle(
            color: Color(0xFF202124),
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              SwitchListTile(
                secondary: Icon(Icons.location_on_outlined, color: primary),
                title: const Text(
                  'Phone location',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  locationEnabled
                      ? 'Center the map on your current location'
                      : 'Location sharing is off',
                ),
                value: locationEnabled,
                onChanged: onLocationChanged,
                activeThumbColor: primary,
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: Icon(Icons.delete_outline_rounded, color: primary),
                title: const Text('Clear event history'),
                subtitle: const Text('Remove saved events from this phone.'),
                enabled: eventCount > 0,
                onTap: eventCount > 0 ? onClearEventHistory : null,
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        const Text(
          'About & support',
          style: TextStyle(
            color: Color(0xFF202124),
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: Icon(Icons.info_outline_rounded, color: primary),
                title: const Text('InflateBody Safety Companion'),
                subtitle: const Text('Version $_appVersion · Prototype'),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: Icon(Icons.support_agent_outlined, color: primary),
                title: const Text('Support & feedback'),
                subtitle: const Text(
                  'No support or feedback contact is configured in this build.',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        const Center(
          child: Text(
            'InflateBody · Safety companion prototype',
            style: TextStyle(color: Color(0xFF687076), fontSize: 12),
          ),
        ),
      ],
    );
  }
}

class _MapView extends StatefulWidget {
  const _MapView({
    required this.reading,
    required this.phonePosition,
    required this.lastPhonePoint,
    required this.locationEnabled,
    required this.showDirectionsOnOpen,
    required this.onDirectionsRequestHandled,
    required this.onFindVest,
  });
  final VestReading reading;
  final Position? phonePosition;
  final LatLng? lastPhonePoint;
  final bool locationEnabled;
  final bool showDirectionsOnOpen;
  final VoidCallback onDirectionsRequestHandled;
  final VoidCallback onFindVest;

  @override
  State<_MapView> createState() => _MapViewState();
}

class _MapViewState extends State<_MapView> {
  final _mapController = MapController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _showRequestedDirections();
    });
  }

  @override
  void didUpdateWidget(covariant _MapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.showDirectionsOnOpen && widget.showDirectionsOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showRequestedDirections();
      });
    }
    final oldPosition = oldWidget.phonePosition;
    final newPosition = widget.phonePosition;
    if (oldPosition == null && newPosition != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _mapController.move(_caregiverPoint, 14.2);
      });
    }
    final moved =
        oldPosition == null ||
        newPosition == null ||
        Geolocator.distanceBetween(
              oldPosition.latitude,
              oldPosition.longitude,
              newPosition.latitude,
              newPosition.longitude,
            ) >
            25;
    if (moved && newPosition != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _mapController.move(_caregiverPoint, 14.2);
      });
    } else if (oldWidget.reading.latitude != widget.reading.latitude ||
        oldWidget.reading.longitude != widget.reading.longitude) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_isDemo) _mapController.move(_vestPoint, 14.2);
      });
    }
  }

  void _showDirections(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _isDemo ? 'Preview directions' : 'Directions to vest',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                _isDemo
                    ? 'This opens a sample destination for testing only. It is not the vest’s real location.'
                    : 'Choose an app for turn-by-turn directions. The selected app receives the vest’s live GPS destination.',
                style: TextStyle(color: Color(0xFF687076), height: 1.4),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _openMapApp(sheetContext, apple: true),
                      icon: const Icon(Icons.map_outlined),
                      label: Text(
                        _isDemo ? 'Preview Apple Maps' : 'Open Apple Maps',
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _openMapApp(sheetContext, apple: false),
                      icon: const Icon(Icons.navigation_outlined),
                      label: Text(
                        _isDemo ? 'Preview Google Maps' : 'Open Google Maps',
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showRequestedDirections() {
    if (!widget.showDirectionsOnOpen) return;
    _showDirections(context);
    widget.onDirectionsRequestHandled();
  }

  Future<void> _openMapApp(BuildContext context, {required bool apple}) async {
    final point = _vestPoint;
    final uri = apple
        ? Uri.parse(
            'https://maps.apple.com/?daddr=${point.latitude},${point.longitude}&dirflg=d',
          )
        : Uri.parse(
            'https://www.google.com/maps/dir/?api=1&destination=${point.latitude},${point.longitude}&travelmode=driving',
          );
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (context.mounted) {
      if (!opened) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open the map app.')),
        );
      } else {
        Navigator.pop(context);
      }
    }
  }

  void _showVestDetails(BuildContext context) {
    final reading = widget.reading;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _isDemo
                    ? 'Demo location'
                    : reading.fallDetected
                    ? 'Fall alert'
                    : 'Vest location',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              _MapDetailRow('Time', _formatDate(reading.timestamp)),
              _MapDetailRow(
                'Battery',
                reading.battery == null
                    ? 'Not reported'
                    : '${reading.battery}%',
              ),
              _MapDetailRow('Vest status', reading.vestStatus),
              _MapDetailRow(
                'Location',
                _isDemo ? 'No live GPS report' : reading.location,
              ),
              if (!_isDemo &&
                  reading.latitude != null &&
                  reading.longitude != null)
                _MapDetailRow(
                  'Coordinates',
                  '${reading.latitude!.toStringAsFixed(5)}, ${reading.longitude!.toStringAsFixed(5)}',
                ),
              if (_isDemo)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF4E5),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Text(
                      'Real directions need live vest GPS. You can preview the sample route below, but it is not the vest’s real location.',
                      style: TextStyle(
                        color: Color(0xFF8A5500),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              if (_isDemo)
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.of(context).pop();
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) _showDirections(this.context);
                          });
                        },
                        icon: const Icon(Icons.navigation_outlined),
                        label: const Text('Preview directions'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () {
                          Navigator.of(context).pop();
                          widget.onFindVest();
                        },
                        icon: const Icon(Icons.my_location_rounded),
                        label: const Text('Request location'),
                      ),
                    ),
                  ],
                )
              else
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) _showDirections(this.context);
                      });
                    },
                    icon: const Icon(Icons.navigation_rounded),
                    label: const Text('Directions'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  bool get _isDemo =>
      widget.reading.latitude == null ||
      widget.reading.longitude == null ||
      widget.reading.location == 'Test location' ||
      widget.reading.location == 'Vest Location Received';

  LatLng get _vestPoint => LatLng(
    widget.reading.latitude ?? 37.7749,
    widget.reading.longitude ?? -122.4194,
  );

  LatLng get _caregiverPoint => widget.phonePosition != null
      ? LatLng(widget.phonePosition!.latitude, widget.phonePosition!.longitude)
      : widget.lastPhonePoint ?? _vestPoint;

  bool get _hasPhoneGps => widget.phonePosition != null;
  bool get _hasLastPhonePoint =>
      widget.phonePosition != null || widget.lastPhonePoint != null;

  @override
  Widget build(BuildContext context) {
    final vestPoint = _vestPoint;
    final caregiverPoint = _caregiverPoint;
    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: caregiverPoint,
            initialZoom: _hasLastPhonePoint ? 14.2 : 12.8,
            minZoom: 4,
            maxZoom: 18,
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.phongtruong.fallprotectionvest',
              panBuffer: 2,
              keepBuffer: 3,
              maxNativeZoom: 18,
              maxZoom: 18,
            ),
            MarkerLayer(
              markers: [
                if (_hasLastPhonePoint)
                  Marker(
                    point: caregiverPoint,
                    width: 54,
                    height: 54,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 3),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x33000000),
                            blurRadius: 8,
                            offset: Offset(0, 3),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.person_rounded,
                        color: Colors.white,
                      ),
                    ),
                  ),
                Marker(
                  point: vestPoint,
                  width: 62,
                  height: 70,
                  child: GestureDetector(
                    onTap: () => _showVestDetails(context),
                    child: VestLocationMarker(
                      color: _isDemo
                          ? const Color(0xFF9A5A00)
                          : const Color(0xFFB42318),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        Positioned(
          top: 14,
          left: 16,
          right: 16,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: const Color(0xFFE7EAE6)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x1A000000),
                  blurRadius: 18,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0F2EF),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const VestIcon(size: 25, color: Color(0xFF111214)),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _hasLastPhonePoint ? 'YOUR LOCATION' : 'MAP',
                              style: const TextStyle(
                                color: Color(0xFF687076),
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.9,
                              ),
                            ),
                          ),
                          _MapStatusBadge(
                            label: _isDemo ? 'VEST DEMO' : 'LIVE VEST GPS',
                            warning: _isDemo,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _hasPhoneGps
                            ? 'Your location'
                            : _hasLastPhonePoint
                            ? 'Last known position'
                            : 'Waiting for location',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF202124),
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _isDemo
                            ? 'No live vest coordinates received'
                            : _hasPhoneGps
                            ? 'Using phone GPS'
                            : _hasLastPhonePoint && !widget.locationEnabled
                            ? 'Location sharing paused'
                            : widget.reading.location,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF687076),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  onPressed: widget.onFindVest,
                  icon: const Icon(Icons.my_location_rounded, size: 17),
                  label: const Text('Find'),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          right: 16,
          bottom: 174,
          child: FloatingActionButton.small(
            heroTag: 'recenter-map',
            backgroundColor: Colors.white,
            foregroundColor: Theme.of(context).colorScheme.primary,
            onPressed: () => _mapController.move(caregiverPoint, 13.5),
            tooltip: 'Recenter map',
            child: const Icon(Icons.my_location),
          ),
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 16,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: const Color(0xFFE7EAE6)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x1A000000),
                  blurRadius: 18,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _isDemo ? 'DEMO DIRECTIONS' : 'DIRECTIONS',
                        style: const TextStyle(
                          color: Color(0xFF687076),
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.9,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        _isDemo
                            ? 'Preview a sample route'
                            : 'Ready to navigate',
                        style: const TextStyle(
                          color: Color(0xFF202124),
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _isDemo
                            ? 'Open Apple Maps or Google Maps with the sample location.'
                            : 'Choose Apple Maps or Google Maps for turn-by-turn directions.',
                        style: const TextStyle(
                          color: Color(0xFF687076),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  onPressed: () => _showDirections(context),
                  icon: Icon(
                    _isDemo ? Icons.map_outlined : Icons.navigation_rounded,
                    size: 18,
                  ),
                  label: Text(
                    _isDemo ? 'Preview directions' : 'Get directions',
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _MapStatusBadge extends StatelessWidget {
  const _MapStatusBadge({required this.label, required this.warning});

  final String label;
  final bool warning;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
    decoration: BoxDecoration(
      color: warning ? const Color(0xFF30250F) : const Color(0xFF173321),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: warning ? const Color(0xFFF4D28C) : const Color(0xFF9BD8AE),
        fontSize: 9,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.4,
      ),
    ),
  );
}

class _MapDetailRow extends StatelessWidget {
  const _MapDetailRow(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 105,
          child: Text(label, style: const TextStyle(color: Color(0xFF687076))),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}

/// A small, recognisable vest symbol used instead of a phone/device icon.
class VestIcon extends StatelessWidget {
  const VestIcon({super.key, this.size = 24, this.color, this.filled = false});

  final double size;
  final Color? color;
  final bool filled;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Vest',
    child: CustomPaint(
      size: Size.square(size),
      painter: _VestIconPainter(
        color: color ?? const Color(0xFF111214),
        filled: filled,
      ),
    ),
  );
}

class _VestIconPainter extends CustomPainter {
  const _VestIconPainter({required this.color, required this.filled});

  final Color color;
  final bool filled;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.075
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()
      ..color = color.withValues(alpha: 0.16)
      ..style = PaintingStyle.fill;
    final path = ui.Path()
      ..moveTo(size.width * .28, size.height * .09)
      ..lineTo(size.width * .42, size.height * .13)
      ..cubicTo(
        size.width * .44,
        size.height * .25,
        size.width * .48,
        size.height * .30,
        size.width * .50,
        size.height * .30,
      )
      ..cubicTo(
        size.width * .52,
        size.height * .30,
        size.width * .56,
        size.height * .25,
        size.width * .58,
        size.height * .13,
      )
      ..lineTo(size.width * .72, size.height * .09)
      ..lineTo(size.width * .88, size.height * .20)
      ..lineTo(size.width * .80, size.height * .47)
      ..lineTo(size.width * .83, size.height * .90)
      ..quadraticBezierTo(
        size.width * .50,
        size.height * .96,
        size.width * .17,
        size.height * .90,
      )
      ..lineTo(size.width * .20, size.height * .47)
      ..lineTo(size.width * .12, size.height * .20)
      ..close();
    if (filled) canvas.drawPath(path, fill);
    canvas.drawPath(path, stroke);
    canvas.drawLine(
      Offset(size.width * .50, size.height * .30),
      Offset(size.width * .50, size.height * .91),
      stroke,
    );
    for (final y in [.59, .77]) {
      canvas.drawLine(
        Offset(size.width * .19, size.height * y),
        Offset(size.width * .43, size.height * y),
        stroke,
      );
      canvas.drawLine(
        Offset(size.width * .57, size.height * y),
        Offset(size.width * .81, size.height * y),
        stroke,
      );
    }
  }

  @override
  bool shouldRepaint(_VestIconPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.filled != filled;
}

/// A simple slip/fall visual, reserved for fall alerts and fall history.
class FallSlipIcon extends StatelessWidget {
  const FallSlipIcon({super.key, this.size = 28, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Person falling',
    child: SizedBox.square(
      dimension: size,
      child: CustomPaint(
        size: Size.square(size),
        painter: _FallSlipIconPainter(color),
      ),
    ),
  );
}

class _FallSlipIconPainter extends CustomPainter {
  const _FallSlipIconPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final figure = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * .16
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    Offset point(double x, double y) => Offset(size.width * x, size.height * y);

    final impact = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * .055
      ..strokeCap = StrokeCap.round;
    for (final (start, end) in [
      ((.30, .84), (.43, .90)),
      ((.27, .91), (.42, .93)),
      ((.32, .97), (.45, .96)),
      ((.70, .84), (.57, .90)),
      ((.73, .91), (.58, .93)),
      ((.68, .97), (.55, .96)),
    ]) {
      canvas.drawLine(point(start.$1, start.$2), point(end.$1, end.$2), impact);
    }

    final legs = ui.Path()
      ..moveTo(size.width * .52, size.height * .68)
      ..lineTo(size.width * .37, size.height * .46)
      ..lineTo(size.width * .15, size.height * .42)
      ..moveTo(size.width * .51, size.height * .70)
      ..lineTo(size.width * .30, size.height * .60)
      ..lineTo(size.width * .11, size.height * .78);
    canvas.drawPath(legs, figure);

    final arms = ui.Path()
      ..moveTo(size.width * .63, size.height * .44)
      ..lineTo(size.width * .52, size.height * .29)
      ..lineTo(size.width * .53, size.height * .11)
      ..moveTo(size.width * .65, size.height * .46)
      ..lineTo(size.width * .79, size.height * .64)
      ..lineTo(size.width * .79, size.height * .85);
    canvas.drawPath(arms, figure);

    final torso = ui.Path()
      ..moveTo(size.width * .65, size.height * .43)
      ..lineTo(size.width * .56, size.height * .56)
      ..lineTo(size.width * .50, size.height * .69);
    canvas.drawPath(torso, figure..strokeWidth = size.width * .21);
    canvas.drawCircle(
      point(.78, .31),
      size.width * .11,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_FallSlipIconPainter oldDelegate) =>
      oldDelegate.color != color;
}

class VestLocationMarker extends StatelessWidget {
  const VestLocationMarker({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 62,
    height: 70,
    child: Stack(
      alignment: Alignment.topCenter,
      children: [
        CustomPaint(size: const Size(62, 70), painter: _VestPinPainter(color)),
        const Positioned(
          top: 12,
          child: VestIcon(size: 31, color: Colors.white),
        ),
      ],
    ),
  );
}

class _VestPinPainter extends CustomPainter {
  const _VestPinPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = ui.Path()
      ..moveTo(size.width / 2, size.height)
      ..cubicTo(0, size.height * .63, 2, 0, size.width / 2, 0)
      ..cubicTo(
        size.width - 2,
        0,
        size.width,
        size.height * .63,
        size.width / 2,
        size.height,
      )
      ..close();
    canvas.drawShadow(path, const Color(0x4D000000), 5, false);
    canvas.drawPath(path, Paint()..color = color);
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_VestPinPainter oldDelegate) => oldDelegate.color != color;
}

String _formatTime(DateTime value) {
  final hour = value.hour == 0
      ? 12
      : value.hour > 12
      ? value.hour - 12
      : value.hour;
  final minute = value.minute.toString().padLeft(2, '0');
  return '$hour:$minute ${value.hour >= 12 ? 'PM' : 'AM'}';
}

String _formatDate(DateTime value) =>
    '${value.month}/${value.day}/${value.year} at ${_formatTime(value)}';
