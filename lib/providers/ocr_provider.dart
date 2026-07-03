import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

class OcrProvider extends ChangeNotifier {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  bool _isInitialized = false;
  int _selectedCameraIndex = 0;
  bool _isProcessing = false;
  bool _isViewActive = false;
  bool _isStreamRunning = false;

  final TextRecognizer _textRecognizer = TextRecognizer();
  RecognizedText? _recognizedText;

  RecognizedText? get recognizedText => _recognizedText;
  CameraController? get controller => _controller;
  bool get isInitialized => _isInitialized;

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
      debugPrint("OCR kamera hatası: $e");
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
        debugPrint("Önceki OCR kamerası temizlenirken hata: $e");
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
      debugPrint("OCR kamera başlatılamadı: $e");
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

        _isProcessing = true;

        try {
          final inputImage = await _inputImageFromCameraImage(image);
          if (!_isViewActive || _controller != controller || inputImage == null) {
            return;
          }

          final recognizedText = await _textRecognizer.processImage(inputImage);
          if (!_isViewActive || _controller != controller) return;

          _recognizedText = recognizedText;
          notifyListeners();
        } catch (e) {
          if (_isViewActive) debugPrint("OCR Hata: $e");
        } finally {
          _isProcessing = false;
        }
      });
    } catch (e) {
      _isStreamRunning = false;
      debugPrint("OCR kamera akışı başlatılamadı: $e");
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

  static List<int> _processBytes(List<Plane> planes) {
    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane plane in planes) {
      allBytes.putUint8List(plane.bytes);
    }
    return allBytes.done().buffer.asUint8List();
  }

  void setViewActive(bool active) {
    _isViewActive = active;
    if (!active) {
      _recognizedText = null;
    }
  }

  Future<void> releaseResources({bool notify = true}) async {
    _isViewActive = false;
    _recognizedText = null;

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
      debugPrint("OCR kamera akışı kapatılırken hata: $e");
    }

    try {
      await controller.dispose();
    } catch (e) {
      debugPrint("OCR kamera dispose hatası: $e");
    }
  }

  @override
  void dispose() {
    _textRecognizer.close();
    _controller?.dispose();
    super.dispose();
  }
}
