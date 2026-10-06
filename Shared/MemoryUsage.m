#include <mach/mach.h>
#include <stdint.h>
uint64_t phone_history_native_footprint(int peak) {
    task_vm_info_data_t info = {0};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    if (count < TASK_VM_INFO_REV1_COUNT) return 0;
    if (peak && count >= TASK_VM_INFO_REV3_COUNT) return info.ledger_phys_footprint_peak;
    return info.phys_footprint;
}
