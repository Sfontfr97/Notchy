"""Renders demo/index.html to notchy-demo.mp4, frame by frame, with Notchy's sounds.

    python3 record.py            # 60 fps, 1920 wide
    python3 record.py --fps 30   # quicker

Needs playwright (with Chromium) and ffmpeg.
"""
import os, sys, shutil, subprocess, tempfile, pathlib
from playwright.sync_api import sync_playwright

HERE = pathlib.Path(__file__).resolve().parent
FPS = int(sys.argv[sys.argv.index('--fps') + 1]) if '--fps' in sys.argv else 60
LOOP = 30.0
OUT = HERE / 'notchy-demo.mp4'

# The same moments as the story in index.html: (seconds, system sound, volume)
SOUNDS = [
    (2.6, 'Tink', 0.25), (13.2, 'Tink', 0.25), (23.3, 'Tink', 0.25),   # clicks
    (11.0, 'Purr', 0.9),                                              # needs your OK
    (15.2, 'Glass', 0.7), (18.6, 'Glass', 0.7),                       # done
]

frames = pathlib.Path(tempfile.mkdtemp(prefix='notchy-frames-'))
try:
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(viewport={'width': 1512, 'height': 982}, device_scale_factor=2)
        page.goto((HERE / 'index.html').as_uri() + '#record')
        page.wait_for_function('typeof window.renderAt === "function"')
        page.evaluate('document.fonts.ready')
        total = int(LOOP * FPS)
        for i in range(total):
            page.evaluate(f'window.renderAt({i / FPS})')
            page.screenshot(path=str(frames / f'f{i:05d}.jpg'), type='jpeg', quality=93)
            if i % 300 == 0:
                print(f'frame {i}/{total}', flush=True)
        browser.close()

    cmd = ['ffmpeg', '-y', '-loglevel', 'error', '-framerate', str(FPS), '-i', str(frames / 'f%05d.jpg')]
    for _, name, _ in SOUNDS:
        cmd += ['-i', f'/System/Library/Sounds/{name}.aiff']
    mix = []
    for n, (at, _, vol) in enumerate(SOUNDS, start=1):
        ms = int(at * 1000)
        mix.append(f'[{n}:a]adelay={ms}|{ms},volume={vol}[s{n}]')
    mix.append(''.join(f'[s{n}]' for n in range(1, len(SOUNDS) + 1)) +
               f'amix=inputs={len(SOUNDS)}:normalize=0,apad,atrim=0:{LOOP}[aud]')
    cmd += ['-filter_complex', ';'.join(mix),
            '-map', '0:v', '-map', '[aud]',
            '-vf', 'scale=1920:-2:flags=lanczos',
            '-c:v', 'libx264', '-preset', 'slow', '-crf', '18', '-pix_fmt', 'yuv420p', '-movflags', '+faststart',
            '-c:a', 'aac', '-b:a', '160k', '-t', str(LOOP), str(OUT)]
    subprocess.run(cmd, check=True)
    print('Made', OUT)
finally:
    shutil.rmtree(frames, ignore_errors=True)
