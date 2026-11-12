import 'package:flutter/foundation.dart';

/// Native Sign in with Apple is supported for the iOS distribution path.
/// Developer ID apps on macOS must use the web/Services ID flow instead.
bool shouldUseNativeAppleLogin(
  TargetPlatform platform, {
  bool nativeMacOS = false,
}) {
  return platform == TargetPlatform.iOS ||
      (platform == TargetPlatform.macOS && nativeMacOS);
}
