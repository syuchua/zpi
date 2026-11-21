#ifndef ZPI_PLUGIN_RUNTIME_H
#define ZPI_PLUGIN_RUNTIME_H
#include "zpi_plugin.h"
#ifdef __cplusplus
extern "C" {
#endif
/* Experimental serial, non-reentrant runtime; see native-plugin-runtime.md.
 * The descriptor is static and borrowed through unload. Validate its prefix,
 * required size/capabilities/functions BEFORE create; no instance exists yet.
 * create must clean partial state on failure. All output structs are host
 * initialized to zero. Callbacks return 0 for success; nonzero for API failure.
 */
#define ZPI_CAP_VALUES UINT64_C(1)
#define ZPI_CAP_TOOLS UINT64_C(2)
#define ZPI_POLL_PENDING 0u
#define ZPI_POLL_PROGRESS 1u
#define ZPI_POLL_COMPLETE 2u
#define ZPI_POLL_FAILED 3u
#define ZPI_POLL_CANCELED 4u

typedef struct zpi_plugin_header_v1 {
    uint32_t abi_major, abi_minor, struct_size, reserved;
    uint64_t required_capabilities;
} zpi_plugin_header_v1;
/* The descriptor symbol returns this header pointer; the function-table prefix
 * follows it. The host validates major, size and capabilities before reading
 * any callback pointer. A conforming plugin returns readable static storage
 * for at least struct_size bytes and never mutates it before unload. The prefix
 * through required_capabilities must be available for size negotiation.
 */

typedef struct zpi_host_v1 {
    uint32_t abi_major, abi_minor, struct_size, reserved;
    uint64_t capabilities;
} zpi_host_v1;
typedef struct zpi_tool_v1 {
    zpi_span name;
    zpi_span description;
    zpi_value parameters; /* JSON-compatible object, borrowed until shutdown */
} zpi_tool_v1;
typedef struct zpi_call_v1 {
    zpi_span call_id;
    zpi_span cwd;
    zpi_value arguments; /* callback-borrowed; copy before start returns */
} zpi_call_v1;
typedef struct zpi_poll_v1 {
    uint32_t state, reserved;
    zpi_owned_value output;
} zpi_poll_v1;
typedef struct zpi_plugin_v1 {
    uint32_t abi_major, abi_minor, struct_size, reserved;
    uint64_t required_capabilities;
    int32_t (*create)(const zpi_host_v1 *, void **instance);
    int32_t (*shutdown)(void *instance);
    uint32_t (*tool_count)(void *instance);
    int32_t (*tool_at)(void *instance, uint32_t index, zpi_tool_v1 *tool);
    int32_t (*start)(void *instance, uint32_t index, const zpi_call_v1 *, void **operation);
    int32_t (*poll)(void *instance, void *operation, zpi_poll_v1 *result);
    int32_t (*cancel)(void *instance, void *operation);
    void (*destroy)(void *instance, void *operation);
    /* Optional appended tail. Read only when struct_size covers this field. */
    zpi_span name;
} zpi_plugin_v1;
/* Required prefix ends at destroy. Appended name is optional even at minor 0. */
#define ZPI_PLUGIN_V1_REQUIRED_SIZE offsetof(zpi_plugin_v1, name)
typedef const zpi_plugin_header_v1 *(*zpi_plugin_descriptor_v1_fn)(void);
#ifdef __cplusplus
}
#endif
#endif
