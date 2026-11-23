import 'package:flutter/material.dart';

/// The single color system used across the companion app.
///
/// Keeping these values together prevents each screen from introducing a
/// slightly different cream, brown, or gray.
abstract final class AppColors {
  static const canvas = Color(0xFFFFF9F3);
  static const surface = Color(0xFFFFFCF8);
  static const surfaceSoft = Color(0xFFF7EDE1);
  static const border = Color(0xFFE7DCD0);
  static const ink = Color(0xFF2E241E);
  static const muted = Color(0xFF74685F);

  static const primary = Color(0xFF87551C);
  static const primaryDeep = Color(0xFF60380F);
  static const gold = Color(0xFFF0B35B);
  static const goldSoft = Color(0xFFFFE8C7);

  static const success = Color(0xFF1B7A4C);
  static const successSoft = Color(0xFFE6F4EB);
  static const danger = Color(0xFFBA3A2D);
  static const dangerSoft = Color(0xFFFDE9E6);
  static const info = Color(0xFF356F9F);
  static const infoSoft = Color(0xFFE6F0F8);

  static const monitoring = Color(0xFF26382E);
  static const monitoringMuted = Color(0xFFC3D0C7);
}
