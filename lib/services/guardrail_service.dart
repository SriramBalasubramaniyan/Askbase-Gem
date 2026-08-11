import '../models/chat_message.dart';
import '../models/db_schema_model.dart';
import 'schema_selector.dart';

enum GuardrailOutcome { allowed, blocked }

class GuardrailResult {
  final GuardrailOutcome outcome;
  final String? reasonMessage;

  const GuardrailResult.allow()
      : outcome = GuardrailOutcome.allowed,
        reasonMessage = null;

  const GuardrailResult.block(String message)
      : outcome = GuardrailOutcome.blocked,
        reasonMessage = message;

  bool get isAllowed => outcome == GuardrailOutcome.allowed;
}

/// Every check here runs entirely on-device, before any Gemini API call is
/// made. Its whole purpose is to keep API usage — and therefore free-tier
/// token/request consumption — limited to genuine, on-topic, non-redundant
/// questions.
class GuardrailService {
  GuardrailService._();
  static final GuardrailService instance = GuardrailService._();

  final _selector = SchemaSelector.instance;

  /// Hard ceiling on question length. Generous enough for any real
  /// question about the data, but stops someone from pasting a huge block
  /// of text that would otherwise be sent to the API as-is.
  static const int maxQuestionLength = 400;

  /// Minimum gap enforced between two sends, to absorb accidental
  /// double-taps on the send button — each of which would otherwise be a
  /// full, separate API call.
  static const Duration minSendInterval = Duration(milliseconds: 1200);

  /// Phrases that indicate an attempt to override these instructions or
  /// extract the system prompt, rather than ask a genuine data question.
  /// Checked before the domain-relevance check so an injection attempt is
  /// rejected on its own terms rather than merely "off topic". Intentionally
  /// short and pattern-level, not exhaustive — this is a cheap first line
  /// of defense, not a substitute for the system prompt's own hardening.
  static final List<RegExp> _injectionPatterns = [
    RegExp(r'ignore\s+(all\s+)?(previous|prior|above)\s+instructions',
        caseSensitive: false),
    RegExp(r'system\s+prompt', caseSensitive: false),
    RegExp(r'reveal\s+(your|the)\s+(instructions|prompt)',
        caseSensitive: false),
    RegExp(r'you\s+are\s+now\s+', caseSensitive: false),
    RegExp(r'act\s+as\s+(if\s+you|a|an)\s+', caseSensitive: false),
    RegExp(r'disregard\s+(the\s+)?(rules|guidelines|instructions)',
        caseSensitive: false),
    RegExp(r'jailbreak', caseSensitive: false),
  ];

  static const _outOfDomainMessage =
      'I can only answer questions about the data in this database. Try '
      'asking about the records, totals, or trends it contains.';

  static const _injectionMessage =
      'I can only help with questions about the data in this database — '
      'I can\'t follow instructions that change how I operate.';

  /// Runs every pre-flight check, in cheapest-first order, short-circuiting
  /// on the first one that fails so nothing after it (including the
  /// domain-relevance scoring, the most expensive check here) runs
  /// unnecessarily.
  GuardrailResult check({
    required String question,
    required DatabaseSchema schema,
    required List<ChatMessage> recentHistory,
  }) {
    final trimmed = question.trim();

    if (trimmed.isEmpty) {
      return const GuardrailResult.block('Type a question first.');
    }

    if (trimmed.length > maxQuestionLength) {
      return GuardrailResult.block(
        'That question is a bit long (${trimmed.length} characters). Try '
        'keeping it under $maxQuestionLength characters.',
      );
    }

    // Exact-repeat guard: if this is verbatim the same question that was
    // just answered successfully, don't spend another API call.
    ChatMessage? lastUserMsg;
    for (final m in recentHistory.reversed) {
      if (m.isUser) {
        lastUserMsg = m;
        break;
      }
    }
    if (lastUserMsg != null &&
        lastUserMsg.content.trim().toLowerCase() == trimmed.toLowerCase()) {
      return const GuardrailResult.block(
        'That\'s the same question you just asked — see the answer above.',
      );
    }

    for (final pattern in _injectionPatterns) {
      if (pattern.hasMatch(trimmed)) {
        return const GuardrailResult.block(_injectionMessage);
      }
    }

    // Domain relevance. Checked standalone first — the common case. If a
    // short question scores 0 on its own, it may still be a legitimate
    // follow-up that leans on context ("what about last month?", "and the
    // total?") rather than repeating a schema noun — those are allowed
    // through only when short (a genuine follow-up is brief; an unrelated
    // off-topic question of any length is not given a free pass just
    // because *something* was asked before it).
    final soloScore = _selector.maxScore(trimmed, schema);
    if (soloScore > 0) return const GuardrailResult.allow();

    final looksLikeFollowUp = lastUserMsg != null && trimmed.length <= 40;
    if (looksLikeFollowUp) return const GuardrailResult.allow();

    return const GuardrailResult.block(_outOfDomainMessage);
  }
}
