import 'dart:io';
import 'package:camera_app/providers/camera_provider.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil_plus/flutter_screenutil_plus.dart';
import 'package:provider/provider.dart';

class GalleryScreen extends StatelessWidget {
  const GalleryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        title: Text("gallery_title".tr()),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Consumer<CameraProvider>(
        builder: (context, provider, child) {
          if (provider.savedPhotos.isEmpty) {
            return Center(
              child: Text(
                "Henüz kaydedilmiş fotoğraf yok.",
                style: TextStyle(color: Colors.white70, fontSize: 16.sp),
              ),
            );
          }

          return Padding(
            padding: EdgeInsets.all(8.r),
            child: GridView.builder(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3, // Yan yana 3 fotoğraf
                crossAxisSpacing: 8.w,
                mainAxisSpacing: 8.h,
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
                      //Hero animasyonunun başlangıç noktası
                      child: Hero(
                        tag: filePath,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8.r),
                          child: Image.file(
                            File(filePath),
                            fit: BoxFit.cover,
                            width: double.infinity,
                            height: double.infinity,
                            errorBuilder: (context, error, stackTrace) {
                              return Container(
                                color: Colors.black45,
                                child: Icon(Icons.broken_image,
                                    color: Colors.white30),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 4.h,
                      right: 4.w,
                      child: GestureDetector(
                        onTap: () => provider.deletePhoto(index),
                        child: Container(
                          padding: EdgeInsets.all(4.r),
                          decoration: const BoxDecoration(
                            color: Colors.black54,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.delete,
                              color: Colors.redAccent, size: 18.r),
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
