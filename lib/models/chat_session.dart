import 'package:flutter/foundation.dart';

/// Lightweight metadata for one saved conversation — enough to render the
/// chat history list without loading every conversation's full message
/// list into memory. Full messages are loaded lazily via
/// ChatHistoryService.loadMessages(id) only when a chat is opened.
@immutable
class ChatSummary {
  final String id;
  final String title;
  final DateTime updatedAt;

  const ChatSummary({
    required this.id,
    required this.title,
    required this.updatedAt,
  });

  ChatSummary copyWith({String? title, DateTime? updatedAt}) => ChatSummary(
        id: id,
        title: title ?? this.title,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory ChatSummary.fromJson(Map<String, dynamic> json) => ChatSummary(
        id: json['id'] as String,
        title: json['title'] as String,
        updatedAt: DateTime.parse(json['updatedAt'] as String),
      );
}
