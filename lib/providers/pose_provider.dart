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

  late PoseDetector _poseDetector;
  bool _isProcessing = false;

  List<Pose> _poses = [];

  List<Pose> get poses => _poses;

  CameraController? get controller => _controller;
  bool get isInitialized => _isInitialized;

  PoseProvider() {
    final options = PoseDetectorOptions(mode: PoseDetectionMode.stream);
    _poseDetector = PoseDetector(options: options);
  }

  Future<void> initializeCameras() async {
    try {
      _cameras = await availableCameras();

      if (_cameras.isNotEmpty) {
        _selectedCameraIndex = _cameras.indexWhere(
            (camera) => camera.lensDirection == CameraLensDirection.back);
        if (_selectedCameraIndex == -1) _selectedCameraIndex = 0;

        await _setupCameraController();
      }
    } catch (e) {
      debugPrint("Kamera hatası: $e");
    }
  }

  Future<void> _setupCameraController() async {
    if (_cameras.isEmpty) return;
    if (_controller != null) {
      await _controller!.dispose();
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
      debugPrint("Kamera başlatılamadı: $e");
    }
  }

  void _startLiveStream() {
    if (_controller == null || !_isInitialized) return;

    _controller!.startImageStream((CameraImage image) async {
      if (_isProcessing) return;
      final now = DateTime.now();
      if (_lastProcessedTime != null &&
          now.difference(_lastProcessedTime!).inMilliseconds < 150) {
        return;
      }

      _isProcessing = true;
      _lastProcessedTime = now;

      try {
        debugPrint("Kare kameradan başarıyla alındı.");

        final inputImage = _inputImageFromCameraImage(image);

        if (inputImage != null) {
          debugPrint(
              "Kare ML Kit formatına çevrildi, AI motoruna gönderiliyor");

          // Yapay zeka analizi
          final poses = await _poseDetector.processImage(inputImage);

          debugPrint(
              "AI analizi bitti! Algılanan iskelet sayısı: ${poses.length}");

          _poses = poses;
          notifyListeners();
        } else {
          debugPrint(
              "Kare ML Kit formatına (InputImage) dönüştürülemedi ve null döndü!");
        }
      } catch (e) {
        debugPrint("İskelet analizinde kritik hata: $e");
      } finally {
        _isProcessing = false;
      }
    });
  }

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    if (_controller == null) return null;
    final camera = _cameras[_selectedCameraIndex];

    InputImageRotation? rotation;
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

    final plane = image.planes.first;
    final allBytes = WriteBuffer();
    for (final Plane plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();

    final metadata = InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: rotation,
      format: format,
      bytesPerRow: plane.bytesPerRow,
    );

    return InputImage.fromBytes(bytes: bytes, metadata: metadata);
  }

  Future<void> toggleCamera() async {
    if (_cameras.length < 2) return;
    if (_controller != null && _controller!.value.isStreamingImages) {
      await _controller!.stopImageStream();
    }
    _isInitialized = false;
    notifyListeners();
    _selectedCameraIndex = (_selectedCameraIndex + 1) % _cameras.length;
    await _setupCameraController();
  }

  @override
  void dispose() {
    _poseDetector.close();
    _controller?.dispose();
    super.dispose();
  }
}
