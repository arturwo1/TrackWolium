#pragma once
#include <stdint.h>

#if defined(_WIN32)
#define TW_API __declspec(dllexport)
#else
#define TW_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct tw_engine tw_engine;

TW_API tw_engine* tw_create(int64_t max_gap_ms);
TW_API void tw_destroy(tw_engine* e);
TW_API void tw_add_sample(tw_engine* e, const char* app, int state);
TW_API void tw_step(tw_engine* e, int64_t now_ms);
TW_API int tw_report_json(tw_engine* e, char* buf, int cap);

#ifdef __cplusplus
}
#endif
