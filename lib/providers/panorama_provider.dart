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
  static const int _progressTargetFrames = 24;
  static const int _minFrameIntervalMs = 700;
  static const double _rotationPerFrameRadians = 0.18;
  static const double _minUsefulAngularVelocity = 0.12;

  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  bool _isInitialized = false;
  bool _isViewActive = false;

  bool _isCapturing = false;
  bool _isProcessing = false;
  int _frameCount = 0;
  String _guidanceKey = 'panorama_start';

  StreamSubscription? _accelSub;
  StreamSubscription? _gyroSub;
  double _accumulatedRotation = 0.0;
  bool _isPhoneStraight = true;
  bool _shouldCaptureNextFrame = false;
  bool _shouldCaptureInitialFrame = false;
  bool _isAddingFrame = false;
  DateTime? _lastFrameCapturedAt;
  DateTime? _lastGyroTime;

  CameraController? get controller => _controller;
  bool get isInitialized => _isInitialized;
  bool get isProcessing => _isProcessing;
  bool get isCapturing => _isCapturing;
  int get frameCount => _frameCount;
  int get progressTargetFrames => _progressTargetFrames;
  String get guidanceKey => _guidanceKey;

  void setViewActive(bool active) {
    _isViewActive = active;

    if (active) {
      _startSensor();
    } else {
      _stopSensor();
      _cancelCapture();
      releaseResources(notify: false);
    }
  }

  void _startSensor() {
    _stopSensor();

    _accelSub = accelerometerEventStream().listen((AccelerometerEvent event) {
      if (!_isCapturing) return;

      if (event.z.abs() > 2.5) {
        _isPhoneStraight = false;
        _updateGuidance('hold_phone_upright');
      } else {
        _isPhoneStraight = true;
        _updateGuidance('rotate_at_constant_speed');
      }
    });

    _gyroSub = gyroscopeEventStream().listen((GyroscopeEvent event) {
      if (!_isCapturing || !_isPhoneStraight) return;

      final now = DateTime.now();
      final elapsedSeconds = _lastGyroTime == null
          ? 0.0
          : now.difference(_lastGyroTime!).inMicroseconds / 1000000.0;
      _lastGyroTime = now;

      final angularVelocity =
          event.y.abs() > event.z.abs() ? event.y.abs() : event.z.abs();
      if (angularVelocity < _minUsefulAngularVelocity) return;

      _accumulatedRotation += angularVelocity * elapsedSeconds;

      if (_accumulatedRotation >= _rotationPerFrameRadians) {
        _accumulatedRotation = 0.0;
        _shouldCaptureNextFrame = true;

      }
    });
  }

  void _stopSensor() {
    _accelSub?.cancel();
    _gyroSub?.cancel();
  }

  Future<void> initializeCameras() async {
    if (_controller != null) return;

    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) return;

      final backCameraIndex = _cameras.indexWhere(
          (camera) => camera.lensDirection == CameraLensDirection.back);

      await _setupCameraController(backCameraIndex == -1 ? 0 : backCameraIndex);
      PanoramaStitcher.init();
    } catch (e) {
      debugPrint("Panorama Kamera hatası: $e");
    }
  }

  Future<void> _setupCameraController(int index) async {
    _controller = CameraController(
      _cameras[index],
      ResolutionPreset.medium,
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
      debugPrint("Kamera başlatılamadı: $e");
    }
  }

  void _startLiveStream() {
    if (!_isInitialized || _controller == null) return;

    try {
      _controller!.startImageStream((CameraImage image) async {
        if (!_isViewActive ||
            _isProcessing ||
            !_isCapturing ||
            !_isPhoneStraight ||
            _isAddingFrame) {
          return;
        }

        if (!_shouldCaptureInitialFrame && !_shouldCaptureNextFrame) return;

        final now = DateTime.now();
        if (_lastFrameCapturedAt != null &&
            now.difference(_lastFrameCapturedAt!).inMilliseconds <
                _minFrameIntervalMs) {
          return;
        }

        _isAddingFrame = true;
        try {
          final bytes = _processBytes(image);
          final nextFrameCount =
              PanoramaStitcher.addFrame(bytes, image.width, image.height);
          if (nextFrameCount <= _frameCount) return;

          _frameCount = nextFrameCount;
          _lastFrameCapturedAt = now;
          _shouldCaptureInitialFrame = false;
          _shouldCaptureNextFrame = false;
          notifyListeners();
        } catch (e) {
          debugPrint("Panorama karesi eklenemedi: $e");
        } finally {
          _isAddingFrame = false;
        }
      });
    } catch (e) {
      debugPrint("Akış başlatılamadı: $e");
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

  void startCapture() {
    PanoramaStitcher.clear();
    _frameCount = 0;
    _accumulatedRotation = 0.0;
    _shouldCaptureNextFrame = false;
    _shouldCaptureInitialFrame = true;
    _lastFrameCapturedAt = null;
    _lastGyroTime = null;
    _isCapturing = true;
    _updateGuidance('rotate_at_constant_speed');

  }

  Future<void> stopAndStitch() async {
    if (!_isCapturing || _frameCount < 2) {
      _cancelCapture();
      return;
    }

    _isCapturing = false;
    _isProcessing = true;
    _updateGuidance('merging');
    notifyListeners();

    try {
      await Future.delayed(const Duration(milliseconds: 100));
      final stitchedBytes = await compute(_processPanoramaInBackground, null);

      if (stitchedBytes != null) {
        final tempDir = Directory.systemTemp;
        final file = File(
            '${tempDir.path}/panorama_${DateTime.now().millisecondsSinceEpoch}.jpg');
        await file.writeAsBytes(stitchedBytes);

        final box = Hive.box<String>('photosBox');
        await box.add(file.path);

        _resetCaptureState();
        _updateGuidance('saved');
      } else {
        _updateGuidance('merge_failed');
      }
    } catch (e) {
      debugPrint("Birleştirme hatası: $e");
      _updateGuidance('merge_failed');
    } finally {
      _isProcessing = false;
      notifyListeners();
    }
  }

  void _resetCaptureState() {
    _isCapturing = false;
    _frameCount = 0;
    _accumulatedRotation = 0.0;
    _shouldCaptureNextFrame = false;
    _shouldCaptureInitialFrame = false;
    _lastFrameCapturedAt = null;
    _lastGyroTime = null;
  }
  void _cancelCapture() {
    _isCapturing = false;
    _frameCount = 0;
    _accumulatedRotation = 0.0;
    _shouldCaptureNextFrame = false;
    _shouldCaptureInitialFrame = false;
    _lastFrameCapturedAt = null;
    _lastGyroTime = null;
    _updateGuidance('panorama_start');
  }

  void _updateGuidance(String key) {
    if (_guidanceKey != key) {
      _guidanceKey = key;
      notifyListeners();
    }
  }

  Future<void> releaseResources({bool notify = true}) async {
    _isViewActive = false;
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
