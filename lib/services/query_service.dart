import 'dart:convert';
import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';

import '../models/db_schema_model.dart';
import '../services/db_service.dart';
import '../services/join_path_finder.dart';
import '../services/llm_service.dart';
import '../services/schema_selector.dart';
import '../services/sql_column_validator.dart';

enum QueryResultStatus {
  success,
  outOfScope,
  cannotAnswer,
  sqlError,
  emptyResult,
  llmError,
}

class QueryResult {
  final QueryResultStatus status;
  final String summary;
  final String? generatedSql;
  final String? rawJson;
  final String? errorDetail;

  /// Tables that were selected by the schema selector.
  /// Populated in debug builds only.
  final List<String>? selectedTableNames;

  const QueryResult({
    required this.status,
    required this.summary,
    this.generatedSql,
    this.rawJson,
    this.errorDetail,
    this.selectedTableNames,
  });

  bool get isSuccess => status == QueryResultStatus.success;
}

class QueryService {
  QueryService._();
  static final QueryService instance = QueryService._();

  final _db = DbService.instance;
  final _llm = LlmService.instance;
  final _selector = SchemaSelector.instance;

  /// Total SQL-generation attempts per question: 1 initial try + this many
  /// self-correction retries. Kept small on purpose — each attempt is a
  /// full on-device generation call, not free on a 0.5B model on a phone,
  /// and a question that's genuinely unanswerable from the schema won't be
  /// fixed by trying harder.
  static const int _maxRetries = 2;
  static const int _maxAttempts = _maxRetries + 1;

  /// Matches the sole column of a single-row/single-column result against
  /// an aggregate function shape, capturing the function name and its
  /// argument (a column reference, `*`, or nothing) separately — the
  /// argument is used to build natural phrasing like "the total disbursed
  /// amount" instead of a generic "the total".
  static final RegExp _aggregatePattern = RegExp(
    r'^(COUNT|SUM|AVG|MIN|MAX)\s*\(\s*(\*|[A-Za-z_][\w.]*)?\s*\)$',
    caseSensitive: false,
  );

  Future<QueryResult> ask({
    required String question,
    required DatabaseSchema schema,
    required void Function(String token) onToken,
  }) async {
    // ── Step 1: Select relevant tables semantically ─────────────────────────
    final selectedTables = _selector.select(question, schema);

    // Debug only — log which tables were selected
    if (kDebugMode) {
      final debugInfo = _selector.debugSelectionInfo(question, schema);
      developer.log(debugInfo, name: 'SchemaSelector');
    }

    final debugTables =
        kDebugMode ? selectedTables.map((t) => t.tableName).toList() : null;

    // ── Steps 2-5: generate → check → validate → execute, with
    // self-correction ─────────────────────────────────────────────────────
    // On failure at any stage, the specific error is fed back into the next
    // generation attempt so the model can actually fix its mistake instead
    // of just re-rolling blind. Column/table/enum-value hallucinations are
    // caught deterministically by SqlColumnValidator *before* ever touching
    // the database. When that failure involves two tables that aren't
    // directly related by a foreign key, a literal, ready-to-use FROM/JOIN
    // skeleton is computed and appended. Loops at most _maxAttempts times.
    String? rawSql;
    String? lastError;
    List<Map<String, dynamic>>? rows;

    for (int attempt = 1; attempt <= _maxAttempts; attempt++) {
      final isRetry = attempt > 1;

      String candidateSql;
      try {
        candidateSql = await _llm.generateSql(
          userQuestion: question,
          selectedTables: selectedTables,
          schemaName: schema.databaseName,
          previousAttemptSql: isRetry ? rawSql : null,
          previousError: isRetry ? lastError : null,
        );
      } catch (e) {
        lastError = e.toString();
        if (kDebugMode) {
          developer.log('Attempt $attempt: generation threw — $lastError',
              name: 'QueryService');
        }
        if (attempt == _maxAttempts) {
          return QueryResult(
            status: QueryResultStatus.llmError,
            summary:
                'The AI model encountered an error while generating a '
                'query. Please try again.',
            errorDetail: lastError,
            selectedTableNames: debugTables,
          );
        }
        continue;
      }

      rawSql = candidateSql;
      final sqlUpper = rawSql.trim().toUpperCase();

      // These are the model correctly declining, not a bug to retry against.
      if (sqlUpper.contains('OUT_OF_SCOPE')) {
        return QueryResult(
          status: QueryResultStatus.outOfScope,
          summary:
              'I can only answer questions about the data in this database. '
              'Please ask something related to the available records.',
          selectedTableNames: debugTables,
        );
      }

      if (sqlUpper.contains('CANNOT_ANSWER')) {
        return QueryResult(
          status: QueryResultStatus.cannotAnswer,
          summary:
              'The information you asked for is not available in this database.',
          selectedTableNames: debugTables,
        );
      }

      // Deterministic pre-flight check: does every table/column referenced
      // actually exist, and does every enum-style comparison use a real
      // documented value? Checked against the full schema (not just the
      // tables the model was shown) so a hallucinated table/column/value
      // is caught even if it happens to collide with something real
      // elsewhere.
      final columnError = SqlColumnValidator.check(rawSql, schema);
      if (columnError != null) {
        lastError = _withJoinPathHint(columnError, rawSql, schema);
        if (kDebugMode) {
          developer.log('Attempt $attempt: column check failed — $lastError',
              name: 'QueryService');
        }
        if (attempt == _maxAttempts) break;
        continue;
      }

      final validationError = _db.validateSql(rawSql);
      if (validationError != null) {
        lastError = validationError;
        if (kDebugMode) {
          developer.log('Attempt $attempt: validation failed — $lastError',
              name: 'QueryService');
        }
        if (attempt == _maxAttempts) break;
        continue;
      }

      try {
        rows = await _db.runSelect(rawSql);
        lastError = null;
        if (kDebugMode) {
          developer.log('Attempt $attempt: succeeded', name: 'QueryService');
        }
        break; // got a runnable query — stop retrying
      } catch (e) {
        lastError = e.toString();
        if (kDebugMode) {
          developer.log('Attempt $attempt: execution failed — $lastError',
              name: 'QueryService');
        }
        if (attempt == _maxAttempts) break;
        continue;
      }
    }

    // Exhausted every attempt without landing a runnable query.
    if (rows == null) {
      return QueryResult(
        status: QueryResultStatus.sqlError,
        summary: 'I couldn\'t come up with a working query for "$question" '
            'right now. Try rephrasing your question, or ask about '
            'something else in the data.',
        generatedSql: rawSql,
        errorDetail: lastError,
        selectedTableNames: debugTables,
      );
    }

    // ── Step 6: Handle empty results ─────────────────────────────────────────
    if (rows.isEmpty) {
      return QueryResult(
        status: QueryResultStatus.emptyResult,
        summary: 'No records were found matching your question.',
        generatedSql: rawSql,
        rawJson: '[]',
        selectedTableNames: debugTables,
      );
    }

    // ── Step 7: Build the answer ─────────────────────────────────────────────
    // The entire answer — including the lead-in framing, not just the
    // facts — is now built deterministically in Dart, with no LLM call at
    // all for this step. An LLM-generated lead-in was tried (given only
    // the question, never the data, on the theory that withholding data
    // would prevent fabrication), but that didn't hold in practice — it
    // still invented specific numbers and names untethered to anything
    // real (e.g. "10,000 registered farmers" sitting right next to the
    // correct deterministic "There are 30 farmers."). Telling the model
    // not to invent a fact turned out to be just another instruction it
    // doesn't reliably follow. Removing it from the pipeline entirely
    // removes that failure mode by construction, and is also faster (one
    // fewer generation call per question).
    final jsonRows = const JsonEncoder.withIndent('  ').convert(
      rows.length > 50 ? rows.sublist(0, 50) : rows,
    );

    final answer = _buildDeterministicAnswer(rows, rawSql, schema);
    onToken(answer);

    return QueryResult(
      status: QueryResultStatus.success,
      summary: answer,
      generatedSql: rawSql,
      rawJson: jsonRows,
      selectedTableNames: debugTables,
    );
  }

  /// Builds the entire answer — lead-in included — directly from [rows].
  /// No LLM involved, so it's always correct. Shapes handled:
  ///   1. Single row, single column, matching an aggregate function
  ///      (COUNT/SUM/AVG/MIN/MAX) → one complete sentence stating that
  ///      value, phrased using the real table name (for COUNT) or the
  ///      real column name (for SUM/AVG/MIN/MAX) pulled from [sql]. No
  ///      separate lead-in — the sentence is already a complete answer.
  ///   2. Any other rows where every row is *only* ID/reference columns
  ///      (nothing descriptive was selected) → an explicit fallback
  ///      message, which also surfaces a SQL-generation quality problem
  ///      (under-selected columns) instead of silently glossing over it.
  ///   3. Rows where every remaining (non-ID) value is identical across
  ///      the whole result (e.g. a "status" column alone, all "Pending")
  ///      → a similar fallback — technically not empty, but equally
  ///      useless for telling the results apart.
  ///   4. Otherwise → a short deterministic lead-in, then every row
  ///      rendered as one bullet each from its non-ID columns in the
  ///      order the query selected them. A single row is rendered as a
  ///      plain sentence rather than a one-item bullet list.
  String _buildDeterministicAnswer(
    List<Map<String, dynamic>> rows,
    String? sql,
    DatabaseSchema schema,
  ) {
    if (rows.length == 1 && rows.first.length == 1) {
      final rawKey = rows.first.keys.first;
      final match = _aggregatePattern.firstMatch(rawKey.trim());
      if (match != null) {
        final primaryTable = sql == null
            ? null
            : SqlColumnValidator.referencedTables(sql, schema)
                .map((t) => t.tableName)
                .firstOrNull;
        return _aggregateSentence(
          match.group(1)!.toUpperCase(),
          match.group(2),
          primaryTable,
          rows.first.values.first,
        );
      }
    }

    final displayRows = rows.map(_stripIdColumns).toList();
    final rowStrings = displayRows.map((r) => r.values.join(', ')).toList();

    final allEmpty = displayRows.every((r) => r.isEmpty);
    if (allEmpty) {
      return 'There are ${rows.length} matching record(s), but they '
          'contain no descriptive details — only reference numbers. Try '
          'asking for specific columns (e.g. names, amounts, or dates).';
    }

    final allIdentical =
        rows.length > 1 && rowStrings.toSet().length == 1;
    if (allIdentical) {
      return 'There are ${rows.length} matching record(s), but the only '
          'value returned ("${rowStrings.first}") is the same for every '
          'one and doesn\'t distinguish them. Try asking for specific '
          'columns (e.g. names, amounts, or dates) so each result can be '
          'told apart.';
    }

    if (rows.length == 1) {
      return 'Here\'s what I found:\n\n${rowStrings.first}.';
    }

    final bullets = rowStrings.map((s) => '- $s').join('\n');
    return 'Here\'s what I found — ${rows.length} in total:\n$bullets';
  }

  /// Returns a copy of [row] with any key named "id" or ending in "_id"
  /// removed — these are reference numbers, not meaningful content, and
  /// should never be surfaced unless the user explicitly asked for one.
  Map<String, dynamic> _stripIdColumns(Map<String, dynamic> row) {
    final out = <String, dynamic>{};
    row.forEach((key, value) {
      final lower = key.toLowerCase();
      if (lower == 'id' || lower.endsWith('_id')) return;
      out[key] = value;
    });
    return out;
  }

  /// Builds a natural sentence for an aggregate result. [tableName], when
  /// available, is used directly for COUNT ("There are 30 farmers." /
  /// "There is 1 farmer.") with basic English pluralization. For
  /// SUM/AVG/MIN/MAX, [arg] (the aggregate's column argument, e.g.
  /// "loan.disbursed_amount") is humanized into a label ("disbursed
  /// amount") when available. Falls back to generic phrasing only when
  /// neither is available (e.g. a bare `COUNT(*)` with no resolvable
  /// table, which shouldn't normally happen but is handled safely).
  String _aggregateSentence(
    String fn,
    String? arg,
    String? tableName,
    dynamic value,
  ) {
    switch (fn) {
      case 'COUNT':
        if (tableName != null) {
          final isOne = value is num && value == 1;
          return isOne
              ? 'There is 1 $tableName.'
              : 'There are $value ${_pluralize(tableName)}.';
        }
        return 'There are $value matching records.';
      case 'SUM':
      case 'AVG':
      case 'MIN':
      case 'MAX':
        final verb = const {
          'SUM': 'total',
          'AVG': 'average',
          'MIN': 'minimum',
          'MAX': 'maximum',
        }[fn]!;
        final label = _humanizeAggregateArg(arg);
        return label != null
            ? 'The $verb $label is $value.'
            : 'The $verb is $value.';
      default:
        return '$value.';
    }
  }

  /// Turns an aggregate argument like "loan.disbursed_amount" or
  /// "quantity_kg" into a readable label ("disbursed amount",
  /// "quantity kg"). Returns null for `*` or no argument, since there's
  /// no meaningful label to build in that case.
  String? _humanizeAggregateArg(String? arg) {
    if (arg == null || arg == '*') return null;
    final column = arg.contains('.') ? arg.split('.').last : arg;
    return column.replaceAll('_', ' ');
  }

  /// Minimal English pluralization sufficient for table names in a
  /// typical schema (farmer → farmers, sale → sales, category → categories).
  String _pluralize(String word) {
    if (word.isEmpty) return word;
    final lower = word.toLowerCase();
    if (lower.endsWith('s') ||
        lower.endsWith('x') ||
        lower.endsWith('z') ||
        lower.endsWith('ch') ||
        lower.endsWith('sh')) {
      return '${word}es';
    }
    if (lower.endsWith('y') &&
        word.length > 1 &&
        !'aeiou'.contains(lower[lower.length - 2])) {
      return '${word.substring(0, word.length - 1)}ies';
    }
    return '${word}s';
  }

  /// If [sql] references two or more real tables that aren't directly
  /// connected by a foreign key, appends a literal, ready-to-use FROM/JOIN
  /// skeleton (found via BFS over the schema's FK graph) to [baseError] so
  /// the next generation attempt can copy it directly instead of having to
  /// assemble a multi-hop join from separate facts on its own.
  String _withJoinPathHint(
    String baseError,
    String sql,
    DatabaseSchema schema,
  ) {
    final tables = SqlColumnValidator.referencedTables(sql, schema);
    if (tables.length < 2) return baseError;

    final hints = <String>[];
    for (var i = 0; i < tables.length; i++) {
      for (var j = i + 1; j < tables.length; j++) {
        final a = tables[i];
        final b = tables[j];

        final directlyLinked = a.fields
                .any((f) => f.foreignKeyRef?.startsWith('${b.tableName}.') ?? false) ||
            b.fields.any(
                (f) => f.foreignKeyRef?.startsWith('${a.tableName}.') ?? false);
        if (directlyLinked) continue;

        final path = JoinPathFinder.findPath(schema, a.tableName, b.tableName);
        if (path != null && path.isNotEmpty) {
          final skeleton = _buildJoinSkeleton(a.tableName, path);
          hints.add('${a.tableName} and ${b.tableName} are not directly '
              'related — do not join them directly to each other. Use '
              'exactly this join structure instead: $skeleton');
        }
      }
    }

    if (hints.isEmpty) return baseError;
    return '$baseError ${hints.join(" ")}';
  }

  /// Builds a literal `FROM x JOIN y ON ... JOIN z ON ...` skeleton from a
  /// starting table and an ordered list of join conditions (as produced by
  /// [JoinPathFinder.findPath]), so the model can copy it directly instead
  /// of assembling a multi-hop join from separate facts itself.
  String _buildJoinSkeleton(String startTable, List<String> conditions) {
    final included = <String>{startTable};
    final buffer = StringBuffer('FROM $startTable');
    for (final condition in conditions) {
      final parts = condition.split('=').map((s) => s.trim()).toList();
      if (parts.length != 2) continue;
      final leftTable = parts[0].split('.').first;
      final rightTable = parts[1].split('.').first;
      final newTable = included.contains(leftTable) ? rightTable : leftTable;
      included.add(newTable);
      buffer.write(' JOIN $newTable ON $condition');
    }
    return buffer.toString();
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
