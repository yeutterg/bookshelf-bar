"""Smooth illustrated KEF proxy, proportioned from official LSX II GLB bounds.

blender --background --python render_kef_cartoon.py -- olive output.png
No textures, normal maps, or runtime 3D. Every surface is deliberately simplified.
"""
import bpy
import math
import sys
from pathlib import Path
from mathutils import Vector

finish, output = sys.argv[sys.argv.index('--') + 1:]
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete(use_global=False)

def srgb(value):
    return value / 12.92 if value < .04045 else ((value + .055) / 1.055) ** 2.4

def material(name, hexcolor, roughness=.58):
    rgb=tuple(srgb(int(hexcolor[i:i+2],16)/255) for i in (0,2,4))
    mat=bpy.data.materials.new(name); mat.diffuse_color=(*rgb,1)
    mat.use_nodes=True
    shader=mat.node_tree.nodes.get('Principled BSDF')
    shader.inputs['Base Color'].default_value=(*rgb,1)
    shader.inputs['Roughness'].default_value=roughness
    shader.inputs['Metallic'].default_value=0
    shader.inputs['Specular IOR Level'].default_value=.22
    shader.inputs['Emission Color'].default_value=(*rgb,1)
    shader.inputs['Emission Strength'].default_value=.17
    return mat

olive=finish=='olive'
body_mat=material('Olive satin' if olive else 'Graphite satin','80926D' if olive else '4E555E')
baffle_mat=material('Smooth front','8B9C76' if olive else '59616B')
surround_mat=material('Soft charcoal surround','353B3C')
cone_mat=material('Copper Uni-Q' if olive else 'Graphite Uni-Q','D9B797' if olive else '68727C')
center_mat=material('Tangerine center','EBCBA4' if olive else 'A5B1BA')
fin_mat=material('Tangerine fins','AF7C55' if olive else '505C69')
logo_mat=material('KEF logo','43533A' if olive else '333E48')
base_mat=material('Inset foot','343B3F')
led_mat=material('LED glass','BBC8BD')

def finish_obj(obj, mat, parent):
    obj.data.materials.append(mat)
    obj.parent=parent
    if obj.type=='MESH':
        for poly in obj.data.polygons: poly.use_smooth=True
    return obj

def rounded_box(name,location,dimensions,radius,mat,parent):
    bpy.ops.mesh.primitive_cube_add(size=1,location=location)
    obj=bpy.context.object; obj.name=name;obj.dimensions=dimensions
    bpy.ops.object.transform_apply(location=False,rotation=False,scale=True)
    bevel=obj.modifiers.new('Generous soft edge','BEVEL');bevel.width=radius;bevel.segments=12
    bevel.affect='EDGES'
    normal=obj.modifiers.new('Smooth broad faces','WEIGHTED_NORMAL');normal.keep_sharp=True;normal.weight=40
    return finish_obj(obj,mat,parent)

def lathe(name,profile,z,mat,parent,segments=128):
    # Each profile point is radius, front/back depth. Axis points toward viewer.
    verts=[];faces=[]
    for radius,y in profile:
        for i in range(segments):
            angle=2*math.pi*i/segments
            verts.append((radius*math.cos(angle),y,z+radius*math.sin(angle)))
    for row in range(len(profile)-1):
        for i in range(segments):
            a=row*segments+i;b=row*segments+(i+1)%segments
            faces.append((a,b,b+segments,a+segments))
    mesh=bpy.data.meshes.new(name);mesh.from_pydata(verts,[],faces);mesh.update()
    obj=bpy.data.objects.new(name,mesh);bpy.context.collection.objects.link(obj)
    return finish_obj(obj,mat,parent)

def sphere(name,location,scale,mat,parent):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=48,ring_count=24,location=location)
    obj=bpy.context.object;obj.name=name;obj.scale=scale
    return finish_obj(obj,mat,parent)

def speaker(name,x,angle):
    root=bpy.data.objects.new(name,None);bpy.context.collection.objects.link(root)
    # Official geometry dimensions are approximately 154.6 x 187.4 x 239.5 mm.
    rounded_box('Rounded cabinet',(0,.006,.121),(.1546,.181,.2395),.022,body_mat,root)
    # A gently raised rounded face gives the large soft edge a clear illustrated read.
    rounded_box('Front baffle',(0,-.074,.123),(.148,.026,.231),.020,baffle_mat,root)
    rounded_box('Inset floating foot',(0,.004,.005),(.119,.139,.010),.004,base_mat,root)
    z=.126
    lathe('Smooth black rolled surround',[(.060,-.089),(.060,-.093),(.059,-.097),(.057,-.100),(.054,-.100),(.052,-.097),(.051,-.094)],z,surround_mat,root)
    lathe('Clean concave Uni-Q cone',[(.052,-.094),(.050,-.096),(.046,-.095),(.038,-.093),(.029,-.091),(.021,-.090),(.012,-.090),(0,-.090)],z,cone_mat,root)
    sphere('Smooth central waveguide',(0,-.095,z),(.016,.008,.016),center_mat,root)
    # Eight broad tangerine petals keep the KEF identity without tiny ridges/noise.
    for i in range(8):
        a=2*math.pi*i/8
        r0=.0025;r1=.0124
        coords=[]
        for radius,ang,y in [(r0,a-.24,-.1040),(r1,a-.12,-.1016),(r1,a+.10,-.1016),(r0,a+.24,-.1040)]:
            coords.append((radius*math.cos(ang),y,z+radius*math.sin(ang)))
        mesh=bpy.data.meshes.new('Tangerine petal');mesh.from_pydata(coords,[],[(0,1,2,3)]);mesh.update()
        obj=bpy.data.objects.new('Tangerine petal',mesh);bpy.context.collection.objects.link(obj);finish_obj(obj,fin_mat,root)
        solid=obj.modifiers.new('Rounded petal thickness','SOLIDIFY');solid.thickness=.0005
        bev=obj.modifiers.new('Soft petal edge','BEVEL');bev.width=.0006;bev.segments=3
    sphere('Center pin',(0,-.105,z),(.0025,.001,.0025),center_mat,root)
    sphere('Small status LED',(0,-.089,.056),(.0020,.0010,.0020),led_mat,root)
    # Small restrained wordmark survives the compact UI scale.
    curve=bpy.data.curves.new('KEF wordmark','FONT');curve.body='KEF';curve.align_x='CENTER';curve.align_y='CENTER'
    curve.size=.0093;curve.space_character=1.05;curve.extrude=.00008;curve.bevel_depth=.00004
    logo=bpy.data.objects.new('KEF wordmark',curve);bpy.context.collection.objects.link(logo)
    logo.location=(0,-.088,.211);logo.rotation_euler=(math.pi/2,0,0);finish_obj(logo,logo_mat,root)
    root.location.x=x;root.rotation_euler.z=math.radians(angle)

speaker('Left speaker',-.108,-7)
speaker('Right speaker',.108,7)

def look(obj,target): obj.rotation_euler=(Vector(target)-obj.location).to_track_quat('-Z','Y').to_euler()
camera_data=bpy.data.cameras.new('Camera');camera=bpy.data.objects.new('Camera',camera_data);bpy.context.collection.objects.link(camera)
camera.location=(0,-1.5,.185);look(camera,(0,0,.121));camera_data.type='ORTHO';camera_data.ortho_scale=.495
bpy.context.scene.camera=camera
for name,loc,energy,size in [('Large softbox',(-.40,-.50,.65),10,.60),('Front fill',(.42,-.45,.28),5,.65),('Soft rim',(.05,.25,.50),8,.55)]:
    data=bpy.data.lights.new(name,'AREA');data.energy=energy;data.size=size
    obj=bpy.data.objects.new(name,data);bpy.context.collection.objects.link(obj);obj.location=loc;look(obj,(0,0,.12))
scene=bpy.context.scene;scene.render.engine='BLENDER_EEVEE'
if hasattr(scene.eevee,'taa_render_samples'): scene.eevee.taa_render_samples=128
scene.world.color=(.20,.20,.20)
scene.view_settings.view_transform='AgX';scene.view_settings.look='AgX - Medium High Contrast'
scene.render.resolution_x=1200;scene.render.resolution_y=750;scene.render.resolution_percentage=100
scene.render.image_settings.file_format='PNG';scene.render.image_settings.color_mode='RGBA';scene.render.film_transparent=True
scene.render.filepath=output;Path(output).parent.mkdir(parents=True,exist_ok=True)
from bpy_extras.object_utils import world_to_camera_view
bpy.context.view_layer.update()
for name in ['Left speaker','Right speaker']:
    root=bpy.data.objects[name]
    center=world_to_camera_view(scene,camera,root.matrix_world @ Vector((0,-.096,.126)))
    edge=world_to_camera_view(scene,camera,root.matrix_world @ Vector((.060,-.096,.126)))
    print('DRIVER_PIXEL',name,round(center.x*1200,3),round((1-center.y)*750,3),'OUTER_RADIUS_PX',round(abs(edge.x-center.x)*1200,3))
bpy.ops.render.render(write_still=True)

