import 'package:camera_app/core/painters/pose_painter.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import '../providers/pose_provider.dart';

class PoseScreen extends StatefulWidget {
  const PoseScreen({super.key});

  @override
  State<PoseScreen> createState() => _PoseScreenState();
}

class _PoseScreenState extends State<PoseScreen> {
  @override
  void initState() {
    super.initState();
    // Ekran açılır açılmaz kamerayı ve Pose Provider'ı başlat
    Future.microtask(() {
      context.read<PoseProvider>().setViewActive(true);
      context.read<PoseProvider>().initializeCameras();
    });
  }

  @override
  void dispose() {
    context.read<PoseProvider>().setViewActive(false);
    context.read<PoseProvider>().releaseResources();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Consumer<PoseProvider>(
        builder: (context, provider, child) {
          // Kamera henüz hazır değilse yükleme animasyonu göster
          if (!provider.isInitialized || provider.controller == null) {
            return const Center(
              child: CircularProgressIndicator(color: Colors.greenAccent),
            );
          }

          // Kamera görüntüsünün ham çözünürlüğünü alıyoruz (Painter'ın boyutları oranlaması için gerekli)
          final previewSize = provider.controller!.value.previewSize!;
          // Portre (dik) modda olduğumuz için genişlik ve yüksekliği ters çeviriyoruz
          final imageSize = Size(previewSize.height, previewSize.width);

          // Kameranın ön veya arka olmasına göre dönüş açısını belirliyoruz
          final lensDirection = provider.controller!.description.lensDirection;
          final rotation = lensDirection == CameraLensDirection.front
              ? InputImageRotation.rotation270deg
              : InputImageRotation.rotation90deg;
          final isFrontCamera = lensDirection == CameraLensDirection.front;
          return Stack(
            fit: StackFit.expand,
            children: [
              //Canlı Kamera Görüntüsü
              CameraPreview(provider.controller!),

              // İskelet Çizimi
              if (provider.poses.isNotEmpty)
                Positioned.fill(
                  child: CustomPaint(
                    painter: PosePainter(
                      provider.poses,
                      imageSize,
                      rotation,
                      isFrontCamera,
                    ),
                  ),
                ),
              // Geri Dönüş ve Kamera Çevirme
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

              Positioned(
                bottom: 40,
                right: 30,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.6),
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: Colors.greenAccent.withOpacity(0.5), width: 2),
                  ),
                  child: IconButton(
                    icon: const Icon(Icons.cameraswitch,
                        color: Colors.white, size: 28),
                    onPressed: () => provider.toggleCamera(),
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
