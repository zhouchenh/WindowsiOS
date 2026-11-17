/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Standalone, opt-in diagnostic; never run by START.bat or guest-tools.
 * Build: make shared-init-probe. No CRT or Windows SDK is needed.
 *
 * Microsoft OpenSharedResource requires Flush on the device updating a shared
 * texture. Flush is asynchronous; a fresh EVENT query plus GetData establishes
 * completion. The stress case intentionally exports after a possibly empty
 * creator Flush, without an explicit creator completion wait. It is an ordering
 * diagnostic, NOT a standalone API-conformance verdict. The matched control
 * forces creator GPU completion before exporting. Initial contents with NULL
 * initial data are unspecified by D3D11; we only compare B's explicit sentinel.
 * https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nf-d3d11-id3d11device-opensharedresource
 * https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nf-d3d11-id3d11devicecontext-flush
 * https://learn.microsoft.com/en-us/windows/win32/api/d3d11/ne-d3d11-d3d11_query
 * ABI slots/structures checked against Microsoft's win32metadata SDK headers.
 */
#include <stdint.h>
#include <stddef.h>
#include <stdatomic.h>

typedef int32_t HR;
typedef void *Handle;
typedef struct { uint32_t a; uint16_t b,c; uint8_t d[8]; } Guid;
typedef struct { uint32_t width,height,mips,array,format,samples,quality,usage,bind,cpu,misc; } TexDesc;
typedef struct { const void *data; uint32_t row_pitch,slice_pitch; } SubData;
typedef struct { void *data; uint32_t row_pitch,depth_pitch; } Mapped;
typedef struct {
    uint16_t description[128];
    uint32_t vendor,device,subsystem,revision;
    uint64_t video_memory,system_memory,shared_memory;
    uint32_t luid_low; int32_t luid_high;
    uint32_t flags;
} AdapterDesc;
_Static_assert(sizeof(Guid)==16 && sizeof(TexDesc)==44 && sizeof(SubData)==16 && sizeof(Mapped)==16,"D3D11 ARM64 ABI");
_Static_assert(sizeof(AdapterDesc)==312 && offsetof(AdapterDesc,flags)==304,"DXGI ARM64 ABI");

__declspec(dllimport) HR CreateDXGIFactory1(const Guid *,void **);
__declspec(dllimport) HR D3D11CreateDevice(void *,uint32_t,Handle,uint32_t,const uint32_t *,uint32_t,
                                         uint32_t,void **,uint32_t *,void **);
__declspec(dllimport) Handle GetStdHandle(uint32_t);
__declspec(dllimport) int32_t WriteFile(Handle,const void *,uint32_t,uint32_t *,void *);
__declspec(dllimport) Handle CreateThread(void *,size_t,uint32_t (*)(void *),void *,uint32_t,uint32_t *);
__declspec(dllimport) int32_t CloseHandle(Handle);
__declspec(dllimport) uint64_t GetTickCount64(void);
__declspec(dllimport) void Sleep(uint32_t);
__declspec(dllimport) void ExitProcess(uint32_t);

/* Minimal freestanding CRT operations used by compiler-generated struct copies. */
void *memset(void *dst,int value,size_t n)
{ uint8_t *p=dst;for(size_t i=0;i<n;++i)p[i]=(uint8_t)value;return dst; }
void *memcpy(void *dst,const void *src,size_t n)
{ uint8_t *p=dst;const uint8_t *q=src;for(size_t i=0;i<n;++i)p[i]=q[i];return dst; }

static const Guid iid_factory={0x770aae78,0xf26f,0x4dba,{0xa8,0x29,0x25,0x3c,0x83,0xd1,0xb3,0x87}};
static const Guid iid_resource={0x035f3ab4,0x482e,0x4e50,{0xb4,0x1f,0x8a,0x7f,0x8b,0xd8,0x96,0x0b}};
static const Guid iid_texture={0x6f15aaf2,0xd208,0x4e89,{0x9a,0xb4,0x48,0x95,0x35,0xd3,0x4f,0x9c}};
#define VT(object,slot,type) ((type)(*(void ***)(object))[slot])
typedef uint32_t (*RefFn)(void *);
typedef HR (*QueryFn)(void *,const Guid *,void **);
typedef HR (*EnumFn)(void *,uint32_t,void **);
typedef HR (*DescFn)(void *,AdapterDesc *);
typedef HR (*CreateTexFn)(void *,const TexDesc *,const SubData *,void **);
typedef HR (*CreateQueryFn)(void *,const uint32_t *,void **);
typedef HR (*OpenFn)(void *,Handle,const Guid *,void **);
typedef HR (*SupportFn)(void *,uint32_t,uint32_t *);
typedef HR (*HandleFn)(void *,Handle *);
typedef void (*SimpleFn)(void *);
typedef void (*EndFn)(void *,void *);
typedef HR (*DataFn)(void *,void *,void *,uint32_t,uint32_t);
typedef HR (*MapFn)(void *,void *,uint32_t,uint32_t,uint32_t,Mapped *);
typedef void (*UnmapFn)(void *,void *,uint32_t);
typedef void (*CopyFn)(void *,void *,void *);
static void release(void **p) {if(*p){VT(*p,2,RefFn)(*p);*p=NULL;}}
static void flush(void *context) {VT(context,111,SimpleFn)(context);}
static void copy(void *context,void *dst,void *src) {VT(context,47,CopyFn)(context,dst,src);}

static Handle output;
static _Atomic(const char *) phase="startup";
static uint64_t started;
static uint8_t initial[64*64*4],sentinel[64*64*4];
static void put(const char *s)
{
    uint32_t n=0,written=0;while(s[n])++n;
    if(output && output!=(Handle)(intptr_t)-1)WriteFile(output,s,n,&written,NULL);
}
static void number(uint64_t n,unsigned base)
{
    char text[32];unsigned i=sizeof(text)-1;text[i]=0;
    do{text[--i]="0123456789abcdef"[n%base];n/=base;}while(n);
    put(text+i);
}
static void field(const char *name,uint64_t n) {put(name);number(n,10);}
static void error(const char *where,HR hr)
{put("ERROR ");put(where);put(" hr=0x");number((uint32_t)hr,16);put("\n");}
static void set_phase(const char *p) {atomic_store_explicit(&phase,p,memory_order_release);}
static uint32_t watchdog(void *unused)
{
    (void)unused;
    for(;;) {
        Sleep(100);
        if(GetTickCount64()-started>=120000) {
            put("WATCHDOG own process exiting after 120 seconds; phase=");
            put(atomic_load_explicit(&phase,memory_order_acquire));put("\n");
            ExitProcess(124);
        }
    }
}
/* Every completion marker is a NEW event; never reuse an EVENT query. */
static int complete(void *device,void *context,const char *label)
{
    void *query=NULL;const uint32_t desc[2]={0,0};
    set_phase(label);
    HR hr=VT(device,24,CreateQueryFn)(device,desc,&query);
    if(hr<0 || !query){error("CreateQuery(EVENT)",hr);return 0;}
    VT(context,28,EndFn)(context,query);
    flush(context);
    uint64_t begin=GetTickCount64();int ok=0;
    for(;;) {
        uint32_t done=0;
        hr=VT(context,29,DataFn)(context,query,&done,sizeof(done),1); /* DONOTFLUSH */
        if(hr==0 && done){ok=1;break;}
        if(hr<0){error(label,hr);break;}
        if(GetTickCount64()-begin>=5000){put("TIMEOUT fresh EVENT ");put(label);put("\n");break;}
        Sleep(1);
    }
    release(&query);return ok;
}
static int create_texture(void *device,TexDesc *desc,const uint8_t *bytes,unsigned bpp,void **out)
{
    SubData data={bytes,64*bpp,64*64*bpp};
    HR hr=VT(device,5,CreateTexFn)(device,desc,bytes?&data:NULL,out);
    if(hr<0 || !*out){error("CreateTexture2D",hr);return 0;}
    return 1;
}
struct Readback {uint32_t mismatch,zeros;uint64_t hash;};
/* Copy plus fresh EVENT precedes a nonblocking staging Map. */
static int readback(void *device,void *context,void *texture,void *staging,unsigned bpp,
                    struct Readback *result,const char *label)
{
    set_phase(label);copy(context,staging,texture);
    if(!complete(device,context,label))return 0;
    Mapped mapped={0};uint64_t begin=GetTickCount64();HR hr;
    for(;;) {
        hr=VT(context,14,MapFn)(context,staging,0,1,0x100000,&mapped); /* READ, DO_NOT_WAIT */
        if(hr!=(HR)0x887a000au)break; /* DXGI_ERROR_WAS_STILL_DRAWING */
        if(GetTickCount64()-begin>=5000){put("TIMEOUT staging Map\n");return 0;}
        Sleep(1);
    }
    if(hr<0){error("Map staging",hr);return 0;}
    int valid=mapped.data && mapped.row_pitch>=64*bpp;
    memset(result,0,sizeof(*result));result->hash=UINT64_C(14695981039346656037);
    if(valid)for(unsigned y=0;y<64;++y)for(unsigned x=0;x<64*bpp;++x) {
        uint8_t v=((const uint8_t *)mapped.data)[(size_t)y*mapped.row_pitch+x];
        result->mismatch+=v!=sentinel[y*64*bpp+x];result->zeros+=v==0;
        result->hash=(result->hash^v)*UINT64_C(1099511628211);
    }
    VT(context,15,UnmapFn)(context,staging,0);
    if(!valid)put("ERROR invalid staging pointer or pitch\n");
    return valid;
}
static void print_read(const char *name,const struct Readback *r)
{put(name);field(" mismatch=",r->mismatch);field(" zero_bytes=",r->zeros);put(" hash=0x");number(r->hash,16);put("\n");}

/* 0 observed stable, 1 changed after A, 2 unsupported shared format,
 * 3 pre-A baseline mismatch, 4 API/completion failure. */
static unsigned run_case(void *a,void *ac,void *b,void *bc,uint32_t format,unsigned bpp,
                         uint32_t bind,int with_initial,int control,unsigned iteration)
{
    void *asrc=NULL,*adst=NULL,*shared=NULL,*dxgi=NULL,*imported=NULL,*bsrc=NULL,*stage=NULL;
    Handle handle=NULL;unsigned result=4;
    TexDesc desc={64,64,1,1,format,1,0,0,bind,0,0};
    put("CASE ");field("format=",format);field(" bytes=",bpp);field(" bind=",bind);
    field(" initial=",with_initial);field(" control=",control);field(" iteration=",iteration);put("\n");
    for(unsigned i=0;i<64*64*bpp;++i) {
        initial[i]=(uint8_t)(0x21+(i*13+iteration)%89);
        sentinel[i]=(uint8_t)(0x91+(i*7+iteration)%97);
    }
    set_phase("prepare unrelated A resources");
    if(!create_texture(a,&desc,initial,bpp,&asrc) || !create_texture(a,&desc,NULL,bpp,&adst))goto done;
    set_phase("prepare B resources");
    desc.usage=0; /* Ordinary initialized source, uploaded before B's copy. */
    if(!create_texture(b,&desc,sentinel,bpp,&bsrc))goto done;
    desc.usage=3;desc.bind=0;desc.cpu=0x20000;
    if(!create_texture(b,&desc,NULL,bpp,&stage))goto done;
    desc.usage=0;desc.bind=bind;desc.cpu=0;desc.misc=2; /* legacy SHARED */
    set_phase("A shared creation");
    HR hr=VT(a,5,CreateTexFn)(a,&desc,with_initial?&(SubData){initial,64*bpp,64*64*bpp}:NULL,&shared);
    if(hr<0 || !shared) {error("shared creation",hr);result=hr==(HR)0x887a0004u?2:4;goto done;}
    /* Satisfy the documented shared-update Flush requirement, but intentionally
     * do not use EVENT in the stress arm before publication. */
    set_phase("A plain Flush before export");flush(ac);
    if(control) {
        copy(ac,adst,asrc);
        if(!complete(a,ac,"A control completion before export"))goto done;
    }
    set_phase("shared handle export/import");
    hr=VT(shared,0,QueryFn)(shared,&iid_resource,&dxgi);
    if(hr<0 || !dxgi){error("QI IDXGIResource",hr);result=hr==(HR)0x80004002u?2:4;goto done;}
    hr=VT(dxgi,8,HandleFn)(dxgi,&handle);
    if(hr<0 || !handle){error("GetSharedHandle",hr);result=hr==(HR)0x887a0004u?2:4;goto done;}
    hr=VT(b,28,OpenFn)(b,handle,&iid_texture,&imported);
    if(hr<0 || !imported){error("OpenSharedResource",hr);result=hr==(HR)0x887a0004u?2:4;goto done;}
    /* Legacy GetSharedHandle handles are not NT handles: never CloseHandle. */
    set_phase("B sentinel write");copy(bc,imported,bsrc);
    if(!complete(b,bc,"B sentinel completion"))goto done;
    struct Readback before,after;
    if(!readback(b,bc,imported,stage,bpp,&before,"B baseline readback"))goto done;
    print_read("BEFORE_A",&before);
    if(before.mismatch){put("BASELINE_MISMATCH: cannot attribute to later A work\n");result=3;goto done;}
    set_phase("A unrelated late work");copy(ac,adst,asrc);
    if(!complete(a,ac,"A late unrelated completion"))goto done;
    if(!readback(b,bc,imported,stage,bpp,&after,"B after A readback"))goto done;
    print_read("AFTER_A",&after);
    result=after.mismatch?1:0;
    put(result?"CHANGED_AFTER_A: ordering candidate, compare matched control\n":"STABLE: no overwrite observed in this case\n");
 done:
    set_phase("case resource cleanup");
    release(&stage);release(&bsrc);release(&imported);release(&dxgi);release(&shared);release(&adst);release(&asrc);
    return result;
}

void WinMainCRTStartup(void)
{
    output=GetStdHandle((uint32_t)-11);started=GetTickCount64();
    put("SharedInitProbe ARM64 v1: local-only 64x64 two-device ordering diagnostic\n");
    put("No WARP fallback. 5s event/map polling bounds; 120s own-process watchdog.\n");
    put("Plain Flush stress is not a standalone conformance test; compare forced-completion control.\n");
    Handle thread=CreateThread(NULL,0,watchdog,NULL,0,NULL);
    if(!thread){put("ERROR cannot start watchdog; refusing GPU work\n");ExitProcess(3);}
    CloseHandle(thread);
    void *factory=NULL,*adapter=NULL,*a=NULL,*ac=NULL,*b=NULL,*bc=NULL;
    uint32_t counts[5]={0},control_failures=0,matched_changed=0,completed=0;
    unsigned exit_code=3;
    HR hr=CreateDXGIFactory1(&iid_factory,&factory);
    if(hr<0 || !factory){error("CreateDXGIFactory1",hr);goto finish;}
    for(uint32_t i=0;i<16;++i) {
        void *candidate=NULL;AdapterDesc desc={0};
        hr=VT(factory,12,EnumFn)(factory,i,&candidate);
        if(hr<0 || !candidate)break;
        hr=VT(candidate,10,DescFn)(candidate,&desc);
        put("ADAPTER ");field("index=",i);put(" vendor=0x");number(desc.vendor,16);
        put(" device=0x");number(desc.device,16);field(" flags=",desc.flags);put("\n");
        if(hr>=0 && desc.vendor==0x1af4 && !(desc.flags&2)){adapter=candidate;break;}
        release(&candidate);
    }
    if(!adapter){put("SKIP: no hardware VirtIO vendor 0x1af4 adapter; no result from WARP or another adapter\n");exit_code=2;goto finish;}
    const uint32_t levels[]={0xb000};uint32_t level;
    set_phase("create device A");
    hr=D3D11CreateDevice(adapter,0,NULL,0x20,levels,1,7,&a,&level,&ac);
    if(hr<0 || !a || !ac){error("D3D11CreateDevice A",hr);goto finish;}
    set_phase("create device B");
    hr=D3D11CreateDevice(adapter,0,NULL,0x20,levels,1,7,&b,&level,&bc);
    if(hr<0 || !b || !bc){error("D3D11CreateDevice B",hr);goto finish;}
    put("Selected explicit VirtIO hardware adapter, feature level=0x");number(level,16);put("\n");
    const uint32_t formats[]={87,61,65}; /* B8G8R8A8_UNORM, R8_UNORM, A8_UNORM */
    for(unsigned f=0;f<3;++f) {
        uint32_t support_a=0,support_b=0;
        HR ha=VT(a,29,SupportFn)(a,formats[f],&support_a);
        HR hb=VT(b,29,SupportFn)(b,formats[f],&support_b);
        put("FORMAT ");field("id=",formats[f]);put(" support_A=0x");number(support_a,16);put(" support_B=0x");number(support_b,16);put("\n");
        if(ha<0 || hb<0 || !(support_a&0x20) || !(support_b&0x20)) {put("SKIP format: texture2D unsupported\n");++counts[2];continue;}
        uint32_t bind=((support_a&support_b)&0x200)?8:0; /* shader sample */
        if((support_a&support_b)&0x4000)bind|=0x20; /* render target clear path */
        for(unsigned initial_data=0;initial_data<2;++initial_data)for(unsigned iteration=0;iteration<3;++iteration) {
            unsigned control=run_case(a,ac,b,bc,formats[f],f?1:4,bind,(int)initial_data,1,iteration);
            ++counts[control];if(control!=0 && control!=2)++control_failures;
            if(control==4)goto summary;
            unsigned stress=run_case(a,ac,b,bc,formats[f],f?1:4,bind,(int)initial_data,0,iteration);
            ++counts[stress];if(stress==1 && control==0)++matched_changed;
            if(control==0 && stress==0)++completed;
            if(stress==4)goto summary;
        }
    }
 summary:
    put("SUMMARY ");field("stable_cases=",counts[0]);field("changed_after_A=",counts[1]);
    field("explicitly_unsupported=",counts[2]);field("baseline_mismatch=",counts[3]);
    field("api_or_completion_failure=",counts[4]);field("control_failures=",control_failures);
    field("stable_pairs=",completed);put("\n");
    if(matched_changed && !control_failures && !counts[3] && !counts[4])put("EVIDENCE: stress changed after A while completed controls did not; correlate with host candidate OFF/ON and raw captures.\n");
    else if(control_failures || counts[3] || counts[4])put("INCONCLUSIVE: control/baseline/API failure prevents a shared-initializer attribution.\n");
    else put("No shared-initializer overwrite reproduced; this does not establish the cause of Explorer text loss.\n");
    if(counts[2])put("PARTIAL_COVERAGE: unsupported formats/sharing interfaces were not validated by stable cases.\n");
    exit_code=(counts[1] || counts[3] || counts[4])?1:((completed==18 && !counts[2])?0:2);
 finish:
    set_phase("device cleanup");release(&bc);release(&b);release(&ac);release(&a);release(&adapter);release(&factory);
    put("EXIT ");number(exit_code,10);field(" elapsed_ms=",GetTickCount64()-started);put("\n");ExitProcess(exit_code);
}
