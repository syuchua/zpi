#include "zpi_plugin.h"

#if UINTPTR_MAX == UINT64_MAX
_Static_assert(sizeof(zpi_span) == 16, "span layout");
_Static_assert(sizeof(zpi_list) == 16, "list layout");
_Static_assert(sizeof(zpi_object) == 16, "object layout");
_Static_assert(sizeof(zpi_value) == 24, "value layout");
_Static_assert(sizeof(zpi_entry) == 40, "entry layout");
_Static_assert(sizeof(zpi_owned_value) == 40, "owned value layout");
_Static_assert(offsetof(zpi_value, payload) == 8, "payload offset");
_Static_assert(offsetof(zpi_owned_value, context) == 24, "context offset");
_Static_assert(offsetof(zpi_owned_value, release) == 32, "release offset");
#endif

static void release_value(void *context) {
    (*(unsigned *)context)++;
}

int zpi_fixture_roundtrip(zpi_value input, zpi_owned_value *output, unsigned *releases) {
    if (!output || !releases || input.flags || input.tag != ZPI_VALUE_U64) return 1;
    output->value = input;
    output->context = releases;
    output->release = release_value;
    return 0;
}
