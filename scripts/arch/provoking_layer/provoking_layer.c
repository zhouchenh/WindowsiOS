/* VK_LAYER_WINIOS_provoking_vertex: tells Vulkan programs the device has VK_EXT_provoking_vertex with
 * "last vertex" mode, which the iPad's Vulkan (Venus over MoltenVK, i.e. Metal) does not offer, and
 * keeps the extension and its structures away from the real driver.
 *
 * Why: ANGLE (Chrome's OpenGL ES on Vulkan) gives no OpenGL ES 3.0 without it, and Chrome needs 3.0,
 * so Chrome had no GPU acceleration at all. The price: flat-shaded values come from the first vertex of a
 * primitive instead of the last. Chrome's own drawing (Skia) feeds flat values from per-instance data,
 * the same for every vertex, so it does not notice; a WebGL page that relies on the last vertex would
 * see different colours.
 *
 * An implicit layer enabled only by WINIOS_FAKE_PROVOKING_VERTEX=1 (the Chrome launcher sets it).
 * Build: gcc -shared -fPIC -O2 -o libVkLayer_winios_provoking.so provoking_layer.c */
#include <stdlib.h>
#include <string.h>
#include <vulkan/vk_layer.h>
#include <vulkan/vulkan.h>

#define EXPORT __attribute__((visibility("default")))

typedef struct Inst {
    VkInstance inst;
    PFN_vkGetInstanceProcAddr gipa;
    PFN_vkEnumerateDeviceExtensionProperties enum_ext;
    PFN_vkGetPhysicalDeviceFeatures2 feat2, feat2khr;
    PFN_vkGetPhysicalDeviceProperties2 prop2, prop2khr;
    PFN_vkDestroyInstance destroy;
    struct Inst *next;
} Inst;

typedef struct Dev {
    VkDevice dev;
    PFN_vkGetDeviceProcAddr gdpa;
    PFN_vkCreateGraphicsPipelines create_gp;
    PFN_vkDestroyDevice destroy;
    struct Dev *next;
} Dev;

static Inst *insts;
static Dev *devs;
static Inst *last_inst; /* physical devices map to their instance by the loader's dispatch key */

static void *key(const void *h) { return *(void **)h; }

static Inst *inst_of(const void *h) {
    for (Inst *i = insts; i; i = i->next)
        if (key(i->inst) == key(h)) return i;
    return last_inst;
}

static Dev *dev_of(VkDevice d) {
    for (Dev *x = devs; x; x = x->next)
        if (key(x->dev) == key(d)) return x;
    return NULL;
}

static VkResult VKAPI_CALL l_CreateInstance(const VkInstanceCreateInfo *ci, const VkAllocationCallbacks *a,
                                            VkInstance *out) {
    VkLayerInstanceCreateInfo *lci = (VkLayerInstanceCreateInfo *)ci->pNext;
    while (lci && !(lci->sType == VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO && lci->function == VK_LAYER_LINK_INFO))
        lci = (VkLayerInstanceCreateInfo *)lci->pNext;
    if (!lci) return VK_ERROR_INITIALIZATION_FAILED;
    PFN_vkGetInstanceProcAddr gipa = lci->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    lci->u.pLayerInfo = lci->u.pLayerInfo->pNext;
    PFN_vkCreateInstance create = (PFN_vkCreateInstance)gipa(VK_NULL_HANDLE, "vkCreateInstance");
    VkResult r = create(ci, a, out);
    if (r != VK_SUCCESS) return r;
    Inst *i = calloc(1, sizeof *i);
    i->inst = *out;
    i->gipa = gipa;
    i->enum_ext = (PFN_vkEnumerateDeviceExtensionProperties)gipa(*out, "vkEnumerateDeviceExtensionProperties");
    i->feat2 = (PFN_vkGetPhysicalDeviceFeatures2)gipa(*out, "vkGetPhysicalDeviceFeatures2");
    i->feat2khr = (PFN_vkGetPhysicalDeviceFeatures2)gipa(*out, "vkGetPhysicalDeviceFeatures2KHR");
    i->prop2 = (PFN_vkGetPhysicalDeviceProperties2)gipa(*out, "vkGetPhysicalDeviceProperties2");
    i->prop2khr = (PFN_vkGetPhysicalDeviceProperties2)gipa(*out, "vkGetPhysicalDeviceProperties2KHR");
    i->destroy = (PFN_vkDestroyInstance)gipa(*out, "vkDestroyInstance");
    i->next = insts;
    insts = i;
    last_inst = i;
    return VK_SUCCESS;
}

static void VKAPI_CALL l_DestroyInstance(VkInstance inst, const VkAllocationCallbacks *a) {
    for (Inst **p = &insts; *p; p = &(*p)->next)
        if ((*p)->inst == inst) {
            Inst *i = *p;
            *p = i->next;
            if (last_inst == i) last_inst = insts;
            i->destroy(inst, a);
            free(i);
            return;
        }
}

static VkResult VKAPI_CALL l_EnumerateDeviceExtensionProperties(VkPhysicalDevice pd, const char *layer,
                                                                uint32_t *count, VkExtensionProperties *props) {
    if (layer && !strcmp(layer, "VK_LAYER_WINIOS_provoking_vertex")) {
        if (!props) *count = 0;
        return VK_SUCCESS;
    }
    Inst *i = inst_of(pd);
    uint32_t n = 0;
    VkResult r = i->enum_ext(pd, layer, &n, NULL);
    if (r != VK_SUCCESS) return r;
    VkExtensionProperties *all = calloc(n + 1, sizeof *all);
    i->enum_ext(pd, layer, &n, all);
    int have = 0;
    for (uint32_t k = 0; k < n; k++)
        if (!strcmp(all[k].extensionName, VK_EXT_PROVOKING_VERTEX_EXTENSION_NAME)) have = 1;
    if (!have && !layer) {
        strcpy(all[n].extensionName, VK_EXT_PROVOKING_VERTEX_EXTENSION_NAME);
        all[n].specVersion = VK_EXT_PROVOKING_VERTEX_SPEC_VERSION;
        n++;
    }
    if (!props) {
        *count = n;
    } else {
        uint32_t c = *count < n ? *count : n;
        memcpy(props, all, c * sizeof *all);
        r = c < n ? VK_INCOMPLETE : VK_SUCCESS;
        *count = c;
    }
    free(all);
    return r;
}

static void fix_features(VkPhysicalDeviceFeatures2 *f) {
    for (VkBaseOutStructure *s = (VkBaseOutStructure *)f->pNext; s; s = s->pNext)
        if (s->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROVOKING_VERTEX_FEATURES_EXT) {
            VkPhysicalDeviceProvokingVertexFeaturesEXT *p = (void *)s;
            p->provokingVertexLast = VK_TRUE;
            p->transformFeedbackPreservesProvokingVertex = VK_FALSE;
        }
}

static void VKAPI_CALL l_GetPhysicalDeviceFeatures2(VkPhysicalDevice pd, VkPhysicalDeviceFeatures2 *f) {
    Inst *i = inst_of(pd);
    (i->feat2 ? i->feat2 : i->feat2khr)(pd, f);
    fix_features(f);
}

static void VKAPI_CALL l_GetPhysicalDeviceFeatures2KHR(VkPhysicalDevice pd, VkPhysicalDeviceFeatures2 *f) {
    Inst *i = inst_of(pd);
    (i->feat2khr ? i->feat2khr : i->feat2)(pd, f);
    fix_features(f);
}

static void fix_props(VkPhysicalDeviceProperties2 *p) {
    for (VkBaseOutStructure *s = (VkBaseOutStructure *)p->pNext; s; s = s->pNext)
        if (s->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROVOKING_VERTEX_PROPERTIES_EXT) {
            VkPhysicalDeviceProvokingVertexPropertiesEXT *q = (void *)s;
            q->provokingVertexModePerPipeline = VK_TRUE;
            q->transformFeedbackPreservesTriangleFanProvokingVertex = VK_FALSE;
        }
}

static void VKAPI_CALL l_GetPhysicalDeviceProperties2(VkPhysicalDevice pd, VkPhysicalDeviceProperties2 *p) {
    Inst *i = inst_of(pd);
    (i->prop2 ? i->prop2 : i->prop2khr)(pd, p);
    fix_props(p);
}

static void VKAPI_CALL l_GetPhysicalDeviceProperties2KHR(VkPhysicalDevice pd, VkPhysicalDeviceProperties2 *p) {
    Inst *i = inst_of(pd);
    (i->prop2khr ? i->prop2khr : i->prop2)(pd, p);
    fix_props(p);
}

typedef struct Patch {
    VkBaseInStructure *at;
    const VkBaseInStructure *was;
} Patch;

/* Remove structs of these types from a chain in place, remembering how to put them back. */
static int unlink_types(const void **head, VkStructureType t1, VkStructureType t2, Patch *patches, int cap,
                        const void **old_head) {
    int n = 0;
    *old_head = *head;
    while (*head && (((const VkBaseInStructure *)*head)->sType == t1 || ((const VkBaseInStructure *)*head)->sType == t2))
        *head = ((const VkBaseInStructure *)*head)->pNext;
    for (VkBaseInStructure *s = (VkBaseInStructure *)*head; s && n < cap;) {
        const VkBaseInStructure *nx = s->pNext;
        if (nx && (nx->sType == t1 || nx->sType == t2)) {
            patches[n].at = s;
            patches[n].was = nx;
            n++;
            s->pNext = nx->pNext;
            continue;
        }
        s = (VkBaseInStructure *)nx;
    }
    return n;
}

static void relink(Patch *patches, int n) {
    while (n--) patches[n].at->pNext = patches[n].was;
}

static VkResult VKAPI_CALL l_CreateDevice(VkPhysicalDevice pd, const VkDeviceCreateInfo *ci,
                                          const VkAllocationCallbacks *a, VkDevice *out) {
    VkLayerDeviceCreateInfo *lci = (VkLayerDeviceCreateInfo *)ci->pNext;
    while (lci && !(lci->sType == VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO && lci->function == VK_LAYER_LINK_INFO))
        lci = (VkLayerDeviceCreateInfo *)lci->pNext;
    if (!lci) return VK_ERROR_INITIALIZATION_FAILED;
    PFN_vkGetInstanceProcAddr gipa = lci->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    PFN_vkGetDeviceProcAddr gdpa = lci->u.pLayerInfo->pfnNextGetDeviceProcAddr;
    lci->u.pLayerInfo = lci->u.pLayerInfo->pNext;
    Inst *in = inst_of(pd);
    PFN_vkCreateDevice create = (PFN_vkCreateDevice)gipa(in->inst, "vkCreateDevice");

    /* the extension and its feature struct never reach the driver */
    VkDeviceCreateInfo c = *ci;
    const char **names = calloc(ci->enabledExtensionCount + 1, sizeof *names);
    uint32_t n = 0;
    for (uint32_t k = 0; k < ci->enabledExtensionCount; k++)
        if (strcmp(ci->ppEnabledExtensionNames[k], VK_EXT_PROVOKING_VERTEX_EXTENSION_NAME))
            names[n++] = ci->ppEnabledExtensionNames[k];
    c.enabledExtensionCount = n;
    c.ppEnabledExtensionNames = names;
    Patch patches[8];
    const void *old;
    int np = unlink_types(&c.pNext, VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROVOKING_VERTEX_FEATURES_EXT,
                          VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROVOKING_VERTEX_FEATURES_EXT, patches, 8, &old);
    VkResult r = create(pd, &c, a, out);
    relink(patches, np);
    free(names);
    if (r != VK_SUCCESS) return r;
    Dev *d = calloc(1, sizeof *d);
    d->dev = *out;
    d->gdpa = gdpa;
    d->create_gp = (PFN_vkCreateGraphicsPipelines)gdpa(*out, "vkCreateGraphicsPipelines");
    d->destroy = (PFN_vkDestroyDevice)gdpa(*out, "vkDestroyDevice");
    d->next = devs;
    devs = d;
    return VK_SUCCESS;
}

static void VKAPI_CALL l_DestroyDevice(VkDevice dev, const VkAllocationCallbacks *a) {
    for (Dev **p = &devs; *p; p = &(*p)->next)
        if ((*p)->dev == dev) {
            Dev *d = *p;
            *p = d->next;
            d->destroy(dev, a);
            free(d);
            return;
        }
}

static VkResult VKAPI_CALL l_CreateGraphicsPipelines(VkDevice dev, VkPipelineCache cache, uint32_t count,
                                                     const VkGraphicsPipelineCreateInfo *cis,
                                                     const VkAllocationCallbacks *a, VkPipeline *out) {
    Dev *d = dev_of(dev);
    enum { MAXP = 64 };
    Patch patches[MAXP];
    const void *olds[MAXP];
    VkPipelineRasterizationStateCreateInfo *rs[MAXP];
    int np = 0, nr = 0;
    for (uint32_t k = 0; k < count && nr < MAXP; k++) {
        VkPipelineRasterizationStateCreateInfo *r = (VkPipelineRasterizationStateCreateInfo *)cis[k].pRasterizationState;
        if (!r) continue;
        rs[nr] = r;
        np += unlink_types(&r->pNext, VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_PROVOKING_VERTEX_STATE_CREATE_INFO_EXT,
                           VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_PROVOKING_VERTEX_STATE_CREATE_INFO_EXT,
                           patches + np, MAXP - np, &olds[nr]);
        nr++;
    }
    VkResult res = d->create_gp(dev, cache, count, cis, a, out);
    relink(patches, np);
    for (int k = 0; k < nr; k++) rs[k]->pNext = olds[k];
    return res;
}

static PFN_vkVoidFunction VKAPI_CALL l_GetDeviceProcAddr(VkDevice dev, const char *name);

static PFN_vkVoidFunction own(const char *name) {
#define F(n) if (!strcmp(name, "vk" #n)) return (PFN_vkVoidFunction)l_##n;
    F(CreateInstance) F(DestroyInstance) F(EnumerateDeviceExtensionProperties) F(GetPhysicalDeviceFeatures2)
    F(GetPhysicalDeviceFeatures2KHR) F(GetPhysicalDeviceProperties2) F(GetPhysicalDeviceProperties2KHR)
    F(CreateDevice) F(DestroyDevice) F(CreateGraphicsPipelines) F(GetDeviceProcAddr)
#undef F
    return NULL;
}

EXPORT PFN_vkVoidFunction VKAPI_CALL l_GetInstanceProcAddr(VkInstance inst, const char *name);

static PFN_vkVoidFunction VKAPI_CALL l_GetDeviceProcAddr(VkDevice dev, const char *name) {
    if (!strcmp(name, "vkGetDeviceProcAddr")) return (PFN_vkVoidFunction)l_GetDeviceProcAddr;
    if (!strcmp(name, "vkDestroyDevice")) return (PFN_vkVoidFunction)l_DestroyDevice;
    if (!strcmp(name, "vkCreateGraphicsPipelines")) return (PFN_vkVoidFunction)l_CreateGraphicsPipelines;
    Dev *d = dev_of(dev);
    return d ? d->gdpa(dev, name) : NULL;
}

EXPORT PFN_vkVoidFunction VKAPI_CALL l_GetInstanceProcAddr(VkInstance inst, const char *name) {
    if (!strcmp(name, "vkGetInstanceProcAddr")) return (PFN_vkVoidFunction)l_GetInstanceProcAddr;
    PFN_vkVoidFunction f = own(name);
    if (f) return f;
    if (!inst) return NULL;
    Inst *i = inst_of(inst);
    return i ? i->gipa(inst, name) : NULL;
}

EXPORT VkResult VKAPI_CALL vkNegotiateLoaderLayerInterfaceVersion(VkNegotiateLayerInterface *v) {
    if (v->loaderLayerInterfaceVersion > 2) v->loaderLayerInterfaceVersion = 2;
    v->pfnGetInstanceProcAddr = l_GetInstanceProcAddr;
    v->pfnGetDeviceProcAddr = l_GetDeviceProcAddr;
    v->pfnGetPhysicalDeviceProcAddr = NULL;
    return VK_SUCCESS;
}
