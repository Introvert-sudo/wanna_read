import 'dart:io';
import 'dart:math';

import 'package:dartcv4/dartcv.dart' as cv;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class ScannerScreen extends StatefulWidget {
  final String photoPath;
  const ScannerScreen({super.key, required this.photoPath});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  Size? _imageSize;
  List<Offset> _corners = [];
  bool _detecting = true;
  bool _warping = false;
  int? _dragIndex;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final src = await cv.imreadAsync(widget.photoPath);
      final size = Size(src.cols.toDouble(), src.rows.toDouble());
      final corners = await detectPageCorners(src);
      src.dispose();
      if (!mounted) return;
      setState(() {
        _imageSize = size;
        _corners = corners;
        _detecting = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _imageSize = const Size(1, 1);
        _corners = _fallbackCorners(const Size(1, 1));
        _detecting = false;
      });
    }
  }

  Future<void> _confirm() async {
    if (_imageSize == null || _corners.length != 4 || _warping) return;
    setState(() => _warping = true);
    try {
      final outPath = await warpPage(widget.photoPath, _corners);
      if (mounted) Navigator.pop(context, outPath);
    } catch (e) {
      if (!mounted) return;
      setState(() => _warping = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Warp failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Adjust corners'),
      ),
      body: _detecting || _imageSize == null
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
              builder: (context, constraints) {
                final viewport = constraints.biggest;
                final fitted = _fittedRect(_imageSize!, viewport);
                return Stack(
                  children: [
                    Positioned.fill(
                      child: Image.file(File(widget.photoPath), fit: BoxFit.contain),
                    ),
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _QuadPainter(
                          _corners.map((c) => _imageToScreen(c, fitted, _imageSize!)).toList(),
                        ),
                      ),
                    ),
                    for (var i = 0; i < _corners.length; i++)
                      _DragHandle(
                        position: _imageToScreen(_corners[i], fitted, _imageSize!),
                        onDrag: (screen) {
                          setState(() {
                            _dragIndex = i;
                            _corners[i] = _clampToImage(
                              _screenToImage(screen, fitted, _imageSize!),
                              _imageSize!,
                            );
                          });
                        },
                        onEnd: () => setState(() => _dragIndex = null),
                        active: _dragIndex == i,
                      ),
                    if (_warping)
                      const Positioned.fill(
                        child: ColoredBox(
                          color: Colors.black54,
                          child: Center(child: CircularProgressIndicator()),
                        ),
                      ),
                  ],
                );
              },
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _warping ? null : () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _warping || _detecting ? null : _confirm,
                  child: const Text('Confirm'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DragHandle extends StatelessWidget {
  final Offset position;
  final ValueChanged<Offset> onDrag;
  final VoidCallback onEnd;
  final bool active;

  const _DragHandle({
    required this.position,
    required this.onDrag,
    required this.onEnd,
    required this.active,
  });

  @override
  Widget build(BuildContext context) {
    const size = 28.0;
    return Positioned(
      left: position.dx - size / 2,
      top: position.dy - size / 2,
      child: GestureDetector(
        onPanUpdate: (d) => onDrag(position + d.delta),
        onPanEnd: (_) => onEnd(),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: active ? Colors.lightBlueAccent : Colors.blueAccent,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 4)],
          ),
        ),
      ),
    );
  }
}

class _QuadPainter extends CustomPainter {
  final List<Offset> points;
  _QuadPainter(this.points);

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length != 4) return;
    final line = Paint()
      ..color = Colors.lightBlueAccent
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final path = Path()..addPolygon(points, true);
    canvas.drawPath(path, line);
  }

  @override
  bool shouldRepaint(covariant _QuadPainter old) => old.points != points;
}

Rect _fittedRect(Size image, Size viewport) {
  final scale = min(viewport.width / image.width, viewport.height / image.height);
  final w = image.width * scale;
  final h = image.height * scale;
  return Rect.fromLTWH((viewport.width - w) / 2, (viewport.height - h) / 2, w, h);
}

Offset _imageToScreen(Offset pt, Rect fitted, Size image) {
  return Offset(
    fitted.left + pt.dx / image.width * fitted.width,
    fitted.top + pt.dy / image.height * fitted.height,
  );
}

Offset _screenToImage(Offset pt, Rect fitted, Size image) {
  return Offset(
    (pt.dx - fitted.left) / fitted.width * image.width,
    (pt.dy - fitted.top) / fitted.height * image.height,
  );
}

Offset _clampToImage(Offset pt, Size image) {
  return Offset(pt.dx.clamp(0, image.width - 1), pt.dy.clamp(0, image.height - 1));
}

List<Offset> _fallbackCorners(Size size) {
  final m = min(size.width, size.height) * 0.08;
  return [
    Offset(m, m),
    Offset(size.width - m, m),
    Offset(size.width - m, size.height - m),
    Offset(m, size.height - m),
  ];
}

List<Offset> orderCorners(List<Offset> pts) {
  Offset tl = pts[0], tr = pts[0], br = pts[0], bl = pts[0];
  for (final p in pts) {
    if (p.dx + p.dy < tl.dx + tl.dy) tl = p;
    if (p.dx + p.dy > br.dx + br.dy) br = p;
    if (p.dy - p.dx < tr.dy - tr.dx) tr = p;
    if (p.dy - p.dx > bl.dy - bl.dx) bl = p;
  }
  return [tl, tr, br, bl];
}

Future<List<Offset>> detectPageCorners(cv.Mat src) async {
  final w = src.cols;
  final h = src.rows;
  final size = Size(w.toDouble(), h.toDouble());
  final fallback = _fallbackCorners(size);

  cv.Mat? small;
  cv.Mat? gray;
  cv.Mat? blurred;
  cv.Mat? edges;
  try {
    final longSide = max(w, h);
    final scale = longSide > 1000 ? 1000 / longSide : 1.0;
    if (scale < 1) {
      small = await cv.resizeAsync(
        src,
        ((w * scale).round(), (h * scale).round()),
        interpolation: cv.INTER_AREA,
      );
    } else {
      small = src;
    }

    gray = await cv.cvtColorAsync(small, cv.COLOR_BGR2GRAY);
    blurred = await cv.gaussianBlurAsync(gray, (5, 5), 0);
    edges = await cv.cannyAsync(blurred, 75, 200);

    final found = await _bestQuad(edges, scale) ??
        await _bestQuad(edges, scale, mode: cv.RETR_EXTERNAL);

    return found ?? fallback;
  } catch (_) {
    return fallback;
  } finally {
    gray?.dispose();
    blurred?.dispose();
    edges?.dispose();
    if (small != null && !identical(small, src)) small.dispose();
  }
}

Future<List<Offset>?> _bestQuad(cv.Mat edges, double scale, {int mode = cv.RETR_LIST}) async {
  final (contours, hierarchy) = await cv.findContoursAsync(edges, mode, cv.CHAIN_APPROX_SIMPLE);
  hierarchy.dispose();

  final imgArea = edges.cols * edges.rows;
  double bestArea = 0;
  List<Offset>? best;

  for (final contour in contours) {
    final area = cv.contourArea(contour);
    if (area < imgArea * 0.15 || area <= bestArea) continue;

    final peri = cv.arcLength(contour, true);
    for (final eps in [0.02, 0.03, 0.04]) {
      final approx = await cv.approxPolyDPAsync(contour, eps * peri, true);
      if (approx.length == 4 && cv.isContourConvex(approx)) {
        bestArea = area;
        best = [
          for (final pt in approx) Offset(pt.x / scale, pt.y / scale),
        ];
        approx.dispose();
        break;
      }
      approx.dispose();
    }
  }
  contours.dispose();
  return best == null ? null : orderCorners(best);
}

Future<String> warpPage(String photoPath, List<Offset> corners) async {
  final ordered = orderCorners(corners);
  final src = await cv.imreadAsync(photoPath);

  double dist(Offset a, Offset b) => (a - b).distance;
  final width = max(dist(ordered[0], ordered[1]), dist(ordered[3], ordered[2])).round().clamp(1, 8000);
  final height = max(dist(ordered[0], ordered[3]), dist(ordered[1], ordered[2])).round().clamp(1, 8000);

  final srcPts = cv.VecPoint.fromList([
    for (final o in ordered) cv.Point(o.dx.round(), o.dy.round()),
  ]);
  final dstPts = cv.VecPoint.fromList([
    cv.Point(0, 0),
    cv.Point(width - 1, 0),
    cv.Point(width - 1, height - 1),
    cv.Point(0, height - 1),
  ]);

  final matrix = await cv.getPerspectiveTransformAsync(srcPts, dstPts);
  final warped = await cv.warpPerspectiveAsync(src, matrix, (width, height));

  final dir = await getTemporaryDirectory();
  final outPath = p.join(dir.path, 'warp_${DateTime.now().millisecondsSinceEpoch}.png');
  await cv.imwriteAsync(outPath, warped);

  src.dispose();
  matrix.dispose();
  warped.dispose();
  srcPts.dispose();
  dstPts.dispose();
  return outPath;
}
