import 'package:flutter_tts/flutter_tts.dart';

class TextToSpeechService {
  final FlutterTts _tts = FlutterTts();
  bool _configured = false;

  Future<void> configure() async {
    if (_configured) return;
    await _tts.setSpeechRate(0.48);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    await _tts.awaitSpeakCompletion(true);
    _configured = true;
  }

  Future<void> speak({
    required String text,
    required String languageCode,
    required void Function() onComplete,
    required void Function(String message) onError,
  }) async {
    await configure();
    await _tts.stop();
    _tts.setCompletionHandler(onComplete);
    _tts.setCancelHandler(onComplete);
    _tts.setErrorHandler((message) => onError(message.toString()));
    final detectedLanguage = _detectLanguage(text, fallback: languageCode);
    await _tts.setLanguage(detectedLanguage == 'tr' ? 'tr-TR' : 'en-US');
    await _tts.speak(text);
  }

  Future<void> stop() => _tts.stop();

  String _detectLanguage(String text, {required String fallback}) {
    final normalized = text.toLowerCase();
    var turkishScore = RegExp(r'[çğıöşü]').allMatches(normalized).length * 3;
    var englishScore = 0;
    final words = RegExp(r"[a-zçğıöşü']+")
        .allMatches(normalized)
        .map((match) => match.group(0))
        .whereType<String>();

    const turkishWords = {
      'bir',
      'bu',
      've',
      'ile',
      'için',
      'olarak',
      'de',
      'da',
      'ne',
      'nasıl',
      'neden',
      'merhaba',
      'evet',
      'hayır',
      'yardımcı',
      'olabilir',
      'teşekkür',
      'lütfen',
      'göre',
      'daha',
    };
    const englishWords = {
      'the',
      'a',
      'an',
      'and',
      'or',
      'is',
      'are',
      'for',
      'with',
      'this',
      'that',
      'what',
      'how',
      'why',
      'hello',
      'yes',
      'no',
      'please',
      'thank',
      'you',
      'can',
      'help',
      'more',
    };

    for (final word in words) {
      if (turkishWords.contains(word)) turkishScore += 1;
      if (englishWords.contains(word)) englishScore += 1;
    }

    if (turkishScore > englishScore) return 'tr';
    if (englishScore > turkishScore) return 'en';
    return fallback == 'tr' ? 'tr' : 'en';
  }
}
