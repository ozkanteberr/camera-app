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

  final TextRecognizer _textRecognizer = TextRecognizer();
  bool _isProcessing = false;
  bool _isViewActive = false;

  RecognizedText? _recognizedText;
  RecognizedText? get recognizedText => _recognizedText;

  CameraController? get controller => _controller;
  bool get isInitialized => _isInitialized;

  Future<void> initializeCameras() async {
    _cameras = await availableCameras();

    if (_cameras.isNotEmpty) {
      _selectedCameraIndex = _cameras.indexWhere(
          (camera) => camera.lensDirection == CameraLensDirection.back);

      if (_selectedCameraIndex == -1) _selectedCameraIndex = 0;
      await _setupCameraController();
    }
  }

  Future<void> _setupCameraController() async {
    _controller = CameraController(
      _cameras[_selectedCameraIndex],
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );

    await _controller!.initialize();
    _isInitialized = true;
    notifyListeners();
    _startLiveStream();
  }

  void _startLiveStream() {
    _controller!.startImageStream((CameraImage image) async {
      if (!_isViewActive || _isProcessing || _controller == null) return;
      _isProcessing = true;

      try {
        final inputImage = await _inputImageFromCameraImage(image);
        if (inputImage != null) {
          final recognizedText = await _textRecognizer.processImage(inputImage);
          _recognizedText = recognizedText;
          notifyListeners();
        }
      } catch (e) {
        debugPrint("OCR Hata: $e");
      } finally {
        _isProcessing = false;
      }
    });
  }

  Future<InputImage?> _inputImageFromCameraImage(CameraImage image) async {
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
    final bytes = await compute(_processBytes, image.planes.toList());
    final metadata = InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: rotation,
      format: format,
      bytesPerRow: image.planes.first.bytesPerRow,
    );
    return InputImage.fromBytes(
        bytes: Uint8List.fromList(bytes), metadata: metadata);
  }

  static List<int> _processBytes(List<Plane> planes) {
    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane plane in planes) {
      allBytes.putUint8List(plane.bytes);
    }
    return allBytes.done().buffer.asUint8List();
  }

  void setViewActive(bool active) => _isViewActive = active;

  Future<void> releaseResources() async {
    await _controller?.stopImageStream();
    await _controller?.dispose();
    _controller = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _textRecognizer.close();
    super.dispose();
  }
}
