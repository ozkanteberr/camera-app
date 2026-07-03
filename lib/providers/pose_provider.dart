import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

class PoseProvider extends ChangeNotifier {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  bool _isInitialized = false;
  int _selectedCameraIndex = 0;
  DateTime? _lastProcessedTime;
  bool _isViewActive = false;
  bool _isProcessing = false;
  bool _isStreamRunning = false;

  late final PoseDetector _poseDetector;
  List<Pose> _poses = [];

  List<Pose> get poses => _poses;
  CameraController? get controller => _controller;
  bool get isInitialized => _isInitialized;
  bool get isViewActive => _isViewActive;

  PoseProvider() {
    final options = PoseDetectorOptions(mode: PoseDetectionMode.stream);
    _poseDetector = PoseDetector(options: options);
  }

  Future<void> initializeCameras() async {
    if (_controller != null) return;

    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) return;

      _selectedCameraIndex = _cameras.indexWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
      );
      if (_selectedCameraIndex == -1) _selectedCameraIndex = 0;

      await _setupCameraController();
    } catch (e) {
      debugPrint("Kamera hatası: $e");
    }
  }

  Future<void> _setupCameraController() async {
    if (_cameras.isEmpty) return;

    final oldController = _controller;
    _controller = null;
    _isInitialized = false;
    _isStreamRunning = false;
    notifyListeners();

    if (oldController != null) {
      try {
        if (oldController.value.isStreamingImages) {
          await oldController.stopImageStream();
        }
        await oldController.dispose();
      } catch (e) {
        debugPrint("Önceki pose kamerası temizlenirken hata: $e");
      }
    }

    final controller = CameraController(
      _cameras[_selectedCameraIndex],
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup:
          Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
    );
    _controller = controller;

    try {
      await controller.initialize();
      if (_controller != controller) return;

      _isInitialized = true;
      notifyListeners();
      _startLiveStream();
    } catch (e) {
      debugPrint("Kamera başlatılamadı: $e");
    }
  }

  void _startLiveStream() {
    final controller = _controller;
    if (controller == null || !_isInitialized || _isStreamRunning) return;

    try {
      _isStreamRunning = true;
      controller.startImageStream((CameraImage image) async {
        if (!_isViewActive || _isProcessing) return;
        if (_controller != controller || !controller.value.isInitialized) return;

        final now = DateTime.now();
        if (_lastProcessedTime != null &&
            now.difference(_lastProcessedTime!).inMilliseconds < 150) {
          return;
        }

        _isProcessing = true;
        _lastProcessedTime = now;

        try {
          final inputImage = await _inputImageFromCameraImage(image);
          if (!_isViewActive || _controller != controller) return;

          if (inputImage == null) return;

          final poses = await _poseDetector.processImage(inputImage);
          if (!_isViewActive || _controller != controller) return;

          _poses = poses;
          notifyListeners();
        } catch (e) {
          if (_isViewActive) {
            debugPrint("İskelet analizinde hata: $e");
          }
        } finally {
          _isProcessing = false;
        }
      });
    } catch (e) {
      _isStreamRunning = false;
      debugPrint("Pose kamera akışı başlatılamadı: $e");
    }
  }

  Future<InputImage?> _inputImageFromCameraImage(CameraImage image) async {
    if (_controller == null) return null;
    final camera = _cameras[_selectedCameraIndex];

    InputImageRotation rotation;
    final orientation = _controller!.value.deviceOrientation;

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
    final bytes = await compute(_processBytes, image.planes.toList());

    if (!_isViewActive || _controller == null) return null;

    final metadata = InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: rotation,
      format: format,
      bytesPerRow: image.planes.first.bytesPerRow,
    );

    return InputImage.fromBytes(
      bytes: Uint8List.fromList(bytes),
      metadata: metadata,
    );
  }

  Future<void> toggleCamera() async {
    if (_cameras.length < 2) return;

    await _stopLiveStream();
    _isInitialized = false;
    notifyListeners();

    _selectedCameraIndex = (_selectedCameraIndex + 1) % _cameras.length;
    await _setupCameraController();
  }

  void setViewActive(bool active) {
    _isViewActive = active;
    if (!active) {
      _poses = [];
      notifyListeners();
    } else if (_controller != null &&
        _isInitialized &&
        !_controller!.value.isStreamingImages) {
      _startLiveStream();
    }
  }

  Future<void> _stopLiveStream() async {
    final controller = _controller;
    if (controller == null) {
      _isStreamRunning = false;
      _isProcessing = false;
      return;
    }

    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } catch (e) {
      debugPrint("Pose kamera akışı durdurulamadı: $e");
    } finally {
      _isStreamRunning = false;
      _isProcessing = false;
    }
  }

  Future<void> releaseResources({bool notify = true}) async {
    _isViewActive = false;
    _poses = [];

    final controller = _controller;
    _controller = null;
    _isInitialized = false;
    _isStreamRunning = false;
    _isProcessing = false;
    if (notify) notifyListeners();

    if (controller == null) return;

    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } catch (e) {
      debugPrint("Pose kamera akışı kapatılırken hata: $e");
    }

    try {
      await controller.dispose();
    } catch (e) {
      debugPrint("Pose kamera dispose hatası: $e");
    }
  }

  static List<int> _processBytes(List<Plane> planes) {
    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane plane in planes) {
      allBytes.putUint8List(plane.bytes);
    }
    return allBytes.done().buffer.asUint8List();
  }

  @override
  void dispose() {
    _poseDetector.close();
    _controller?.dispose();
    super.dispose();
  }
}

