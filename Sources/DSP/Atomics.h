// Lock-free primitives shared between the UI and the real-time audio thread.
// Swift's Atomic<> can't live in arrays, so the handful we need are plain C builtins.
#pragma once
#include <stdbool.h>
#include <stdint.h>

static inline void *TBExchangePtr(void **slot, void *value) {
    return __atomic_exchange_n(slot, value, __ATOMIC_ACQ_REL);
}

static inline bool TBCompareExchangePtr(void **slot, void *expected, void *desired) {
    return __atomic_compare_exchange_n(slot, &expected, desired, false, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
}

static inline void *TBLoadPtr(void **slot) {
    return __atomic_load_n(slot, __ATOMIC_ACQUIRE);
}

static inline int64_t TBLoad64(int64_t *slot) {
    return __atomic_load_n(slot, __ATOMIC_ACQUIRE);
}

static inline void TBStore64(int64_t *slot, int64_t value) {
    __atomic_store_n(slot, value, __ATOMIC_RELEASE);
}

static inline int64_t TBAdd64(int64_t *slot, int64_t value) {
    return __atomic_add_fetch(slot, value, __ATOMIC_ACQ_REL);
}

static inline float TBLoadFloat(float *slot) {
    float out;
    __atomic_load(slot, &out, __ATOMIC_ACQUIRE);
    return out;
}

static inline void TBStoreFloat(float *slot, float value) {
    __atomic_store(slot, &value, __ATOMIC_RELEASE);
}
