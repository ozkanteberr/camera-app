import 'dart:io';
import 'package:camera_app/provider/camera_provider.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class GalleryScreen extends StatelessWidget {
  const GalleryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        title: const Text("Kaydedilen Fotoğraflar"),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Consumer<CameraProvider>(
        builder: (context, provider, child) {
          if (provider.savedPhotos.isEmpty) {
            return const Center(
              child: Text(
                "Henüz kaydedilmiş fotoğraf yok.",
                style: TextStyle(color: Colors.white70, fontSize: 16),
              ),
            );
          }

          return Padding(
            padding: const EdgeInsets.all(8.0),
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3, // Yan yana 3 fotoğraf
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemCount: provider.savedPhotos.length,
              itemBuilder: (context, index) {
                final filePath = provider.savedPhotos[index];

                return Stack(
                  children: [
                    GestureDetector(
                      onTap: () {
                        // Fotoğrafa tıklandığında tam ekran sayfasına git
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) =>
                                FullScreenImageScreen(filePath: filePath),
                          ),
                        );
                      },
                      // Hero animasyonunun başlangıç noktası (tag, diğer sayfadakiyle aynı olmalı)
                      child: Hero(
                        tag: filePath,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.file(
                            File(filePath),
                            fit: BoxFit.cover,
                            width: double.infinity,
                            height: double.infinity,
                            errorBuilder: (context, error, stackTrace) {
                              return Container(
                                color: Colors.black45,
                                child: const Icon(Icons.broken_image,
                                    color: Colors.white30),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 4,
                      right: 4,
                      child: GestureDetector(
                        onTap: () => provider.deletePhoto(index),
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(
                            color: Colors.black54,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.delete,
                              color: Colors.redAccent, size: 18),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class FullScreenImageScreen extends StatelessWidget {
  final String filePath;
  const FullScreenImageScreen({super.key, required this.filePath});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.white,
      ),
      extendBodyBehindAppBar: true, // Fotoğrafı ekranın en üstüne kadar uzatır
      body: Center(
        child: Hero(
          tag: filePath,
          child: InteractiveViewer(
            panEnabled: true, // Kaydırma serbest
            minScale: 0.5,
            maxScale: 4.0,
            child: Image.file(
              File(filePath),
              fit: BoxFit.contain,
              width: double.infinity,
              height: double.infinity,
            ),
          ),
        ),
      ),
    );
  }
}
