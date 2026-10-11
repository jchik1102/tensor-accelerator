from fractions import Fraction
import random
import pytest
from host.ta.numeric import requantize, matrix, encode_scale

def test_signed_ties_and_saturation():
    assert [requantize(x,1,1) for x in [-5,-3,-1,1,3,5]] == [-2,-2,0,0,2,2]
    assert requantize(-3,1,0,True)==0
    assert requantize(-(1<<31),2147483647,0)==-128
    assert requantize((1<<31)-1,2147483647,0)==127

def test_fraction_oracle():
    rng=random.Random(42)
    for _ in range(2000):
        v=rng.randrange(-(1<<31),(1<<31));m=rng.randrange(1,1<<31);s=rng.randrange(63)
        expected=min(127,max(-128,round(Fraction(v*m,1<<s))))
        assert requantize(v,m,s)==expected

def test_hand_matrix_and_bound():
    assert matrix([[1,-2,3],[-128,127,0]], [[-4,5,6],[1,0,-1]], [7,-1],[1,1],[0,0]) == (
        [[11,-3],[127,-128]],[[11,-3],[1154,-129]])
    with pytest.raises(ValueError,match='unsafe'):
        matrix([[1]],[[1]],[2147483647],[1],[0])

@pytest.mark.parametrize('m,s',[(0,0),(1,63),(1,-1),(1<<31,0)])
def test_invalid_parameters(m,s):
    with pytest.raises(ValueError):requantize(0,m,s)

def test_scale_encoding():
    for ratio in [1e-8,.001,.5,1,32,1e6]:
        m,s=encode_scale(ratio)
        assert abs(m/(1<<s)-ratio) <= ratio*1e-8
    for ratio in [0,-1,float('nan'),float('inf'),1e30]:
        with pytest.raises(ValueError):encode_scale(ratio)

def test_reject_silent_integer_casts():
    with pytest.raises(ValueError,match='integer encoding'):
        matrix([[1]],[[1.5]],[0],[1],[0])
    with pytest.raises(ValueError,match='integer encoding'):requantize(1,1,0.5)
