import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:provider/provider.dart';
import '../providers/ocr_provider.dart';
import '../core/painters/ocr_painter.dart';

class OCRScreen extends StatefulWidget {
  const OCRScreen({super.key});

  @override
  State<OCRScreen> createState() => _OCRScreenState();
}

class _OCRScreenState extends State<OCRScreen> {
  late final OcrProvider _ocrProvider;

  @override
  void initState() {
    super.initState();
    _ocrProvider = context.read<OcrProvider>();
    Future.microtask(() async {
      _ocrProvider.setViewActive(true);
      await _ocrProvider.initializeCameras();
    });
  }

  @override
  void dispose() {
    _ocrProvider.releaseResources(notify: false);
    super.dispose();
  }

  Future<void> _closeScreen() async {
    final navigator = Navigator.of(context);
    await _ocrProvider.releaseResources();
    if (mounted) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        await _ocrProvider.releaseResources();
        return true;
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Consumer<OcrProvider>(
          builder: (context, provider, child) {
            if (!provider.isInitialized || provider.controller == null) {
              return const Center(
                child: CircularProgressIndicator(color: Colors.orangeAccent),
              );
            }

            final previewSize = provider.controller!.value.previewSize!;
            final imageSize = Size(previewSize.height, previewSize.width);
            final rotation = InputImageRotation.rotation90deg;

            return Stack(
              fit: StackFit.expand,
              children: [
                CameraPreview(provider.controller!),
                if (provider.recognizedText != null)
                  Positioned.fill(
                    child: CustomPaint(
                      painter: OCRPainter(
                        provider.recognizedText!,
                        imageSize,
                        rotation,
                      ),
                    ),
                  ),
                Positioned(
                  top: 50,
                  left: 20,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.5),
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.arrow_back_ios_new,
                          color: Colors.white, size: 20),
                      onPressed: _closeScreen,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
