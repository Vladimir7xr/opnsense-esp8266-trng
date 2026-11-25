#include <ESP8266WiFi.h>
#include <bearssl/bearssl_hash.h>

// Enable internal Vcc measurement mode (thermal noise of the crystal's power supply).
// IMPORTANT: When using ADC_VCC, pin A0 (TOUT) must remain completely disconnected!
ADC_MODE(ADC_VCC);

#define RAW_BUFFER_SIZE 512   // 512 bytes of raw entropy for 32 bytes of output (16:1 compression)
#define STATE_SIZE 32         // Size of the internal state (previous hash)

// Buffer: [32 bytes of previous hash] + [512 bytes of new raw data]
uint8_t entropy_buffer[STATE_SIZE + RAW_BUFFER_SIZE];
uint8_t hash_out[STATE_SIZE];
bool is_warmed_up = false;

void setup() {
  // Forcefully disable Wi-Fi before starting any processes
  WiFi.persistent(false);
  WiFi.mode(WIFI_OFF);
  WiFi.forceSleepBegin();
  delay(1);

  // --- Pin Configuration for Universal Use (ESP12E / ESP07) ---
  // Configure unused pins first to prevent floating inputs and EMI.
  // Avoid touching GPIO15 (needs hardware pull-down for boot) and GPIO6-11 (Flash).
  pinMode(16, INPUT_PULLDOWN_16); // GPIO16 - uses internal pull-down
  pinMode(0, INPUT_PULLUP);       // GPIO0
  pinMode(2, INPUT_PULLUP);       // GPIO2
  pinMode(4, INPUT_PULLUP);       // GPIO4
  pinMode(5, INPUT_PULLUP);       // GPIO5
  pinMode(12, INPUT_PULLUP);      // GPIO12
  pinMode(13, INPUT_PULLUP);      // GPIO13
  pinMode(14, INPUT_PULLUP);      // GPIO14

  // Initialize UART and then detach RX (GPIO3) as a physical/logical Data Diode
  Serial.begin(115200);
  pinMode(3, INPUT_PULLUP);

  // Initial seed mixing at startup
  for (int i = 0; i < STATE_SIZE; i++) {
    entropy_buffer[i] = (uint8_t)(ESP.getVcc() ^ ESP.getCycleCount());
    delayMicroseconds(17);
  }
}

void loop() {
  uint32_t transitions = 0;
  uint32_t lag2_matches = 0;
  uint32_t ones_count = 0;
  uint8_t bit_history = 0;

  uint16_t min_vcc = 0xFFFF;
  uint16_t max_vcc = 0;

  // Fill 512 bytes of raw data (keeping previous hash at offset 0..31)
  for (int i = 0; i < RAW_BUFFER_SIZE; i++) {
    uint8_t sample_byte = 0;

    for (int bit = 0; bit < 8; bit++) {
      uint16_t vcc = ESP.getVcc();
      if (vcc < min_vcc) min_vcc = vcc;
      if (vcc > max_vcc) max_vcc = vcc;

      uint32_t c1 = ESP.getCycleCount();

      // Non-periodic delay depending on previous sample (breaks 50 Hz harmonics)
      delayMicroseconds(10 + ((vcc ^ c1) & 0x1F));

      uint32_t c2 = ESP.getCycleCount();

      // Mix lower bits of Vcc, cycle delta, and shifts
      uint8_t entropy_bit = (vcc ^ (vcc >> 1) ^ (c2 - c1) ^ (c2 >> 2)) & 1;

      // Track lag-1 transitions and lag-2 matches (catches 101010... and 11001100... patterns)
      if ((i > 0 || bit > 0) && (entropy_bit != (bit_history & 1))) {
        transitions++;
      }
      if ((i > 0 || bit > 1) && (entropy_bit == ((bit_history >> 1) & 1))) {
        lag2_matches++;
      }
      bit_history = (bit_history << 1) | entropy_bit;

      if (entropy_bit) {
        ones_count++;
      }

      sample_byte = (sample_byte << 1) | entropy_bit;
    }

    entropy_buffer[STATE_SIZE + i] = sample_byte;
  }

  // Multi-stage Health Check:
  // 1. ADC range check: min_vcc != max_vcc ensures ADC is alive and fluctuating
  // 2. Lag-1 transitions & Lag-2 pattern lock (blocks square-wave / alternating faults)
  // 3. Monobit zero/one bias limits
  if (min_vcc == max_vcc ||
      transitions < 800 || transitions > 3296 ||
      lag2_matches < 800 || lag2_matches > 3296 ||
      ones_count < 1024 || ones_count > 3072) {
    return;
  }

  // Calculate SHA-256 using built-in BearSSL
  br_sha256_context ctx;
  br_sha256_init(&ctx);
  br_sha256_update(&ctx, entropy_buffer, STATE_SIZE + RAW_BUFFER_SIZE);
  br_sha256_out(&ctx, hash_out);

  // Save new hash to the beginning of the buffer for the next cycle (Sponge)
  memcpy(entropy_buffer, hash_out, STATE_SIZE);

  // Discard the very first cold-start block after power-on so only warmed-up state is emitted
  if (!is_warmed_up) {
    is_warmed_up = true;
    return;
  }

  // Output 32 bytes of pure entropy to CP2102
  Serial.write(hash_out, STATE_SIZE);
}