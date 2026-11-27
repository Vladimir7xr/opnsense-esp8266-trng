#include <ESP8266WiFi.h>
#include <bearssl/bearssl_hmac.h>

// Enable internal Vcc measurement mode (thermal noise of the crystal's power supply).
// IMPORTANT: When using ADC_VCC, pin A0 (TOUT) must remain completely disconnected!
ADC_MODE(ADC_VCC);

#define RAW_BUFFER_SIZE 1024  // 1024 bytes (8192 bits) of raw entropy for 32 bytes output (32:1 compression)
#define STATE_SIZE 32         // 256-bit internal state key & output block size

// SP 800-90B-inspired continuous health tests (binary samples, conservative H=0.5, alpha=2^-20)
#define RCT_CUTOFF 41         // Repetition Count Test: fail on runs of >= 41 identical bits
#define APT_WINDOW 1024       // Adaptive Proportion Test: non-overlapping windows of 1024 bits
#define APT_HIGH 800          // ~CRITBINOM(1024, 2^-0.5, 1-2^-20)
#define APT_LOW 224           // symmetric lower bound (APT_WINDOW - APT_HIGH)
#define ADC_MIN_RANGE 4       // minimum expected max_vcc - min_vcc across the block

// Domain separation tags (strictly isolates init, state update, and output derivation)
static const char DOMAIN_TAG_INIT[] = "ESP8266_TRNG_V3_INIT";
static const char DOMAIN_TAG_STEP[] = "ESP8266_TRNG_V3_STEP";
static const char DOMAIN_TAG_OUT[]  = "ESP8266_TRNG_V3_OUT";

// Internal secret state (never transmitted over UART)
static uint8_t state_key[STATE_SIZE];
static uint8_t raw_buffer[RAW_BUFFER_SIZE];
static uint64_t frame_counter = 0;
static bool is_warmed_up = false;

// Prevent compiler dead-store elimination when wiping sensitive RAM buffers
static void secure_zero(void *ptr, size_t len) {
  volatile uint8_t *p = (volatile uint8_t *)ptr;
  while (len--) {
    *p++ = 0;
  }
}

void setup() {
  // Forcefully disable Wi-Fi before starting any processes (~15-20 mA, zero RF EMI)
  WiFi.persistent(false);
  WiFi.mode(WIFI_OFF);
  WiFi.forceSleepBegin();
  delay(1);

  // --- Pin Configuration for Universal Use (ESP-12E / ESP-12F / ESP-07) ---
  // Configure unused pins to prevent floating inputs and electromagnetic interference.
  // Do not touch GPIO15 (needs hardware pull-down for boot) and GPIO6-11 (SPI Flash).
  pinMode(16, INPUT_PULLDOWN_16); // GPIO16 - uses internal pull-down
  pinMode(0, INPUT_PULLUP);       // GPIO0
  pinMode(2, INPUT_PULLUP);       // GPIO2
  pinMode(4, INPUT_PULLUP);       // GPIO4
  pinMode(5, INPUT_PULLUP);       // GPIO5
  pinMode(12, INPUT_PULLUP);      // GPIO12
  pinMode(13, INPUT_PULLUP);      // GPIO13
  pinMode(14, INPUT_PULLUP);      // GPIO14

  // Initialize UART and detach RX (GPIO3) as a physical/logical Data Diode
  Serial.begin(115200);
  pinMode(3, INPUT_PULLUP);

  // Initial HKDF-Extract style seeding with zero-key HMAC-SHA256
  uint8_t zero_key[STATE_SIZE];
  secure_zero(zero_key, sizeof(zero_key));

  br_hmac_key_context kc;
  br_hmac_context hctx;
  br_hmac_key_init(&kc, &br_sha256_vtable, zero_key, STATE_SIZE);
  br_hmac_init(&hctx, &kc, 0);
  br_hmac_update(&hctx, DOMAIN_TAG_INIT, sizeof(DOMAIN_TAG_INIT) - 1);

  for (int i = 0; i < 64; i++) {
    uint16_t vcc = ESP.getVcc();
    uint32_t cyc = ESP.getCycleCount();
    br_hmac_update(&hctx, &vcc, sizeof(vcc));
    br_hmac_update(&hctx, &cyc, sizeof(cyc));
    delayMicroseconds(17 + (cyc & 0x0F));
  }

  br_hmac_out(&hctx, state_key);

  // Wipe temporary init contexts
  secure_zero(&kc, sizeof(kc));
  secure_zero(&hctx, sizeof(hctx));
}

void loop() {
  uint32_t transitions = 0;
  uint32_t lag2_matches = 0;
  uint32_t ones_count = 0;
  uint8_t bit_history = 0;

  uint16_t min_vcc = 0xFFFF;
  uint16_t max_vcc = 0;

  // Continuous health tests (RCT + APT) state
  uint8_t  rct_last_bit = 0;
  uint32_t rct_run_len  = 0;
  uint32_t apt_pos      = 0;   // position within the current APT_WINDOW
  uint32_t apt_ones     = 0;   // ones counted in the current window
  bool     hc_failed    = false;

  // Collect 1024 bytes (8192 bits) of raw physical entropy
  for (int i = 0; i < RAW_BUFFER_SIZE; i++) {
    uint8_t sample_byte = 0;

    for (int bit = 0; bit < 8; bit++) {
      uint16_t vcc = ESP.getVcc();
      if (vcc < min_vcc) min_vcc = vcc;
      if (vcc > max_vcc) max_vcc = vcc;

      uint32_t c1 = ESP.getCycleCount();

      // Non-periodic delay depending on previous sample (breaks 50/60 Hz mains harmonics)
      delayMicroseconds(10 + ((vcc ^ c1) & 0x1F));

      uint32_t c2 = ESP.getCycleCount();

      // Mix lower bits of Vcc, cycle delta, and shifts
      uint8_t entropy_bit = (vcc ^ (vcc >> 1) ^ (c2 - c1) ^ (c2 >> 2)) & 1;

      // Track lag-1 transitions and lag-2 matches (catches 101010... and 11001100... faults)
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

      // RCT: track consecutive identical bits
      if (entropy_bit == rct_last_bit) {
        rct_run_len++;
        if (rct_run_len >= RCT_CUTOFF) hc_failed = true;
      } else {
        rct_last_bit = entropy_bit;
        rct_run_len = 1;
      }

      // APT: count ones in non-overlapping 1024-bit windows
      apt_pos++;
      if (entropy_bit) apt_ones++;
      if (apt_pos == APT_WINDOW) {
        if (apt_ones > APT_HIGH || apt_ones < APT_LOW) hc_failed = true;
        apt_pos = 0;
        apt_ones = 0;
      }

      sample_byte = (sample_byte << 1) | entropy_bit;

      if (hc_failed) break;
    }

    if (hc_failed) break;

    raw_buffer[i] = sample_byte;
  }

  // Multi-stage Continuous Health Check (scaled for 8192 raw bits):
  // 0. RCT + APT (SP 800-90B-inspired): hc_failed flag raised during sampling
  // 1. ADC range check: (max_vcc - min_vcc) >= ADC_MIN_RANGE (live ADC fluctuations)
  // 2. Lag-1 transitions & Lag-2 pattern lock (~20% to ~80% of 8192 bits)
  // 3. Monobit bias bounds (25% to 75% of 8192 bits)
  if (hc_failed ||
      (uint16_t)(max_vcc - min_vcc) < ADC_MIN_RANGE ||
      transitions < 1600 || transitions > 6592 ||
      lag2_matches < 1600 || lag2_matches > 6592 ||
      ones_count < 2048 || ones_count > 6144) {
    secure_zero(raw_buffer, RAW_BUFFER_SIZE);
    return;
  }

  frame_counter++;

  br_hmac_key_context kc;
  br_hmac_context hctx;

  // Step 1: Rotate internal state_key using HMAC-SHA256 Extractor
  // state_key = HMAC-SHA256(state_key, DOMAIN_STEP || frame_counter || raw_buffer)
  br_hmac_key_init(&kc, &br_sha256_vtable, state_key, STATE_SIZE);
  br_hmac_init(&hctx, &kc, 0);
  br_hmac_update(&hctx, DOMAIN_TAG_STEP, sizeof(DOMAIN_TAG_STEP) - 1);
  br_hmac_update(&hctx, &frame_counter, sizeof(frame_counter));
  br_hmac_update(&hctx, raw_buffer, RAW_BUFFER_SIZE);
  br_hmac_out(&hctx, state_key);

  // Immediately wipe raw entropy buffer from RAM
  secure_zero(raw_buffer, RAW_BUFFER_SIZE);

  // Discard the very first cold-start block after power-on
  if (!is_warmed_up) {
    is_warmed_up = true;
    secure_zero(&kc, sizeof(kc));
    secure_zero(&hctx, sizeof(hctx));
    return;
  }

  // Step 2: Derive independent output block (Forward Secrecy / State Separation)
  // output_block = HMAC-SHA256(state_key, DOMAIN_OUT || frame_counter)
  uint8_t output_block[STATE_SIZE];
  br_hmac_key_init(&kc, &br_sha256_vtable, state_key, STATE_SIZE);
  br_hmac_init(&hctx, &kc, 0);
  br_hmac_update(&hctx, DOMAIN_TAG_OUT, sizeof(DOMAIN_TAG_OUT) - 1);
  br_hmac_update(&hctx, &frame_counter, sizeof(frame_counter));
  br_hmac_out(&hctx, output_block);

  // Transmit 32 bytes of conditioned entropy to CP2102
  Serial.write(output_block, STATE_SIZE);

  // Wipe output buffer and HMAC contexts from RAM
  secure_zero(output_block, sizeof(output_block));
  secure_zero(&kc, sizeof(kc));
  secure_zero(&hctx, sizeof(hctx));
}
