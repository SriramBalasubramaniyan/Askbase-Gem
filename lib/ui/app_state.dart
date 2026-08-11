import 'package:flutter/foundation.dart';

import '../models/chat_message.dart';
import '../models/chat_session.dart';
import '../models/db_schema_model.dart';
import '../services/chat_history_service.dart';
import '../services/db_service.dart';
import '../services/guardrail_service.dart';
import '../services/llm_service.dart';
import '../services/query_service.dart';

enum AppStatus { initializing, needsApiKey, loading, ready, error }

class AppState extends ChangeNotifier {
  AppState(this._schema);

  final DatabaseSchema _schema;
  final _history = ChatHistoryService.instance;
  final _guardrail = GuardrailService.instance;

  AppStatus _status = AppStatus.initializing;
  String _statusMessage = 'Starting…';
  String? _errorMessage;

  // ── Multi-chat state ─────────────────────────────────────────────────────
  // `_currentChatId == null` means the current view is an unsaved draft —
  // a chat is only created (and shows up in `_chatIndex`) once its first
  // message is actually sent, matching how production chat apps behave
  // (an empty "New chat" is not itself a saved conversation).
  List<ChatSummary> _chatIndex = [];
  String? _currentChatId;
  final List<ChatMessage> _messages = [];
  bool _isProcessing = false;
  DateTime? _lastSentAt;

  // ── Getters ───────────────────────────────────────────────────────────────
  AppStatus get status => _status;
  String get statusMessage => _statusMessage;
  String? get errorMessage => _errorMessage;
  List<ChatMessage> get messages => List.unmodifiable(_messages);
  bool get isProcessing => _isProcessing;
  DatabaseSchema get schema => _schema;
  List<ChatSummary> get chatIndex => List.unmodifiable(_chatIndex);
  String? get currentChatId => _currentChatId;

  // ── Initialisation ────────────────────────────────────────────────────────

  Future<void> initialize() async {
    _setStatus(AppStatus.initializing, 'Starting up…');
    try {
      _setStatus(AppStatus.initializing, 'Loading database…');
      await DbService.instance.init(_schema);

      final hasKey = await LlmService.instance.hasApiKey();
      if (!hasKey) {
        _setStatus(AppStatus.needsApiKey, 'API key required');
        return;
      }

      _chatIndex = await _history.loadIndex();
      if (_chatIndex.isNotEmpty) {
        final mostRecent = _chatIndex.first;
        _currentChatId = mostRecent.id;
        _messages
          ..clear()
          ..addAll(await _history.loadMessages(mostRecent.id));
      }

      _setStatus(AppStatus.ready, 'Ready');
    } catch (e) {
      _setStatus(AppStatus.error, 'Initialization failed');
      _errorMessage = e.toString();
      notifyListeners();
    }
  }

  // ── API key ───────────────────────────────────────────────────────────────

  Future<void> setApiKey(String key) async {
    _errorMessage = null;
    await LlmService.instance.saveApiKey(key);
    _chatIndex = await _history.loadIndex();
    if (_chatIndex.isNotEmpty) {
      final mostRecent = _chatIndex.first;
      _currentChatId = mostRecent.id;
      _messages
        ..clear()
        ..addAll(await _history.loadMessages(mostRecent.id));
    }
    _setStatus(AppStatus.ready, 'Ready');
  }

  Future<void> clearApiKey() async {
    await LlmService.instance.clearApiKey();
    _setStatus(AppStatus.needsApiKey, 'API key required');
  }

  // ── Chat session management ──────────────────────────────────────────────

  /// Starts a fresh, unsaved conversation. If the current chat is already
  /// an empty draft, this is a no-op — avoids piling up empty entries.
  void createNewChat() {
    if (_isProcessing) return;
    if (_currentChatId == null && _messages.isEmpty) return;
    _currentChatId = null;
    _messages.clear();
    notifyListeners();
  }

  Future<void> switchChat(String chatId) async {
    if (_isProcessing || chatId == _currentChatId) return;
    final loaded = await _history.loadMessages(chatId);
    _currentChatId = chatId;
    _messages
      ..clear()
      ..addAll(loaded);
    notifyListeners();
  }

  Future<void> deleteChat(String chatId) async {
    if (_isProcessing) return;
    _chatIndex = _chatIndex.where((c) => c.id != chatId).toList();
    await _history.saveIndex(_chatIndex);
    await _history.deleteChat(chatId);

    if (chatId == _currentChatId) {
      if (_chatIndex.isNotEmpty) {
        await switchChat(_chatIndex.first.id);
        return;
      }
      _currentChatId = null;
      _messages.clear();
    }
    notifyListeners();
  }

  /// Clears every saved chat and starts a fresh draft.
  Future<void> clearAllChats() async {
    if (_isProcessing) return;
    for (final chat in _chatIndex) {
      await _history.deleteChat(chat.id);
    }
    _chatIndex = [];
    await _history.saveIndex(_chatIndex);
    _currentChatId = null;
    _messages.clear();
    notifyListeners();
  }

  /// Kept for the existing "clear chat" action in the chat screen — clears
  /// just the currently open conversation (and deletes it from history if
  /// it was already saved), without touching other saved chats.
  Future<void> clearChat() async {
    if (_isProcessing) return;
    if (_currentChatId != null) {
      await deleteChat(_currentChatId!);
    } else {
      _messages.clear();
      notifyListeners();
    }
  }

  // ── Chat ──────────────────────────────────────────────────────────────────

  Future<void> sendMessage(String question) async {
    if (_isProcessing) return;
    final trimmed = question.trim();
    if (trimmed.isEmpty) return;
    if (_status != AppStatus.ready) return;

    // Silent debounce for accidental double-taps — no message shown, no
    // API call, nothing recorded. A deliberate resend a moment later goes
    // through normally.
    final now = DateTime.now();
    if (_lastSentAt != null &&
        now.difference(_lastSentAt!) < GuardrailService.minSendInterval) {
      return;
    }
    _lastSentAt = now;

    // ── Guardrails: length, exact-repeat, prompt-injection, domain
    // relevance — all run on-device, before any API call, so a blocked
    // question costs zero tokens. ─────────────────────────────────────────
    final guard = _guardrail.check(
      question: trimmed,
      schema: _schema,
      recentHistory: _messages,
    );
    if (!guard.isAllowed) {
      await _appendExchange(
        question: trimmed,
        answerState: MessageState.done,
        answerContent: guard.reasonMessage!,
      );
      return;
    }

    _isProcessing = true;

    final userMsg = ChatMessage(
      id: '${DateTime.now().millisecondsSinceEpoch}_u',
      role: MessageRole.user,
      content: trimmed,
      state: MessageState.done,
      timestamp: DateTime.now(),
    );
    _messages.add(userMsg);

    final assistantId = '${DateTime.now().millisecondsSinceEpoch}_a';
    _messages.add(ChatMessage(
      id: assistantId,
      role: MessageRole.assistant,
      content: '',
      state: MessageState.thinking,
      timestamp: DateTime.now(),
    ));
    notifyListeners();

    // Compact history for follow-up resolution: question + generated SQL
    // only, from successful prior turns in *this* chat, oldest first,
    // capped inside LlmService. Full narrative answers and raw rows are
    // deliberately left out — see SqlHistoryTurn.
    final sqlHistory = _messages
        .where((m) =>
            m.isAssistant &&
            m.state == MessageState.done &&
            m.generatedSql != null &&
            m.generatedSql!.isNotEmpty)
        .map((m) {
      final idx = _messages.indexOf(m);
      final priorUser = idx > 0 ? _messages[idx - 1] : null;
      if (priorUser == null || !priorUser.isUser) return null;
      return SqlHistoryTurn(question: priorUser.content, sql: m.generatedSql!);
    }).whereType<SqlHistoryTurn>().toList();

    String streamedContent = '';

    try {
      final result = await QueryService.instance.ask(
        question: trimmed,
        schema: _schema,
        history: sqlHistory,
        onToken: (token) {
          streamedContent += token;
          _updateAssistantMessage(
            assistantId,
            content: streamedContent,
            state: MessageState.streaming,
          );
        },
      );

      _updateAssistantMessage(
        assistantId,
        content: result.summary.isNotEmpty ? result.summary : streamedContent,
        state: MessageState.done,
        generatedSql: result.generatedSql,
        rawData: result.rawJson,
        selectedTableNames: result.selectedTableNames,
      );
    } catch (e) {
      _updateAssistantMessage(
        assistantId,
        content: 'Something went wrong. Please try again.',
        state: MessageState.error,
      );
    }

    _isProcessing = false;
    await _persistCurrentChat(firstQuestionForTitle: trimmed);
    notifyListeners();
  }

  /// Adds a user question and an already-final assistant reply in one go —
  /// used for guardrail-blocked turns, which never touch the LLM and so
  /// never go through the streaming/thinking states.
  Future<void> _appendExchange({
    required String question,
    required MessageState answerState,
    required String answerContent,
  }) async {
    _messages.add(ChatMessage(
      id: '${DateTime.now().millisecondsSinceEpoch}_u',
      role: MessageRole.user,
      content: question,
      state: MessageState.done,
      timestamp: DateTime.now(),
    ));
    _messages.add(ChatMessage(
      id: '${DateTime.now().millisecondsSinceEpoch}_a',
      role: MessageRole.assistant,
      content: answerContent,
      state: answerState,
      timestamp: DateTime.now(),
    ));
    await _persistCurrentChat(firstQuestionForTitle: question);
    notifyListeners();
  }

  void _updateAssistantMessage(
    String id, {
    required String content,
    required MessageState state,
    String? generatedSql,
    String? rawData,
    List<String>? selectedTableNames,
  }) {
    final idx = _messages.indexWhere((m) => m.id == id);
    if (idx == -1) return;
    _messages[idx] = _messages[idx].copyWith(
      content: content,
      state: state,
      generatedSql: generatedSql,
      rawData: rawData,
      selectedTableNames: selectedTableNames,
    );
    notifyListeners();
  }

  /// Persists the current conversation and (on its very first exchange)
  /// creates its history entry with a title derived from the first
  /// question — no LLM call involved, so this costs nothing.
  Future<void> _persistCurrentChat({required String firstQuestionForTitle}) async {
    final isNewChat = _currentChatId == null;
    final chatId = _currentChatId ?? _history.newChatId();
    _currentChatId = chatId;

    await _history.saveMessages(chatId, _messages);

    if (isNewChat) {
      final title = _history.titleFromQuestion(firstQuestionForTitle);
      _chatIndex = [
        ChatSummary(id: chatId, title: title, updatedAt: DateTime.now()),
        ..._chatIndex,
      ];
    } else {
      _chatIndex = _chatIndex
          .map((c) =>
              c.id == chatId ? c.copyWith(updatedAt: DateTime.now()) : c)
          .toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    }
    await _history.saveIndex(_chatIndex);
  }

  void _setStatus(AppStatus status, String message) {
    _status = status;
    _statusMessage = message;
    notifyListeners();
  }
}
