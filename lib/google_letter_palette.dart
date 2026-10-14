import 'package:flutter/material.dart';

/// Four letter colors sampled from the user's supplied Google logo JPEG.
/// The photo's gray background is intentionally NOT adopted.
/// These are JPEG pixel colors (compression means tiny pixel variation).
abstract final class GoogleLetterPalette {
  static const blue = Color(0xFF8BB4F6);
  static const red = Color(0xFFD7523F);
  static const yellow = Color(0xFFF1BF42);
  static const green = Color(0xFF5AA55D);
  static const ink = Color(0xFF221A1B); // Existing app neutral, not logo gray.
  static const surface = Color(0xFF352729);
  static const dimSurface = Color(0xFF372825);
}
