#include <Arduino.h>

void infiniteLoop(void (*print)(const char*)) {
    static unsigned long count = 0;
    char buffer[64];
    snprintf(buffer, sizeof(buffer), "[prog4] Tick #%lu\r\n", count++);
    print(buffer);
}
