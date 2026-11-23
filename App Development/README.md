# App Development

Flutter source for the InflateBody Fall Protection Vest companion-app prototype.

## What this prototype includes

- Home, Device, History, Map, and Settings screens
- Bluetooth pairing and a trusted-local-Wi-Fi gateway option
- Local fall-candidate alerts and on-device event history
- Map preview and external Apple Maps / Google Maps directions when live vest GPS is available
- Optional Firebase email sign-in and AI support chat

## Important scope

This is a student prototype, not a medical device or emergency service. A fall candidate is experimental and unvalidated. The app does not control vest inflation, deflation, reset hardware, emergency services, or caregiver messaging.

## Run locally

```bash
flutter pub get
flutter run
```

For an iPhone release build on the project Mac, use:

```bash
./run_iphone_release.sh
```

## Firebase setup

Firebase configuration is intentionally not included in this public folder. To enable Firebase Authentication or the AI assistant, create/select your own Firebase project and run:

```bash
dart pub global activate flutterfire_cli
flutterfire configure
```

Do not commit `GoogleService-Info.plist`, `google-services.json`, or `lib/firebase_options.dart` from a production Firebase project.

## Demo link

This is a native Flutter mobile app. A GitHub Pages website cannot provide Bluetooth, local notifications, iPhone signing, or live vest communication. Use the source above to run the app on an Android simulator/device, iPhone, macOS, or another supported Flutter target.
