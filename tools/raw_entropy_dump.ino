#include <ESP8266WiFi.h>

ADC_MODE(ADC_VCC);

// WDEV free-running timer — see esp8266_trng.ino for full caveats.
#define WDEV_NOW() (*(volatile uint32_t *)0x3FF20C00)

#define RAW_BUFFER_SIZE 1024
uint8_t raw_buffer[RAW_BUFFER_SIZE];

void setup() {
  WiFi.persistent(false);
  WiFi.mode(WIFI_OFF);
  WiFi.forceSleepBegin();
  delay(1);

  Serial.begin(115200);

  pinMode(3, INPUT_PULLUP);
  pinMode(16, INPUT_PULLDOWN_16);
  pinMode(0, INPUT_PULLUP);
  pinMode(2, INPUT_PULLUP);
  pinMode(4, INPUT_PULLUP);
  pinMode(5, INPUT_PULLUP);
  pinMode(12, INPUT_PULLUP);
  pinMode(13, INPUT_PULLUP);
  pinMode(14, INPUT_PULLUP);
}

void loop() {
  for (int i = 0; i < RAW_BUFFER_SIZE; i++) {
    uint8_t sample_byte = 0;
    for (int bit = 0; bit < 8; bit++) {
      uint16_t vcc = ESP.getVcc();
      uint32_t c1 = ESP.getCycleCount();
      delayMicroseconds(10 + ((vcc ^ c1) & 0x1F));
      uint32_t c2 = ESP.getCycleCount();
      uint32_t wdev = WDEV_NOW();

      uint8_t entropy_bit = (vcc ^ (vcc >> 1) ^ (c2 - c1) ^ (c2 >> 2) ^ wdev ^ (wdev >> 1)) & 1;
      sample_byte = (sample_byte << 1) | entropy_bit;
    }
    raw_buffer[i] = sample_byte;
  }

  Serial.write(raw_buffer, RAW_BUFFER_SIZE);
}
