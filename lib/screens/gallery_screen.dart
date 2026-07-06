import 'dart:async';
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
        title: Text('gallery_title'.tr()),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Consumer<CameraProvider>(
        builder: (context, provider, child) {
          if (provider.savedPhotos.isEmpty) {
            return Center(
              child: Text(
                'Henuz kaydedilmis fotograf yok.',
                style: TextStyle(color: Colors.white70, fontSize: 16.sp),
              ),
            );
          }

          return ListView.separated(
            padding: EdgeInsets.all(8.r),
            itemCount: provider.savedPhotos.length,
            separatorBuilder: (_, __) => SizedBox(height: 10.h),
            itemBuilder: (context, index) {
              final filePath = provider.savedPhotos[index];

              return FutureBuilder<Size>(
                future: _readImageSize(filePath),
                builder: (context, snapshot) {
                  final size = snapshot.data;
                  final aspectRatio = size == null || size.height == 0
                      ? 1.0
                      : (size.width / size.height).clamp(0.45, 3.5);

                  return Stack(
                    children: [
                      GestureDetector(
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) =>
                                  FullScreenImageScreen(filePath: filePath),
                            ),
                          );
                        },
                        child: Hero(
                          tag: filePath,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8.r),
                            child: AspectRatio(
                              aspectRatio: aspectRatio,
                              child: Image.file(
                                File(filePath),
                                fit: BoxFit.contain,
                                width: double.infinity,
                                errorBuilder: (context, error, stackTrace) {
                                  return Container(
                                    color: Colors.black45,
                                    child: const Icon(
                                      Icons.broken_image,
                                      color: Colors.white30,
                                    ),
                                  );
                                },
                              ),
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
                            child: Icon(
                              Icons.delete,
                              color: Colors.redAccent,
                              size: 18.r,
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

Future<Size> _readImageSize(String filePath) async {
  final image = FileImage(File(filePath));
  final stream = image.resolve(const ImageConfiguration());
  final completer = Completer<Size>();
  late ImageStreamListener listener;

  listener = ImageStreamListener((info, _) {
    stream.removeListener(listener);
    completer.complete(Size(
      info.image.width.toDouble(),
      info.image.height.toDouble(),
    ));
  }, onError: (error, stackTrace) {
    stream.removeListener(listener);
    completer.complete(const Size(1, 1));
  });

  stream.addListener(listener);
  return completer.future;
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
      extendBodyBehindAppBar: true,
      body: Center(
        child: Hero(
          tag: filePath,
          child: Image.file(
            File(filePath),
            fit: BoxFit.contain,
            width: double.infinity,
            height: double.infinity,
          ),
        ),
      ),
    );
  }
}