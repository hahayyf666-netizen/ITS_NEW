// Adapter around the unmodified VTM inverse-transform primitives.
// No matrix arithmetic or output-support rules are reimplemented here.
#include "TrQuant_EMT.h"
#include <iostream>
#include <vector>
#include <stdexcept>
using InvFn = void (*)(const TCoeff*,TCoeff*,int,int,int,int,TCoeff,TCoeff);
InvFn select_inverse(int type,int n) {
    if(type==0) {
        switch(n) {case 4:return fastInverseDCT2_B4;case 8:return fastInverseDCT2_B8;case 16:return fastInverseDCT2_B16;case 32:return fastInverseDCT2_B32;case 64:return fastInverseDCT2_B64;}
    } else if(type==1) {
        switch(n) {case 4:return fastInverseDST7_B4;case 8:return fastInverseDST7_B8;case 16:return fastInverseDST7_B16;case 32:return fastInverseDST7_B32;}
    } else if(type==2) {
        switch(n) {case 4:return fastInverseDCT8_B4;case 8:return fastInverseDCT8_B8;case 16:return fastInverseDCT8_B16;case 32:return fastInverseDCT8_B32;}
    }
    throw std::runtime_error("unsupported inverse mode");
}
int main() {
    int count;
    if(!(std::cin>>count)) return 2;
    for(int c=0;c<count;++c) {
        int w,h,hor,ver,cw,ch;
        if(!(std::cin>>w>>h>>hor>>ver>>cw>>ch)) return 3;
        std::vector<TCoeff> src(w*h),tmp(w*h),dst(w*h);
        for(auto& x:src) if(!(std::cin>>x)) return 4;
        // VTM fast DST/DCT8 primitives assume coefficients outside the
        // permitted frequency support are already zero.  Apply the frozen
        // engineering input-support mask before calling those primitives.
        for(int r=0;r<h;++r) for(int col=0;col<w;++col)
            if(r>=ch || col>=cw) src[r*w+col]=0;
        // Exact xIT ordering/skip argument positions, frozen shifts7/10.
        select_inverse(ver,h)(src.data(),tmp.data(),7,w,w-cw,h-ch,-32768,32767);
        select_inverse(hor,w)(tmp.data(),dst.data(),10,h,0,w-cw,-32768,32767);
        for(int i=0;i<w*h;++i) std::cout<<dst[i]<<(i+1==w*h?'\n':' ');
    }
    return 0;
}
