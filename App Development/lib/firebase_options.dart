// Placeholder used by the public web demo.
//
// This repository does not include the Firebase project configuration. Run
// `flutterfire configure` in a private development copy to replace this file
// with the generated configuration before enabling Firebase features.
import 'package:firebase_core/firebase_core.dart';

abstract final class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform => throw UnsupportedError(
    'Firebase is not configured in the public demo. '
    'Run flutterfire configure in your private app copy.',
  );
}
