import 'dart:io';

import 'package:camera/camera.dart';
import 'package:camera_app/provider/camera_provider.dart';
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
        builder: (context, cameraProvider, child) {
          //kamera yüklenmediyse
          if (!cameraProvider.isInitialized ||
              cameraProvider.controller == null) {
            return const Center(
              child: CircularProgressIndicator(color: Colors.black),
            );
          }

          //kamera yüklendiyse

          return Stack(
            fit: StackFit.expand,
            children: [
              Center(
                child: cameraProvider.capturedImage != null
                    ? Image.file(
                        File(cameraProvider.capturedImage!.path),
                        fit: BoxFit.cover,
                        width: double.infinity,
                        height: double.infinity,
                      )
                    : CameraPreview(cameraProvider.controller!),
              ),
              if (cameraProvider.capturedImage == null)
                Positioned(
                  top: 120,
                  left: 20,
                  right: 20,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 16),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.65),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white24, width: 1),
                    ),
                    child: Text(
                      cameraProvider.guidanceKey
                          .tr(), // Easy localization çevirisi yapıyor
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ),
              Positioned(
                bottom: 30,
                left: 20,
                right: 20,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.7),
                    borderRadius: BorderRadius.circular(30),
                  ),
                  child: cameraProvider.capturedImage != null
                      // Fotoğraf Çekildiyse Gösterilecek Butonlar
                      ? Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            TextButton.icon(
                              onPressed: () =>
                                  cameraProvider.clearCapturedImage(),
                              icon:
                                  const Icon(Icons.close, color: Colors.white),
                              label: const Text("İptal Et",
                                  style: TextStyle(color: Colors.white)),
                            ),
                            const SizedBox(width: 20),
                            ElevatedButton.icon(
                              onPressed: () async {
                                await cameraProvider.saveCapturedImage();
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text(
                                          "Fotoğraf galeriye kaydedildi!")),
                                );
                              },
                              icon: const Icon(Icons.check),
                              label: const Text("Kaydet"),
                            ),
                          ],
                        )
                      // Canlı Kameradayken Gösterilecek Butonlar
                      : Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            // Çözünürlük Seçici
                            DropdownButton<ResolutionPreset>(
                              dropdownColor: Colors.black87,
                              value: cameraProvider.selectedResolution,
                              style: const TextStyle(color: Colors.white),
                              icon: const Icon(Icons.high_quality,
                                  color: Colors.white),
                              underline: const SizedBox(),
                              items: const [
                                DropdownMenuItem(
                                    value: ResolutionPreset.low,
                                    child: Text("Low")),
                                DropdownMenuItem(
                                    value: ResolutionPreset.medium,
                                    child: Text("Med")),
                                DropdownMenuItem(
                                    value: ResolutionPreset.high,
                                    child: Text("High")),
                                DropdownMenuItem(
                                    value: ResolutionPreset.max,
                                    child: Text("Max")),
                              ],
                              onChanged: (value) {
                                if (value != null) {
                                  cameraProvider.changeResolution(value);
                                }
                              },
                            ),

                            GestureDetector(
                              onTap: () {
                                if (!cameraProvider.isTakingPicture) {
                                  cameraProvider.takePicture();
                                }
                              },
                              child: Container(
                                width: 70,
                                height: 70,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border:
                                      Border.all(color: Colors.white, width: 4),
                                ),
                                child: Container(
                                  margin: const EdgeInsets.all(4),
                                  decoration: const BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                  ),
                                  child: cameraProvider.isTakingPicture
                                      ? const Padding(
                                          padding: EdgeInsets.all(16.0),
                                          child: CircularProgressIndicator(
                                            color: Colors.black,
                                            strokeWidth: 3,
                                          ),
                                        )
                                      : null, // Yüklenme yoksa içi boş beyaz kalır
                                ),
                              ),
                            ),
                            // Ön/Arka Kamera Değiştirme Butonu
                            IconButton(
                              icon: const Icon(Icons.cameraswitch,
                                  color: Colors.white, size: 30),
                              onPressed: () => cameraProvider.toggleCamera(),
                            ),
                          ],
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
