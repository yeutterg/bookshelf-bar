"""Shape-faithful cartoon studies built from the official KEF cabinet mesh.

Usage: blender --background --python render_variants.py -- satin pair output.png [model.glb] [graphite|olive]
Treatments: satin, clay, illustrated. Layouts: pair, angle.
Cabinet mesh is preserved; only driver, finish, LED and wordmark are simplified.
"""
import bpy
import math
import sys
from pathlib import Path
from mathutils import Vector
from bpy_extras.object_utils import world_to_camera_view

args=sys.argv[sys.argv.index('--')+1:]
style,layout,output=args[:3]
model=args[3] if len(args)>3 else '/tmp/kef-models/lsx2lt-graphite.glb'
finish=args[4] if len(args)>4 else 'graphite'
assert style in {'satin','clay','illustrated'} and layout in {'pair','angle'}
assert finish in {'graphite','olive'}
bpy.ops.object.select_all(action='SELECT');bpy.ops.object.delete(use_global=False)
bpy.ops.import_scene.gltf(filepath=model)
source=next(o for o in bpy.context.scene.objects if o.type=='MESH')
mesh=source.data
parents=list(range(len(mesh.vertices)))
def root(i):
    while parents[i]!=i: parents[i]=parents[parents[i]];i=parents[i]
    return i
for edge in mesh.edges:
    a,b=edge.vertices;parents[root(a)]=root(b)
points=[source.matrix_world@v.co for v in mesh.vertices]
groups={}
for i in range(len(points)): groups.setdefault(root(i),[]).append(i)
cabinet_groups=[]
for ident,indices in groups.items():
    coords=[points[i] for i in indices]
    if max(v.x for v in coords)-min(v.x for v in coords)>.12 and max(v.z for v in coords)-min(v.z for v in coords)>.18 and len(indices)>100:
        cabinet_groups.append((ident,indices))
assert len(cabinet_groups)==4, 'Official mesh changed: inspect cabinet components before rendering.'
cabinet=[]
normal_matrix=source.matrix_world.to_3x3().inverted().transposed()
for ident,indices in cabinet_groups:
    remap={old:new for new,old in enumerate(indices)}
    verts=[(points[i].x,points[i].y,points[i].z+.005244) for i in indices]
    selected=[poly for poly in mesh.polygons if root(poly.vertices[0])==ident]
    faces=[tuple(remap[i] for i in poly.vertices) for poly in selected]
    normals=[tuple((normal_matrix@mesh.corner_normals[i].vector).normalized()) for poly in selected for i in poly.loop_indices]
    cabinet.append((verts,faces,normals,max(points[i].y for i in indices)-min(points[i].y for i in indices)))
bpy.ops.object.select_all(action='SELECT');bpy.ops.object.delete(use_global=False)

def linear(c): return c/12.92 if c<.04045 else ((c+.055)/1.055)**2.4
def material(name,hexcolor):
    color=tuple(linear(int(hexcolor[i:i+2],16)/255) for i in (0,2,4))
    mat=bpy.data.materials.new(name);mat.use_nodes=True
    nt=mat.node_tree;bs=nt.nodes.get('Principled BSDF')
    if style=='illustrated':
        # Broad normal-based shading: no atlas, normal map, sparkle or shadow noise.
        geom=nt.nodes.new('ShaderNodeNewGeometry')
        dot=nt.nodes.new('ShaderNodeVectorMath');dot.operation='DOT_PRODUCT';dot.inputs[1].default_value=Vector((-.35,-.65,.68)).normalized()
        nt.links.new(geom.outputs['Normal'],dot.inputs[0])
        ramp=nt.nodes.new('ShaderNodeValToRGB');ramp.color_ramp.interpolation='EASE'
        stops=[(0,.43),(.4,.68),(.70,1.07),(1,1.35)]
        for e in list(ramp.color_ramp.elements)[1:]:ramp.color_ramp.elements.remove(e)
        for n,(pos,scale) in enumerate(stops):
            e=ramp.color_ramp.elements[0] if n==0 else ramp.color_ramp.elements.new(pos)
            e.position=pos;e.color=(*(v*scale for v in color),1)
        nt.links.new(dot.outputs['Value'],ramp.inputs[0])
        emit=nt.nodes.new('ShaderNodeEmission');nt.links.new(ramp.outputs[0],emit.inputs[0]);nt.links.new(emit.outputs[0],nt.nodes.get('Material Output').inputs[0])
    else:
        bs.inputs['Base Color'].default_value=(*color,1)
        bs.inputs['Roughness'].default_value=.43 if style=='satin' else .95
        bs.inputs['Specular IOR Level'].default_value=.28 if style=='satin' else .06
        bs.inputs['Emission Color'].default_value=(*color,1)
        bs.inputs['Emission Strength'].default_value=.13 if style=='satin' else .27
    return mat

palettes={
    'satin':['58616B','626E78','313940','7A8791','B6C2C9','56636F','34414D'],
    'clay':['71777B','7B8388','414649','929A9C','C4CAC9','737D80','4C5659'],
    'illustrated':['41474B','4C545A','252729','505254','707274','3D4043','3A515E'],
}
palette=palettes[style]
if style=='illustrated' and finish=='olive':
    # Preserve the previously approved olive/copper material colors.
    palette=['80926D','8B9C76','353B3C','D9B797','EBCBA4','AF7C55','43533A']
body,baffle,surround,cone,center,petal,logo=[material(n,c) for n,c in zip(['Cabinet','Baffle','Surround','Cone','Center','Petal','Wordmark'],palette)]
led=material('LED','C4D2D0')

def mesh_object(name,verts,faces,mat,parent):
    data=bpy.data.meshes.new(name);data.from_pydata(verts,[],faces);data.update()
    obj=bpy.data.objects.new(name,data);bpy.context.collection.objects.link(obj);obj.parent=parent;obj.data.materials.append(mat)
    for p in data.polygons:p.use_smooth=True
    return obj
def lathe(name,profile,z,mat,parent):
    verts=[];faces=[];segments=128
    for radius,y in profile:
        for i in range(segments):
            a=2*math.pi*i/segments;verts.append((radius*math.cos(a),y,z+radius*math.sin(a)))
    for row in range(len(profile)-1):
        for i in range(segments):
            a=row*segments+i;b=row*segments+(i+1)%segments;faces.append((a,b,b+segments,a+segments))
    return mesh_object(name,verts,faces,mat,parent)
def sphere(name,loc,scale,mat,parent):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=48,ring_count=24,location=loc)
    obj=bpy.context.object;obj.name=name;obj.scale=scale;obj.parent=parent;obj.data.materials.append(mat)
    for p in obj.data.polygons:p.use_smooth=True
    return obj

def speaker(name,x,angle):
    parent=bpy.data.objects.new(name,None);bpy.context.collection.objects.link(parent)
    for i,(verts,faces,normals,depth) in enumerate(cabinet):
        obj=mesh_object('Official curved cabinet '+str(i),verts,faces,body if depth>.1 else baffle,parent)
        obj.data.normals_split_custom_set(normals)
        if .018<depth<.030: front=obj
    z=.116493+.005244
    lathe('Smooth surround',[(.0572,-.102),(.0565,-.104),(.0545,-.106),(.049,-.105),(.046,-.102),(.044,-.100)],z,surround,parent)
    lathe('Smooth Uni-Q cone',[(.044,-.100),(.042,-.100),(.037,-.096),(.030,-.091),(.021,-.086),(.012,-.085),(0,-.085)],z,cone,parent)
    sphere('Waveguide',(0,-.087,z),(.015,.008,.015),center,parent)
    for i in range(8):
        a=2*math.pi*i/8;verts=[]
        for r,theta,y in [(.0025,a-.22,-.096),(.0116,a-.12,-.0937),(.0116,a+.10,-.0937),(.0025,a+.22,-.096)]:
            verts.append((r*math.cos(theta),y,z+r*math.sin(theta)))
        obj=mesh_object('Tangerine petal',verts,[(0,1,2,3)],petal,parent)
        solid=obj.modifiers.new('Petal thickness','SOLIDIFY');solid.thickness=.0004
        bevel=obj.modifiers.new('Soft petal edge','BEVEL');bevel.width=.0005;bevel.segments=3
    sphere('Center pin',(0,-.097,z),(.0022,.001,.0022),center,parent)
    sphere('Status LED',(0,-.1013,.0558),(.0028,.0007,.0028),led,parent)
    if style!='illustrated':
        curve=bpy.data.curves.new('KEF below driver','FONT');curve.body='KEF';curve.align_x='CENTER';curve.align_y='CENTER';curve.size=.009
        text=bpy.data.objects.new('KEF below driver',curve);bpy.context.collection.objects.link(text);text.data.materials.append(logo)
        text.location=(0,-.10065,.029);text.rotation_euler=(math.pi/2,0,0);text.parent=parent
        # Follow the genuine curved baffle closely so the logo does not float/cast a duplicate shadow.
        bpy.ops.object.select_all(action='DESELECT');text.select_set(True);bpy.context.view_layer.objects.active=text
        bpy.ops.object.convert(target='MESH');text=bpy.context.object
        wrap=text.modifiers.new('Printed on curved baffle','SHRINKWRAP');wrap.target=front;wrap.wrap_method='NEAREST_SURFACEPOINT';wrap.offset=.00010
    parent.location.x=x;parent.rotation_euler.z=math.radians(angle)
    return parent

if layout=='pair':
    # Approved C: left baffle aims right, right baffle aims left, exposing the outer sides.
    # Preserve the earlier A/B comparison poses exactly.
    toe_in_degrees=11 if style=='illustrated' else -18
    speakers=[speaker('Left',-.116,toe_in_degrees),speaker('Right',.116,-toe_in_degrees)]
else:speakers=[speaker('Angle study',0,35)]
def look(obj,point):obj.rotation_euler=(Vector(point)-obj.location).to_track_quat('-Z','Y').to_euler()
camdata=bpy.data.cameras.new('Camera');cam=bpy.data.objects.new('Camera',camdata);bpy.context.collection.objects.link(cam)
cam.location=(0,-1.5,.22 if layout=='pair' else .33);look(cam,(0,0,.120));camdata.type='ORTHO';camdata.ortho_scale=.55 if layout=='pair' else .31
bpy.context.scene.camera=cam
for name,loc,power,size in [('Key',(-.45,-.60,.70),12,.7),('Fill',(.45,-.4,.32),5,.7),('Rim',(.12,.30,.50),9,.55)]:
    data=bpy.data.lights.new(name,'AREA');data.energy=power;data.size=size
    obj=bpy.data.objects.new(name,data);bpy.context.collection.objects.link(obj);obj.location=loc;look(obj,(0,0,.12))
scene=bpy.context.scene;scene.render.engine='BLENDER_EEVEE'
if hasattr(scene.eevee,'taa_render_samples'):scene.eevee.taa_render_samples=128
scene.world.color=(.2,.2,.2)
scene.view_settings.view_transform='Standard' if style=='illustrated' else 'AgX'
scene.view_settings.look='None' if style=='illustrated' else 'AgX - Medium High Contrast'
scene.render.resolution_x=1200 if layout=='pair' else 800
scene.render.resolution_y=750 if layout=='pair' else 900
scene.render.resolution_percentage=100;scene.render.film_transparent=True
scene.render.image_settings.file_format='PNG';scene.render.image_settings.color_mode='RGBA'
bpy.context.view_layer.update()
for obj in speakers:
    c=world_to_camera_view(scene,cam,obj.matrix_world@Vector((0,-.103,.121737)))
    print('PROJECTED_CENTER',obj.name,c.x,1-c.y)
scene.render.filepath=output;Path(output).parent.mkdir(parents=True,exist_ok=True)
bpy.ops.render.render(write_still=True)
