#include "zpi_plugin_runtime.h"
#include <stdlib.h>
#include <string.h>

struct instance { unsigned live; unsigned outputs; };
struct operation { struct instance *owner; unsigned polls; unsigned canceled; unsigned cancels; zpi_span call_id; };
static const uint8_t tool_name[] = "echo_native";
static const uint8_t tool_description[] = "Return the received call id";
static const zpi_entry schema_entries[] = {
    { { (const uint8_t *)"type", 4 }, { ZPI_VALUE_STRING, 0, { .span = { (const uint8_t *)"object", 6 } } } },
    { { (const uint8_t *)"additionalProperties", 20 }, { ZPI_VALUE_BOOL, 0, { .boolean = 1 } } },
};
static const zpi_value schema_value = {
    .tag = ZPI_VALUE_OBJECT, .flags = 0,
    .payload.object = { schema_entries, 2 },
};
static int32_t create(const zpi_host_v1 *host, void **out) {
    if (!host || !out || host->abi_major != ZPI_ABI_MAJOR || !(host->capabilities & ZPI_CAP_TOOLS)) return 1;
    *out = calloc(1, sizeof(struct instance));
    return *out ? 0 : 2;
}
static int32_t shutdown_plugin(void *opaque) {
    struct instance *instance = opaque;
    if (!instance || instance->live || instance->outputs) return 1;
    free(instance);
    return 0;
}
static uint32_t tool_count(void *opaque) { return opaque ? 1 : 0; }
static int32_t tool_at(void *opaque, uint32_t index, zpi_tool_v1 *tool) {
    if (!opaque || index || !tool) return 1;
    tool->name = (zpi_span){ tool_name, sizeof(tool_name) - 1 };
    tool->description = (zpi_span){ tool_description, sizeof(tool_description) - 1 };
    tool->parameters = schema_value;
    return 0;
}
struct output { struct instance *owner; uint8_t bytes[]; };
static void release_output(void *opaque) {
    struct output *output = opaque;
    output->owner->outputs--;
    free(output);
}
static int32_t start(void *opaque, uint32_t index, const zpi_call_v1 *call, void **out) {
    if (!opaque || index || !call || !out || (call->call_id.len && !call->call_id.ptr)) return 1;
    struct operation *operation = calloc(1, sizeof(*operation));
    if (!operation) return 2;
    uint8_t *copy = NULL;
    if (call->call_id.len) {
        copy = malloc(call->call_id.len);
        if (!copy) { free(operation); return 2; }
        memcpy(copy, call->call_id.ptr, call->call_id.len);
        operation->call_id = (zpi_span){ copy, call->call_id.len };
    }
    operation->owner = opaque;
    ((struct instance *)opaque)->live++;
    *out = operation;
    return 0;
}
static int32_t poll_operation(void *opaque, void *handle, zpi_poll_v1 *result) {
    if (!opaque || !handle || !result) return 1;
    struct operation *operation = handle;
    memset(result, 0, sizeof(*result));
    if (operation->canceled) { result->state = ZPI_POLL_CANCELED; return 0; }
    if (operation->call_id.len == 5 && !memcmp(operation->call_id.ptr, "stall", 5)) { result->state = ZPI_POLL_PENDING; return 0; }
    if (operation->call_id.len == 7 && !memcmp(operation->call_id.ptr, "pending", 7) && operation->polls == 0) {
        operation->polls++;
        result->state = ZPI_POLL_PENDING;
        return 0;
    }
    if (operation->polls++ == 0) { result->state = ZPI_POLL_PROGRESS; return 0; }
    struct output *output = malloc(sizeof(*output) + operation->call_id.len);
    if (!output) return 2;
    output->owner = opaque;
    output->owner->outputs++;
    if (operation->call_id.len) memcpy(output->bytes, operation->call_id.ptr, operation->call_id.len);
    result->state = ZPI_POLL_COMPLETE;
    result->output.value.tag = ZPI_VALUE_STRING;
    result->output.value.payload.span = (zpi_span){ output->bytes, operation->call_id.len };
    result->output.context = output;
    result->output.release = release_output;
    if (operation->call_id.len == 9 && !memcmp(operation->call_id.ptr, "malformed", 9)) result->output.value.tag = 999;
    if (operation->call_id.len == 4 && !memcmp(operation->call_id.ptr, "fail", 4)) result->state = ZPI_POLL_FAILED;
    return 0;
}
static int32_t cancel_operation(void *opaque, void *handle) {
    if (!opaque || !handle) return 1;
    struct operation *operation = handle;
    operation->canceled = 1;
    operation->cancels++;
    return 0;
}
static void destroy_operation(void *opaque, void *handle) {
    struct operation *operation = handle;
    if (operation) {
        ((struct instance *)opaque)->live--;
        free((void *)operation->call_id.ptr);
        free(operation);
    }
}
static const zpi_plugin_v1 descriptor = {
    .abi_major = ZPI_ABI_MAJOR, .abi_minor = ZPI_ABI_MINOR,
    .struct_size = sizeof(zpi_plugin_v1), .reserved = 0,
    .required_capabilities = ZPI_CAP_VALUES | ZPI_CAP_TOOLS,
    .create = create, .shutdown = shutdown_plugin, .tool_count = tool_count,
    .tool_at = tool_at, .start = start, .poll = poll_operation,
    .cancel = cancel_operation, .destroy = destroy_operation,
    .name = { tool_name, sizeof(tool_name) - 1 },
};
uint32_t zpi_fixture_cancel_count(void *handle) { return ((struct operation *)handle)->cancels; }
const zpi_plugin_header_v1 *zpi_plugin_descriptor_v1(void) {
    return (const zpi_plugin_header_v1 *)&descriptor;
}
