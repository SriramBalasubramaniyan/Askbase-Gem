/// API Configuration
/// ─────────────────────────────────────────────────────────────────────────────
/// The Gemini API key is entered by the user at first launch (see
/// ApiKeyScreen) and stored on-device via shared_preferences — it is not
/// hardcoded here. Get a free key at: https://aistudio.google.com/app/apikey
/// ─────────────────────────────────────────────────────────────────────────────

class ApiConfig {
  /// Base URL for the Gemini Developer API (free-tier endpoint — no billing
  /// account required, generous free daily quota).
  static const String geminiBaseUrl =
      'https://generativelanguage.googleapis.com/v1beta';

  /// Model used for SQL generation. gemini-flash-lite-latest always points
  /// to the newest Flash-Lite model — the lowest-token-cost, highest-free-
  /// quota tier Gemini offers, which is all this single short-prompt call
  /// needs.
  static const String geminiModel = 'gemini-flash-lite-latest';

  /// Request timeout — generous for slow field connections.
  static const Duration requestTimeout = Duration(seconds: 30);
}
