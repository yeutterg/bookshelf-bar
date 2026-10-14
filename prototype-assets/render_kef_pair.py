"""Render a matched KEF speaker pair from an official KEF GLB asset.

Usage:
  blender --background --python render_kef_pair.py -- model.glb output.png [product|toon]
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

import bpy
from mathutils import Vector


def look_at(obj: bpy.types.Object, point: Vector) -> None:
    obj.rotation_euler = (point - obj.location).to_track_quat("-Z", "Y").to_euler()


def import_group(path: Path, name: str) -> bpy.types.Object:
    before = set(bpy.context.scene.objects)
    bpy.ops.import_scene.gltf(filepath=str(path))
    imported = [obj for obj in bpy.context.scene.objects if obj not in before]
    root = bpy.data.objects.new(name, None)
    bpy.context.scene.collection.objects.link(root)
    for obj in imported:
        if obj.parent is None:
            matrix = obj.matrix_world.copy()
            obj.parent = root
            obj.matrix_world = matrix
    return root


def mesh_bounds(objects: list[bpy.types.Object]) -> tuple[Vector, Vector]:
    points: list[Vector] = []
    for obj in objects:
        if obj.type != "MESH":
            continue
        points.extend(obj.matrix_world @ Vector(corner) for corner in obj.bound_box)
    return (
        Vector((min(p.x for p in points), min(p.y for p in points), min(p.z for p in points))),
        Vector((max(p.x for p in points), max(p.y for p in points), max(p.z for p in points))),
    )


def add_area(name: str, location: tuple[float, float, float], energy: float, size: float) -> None:
    data = bpy.data.lights.new(name, "AREA")
    data.energy = energy
    data.shape = "DISK"
    data.size = size
    light = bpy.data.objects.new(name, data)
    bpy.context.scene.collection.objects.link(light)
    light.location = location
    look_at(light, Vector((0, 0, 0.12)))


def configure_product(scene: bpy.types.Scene) -> None:
    scene.render.engine = "BLENDER_EEVEE"
    scene.view_settings.look = "AgX - Medium High Contrast"


def configure_toon(scene: bpy.types.Scene) -> None:
    """Use a soft, graphic render while preserving KEF's finish textures.

    The official GLBs use a single textured mesh, so Workbench rendering would lose
    finish and driver detail. Eevee keeps those textures, while rough materials,
    broad lighting and a restrained Freestyle contour remove photoreal surface noise.
    No 3D scene is rendered at runtime.
    """
    scene.render.engine = "BLENDER_EEVEE"
    scene.view_settings.look = "AgX - Medium High Contrast"
    for material in bpy.data.materials:
        if not material.use_nodes or material.node_tree is None:
            continue
        for node in material.node_tree.nodes:
            if node.type != "BSDF_PRINCIPLED":
                continue
            for name, value in (
                ("Roughness", 0.72),
                ("Metallic", 0.0),
                ("Specular IOR Level", 0.28),
                ("Coat Weight", 0.0),
            ):
                socket = node.inputs.get(name)
                if socket is not None:
                    socket.default_value = value

    scene.render.use_freestyle = True
    scene.render.line_thickness = 0.7
    line_style = bpy.context.view_layer.freestyle_settings.linesets[0].linestyle
    line_style.color = (0.025, 0.03, 0.04)
    line_style.alpha = 0.38


def main() -> None:
    args = sys.argv[sys.argv.index("--") + 1 :]
    if len(args) not in (2, 3):
        raise SystemExit("Expected: model.glb output.png [product|toon]")
    model_path, output_path = map(Path, args[:2])
    style = args[2] if len(args) == 3 else "toon"
    if style not in {"product", "toon"}:
        raise SystemExit("Style must be 'product' or 'toon'")

    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)

    left = import_group(model_path, "Left speaker")
    left_objects = list(bpy.context.scene.objects)
    low, high = mesh_bounds(left_objects)
    width = high.x - low.x
    center = (low + high) / 2

    right = import_group(model_path, "Right speaker")
    gap = width * 0.18
    offset = (width + gap) / 2
    left.location.x -= center.x + offset
    right.location.x -= center.x - offset
    left.location.z -= low.z
    right.location.z -= low.z

    # A subtle toe-in reveals the cabinet depth while retaining a clean front view.
    left.rotation_euler.z = math.radians(-3.0)
    right.rotation_euler.z = math.radians(3.0)

    camera_data = bpy.data.cameras.new("Camera")
    camera = bpy.data.objects.new("Camera", camera_data)
    bpy.context.scene.collection.objects.link(camera)
    camera.location = (0, -1.35, (high.z - low.z) * 0.50)
    target = Vector((0, 0, (high.z - low.z) * 0.48))
    look_at(camera, target)
    camera_data.type = "ORTHO"
    camera_data.ortho_scale = (high.z - low.z) * 1.85
    bpy.context.scene.camera = camera

    add_area("Key", (-0.45, -0.65, 0.55), 18, 0.65)
    add_area("Fill", (0.50, -0.35, 0.30), 9, 0.50)
    add_area("Rim", (0.0, 0.35, 0.48), 14, 0.45)

    world = bpy.data.worlds.new("World") if not bpy.context.scene.world else bpy.context.scene.world
    bpy.context.scene.world = world
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.025, 0.028, 0.032, 1)
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.08

    scene = bpy.context.scene
    if style == "toon":
        configure_toon(scene)
    else:
        configure_product(scene)
    scene.render.resolution_x = 1400
    scene.render.resolution_y = 760
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.film_transparent = True
    scene.render.filepath = str(output_path)
    scene.render.image_settings.color_depth = "8"

    output_path.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.render.render(write_still=True)


if __name__ == "__main__":
    main()
