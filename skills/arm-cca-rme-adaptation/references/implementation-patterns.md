# Implementation Patterns Reference

Code patterns extracted from QEMU's CCA RME implementation (Jean-Philippe
Brucker's upstream series). Use these as templates when adapting your VMM.

## Table of Contents

1. [QOM Object Registration](#qom-object-registration)
2. [Confidential Guest Support Integration](#confidential-guest-support-integration)
3. [ROM Load Notification](#rom-load-notification)
4. [Measurement Log Implementation](#measurement-log-implementation)
5. [Boot Flow Adaptation](#boot-flow-adaptation)
6. [Register Access for Realm vCPUs](#register-access-for-realm-vcpus)
7. [Migration Blocker](#migration-blocker)
8. [Device Assignment Handler](#device-assignment-handler)
9. [QAPI Schema Definitions](#qapi-schema-definitions)
10. [Command Line Usage](#command-line-usage)

---

## QOM Object Registration

### RME Guest (Community/Upstream Pattern)

```c
#define TYPE_RME_GUEST "rme-guest"
OBJECT_DECLARE_SIMPLE_TYPE(RmeGuest, RME_GUEST)

struct RmeGuest {
    ConfidentialGuestSupport parent_obj;
    Notifier rom_load_notifier;
    GSList *ram_regions;

    char *personalization_value_str;
    uint8_t personalization_value[ARM_RME_CONFIG_RPV_SIZE];
    RmeGuestMeasurementAlgorithm measurement_algo;
    bool use_measurement_log;
    bool hisi_cca_enable;

    RmeRamRegion init_ram;
    uint8_t ipa_bits;
    size_t num_cpus;

    TpmLog *log;
    GHashTable *images;
};

OBJECT_DEFINE_SIMPLE_TYPE_WITH_INTERFACES(RmeGuest, rme_guest, RME_GUEST,
    CONFIDENTIAL_GUEST_SUPPORT, { TYPE_USER_CREATABLE }, { })

static void rme_guest_class_init(ObjectClass *oc, void *data) {
    // Add properties: personalization-value, measurement-algorithm,
    // measurement-log, hisi-cca-enable
    object_class_property_add_str(oc, "personalization-value",
                                  rme_get_rpv, rme_set_rpv);
    object_class_property_add_enum(oc, "measurement-algorithm",
        "RmeGuestMeasurementAlgorithm",
        &RmeGuestMeasurementAlgorithm_lookup,
        rme_get_measurement_algo, rme_set_measurement_algo);
    object_class_property_add_bool(oc, "measurement-log",
        rme_get_measurement_log, rme_set_measurement_log);
}

static void rme_guest_init(Object *obj) {
    if (rme_guest) {
        error_report("a single instance of RmeGuest is supported");
        exit(1);
    }
    rme_guest = RME_GUEST(obj);
    rme_guest->measurement_algo = RME_GUEST_MEASUREMENT_ALGORITHM_SHA512;
}
```

---

## Confidential Guest Support Integration

### Machine init integration:

```c
int kvm_arm_rme_init(MachineState *ms) {
    static Error *rme_mig_blocker;
    ConfidentialGuestSupport *cgs = ms->cgs;

    if (!rme_guest) return 0;

    if (!cgs) {
        error_report("missing -machine confidential-guest-support parameter");
        return -EINVAL;
    }

    if (!kvm_check_extension(kvm_state, KVM_CAP_ARM_RME)) {
        return -ENODEV;
    }

    // Initialize measurement log
    rme_init_measurement_log(ms);

    rme_guest->num_cpus = ms->smp.max_cpus;

    // Block migration
    error_setg(&rme_mig_blocker, "RME: migration is not implemented");
    migrate_add_blocker(&rme_mig_blocker, &error_fatal);

    // Register deferred activation
    qemu_add_vm_change_state_handler(rme_vm_state_change, NULL);

    // Register ROM load notifier
    rme_guest->rom_load_notifier.notify = rme_rom_load_notify;
    rom_add_load_notifier(&rme_guest->rom_load_notifier);

    cgs->ready = true;
    return 0;
}
```

### Called from kvm_arch_init():

```c
// In target/arm/kvm.c:
ret = kvm_arm_rme_init(ms);
if (ret) {
    error_report("Failed to enable RME: %s", strerror(-ret));
}
```

---

## ROM Load Notification

### Registering the notifier:

```c
// In hw/core/loader.c — add a load notifier mechanism:
void rom_add_load_notifier(Notifier *notifier) {
    // Called when each ROM/image is loaded into guest memory
}
```

### Handling load events:

```c
static void rme_rom_load_notify(Notifier *notifier, void *data) {
    RmeRamRegion *region;
    RomLoaderNotifyData *rom = data;

    if (rom->addr == -1) {
        // ACPI tables — loaded by firmware via fw_cfg, measured by firmware
        return;
    }

    region = g_new0(RmeRamRegion, 1);
    region->base = QEMU_ALIGN_DOWN(rom->addr, RME_PAGE_SIZE);
    region->size = QEMU_ALIGN_UP(rom->addr + rom->len, RME_PAGE_SIZE)
                   - region->base;
    region->blob_ptr = rom->blob_ptr;

    // Look up image type from registered filenames
    if (rme_guest->images) {
        region->filetype = g_hash_table_lookup(rme_guest->images, rom->name);
    }

    // Sort by GPA for deterministic RIM calculation
    rme_guest->ram_regions = g_slist_insert_sorted(
        rme_guest->ram_regions, region, rme_compare_ram_regions);
}
```

### Image type registration:

```c
// Register expected images before loading starts:
filename = g_strdup(ms->kernel_filename);
if (filename) {
    filetype = g_new0(RmeLogFiletype, 1);
    filetype->event_type = TCG_EV_POST_CODE2;
    filetype->desc = "KERNEL";
    g_hash_table_insert(rme_guest->images, filename, filetype);
}
// Repeat for initrd, firmware, DTB...
```

---

## Measurement Log Implementation

### Log structure:

The measurement log uses TPM event log format with these event types:

| Event Type | Value | Used For |
|---|---|---|
| `TCG_EV_NO_ACTION` | 3 | VMM version info |
| `TCG_EV_EVENT_TAG` | 6 | Realm create, RIPAS, REC |
| `TCG_EV_POST_CODE2` | 0x8000000D | Kernel, initrd, DTB |
| `TCG_EV_EFI_PLATFORM_FIRMWARE_BLOB2` | 0x8000000A | Firmware |

### Event tag format:

```c
#define EVENT_LOG_TAG_REALM_CREATE  1
#define EVENT_LOG_TAG_INIT_RIPAS    2
#define EVENT_LOG_TAG_REC_CREATE    3

typedef struct {
    uint32_t id;
    uint32_t data_size;
    uint8_t  data[];
} EventLogTagged;
```

### Realm creation event:

```c
static int rme_log_realm_create(Error **errp) {
    EventLogVmmVersion vmm_version = {
        .signature = "VM VERSION",
        .name = "QEMU",
        .version = QEMU_VERSION,
        .ram_size = cpu_to_le64(rme_guest->init_ram.size),
        .num_cpus = cpu_to_le32(rme_guest->num_cpus),
    };

    // Log VMM version as EV_NO_ACTION
    tpm_log_add_event(rme_guest->log, TCG_EV_NO_ACTION,
                      (uint8_t *)&vmm_version, sizeof(vmm_version),
                      NULL, 0, errp);

    // Log realm parameters as EVENT_TAG
    struct { uint64_t flags; uint8_t s2sz; uint8_t sve_vl;
             uint8_t num_bps; uint8_t num_wps; uint8_t pmu_num_ctrs;
             uint8_t hash_algo; } params = { .s2sz = rme_guest->ipa_bits };
    // Fill params from CPU capabilities...

    rme_log_event_tag(EVENT_LOG_TAG_REALM_CREATE,
                      (uint8_t *)&params, sizeof(params), errp);
}
```

### Closing the log:

```c
static int rme_close_measurement_log(Error **errp) {
    // 1. Log the log itself (so verifier knows its location)
    rme_log_image(&log_filetype, NULL, log_base, log_size, errp);

    // 2. Write and close the TPM log
    tpm_log_write_and_close(rme_guest->log, errp);

    // 3. Populate the log region WITHOUT measuring
    //    (log contents depend on measurement, creating a chicken-and-egg)
    rme_populate_range(log_base, log_size, /* measure */ false, errp);

    // 4. Free the log object
    object_unparent(OBJECT(rme_guest->log));
    rme_guest->log = NULL;
}
```

---

## Boot Flow Adaptation

### Firmware in RAM (not flash):

```c
static bool virt_confidential_firmware_init(VirtMachineState *vms,
                                            MemoryRegion *sysmem) {
    MemoryRegion *fw_ram;
    hwaddr fw_base = vms->memmap[VIRT_FLASH].base;
    hwaddr fw_size = vms->memmap[VIRT_FLASH].size;

    if (!MACHINE(vms)->firmware) return false;

    // Create RAM at flash address instead of using pflash
    fw_ram = g_new(MemoryRegion, 1);
    memory_region_init_ram(fw_ram, NULL, "fw_ram", fw_size, NULL);
    memory_region_add_subregion(sysmem, fw_base, fw_ram);
    return true;
}
```

### Skip bootloader:

```c
// In hw/arm/boot.c:
if (info->confidential) {
    arm_setup_confidential_firmware_boot(cpu, info, firmware_filename);
    // Skip normal bootloader setup
}
```

### DTB handling:

```c
// Load DTB as-is for confidential VMs (no randomness)
if (binfo->dtb_filename && binfo->confidential) {
    // DTB is already loaded by the ROM loader
    // Don't modify it — it's part of the measurement
}
```

### Disable DTB randomness:

```c
// In hw/arm/virt.c:
if (virt_machine_is_confidential(vms)) {
    // Skip DTB randomness for confidential VMs
    // Randomness would break attestation
}
```

---

## Register Access for Realm vCPUs

### Conditional register sync:

```c
// In kvm64.c — kvm_arch_put_registers:
if (cpu->kvm_rme) {
    return kvm_arm_rme_put_core_regs(cs);
}
// Normal register put for non-realm vCPUs...

// In kvm64.c — kvm_arch_get_registers:
if (cpu->kvm_rme) {
    return kvm_arm_rme_get_core_regs(cs);
}
// Normal register get for non-realm vCPUs...
```

### Skip ID register sync:

```c
// In kvm_arch_init_vcpu:
if (cpu->kvm_rme) {
    return 0;  // Skip writable ID register sync
}
// Normal ID register handling...
```

---

## Migration Blocker

```c
int kvm_arm_rme_init(MachineState *ms) {
    static Error *rme_mig_blocker;

    error_setg(&rme_mig_blocker, "RME: migration is not implemented");
    migrate_add_blocker(&rme_mig_blocker, &error_fatal);
}
```

### Reset blocker:

```c
bool kvm_arch_cpu_check_are_resettable(void) {
    if (kvm_arm_rme_enabled()) return false;
    return true;
}
```

---

## Device Assignment Handler

```c
int kvm_arm_handle_rme_dev(CPUState *cs, struct kvm_run *run) {
    ARMCPU *cpu = ARM_CPU(cs);

    if (!cpu->kvm_rme) return -EINVAL;

    // Resolve guest BDF to host BDF for VFIO passthrough
    run->rme_dev.vfio_dev = get_vfio_dev_bdf(
        run->rme_dev.guest_dev_bdf, &run->rme_dev.dev_bdf);
    return 0;
}

// In kvm_arch_handle_exit:
case KVM_EXIT_ARM_RME_DEV:
    ret = kvm_arm_handle_rme_dev(cs, run);
    break;
```

---

## QAPI Schema Definitions

### RME Guest Properties (qapi/qom.json):

```json
{
  "enum": "RmeGuestMeasurementAlgorithm",
  "data": ["sha256", "sha512"]
}

{
  "struct": "RmeGuestProperties",
  "data": {
    "*personalization-value": "str",
    "*measurement-algorithm": "RmeGuestMeasurementAlgorithm",
    "*measurement-log": "bool",
    "*hisi-cca-enable": "bool"
  }
}
```

### QOM type registration:

```json
// In the ObjectType enum:
"rme-guest"

// In the ObjectType -> Properties mapping:
"rme-guest": "RmeGuestProperties"
```

---

## Command Line Usage

### Standard RME VM:

```bash
qemu-system-aarch64 \
  -M virt,confidential-guest-support=cgs0 \
  -object rme-guest,id=cgs0,\
    measurement-algorithm=sha512,\
    measurement-log=on,\
    personalization-value=$(base64 < /dev/urandom | head -c 88) \
  -cpu host \
  -smp 4 \
  -m 4G \
  -bios edk2-aarch64-code.fd \
  -kernel Image \
  -initrd initrd.img \
  -append "root=/dev/vda console=ttyAMA0"
```

### RME VM with HiSi CCA (DMA support):

```bash
qemu-system-aarch64 \
  -M virt,confidential-guest-support=cgs0,iommu=smmuv3 \
  -object rme-guest,id=cgs0,\
    hisi-cca-enable=on \
  -device vfio-pci,host=0000:31:00.0
```
