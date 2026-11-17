/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Local fake COM/GPU model verifies the probe's ordering and classification;
 * it does not run D3D or validate the shipped driver. */
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#define __declspec(x)
#undef memset
#undef memcpy
#define memset probe_memset
#define memcpy probe_memcpy
#include "../tools/shared_init_probe_arm64.c"
#undef memset
#undef memcpy

struct Obj {void **vt;int refs,owner,kind,ready;unsigned bpp;uint8_t data[16384],wanted[16384];};
struct Ctx {void **vt;int owner;struct Obj *dst[8],*src[8],*query;unsigned count;};
struct Dev {void **vt;int owner;};
static void *dv[40],*cv[112],*rv[9];
static struct Dev da={dv,1},db={dv,2};
static struct Ctx ca={.vt=cv,.owner=1},cb={.vt=cv,.owner=2};
static struct Obj *objects[128];
static unsigned used,live,queries,closes;
static int fixed,corrupt,fail_query,fail_shared,unsupported;
static uint64_t fake_time;
static uint8_t mapped_copy[64*(256+8)];
HR CreateDXGIFactory1(const Guid *g,void **o){(void)g;(void)o;return -1;}
HR D3D11CreateDevice(void *a,uint32_t t,Handle s,uint32_t f,const uint32_t *l,uint32_t n,
                    uint32_t sdk,void **d,uint32_t *level,void **c)
{(void)a;(void)t;(void)s;(void)f;(void)l;(void)n;(void)sdk;(void)d;(void)level;(void)c;return -1;}
Handle GetStdHandle(uint32_t h){(void)h;return NULL;}
int32_t WriteFile(Handle h,const void *p,uint32_t n,uint32_t *w,void *o)
{(void)h;(void)p;(void)o;*w=n;return 1;}
Handle CreateThread(void *s,size_t z,uint32_t (*f)(void *),void *p,uint32_t flags,uint32_t *id)
{(void)s;(void)z;(void)f;(void)p;(void)flags;(void)id;return NULL;}
int32_t CloseHandle(Handle h){(void)h;++closes;return 1;}
uint64_t GetTickCount64(void){fake_time+=1001;return fake_time;}
void Sleep(uint32_t n){(void)n;}
void ExitProcess(uint32_t n){fprintf(stderr,"unexpected ExitProcess %u\n",n);abort();}
static struct Obj *new_obj(int owner,int kind)
{
    assert(used<128);struct Obj *o=calloc(1,sizeof(*o));assert(o);
    o->vt=rv;o->refs=1;o->owner=owner;o->kind=kind;objects[used++]=o;++live;return o;
}
static uint32_t drop(void *p)
{
    struct Obj *o=p;assert(o->refs>0);if(--o->refs)return (uint32_t)o->refs;
    for(unsigned i=0;i<used;++i)if(objects[i]==o)objects[i]=NULL;
    --live;free(o);return 0;
}
static HR qi(void *p,const Guid *g,void **out)
{assert(!memcmp(g,&iid_resource,sizeof(*g)));struct Obj *o=p;++o->refs;*out=o;return 0;}
static HR get_handle(void *p,Handle *out){*out=p;return 0;}
static HR open_shared(void *dev,Handle h,const Guid *g,void **out)
{assert(dev==&db && !memcmp(g,&iid_texture,sizeof(*g)));struct Obj *o=h;++o->refs;*out=o;return 0;}
static HR texture(void *p,const TexDesc *d,const SubData *initial_data,void **out)
{
    *out=NULL;if(d->misc && (fail_shared || unsupported))return unsupported?(HR)0x887a0004u:(HR)0x80004005u;
    struct Obj *o=new_obj(((struct Dev *)p)->owner,0);o->bpp=d->format==87?4:1;
    if(initial_data)for(unsigned y=0;y<64;++y)
        memcpy(o->wanted+y*64*o->bpp,(const uint8_t *)initial_data->data+y*initial_data->row_pitch,64*o->bpp);
    if(d->misc && fixed){memcpy(o->data,o->wanted,64*64*o->bpp);o->ready=1;}
    *out=o;return 0;
}
static HR query(void *p,const uint32_t *d,void **out)
{assert(d[0]==0 && d[1]==0);++queries;*out=new_obj(((struct Dev *)p)->owner,1);return 0;}
static void enqueue(void *p,void *d,void *s)
{struct Ctx *c=p;assert(c->count<8);c->dst[c->count]=d;c->src[c->count++]=s;}
static void end_event(void *p,void *q)
{struct Ctx *c=p;assert(!c->query);c->query=q;}
static void execute(void *p)
{
    struct Ctx *c=p;if(!c->count && !c->query)return; /* empty Flush leaves initialization pending */
    for(unsigned i=0;i<used;++i) {
        struct Obj *o=objects[i];if(o && !o->kind && o->owner==c->owner && !o->ready) {
            memcpy(o->data,o->wanted,64*64*o->bpp);o->ready=1;
        }
    }
    for(unsigned i=0;i<c->count;++i) {
        struct Obj *d=c->dst[i],*s=c->src[i];memcpy(d->data,s->data,64*64*d->bpp);
        if(corrupt && c->owner==2 && d->owner==1)d->data[0]^=1;
    }
    c->count=0;if(c->query)c->query->ready=1;c->query=NULL;
}
static HR event_data(void *p,void *q,void *data,uint32_t size,uint32_t flags)
{(void)p;assert(size==4 && flags==1);*(uint32_t *)data=fail_query?0:((struct Obj *)q)->ready;return fail_query?1:0;}
static HR map(void *p,void *tex,uint32_t sub,uint32_t type,uint32_t flags,Mapped *mapped)
{
    (void)p;struct Obj *o=tex;assert(sub==0 && type==1 && flags==0x100000);
    mapped->data=mapped_copy;mapped->row_pitch=64*o->bpp+8;
    for(unsigned y=0;y<64;++y)memcpy(mapped_copy+y*mapped->row_pitch,o->data+y*64*o->bpp,64*o->bpp);
    return 0;
}
static void unmap(void *p,void *tex,uint32_t sub){(void)p;(void)tex;assert(!sub);}
int main(int argc,char **argv)
{
    assert(argc==2);dv[5]=(void *)texture;dv[24]=(void *)query;dv[28]=(void *)open_shared;
    cv[14]=(void *)map;cv[15]=(void *)unmap;cv[28]=(void *)end_event;cv[29]=(void *)event_data;
    cv[47]=(void *)enqueue;cv[111]=(void *)execute;rv[0]=(void *)qi;rv[2]=(void *)drop;rv[8]=(void *)get_handle;
    int control=0,with_data=0;unsigned expected=0,format=61,bpp=1;
    if(!strcmp(argv[1],"control"))control=1;
    else if(!strcmp(argv[1],"late-zero"))expected=1;
    else if(!strcmp(argv[1],"late-data")){expected=1;with_data=1;}
    else if(!strcmp(argv[1],"control-data")){control=1;with_data=1;}
    else if(!strcmp(argv[1],"bgra-late")){format=87;bpp=4;expected=1;}
    else if(!strcmp(argv[1],"bgra-control")){format=87;bpp=4;control=1;}
    else if(!strcmp(argv[1],"a8-fixed")){format=65;fixed=1;}
    else if(!strcmp(argv[1],"fixed"))fixed=1;
    else if(!strcmp(argv[1],"baseline")){corrupt=1;expected=3;}
    else if(!strcmp(argv[1],"event-timeout")){fail_query=1;expected=4;}
    else if(!strcmp(argv[1],"shared-error")){fail_shared=1;expected=4;}
    else if(!strcmp(argv[1],"unsupported")){unsupported=1;expected=2;}
    else assert(0);
    unsigned result=run_case(&da,&ca,&db,&cb,format,bpp,8,with_data,control,0);
    assert(result==expected && !live && !closes);
    if(result==0 || result==1)assert(queries==(control?5:4));
    printf("probe model: %s passed\n",argv[1]);return 0;
}
