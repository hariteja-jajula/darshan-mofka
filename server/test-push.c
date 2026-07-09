#include <stdio.h>
#include <stdlib.h>
#include <diaspora/diaspora_c.h>

int main(int argc, char **argv)
{
    const char *group_file = argv[1];
    char options[1024];
    snprintf(options, sizeof(options), "{\"group_file\":\"%s\"}", group_file);

    diaspora_driver_t *d = diaspora_driver_create("mofka", options);
    if (!d) { fprintf(stderr, "driver: %s\n", diaspora_c_last_error()); return 1; }

    diaspora_topic_t *t = diaspora_topic_open(d, "darshan");
    if (!t) { fprintf(stderr, "topic: %s\n", diaspora_c_last_error()); return 1; }

    diaspora_producer_t *p = diaspora_producer_create(t, "test", 0, 0, DIASPORA_C_ORDERING_LOOSE);
    if (!p) { fprintf(stderr, "producer: %s\n", diaspora_c_last_error()); return 1; }

    for (int i = 0; i < 5; i++) {
        char msg[256];
        snprintf(msg, sizeof(msg), "{\"n\":%d,\"hello\":\"mofka\"}", i);
        if (diaspora_producer_push(p, msg, NULL, 0) != DIASPORA_C_OK)
            fprintf(stderr, "push %d: %s\n", i, diaspora_c_last_error());
    }

    int rc = diaspora_producer_flush_timeout(p, 5000);
    printf("flush rc=%d (0=OK 1=TIMEOUT -1=ERR)\n", rc);

    diaspora_producer_destroy(p);
    diaspora_topic_destroy(t);
    diaspora_driver_destroy(d);
    printf("pushed 5 records to topic 'darshan'\n");
    return 0;
}
