// بيرسم أيقونة Basket (سلة بيضا على مربع أخضر بزوايا مدورة) بدل ما تتعمل في برنامج رسم.
// التشغيل من فولدر source:  dart run tool/make_app_icon.dart
// وبعدها:  dart run flutter_launcher_icons   (عشان أيقونات أندرويد وويندوز تتعمل منها)
import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

const _size = 1024;

void main() {
  File('assets/icon/app_icon.png').writeAsBytesSync(img.encodePng(_draw(background: true, scale: 1)));
  // أيقونة أندرويد المتغيرة: السلة لوحدها في نص المساحة الآمنة، والخلفية لونها من pubspec
  File('assets/icon/app_icon_foreground.png').writeAsBytesSync(img.encodePng(_draw(background: false, scale: 0.62)));
  stdout.writeln('تم: assets/icon/app_icon.png و app_icon_foreground.png');
}

img.Image _draw({required bool background, required double scale}) {
  final im = img.Image(width: _size, height: _size, numChannels: 4);
  final green1 = [0x15, 0x80, 0x3D], green2 = [0x22, 0xC5, 0x5E];
  final orange = img.ColorRgba8(0xFF, 0x7A, 0x1A, 255);
  final white = img.ColorRgba8(255, 255, 255, 255);
  final c = _size / 2;

  for (var y = 0; y < _size; y++) {
    for (var x = 0; x < _size; x++) {
      // الإحداثيات بالنسبة لمقاس الرسم الأصلي (1024) بعد التصغير حوالين النص
      final u = (x - c) / scale + c, v = (y - c) / scale + c;
      img.Color? color;
      if (background && _roundedRect(x.toDouble(), y.toDouble(), 0, 0, 1024, 1024, 220)) {
        final t = (x + y) / (2 * _size);
        color = img.ColorRgba8(
          (green1[0] + (green2[0] - green1[0]) * t).round(),
          (green1[1] + (green2[1] - green1[1]) * t).round(),
          (green1[2] + (green2[2] - green1[2]) * t).round(),
          255,
        );
      }
      if (_basket(u, v)) color = white;
      if (_dist(u, v, 790, 250) <= 78) color = orange;
      if (color != null) im.setPixel(x, y, color);
    }
  }
  return im;
}

double _dist(double x, double y, double cx, double cy) => math.sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy));

bool _roundedRect(double x, double y, double l, double t, double r, double b, double rad) {
  if (x < l || x > r || y < t || y > b) return false;
  final cx = x.clamp(l + rad, r - rad), cy = y.clamp(t + rad, b - rad);
  return _dist(x, y, cx, cy) <= rad;
}

/// السلة: إيد نص دايرة، وحافة عريضة، وجسم شبه منحرف فيه 3 فتحات.
bool _basket(double x, double y) {
  // الإيد
  final d = _dist(x, y, 512, 470);
  if (y <= 470 && d >= 200 && d <= 250) return true;
  // الحافة
  if (_roundedRect(x, y, 150, 430, 874, 520, 40)) return true;
  // الجسم: بيضيق لتحت
  if (y >= 520 && y <= 810) {
    final t = (y - 520) / 290;
    final half = 330 - 80 * t;
    if ((x - 512).abs() > half) return false;
    // الزوايا اللي تحت مدورة
    if (y > 760 && !_roundedRect(x, y, 512 - half, 520, 512 + half, 810, 50)) return false;
    // الفتحات
    for (final sx in [392.0, 512.0, 632.0]) {
      if ((x - sx).abs() < 22 && y > 575 && y < 750) return false;
    }
    return true;
  }
  return false;
}
