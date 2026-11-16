import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// A smooth photo-like gradient with some noise, so encoders have real work.
img.Image photo(int w, int h, {int seed = 1}) {
  final rnd = math.Random(seed);
  final image = img.Image(width: w, height: h);
  for (final px in image) {
    final n = rnd.nextInt(24);
    px
      ..r = (px.x * 255 ~/ w + n).clamp(0, 255)
      ..g = (px.y * 255 ~/ h + n).clamp(0, 255)
      ..b = ((px.x + px.y) * 127 ~/ (w + h) + 64).clamp(0, 255);
  }
  return image;
}

/// A white disc on a fully transparent background.
img.Image transparentLogo(int size) {
  final image = img.Image(width: size, height: size, numChannels: 4);
  img.fillCircle(
    image,
    x: size ~/ 2,
    y: size ~/ 2,
    radius: size ~/ 3,
    color: img.ColorRgba8(30, 120, 220, 255),
    antialias: true,
  );
  return image;
}

/// A non-square JPEG stored sideways with EXIF orientation 6 (rotate 90°),
/// as phones do. Stored 400×300; displays as 300×400.
List<int> rotatedJpeg() {
  final stored = photo(400, 300, seed: 7);
  stored.exif.imageIfd.orientation = 6;
  return img.encodeJpg(stored, quality: 95);
}

const inkscapeSvg = '''<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<!-- Created with Inkscape (http://www.inkscape.org/) -->
<svg
   xmlns:dc="http://purl.org/dc/elements/1.1/"
   xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
   xmlns:svg="http://www.w3.org/2000/svg"
   xmlns="http://www.w3.org/2000/svg"
   xmlns:xlink="http://www.w3.org/1999/xlink"
   xmlns:sodipodi="http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd"
   xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape"
   width="24" height="24" viewBox="0 0 24 24" version="1.1" id="svg8"
   inkscape:version="1.3" sodipodi:docname="home.svg">
  <metadata id="metadata5">
    <rdf:RDF><dc:title>Home</dc:title></rdf:RDF>
  </metadata>
  <sodipodi:namedview id="base" pagecolor="#ffffff" inkscape:zoom="22.4" />
  <defs id="defs2">
    <linearGradient id="grad"><stop offset="0" stop-color="#ff0000"/><stop offset="1" stop-color="#0000ff"/></linearGradient>
  </defs>
  <g inkscape:label="Layer 1" inkscape:groupmode="layer" id="layer1">
    <g id="g10">
      <g></g>
      <path id="path12" style="fill:url(#grad)" d="M 12.000000,3.0000001 L 2.0000000,12.500000 H 5.0000000 V 21.000000 H 10.000000 V 15.000000 H 14.000000 V 21.000000 H 19.000000 V 12.500000 H 22.000000 Z" />
      <circle cx="12.0004" cy="9.49999" r="1.500001" fill="#ffffff" transform="matrix(0.70710678,0.70710678,-0.70710678,0.70710678,0,0)"/>
      <path d="M2 2a1 1 0 011 1" stroke="#000" fill="none"/>
    </g>
  </g>
</svg>
''';

/// Writes a representative `assets_src/` tree into [root].
void writeDemoSources(String root) {
  void write(String rel, List<int> bytes) {
    final file = File(p.join(root, rel));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
  }

  write('images/hero.jpg', img.encodeJpg(photo(1200, 900), quality: 95));
  write('images/camera_photo.jpg', rotatedJpeg());
  write('images/logo.png', img.encodePng(transparentLogo(300)));
  write('images/banner@4x.png', img.encodePng(photo(800, 200, seed: 3)));
  write('images/small@2x.png', img.encodePng(photo(100, 100, seed: 5)));
  write('icons/home.icon.png', img.encodePng(transparentLogo(96)));
  write('icons/home.svg', inkscapeSvg.codeUnits);
  write('fonts/Cairo-Bold.ttf', List.filled(2048, 7));
  write('data/config.json', '{"a": 1}'.codeUnits);
}
