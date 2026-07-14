import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

typedef SpeechTextCallback = void Function(String text, bool isFinal);
typedef SpeechStatusCallback = void Function(String status);
typedef SpeechErrorCallback = void Function(String message, bool permanent);

class SpeechRecognitionService {
  final SpeechToText _speech = SpeechToText();
  SpeechStatusCallback? _statusCallback;
  SpeechErrorCallback? _errorCallback;
  bool _initialized = false;

  bool get isListening => _speech.isListening;

  Future<bool> initialize({
    required SpeechStatusCallback onStatus,
    required SpeechErrorCallback onError,
  }) async {
    _statusCallback = onStatus;
    _errorCallback = onError;
    if (_initialized) return true;
    _initialized = await _speech.initialize(
      onStatus: (status) => _statusCallback?.call(status),
      onError: _handleError,
      finalTimeout: const Duration(seconds: 2),
    );
    return _initialized;
  }

  Future<bool> startListening({
    required String languageCode,
    required SpeechTextCallback onText,
    required void Function(double level) onSoundLevel,
    required SpeechStatusCallback onStatus,
    required SpeechErrorCallback onError,
  }) async {
    final available = await initialize(onStatus: onStatus, onError: onError);
    if (!available) return false;
    if (_speech.isListening) await _speech.stop();

    final localeId = await _resolveLocale(languageCode);
    await _speech.listen(
      onResult: (SpeechRecognitionResult result) {
        onText(result.recognizedWords, result.finalResult);
      },
      onSoundLevelChange: onSoundLevel,
      listenOptions: SpeechListenOptions(
        cancelOnError: true,
        partialResults: true,
        listenMode: ListenMode.dictation,
        autoPunctuation: true,
        pauseFor: const Duration(seconds: 3),
        listenFor: const Duration(seconds: 45),
        localeId: localeId,
      ),
    );
    return _speech.isListening;
  }

  Future<void> stop() async {
    if (_speech.isListening) await _speech.stop();
  }

  Future<void> cancel() async {
    if (_speech.isListening) await _speech.cancel();
  }

  Future<String?> _resolveLocale(String languageCode) async {
    final locales = await _speech.locales();
    for (final locale in locales) {
      final normalized = locale.localeId.toLowerCase().replaceAll('-', '_');
      if (normalized == '${languageCode.toLowerCase()}_${languageCode == 'tr' ? 'tr' : 'us'}') {
        return locale.localeId;
      }
    }
    for (final locale in locales) {
      if (locale.localeId.toLowerCase().startsWith(languageCode.toLowerCase())) {
        return locale.localeId;
      }
    }
    return (await _speech.systemLocale())?.localeId;
  }

  void _handleError(SpeechRecognitionError error) {
    _errorCallback?.call(error.errorMsg, error.permanent);
  }
}
