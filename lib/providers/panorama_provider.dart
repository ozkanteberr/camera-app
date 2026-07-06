import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:panorama_stitcher/panorama_stitcher.dart';
import 'package:sensors_plus/sensors_plus.dart';

Uint8List? _processPanoramaInBackground(_) => PanoramaStitcher.process();

class PanoramaProvider extends ChangeNotifier {
  static const int _progressTargetFrames = 18;
  static const int _minStitchFrames = 4;
  static const int _minFrameIntervalMs = 320;
  static const double _rotationPerFrameRadians = 0.11;
  static const double _minUsefulAngularVelocity = 0.10;
  static const double _maxUsefulAngularVelocity = 1.25;
  static const double _flatPhoneThreshold = 4.2;

  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  bool _isInitialized = false;
  bool _isViewActive = false;

  bool _isCapturing = false;
  bool _isProcessing = false;
  bool _isAddingFrame = false;
  bool _isAutoCompleting = false;
  int _frameCount = 0;
  String _guidanceKey = 'panorama_start';

  StreamSubscription? _accelSub;
  StreamSubscription? _gyroSub;
  double _accumulatedRotation = 0.0;
  double _smoothedTiltZ = 0.0;
  bool _isPhoneStraight = true;
  bool _shouldCaptureNextFrame = false;
  bool _shouldCaptureInitialFrame = false;
  DateTime? _lastFrameCapturedAt;
  DateTime? _lastFrameAttemptedAt;
  DateTime? _lastGyroTime;
  DateTime? _lastMotionGuidanceAt;

  CameraController? get controller => _controller;
  bool get isInitialized => _isInitialized;
  bool get isProcessing => _isProcessing;
  bool get isCapturing => _isCapturing;
  int get frameCount => _frameCount;
  int get progressTargetFrames => _progressTargetFrames;
  int get minStitchFrames => _minStitchFrames;
  String get guidanceKey => _guidanceKey;
  double get captureProgress =>
      (_frameCount / _progressTargetFrames).clamp(0.0, 1.0).toDouble();
  bool get canFinishCapture => _frameCount >= _minStitchFrames;

  void setViewActive(bool active) {
    _isViewActive = active;

    if (active) {
      _startSensor();
    } else {
      _stopSensor();
      unawaited(releaseResources(notify: false));
    }
  }

  void _startSensor() {
    _stopSensor();

    _accelSub = accelerometerEventStream().listen((AccelerometerEvent event) {
      if (!_isCapturing) return;

      final tiltZ = event.z.abs();
      _smoothedTiltZ = _smoothedTiltZ == 0.0
          ? tiltZ
          : (_smoothedTiltZ * 0.82) + (tiltZ * 0.18);
      final isStraight = _smoothedTiltZ < _flatPhoneThreshold;

      if (_isPhoneStraight == isStraight) return;

      _isPhoneStraight = isStraight;
      if (!_isPhoneStraight) {
        _lastGyroTime = null;
        _accumulatedRotation = 0.0;
        _shouldCaptureNextFrame = false;
        _updateGuidance('hold_phone_upright', force: true);
      } else {
        _updateGuidance('rotate_at_constant_speed', force: true);
      }
    });

    _gyroSub = gyroscopeEventStream().listen((GyroscopeEvent event) {
      if (!_isCapturing) return;

      final now = DateTime.now();
      final elapsedSeconds = _lastGyroTime == null
          ? 0.0
          : now.difference(_lastGyroTime!).inMicroseconds / 1000000.0;
      _lastGyroTime = now;

      if (!_isPhoneStraight || elapsedSeconds <= 0.0) return;

      final angularVelocity =
          event.y.abs() > event.z.abs() ? event.y.abs() : event.z.abs();

      if (angularVelocity < _minUsefulAngularVelocity) {
        _showMotionGuidance('panorama_rotate_faster');
        return;
      }

      if (angularVelocity > _maxUsefulAngularVelocity) {
        _accumulatedRotation = 0.0;
        _shouldCaptureNextFrame = false;
        _showMotionGuidance('panorama_rotate_slower');
        return;
      }

      _showMotionGuidance('rotate_at_constant_speed');
      final cappedElapsedSeconds = elapsedSeconds.clamp(0.0, 0.08).toDouble();
      _accumulatedRotation += angularVelocity * cappedElapsedSeconds;

      if (_accumulatedRotation >= _rotationPerFrameRadians) {
        _accumulatedRotation = 0.0;
        _shouldCaptureNextFrame = true;
      }
    });
  }

  void _stopSensor() {
    _accelSub?.cancel();
    _gyroSub?.cancel();
    _accelSub = null;
    _gyroSub = null;
  }

  Future<void> initializeCameras() async {
    if (_controller != null) return;

    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) return;

      final backCameraIndex = _cameras.indexWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
      );

      await _setupCameraController(backCameraIndex == -1 ? 0 : backCameraIndex);
      PanoramaStitcher.init();
    } catch (e) {
      debugPrint('Panorama camera error: $e');
    }
  }

  Future<void> _setupCameraController(int index) async {
    _controller = CameraController(
      _cameras[index],
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup:
          Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
    );

    try {
      await _controller!.initialize();
      _isInitialized = true;
      notifyListeners();
    } catch (e) {
      debugPrint('Panorama camera could not start: $e');
    }
  }

  Future<void> _startLiveStream() async {
    final controller = _controller;
    if (!_isInitialized || controller == null) return;
    if (controller.value.isStreamingImages) return;

    try {
      await controller.startImageStream(_handleCameraImage);
    } catch (e) {
      debugPrint('Panorama image stream could not start: $e');
    }
  }

  Future<void> _stopLiveStream() async {
    final controller = _controller;
    if (controller == null || !controller.value.isStreamingImages) return;

    try {
      await controller.stopImageStream();
    } catch (e) {
      debugPrint('Panorama image stream could not stop: $e');
    }
  }

  void _handleCameraImage(CameraImage image) {
    if (!_isViewActive ||
        _isProcessing ||
        !_isCapturing ||
        !_isPhoneStraight ||
        _isAddingFrame) {
      return;
    }

    if (!_shouldCaptureInitialFrame && !_shouldCaptureNextFrame) return;

    final now = DateTime.now();
    if (_lastFrameAttemptedAt != null &&
        now.difference(_lastFrameAttemptedAt!).inMilliseconds <
            _minFrameIntervalMs) {
      return;
    }

    _isAddingFrame = true;
    _lastFrameAttemptedAt = now;
    try {
      final bytes = _processBytes(image);
      final nextFrameCount =
          PanoramaStitcher.addFrame(bytes, image.width, image.height);

      if (nextFrameCount <= _frameCount) {
        _shouldCaptureNextFrame = false;
        if (_frameCount == 0) {
          _updateGuidance('panorama_hold_steady');
        } else {
          _showMotionGuidance('panorama_keep_moving');
        }
        return;
      }

      _frameCount = nextFrameCount;
      _lastFrameCapturedAt = now;
      _shouldCaptureInitialFrame = false;
      _shouldCaptureNextFrame = false;
      _updateGuidance('rotate_at_constant_speed');
      notifyListeners();

      if (_frameCount >= _progressTargetFrames && !_isAutoCompleting) {
        _isAutoCompleting = true;
        unawaited(Future<void>.microtask(stopAndStitch));
      }
    } catch (e) {
      debugPrint('Panorama frame could not be added: $e');
    } finally {
      _isAddingFrame = false;
    }
  }

  Uint8List _processBytes(CameraImage image) {
    final width = image.width;
    final height = image.height;
    final ySize = width * height;
    final uvSize = width * height ~/ 2;
    final nv21 = Uint8List(ySize + uvSize);

    if (image.planes.length == 1) {
      final plane = image.planes.first;
      if (plane.bytesPerRow == width && plane.bytes.length >= nv21.length) {
        nv21.setRange(0, nv21.length, plane.bytes);
        return nv21;
      }

      var offset = 0;
      for (var row = 0; row < height + height ~/ 2; row++) {
        final rowStart = row * plane.bytesPerRow;
        nv21.setRange(offset, offset + width, plane.bytes, rowStart);
        offset += width;
      }
      return nv21;
    }

    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];

    var offset = 0;
    for (var row = 0; row < height; row++) {
      final rowStart = row * yPlane.bytesPerRow;
      nv21.setRange(offset, offset + width, yPlane.bytes, rowStart);
      offset += width;
    }

    var uvOffset = ySize;
    final uvPixelStride = uPlane.bytesPerPixel ?? 1;
    for (var row = 0; row < height ~/ 2; row++) {
      for (var col = 0; col < width ~/ 2; col++) {
        final uvIndex = row * uPlane.bytesPerRow + col * uvPixelStride;
        nv21[uvOffset++] = vPlane.bytes[uvIndex];
        nv21[uvOffset++] = uPlane.bytes[uvIndex];
      }
    }

    return nv21;
  }

  Future<void> startCapture() async {
    if (_isProcessing || _isCapturing || !_isInitialized) return;

    PanoramaStitcher.clear();
    _resetCaptureState(resetGuidance: false);
    _smoothedTiltZ = 0.0;
    _isPhoneStraight = true;
    _shouldCaptureInitialFrame = true;
    _isCapturing = true;
    _updateGuidance('rotate_at_constant_speed', force: true);
    await _startLiveStream();
  }

  Future<void> stopAndStitch() async {
    if (!_isCapturing) return;

    if (_frameCount < _minStitchFrames) {
      _updateGuidance('panorama_need_more_frames', force: true);
      return;
    }

    _isCapturing = false;
    _isProcessing = true;
    _updateGuidance('merging', force: true);
    notifyListeners();

    try {
      await _stopLiveStream();
      final stitchedBytes = await compute(_processPanoramaInBackground, null);

      if (stitchedBytes != null) {
        final tempDir = Directory.systemTemp;
        final file = File(
          '${tempDir.path}/panorama_${DateTime.now().millisecondsSinceEpoch}.jpg',
        );
        await file.writeAsBytes(stitchedBytes);

        final box = Hive.box<String>('photosBox');
        await box.add(file.path);

        _resetCaptureState(resetGuidance: false);
        _updateGuidance('saved', force: true);
      } else {
        _resetCaptureState(resetGuidance: false);
        _updateGuidance('merge_failed', force: true);
      }
    } catch (e) {
      debugPrint('Panorama stitch error: $e');
      _updateGuidance('merge_failed', force: true);
    } finally {
      _isProcessing = false;
      _isAutoCompleting = false;
      notifyListeners();
    }
  }

  void _resetCaptureState({bool resetGuidance = true}) {
    _isCapturing = false;
    _frameCount = 0;
    _accumulatedRotation = 0.0;
    _shouldCaptureNextFrame = false;
    _shouldCaptureInitialFrame = false;
    _isAutoCompleting = false;
    _lastFrameCapturedAt = null;
    _lastFrameAttemptedAt = null;
    _lastGyroTime = null;
    _lastMotionGuidanceAt = null;
    if (resetGuidance) {
      _guidanceKey = 'panorama_start';
    }
  }

  void _cancelCapture({bool notify = true}) {
    _resetCaptureState();
    unawaited(_stopLiveStream());
    if (notify) notifyListeners();
  }

  void _showMotionGuidance(String key) {
    final now = DateTime.now();
    if (_lastMotionGuidanceAt != null &&
        now.difference(_lastMotionGuidanceAt!).inMilliseconds < 650) {
      return;
    }
    _lastMotionGuidanceAt = now;
    _updateGuidance(key);
  }

  void _updateGuidance(String key, {bool force = false}) {
    if (!force && _guidanceKey == key) return;
    _guidanceKey = key;
    notifyListeners();
  }

  Future<void> releaseResources({bool notify = true}) async {
    _isViewActive = false;
    _stopSensor();
    _resetCaptureState();
    final controller = _controller;
    _controller = null;
    _isInitialized = false;
    if (notify) notifyListeners();

    if (controller != null) {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
      await controller.dispose();
    }
  }
}