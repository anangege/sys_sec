# Realm Lifecycle Reference

This document describes the complete realm VM lifecycle — from creation to
activation — with state machine diagrams and sequencing details.

## Table of Contents

1. [State Machine Overview](#state-machine-overview)
2. [Phase 1: Initialization](#phase-1-initialization)
3. [Phase 2: Configuration](#phase-2-configuration)
4. [Phase 3: Realm Creation](#phase-3-realm-creation)
5. [Phase 4: Memory Population](#phase-4-memory-population)
6. [Phase 5: CPU Finalization](#phase-5-cpu-finalization)
7. [Phase 6: Activation](#phase-6-activation)
8. [Deferred Activation Pattern](#deferred-activation-pattern)

---

## State Machine Overview

```
                    ┌──────────────┐
                    │   VM Create   │
                    │ (KVM_CREATE_VM│
                    │  with REALM)  │
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
                    │  vCPU Init    │
                    │ (REC feature) │
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
                    │  Configure    │
                    │ (RPV, Hash)   │
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
                    │ Create Realm  │
                    │  Descriptor   │
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
                    │  Init RIPAS   │
                    │ (declare RAM) │
                    └──────┬───────┘
                           │
              ┌────────────▼────────────┐
              │  Load Images & Populate │
              │  (kernel, initrd, fw,   │
              │   DTB, measurement log) │
              └────────────┬────────────┘
                           │
                    ┌──────▼───────┐
                    │ Finalize RECs │
                    │ (lock vCPUs)  │
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
                    │   Activate    │
                    │   Realm       │
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
                    │   Running     │
                    │  (protected)  │
                    └──────────────┘
```

**Critical constraint**: Activation must happen AFTER all images are loaded and
all vCPUs are finalized. The measurement (RIM) depends on the complete initial
state.

---

## Phase 1: Initialization

### When: VMM startup, before `KVM_CREATE_VM`

1. **Detect RME support**:
   ```c
   if (!kvm_check_extension(kvm_state, KVM_CAP_ARM_RME)) {
       return -ENODEV;
   }
   ```

2. **Create the confidential guest object** (QOM):
   - User passes `-object rme-guest,id=cgs0`
   - VMM stores the object reference and sets `cgs->ready = true`

3. **Compute IPA size with RME bit reservation**:
   ```c
   // Upper GPA bit differentiates Realm from NS memory
   if (rme_enabled) {
       rme_reserve_bit = 1;
       requested_pa_size = 64 - clz64(highest_gpa) + rme_reserve_bit;
   }
   ```

4. **Create VM with realm type**:
   ```c
   vmfd = ioctl(kvmfd, KVM_CREATE_VM, ipa_size | KVM_VM_TYPE_ARM_REALM);
   ```

5. **Initialize vCPUs with REC feature**:
   ```c
   cpu->kvm_init_features[0] |= (1 << KVM_ARM_VCPU_REC);
   ```

### Key decisions at this phase:
- Measurement algorithm (SHA-256 or SHA-512)
- Realm Personalization Value (RPV) — 64 bytes, typically base64-encoded
- Whether to enable measurement log

---

## Phase 2: Configuration

### When: After VM creation, before realm descriptor creation

Configure realm parameters via `KVM_CAP_ARM_RME_CONFIG_REALM`:

```c
// Iterate through configuration items:
const uint32_t config_options[] = {
    ARM_RME_CONFIG_RPV,
    ARM_RME_CONFIG_HASH_ALGO,
    ARM_RME_CONFIG_HISI_CCA,  // optional
};

for (option = 0; option < ARRAY_SIZE(config_options); option++) {
    rme_configure_one(rme_guest, config_options[option], errp);
}
```

Each configuration call:
```c
struct arm_rme_config args = { .cfg = cfg };
// Fill args based on cfg type...
kvm_vm_enable_cap(kvm_state, KVM_CAP_ARM_RME, 0,
                  KVM_CAP_ARM_RME_CONFIG_REALM, (intptr_t)&args);
```

### Measurement log initialization (optional but recommended):

Create a TPM-style event log before any measurements:
1. Create TPM log object with chosen digest algorithm
2. Register image name → filetype mappings (KERNEL, INITRD, FIRMWARE, DTB)
3. Log will be populated during the image loading phase

---

## Phase 3: Realm Creation

### When: After configuration, before memory population

Create the Realm Descriptor (RD) in KVM:

```c
ret = kvm_vm_enable_cap(kvm_state, KVM_CAP_ARM_RME, 0,
                        KVM_CAP_ARM_RME_CREATE_REALM);
```

After creation, log the realm parameters to the measurement log:
- IPA bits (s2sz)
- SVE vector length
- Number of breakpoints/watchpoints
- PMU counter count
- Hash algorithm

```c
rme_log_event_tag(EVENT_LOG_TAG_REALM_CREATE, &params, sizeof(params), errp);
```

---

## Phase 4: Memory Population

### When: After realm creation, during image loading

This phase has two sub-steps:

### 4a. Initialize RIPAS (Realm IPA Space)

Declare the total RAM range that the realm will use:

```c
struct arm_rme_init_ripas init_args = {
    .base = QEMU_ALIGN_DOWN(ram_base, RME_PAGE_SIZE),
    .size = QEMU_ALIGN_UP(ram_end, RME_PAGE_SIZE) - init_args.base,
};
kvm_vm_enable_cap(kvm_state, KVM_CAP_ARM_RME, 0,
                  KVM_CAP_ARM_RME_INIT_RIPAS_REALM, (intptr_t)&init_args);
```

Log the RIPAS initialization:
```c
rme_log_ripas(ram->base, ram->size, errp);
```

### 4b. Populate loaded images

As each image is loaded into guest memory, populate and measure it:

```c
struct arm_rme_populate_realm populate_args = {
    .base = QEMU_ALIGN_DOWN(image_base, RME_PAGE_SIZE),
    .size = QEMU_ALIGN_UP(image_end, RME_PAGE_SIZE) - populate_args.base,
    .flags = KVM_ARM_RME_POPULATE_FLAGS_MEASURE,
};
kvm_vm_enable_cap(kvm_state, KVM_CAP_ARM_RME, 0,
                  KVM_CAP_ARM_RME_POPULATE_REALM, (intptr_t)&populate_args);
```

**ROM load notification pattern**: Register a notifier that fires when each ROM
image is loaded. Collect all regions, sort by GPA (for deterministic
measurement), then populate in order:

```c
static void rme_rom_load_notify(Notifier *notifier, void *data) {
    RomLoaderNotifyData *rom = data;
    RmeRamRegion *region = g_new0(RmeRamRegion, 1);
    region->base = QEMU_ALIGN_DOWN(rom->addr, RME_PAGE_SIZE);
    region->size = QEMU_ALIGN_UP(rom->addr + rom->len, RME_PAGE_SIZE) - region->base;
    region->blob_ptr = rom->blob_ptr;
    // Insert sorted by GPA for deterministic RIM
    rme_guest->ram_regions = g_slist_insert_sorted(
        rme_guest->ram_regions, region, rme_compare_ram_regions);
}
```

**Images to populate and measure** (in GPA order):
1. Firmware (at flash base address, loaded as RAM)
2. Kernel image
3. Initrd
4. Device Tree Blob (DTB)

**Images to populate WITHOUT measuring**:
- Measurement log itself (populated after closing the log)

### DMA mapping (HiSi CCA only):

If IOMMU is present or HiSi CCA is enabled, map non-populated RAM ranges for DMA:
```c
if (ms->iommu || rme_guest->hisi_cca_enable) {
    rme_map_ram(init_ram.base, init_ram.size, ram_regions);
}
```

---

## Phase 5: CPU Finalization

### When: After all images loaded, before activation

Finalize each REC to lock in the initial CPU state:

```c
CPU_FOREACH(cs) {
    ARMCPU *cpu = ARM_CPU(cs);

    // Finalize the REC — locks the vCPU configuration
    ret = kvm_arm_vcpu_finalize(cs, KVM_ARM_VCPU_REC);

    // Log the primary CPU's initial state
    if (!logged_primary_cpu) {
        rme_log_rec(REC_CREATE_FLAG_RUNNABLE, cpu->env.pc,
                    cpu->env.xregs, errp);
        logged_primary_cpu = true;
    }
}
```

The REC finalization must happen AFTER `do_cpu_reset()` has initialized the boot
PC and `kvm_cpu_synchronize_post_reset()` has registered it with KVM.

---

## Phase 6: Activation

### When: After all population and CPU finalization

Close the measurement log and activate the realm:

```c
// 1. Close and populate the measurement log into guest memory
rme_close_measurement_log(errp);

// 2. Activate the realm — transitions to running state
ret = kvm_vm_enable_cap(kvm_state, KVM_CAP_ARM_RME, 0,
                        KVM_CAP_ARM_RME_ACTIVATE_REALM);

// 3. Mark guest state as protected
kvm_mark_guest_state_protected();
```

After activation:
- Guest memory is encrypted/protected
- CPU registers are restricted
- Migration is blocked (for standard RME)
- Reset is blocked

---

## Deferred Activation Pattern

The critical challenge is that activation must happen AFTER all setup is complete
but the VMM's initialization sequence loads images and creates vCPUs at different
times. The solution is **deferred activation via VM state change handler**:

```c
// During initialization (kvm_arm_rme_init):
qemu_add_vm_change_state_handler(rme_vm_state_change, NULL);

// The handler fires when the VM transitions to "running":
static void rme_vm_state_change(void *opaque, bool running, RunState state) {
    if (!running) return;

    // At this point:
    // - All ROM images have been loaded (notifiers fired)
    // - All vCPUs have been reset and synchronized
    // - Memory map is complete
    rme_create_realm(&err);
}
```

The `rme_create_realm()` function then executes the full sequence:
1. Configure (RPV, hash algo)
2. Create realm descriptor
3. Log realm creation
4. Init RIPAS
5. Populate all collected RAM regions
6. Map DMA ranges (if needed)
7. Finalize all RECs
8. Close measurement log
9. Activate realm

