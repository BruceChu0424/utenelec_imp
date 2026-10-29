"""Run Blender with --background --factory-startup --python this.py -- output.mp4.

Produces only a solid teal COLOR strip, using Blender's bundled H.264 encoder.
The resulting three-second file is embedded in synthetic_h264_mp4.dart so browser
tests do not need to fetch or bundle an application asset. Container metadata
includes generation time, so regenerating produces a new SHA-256.
"""
from pathlib import Path
import sys

import bpy

output = Path(sys.argv[sys.argv.index('--') + 1]).resolve()
scene = bpy.context.scene
scene.frame_start, scene.frame_end = 1, 30
scene.render.resolution_x, scene.render.resolution_y = 160, 90
scene.render.resolution_percentage = 100
scene.render.fps = 10
scene.render.image_settings.media_type = 'VIDEO'
scene.render.image_settings.file_format = 'FFMPEG'
scene.render.ffmpeg.format = 'MPEG4'
scene.render.ffmpeg.codec = 'H264'
scene.render.ffmpeg.constant_rate_factor = 'MEDIUM'
scene.render.filepath = str(output)
scene.render.use_sequencer = True
editor = scene.sequence_editor_create()
strip = editor.strips.new_effect('Synthetic teal', 'COLOR', channel=1,
                                frame_start=1, length=30)
strip.color = (0.05, 0.58, 0.53)
bpy.ops.render.render(animation=True)
