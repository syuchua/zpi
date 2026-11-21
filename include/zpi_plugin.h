#ifndef ZPI_PLUGIN_H
#define ZPI_PLUGIN_H
/* Experimental native value contract. No stable loader ABI is published yet.
 * Compile for the same OS, CPU and C ABI as the host. All views are immutable.
 * A view and its entire backing graph are borrowed for a callback unless an
 * explicit owned descriptor says otherwise. Null pointer requires zero length.
 * No exception/unwind may cross a callback. These pointers are trusted memory.
 */
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

#define ZPI_ABI_MAJOR 1u
#define ZPI_ABI_MINOR 0u
#define ZPI_VALUE_NULL 0u
#define ZPI_VALUE_BOOL 1u
#define ZPI_VALUE_I64 2u
#define ZPI_VALUE_U64 3u
#define ZPI_VALUE_F64 4u
#define ZPI_VALUE_NUMBER 5u /* exact JSON number lexeme, UTF-8 ASCII */
#define ZPI_VALUE_STRING 6u /* UTF-8 */
#define ZPI_VALUE_BYTES 7u  /* never implicitly converted to JSON text */
#define ZPI_VALUE_LIST 8u
#define ZPI_VALUE_OBJECT 9u /* ordered, unique UTF-8 keys */

typedef struct zpi_span {
    const uint8_t *ptr;
    size_t len;
} zpi_span;
typedef struct zpi_value zpi_value;
typedef struct zpi_entry zpi_entry;
typedef struct zpi_list {
    const zpi_value *ptr;
    size_t len;
} zpi_list;
typedef struct zpi_object {
    const zpi_entry *ptr;
    size_t len;
} zpi_object;
typedef union zpi_payload {
    uint8_t boolean; /* 0 or 1 */
    int64_t signed_integer;
    uint64_t unsigned_integer;
    double float_number; /* finite only */
    zpi_span span;
    zpi_list list;
    zpi_object object;
} zpi_payload;
struct zpi_value {
    uint32_t tag;
    uint32_t flags; /* reserved; must be zero */
    zpi_payload payload;
};
struct zpi_entry {
    zpi_span key;
    zpi_value value;
};
/* Owned values transfer one release responsibility with the descriptor. The
 * receiver releases once after finishing reads, before unloading the producer.
 * A null callback denotes a borrowed graph and MUST be paired with context=NULL;
 * the producer keeps the entire immutable graph alive until the parent operation
 * is destroyed (the entire module lifetime for static metadata). It is invalid
 * to borrow stack data or release a borrowed graph. A non-null callback denotes
 * an owned graph and accepts the context exactly once, including empty values.
 * The producer owns the complete nested graph. Copying the descriptor does not
 * acquire another ownership reference. release must not reenter the host.
 */
typedef void (*zpi_release_fn)(void *context);
typedef struct zpi_owned_value {
    zpi_value value;
    void *context;
    zpi_release_fn release;
} zpi_owned_value;

#ifdef __cplusplus
}
#endif
#endif
