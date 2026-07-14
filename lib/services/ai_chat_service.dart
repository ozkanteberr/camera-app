import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/chat_message.dart';

abstract class AiChatService {
  Future<String> sendMessage({
    required String message,
    required List<ChatMessage> history,
    required String languageCode,
  });
}

class AiChatException implements Exception {
  const AiChatException(this.messageKey);

  final String messageKey;
}

class GeminiAiChatService implements AiChatService {
  GeminiAiChatService({
    required String apiKey,
    this.model = 'gemini-flash-latest',
    http.Client? client,
  })  : _apiKey = apiKey.trim(),
        _client = client ?? http.Client();

  static const _baseUrl = 'https://generativelanguage.googleapis.com/v1beta/models';
  static const _requestTimeout = Duration(seconds: 35);
  static const _maximumHistoryMessages = 20;

  final String _apiKey;
  final String model;
  final http.Client _client;
  String? _resolvedModel;

  @override
  Future<String> sendMessage({
    required String message,
    required List<ChatMessage> history,
    required String languageCode,
  }) async {
    if (_apiKey.isEmpty || _apiKey == 'your_gemini_api_key_here') {
      _log('Request stopped: GEMINI_API_KEY is missing.');
      throw const AiChatException('voice_chat_api_key_missing');
    }

    final contents = _conversationContents(message, history);
    var activeModel = _resolvedModel ?? _normalizeModelName(model);
    final stopwatch = Stopwatch()..start();
    _log(
      'Request started: model=$activeModel, '
      'conversationItems=${contents.length}.',
    );
    final body = jsonEncode({
      'system_instruction': {
        'parts': [
          {
            'text': languageCode == 'tr'
                ? 'Sen yardımcı, açık ve güvenilir bir asistansın. Önceki mesajlar başka dilde olsa bile kullanıcı açıkça farklı bir dil istemedikçe bütün yanıtını Türkçe ve mümkün olduğunca öz yaz.'
                : 'You are a helpful, clear, and reliable assistant. Even if earlier messages are in another language, write your entire response in English unless the user explicitly requests a different language.',
          },
        ],
      },
      'contents': contents,
      'generationConfig': {
        'temperature': 0.7,
        'maxOutputTokens': 1024,
      },
    });

    try {
      var response = await _generateContent(activeModel, body);

      if (response.statusCode == 404) {
        _log('Configured model was not found. Discovering available models.');
        final fallbackModel = await _findAvailableFlashModel(
          excludedModel: activeModel,
        );
        if (fallbackModel != null) {
          activeModel = fallbackModel;
          _resolvedModel = fallbackModel;
          _log('Retrying with discovered model=$activeModel.');
          response = await _generateContent(activeModel, body);
        }
      }

      final responseBody = utf8.decode(response.bodyBytes);
      final data = _decodeResponse(responseBody);
      _log(
        'Response received: status=${response.statusCode}, '
        'elapsedMs=${stopwatch.elapsedMilliseconds}.',
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        _log(
          'Gemini API error: status=${response.statusCode}, '
          'detail=${_apiErrorDetail(data)}.',
        );
        throw AiChatException(_errorKeyForStatus(response.statusCode));
      }

      final text = _extractText(data);
      if (text.isEmpty) {
        _log('Empty response: ${_emptyResponseDetail(data)}.');
        throw const AiChatException('voice_chat_response_blocked');
      }
      _log(
        'Request completed: elapsedMs=${stopwatch.elapsedMilliseconds}, '
        'responseCharacters=${text.length}.',
      );
      return text;
    } on AiChatException catch (error) {
      _log('Request failed: messageKey=${error.messageKey}.');
      rethrow;
    } on TimeoutException catch (error, stackTrace) {
      _log('Request timed out.', error: error, stackTrace: stackTrace);
      throw const AiChatException('voice_chat_ai_timeout');
    } on SocketException catch (error, stackTrace) {
      _log('Socket error.', error: error, stackTrace: stackTrace);
      throw const AiChatException('voice_chat_ai_network_error');
    } on http.ClientException catch (error, stackTrace) {
      _log('HTTP client error.', error: error, stackTrace: stackTrace);
      throw const AiChatException('voice_chat_ai_network_error');
    } on FormatException catch (error, stackTrace) {
      _log('Invalid JSON response.', error: error, stackTrace: stackTrace);
      throw const AiChatException('voice_chat_ai_error');
    } catch (error, stackTrace) {
      _log('Unexpected error.', error: error, stackTrace: stackTrace);
      throw const AiChatException('voice_chat_ai_error');
    }
  }

  Future<http.Response> _generateContent(String modelName, String body) {
    final uri = Uri.parse('$_baseUrl/$modelName:generateContent');
    return _client
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'x-goog-api-key': _apiKey,
          },
          body: body,
        )
        .timeout(_requestTimeout);
  }

  Future<String?> _findAvailableFlashModel({
    required String excludedModel,
  }) async {
    final response = await _client
        .get(
          Uri.parse('$_baseUrl?pageSize=1000'),
          headers: {'x-goog-api-key': _apiKey},
        )
        .timeout(_requestTimeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final data = _decodeResponse(utf8.decode(response.bodyBytes));
      _log(
        'Model discovery failed: status=${response.statusCode}, '
        'detail=${_apiErrorDetail(data)}.',
      );
      return null;
    }

    final data = _decodeResponse(utf8.decode(response.bodyBytes));
    final models = data['models'];
    if (models is! List) return null;

    final availableModels = models
        .whereType<Map<String, dynamic>>()
        .where(_supportsGenerateContent)
        .map((item) => _normalizeModelName(item['name']?.toString() ?? ''))
        .where(_isTextFlashModel)
        .where((name) => name != excludedModel)
        .toList();

    _log(
      'Discovered Flash models: '
      '${_safeLogText(availableModels.join(', '))}.',
    );
    if (availableModels.isEmpty) return null;

    const preferences = [
      'gemini-3.5-flash',
      'gemini-3.1-flash-lite',
      'gemini-3-flash',
      'gemini-flash-latest',
      'gemini-2.5-flash-lite',
      'gemini-2.5-flash',
    ];
    for (final preferred in preferences) {
      if (availableModels.contains(preferred)) return preferred;
    }
    availableModels.sort((left, right) => right.compareTo(left));
    return availableModels.first;
  }

  bool _supportsGenerateContent(Map<String, dynamic> modelData) {
    final methods = modelData['supportedGenerationMethods'] ??
        modelData['supportedActions'];
    return methods is List && methods.contains('generateContent');
  }

  bool _isTextFlashModel(String name) {
    final normalized = name.toLowerCase();
    if (!normalized.contains('gemini') || !normalized.contains('flash')) {
      return false;
    }
    const excludedKinds = [
      'image',
      'tts',
      'live',
      'audio',
      'embedding',
      'vision',
    ];
    return !excludedKinds.any(normalized.contains);
  }

  String _normalizeModelName(String name) {
    final trimmed = name.trim();
    return trimmed.startsWith('models/') ? trimmed.substring(7) : trimmed;
  }

  List<Map<String, Object>> _conversationContents(
    String message,
    List<ChatMessage> history,
  ) {
    final start = history.length > _maximumHistoryMessages
        ? history.length - _maximumHistoryMessages
        : 0;
    final recentHistory = history.sublist(start);
    final contents = recentHistory
        .map(
          (item) => <String, Object>{
            'role': item.role == ChatRole.user ? 'user' : 'model',
            'parts': [
              {'text': item.text},
            ],
          },
        )
        .toList();

    if (recentHistory.isEmpty ||
        recentHistory.last.role != ChatRole.user ||
        recentHistory.last.text != message) {
      contents.add({
        'role': 'user',
        'parts': [
          {'text': message},
        ],
      });
    }
    return contents;
  }

  Map<String, dynamic> _decodeResponse(String body) {
    if (body.isEmpty) return const {};
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) throw const FormatException();
    return decoded;
  }

  String _extractText(Map<String, dynamic> data) {
    final candidates = data['candidates'];
    if (candidates is! List || candidates.isEmpty) return '';
    final candidate = candidates.first;
    if (candidate is! Map<String, dynamic>) return '';
    final content = candidate['content'];
    if (content is! Map<String, dynamic>) return '';
    final parts = content['parts'];
    if (parts is! List) return '';

    return parts
        .whereType<Map<String, dynamic>>()
        .map((part) => part['text'])
        .whereType<String>()
        .join('\n')
        .trim();
  }

  String _errorKeyForStatus(int statusCode) {
    if (statusCode == 400) return 'voice_chat_request_error';
    if (statusCode == 401 || statusCode == 403) {
      return 'voice_chat_api_key_invalid';
    }
    if (statusCode == 404) return 'voice_chat_model_unavailable';
    if (statusCode == 429) return 'voice_chat_quota_exceeded';
    if (statusCode >= 500) return 'voice_chat_ai_server_error';
    return 'voice_chat_ai_error';
  }

  String _apiErrorDetail(Map<String, dynamic> data) {
    final error = data['error'];
    if (error is! Map<String, dynamic>) return 'No error detail';
    final status = error['status']?.toString() ?? 'unknown';
    final message = error['message']?.toString() ?? 'No message';
    return '$status: ${_safeLogText(message)}';
  }

  String _emptyResponseDetail(Map<String, dynamic> data) {
    final promptFeedback = data['promptFeedback'];
    if (promptFeedback is Map<String, dynamic>) {
      final blockReason = promptFeedback['blockReason'];
      if (blockReason != null) return 'promptBlockReason=$blockReason';
    }
    final candidates = data['candidates'];
    if (candidates is List && candidates.isNotEmpty) {
      final candidate = candidates.first;
      if (candidate is Map<String, dynamic>) {
        return 'finishReason=${candidate['finishReason'] ?? 'unknown'}';
      }
    }
    return 'No candidate content';
  }

  String _safeLogText(String value) {
    final redacted = value.replaceAll(_apiKey, '[REDACTED]').replaceAll('\n', ' ');
    return redacted.length <= 500 ? redacted : '${redacted.substring(0, 500)}...';
  }

  void _log(
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (!kDebugMode) return;
    developer.log(
      message,
      name: 'GeminiAiChat',
      error: error,
      stackTrace: stackTrace,
    );
  }
}
