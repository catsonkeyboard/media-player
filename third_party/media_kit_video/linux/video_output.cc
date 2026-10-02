// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#include "include/media_kit_video/video_output.h"
#include "include/media_kit_video/texture_gl.h"
#include "include/media_kit_video/texture_sw.h"

#include <epoxy/egl.h>
#include <epoxy/glx.h>
#include <gdk/gdkwayland.h>
#include <gdk/gdkx.h>

struct _VideoOutput {
  GObject parent_instance;
  TextureGL* texture_gl;
  EGLDisplay egl_display; /* EGL display for mpv rendering (shared with flutter). */
  EGLContext egl_context; /* Isolated EGL context (non-shared). */
  EGLSurface egl_surface; /* Place holder surface for activating egl context */
  guint8* pixel_buffers[3]; /* 三缓冲：写一帧、发布一帧、留一帧给上传 */
  gint pixel_buffer_write;
  gint pixel_buffer_read;
  TextureSW* texture_sw;
  GMutex mutex; /* Only used in S/W rendering. */
  mpv_handle* handle;
  mpv_render_context* render_context;
  gint64 width;
  gint64 height;
  VideoOutputConfiguration configuration;
  TextureUpdateCallback texture_update_callback;
  gpointer texture_update_callback_context;
  FlTextureRegistrar* texture_registrar;
  gboolean destroyed;
};

G_DEFINE_TYPE(VideoOutput, video_output, G_TYPE_OBJECT)

static gboolean g_engine_terminating = FALSE;

void video_output_set_engine_terminating(gboolean value) {
  g_engine_terminating = value;
}

// 供 runner（my_application.cc）在 delete-event 时同步置位：
// Dart 侧通道投递在引擎繁忙时会延迟数秒，来不及在播放器释放前生效。
extern "C" __attribute__((visibility("default"))) void
media_kit_video_set_engine_terminating(gboolean value) {
  g_engine_terminating = value;
}

static void video_output_dispose(GObject* object) {
  VideoOutput* self = VIDEO_OUTPUT(object);
  if (self->destroyed) {
    // 已清理过（GObject 允许 dispose 重入）：跳过，避免双重释放。
    G_OBJECT_CLASS(video_output_parent_class)->dispose(object);
    return;
  }
  self->destroyed = TRUE;

  // Make sure no more callbacks are invoked from mpv.
  if (self->render_context) {
    mpv_render_context_set_update_callback(self->render_context, NULL, NULL);
  }

  if (self->texture_gl) {
    fl_texture_registrar_unregister_texture(self->texture_registrar,
                                            FL_TEXTURE(self->texture_gl));

    // Save Flutter's current context before cleanup
    EGLDisplay current_display = eglGetCurrentDisplay();
    EGLContext flutter_context = eglGetCurrentContext();
    EGLSurface flutter_draw_surface = eglGetCurrentSurface(EGL_DRAW);
    EGLSurface flutter_read_surface = eglGetCurrentSurface(EGL_READ);

    // Free mpv_render_context with our own isolated EGL context
    if (self->render_context != NULL) {
      if (self->egl_context != EGL_NO_CONTEXT) {
        eglMakeCurrent(self->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                       self->egl_context);
      }
      mpv_render_context_free(self->render_context);
      self->render_context = NULL;

      // Restore Flutter's context
      if (flutter_context != EGL_NO_CONTEXT) {
        eglMakeCurrent(current_display, flutter_draw_surface,
                       flutter_read_surface, flutter_context);
      }
    }

    // EGL 资源（纹理/EGLImage/上下文）的销毁策略：
    // - 引擎即将终止（关窗退出）：故意保留，进程马上退出，立即销毁会与
    //   引擎关闭竞态触发 Mesa use-after-free 崩溃（4K 大纹理易复现）。
    // - 页面内正常切换：延迟 1s 到主循环，等引擎 raster 静默后再销毁。
    if (!g_engine_terminating) {
      TextureGL* texture_gl = self->texture_gl;
      EGLDisplay egl_display = self->egl_display;
      EGLContext egl_context = self->egl_context;
      self->texture_gl = NULL;
      self->egl_context = EGL_NO_CONTEXT;
      gpointer* deferred = g_new(gpointer, 4);
      deferred[0] = texture_gl;
      deferred[1] = (gpointer)egl_display;
      deferred[2] = (gpointer)egl_context;
      deferred[3] = g_object_ref(self);
      g_timeout_add(
          1000,
          [](gpointer data) -> gboolean {
            gpointer* deferred = (gpointer*)data;
            TextureGL* texture_gl = TEXTURE_GL(deferred[0]);
            EGLDisplay egl_display = (EGLDisplay)deferred[1];
            EGLContext egl_context = (EGLContext)deferred[2];
            VideoOutput* self = VIDEO_OUTPUT(deferred[3]);
            if (egl_context != EGL_NO_CONTEXT) {
              // texture_gl_dispose 从 VideoOutput 读取上下文来删除 GL 对象
              //（name 位于共享组，须显式删除，销毁上下文不会释放它）。
              video_output_set_egl_context(self, egl_display, egl_context);
              eglMakeCurrent(egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                             egl_context);
            }
            g_object_unref(texture_gl);
            if (egl_context != EGL_NO_CONTEXT) {
              eglMakeCurrent(egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                             EGL_NO_CONTEXT);
              eglDestroyContext(egl_display, egl_context);
              video_output_set_egl_context(self, EGL_NO_DISPLAY,
                                           EGL_NO_CONTEXT);
            }
            g_object_unref(self);
            g_free(deferred);
            return G_SOURCE_REMOVE;
          },
          deferred);
    }
  }
  if (self->texture_sw) {
    fl_texture_registrar_unregister_texture(self->texture_registrar,
                                            FL_TEXTURE(self->texture_sw));
    // 像素缓冲同样延迟释放：引擎上传可能仍在读取。
    guint8** buffers = g_new(guint8*, 3);
    for (int i = 0; i < 3; i++) {
      buffers[i] = self->pixel_buffers[i];
      self->pixel_buffers[i] = NULL;
    }
    g_object_unref(self->texture_sw);
    self->texture_sw = NULL;
    g_timeout_add(1000, [](gpointer data) -> gboolean {
      guint8** buffers = (guint8**)data;
      for (int i = 0; i < 3; i++) {
        g_free(buffers[i]);
      }
      g_free(buffers);
      return G_SOURCE_REMOVE;
    }, buffers);
    if (self->render_context != NULL) {
      mpv_render_context_free(self->render_context);
      self->render_context = NULL;
    }
  }

  g_mutex_clear(&self->mutex);
  G_OBJECT_CLASS(video_output_parent_class)->dispose(object);
}

static void video_output_class_init(VideoOutputClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = video_output_dispose;
}

static void video_output_init(VideoOutput* self) {
  self->texture_gl = NULL;
  self->egl_display = EGL_NO_DISPLAY;
  self->egl_context = EGL_NO_CONTEXT;
  self->egl_surface = EGL_NO_SURFACE;
  self->texture_sw = NULL;
  for (int i = 0; i < 3; i++) {
    self->pixel_buffers[i] = NULL;
  }
  self->pixel_buffer_write = 0;
  self->pixel_buffer_read = 0;
  self->handle = NULL;
  self->render_context = NULL;
  self->width = 0;
  self->height = 0;
  self->configuration = VideoOutputConfiguration{};
  self->texture_update_callback = NULL;
  self->texture_update_callback_context = NULL;
  self->texture_registrar = NULL;
  self->destroyed = FALSE;
  g_mutex_init(&self->mutex);
}

VideoOutput* video_output_new(FlTextureRegistrar* texture_registrar,
                              FlView* view,
                              gint64 handle,
                              VideoOutputConfiguration configuration) {
  VideoOutput* self = VIDEO_OUTPUT(g_object_new(video_output_get_type(), NULL));
  self->texture_registrar = texture_registrar;
  self->handle = (mpv_handle*)handle;
  self->width = configuration.width;
  self->height = configuration.height;
  self->configuration = configuration;
#ifndef MPV_RENDER_API_TYPE_SW
  // MPV_RENDER_API_TYPE_SW must be available for S/W rendering.
  if (!self->configuration.enable_hardware_acceleration) {
    g_printerr("media_kit: VideoOutput: S/W rendering is not supported.\n");
  }
  self->configuration.enable_hardware_acceleration = TRUE;
#endif
  mpv_set_option_string(self->handle, "video-sync", "audio");
  // Causes frame drops with `pulse` audio output. (SlotSun/dart_simple_live#42)
  // mpv_set_option_string(self->handle, "video-timing-offset", "0");
  gboolean hardware_acceleration_supported = FALSE;
  if (self->configuration.enable_hardware_acceleration) {
    // Flutter 3.38+ 将 EGL 上下文移到 raster 线程，平台线程上没有 current
    // context（media-kit#1404）。这里直接从 GDK 原生 display 获取 EGLDisplay，
    // 创建独立 GLES 上下文并在构造期建好 mpv 渲染上下文；帧数据经 EGLImage
    // 共享给 Flutter 的纹理（见 texture_gl.cc）。
    GdkDisplay* gdk_display = gdk_display_get_default();
    EGLDisplay egl_display = EGL_NO_DISPLAY;
    if (GDK_IS_WAYLAND_DISPLAY(gdk_display)) {
      egl_display = eglGetDisplay(
          (EGLNativeDisplayType)gdk_wayland_display_get_wl_display(gdk_display));
    } else if (GDK_IS_X11_DISPLAY(gdk_display)) {
      egl_display = eglGetDisplay(
          (EGLNativeDisplayType)gdk_x11_display_get_xdisplay(gdk_display));
    }
    if (egl_display == EGL_NO_DISPLAY || !eglInitialize(egl_display, NULL, NULL)) {
      g_printerr("media_kit: VideoOutput: Failed to open EGL display.\n");
    } else {
      self->egl_display = egl_display;
      eglBindAPI(EGL_OPENGL_ES_API);
      EGLConfig config = NULL;
      EGLint num_configs = 0;
      const EGLint config_attribs[] = {
          EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
          EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
          EGL_COLOR_BUFFER_TYPE, EGL_RGB_BUFFER,
          EGL_RED_SIZE, 8,
          EGL_GREEN_SIZE, 8,
          EGL_BLUE_SIZE, 8,
          EGL_ALPHA_SIZE, 8,
          EGL_NONE,
      };
      if (!eglChooseConfig(self->egl_display, config_attribs, &config, 1,
                           &num_configs) ||
          num_configs < 1) {
        g_printerr("media_kit: VideoOutput: No suitable EGL config.\n");
      } else {
        EGLint context_attribs[] = {
            EGL_CONTEXT_CLIENT_VERSION, 3,
            EGL_NONE,
        };
        self->egl_context = eglCreateContext(self->egl_display, config,
                                             EGL_NO_CONTEXT, context_attribs);
        if (self->egl_context == EGL_NO_CONTEXT) {
          g_printerr("media_kit: VideoOutput: Failed to create EGL context. Error: 0x%x\n",
                     eglGetError());
        } else if (eglMakeCurrent(self->egl_display, EGL_NO_SURFACE,
                                  EGL_NO_SURFACE, self->egl_context)) {
          self->texture_gl = texture_gl_new(self);
          if (!fl_texture_registrar_register_texture(
                  texture_registrar, FL_TEXTURE(self->texture_gl))) {
            g_printerr("media_kit: VideoOutput: Failed to register texture.\n");
          } else {
            mpv_opengl_init_params gl_init_params{
                [](auto, auto name) {
                  return (void*)eglGetProcAddress(name);
                },
                NULL,
            };
            mpv_render_param params[] = {
                {MPV_RENDER_PARAM_API_TYPE, (void*)MPV_RENDER_API_TYPE_OPENGL},
                {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, (void*)&gl_init_params},
                {MPV_RENDER_PARAM_INVALID, (void*)0},
                {MPV_RENDER_PARAM_INVALID, (void*)0},
            };
            // VAAPI acceleration requires passing X11/Wayland display
            if (GDK_IS_WAYLAND_DISPLAY(gdk_display)) {
              params[2].type = MPV_RENDER_PARAM_WL_DISPLAY;
              params[2].data = gdk_wayland_display_get_wl_display(gdk_display);
            } else if (GDK_IS_X11_DISPLAY(gdk_display)) {
              params[2].type = MPV_RENDER_PARAM_X11_DISPLAY;
              params[2].data = gdk_x11_display_get_xdisplay(gdk_display);
            }
            if (mpv_render_context_create(&self->render_context, self->handle,
                                          params) == 0) {
              mpv_render_context_set_update_callback(
                  self->render_context,
                  [](void* data) {
                    VideoOutput* self = (VideoOutput*)data;
                    if (self->destroyed) {
                      return;
                    }
                    fl_texture_registrar_mark_texture_frame_available(
                        self->texture_registrar, FL_TEXTURE(self->texture_gl));
                  },
                  self);
              hardware_acceleration_supported = TRUE;
              g_print("media_kit: VideoOutput: H/W rendering with isolated EGL context.\n");
            } else {
              g_printerr("media_kit: VideoOutput: Failed to create mpv_render_context.\n");
            }
          }
          eglMakeCurrent(self->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                         EGL_NO_CONTEXT);
        } else {
          g_printerr("media_kit: VideoOutput: Failed to make EGL context current. Error: 0x%x\n",
                     eglGetError());
          eglDestroyContext(self->egl_display, self->egl_context);
          self->egl_context = EGL_NO_CONTEXT;
        }
      }
    }
  }
#ifdef MPV_RENDER_API_TYPE_SW
  if (!hardware_acceleration_supported) {
    g_printerr("media_kit: VideoOutput: S/W rendering.\n");
    // H/W rendering failed. Fallback to S/W rendering.
    for (int i = 0; i < 3; i++) {
      self->pixel_buffers[i] = g_new0(guint8, SW_RENDERING_PIXEL_BUFFER_SIZE);
    }
    self->texture_gl = NULL;
    self->texture_sw = texture_sw_new(self);
    if (fl_texture_registrar_register_texture(texture_registrar,
                                              FL_TEXTURE(self->texture_sw))) {
      mpv_render_param params[] = {
          {MPV_RENDER_PARAM_API_TYPE, (void*)MPV_RENDER_API_TYPE_SW},
          {MPV_RENDER_PARAM_INVALID, (void*)0},
      };
      if (mpv_render_context_create(&self->render_context, self->handle,
                                    params) == 0) {
        mpv_render_context_set_update_callback(
            self->render_context,
            [](void* data) {
              gdk_threads_add_idle(
                  [](gpointer data) -> gboolean {
                    VideoOutput* self = (VideoOutput*)data;
                    if (self->destroyed) {
                      return FALSE;
                    }
                    gint64 width = video_output_get_width(self);
                    gint64 height = video_output_get_height(self);
                    if (width > 0 && height > 0) {
                      // 写入后台缓冲，完成后发布；上传方始终读最近完成的帧，
                      // 与写入错开两帧，避免撕裂（Flutter 上传无回执）。
                      guint8* target = self->pixel_buffers[self->pixel_buffer_write];
                      gint32 size[]{(gint32)width, (gint32)height};
                      gint32 pitch = 4 * (gint32)width;
                      mpv_render_param params[]{
                          {MPV_RENDER_PARAM_SW_SIZE, size},
                          {MPV_RENDER_PARAM_SW_FORMAT, (void*)"rgb0"},
                          {MPV_RENDER_PARAM_SW_STRIDE, &pitch},
                          {MPV_RENDER_PARAM_SW_POINTER, target},
                          {MPV_RENDER_PARAM_INVALID, (void*)0},
                      };
                      mpv_render_context_render(self->render_context, params);
                      g_mutex_lock(&self->mutex);
                      self->pixel_buffer_read = self->pixel_buffer_write;
                      self->pixel_buffer_write =
                          (self->pixel_buffer_write + 1) % 3;
                      g_mutex_unlock(&self->mutex);
                      fl_texture_registrar_mark_texture_frame_available(
                          self->texture_registrar,
                          FL_TEXTURE(self->texture_sw));
                    }
                    return FALSE;
                  },
                  data);
            },
            self);
      }
    }
  }
#endif
  return self;
}

void video_output_set_texture_update_callback(
    VideoOutput* self,
    TextureUpdateCallback texture_update_callback,
    gpointer texture_update_callback_context) {
  self->texture_update_callback = texture_update_callback;
  self->texture_update_callback_context = texture_update_callback_context;
  // Notify initial dimensions as (1, 1) if |width| & |height| are 0 i.e.
  // texture & video frame size is based on playing file's resolution. This
  // will make sure that `Texture` widget on Flutter's widget tree is actually
  // mounted & |fl_texture_registrar_mark_texture_frame_available| actually
  // invokes the |TextureGL| or |TextureSW| callbacks. Otherwise it will be a
  // never ending deadlock where no video frames are ever rendered.
  gint64 texture_id = video_output_get_texture_id(self);
  if (self->width == 0 || self->height == 0) {
    self->texture_update_callback(texture_id, 1, 1,
                                  self->texture_update_callback_context);
  } else {
    self->texture_update_callback(texture_id, self->width, self->height,
                                  self->texture_update_callback_context);
  }
}

void video_output_set_size(VideoOutput* self, gint64 width, gint64 height) {
  // Ideally, a mutex should be used here & |video_output_get_width| +
  // |video_output_get_height|. However, that is throwing everything into a
  // deadlock. Flutter itself seems to have some synchronization mechanism in
  // rendering & platform channels AFAIK.

  // H/W
  if (self->texture_gl) {
    self->width = width;
    self->height = height;
  }
  // S/W
  if (self->texture_sw) {
    self->width = CLAMP(width, 0, SW_RENDERING_MAX_WIDTH);
    self->height = CLAMP(height, 0, SW_RENDERING_MAX_HEIGHT);
  }
}

mpv_render_context* video_output_get_render_context(VideoOutput* self) {
  return self->render_context;
}

EGLDisplay video_output_get_egl_display(VideoOutput* self) {
  return self->egl_display;
}

EGLContext video_output_get_egl_context(VideoOutput* self) {
  return self->egl_context;
}

EGLSurface video_output_get_egl_surface(VideoOutput* self) {
  return self->egl_surface;
}

void video_output_set_egl_context(VideoOutput* self,
                                  EGLDisplay display,
                                  EGLContext context) {
  self->egl_display = display;
  self->egl_context = context;
}

void video_output_set_render_context(VideoOutput* self,
                                     mpv_render_context* render_context) {
  self->render_context = render_context;
}

mpv_handle* video_output_get_mpv_handle(VideoOutput* self) {
  return self->handle;
}

gboolean video_output_is_destroyed(VideoOutput* self) {
  return self->destroyed;
}

FlTextureRegistrar* video_output_get_texture_registrar(VideoOutput* self) {
  return self->texture_registrar;
}

guint8* video_output_get_pixel_buffer(VideoOutput* self) {
  // 返回最近一次完整渲染的缓冲；该缓冲在接下来两帧内不会被覆写。
  g_mutex_lock(&self->mutex);
  guint8* buffer = self->pixel_buffers[self->pixel_buffer_read];
  g_mutex_unlock(&self->mutex);
  return buffer;
}

gint64 video_output_get_width(VideoOutput* self) {
  // Fixed width.
  if (self->width) {
    return self->width;
  }

  // Video resolution dependent width.
  gint64 width = 0;
  gint64 height = 0;

  mpv_node params;
  mpv_get_property(self->handle, "video-out-params", MPV_FORMAT_NODE, &params);

  int64_t dw = 0, dh = 0, rotate = 0;
  if (params.format == MPV_FORMAT_NODE_MAP) {
    for (int32_t i = 0; i < params.u.list->num; i++) {
      char* key = params.u.list->keys[i];
      auto value = params.u.list->values[i];
      if (value.format == MPV_FORMAT_INT64) {
        if (strcmp(key, "dw") == 0) {
          dw = value.u.int64;
        }
        if (strcmp(key, "dh") == 0) {
          dh = value.u.int64;
        }
        if (strcmp(key, "rotate") == 0) {
          rotate = value.u.int64;
        }
      }
    }
    mpv_free_node_contents(&params);
  }

  width = rotate == 0 || rotate == 180 ? dw : dh;
  height = rotate == 0 || rotate == 180 ? dh : dw;

  if (self->texture_sw != NULL) {
    // Make sure |width| & |height| fit between |SW_RENDERING_MAX_WIDTH| &
    // |SW_RENDERING_MAX_HEIGHT| while maintaining aspect ratio.
    if (width >= SW_RENDERING_MAX_WIDTH) {
      return SW_RENDERING_MAX_WIDTH;
    }
    if (height >= SW_RENDERING_MAX_HEIGHT) {
      return width / height * SW_RENDERING_MAX_HEIGHT;
    }
  }

  return width;
}

gint64 video_output_get_height(VideoOutput* self) {
  // Fixed height.
  if (self->width) {
    return self->height;
  }

  // Video resolution dependent height.
  gint64 width = 0;
  gint64 height = 0;

  mpv_node params;
  mpv_get_property(self->handle, "video-out-params", MPV_FORMAT_NODE, &params);

  int64_t dw = 0, dh = 0, rotate = 0;
  if (params.format == MPV_FORMAT_NODE_MAP) {
    for (int32_t i = 0; i < params.u.list->num; i++) {
      char* key = params.u.list->keys[i];
      auto value = params.u.list->values[i];
      if (value.format == MPV_FORMAT_INT64) {
        if (strcmp(key, "dw") == 0) {
          dw = value.u.int64;
        }
        if (strcmp(key, "dh") == 0) {
          dh = value.u.int64;
        }
        if (strcmp(key, "rotate") == 0) {
          rotate = value.u.int64;
        }
      }
    }
    mpv_free_node_contents(&params);
  }

  width = rotate == 0 || rotate == 180 ? dw : dh;
  height = rotate == 0 || rotate == 180 ? dh : dw;

  if (self->texture_sw != NULL) {
    // Make sure |width| & |height| fit between |SW_RENDERING_MAX_WIDTH| &
    // |SW_RENDERING_MAX_HEIGHT| while maintaining aspect ratio.
    if (height >= SW_RENDERING_MAX_HEIGHT) {
      return SW_RENDERING_MAX_HEIGHT;
    }
    if (width >= SW_RENDERING_MAX_WIDTH) {
      return height / width * SW_RENDERING_MAX_WIDTH;
    }
  }

  return height;
}

gint64 video_output_get_texture_id(VideoOutput* self) {
  // H/W
  if (self->texture_gl) {
    return (gint64)self->texture_gl;
  }
  // S/W
  if (self->texture_sw) {
    return (gint64)self->texture_sw;
  }
  g_assert_not_reached();
  return -1;
}

void video_output_notify_texture_update(VideoOutput* self) {
  gint64 id = video_output_get_texture_id(self);
  gint64 width = video_output_get_width(self);
  gint64 height = video_output_get_height(self);
  gpointer context = self->texture_update_callback_context;
  if (self->texture_update_callback != NULL) {
    self->texture_update_callback(id, width, height, context);
  }
}
