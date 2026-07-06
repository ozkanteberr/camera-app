#include <opencv2/opencv.hpp>
#include <opencv2/stitching.hpp>
#include <android/log.h>
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <stdint.h>
#include <vector>

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "PanoramaEngine", __VA_ARGS__)

namespace {
constexpr size_t kMaxCapturedFrames = 24;
constexpr int kMaxFrameWidth = 960;

std::mutex frames_mutex;
std::vector<cv::Mat> captured_frames;
}

extern "C" {

__attribute__((visibility("default"))) __attribute__((used))
int32_t init_panorama_engine() {
  cv::setNumThreads(2);
  LOGI("Panorama motoru hazir.");
  return 1;
}

__attribute__((visibility("default"))) __attribute__((used))
void clear_frames() {
  std::lock_guard<std::mutex> lock(frames_mutex);
  captured_frames.clear();
  LOGI("Hafiza temizlendi. Yeni panorama cekimi icin hazir.");
}

__attribute__((visibility("default"))) __attribute__((used))
int32_t add_frame(uint8_t *image_bytes, int32_t width, int32_t height) {
  if (image_bytes == nullptr || width <= 0 || height <= 0) {
    LOGI("Hata: Gecersiz kamera karesi.");
    return -1;
  }

  std::lock_guard<std::mutex> lock(frames_mutex);
  if (captured_frames.size() >= kMaxCapturedFrames) {
    return static_cast<int32_t>(captured_frames.size());
  }

  try {
    cv::Mat nv21_img(height + height / 2, width, CV_8UC1, image_bytes);
    cv::Mat bgr_img;
    cv::cvtColor(nv21_img, bgr_img, cv::COLOR_YUV2BGR_NV21);

    cv::Mat output_img;
    if (width > kMaxFrameWidth) {
      const double scale = static_cast<double>(kMaxFrameWidth) / width;
      cv::resize(bgr_img, output_img, cv::Size(), scale, scale, cv::INTER_AREA);
    } else {
      output_img = bgr_img;
    }

    if (output_img.cols > output_img.rows) {
      cv::rotate(output_img, output_img, cv::ROTATE_90_CLOCKWISE);
    }

    captured_frames.push_back(output_img.clone());
    LOGI("Yeni kare eklendi. Toplam kare sayisi: %d", (int)captured_frames.size());
    return static_cast<int32_t>(captured_frames.size());
  } catch (const cv::Exception &e) {
    LOGI("OpenCV kare ekleme hatasi: %s", e.what());
    return -2;
  } catch (...) {
    LOGI("Bilinmeyen kare ekleme hatasi.");
    return -3;
  }
}


__attribute__((visibility("default"))) __attribute__((used))
int32_t add_encoded_frame(uint8_t *image_bytes, int32_t length) {
  if (image_bytes == nullptr || length <= 0) {
    LOGI("Hata: Gecersiz JPEG karesi.");
    return -1;
  }

  std::lock_guard<std::mutex> lock(frames_mutex);
  if (captured_frames.size() >= kMaxCapturedFrames) {
    return static_cast<int32_t>(captured_frames.size());
  }

  try {
    std::vector<uchar> buffer(image_bytes, image_bytes + length);
    cv::Mat bgr_img = cv::imdecode(buffer, cv::IMREAD_COLOR);
    if (bgr_img.empty()) {
      LOGI("Hata: JPEG decode edilemedi.");
      return -2;
    }

    cv::Mat output_img;
    if (bgr_img.cols > kMaxFrameWidth) {
      const double scale = static_cast<double>(kMaxFrameWidth) / bgr_img.cols;
      cv::resize(bgr_img, output_img, cv::Size(), scale, scale, cv::INTER_AREA);
    } else {
      output_img = bgr_img;
    }

    if (output_img.cols > output_img.rows) {
      cv::rotate(output_img, output_img, cv::ROTATE_90_CLOCKWISE);
    }

    captured_frames.push_back(output_img.clone());
    LOGI("JPEG kare eklendi. Toplam kare sayisi: %d", (int)captured_frames.size());
    return static_cast<int32_t>(captured_frames.size());
  } catch (const cv::Exception &e) {
    LOGI("OpenCV JPEG kare hatasi: %s", e.what());
    return -3;
  } catch (...) {
    LOGI("Bilinmeyen JPEG kare hatasi.");
    return -4;
  }
}
__attribute__((visibility("default"))) __attribute__((used))
int32_t process_panorama(uint8_t **output_image_bytes, int32_t *out_width, int32_t *out_height) {
  if (output_image_bytes == nullptr || out_width == nullptr || out_height == nullptr) {
    return -1;
  }

  *output_image_bytes = nullptr;
  *out_width = 0;
  *out_height = 0;

  std::vector<cv::Mat> frames_snapshot;
  {
    std::lock_guard<std::mutex> lock(frames_mutex);
    if (captured_frames.size() < 2) {
      LOGI("Hata: Birlestirme icin yeterli kare yok.");
      return -2;
    }

    frames_snapshot.reserve(captured_frames.size());
    for (const cv::Mat &frame : captured_frames) {
      if (!frame.empty()) {
        frames_snapshot.push_back(frame.clone());
      }
    }
  }

  if (frames_snapshot.size() < 2) {
    return -3;
  }

  try {
    LOGI("Panorama birlestirme basladi. Kare sayisi: %d", (int)frames_snapshot.size());

    cv::Ptr<cv::Stitcher> stitcher = cv::Stitcher::create(cv::Stitcher::SCANS);
    stitcher->setRegistrationResol(0.6);
    stitcher->setSeamEstimationResol(0.1);
    stitcher->setCompositingResol(1.0);
    stitcher->setPanoConfidenceThresh(0.5);

    cv::Mat result_img;
    cv::Stitcher::Status status = stitcher->stitch(frames_snapshot, result_img);

    if (status != cv::Stitcher::OK || result_img.empty()) {
      LOGI("SCANS modu basarisiz. Kod: %d. PANORAMA deneniyor.", int(status));
      cv::Ptr<cv::Stitcher> scan_stitcher = cv::Stitcher::create(cv::Stitcher::PANORAMA);
      scan_stitcher->setRegistrationResol(0.6);
      scan_stitcher->setSeamEstimationResol(0.1);
      scan_stitcher->setCompositingResol(1.0);
      result_img.release();
      status = scan_stitcher->stitch(frames_snapshot, result_img);
    }

    if (status != cv::Stitcher::OK || result_img.empty()) {
      LOGI("Hata: Birlestirme basarisiz oldu. OpenCV Hata Kodu: %d", int(status));
      return -4;
    }

    std::vector<uchar> buffer;
    const std::vector<int> params = {cv::IMWRITE_JPEG_QUALITY, 92};
    if (!cv::imencode(".jpg", result_img, buffer, params) || buffer.empty()) {
      LOGI("Hata: JPG kodlama basarisiz.");
      return -5;
    }

    uint8_t *native_buffer = static_cast<uint8_t *>(std::malloc(buffer.size()));
    if (native_buffer == nullptr) {
      LOGI("Hata: Cikti icin bellek ayrilamadi.");
      return -6;
    }

    std::memcpy(native_buffer, buffer.data(), buffer.size());
    *output_image_bytes = native_buffer;
    *out_width = result_img.cols;
    *out_height = result_img.rows;

    LOGI("Birlestirme basarili! Yeni fotograf boyutlari: %d x %d", result_img.cols, result_img.rows);
    return static_cast<int32_t>(buffer.size());
  } catch (const cv::Exception &e) {
    LOGI("OpenCV birlestirme hatasi: %s", e.what());
    return -7;
  } catch (...) {
    LOGI("Bilinmeyen birlestirme hatasi.");
    return -8;
  }
}

__attribute__((visibility("default"))) __attribute__((used))
void free_panorama_buffer(uint8_t *buffer) {
  if (buffer != nullptr) {
    std::free(buffer);
  }
}

}
