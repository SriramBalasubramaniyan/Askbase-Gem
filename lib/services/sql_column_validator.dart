import '../models/db_schema_model.dart';

/// Deterministic, non-executing check that every table/column referenced
/// in a generated SQL query actually exists in [schema], and that any
/// value compared against an enum-style column is one of its documented
/// allowed values. This runs before the query ever touches the database —
/// it's free (no I/O), and unlike a raw SQLite error, it can point at
/// exactly what's wrong and what the real options were. That's what lets
/// the self-correction retry loop in QueryService actually fix a mistake
/// instead of re-rolling the same one against a vague error string.
///
/// This is intentionally NOT a full SQL parser — it targets the concrete
/// hallucination patterns observed in practice:
///   1. Qualified references: `alias.column` where `alias` resolves to a
///      real table (via FROM/JOIN) but `column` isn't one of its fields
///      (e.g. `insurance.crop_id`, which doesn't exist — the real path is
///      insurance → sowing → crop).
///   2. Qualified references to a real table that was never declared in
///      FROM/JOIN *at all* (e.g. `SELECT crop.name FROM insurance ...` —
///      `crop` is a real table, just never joined in this query).
///   3. Unqualified column references — both in the WHERE clause and the
///      SELECT list — for single-table queries (e.g. `SELECT ...,
///      payment_date FROM sale`, which has no `payment_date`, only
///      `sale_date`; or `WHERE status = 'PENDING'` on `sale`, which only
///      has `payment_status`).
///   4. Invented enum values: when a field's schema description lists its
///      allowed values in parentheses (e.g. "Loan status (Active, Repaid,
///      Overdue, NPA)"), any string-literal comparison against that
///      column must use one of those exact values — never a plausible-
///      sounding invented one (e.g. `claim_status = 'active'` when the
///      real allowed values are None/Filed/Approved/Rejected/Paid).
///      Purely casing differences are intentionally NOT flagged here —
///      that's handled separately and more robustly by DbService's
///      COLLATE NOCASE rewrite, so this only catches genuinely wrong
///      values, not case mismatches of otherwise-correct ones.
/// Subquery interiors (parenthesized `SELECT ...` blocks, e.g. inside an
/// `IN (...)`) are masked out before any of the above runs — otherwise a
/// subquery's own FROM/JOIN silently makes the outer query look like a
/// multi-table query, which disables the single-table unqualified-column
/// check for the *outer* query too and lets a real hallucination through.
/// Anything this still can't confidently parse (unusual syntax) is left
/// alone — it falls through to the existing execution-time error
/// handling, so this can only catch problems earlier, never introduce new
/// false failures on SQL it doesn't understand.
class SqlColumnValidator {
  SqlColumnValidator._();

  // The negative lookahead before the alias group is load-bearing: without
  // it, "FROM crop JOIN insurance" would have its alias group greedily
  // swallow the keyword "JOIN" as if it were crop's alias, which then
  // consumes the string past that point and causes the second table
  // ("JOIN insurance") to never be matched at all — silently reducing a
  // multi-table query down to a single detected table. Verified against
  // real multi-join queries before shipping.
  static final RegExp _fromJoinPattern = RegExp(
    r'\b(?:FROM|JOIN)\s+([A-Za-z_]\w*)'
    r'(?:\s+(?:AS\s+)?(?!(?:WHERE|ON|GROUP|ORDER|LIMIT|JOIN|LEFT|INNER|RIGHT|FULL|OUTER|AND|OR|UNION|HAVING)\b)([A-Za-z_]\w*))?',
    caseSensitive: false,
  );

  static final RegExp _qualifiedRefPattern =
      RegExp(r'\b([A-Za-z_]\w*)\.([A-Za-z_]\w*)\b');

  static final RegExp _qualifiedRefStripPattern =
      RegExp(r'\b[A-Za-z_]\w*\.[A-Za-z_]\w*\b');

  static final RegExp _whereComparisonPattern = RegExp(
    r'\b([A-Za-z_]\w*)\s*(?:=|!=|<>|<=|>=|<|>|LIKE)\s',
    caseSensitive: false,
  );

  static final RegExp _bareIdentifierPattern = RegExp(r'\b[A-Za-z_]\w*\b');

  static final RegExp _asKeywordPattern =
      RegExp(r'\s+AS\s+', caseSensitive: false);

  static final RegExp _selectKeywordPattern =
      RegExp(r'^SELECT\b', caseSensitive: false);

  /// Matches `column = 'value'` / `!=` / `<>` string-literal comparisons,
  /// capturing the (possibly qualified) column and the literal value, for
  /// the enum-value check. A SQLite string literal escapes an embedded
  /// quote by doubling it (e.g. 'John''s Farm'), which is what
  /// (?:[^']|'')* captures.
  static final RegExp _valueComparisonPattern = RegExp(
    r"\b([A-Za-z_][\w.]*)\s*(?:=|!=|<>)\s*'((?:[^']|'')*)'",
    caseSensitive: false,
  );

  /// Matches a parenthesized group within a field description, used to
  /// find an allowed-value list like "(Active, Repaid, Overdue, NPA)".
  static final RegExp _parenGroupPattern = RegExp(r'\(([^()]+)\)');

  /// Words that can legally appear right after a table name in a FROM/JOIN
  /// clause without being an alias — so "FROM farmer WHERE ..." doesn't
  /// get misread as table "farmer" aliased to "where".
  static const _reservedWords = {
    'where', 'on', 'group', 'order', 'limit', 'join', 'left', 'inner',
    'right', 'full', 'outer', 'and', 'or', 'union', 'having', 'as',
  };

  /// SQL syntax words that can appear as bare tokens without being a
  /// column name, so they're never flagged as a missing column.
  static const _sqlKeywords = {
    'and', 'or', 'not', 'select', 'from', 'where', 'group', 'order', 'by',
    'limit', 'having', 'distinct', 'as', 'case', 'when', 'then', 'else',
    'end', 'null', 'is', 'in', 'between', 'exists', 'all', 'count', 'sum',
    'avg', 'min', 'max', 'collate', 'nocase',
  };

  static final RegExp _numericPattern = RegExp(r'^\d+$');

  /// Returns a specific, actionable correction message if [sql] references
  /// a table/column that doesn't exist in [schema], a value that violates
  /// a documented enum column, or null if this check didn't find a
  /// problem (which does not guarantee the SQL is otherwise valid — only
  /// that this particular check passed).
  static String? check(String sql, DatabaseSchema schema) {
    final masked = _maskSubqueries(sql);
    final aliasMap = _extractTableAliases(masked, schema);
    if (aliasMap.isEmpty) return null; // couldn't parse FROM/JOIN confidently

    // Unknown tables referenced in FROM/JOIN.
    for (final entry in aliasMap.entries) {
      if (entry.value == null) {
        final available = schema.tables.map((t) => t.tableName).join(', ');
        return 'Table "${entry.key}" does not exist. Available tables: '
            '$available.';
      }
    }

    // Qualified alias.column references — checked across the whole query
    // (SELECT list, JOIN...ON, WHERE, ORDER BY, etc).
    for (final m in _qualifiedRefPattern.allMatches(masked)) {
      final alias = m.group(1)!;
      final col = m.group(2)!;

      if (aliasMap.containsKey(alias)) {
        final table = aliasMap[alias];
        if (table == null) continue; // already reported above
        final err = _checkIdentifiers([col], table);
        if (err != null) return err;
        continue;
      }

      // The alias isn't declared anywhere in this query's FROM/JOIN. If it
      // happens to be the exact name of a real table in the schema, this
      // is almost certainly a forgotten JOIN — the model referenced a
      // table it never actually brought into the query (e.g. `crop.name`
      // in a query whose FROM/JOIN never mentions `crop` at all). Aliases
      // that *aren't* real table names are left alone here — could be
      // something this parser doesn't understand, not worth risking a
      // false positive over.
      final maybeTable = schema.tableByName(alias);
      if (maybeTable != null) {
        final declared = aliasMap.entries
            .where((e) => e.value != null)
            .map((e) => e.key)
            .toSet();
        return 'Table "$alias" is referenced (as "$alias.$col") but was '
            'never declared in FROM/JOIN — it was never actually joined '
            'into this query. Declared tables here: ${declared.join(", ")}. '
            'Either add "$alias" to the query with an appropriate JOIN '
            'condition, or remove the reference to it.';
      }
    }

    // Unqualified references — only for single-table queries (no JOIN).
    // With a JOIN present, an unqualified column is ambiguous between
    // tables, so it's left to execution-time error handling instead of
    // risking a false positive here.
    final involvedTables = aliasMap.values.whereType<TableSchema>().toList();
    final distinctTableNames =
        involvedTables.map((t) => t.tableName).toSet();

    if (distinctTableNames.length == 1) {
      final table = involvedTables.first;
      final upperMasked = masked.toUpperCase();

      // SELECT-list check.
      final selectStart = upperMasked.indexOf('SELECT');
      final fromStart = upperMasked.indexOf('FROM');
      if (selectStart != -1 && fromStart != -1 && fromStart > selectStart) {
        var selectClause = masked
            .substring(selectStart + 'SELECT'.length, fromStart)
            .trim();
        if (selectClause.toUpperCase().startsWith('DISTINCT')) {
          selectClause = selectClause.substring('DISTINCT'.length).trim();
        }
        final candidates = _extractBareIdentifiers(selectClause);
        final err = _checkIdentifiers(candidates, table);
        if (err != null) return err;
      }

      // WHERE-clause check.
      final whereStart = upperMasked.indexOf('WHERE');
      if (whereStart != -1) {
        final whereClause = masked.substring(whereStart);
        final candidates = _whereComparisonPattern
            .allMatches(whereClause)
            .map((m) => m.group(1)!)
            .where((c) => !c.contains('.'));
        final err = _checkIdentifiers(candidates, table);
        if (err != null) return err;
      }
    }

    // Enum-value check — every string-literal comparison anywhere in the
    // query, checked against whichever table it resolves to (via a known
    // alias, or the sole table for a single-table query).
    final enumErr = _checkEnumValues(masked, aliasMap, distinctTableNames);
    if (enumErr != null) return enumErr;

    return null;
  }

  /// Returns the distinct real tables referenced via FROM/JOIN in [sql]
  /// (subquery interiors masked out first, tables that don't resolve to
  /// anything real omitted). Exposed so other components — e.g. join-path
  /// hinting on a validation failure — can reuse this parsing without
  /// duplicating it.
  static List<TableSchema> referencedTables(String sql, DatabaseSchema schema) {
    final masked = _maskSubqueries(sql);
    final aliasMap = _extractTableAliases(masked, schema);
    final seen = <String>{};
    final result = <TableSchema>[];
    for (final table in aliasMap.values) {
      if (table == null) continue;
      if (seen.add(table.tableName)) result.add(table);
    }
    return result;
  }

  // ── Internals ────────────────────────────────────────────────────────────

  /// Checks every `column = 'value'` / `!=` / `<>` comparison in [sql]
  /// against the allowed-value list (if any) documented in that column's
  /// field description. Only string-literal comparisons are considered;
  /// numeric/column comparisons are untouched. Case differences alone are
  /// never flagged — DbService's COLLATE NOCASE rewrite already handles
  /// those — only values that don't match any allowed value regardless of
  /// case are reported.
  static String? _checkEnumValues(
    String sql,
    Map<String, TableSchema?> aliasMap,
    Set<String> distinctTableNames,
  ) {
    for (final m in _valueComparisonPattern.allMatches(sql)) {
      final ident = m.group(1)!;
      final rawValue = m.group(2)!;

      TableSchema? table;
      String columnName;
      if (ident.contains('.')) {
        final parts = ident.split('.');
        final alias = parts.first;
        columnName = parts.last;
        if (!aliasMap.containsKey(alias)) continue;
        table = aliasMap[alias];
      } else {
        if (distinctTableNames.length != 1) continue; // ambiguous, skip
        columnName = ident;
        table = aliasMap.values.firstWhere(
          (t) => t != null,
          orElse: () => null,
        );
      }
      if (table == null) continue;

      final field = _findField(table, columnName);
      if (field == null) continue; // reported by the column-existence check

      final allowed = _extractAllowedValues(field.description);
      if (allowed == null) continue; // not a documented enum field

      final matches =
          allowed.any((a) => a.toLowerCase() == rawValue.toLowerCase());
      if (!matches) {
        return 'Table "${table.tableName}" column "$columnName" only '
            'allows these values: ${allowed.join(", ")}. "$rawValue" is '
            'not one of them — use one of the allowed values exactly.';
      }
    }
    return null;
  }

  static FieldDef? _findField(TableSchema table, String name) {
    for (final f in table.fields) {
      if (f.name == name) return f;
    }
    return null;
  }

  /// Extracts an enum-style allowed-value list from a field description,
  /// if it has one — e.g. "Loan status (Active, Repaid, Overdue, NPA)."
  /// returns [Active, Repaid, Overdue, NPA]. A parenthetical group only
  /// qualifies if it contains 2+ comma-separated, short (<=30 char),
  /// non-sentence items — so an aside like "(kg)" or "(in rupees)" is
  /// never mistaken for a value list. If a description has more than one
  /// qualifying group, the last one is used.
  static List<String>? _extractAllowedValues(String description) {
    List<String>? found;
    for (final m in _parenGroupPattern.allMatches(description)) {
      final parts = m
          .group(1)!
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      if (parts.length < 2) continue;
      final looksLikeEnum =
          parts.every((p) => p.length <= 30 && !p.contains('.'));
      if (looksLikeEnum) found = parts;
    }
    return found;
  }

  /// Replaces the contents of any parenthesized `(SELECT ...)` block with
  /// blank space of the same length (parens kept, so overall shape/offsets
  /// are undisturbed), so subquery FROM/JOIN/column references never leak
  /// into the outer query's table/column analysis. Doesn't validate the
  /// subquery itself — just stops it from corrupting the outer check.
  static String _maskSubqueries(String sql) {
    final buffer = StringBuffer();
    var i = 0;
    while (i < sql.length) {
      final c = sql[i];
      if (c == '(') {
        final end = _findMatchingParen(sql, i);
        if (end != -1) {
          final inner = sql.substring(i + 1, end).trimLeft();
          if (_selectKeywordPattern.hasMatch(inner)) {
            buffer.write('(');
            buffer.write(' ' * (end - i - 1));
            buffer.write(')');
            i = end + 1;
            continue;
          }
        }
      }
      buffer.write(c);
      i++;
    }
    return buffer.toString();
  }

  /// Returns the index of the `)` matching the `(` at [openIndex], or -1
  /// if unbalanced.
  static int _findMatchingParen(String s, int openIndex) {
    var depth = 0;
    for (var i = openIndex; i < s.length; i++) {
      if (s[i] == '(') depth++;
      if (s[i] == ')') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }

  static String? _checkIdentifiers(
    Iterable<String> candidates,
    TableSchema table,
  ) {
    final fieldNames = table.fields.map((f) => f.name).toSet();
    for (final candidate in candidates) {
      final lower = candidate.toLowerCase();
      if (_sqlKeywords.contains(lower)) continue;
      if (_numericPattern.hasMatch(candidate)) continue;
      if (!fieldNames.contains(candidate)) {
        return 'Table "${table.tableName}" has no column "$candidate". Its '
            'actual columns are: ${fieldNames.join(", ")}.';
      }
    }
    return null;
  }

  /// Extracts candidate bare (unqualified) identifier names from a
  /// comma-separated clause fragment (typically a SELECT list), skipping:
  ///  - the alias half of "expr AS alias" items,
  ///  - `*` and `table.*`,
  ///  - anything that's part of an `alias.column` qualified reference
  ///    (those are checked separately, so stripped here first to avoid
  ///    double-checking or misreading the alias itself as a column).
  static List<String> _extractBareIdentifiers(String clause) {
    final out = <String>[];
    for (final item in _splitTopLevel(clause, ',')) {
      var expr = item.trim();
      final asMatch = _asKeywordPattern.firstMatch(expr);
      if (asMatch != null) {
        expr = expr.substring(0, asMatch.start);
      }
      if (expr == '*' || expr.endsWith('.*')) continue;
      final withoutQualified = expr.replaceAll(_qualifiedRefStripPattern, '');
      for (final m in _bareIdentifierPattern.allMatches(withoutQualified)) {
        out.add(m.group(0)!);
      }
    }
    return out;
  }

  /// Splits [s] on top-level occurrences of [sep], respecting parenthesis
  /// nesting (so `COUNT(a, b)` isn't split into two items).
  static List<String> _splitTopLevel(String s, String sep) {
    final parts = <String>[];
    var depth = 0;
    var start = 0;
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (c == '(') {
        depth++;
      } else if (c == ')') {
        depth--;
      } else if (c == sep && depth == 0) {
        parts.add(s.substring(start, i));
        start = i + 1;
      }
    }
    parts.add(s.substring(start));
    return parts;
  }

  /// Maps every alias (and each table's own bare name) used in FROM/JOIN
  /// clauses to its resolved [TableSchema], or to null if it doesn't
  /// match any real table in [schema]. Expects subquery interiors to
  /// already be masked out by the caller.
  static Map<String, TableSchema?> _extractTableAliases(
    String sql,
    DatabaseSchema schema,
  ) {
    final map = <String, TableSchema?>{};
    for (final m in _fromJoinPattern.allMatches(sql)) {
      final tableName = m.group(1)!;
      final rawAlias = m.group(2);
      final table = schema.tableByName(tableName);

      map[tableName] = table;

      if (rawAlias != null &&
          !_reservedWords.contains(rawAlias.toLowerCase())) {
        map[rawAlias] = table;
      }
    }
    return map;
  }
}
