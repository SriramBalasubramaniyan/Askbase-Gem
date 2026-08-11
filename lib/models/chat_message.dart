import 'package:flutter/foundation.dart';

enum MessageRole { user, assistant }
enum MessageState { idle, thinking, streaming, done, error }

@immutable
class ChatMessage {
  final String id;
  final MessageRole role;
  final String content;
  final MessageState state;
  final DateTime timestamp;
  final String? generatedSql;
  final String? rawData;

  /// Debug-only: tables selected by SchemaSelector for this response.
  /// Null in release builds.
  final List<String>? selectedTableNames;

  const ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    this.state = MessageState.idle,
    required this.timestamp,
    this.generatedSql,
    this.rawData,
    this.selectedTableNames,
  });

  ChatMessage copyWith({
    String? content,
    MessageState? state,
    String? generatedSql,
    String? rawData,
    List<String>? selectedTableNames,
  }) {
    return ChatMessage(
      id: id,
      role: role,
      content: content ?? this.content,
      state: state ?? this.state,
      timestamp: timestamp,
      generatedSql: generatedSql ?? this.generatedSql,
      rawData: rawData ?? this.rawData,
      selectedTableNames: selectedTableNames ?? this.selectedTableNames,
    );
  }

  bool get isUser => role == MessageRole.user;
  bool get isAssistant => role == MessageRole.assistant;
  bool get isLoading =>
      state == MessageState.thinking || state == MessageState.streaming;

  // ── Persistence ─────────────────────────────────────────────────────────
  // Only messages in a settled state (done/error) are ever persisted — see
  // ChatHistoryService — so state always round-trips as "done" or "error".

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role.name,
        'content': content,
        'state': state.name,
        'timestamp': timestamp.toIso8601String(),
        'generatedSql': generatedSql,
        'rawData': rawData,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String,
      role: MessageRole.values.byName(json['role'] as String),
      content: json['content'] as String,
      state: MessageState.values.byName(json['state'] as String? ?? 'done'),
      timestamp: DateTime.parse(json['timestamp'] as String),
      generatedSql: json['generatedSql'] as String?,
      rawData: json['rawData'] as String?,
    );
  }
}
