/* Independently compiled loader fixtures. CASE is supplied by build.zig.
 * Header-only fixtures deliberately do not allocate a full function table.
 */
#include "zpi_plugin_runtime.h"
#include <stdlib.h>

#ifndef CASE
#error CASE must select a fixture
#endif

#if CASE == 0
int zpi_fixture_without_descriptor(void) { return 0; }
#elif CASE == 1
const zpi_plugin_header_v1 *zpi_plugin_descriptor_v1(void) { return NULL; }
#elif CASE == 2 || CASE == 3
static const zpi_plugin_header_v1 header = {
    CASE == 2 ? 99u : ZPI_ABI_MAJOR, ZPI_ABI_MINOR,
    sizeof(zpi_plugin_header_v1), 0, 0,
};
const zpi_plugin_header_v1 *zpi_plugin_descriptor_v1(void) { return &header; }
#else
static int32_t create(const zpi_host_v1 *host, void **instance) {
    (void)host;
    *instance = NULL;
#if CASE == 6
    return 1;
#elif CASE == 4 || CASE == 5 || CASE == 9
    /* These descriptors must be rejected before any instance callback. */
    abort();
#else
    return 0;
#endif
}
static int32_t shutdown_plugin(void *instance) { (void)instance; return 0; }
static uint32_t tool_count(void *instance) { (void)instance; return 0; }
static int32_t tool_at(void *instance, uint32_t index, zpi_tool_v1 *tool) {
    (void)instance; (void)index; (void)tool; return 1;
}
static int32_t start(void *instance, uint32_t index, const zpi_call_v1 *call, void **operation) {
    (void)instance; (void)index; (void)call; *operation = NULL; return 1;
}
static int32_t poll_operation(void *instance, void *operation, zpi_poll_v1 *result) {
    (void)instance; (void)operation; (void)result; return 1;
}
static int32_t cancel_operation(void *instance, void *operation) {
    (void)instance; (void)operation; return 1;
}
static void destroy_operation(void *instance, void *operation) { (void)instance; (void)operation; }

/* Exact required prefix: the old plugin allocates no optional name field. */
struct required_prefix {
    uint32_t abi_major, abi_minor, struct_size, reserved;
    uint64_t required_capabilities;
    int32_t (*create)(const zpi_host_v1 *, void **);
    int32_t (*shutdown)(void *);
    uint32_t (*tool_count)(void *);
    int32_t (*tool_at)(void *, uint32_t, zpi_tool_v1 *);
    int32_t (*start)(void *, uint32_t, const zpi_call_v1 *, void **);
    int32_t (*poll)(void *, void *, zpi_poll_v1 *);
    int32_t (*cancel)(void *, void *);
    void (*destroy)(void *, void *);
};
_Static_assert(sizeof(struct required_prefix) == ZPI_PLUGIN_V1_REQUIRED_SIZE, "mandatory prefix layout");
struct extended_table { zpi_plugin_v1 table; uint64_t future[8]; };

#if CASE == 7
static const struct required_prefix descriptor = {
#else
static const struct extended_table extended = { .table = {
#endif
    .abi_major = ZPI_ABI_MAJOR,
    .abi_minor = CASE == 8 ? 99u : ZPI_ABI_MINOR,
#if CASE == 7
    .struct_size = sizeof(struct required_prefix),
#else
    .struct_size = CASE == 8 ? sizeof(struct extended_table) : sizeof(zpi_plugin_v1),
#endif
    .reserved = CASE == 9 ? 1u : 0u,
    .required_capabilities = CASE == 4 ? UINT64_C(0x80000000) : ZPI_CAP_VALUES | ZPI_CAP_TOOLS,
    .create = create, .shutdown = shutdown_plugin, .tool_count = tool_count,
    .tool_at = tool_at, .start = start,
    .poll = CASE == 5 ? NULL : poll_operation,
    .cancel = cancel_operation, .destroy = destroy_operation,
#if CASE == 7
};
#else
} };
#endif
const zpi_plugin_header_v1 *zpi_plugin_descriptor_v1(void) {
#if CASE == 7
    return (const zpi_plugin_header_v1 *)&descriptor;
#else
    return (const zpi_plugin_header_v1 *)&extended.table;
#endif
}
#endif
