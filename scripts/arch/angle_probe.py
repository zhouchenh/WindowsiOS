#!/usr/bin/env python3
# Can Chrome's own ANGLE (libEGL/libGLESv2 in /opt/google/chrome) make an OpenGL ES context here, and
# which? Tries each ANGLE back end, headless (device/surfaceless display, a pbuffer), ES 3.0 then 2.0.
#   python3 angle_probe.py [vulkan|gl|gles|swiftshader ...]
import ctypes, sys

D = '/opt/google/chrome/'
egl = ctypes.CDLL(D + 'libEGL.so', mode=ctypes.RTLD_GLOBAL)
gles = ctypes.CDLL(D + 'libGLESv2.so', mode=ctypes.RTLD_GLOBAL)

EGL_PLATFORM_ANGLE_ANGLE = 0x3202
EGL_PLATFORM_ANGLE_TYPE_ANGLE = 0x3203
TYPES = {'gl': 0x320D, 'gles': 0x320E, 'vulkan': 0x3450, 'swiftshader': 0x3450}
EGL_PLATFORM_ANGLE_DEVICE_TYPE_ANGLE = 0x3209
EGL_PLATFORM_ANGLE_DEVICE_TYPE_SWIFTSHADER_ANGLE = 0x3487
EGL_NONE, EGL_TRUE = 0x3038, 1
EGL_VENDOR, EGL_VERSION, EGL_EXTENSIONS = 0x3053, 0x3054, 0x3055
EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE = 0x3033, 0x0001, 0x3040
EGL_OPENGL_ES2_BIT, EGL_OPENGL_ES3_BIT = 0x0004, 0x0040
EGL_RED_SIZE, EGL_GREEN_SIZE, EGL_BLUE_SIZE = 0x3024, 0x3023, 0x3022
EGL_WIDTH, EGL_HEIGHT = 0x3057, 0x3056
EGL_CONTEXT_MAJOR_VERSION, EGL_CONTEXT_MINOR_VERSION = 0x3098, 0x30FB
EGL_OPENGL_ES_API = 0x30A0
GL_VENDOR, GL_RENDERER, GL_VERSION = 0x1F00, 0x1F01, 0x1F02

egl.eglGetPlatformDisplayEXT.restype = ctypes.c_void_p
egl.eglGetPlatformDisplayEXT.argtypes = [ctypes.c_uint, ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
egl.eglInitialize.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int)]
egl.eglQueryString.restype = ctypes.c_char_p
egl.eglQueryString.argtypes = [ctypes.c_void_p, ctypes.c_int]
egl.eglChooseConfig.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_void_p),
                                ctypes.c_int, ctypes.POINTER(ctypes.c_int)]
egl.eglCreatePbufferSurface.restype = ctypes.c_void_p
egl.eglCreatePbufferSurface.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
egl.eglCreateContext.restype = ctypes.c_void_p
egl.eglCreateContext.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
egl.eglMakeCurrent.argtypes = [ctypes.c_void_p] * 4
egl.eglTerminate.argtypes = [ctypes.c_void_p]
gles.glGetString.restype = ctypes.c_char_p
gles.glGetString.argtypes = [ctypes.c_uint]


def arr(*v):
    return (ctypes.c_int * len(v))(*v)


def probe(name):
    print(f'== ANGLE {name}')
    a = [EGL_PLATFORM_ANGLE_TYPE_ANGLE, TYPES[name]]
    if name == 'swiftshader':
        a += [EGL_PLATFORM_ANGLE_DEVICE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_DEVICE_TYPE_SWIFTSHADER_ANGLE]
    dpy = egl.eglGetPlatformDisplayEXT(EGL_PLATFORM_ANGLE_ANGLE, None, arr(*a, EGL_NONE))
    ma, mi = ctypes.c_int(), ctypes.c_int()
    if not dpy or not egl.eglInitialize(dpy, ctypes.byref(ma), ctypes.byref(mi)):
        print(f'   eglInitialize failed: {egl.eglGetError():#x}')
        return
    print('   EGL', egl.eglQueryString(dpy, EGL_VERSION).decode())
    for major, bit in ((3, EGL_OPENGL_ES3_BIT), (2, EGL_OPENGL_ES2_BIT)):
        cfg, n = ctypes.c_void_p(), ctypes.c_int()
        egl.eglChooseConfig(dpy, arr(EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, bit, EGL_RED_SIZE, 8,
                                     EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_NONE), ctypes.byref(cfg), 1, ctypes.byref(n))
        if n.value < 1:
            print(f'   ES{major}: no config')
            continue
        surf = egl.eglCreatePbufferSurface(dpy, cfg, arr(EGL_WIDTH, 64, EGL_HEIGHT, 64, EGL_NONE))
        egl.eglBindAPI(EGL_OPENGL_ES_API)
        ctx = egl.eglCreateContext(dpy, cfg, None, arr(EGL_CONTEXT_MAJOR_VERSION, major, EGL_NONE))
        if not ctx:
            print(f'   ES{major}: eglCreateContext failed {egl.eglGetError():#x}')
            continue
        egl.eglMakeCurrent(dpy, surf, surf, ctx)
        print(f'   ES{major}: OK  {gles.glGetString(GL_VERSION).decode()}  |  {gles.glGetString(GL_RENDERER).decode()}')
        break
    egl.eglTerminate(dpy)


for n in sys.argv[1:] or ['vulkan', 'gles', 'gl', 'swiftshader']:
    try:
        probe(n)
    except Exception as e:
        print('   error', e)
