// SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
// SPDX-License-Identifier: MIT
//
// Eclipse eCAL's C API as Lean external objects. Lean decides; this file calls eCAL and moves
// bytes.
//
// Writing: eCAL_Publisher_SendPayloadWriter calls back on the sending thread with a pointer into
// the shared memory file, so a Lean closure writes the message there directly.
//
// Reading: eCAL calls the receive callback on its own thread with a pointer into the memory file.
// That thread hands the pointer to the Lean thread and waits until Lean releases it, so Lean
// reads in place and eCAL never runs Lean code on a thread Lean did not start. The view is
// cleared on release so it cannot be read after eCAL reuses the memory.
#include <lean/lean.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <ecal_c/ecal.h>

static void noop_foreach(void *p, b_lean_obj_arg f) { (void)p; (void)f; }
static lean_obj_res user_err(const char *msg) {
	return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(msg)));
}

// ---- process ---------------------------------------------------------------------------------
// shm_registration = 1 finds peers through a shared-memory registration queue instead of eCAL's
// default UDP broadcast on port 14000.
LEAN_EXPORT lean_obj_res el_initialize(b_lean_obj_arg unit, uint8_t shm_registration, lean_obj_arg w) {
	(void)w;
	unsigned int components = eCAL_Init_Publisher | eCAL_Init_Subscriber;
	eCAL_Configuration *cfg = eCAL_Init_Configuration();
	if (shm_registration) cfg->registration.local.transport_type = eCAL_Registration_Local_eTransportType_shm;
	int r = eCAL_Initialize(lean_string_cstr(unit), &components, cfg);
	eCAL_Configuration_Delete(cfg);
	if (r < 0) return user_err("ecal: initialize failed");
	return lean_io_result_mk_ok(lean_box(0));
}
LEAN_EXPORT lean_obj_res el_finalize(lean_obj_arg w) {
	(void)w;
	eCAL_Finalize();
	return lean_io_result_mk_ok(lean_box(0));
}
LEAN_EXPORT lean_obj_res el_version(lean_obj_arg w) {
	(void)w;
	return lean_io_result_mk_ok(lean_mk_string(eCAL_GetVersionString()));
}

// ---- views: a byte range of a memory file, valid while its owner says so ---------------------
typedef struct { uint8_t *p; uint64_t n; int writable; } lean_view;
static void view_finalize(void *p) { free(p); }
static lean_external_class *g_view = NULL;
static lean_view *VIEW(b_lean_obj_arg o) { return lean_get_external_data(o); }
static lean_object *view_new(uint8_t *p, uint64_t n, int writable) {
	if (!g_view) g_view = lean_register_external_class(view_finalize, noop_foreach);
	lean_view *v = malloc(sizeof *v);
	v->p = p; v->n = n; v->writable = writable;
	return lean_alloc_external(g_view, v);
}
static lean_obj_res view_err(void) { return user_err("ecal: view used after release, out of range, or not writable"); }
static int view_ok(lean_view *v, uint64_t off, uint64_t n) { return v->p && off <= v->n && n <= v->n - off; }

LEAN_EXPORT uint64_t el_view_size(b_lean_obj_arg o) { return VIEW(o)->n; }
LEAN_EXPORT lean_obj_res el_view_u64(b_lean_obj_arg o, uint64_t off, lean_obj_arg w) {
	(void)w; lean_view *v = VIEW(o); uint64_t x = 0;
	if (!view_ok(v, off, 8)) return view_err();
	memcpy(&x, v->p + off, 8);
	return lean_io_result_mk_ok(lean_box_uint64(x));
}
LEAN_EXPORT lean_obj_res el_view_set_u64(b_lean_obj_arg o, uint64_t off, uint64_t x, lean_obj_arg w) {
	(void)w; lean_view *v = VIEW(o);
	if (!v->writable || !view_ok(v, off, 8)) return view_err();
	memcpy(v->p + off, &x, 8);
	return lean_io_result_mk_ok(lean_box(0));
}
LEAN_EXPORT lean_obj_res el_view_read(b_lean_obj_arg o, uint64_t off, uint64_t n, lean_obj_arg w) {
	(void)w; lean_view *v = VIEW(o);
	if (!view_ok(v, off, n)) return view_err();
	lean_object *a = lean_alloc_sarray(1, n, n);
	memcpy(lean_sarray_cptr(a), v->p + off, n);
	return lean_io_result_mk_ok(a);
}
LEAN_EXPORT lean_obj_res el_view_write(b_lean_obj_arg o, uint64_t off, b_lean_obj_arg bytes, lean_obj_arg w) {
	(void)w; lean_view *v = VIEW(o); size_t n = lean_sarray_size(bytes);
	if (!v->writable || !view_ok(v, off, n)) return view_err();
	memcpy(v->p + off, lean_sarray_cptr(bytes), n);
	return lean_io_result_mk_ok(lean_box(0));
}
LEAN_EXPORT lean_obj_res el_view_fill(b_lean_obj_arg o, uint64_t off, uint64_t n, uint64_t seed, lean_obj_arg w) {
	(void)w; lean_view *v = VIEW(o);
	if (!v->writable || !view_ok(v, off, n)) return view_err();
	uint64_t x = seed | 1;
	for (uint64_t i = 0; i < n; i++) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; v->p[off + i] = (uint8_t)x; }
	return lean_io_result_mk_ok(lean_box(0));
}
LEAN_EXPORT lean_obj_res el_view_fnv(b_lean_obj_arg o, uint64_t off, uint64_t n, lean_obj_arg w) {
	(void)w; lean_view *v = VIEW(o);
	if (!view_ok(v, off, n)) return view_err();
	uint64_t x = 1469598103934665603ull;
	for (uint64_t i = 0; i < n; i++) { x ^= v->p[off + i]; x *= 1099511628211ull; }
	return lean_io_result_mk_ok(lean_box_uint64(x));
}

// ---- host buffers: frames being sent or assembled --------------------------------------------
typedef struct { uint8_t *p; uint64_t n; } lean_buf;
static void buf_finalize(void *p) { lean_buf *b = p; free(b->p); free(b); }
static lean_external_class *g_buf = NULL;
static lean_buf *BUF(b_lean_obj_arg o) { return lean_get_external_data(o); }
LEAN_EXPORT lean_obj_res el_buf_new(uint64_t n, uint64_t seed, lean_obj_arg w) {
	(void)w;
	if (!g_buf) g_buf = lean_register_external_class(buf_finalize, noop_foreach);
	lean_buf *b = calloc(1, sizeof *b);
	b->p = malloc(n ? n : 1); b->n = n;
	uint64_t x = seed | 1;
	for (uint64_t i = 0; i < n; i++) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; b->p[i] = (uint8_t)x; }
	return lean_io_result_mk_ok(lean_alloc_external(g_buf, b));
}
LEAN_EXPORT lean_obj_res el_buf_set_u64(b_lean_obj_arg o, uint64_t off, uint64_t x, lean_obj_arg w) {
	(void)w; lean_buf *b = BUF(o);
	if (off > b->n || b->n - off < 8) return view_err();
	memcpy(b->p + off, &x, 8);
	return lean_io_result_mk_ok(lean_box(0));
}
LEAN_EXPORT lean_obj_res el_buf_u64(b_lean_obj_arg o, uint64_t off, lean_obj_arg w) {
	(void)w; lean_buf *b = BUF(o); uint64_t x = 0;
	if (off > b->n || b->n - off < 8) return view_err();
	memcpy(&x, b->p + off, 8);
	return lean_io_result_mk_ok(lean_box_uint64(x));
}
LEAN_EXPORT lean_obj_res el_buf_fnv(b_lean_obj_arg o, lean_obj_arg w) {
	(void)w; lean_buf *b = BUF(o);
	uint64_t x = 1469598103934665603ull;
	for (uint64_t i = 0; i < b->n; i++) { x ^= b->p[i]; x *= 1099511628211ull; }
	return lean_io_result_mk_ok(lean_box_uint64(x));
}
LEAN_EXPORT lean_obj_res el_view_copy_from(b_lean_obj_arg o, uint64_t off, b_lean_obj_arg bo, uint64_t boff, uint64_t n, lean_obj_arg w) {
	(void)w; lean_view *v = VIEW(o); lean_buf *b = BUF(bo);
	if (!v->writable || !view_ok(v, off, n) || boff > b->n || b->n - boff < n) return view_err();
	memcpy(v->p + off, b->p + boff, n);
	return lean_io_result_mk_ok(lean_box(0));
}
LEAN_EXPORT lean_obj_res el_view_copy_to(b_lean_obj_arg o, uint64_t off, uint64_t n, b_lean_obj_arg bo, uint64_t boff, lean_obj_arg w) {
	(void)w; lean_view *v = VIEW(o); lean_buf *b = BUF(bo);
	if (!view_ok(v, off, n) || boff > b->n || b->n - boff < n) return view_err();
	memcpy(b->p + boff, v->p + off, n);
	return lean_io_result_mk_ok(lean_box(0));
}

// ---- publisher -------------------------------------------------------------------------------
static lean_external_class *g_pub = NULL;
static void pub_finalize(void *p) { if (p) eCAL_Publisher_Delete(p); }

LEAN_EXPORT lean_obj_res el_pub_new(b_lean_obj_arg topic, uint8_t zero_copy, uint32_t ack_ms, uint32_t buffers, lean_obj_arg w) {
	(void)w;
	if (!g_pub) g_pub = lean_register_external_class(pub_finalize, noop_foreach);
	struct eCAL_Publisher_Configuration cfg = *eCAL_GetPublisherConfiguration();
	cfg.layer.shm.enable = 1;
	cfg.layer.shm.zero_copy_mode = zero_copy;
	cfg.layer.shm.acknowledge_timeout_ms = ack_ms;
	if (buffers) cfg.layer.shm.memfile_buffer_count = buffers;
	struct eCAL_SDataTypeInformation dt = {"bytes", "raw", NULL, 0};
	eCAL_Publisher *p = eCAL_Publisher_New(lean_string_cstr(topic), &dt, NULL, &cfg);
	if (!p) return user_err("ecal: publisher not created");
	return lean_io_result_mk_ok(lean_alloc_external(g_pub, p));
}
LEAN_EXPORT lean_obj_res el_pub_subscribers(b_lean_obj_arg o, lean_obj_arg w) {
	(void)w; return lean_io_result_mk_ok(lean_box_uint64(eCAL_Publisher_GetSubscriberCount(lean_get_external_data(o))));
}
LEAN_EXPORT lean_obj_res el_pub_send(b_lean_obj_arg o, b_lean_obj_arg bytes, lean_obj_arg w) {
	(void)w;
	int r = eCAL_Publisher_Send(lean_get_external_data(o), lean_sarray_cptr(bytes), lean_sarray_size(bytes), NULL);
	return lean_io_result_mk_ok(lean_box_uint32((uint32_t)r));
}

// The payload writer's callbacks carry no user pointer, so the current send lives in a
// thread-local. eCAL calls them on the sending thread, inside SendPayloadWriter.
static _Thread_local struct { lean_object *f; uint64_t len; lean_object *err; } t_send;
static size_t pw_size(void) { return (size_t)t_send.len; }
static int pw_write(void *buffer, size_t size) {
	lean_object *vo = view_new(buffer, size, 1);
	lean_inc(vo);
	lean_inc(t_send.f);
	lean_object *r = lean_apply_2(t_send.f, vo, lean_io_mk_world());
	VIEW(vo)->p = NULL;
	lean_dec(vo);
	if (lean_io_result_is_error(r)) { t_send.err = r; return 1; }
	lean_dec(r);
	return 0;
}
// Send `len` bytes that f writes in place. Returns eCAL's result: 0 when sent, non-zero otherwise.
LEAN_EXPORT lean_obj_res el_pub_send_with(b_lean_obj_arg o, uint64_t len, b_lean_obj_arg f, lean_obj_arg w) {
	(void)w;
	struct eCAL_PayloadWriter pw = {pw_write, pw_write, pw_size};
	t_send.f = f; t_send.len = len; t_send.err = NULL;
	int r = eCAL_Publisher_SendPayloadWriter(lean_get_external_data(o), &pw, NULL);
	lean_object *err = t_send.err;
	t_send.f = NULL; t_send.err = NULL;
	if (err) return err;
	return lean_io_result_mk_ok(lean_box_uint32((uint32_t)r));
}

// ---- subscriber: eCAL's thread hands each message to the Lean thread and waits ---------------
typedef struct {
	eCAL_Subscriber *sub;
	pthread_mutex_t mu;
	pthread_cond_t cv;
	const uint8_t *p; // the offered message, NULL when none
	uint64_t n;
	int64_t clock;
	int taken;        // Lean holds it
	int closing;
} lean_sub;
static lean_external_class *g_sub = NULL;
static void sub_finalize(void *q) {
	lean_sub *s = q;
	pthread_mutex_lock(&s->mu);
	s->closing = 1;
	pthread_cond_broadcast(&s->cv);
	pthread_mutex_unlock(&s->mu);
	eCAL_Subscriber_Delete(s->sub); // waits for a running callback
	pthread_cond_destroy(&s->cv);
	pthread_mutex_destroy(&s->mu);
	free(s);
}
static void on_receive(const struct eCAL_STopicId *id, const struct eCAL_SDataTypeInformation *dt,
                       const struct eCAL_SReceiveCallbackData *d, void *arg) {
	(void)id; (void)dt;
	lean_sub *s = arg;
	pthread_mutex_lock(&s->mu);
	while (s->p && !s->closing) pthread_cond_wait(&s->cv, &s->mu);
	if (!s->closing) {
		s->p = d->buffer; s->n = d->buffer_size; s->clock = d->send_clock; s->taken = 0;
		pthread_cond_broadcast(&s->cv);
		while (s->p && !s->closing) pthread_cond_wait(&s->cv, &s->mu); // until Lean releases
	}
	pthread_mutex_unlock(&s->mu);
}
LEAN_EXPORT lean_obj_res el_sub_new(b_lean_obj_arg topic, lean_obj_arg w) {
	(void)w;
	if (!g_sub) g_sub = lean_register_external_class(sub_finalize, noop_foreach);
	lean_sub *s = calloc(1, sizeof *s);
	pthread_mutex_init(&s->mu, NULL);
	pthread_cond_init(&s->cv, NULL);
	struct eCAL_SDataTypeInformation dt = {"bytes", "raw", NULL, 0};
	s->sub = eCAL_Subscriber_New(lean_string_cstr(topic), &dt, NULL, eCAL_GetSubscriberConfiguration());
	if (!s->sub) { free(s); return user_err("ecal: subscriber not created"); }
	eCAL_Subscriber_SetReceiveCallback(s->sub, on_receive, s);
	return lean_io_result_mk_ok(lean_alloc_external(g_sub, s));
}
LEAN_EXPORT lean_obj_res el_sub_publishers(b_lean_obj_arg o, lean_obj_arg w) {
	(void)w; return lean_io_result_mk_ok(lean_box_uint64(eCAL_Subscriber_GetPublisherCount(((lean_sub *)lean_get_external_data(o))->sub)));
}
// Wait up to wait_ms for a message; call f on it in place; release it. Returns the publisher's
// send clock + 1, or 0 when nothing came.
LEAN_EXPORT lean_obj_res el_sub_receive(b_lean_obj_arg o, uint64_t wait_ms, b_lean_obj_arg f, lean_obj_arg w) {
	(void)w;
	lean_sub *s = lean_get_external_data(o);
	struct timespec dl;
	clock_gettime(CLOCK_REALTIME, &dl);
	dl.tv_sec += (time_t)(wait_ms / 1000);
	dl.tv_nsec += (long)(wait_ms % 1000) * 1000000L;
	if (dl.tv_nsec >= 1000000000L) { dl.tv_sec++; dl.tv_nsec -= 1000000000L; }
	pthread_mutex_lock(&s->mu);
	while (!(s->p && !s->taken) && !s->closing)
		if (pthread_cond_timedwait(&s->cv, &s->mu, &dl) != 0) break;
	if (!(s->p && !s->taken)) { pthread_mutex_unlock(&s->mu); return lean_io_result_mk_ok(lean_box_uint64(0)); }
	s->taken = 1;
	uint8_t *p = (uint8_t *)s->p; uint64_t n = s->n; int64_t clock = s->clock;
	pthread_mutex_unlock(&s->mu);

	lean_object *vo = view_new(p, n, 0);
	lean_inc(vo);
	lean_inc(f);
	lean_object *r = lean_apply_2(f, vo, lean_io_mk_world());
	VIEW(vo)->p = NULL;
	lean_dec(vo);

	pthread_mutex_lock(&s->mu);
	s->p = NULL; s->taken = 0;
	pthread_cond_broadcast(&s->cv);
	pthread_mutex_unlock(&s->mu);
	if (lean_io_result_is_error(r)) return r;
	lean_dec(r);
	return lean_io_result_mk_ok(lean_box_uint64((uint64_t)clock + 1));
}
