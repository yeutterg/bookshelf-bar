"""Render, alpha-trim and losslessly encode production KEF finish illustrations.

python3 render_finish_set.py
The 580x352 RGBA outputs cover a roughly 290px pair at 2x display scale.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import subprocess
import json
from PIL import Image

HERE=Path(__file__).resolve().parent
BLENDER='/Applications/Blender.app/Contents/MacOS/Blender'
MODEL='/tmp/kef-models/lsx2lt-graphite.glb'
FINISHES=['lt-stone-white','lt-sage-green','lsxii-carbon-black','lsxii-mineral-white','lsxii-cobalt-blue','lsxii-lava-red','lsxii-olive-green','lsxii-soundwave','lsxii-cotton-white','lsxii-amber-haze']

def render(finish):
    raw=HERE/f'production-{finish}-raw.png'
    target=HERE/f'production-{finish}.png'
    result=subprocess.run([BLENDER,'--background','--python',str(HERE/'render_variants.py'),'--','illustrated','pair',str(raw),MODEL,finish],capture_output=True,text=True)
    if result.returncode or not raw.exists(): raise RuntimeError(f'{finish}: {result.stdout}\n{result.stderr}')
    with Image.open(raw) as source:
        source=source.convert('RGBA');bounds=source.getchannel('A').getbbox()
        assert bounds==(165,113,1035,641),(finish,bounds)
        trimmed=source.crop(bounds).resize((580,352),Image.Resampling.LANCZOS)
        trimmed.save(target,optimize=True,compress_level=9)
    print(f'{finish}: {target.name} {target.stat().st_size} bytes',flush=True)
    return {'finish':finish,'file':target.name,'raw_file':raw.name,'dimensions':[580,352],'source_alpha_bounds':bounds,'bytes':target.stat().st_size}

if __name__=='__main__':
    with ThreadPoolExecutor(max_workers=3) as pool: results=list(pool.map(render,FINISHES))
    print(json.dumps(results,indent=2))
