#include <Arduino.h>

typedef void (*print_fn)(const char*);

void prog1(print_fn print) {
    print("[prog1] Hello from program 1!\r\n");
    for (int i = 0; i < 3; i++) {
        print("[prog1] Tick...\r\n");
    }
#ifdef MEMORY_TEST
    volatile unsigned int* flashAddress = reinterpret_cast<volatile unsigned int*>(0x08000000);
    *flashAddress = 0xFFFFFFFF;
#endif
}
