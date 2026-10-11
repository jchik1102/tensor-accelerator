import numpy as np
from PIL import Image, ImageDraw
from host.ta.preprocessing import normalize
from host.ta.runtime import preprocess

def stroke(size, offset):
    im=Image.new('L',(140,140))
    draw=ImageDraw.Draw(im)
    x,y=offset
    draw.line([(x,y),(x+size,y),(x+size//2,y+size)],fill=255,width=max(1,size//10))
    return np.asarray(im)

def test_translation_invariance_and_centroid():
    first=normalize(stroke(60,(10,10)))
    second=normalize(stroke(60,(60,60)))
    assert np.array_equal(first,second)
    yy,xx=np.indices(first.shape)
    assert abs((xx*first).sum()/first.sum()-13.5)<=.5
    assert abs((yy*first).sum()/first.sum()-13.5)<=.5
    ys,xs=np.nonzero(first>16)
    assert max(xs.max()-xs.min()+1,ys.max()-ys.min()+1)==20

def test_blank_and_edge_strokes_no_wrap():
    assert not normalize(np.zeros((28,28),np.uint8)).any()
    im=np.zeros((28,28),np.uint8);im[:,0]=255
    result=normalize(im)
    assert not result[:,0].any() and not result[:,-1].any()
    assert result.max()==255

def test_preview_is_exact_quantizer_source():
    im=stroke(80,(30,30))
    values,preview=preprocess(im.reshape(-1).tolist(),140,140)
    assert values==np.rint(np.asarray(preview)*127/255).astype(int).tolist()
    assert preview==normalize(im).reshape(-1).tolist()
