import 'dart:io';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:camera_app/providers/camera_provider.dart';
import 'package:camera_app/screens/gallery_screen.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:easy_localization/easy_localization.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => context.read<CameraProvider>().initializeCameras());
  }

  @override
  void dispose() {
    context.read<CameraProvider>().closeCamera();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Consumer<CameraProvider>(
        builder: (context, provider, child) {
          if (!provider.isInitialized || provider.controller == null) {
            return const Center(
                child: CircularProgressIndicator(color: Colors.white));
          }

          return Stack(
            fit: StackFit.expand,
            children: [
              // 1. Kamera Görüntüsü
              Center(
                child: provider.capturedImage != null
                    ? Image.file(File(provider.capturedImage!.path),
                        fit: BoxFit.cover)
                    : CameraPreview(provider.controller!),
              ),

              // 2. YÖNLENDİRME KUTUSU (Geri getirildi!)
              if (provider.capturedImage == null)
                Align(
                  alignment: const Alignment(0.0, -0.65),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 32, vertical: 20),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.5),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                              color: Colors.white.withOpacity(0.3), width: 1.5),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              provider.guidanceKey == 'saga_cevir'
                                  ? Icons.turn_right
                                  : provider.guidanceKey == 'sola_cevir'
                                      ? Icons.turn_left
                                      : provider.guidanceKey == 'yuz_bulunamadi'
                                          ? Icons.face_retouching_off
                                          : Icons.face,
                              color: Colors.white,
                              size: 36,
                            ),
                            const SizedBox(width: 16),
                            Text(provider.guidanceKey.tr(),
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

              Positioned(
                top: 50,
                left: 20,
                child: Container(
                  decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.5),
                      shape: BoxShape.circle),
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back_ios_new,
                        color: Colors.white, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
              ),

              Positioned(
                top: 50,
                right: 20,
                child: Container(
                  decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.5),
                      shape: BoxShape.circle),
                  child: IconButton(
                    icon: const Icon(Icons.photo_library,
                        color: Colors.white, size: 22),
                    onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const GalleryScreen())),
                  ),
                ),
              ),

              // 4. Alt Kontrol Paneli (Çözünürlük Menüsü ve Deklanşör dahil)
              Positioned(
                bottom: 40,
                left: 20,
                right: 20,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.6),
                    borderRadius: BorderRadius.circular(30),
                  ),
                  child: provider.capturedImage != null
                      ? _buildConfirmRow(provider)
                      : _buildCameraControls(provider),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildConfirmRow(CameraProvider provider) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        TextButton.icon(
          onPressed: () => provider.clearCapturedImage(),
          icon: const Icon(Icons.close, color: Colors.redAccent),
          label: const Text("İptal", style: TextStyle(color: Colors.redAccent)),
        ),
        ElevatedButton.icon(
          onPressed: () async => await provider.saveCapturedImage(),
          icon: const Icon(Icons.check, color: Colors.white),
          label: const Text("Onayla", style: TextStyle(color: Colors.white)),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
        ),
      ],
    );
  }

  Widget _buildCameraControls(CameraProvider provider) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        PopupMenuButton<ResolutionPreset>(
          icon: const Icon(Icons.hd, color: Colors.white, size: 26),
          color: Colors.black87,
          initialValue: provider.selectedResolution,
          onSelected: (value) =>
              provider.changeResolution(value), // Fonksiyon bağlandı!
          itemBuilder: (context) => const [
            PopupMenuItem(
                value: ResolutionPreset.low,
                child: Text("Low", style: TextStyle(color: Colors.white))),
            PopupMenuItem(
                value: ResolutionPreset.medium,
                child: Text("Medium", style: TextStyle(color: Colors.white))),
            PopupMenuItem(
                value: ResolutionPreset.high,
                child: Text("High", style: TextStyle(color: Colors.white))),
            PopupMenuItem(
                value: ResolutionPreset.max,
                child: Text("Max", style: TextStyle(color: Colors.white))),
          ],
        ),
        GestureDetector(
          onTap: () => provider.isTakingPicture ? null : provider.takePicture(),
          child: Container(
            width: 66,
            height: 66,
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 3)),
            child: Container(
              margin: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                  color: provider.isTakingPicture ? Colors.grey : Colors.white,
                  shape: BoxShape.circle),
              child: provider.isTakingPicture
                  ? const CircularProgressIndicator(
                      color: Colors.black, strokeWidth: 2.5)
                  : null,
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.cameraswitch, color: Colors.white, size: 26),
          onPressed: () => provider.toggleCamera(),
        ),
      ],
    );
  }
}
