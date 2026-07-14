import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/chat_message.dart';
import '../services/ai_chat_service.dart';
import '../services/speech_recognition_service.dart';
import '../services/text_to_speech_service.dart';

enum VoiceChatState { idle, preparing, listening, sending, speaking, error }

class VoiceChatProvider extends ChangeNotifier {
  VoiceChatProvider({
    required AiChatService aiService,
    SpeechRecognitionService? speechService,
    TextToSpeechService? ttsService,
  })  : _aiService = aiService,
        _speechService = speechService ?? SpeechRecognitionService(),
        _ttsService = ttsService ?? TextToSpeechService();

  final AiChatService _aiService;
  final SpeechRecognitionService _speechService;
  final TextToSpeechService _ttsService;
  final List<ChatMessage> _messages = [];

  VoiceChatState _state = VoiceChatState.idle;
  String _draft = '';
  String _speechBaseDraft = '';
  String? _errorMessage;
  String? _speakingMessageId;
  bool _autoRead = false;
  double _soundLevel = 0;
  double _minimumSoundLevel = 500;
  double _maximumSoundLevel = -500;
  int _messageSequence = 0;
  int _speechSession = 0;
  bool _disposed = false;

  List<ChatMessage> get messages => List.unmodifiable(_messages);
  VoiceChatState get state => _state;
  String get draft => _draft;
  String? get errorMessage => _errorMessage;
  String? get speakingMessageId => _speakingMessageId;
  bool get autoRead => _autoRead;
  double get soundLevel => _soundLevel;
  bool get isListening => _state == VoiceChatState.listening;
  bool get isSending => _state == VoiceChatState.sending;
  bool get isSpeaking => _state == VoiceChatState.speaking;
  bool get canSend => _draft.trim().isNotEmpty && !isSending;

  void updateDraft(String value) {
    if (_draft == value) return;
    _draft = value;
    _errorMessage = null;
    _notify();
  }

  void setAutoRead(bool value) {
    _autoRead = value;
    _notify();
  }

  Future<void> toggleListening(String languageCode) async {
    if (isListening) {
      await stopListening();
    } else {
      await startListening(languageCode);
    }
  }

  Future<void> startListening(String languageCode) async {
    if (isSending || _state == VoiceChatState.preparing) return;
    await stopSpeaking();
    final session = ++_speechSession;
    _state = VoiceChatState.preparing;
    _errorMessage = null;
    _speechBaseDraft = _draft.trim();
    _minimumSoundLevel = 500;
    _maximumSoundLevel = -500;
    _soundLevel = 0;
    _notify();

    try {
      final started = await _speechService.startListening(
        languageCode: languageCode,
        onText: (text, isFinal) {
          if (session == _speechSession) {
            _handleSpeechText(text, isFinal);
          }
        },
        onSoundLevel: (level) {
          if (session == _speechSession) {
            _handleSoundLevel(level);
          }
        },
        onStatus: (status) {
          if (session == _speechSession) {
            _handleSpeechStatus(status);
          }
        },
        onError: (message, permanent) {
          if (session == _speechSession) {
            _handleSpeechError(message, permanent);
          }
        },
      );
      if (session != _speechSession) return;
      if (!started) {
        if (_errorMessage == null) {
          _state = VoiceChatState.error;
          _errorMessage = 'voice_chat_speech_unavailable';
        }
      } else {
        _state = VoiceChatState.listening;
      }
    } catch (error) {
      if (session != _speechSession) return;
      _state = VoiceChatState.error;
      _errorMessage = error.toString();
    }
    _notify();
  }

  Future<void> stopListening() async {
    _speechSession += 1;
    await _speechService.stop();
    if (_state == VoiceChatState.listening || _state == VoiceChatState.preparing) {
      _state = VoiceChatState.idle;
      _soundLevel = 0;
      _notify();
    }
  }

  Future<void> sendMessage(String languageCode) async {
    final text = _draft.trim();
    if (text.isEmpty || isSending) return;
    await stopListening();
    await stopSpeaking();

    _messages.add(_newMessage(text, ChatRole.user));
    _draft = '';
    _speechBaseDraft = '';
    _state = VoiceChatState.sending;
    _errorMessage = null;
    _notify();

    try {
      final answer = await _aiService.sendMessage(
        message: text,
        history: List.unmodifiable(_messages),
        languageCode: languageCode,
      );
      if (answer.trim().isEmpty) throw StateError('Empty AI response');
      final assistantMessage = _newMessage(answer.trim(), ChatRole.assistant);
      _messages.add(assistantMessage);
      _state = VoiceChatState.idle;
      _notify();
      if (_autoRead) await speakMessage(assistantMessage, languageCode);
    } on AiChatException catch (error) {
      _state = VoiceChatState.error;
      _errorMessage = error.messageKey;
      _notify();
    } catch (error) {
      _state = VoiceChatState.error;
      _errorMessage = 'voice_chat_ai_error';
      _notify();
    }
  }

  Future<void> speakMessage(ChatMessage message, String languageCode) async {
    if (message.role != ChatRole.assistant) return;
    if (_speakingMessageId == message.id) {
      await stopSpeaking();
      return;
    }
    await stopListening();
    await _ttsService.stop();
    _speakingMessageId = message.id;
    _state = VoiceChatState.speaking;
    _errorMessage = null;
    _notify();
    try {
      await _ttsService.speak(
        text: message.text,
        languageCode: languageCode,
        onComplete: _finishSpeaking,
        onError: (message) {
          _speakingMessageId = null;
          _state = VoiceChatState.error;
          _errorMessage = 'voice_chat_tts_error';
          _notify();
        },
      );
    } catch (error) {
      _speakingMessageId = null;
      _state = VoiceChatState.error;
      _errorMessage = 'voice_chat_tts_error';
      _notify();
    }
  }

  Future<void> stopSpeaking() async {
    if (_speakingMessageId == null && _state != VoiceChatState.speaking) return;
    await _ttsService.stop();
    _finishSpeaking();
  }

  Future<void> leaveScreen() async {
    _speechSession += 1;
    await _speechService.cancel();
    await _ttsService.stop();
    _speakingMessageId = null;
    if (_state != VoiceChatState.sending) _state = VoiceChatState.idle;
    _soundLevel = 0;
    _notify();
  }

  void clearError() {
    _errorMessage = null;
    if (_state == VoiceChatState.error) _state = VoiceChatState.idle;
    _notify();
  }

  Future<void> clearConversation() async {
    await stopListening();
    await stopSpeaking();
    _messages.clear();
    _draft = '';
    _errorMessage = null;
    if (!isSending) _state = VoiceChatState.idle;
    _notify();
  }

  void _handleSpeechText(String text, bool isFinal) {
    final recognized = text.trim();
    _draft = [_speechBaseDraft, recognized].where((part) => part.isNotEmpty).join(' ');
    if (isFinal && _state == VoiceChatState.listening) {
      _state = VoiceChatState.idle;
      _soundLevel = 0;
    }
    _notify();
  }

  void _handleSpeechStatus(String status) {
    if ((status == 'done' || status == 'notListening') && _state == VoiceChatState.listening) {
      _state = VoiceChatState.idle;
      _soundLevel = 0;
      _notify();
    }
  }

  void _handleSpeechError(String message, bool permanent) {
    _state = VoiceChatState.error;
    _errorMessage = _speechErrorKey(message);
    _soundLevel = 0;
    _notify();
  }

  void _handleSoundLevel(double level) {
    _minimumSoundLevel = level < _minimumSoundLevel ? level : _minimumSoundLevel;
    _maximumSoundLevel = level > _maximumSoundLevel ? level : _maximumSoundLevel;
    final range = _maximumSoundLevel - _minimumSoundLevel;
    _soundLevel = range <= 0
        ? 0.15
        : ((level - _minimumSoundLevel) / range).clamp(0.0, 1.0).toDouble();
    _notify();
  }

  String _speechErrorKey(String message) {
    final normalized = message.toLowerCase();
    if (normalized.contains('permission') || normalized.contains('notallowed')) {
      return 'voice_chat_microphone_permission';
    }
    if (normalized.contains('network')) return 'voice_chat_network_error';
    if (normalized.contains('no_match') || normalized.contains('speech_timeout')) {
      return 'voice_chat_no_speech';
    }
    return 'voice_chat_speech_error';
  }

  ChatMessage _newMessage(String text, ChatRole role) {
    _messageSequence += 1;
    return ChatMessage(
      id: '${DateTime.now().microsecondsSinceEpoch}-$_messageSequence',
      text: text,
      role: role,
      createdAt: DateTime.now(),
    );
  }

  void _finishSpeaking() {
    _speakingMessageId = null;
    if (_state == VoiceChatState.speaking) _state = VoiceChatState.idle;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _speechSession += 1;
    unawaited(_speechService.cancel());
    unawaited(_ttsService.stop());
    super.dispose();
  }
}
