import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_message.dart';
import '../models/chat_session.dart';

const _prefKeyIndex = 'chat_index';
const _prefKeyChatPrefix = 'chat_session:';

/// Local persistence for chat sessions. Two layers, kept separate on
/// purpose so opening the history drawer never has to load every
/// conversation's full message list — only the small index is read
/// up front; a chat's messages are loaded on demand when it's opened.
class ChatHistoryService {
  ChatHistoryService._();
  static final ChatHistoryService instance = ChatHistoryService._();

  /// Chats older than this many days are dropped from the index the next
  /// time it's saved — a simple, dependency-free way to keep local storage
  /// (and the drawer list) from growing unbounded over long-term use.
  static const int _maxAgeDays = 90;

  /// Hard cap on how many chats are kept regardless of age.
  static const int _maxChats = 200;

  Future<List<ChatSummary>> loadIndex() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefKeyIndex);
    if (raw == null || raw.isEmpty) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    final summaries = list
        .map((e) => ChatSummary.fromJson(e as Map<String, dynamic>))
        .toList();
    summaries.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return summaries;
  }

  Future<void> saveIndex(List<ChatSummary> summaries) async {
    final cutoff = DateTime.now().subtract(const Duration(days: _maxAgeDays));
    final pruned = summaries.where((s) => s.updatedAt.isAfter(cutoff)).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final capped =
        pruned.length > _maxChats ? pruned.sublist(0, _maxChats) : pruned;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefKeyIndex,
      jsonEncode(capped.map((s) => s.toJson()).toList()),
    );

    // Clean up message payloads for any chat that fell out of the index.
    final keptIds = capped.map((s) => s.id).toSet();
    for (final old in summaries) {
      if (!keptIds.contains(old.id)) {
        await prefs.remove('$_prefKeyChatPrefix${old.id}');
      }
    }
  }

  Future<List<ChatMessage>> loadMessages(String chatId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_prefKeyChatPrefix$chatId');
    if (raw == null || raw.isEmpty) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveMessages(String chatId, List<ChatMessage> messages) async {
    final prefs = await SharedPreferences.getInstance();
    // Only settled messages are worth persisting — an in-flight
    // "thinking"/"streaming" placeholder has no meaning after a restart.
    final settled = messages
        .where((m) =>
            m.state == MessageState.done || m.state == MessageState.error)
        .toList();
    await prefs.setString(
      '$_prefKeyChatPrefix$chatId',
      jsonEncode(settled.map((m) => m.toJson()).toList()),
    );
  }

  Future<void> deleteChat(String chatId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefKeyChatPrefix$chatId');
  }

  /// Derives a chat title from its first user question — no model call
  /// involved, so this costs zero tokens. Truncates at a word boundary
  /// rather than mid-word.
  String titleFromQuestion(String question) {
    final cleaned = question.trim().replaceAll(RegExp(r'\s+'), ' ');
    const maxLen = 42;
    if (cleaned.length <= maxLen) return cleaned;
    final truncated = cleaned.substring(0, maxLen);
    final lastSpace = truncated.lastIndexOf(' ');
    final cut = lastSpace > 20 ? truncated.substring(0, lastSpace) : truncated;
    return '$cut…';
  }

  String newChatId() =>
      '${DateTime.now().millisecondsSinceEpoch}_${_shortRandom()}';

  String _shortRandom() =>
      (DateTime.now().microsecondsSinceEpoch % 100000).toString();
}
