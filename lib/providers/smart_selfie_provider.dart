import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:hive/hive.dart';

class SmartSelfieProvider extends ChangeNotifier {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  bool _isInitialized = false;
  bool _isProcessing = false;
  bool _isStreamRunning = false;
  bool _isViewActive = false;
  bool _isCountingDown = false;
  bool _isCapturing = false;

  int _selectedCameraIndex = 0;
  String _guidanceKey = 'yuz_bulunamadi';
  int? _countdown;
  DateTime? _lastProcessedTime;
  Rect? _faceBoundingBox;
  Size? _cameraImageSize;

  late final FaceDetector _faceDetector;
  final FlutterTts _flutterTts = FlutterTts();
  final Map<String, String> _spokenMessages = {};
  String? _lastSpokenKey;
  bool _isSpeaking = false;
  DateTime? _lastSpeechTime;

  CameraController? get controller => _controller;
  bool get isInitialized => _isInitialized;
  bool get isCountingDown => _isCountingDown;
  bool get isCapturing => _isCapturing;
  String get guidanceKey => _guidanceKey;
  int? get countdown => _countdown;
  Rect? get faceBoundingBox => _faceBoundingBox;
  Size? get cameraImageSize => _cameraImageSize;

  SmartSelfieProvider() {
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableClassification: false,
        enableTracking: true,
        performanceMode: FaceDetectorMode.accurate,
      ),
    );
    _configureTts();
  }

  Future<void> _configureTts() async {
    await _flutterTts.setSpeechRate(0.48);
    await _flutterTts.setVolume(1.0);
    await _flutterTts.setPitch(1.0);
    await _flutterTts.awaitSpeakCompletion(true);
    _flutterTts.setCompletionHandler(() => _isSpeaking = false);
    _flutterTts.setCancelHandler(() => _isSpeaking = false);
    _flutterTts.setErrorHandler((_) => _isSpeaking = false);
  }

  Future<void> setVoiceLanguage(String languageCode) async {
    await _flutterTts.setLanguage(languageCode);
  }

  void setSpokenMessages(Map<String, String> messages) {
    _spokenMessages
      ..clear()
      ..addAll(messages);
  }

  void setViewActive(bool active) {
    _isViewActive = active;
    if (!active) {
      _cancelCountdown();
      _clearFaceOverlay(notify: false);
      _stopSpeaking();
    }
  }

  Future<void> initializeCameras() async {
    if (_controller != null) return;

    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        debugPrint("Cihazda kamera bulunamadı.");
        return;
      }

      _selectedCameraIndex = _cameras.indexWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
      );
      if (_selectedCameraIndex == -1) _selectedCameraIndex = 0;

      await _setupCameraController();
    } catch (e) {
      debugPrint("Smart Selfie kamerası başlatılırken hata: $e");
    }
  }

  Future<void> _setupCameraController() async {
    if (_cameras.isEmpty) return;

    _isInitialized = false;
    _isProcessing = false;
    _isStreamRunning = false;
    notifyListeners();

    if (_controller != null) {
      await _controller!.dispose();
      _controller = null;
    }

    _controller = CameraController(
      _cameras[_selectedCameraIndex],
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );

    try {
      await _controller!.initialize();
      _isInitialized = true;
      notifyListeners();
      _startLiveStream();
    } catch (e) {
      debugPrint("Smart Selfie kamera başlatılamadı: $e");
    }
  }

  void _startLiveStream() {
    final controller = _controller;
    if (controller == null || !_isInitialized || _isStreamRunning) return;

    try {
      _isStreamRunning = true;
      controller.startImageStream((CameraImage image) async {
        if (!_isViewActive ||
            _isProcessing ||
            _isCountingDown ||
            _isCapturing) {
          return;
        }
        if (_controller != controller || !controller.value.isInitialized) {
          return;
        }

        final now = DateTime.now();
        if (_lastProcessedTime != null &&
            now.difference(_lastProcessedTime!).inMilliseconds < 250) {
          return;
        }

        _isProcessing = true;
        _lastProcessedTime = now;

        try {
          await _processFrame(image);
        } catch (e) {
          if (_isViewActive) {
            debugPrint("Smart Selfie kare işlenirken hata: $e");
          }
        } finally {
          _isProcessing = false;
        }
      });
    } catch (e) {
      debugPrint("Smart Selfie canlı akış başlatılamadı: $e");
      _isStreamRunning = false;
    }
  }

  Future<void> _processFrame(CameraImage image) async {
    final inputImage = _inputImageFromCameraImage(image);
    if (inputImage == null) {
      _clearFaceOverlay();
      _updateGuidanceState('yuz_bulunamadi');
      return;
    }

    final faces = await _faceDetector.processImage(inputImage);
    if (!_isViewActive) return;

    if (faces.isEmpty) {
      _clearFaceOverlay();
      _updateGuidanceState('yuz_bulunamadi');
      return;
    }

    if (faces.length > 1) {
      _clearFaceOverlay();
      _updateGuidanceState('multiple_faces');
      return;
    }

    final face = faces.first;
    final rotatedImageSize =
        Size(image.height.toDouble(), image.width.toDouble());
    _updateFaceOverlay(
      face.boundingBox,
      rotatedImageSize,
    );

    final eulerY = face.headEulerAngleY;
    if (eulerY == null) {
      _updateGuidanceState('yuz_bulunamadi');
      return;
    }

    if (eulerY > 18) {
      _updateGuidanceState('saga_cevir');
      return;
    }

    if (eulerY < -18) {
      _updateGuidanceState('sola_cevir');
      return;
    }

    final faceCenter = face.boundingBox.center;
    final centerX = faceCenter.dx / rotatedImageSize.width;
    final centerY = faceCenter.dy / rotatedImageSize.height;
    const targetX = 0.5;
    const targetY = 0.44;
    const horizontalTolerance = 0.14;
    const verticalTolerance = 0.12;

    if (centerY < targetY - verticalTolerance) {
      _updateGuidanceState('asagi_indir');
      return;
    }

    if (centerY > targetY + verticalTolerance) {
      _updateGuidanceState('yukari_kaldir');
      return;
    }

    if ((centerX - targetX).abs() > horizontalTolerance) {
      _updateGuidanceState('duz_bak');
      return;
    }

    _updateGuidanceState('harika_bekle');
    _startCountdown();
  }

  void _updateFaceOverlay(Rect boundingBox, Size imageSize) {
    final previousBox = _faceBoundingBox;
    final movedEnough = previousBox == null ||
        (previousBox.center - boundingBox.center).distance > 8 ||
        (previousBox.width - boundingBox.width).abs() > 8 ||
        (previousBox.height - boundingBox.height).abs() > 8;

    _faceBoundingBox = boundingBox;
    _cameraImageSize = imageSize;

    if (movedEnough) notifyListeners();
  }

  void _clearFaceOverlay({bool notify = true}) {
    if (_faceBoundingBox == null && _cameraImageSize == null) return;
    _faceBoundingBox = null;
    _cameraImageSize = null;
    if (notify) notifyListeners();
  }

  void _updateGuidanceState(String newKey) {
    if (!_isViewActive) return;

    if (_guidanceKey != newKey) {
      _guidanceKey = newKey;
      notifyListeners();
    }
    _speakGuidance(newKey);
  }

  Future<void> _speakGuidance(String key) async {
    if (!_isViewActive || _isCountingDown || _isCapturing) return;

    final now = DateTime.now();
    final isRecentRepeat = _lastSpokenKey == key &&
        _lastSpeechTime != null &&
        now.difference(_lastSpeechTime!).inSeconds < 4;
    if (_isSpeaking || isRecentRepeat) return;

    _isSpeaking = true;
    _lastSpokenKey = key;
    _lastSpeechTime = now;

    try {
      await _flutterTts.speak(_spokenMessages[key] ?? key);
    } catch (e) {
      _isSpeaking = false;
      debugPrint("Smart Selfie seslendirme hatası: $e");
    }
  }

  void _startCountdown() {
    if (_isCountingDown || _isCapturing || !_isViewActive) return;
    _runCountdown();
  }

  Future<void> _runCountdown() async {
    _isCountingDown = true;

    for (var number = 3; number >= 1; number--) {
      if (!_isViewActive || !_isCountingDown) return;

      _countdown = number;
      notifyListeners();
      await _speakNow(number.toString());

      if (!_isViewActive || !_isCountingDown) return;
      await Future.delayed(const Duration(milliseconds: 650));
    }

    _countdown = null;
    notifyListeners();
    await _captureSelfie();
  }

  Future<void> _speakNow(String message) async {
    if (!_isViewActive) return;

    try {
      await _flutterTts.stop();
      await Future.delayed(const Duration(milliseconds: 120));
      if (!_isViewActive) return;

      _isSpeaking = true;
      await _flutterTts.speak(message);
    } catch (e) {
      debugPrint("Smart Selfie seslendirme hatası: $e");
    } finally {
      _isSpeaking = false;
    }
  }

  Future<void> _captureSelfie() async {
    if (!_isViewActive) return;

    if (_controller == null || !_controller!.value.isInitialized) {
      _isCountingDown = false;
      return;
    }

    if (_controller!.value.isTakingPicture || _isCapturing) return;

    try {
      _isCapturing = true;
      _guidanceKey = 'cekiliyor';
      notifyListeners();
      await _speakNow(_spokenMessages['cekiliyor'] ?? 'cekiliyor');
      await stopLiveStream();

      final image = await _controller!.takePicture();
      final box = Hive.box<String>('photosBox');
      await box.add(image.path);

      _guidanceKey = 'kaydedildi';
      notifyListeners();
      await _speakNow(_spokenMessages['kaydedildi'] ?? 'kaydedildi');
    } catch (e) {
      debugPrint("Smart Selfie çekim/kayıt hatası: $e");
    } finally {
      _isCapturing = false;
      _isCountingDown = false;
      _countdown = null;
      notifyListeners();

      if (_isViewActive &&
          _controller != null &&
          _controller!.value.isInitialized) {
        _startLiveStream();
      }
    }
  }

  Future<void> stopLiveStream() async {
    if (_controller == null) {
      _isStreamRunning = false;
      return;
    }

    try {
      if (_controller!.value.isStreamingImages) {
        await _controller!.stopImageStream();
      }
    } catch (e) {
      debugPrint("Smart Selfie stream durdurulurken hata: $e");
    } finally {
      _isStreamRunning = false;
      _isProcessing = false;
    }
  }

  Future<void> releaseResources({bool notify = true}) async {
    _isViewActive = false;
    _cancelCountdown();
    await _stopSpeaking();

    final controller = _controller;
    _controller = null;
    _isInitialized = false;
    _isStreamRunning = false;
    _isProcessing = false;
    _clearFaceOverlay(notify: false);
    if (notify) notifyListeners();

    if (controller == null) return;

    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } catch (e) {
      debugPrint("Smart Selfie stream kapatılırken hata: $e");
    }

    try {
      await controller.dispose();
    } catch (e) {
      debugPrint("Smart Selfie kamera dispose hatası: $e");
    }
  }

  void _cancelCountdown() {
    _isCountingDown = false;
    _countdown = null;
  }

  Future<void> _stopSpeaking() async {
    try {
      await _flutterTts.stop();
    } catch (_) {
      // tts i durdurmak için.
    } finally {
      _isSpeaking = false;
    }
  }

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    if (_controller == null) return null;

    final camera = _cameras[_selectedCameraIndex];
    final orientation = _controller!.value.deviceOrientation;
    InputImageRotation rotation;

    if (camera.lensDirection == CameraLensDirection.front) {
      switch (orientation) {
        case DeviceOrientation.portraitUp:
          rotation = InputImageRotation.rotation270deg;
          break;
        case DeviceOrientation.landscapeLeft:
          rotation = InputImageRotation.rotation180deg;
          break;
        case DeviceOrientation.portraitDown:
          rotation = InputImageRotation.rotation90deg;
          break;
        case DeviceOrientation.landscapeRight:
          rotation = InputImageRotation.rotation0deg;
          break;
      }
    } else {
      switch (orientation) {
        case DeviceOrientation.portraitUp:
          rotation = InputImageRotation.rotation90deg;
          break;
        case DeviceOrientation.landscapeLeft:
          rotation = InputImageRotation.rotation90deg;
          break;
        case DeviceOrientation.portraitDown:
          rotation = InputImageRotation.rotation270deg;
          break;
        case DeviceOrientation.landscapeRight:
          rotation = InputImageRotation.rotation180deg;
          break;
      }
    }

    final format =
        Platform.isAndroid ? InputImageFormat.nv21 : InputImageFormat.bgra8888;
    final plane = image.planes.first;
    final bytesBuffer = WriteBuffer();
    for (final plane in image.planes) {
      bytesBuffer.putUint8List(plane.bytes);
    }

    final metadata = InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: rotation,
      format: format,
      bytesPerRow: plane.bytesPerRow,
    );

    return InputImage.fromBytes(
      bytes: bytesBuffer.done().buffer.asUint8List(),
      metadata: metadata,
    );
  }

  @override
  void dispose() {
    _faceDetector.close();
    _flutterTts.stop();
    _controller?.dispose();
    super.dispose();
  }
}
