#!/usr/bin/env python3
"""Deterministic, stdlib-only KanjiVG -> normalized, ordered stroke polylines.

Input is the official repository at PINNED_COMMIT, extracted offline. Only base
Unicode filenames are admitted. Unknown SVG commands fail closed (no approximation).
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import xml.etree.ElementTree as ET

PINNED_COMMIT = '70a0b7ae0c18ceb5cb358274b029cce0234a43bc'
EXPECTED_BASE_SHA256 = '3162fb37a42b5eaf1695a51eea018c986ff495a51bbf8a8a7d70c8594f37dd53'
QUANTIZATION = 10000
TOLERANCE = 0.25  # SVG pixels, before fitting the 109px viewBox into [0, 1].
TOKEN = re.compile(r'[A-Za-z]|[-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?')


def flatten_cubic(p0, p1, p2, p3, depth=0):
    """De Casteljau subdivision until controls are within 0.25px of the chord."""
    dx, dy = p3[0] - p0[0], p3[1] - p0[1]
    chord = math.hypot(dx, dy)
    def distance(point):
        if chord == 0:
            return math.dist(point, p0)
        return abs(dy * (point[0] - p0[0]) - dx * (point[1] - p0[1])) / chord
    # The projection guard also preserves collinear curves that double back.
    controls = [math.dist(p0, p1), math.dist(p1, p2), math.dist(p2, p3)]
    if depth >= 16 or (max(distance(p1), distance(p2)) <= TOLERANCE and sum(controls) <= chord + TOLERANCE):
        return [p3]
    def midpoint(a, b):
        return ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2)
    a, b, c = midpoint(p0, p1), midpoint(p1, p2), midpoint(p2, p3)
    d, e = midpoint(a, b), midpoint(b, c)
    middle = midpoint(d, e)
    return flatten_cubic(p0, a, d, middle, depth + 1) + flatten_cubic(middle, e, c, p3, depth + 1)


def sample_path(path):
    tokens = TOKEN.findall(path)
    if re.sub(TOKEN, '', path).strip(' ,\t\r\n'):
        raise ValueError('unparsed SVG input')
    points, current, previous_control = [], (0.0, 0.0), None
    command, index = None, 0
    while index < len(tokens):
        if tokens[index].isalpha():
            command = tokens[index]
            index += 1
        if command not in ('M', 'm', 'L', 'l', 'C', 'c', 'S', 's'):
            raise ValueError(f'unsupported SVG command: {command}')
        count = {'M': 2, 'L': 2, 'C': 6, 'S': 4}[command.upper()]
        values = [float(value) for value in tokens[index:index + count]]
        if len(values) != count or not all(math.isfinite(value) for value in values):
            raise ValueError('invalid SVG coordinates')
        index += count
        def point(at):
            x, y = values[at:at + 2]
            return (x + current[0], y + current[1]) if command.islower() else (x, y)
        if command.upper() == 'M':
            if points:
                raise ValueError('discontinuous subpath in one pen-down stroke')
            current = point(0)
            points.append(current)
            previous_control = None
            command = 'l' if command == 'm' else 'L'
        elif command.upper() == 'L':
            current = point(0)
            points.append(current)
            previous_control = None
        else:
            if command.upper() == 'C':
                first, second, end = point(0), point(2), point(4)
            else:
                first = current if previous_control is None else (2 * current[0] - previous_control[0], 2 * current[1] - previous_control[1])
                second, end = point(0), point(2)
            points.extend(flatten_cubic(current, first, second, end))
            current, previous_control = end, second
    if len(points) < 2:
        raise ValueError('stroke has no trajectory')
    return points


def convert_svg(path):
    tree = ET.parse(path)
    paths = [element for element in tree.iter() if element.tag.endswith('}path') and re.search(r'-s\d+$', element.get('id', ''))]
    numbers = [int(re.search(r'-s(\d+)$', element.get('id')).group(1)) for element in paths]
    if numbers != list(range(1, len(paths) + 1)) or not paths:
        raise ValueError(f'{path}: invalid stroke order')
    strokes = [sample_path(element.attrib['d']) for element in paths]
    points = [point for stroke in strokes for point in stroke]
    min_x, min_y = min(0, min(p[0] for p in points)), min(0, min(p[1] for p in points))
    size = max(109 - min_x, 109 - min_y, max(p[0] for p in points) - min_x, max(p[1] for p in points) - min_y)
    result = []
    for stroke in strokes:
        quantized = []
        for x, y in stroke:
            point = [round((x - min_x) / size * QUANTIZATION), round((y - min_y) / size * QUANTIZATION)]
            if quantized[-2:] != point:
                quantized.extend(point)
        if len(quantized) < 4:
            raise ValueError(f'{path}: degenerate quantized stroke')
        result.append(quantized)
    return result


def build(source, output, archive=None):
    characters = {}
    digest = hashlib.sha256()
    for path in sorted((source / 'kanji').glob('*.svg')):
        if not re.fullmatch(r'[0-9a-f]{5,6}', path.stem):
            continue
        digest.update(path.name.encode() + b'\0' + path.read_bytes())
        characters[chr(int(path.stem, 16))] = convert_svg(path)
    if digest.hexdigest() != EXPECTED_BASE_SHA256:
        raise ValueError('source base SVG digest differs from the pinned upstream revision')
    payload = {'version': 1, 'quantization': QUANTIZATION, 'source': {'project': 'KanjiVG', 'commit': PINNED_COMMIT, 'license': 'CC-BY-SA-3.0', 'base_svg_sha256': digest.hexdigest()}, 'characters': characters}
    output.mkdir(parents=True, exist_ok=True)
    data = (json.dumps(payload, ensure_ascii=False, separators=(',', ':')) + '\n').encode()
    (output / 'strokes.json').write_bytes(data)
    (output / 'COPYING').write_bytes((source / 'COPYING').read_bytes())
    manifest = dict(payload['source'], glyphs=len(characters), strokes=sum(map(len, characters.values())), bytes=len(data), data_sha256=hashlib.sha256(data).hexdigest(), svg_tolerance_px=TOLERANCE, normalization='isotropic fit of union of 109px viewBox and sampled bounds; round to 1/10000')
    if archive:
        manifest['archive_sha256'] = hashlib.sha256(archive.read_bytes()).hexdigest()
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(manifest, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--output', type=Path, default=Path('app/assets/kanjivg'))
    parser.add_argument('--archive', type=Path)
    args = parser.parse_args()
    build(args.source, args.output, args.archive)
