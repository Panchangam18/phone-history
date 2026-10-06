#include <stdint.h>
typedef int32_t (*PhoneHistoryTunnelConnector)(const char *, uint16_t);
void phone_history_set_tunnel_connector(PhoneHistoryTunnelConnector connector);
char *phone_history_run_background(const char *pairing_path, const char *folder_path, const char *status_path);
char *phone_history_listener_probe(const char *config_path);
char *phone_history_vpn_ax_probe(const char *pairing_path, uint32_t hierarchy_read_limit, int32_t expected_pid);
char *phone_history_local_access_probe(void);
char *phone_history_ax_read_probe(int32_t target_pid);
void phone_history_local_access_free(char *text);
char *phone_history_pair(const char *ip, uint16_t port, const char *pairing_path);
char *phone_history_capture(const char *ip, uint16_t port, const char *pairing_path, const char *output_path, uint32_t seconds);
void phone_history_free(char *result);
void phone_history_stop(void);
char *phone_history_check_now(void);
char *phone_history_screenshot_now(void);
char *phone_history_transport_probe(const char *ip, uint16_t port);

typedef char *(*PhoneHistoryVisionReader)(const uint8_t *, uintptr_t, double);
void phone_history_set_vision_reader(PhoneHistoryVisionReader reader);
uint32_t phone_history_submit_memory(const char *row);

uint64_t phone_history_native_footprint(int peak);
