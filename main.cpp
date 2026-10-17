#include <Arduino.h>
#include "user_programs_registry.h"

struct TaskContext {
    volatile uint32_t* stackPointer;
    uintptr_t programCounter;
    bool ready;
};

static volatile uint32_t systemTicks = 0;
static volatile bool backgroundTaskEnabled = false;
static volatile bool schedulerBusy = false;
static volatile bool stopBackgroundTask = false;
static volatile uint8_t activeTask = 0;
static TaskContext taskContexts[2] = {};

void system_print(const char* s) {
    Serial.print(s);
}

static void uartEmergencyPrint(const char* text) {
    volatile uint32_t* status = reinterpret_cast<volatile uint32_t*>(0x40013800);
    volatile uint32_t* data = reinterpret_cast<volatile uint32_t*>(0x40013804);

    while (*text != '\0') {
        while ((*status & (1u << 7)) == 0) {}
        *data = static_cast<uint32_t>(*text++);
    }
}

static void saveTaskContext(uint8_t task) {
    uint32_t stackPointer;
    asm volatile("mov %0, sp" : "=r"(stackPointer));
    taskContexts[task].stackPointer = reinterpret_cast<volatile uint32_t*>(stackPointer);
    taskContexts[task].programCounter = reinterpret_cast<uintptr_t>(__builtin_return_address(0));
    taskContexts[task].ready = true;
}

extern "C" void HAL_SYSTICK_Callback(void) {
    if (schedulerBusy) {
        return;
    }

    schedulerBusy = true;
    systemTicks++;
    saveTaskContext(activeTask);

    if (backgroundTaskEnabled && systemTicks % 500 == 0) {
        activeTask = 1;
        uartEmergencyPrint("ALERTE\r\n");
        infiniteLoop(uartEmergencyPrint);
        activeTask = 0;
    }

    schedulerBusy = false;
}

void waitForEnter() {
    int c = -1;
    while (true) {
        if (Serial.available() > 0) {
            c = Serial.read();
            if (c == '\r' || c == '\n') break;
        }
        delay(1);
    }
}

int readChoice() {
    String input = "";
    while (true) {
        if (Serial.available() > 0) {
            char c = Serial.read();

            if (c == 'q' || c == 'Q') return -2; // code spécial pour shutdown

            if (c == '\r' || c == '\n') break;   // Enter
            if (c >= '0' && c <= '9') {          // chiffre
                Serial.print(c);                 // écho
                input += c;
            }
        }
        delay(1);
    }

    // Validation : un seul chiffre
    if (input.length() != 1) return -1;
    int choice = input.toInt() - 1; // 0-based
    if (choice < 0 || choice >= programCount) return -1;
    return choice;
}

void showMenu() {
    Serial.println("\r\n=== Mini OS (STM32 QEMU) ===");
    Serial.println("Programmes disponibles :");
    for (int i = 0; i < programCount; i++) {
        Serial.print("  ");
        Serial.print(i + 1);
        Serial.print(") ");
        Serial.println(programTable[i].name);
    }
    Serial.println("Tapez 'q' pour quitter.");
}

void setup() {
    Serial.begin(115200);
    while (!Serial) {}

    Serial.println("Appuyez sur Entrée pour démarrer le menu...");
    waitForEnter();
}

void loop() {
    showMenu();

    Serial.println("\r\nChoisissez un programme (1..n) : ");
    int choice = readChoice();

    if (choice == -2) { // shutdown
        Serial.println("\r\n[Kernel] Arrêt du système...");
        Serial.println("\r\n[Kernel] Système arrêté, vous pouvez éteindre votre STM32");
        while(1) {
          Serial.println("Appuyez sur Entrée pour démarrer le STM32...");
          waitForEnter();
          return;
        }  // MCU bloqué
    }

    if (choice == -1) {
        Serial.println("\r\nChoix invalide.");
        delay(500); // petite pause avant de revenir au menu
        return;     // retour au début de loop()
    }

    Serial.print("\r\n[Kernel] Démarrage du programme ");
    Serial.println(programTable[choice].name);
    Serial.println("----------------------------------");

    stopBackgroundTask = false;
    backgroundTaskEnabled = true;

    if (choice == 0) {
        while (!stopBackgroundTask) {
            if (Serial.available() > 0) {
                char c = Serial.read();
                if (c == 'q' || c == 'Q') {
                    stopBackgroundTask = true;
                }
            }
            delay(10);
        }
    } else {
        programTable[choice].func(system_print);
    }

    backgroundTaskEnabled = false;
    activeTask = 0;

    Serial.println("----------------------------------");
    Serial.println("[Kernel] Programme terminé.");

    // Attente avant de revenir au menu
    Serial.println("\r\nAppuyez sur Entrée pour revenir au menu...");
    waitForEnter();
}
