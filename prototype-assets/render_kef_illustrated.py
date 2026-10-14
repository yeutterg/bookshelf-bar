"""Render a softly illustrated KEF pair from an official KEF GLB.

The output preserves the manufacturer's textured finish and geometry, but uses
a restrained toon ramp instead of photoreal material response. It is intended
to be composited with lightweight SwiftUI motion layers at runtime.

Usage:
  blender --background --python render_kef_illustrated.py -- model.glb output.png [soft|outline]
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

import bpy
from mathutils import Vector


def look_at(obj: bpy.types.Object, target: Vector) -> None:
    obj.rotation_euler = (target - obj.location).to_track_quat("-Z", "Y").to_euler()


def add_pair(model_path: Path) -> tuple[float, float]:
    bpy.ops.import_scene.gltf(filepath=str(model_path))
    meshes = [obj for obj in bpy.context.scene.objects if obj.type == "MESH"]
    points = [obj.matrix_world @ Vector(corner) for obj in meshes for corner in obj.bound_box]
    low = Vector(tuple(min(point[index] for point in points) for index in range(3)))
    high = Vector(tuple(max(point[index] for point in points) for index in range(3)))
    width, height = high.x - low.x, high.z - low.z
    center = (low + high) / 2

    original_roots = [obj for obj in bpy.context.scene.objects if obj.parent is None]
    left = bpy.data.objects.new("Left speaker", None)
    bpy.context.collection.objects.link(left)
    for obj in original_roots:
        matrix = obj.matrix_world.copy()
        obj.parent = left
        obj.matrix_world = matrix
    left.location = (-center.x - width * 0.68, 0, -low.z)
    left.rotation_euler.z = math.radians(-7)

    bpy.ops.import_scene.gltf(filepath=str(model_path))
    right = bpy.data.objects.new("Right speaker", None)
    bpy.context.collection.objects.link(right)
    for obj in list(bpy.context.scene.objects):
        if obj.parent is None and obj not in (left, right):
            matrix = obj.matrix_world.copy()
            obj.parent = right
            obj.matrix_world = matrix
    right.location = (-center.x + width * 0.68, 0, -low.z)
    right.rotation_euler.z = math.radians(7)
    return width, height


def illustrate_materials(model_path: Path) -> None:
    for material in bpy.data.materials:
        if not material.use_nodes or material.node_tree is None:
            continue
        nodes = material.node_tree.nodes
        links = material.node_tree.links
        principled = next((node for node in nodes if node.type == "BSDF_PRINCIPLED"), None)
        if principled is None or not principled.inputs["Base Color"].links:
            continue

        color_source = principled.inputs["Base Color"].links[0].from_socket
        diffuse = nodes.new("ShaderNodeBsdfDiffuse")
        diffuse.inputs["Color"].default_value = (0.8, 0.8, 0.8, 1)
        normal = next((node for node in nodes if node.type == "NORMAL_MAP"), None)
        if normal is not None:
            normal.inputs["Strength"].default_value = 0.2
            links.new(normal.outputs["Normal"], diffuse.inputs["Normal"])

        shader_to_rgb = nodes.new("ShaderNodeShaderToRGB")
        links.new(diffuse.outputs[0], shader_to_rgb.inputs[0])
        ramp = nodes.new("ShaderNodeValToRGB")
        ramp.color_ramp.interpolation = "EASE"
        stops = ((0.0, 0.40), (0.32, 0.66), (0.62, 0.86), (0.9, 1.0))
        for element in list(ramp.color_ramp.elements)[1:]:
            ramp.color_ramp.elements.remove(element)
        ramp.color_ramp.elements[0].position = stops[0][0]
        ramp.color_ramp.elements[0].color = (stops[0][1],) * 3 + (1,)
        for position, value in stops[1:]:
            ramp.color_ramp.elements.new(position).color = (value,) * 3 + (1,)
        links.new(shader_to_rgb.outputs[0], ramp.inputs[0])

        finish = nodes.new("ShaderNodeHueSaturation")
        finish.inputs["Saturation"].default_value = 0.66
        finish.inputs["Value"].default_value = 1.8 if "graphite" in model_path.name else 1.3
        links.new(color_source, finish.inputs["Color"])
        gamma = nodes.new("ShaderNodeGamma")
        gamma.inputs["Gamma"].default_value = 0.73 if "graphite" in model_path.name else 0.92
        links.new(finish.outputs[0], gamma.inputs["Color"])

        multiply = nodes.new("ShaderNodeMixRGB")
        multiply.blend_type = "MULTIPLY"
        multiply.inputs[0].default_value = 0.68
        links.new(gamma.outputs[0], multiply.inputs[1])
        links.new(ramp.outputs[0], multiply.inputs[2])
        emission = nodes.new("ShaderNodeEmission")
        links.new(multiply.outputs[0], emission.inputs["Color"])
        output = next(node for node in nodes if node.type == "OUTPUT_MATERIAL")
        links.new(emission.outputs[0], output.inputs[0])


def main() -> None:
    args = sys.argv[sys.argv.index("--") + 1 :]
    if len(args) not in (2, 3):
        raise SystemExit("Expected: model.glb output.png [soft|outline]")
    model_path, output_path = map(Path, args[:2])
    style = args[2] if len(args) == 3 else "soft"

    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    width, height = add_pair(model_path)
    illustrate_materials(model_path)

    camera_data = bpy.data.cameras.new("Camera")
    camera = bpy.data.objects.new("Camera", camera_data)
    bpy.context.collection.objects.link(camera)
    camera.location = (0, -1.35, height * 0.59)
    look_at(camera, Vector((0, 0, height * 0.48)))
    camera_data.type = "ORTHO"
    camera_data.ortho_scale = width * 3.28
    bpy.context.scene.camera = camera

    for name, location, energy, size in (
        ("Key", (-0.4, -0.6, 0.65), 30, 0.85),
        ("Fill", (0.45, -0.3, 0.35), 12, 0.65),
    ):
        data = bpy.data.lights.new(name, "AREA")
        data.energy = energy
        data.size = size
        light = bpy.data.objects.new(name, data)
        bpy.context.collection.objects.link(light)
        light.location = location
        look_at(light, Vector((0, 0, height / 2)))

    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.world.color = (0.15, 0.15, 0.15)
    scene.view_settings.view_transform = "Standard"
    scene.view_settings.look = "None"
    scene.render.resolution_x = 1200
    scene.render.resolution_y = 750
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = True
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    if style == "outline":
        scene.render.use_freestyle = True
        scene.render.line_thickness = 0.8
        line_style = bpy.context.view_layer.freestyle_settings.linesets[0].linestyle
        line_style.color = (0.06, 0.075, 0.07)
        line_style.alpha = 0.45

    output_path.parent.mkdir(parents=True, exist_ok=True)
    scene.render.filepath = str(output_path)
    bpy.ops.render.render(write_still=True)


if __name__ == "__main__":
    main()
