import 'package:flutter/material.dart';

/// Every color used in the app lives here. Change a value once and it
/// updates everywhere - screens must not use `Colors.*` or raw hex values.
abstract final class AppColors {
  // Brand blue
  static const primary = Color(0xFF1E5EFF);
  static const primaryDark = Color(0xFF0A3DCC);
  static const primaryLight = Color(0xFF5B8CFF);
  static const primarySoft = Color(0xFFEAF0FF);
  static const onPrimary = Color(0xFFFFFFFF);

  // Surfaces
  static const background = Color(0xFFF5F8FF);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceMuted = Color(0xFFF0F4FC);
  static const border = Color(0xFFE2E8F5);
  static const divider = Color(0xFFEDF1F9);

  // Text
  static const textPrimary = Color(0xFF0F1B3D);
  static const textSecondary = Color(0xFF5B6B8C);
  static const textMuted = Color(0xFF94A3C0);

  // Status
  static const success = Color(0xFF12B76A);
  static const successSoft = Color(0xFFE7F8EF);
  static const warning = Color(0xFFF59E0B);
  static const warningSoft = Color(0xFFFEF4E2);
  static const error = Color(0xFFE5484D);
  static const errorSoft = Color(0xFFFDECEC);
  static const neutral = Color(0xFF64748B);
  static const neutralSoft = Color(0xFFEFF2F7);

  // Camera / scanner overlay
  static const scannerBackground = Color(0xFF000000);
  static const scannerOverlay = Color(0x99000000);
  static const scannerFrame = Color(0xFFFFFFFF);
  static const scannerText = Color(0xFFFFFFFF);

  // Misc
  static const transparent = Color(0x00000000);
  static const snackBar = Color(0xFF0F1B3D);
  static const shadow = Color(0x141E5EFF);

  static const primaryGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [primary, primaryDark],
  );
}
