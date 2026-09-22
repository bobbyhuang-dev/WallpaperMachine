#!/usr/bin/env python3
"""Brand export contracts: native appearances, template alpha and ICO interoperability."""
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import brand


class BrandTests(unittest.TestCase):
    def test_ico_entries_locate_images_including_256_pixel_encoding(self):
        images = [(16, b'first-image'), (32, b'second-longer-image'), (256, b'largest-image')]
        data = brand.ico_bytes(images)
        self.assertEqual(struct.unpack_from('<HHH', data), (0, 1, 3))
        for i, (size, payload) in enumerate(images):
            w, h, colors, reserved, planes, bits, length, offset = struct.unpack_from('<BBBBHHII', data, 6 + i * 16)
            self.assertEqual((w or 256, h or 256), (size, size))
            self.assertEqual((planes, bits), (1, 32))
            self.assertEqual(data[offset:offset + length], payload)

    @unittest.skipUnless(sys.platform == 'darwin', 'Requires macOS Icon Composer')
    def test_app_icon_renders_one_background_per_appearance(self):
        developer = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
        tool = developer.parent / 'Applications/Icon Composer.app/Contents/Executables/ictool'
        with tempfile.TemporaryDirectory() as scratch:
            work = Path(scratch)
            icon = work / 'AppIcon.icon'
            with patch.object(brand, 'APP_ICON', icon), patch.object(brand, 'TRAY_ICON_SET', work / 'tray'):
                brand.write_app_icons(work)
            for rendition, background, foreground in [('Default', 1, 0), ('Dark', 0, 1)]:
                with self.subTest(appearance=rendition):
                    image = work / f'{rendition}.png'
                    subprocess.run([str(tool), str(icon), '--export-image', '--output-file', str(image),
                                    '--platform', 'macOS', '--rendition', rendition,
                                    '--width', '256', '--height', '256', '--scale', '1',
                                    '--design-generation', '26'],
                                   check=True, capture_output=True)
                    result = subprocess.run(['swift', '-e', r'''
import AppKit
let image = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))!
let points = [(0, 0), (25, 128), (40, 128), (128, 48), (128, 128), (101, 155)]
let colors = points.map { x, y -> [Double] in
    let c = image.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
}
// Cross both screen/frame joins: neither may expose the appearance background.
let joins = ((48...96).map { (128, $0) } + (166...208).map { ($0, 128) }).map { x, y -> [Double] in
    let c = image.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
}
let foreground = Double(CommandLine.arguments[2])!
let edges = [false, true].map { vertical -> [Int] in
    let pixels = (0..<256).filter { p in
        let c = image.colorAt(x: vertical ? 128 : p, y: vertical ? p : 128)!.usingColorSpace(.sRGB)!
        return c.alphaComponent > 0.99 && [c.redComponent, c.greenComponent, c.blueComponent].allSatisfy {
            abs($0 - foreground) < 0.04
        }
    }
    return [pixels.first ?? -1, pixels.last ?? -1]
}
print(String(data: try JSONSerialization.data(withJSONObject: [colors, joins, edges]), encoding: .utf8)!)
''', str(image), str(foreground)], check=True, capture_output=True, text=True)
                    colors, joins, edges = json.loads(result.stdout)
                    for first, last in edges:
                        self.assertGreaterEqual(first, 0, 'Frame must be visible on each central axis')
                        self.assertAlmostEqual(first, 255 - last, delta=1,
                                               msg='Opposing display-frame margins must match')
                    corner, outer, inner, frame, screen, gear_clearance = colors
                    self.assertEqual(corner[3], 0, 'System mask must leave transparent corners')
                    for color in (outer, inner):
                        self.assertGreater(color[3], 0.99)
                        for channel in color[:3]:
                            self.assertAlmostEqual(channel, background, delta=0.04,
                                                   msg='No contrasting outer tile or inset background')
                    for channel in frame[:3]:
                        self.assertAlmostEqual(channel, foreground, delta=0.04,
                                               msg='Frame must contrast with its appearance background')
                    self.assertGreater(max(screen[:3]) - min(screen[:3]), 0.2,
                                       'Wallpaper panel must retain its color')
                    for channel in gear_clearance[:3]:
                        self.assertAlmostEqual(channel, background, delta=0.04,
                                               msg='Wallpaper must leave a clean cutout around the gear')
                    for color in joins:
                        self.assertGreater(color[3], 0.99)
                        self.assertGreater(max(abs(c - background) for c in color[:3]), 0.2,
                                           'Enlarged screen/frame joins must not expose a background seam')

    @unittest.skipUnless(sys.platform == 'darwin', 'Requires macOS Icon Composer')
    def test_dock_variants_preserve_transparent_margin_and_distinct_artwork(self):
        with tempfile.TemporaryDirectory() as scratch:
            work = Path(scratch)
            with patch.object(brand, 'APP_ICON', work / 'AppIcon.icon'), \
                    patch.object(brand, 'TRAY_ICON_SET', work / 'tray'), \
                    patch.object(brand, 'DOCK_ICONS', work / 'dock'):
                brand.write_app_icons(work)
                paths = brand.write_dock_icons(work)
            result = subprocess.run(['swift', '-e', r'''
import AppKit
for path in CommandLine.arguments.dropFirst() {
    let image = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path)))!
    let points = [(0, 0), (50, 512), (512, 50), (180, 512), (512, 256), (512, 512), (327, 698)]
    let colors = points.map { x, y -> [Double] in
        let c = image.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
    }
    let frame = colors[4]
    let frameWidth = (180..<320).filter { y in
        let c = image.colorAt(x: 512, y: y)!.usingColorSpace(.sRGB)!
        return c.alphaComponent > 0.99 && zip([c.redComponent, c.greenComponent, c.blueComponent], frame.prefix(3))
            .allSatisfy { abs($0 - $1) < 0.04 }
    }.count
    print(String(data: try JSONSerialization.data(withJSONObject: [colors, frameWidth]), encoding: .utf8)!)
}
''', *map(str, paths)], check=True, capture_output=True, text=True)
            frame_widths = []
            for path, line in zip(paths, result.stdout.splitlines(), strict=True):
                with self.subTest(icon=path.stem):
                    colors, frame_width = json.loads(line)
                    frame_widths.append(frame_width)
                    self.assertGreater(frame_width, 0, 'Top frame must remain visible')
                    corner, left_margin, top_margin, background, frame, interior, hub = colors
                    for color in (corner, left_margin, top_margin):
                        self.assertEqual(color[3], 0, 'Dock margin must stay transparent, not white-matted')
                    expected_background = 0 if path.stem == 'night' else 1
                    for color in (background, hub):
                        self.assertGreater(color[3], 0.99)
                        for channel in color[:3]:
                            self.assertAlmostEqual(channel, expected_background, delta=0.04)
                    if path.stem == 'minimal':
                        self.assertGreater(frame[2], 0.75, 'Minimal mark must remain blue')
                        self.assertGreater(frame[2] - frame[1], 0.2)
                        self.assertGreater(frame[1] - frame[0], 0.2)
                        for channel in interior[:3]:
                            self.assertAlmostEqual(channel, 1, delta=0.04, msg='Minimal has no wallpaper fill')
                    else:
                        for channel in frame[:3]:
                            self.assertAlmostEqual(channel, 1 - expected_background, delta=0.04)
                        self.assertGreater(max(interior[:3]) - min(interior[:3]), 0.2,
                                           'Day and Night retain the colored wallpaper')
            # The wallpaper slightly overlaps the inner edge to avoid a seam;
            # allow three source pixels (under 0.3 px at picker size).
            self.assertLessEqual(max(frame_widths) - min(frame_widths), 3,
                                 'Dock variants must have consistent rendered frame thickness')

    @unittest.skipUnless(sys.platform == 'darwin', 'Requires macOS image tools')
    def test_tray_export_preserves_transparent_background_and_antialiasing(self):
        with tempfile.TemporaryDirectory() as scratch:
            work = Path(scratch)
            sizes = {work / name: px for name, px in brand.TRAY_ICON_SIZES.items()}
            brand.rasterize(brand.tray_svg(), sizes, work, source=256, template=True)
            result = subprocess.run(['swift', '-e', r'''
import AppKit
for path in CommandLine.arguments.dropFirst() {
    let image = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path)))!
    var alpha: [Int] = []
    for y in 0..<image.pixelsHigh {
        for x in 0..<image.pixelsWide {
            alpha.append(Int((image.colorAt(x: x, y: y)!.alphaComponent * 255).rounded()))
        }
    }
    let data = try JSONSerialization.data(withJSONObject: alpha)
    print(String(data: data, encoding: .utf8)!)
}
''', *map(str, sizes)], check=True, capture_output=True, text=True)
            for px, line in zip(sizes.values(), result.stdout.splitlines(), strict=True):
                with self.subTest(size=px):
                    alpha = json.loads(line)
                    self.assertEqual(len(alpha), px * px)
                    self.assertEqual(alpha[0], 0, 'Background must be transparent')
                    self.assertEqual(alpha[(px // 2) * px + px // 2], 0,
                                     'Display interior must be transparent')
                    self.assertEqual(max(alpha), 255, 'Glyph must remain opaque')
                    self.assertTrue(any(0 < a < 255 for a in alpha),
                                    'Preserve antialiased edges')

if __name__ == '__main__':
    unittest.main()
