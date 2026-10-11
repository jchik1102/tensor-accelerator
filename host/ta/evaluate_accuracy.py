import json
from pathlib import Path
import numpy as np
from PIL import Image, ImageFilter
from torchvision.datasets import MNIST
from .model import load, run_batch
from .preprocessing import normalize

ROOT=Path(__file__).resolve().parents[2]

def evaluate(model, pixels):
    scores,_=run_batch(model,np.rint(pixels.reshape(-1,784).astype(float)*127/255).astype(np.int8))
    return scores.argmax(1)

def main():
    dataset=MNIST(ROOT/'data',train=False,download=False)
    labels=dataset.targets.numpy()
    raw=dataset.data.numpy()
    old=load(ROOT/'artifacts/baseline-pre-hex/model/model.json')
    new=load(ROOT/'artifacts/model-candidate/model.json')
    variants={'original':raw}
    
    for name in ('small_offset','large_offset','thick','thin','tilted'):
        images=[]
        for array in raw[:2000]:
            im=Image.fromarray(array)
            if name=='small_offset':
                im=im.resize((20,20),Image.Resampling.BILINEAR)
                canvas=Image.new('L',(28,28));canvas.paste(im,(1,7));im=canvas
            elif name=='large_offset':
                
                ys,xs=np.nonzero(array>16)
                im=im.crop((int(xs.min()),int(ys.min()),int(xs.max()+1),int(ys.max()+1)))
                ratio=24/max(im.size)
                im=im.resize(tuple(max(1,round(v*ratio)) for v in im.size),Image.Resampling.BILINEAR)
                canvas=Image.new('L',(28,28));canvas.paste(im,(28-im.width,1));im=canvas
            elif name=='thick':im=im.filter(ImageFilter.MaxFilter(3))
            elif name=='thin':im=Image.blend(im,im.filter(ImageFilter.MinFilter(3)),.5)
            else:im=im.rotate(12,resample=Image.Resampling.BILINEAR)
            images.append(np.asarray(im))
        variants[name]=np.stack(images)
    report={'kind':'CPU integer evaluation; synthetic variants are not real user drawings',
            'variant_examples':{},'baseline':{},'candidate':{},'candidate_per_class':{}}
    for name,pixels in variants.items():
        target=labels[:len(pixels)]
        normalized=np.stack([normalize(x) for x in pixels])
        a=evaluate(old,pixels);b=evaluate(new,normalized)
        report['variant_examples'][name]=len(pixels)
        report['baseline'][name]=float((a==target).mean())
        report['candidate'][name]=float((b==target).mean())
        report['candidate_per_class'][name]={str(i):float((b[target==i]==i).mean()) for i in range(10)}
        print(name,report['baseline'][name],report['candidate'][name],flush=True)
    (ROOT/'artifacts/accuracy-comparison.json').write_text(json.dumps(report,indent=2))

if __name__=='__main__':main()
