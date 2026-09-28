#import "IcliPrivate.h"
#import <dispatch/dispatch.h>
#import <notify.h>

// Darwin notifications through notifyd. A registration of our own, made
// before the post, both carries the state and proves notifyd delivered it.
uint32_t icli_notify_post(const char *name, bool set_state, uint64_t state, bool *delivered) {
    *delivered = false;
    dispatch_semaphore_t received = dispatch_semaphore_create(0);
    dispatch_queue_t queue = dispatch_queue_create("icli.notify", DISPATCH_QUEUE_SERIAL);
    int token = 0;
    uint32_t status = notify_register_dispatch(name, &token, queue, ^(int t) {
        dispatch_semaphore_signal(received);
    });
    if (status != NOTIFY_STATUS_OK) return status;
    if (set_state) status = notify_set_state(token, state);
    if (status == NOTIFY_STATUS_OK) status = notify_post(name);
    if (status == NOTIFY_STATUS_OK)
        *delivered = dispatch_semaphore_wait(received, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0;
    notify_cancel(token);
    return status;
}

uint32_t icli_notify_get_state(const char *name, uint64_t *state) {
    int token = 0;
    uint32_t status = notify_register_check(name, &token);
    if (status != NOTIFY_STATUS_OK) return status;
    status = notify_get_state(token, state);
    notify_cancel(token);
    return status;
}
