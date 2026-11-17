/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "dxmt_data_lock.h"
#include <pthread.h>
static pthread_mutex_t dxmt_data_mutex = PTHREAD_MUTEX_INITIALIZER;
void hv_dxmt_data_lock(void) { pthread_mutex_lock(&dxmt_data_mutex); }
void hv_dxmt_data_unlock(void) { pthread_mutex_unlock(&dxmt_data_mutex); }
