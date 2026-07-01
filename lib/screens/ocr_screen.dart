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
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      final provider = context.read<OcrProvider>();
      provider.setViewActive(true);
      provider.initializeCameras();
    });
  }

  @override
  void dispose() {
    context.read<OcrProvider>().setViewActive(false);
    context.read<OcrProvider>().releaseResources();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Consumer<OcrProvider>(
        builder: (context, provider, child) {
          if (!provider.isInitialized || provider.controller == null) {
            return const Center(
                child: CircularProgressIndicator(color: Colors.orangeAccent));
          }

          final previewSize = provider.controller!.value.previewSize!;
          final imageSize = Size(previewSize.height, previewSize.width);
          final rotation = InputImageRotation.rotation90deg;

          return Stack(
            fit: StackFit.expand,
            children: [
              // Kamera Görüntüsü
              CameraPreview(provider.controller!),

              // 2. OCR Çizim Katmanı
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

              // 3. Arayüz Kontrolleri
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
                    onPressed: () {
                      Navigator.pop(context);
                    },
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
