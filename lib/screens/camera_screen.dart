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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<CameraProvider>().initializeCameras();
    });
  }

  @override
  void dispose() {
    context.read<CameraProvider>().closeCamera();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: AppBar(
          title: const Text(
            "Kamera App",
          ),
          centerTitle: true,
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: Colors.black,
          actions: [
            IconButton(
              icon: const Icon(Icons.photo_library, size: 28),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (context) => const GalleryScreen()),
                );
              },
            ),
          ],
        ),
      ),
      extendBodyBehindAppBar: true,
      body: Consumer<CameraProvider>(
        builder: (context, provider, child) {
          //kamera yüklenmediyse
          if (!provider.isInitialized || provider.controller == null) {
            return const Center(
              child: CircularProgressIndicator(color: Colors.black),
            );
          }

          //kamera yüklendiyse

          return Stack(
            fit: StackFit.expand,
            children: [
              // kamera
              Center(
                child: provider.capturedImage != null
                    ? Image.file(
                        File(provider.capturedImage!.path),
                        fit: BoxFit.cover,
                        width: double.infinity,
                        height: double.infinity,
                      )
                    : CameraPreview(provider.controller!),
              ),

              // guidance yönlendirme kutusu
              if (provider.capturedImage == null)
                Align(
                  // Ekranın tam ortasının biraz üstü (Yüz hizası)
                  alignment: const Alignment(0.0, -0.65),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 32, vertical: 20),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(
                              0.5), // Okunabilirliği artırmak için biraz koyulttuk
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
                              size: 36, // İkon boyutunu oldukça büyüttük
                            ),
                            const SizedBox(width: 16),
                            Text(
                              provider.guidanceKey.tr(),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize:
                                    24, // Yazı boyutunu çok daha belirgin yaptık
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.2,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

              // alt kontrol paneli
              Positioned(
                bottom: 30,
                left: 40,
                right: 40,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(30),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10), // Daraltıldı
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.4),
                        borderRadius: BorderRadius.circular(30),
                        border:
                            Border.all(color: Colors.white.withOpacity(0.1)),
                      ),
                      child: provider.capturedImage != null
                          ? Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                TextButton.icon(
                                  onPressed: () =>
                                      provider.clearCapturedImage(),
                                  icon: const Icon(Icons.close,
                                      color: Colors.redAccent, size: 20),
                                  label: const Text("İptal",
                                      style:
                                          TextStyle(color: Colors.redAccent)),
                                ),
                                ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.green,
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(20)),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 16, vertical: 8),
                                  ),
                                  onPressed: () async {
                                    await provider.saveCapturedImage();
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                              "📸 Fotoğraf galeriye kaydedildi!"),
                                          backgroundColor: Colors.green,
                                          behavior: SnackBarBehavior.floating,
                                        ),
                                      );
                                    }
                                  },
                                  icon: const Icon(Icons.check, size: 20),
                                  label: const Text("Onayla"),
                                ),
                              ],
                            )
                          : Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                // çözünürlük seçme
                                PopupMenuButton<ResolutionPreset>(
                                  icon: const Icon(Icons.hd,
                                      color: Colors.white, size: 26),
                                  color: Colors.black87,
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12)),
                                  initialValue: provider.selectedResolution,
                                  onSelected: (value) =>
                                      provider.changeResolution(value),
                                  itemBuilder: (context) => const [
                                    PopupMenuItem(
                                        value: ResolutionPreset.low,
                                        child: Text("Low",
                                            style: TextStyle(
                                                color: Colors.white))),
                                    PopupMenuItem(
                                        value: ResolutionPreset.medium,
                                        child: Text("Medium",
                                            style: TextStyle(
                                                color: Colors.white))),
                                    PopupMenuItem(
                                        value: ResolutionPreset.high,
                                        child: Text("High",
                                            style: TextStyle(
                                                color: Colors.white))),
                                    PopupMenuItem(
                                        value: ResolutionPreset.max,
                                        child: Text("Max",
                                            style: TextStyle(
                                                color: Colors.white))),
                                  ],
                                ),

                                // Deklanşör Butonu (Bir tık daha kibar)
                                GestureDetector(
                                  onTap: () {
                                    if (!provider.isTakingPicture)
                                      provider.takePicture();
                                  },
                                  child: Container(
                                    width: 66, // 76'dan 66'ya düşürüldü
                                    height: 66,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                          color: Colors.white, width: 3),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withOpacity(0.3),
                                          blurRadius: 8,
                                          spreadRadius: 1,
                                        )
                                      ],
                                    ),
                                    child: Container(
                                      margin: const EdgeInsets.all(5),
                                      decoration: BoxDecoration(
                                        color: provider.isTakingPicture
                                            ? Colors.grey
                                            : Colors.white,
                                        shape: BoxShape.circle,
                                      ),
                                      child: provider.isTakingPicture
                                          ? const Padding(
                                              padding: EdgeInsets.all(14.0),
                                              child: CircularProgressIndicator(
                                                  color: Colors.black,
                                                  strokeWidth: 2.5),
                                            )
                                          : null,
                                    ),
                                  ),
                                ),

                                // Kamera Çevirme
                                IconButton(
                                  icon: const Icon(Icons.cameraswitch,
                                      color: Colors.white, size: 26),
                                  onPressed: () => provider.toggleCamera(),
                                ),
                              ],
                            ),
                    ),
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
