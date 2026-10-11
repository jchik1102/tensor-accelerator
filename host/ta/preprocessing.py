import numpy as np
from PIL import Image

VERSION = 'ink20-com-v1'

def normalize(gray):
    gray = np.asarray(gray, dtype=np.uint8)
    ys, xs = np.nonzero(gray > 16)
    if not len(xs):
        return np.zeros((28, 28), dtype=np.uint8)
    crop = gray[ys.min():ys.max()+1, xs.min():xs.max()+1]
    height, width = crop.shape
    size = (max(1, round(20*width/max(width, height))),
            max(1, round(20*height/max(width, height))))
    ink = np.asarray(Image.fromarray(crop).resize(size, Image.Resampling.BILINEAR))
    
    yy, xx = np.indices(ink.shape)
    mass = float(ink.sum())
    if mass == 0:
        return np.zeros((28, 28), dtype=np.uint8)
    left = int(round(13.5 - float((xx*ink).sum())/mass))
    top = int(round(13.5 - float((yy*ink).sum())/mass))
    left = min(max(left, 0), 28-size[0])
    top = min(max(top, 0), 28-size[1])
    result = np.zeros((28, 28), dtype=np.uint8)
    result[top:top+size[1], left:left+size[0]] = ink
    return result
