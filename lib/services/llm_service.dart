import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/api_config.dart';
import '../models/db_schema_model.dart';

const _prefKeyApiKey = 'gemini_api_key';

class LlmService {
  LlmService._();
  static final LlmService instance = LlmService._();

  String? _apiKey;

  // ── API key management ───────────────────────────────────────────────────

  Future<bool> hasApiKey() async {
    final key = await _loadApiKey();
    return key != null && key.isNotEmpty;
  }

  Future<String?> _loadApiKey() async {
    if (_apiKey != null) return _apiKey;
    final prefs = await SharedPreferences.getInstance();
    _apiKey = prefs.getString(_prefKeyApiKey);
    return _apiKey;
  }

  Future<void> saveApiKey(String key) async {
    final trimmed = key.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKeyApiKey, trimmed);
    _apiKey = trimmed;
  }

  Future<void> clearApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefKeyApiKey);
    _apiKey = null;
  }

  // ── SQL Generation ────────────────────────────────────────────────────────

  /// [selectedTables] — pre-filtered by SchemaSelector, not the full schema.
  /// [schemaName] — used only in the system prompt header.
  ///
  /// [previousAttemptSql] / [previousError] — when set (on a retry after a
  /// failed attempt), the prompt switches from "write a query" to "fix this
  /// specific query, here's exactly why it failed". [previousError] may
  /// come from the deterministic column/table/enum-value validator
  /// (specific: "table X has no column Y, actual columns are..." / "column
  /// Z only allows these values..."), a ready-to-use join skeleton appended
  /// by QueryService when two tables in the query aren't directly related,
  /// or a real SQLite execution error.
  ///
  /// This is the only generation call in the pipeline — all result text is
  /// built directly from query rows in QueryService, with no model
  /// involvement.
  Future<String> generateSql({
    required String userQuestion,
    required List<TableSchema> selectedTables,
    required String schemaName,
    String? previousAttemptSql,
    String? previousError,
  }) async {
    final apiKey = await _loadApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      throw StateError('Gemini API key not set.');
    }

    final isRetry = previousAttemptSql != null &&
        previousAttemptSql.isNotEmpty &&
        previousError != null &&
        previousError.isNotEmpty;

    final userText = isRetry
        ? 'Question: $userQuestion\n\n'
            'Your previous SQL failed to run:\n$previousAttemptSql\n\n'
            'Error: $previousError\n\n'
            'Fix the query using the exact information in the error above. '
            'Use ONLY the exact table and column names listed in SCHEMA — '
            'do not invent or guess a name that isn\'t there. If the error '
            'gives you a join structure to use, copy it exactly as given — '
            'do not modify it. If no valid query is possible, output '
            'CANNOT_ANSWER.\n\nSQL:'
        : 'Question: $userQuestion\n\nSQL:';

    final uri = Uri.parse(
      '${ApiConfig.geminiBaseUrl}/models/${ApiConfig.geminiModel}:generateContent',
    );

    final body = jsonEncode({
      'system_instruction': {
        'parts': [
          {'text': _buildSqlSystemPrompt(selectedTables, schemaName)}
        ],
      },
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': userText}
          ],
        }
      ],
      'generationConfig': {
        'temperature': 0.1,
        'topK': 1,
        'maxOutputTokens': 300,
      },
    });

    http.Response response;
    try {
      response = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'x-goog-api-key': apiKey,
            },
            body: body,
          )
          .timeout(ApiConfig.requestTimeout);
    } catch (e) {
      throw StateError('Network error while contacting Gemini: $e');
    }

    if (response.statusCode != 200) {
      throw StateError(
        'Gemini API error (${response.statusCode}): ${response.body}',
      );
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final candidates = decoded['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) {
      throw StateError('Gemini API returned no candidates.');
    }
    final parts =
        (candidates.first['content']?['parts'] as List<dynamic>?) ?? [];
    final sqlText = parts.map((p) => p['text'] ?? '').join();
    return _extractSql(sqlText);
  }

  // ── Prompt builders ───────────────────────────────────────────────────────

  String _buildSqlSystemPrompt(
      List<TableSchema> tables, String schemaName) {
    final schemaLines = tables.map((table) {
      final cols = table.fields.map((f) {
        final fk = f.foreignKeyRef != null ? '→${f.foreignKeyRef}' : '';
        return '${f.name}$fk';
      }).join(', ');
      return '${table.tableName}($cols)';
    }).join('\n');

    return 'SQLite expert for $schemaName. Output ONLY a valid SELECT query '
        'or CANNOT_ANSWER or OUT_OF_SCOPE.\n'
        'Rules: SELECT only. Use ONLY the exact table and column names '
        'listed below — never invent, guess, or assume a column exists just '
        'because it seems plausible. If a needed column truly isn\'t listed, '
        'output CANNOT_ANSWER instead of guessing. '
        'If a column\'s description lists specific allowed values in '
        'parentheses, any comparison against that column must use one of '
        'those exact values verbatim — never a similar-sounding or '
        'invented value. Never add a WHERE condition on a specific value '
        'the user did not ask for. '
        'For questions using "most", "least", "highest", "lowest", "top", '
        'or "best", ORDER BY (or use MAX()/MIN() on) the column that '
        'actually measures that quantity (an amount, quantity, price, or '
        'count column) — never an ID column. Sorting or taking MAX/MIN of '
        'an ID column does not mean "the most" or "the least" of anything '
        'real. '
        'Only JOIN a table if you need a column from it. If you do JOIN a '
        'table, SELECT its name or other descriptive column — never join a '
        'table and then use nothing from it. '
        'For ANY question — list/show-style or otherwise, with or without '
        'a JOIN — SELECT several of the relevant table\'s substantive '
        'columns (amounts, dates, types, statuses, categories, names, '
        'descriptions), not just an identifier; a result containing only '
        'ID/reference-number columns is never useful. Also SELECT any '
        'column used in ORDER BY or an aggregate function, so the result '
        'actually contains the value being ranked or computed. '
        'For questions asking "which"/"who" about a set of entities (not '
        'asking to count individual events), use SELECT DISTINCT so each '
        'entity appears once even if it has multiple related records. '
        'If the question uses words like "each", "every", "per", or asks '
        'for a breakdown/list across entities (e.g. "how many X does each '
        'Y have"), GROUP BY that entity and return one row per entity — '
        'not a single overall total. '
        'LIMIT 100 if unspecified. Dates are TEXT YYYY-MM-DD.\n\n'
        'SCHEMA:\n$schemaLines';
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _extractSql(String raw) =>
      raw.replaceAll('```sql', '').replaceAll('```', '').trim();
}
