# KVM Interface Reference for ARM CCA RME

This document contains the complete KVM ioctl interface definitions needed for
CCA RME adaptation. Extracted from the openEuler QEMU fork's linux-headers.

## Table of Contents

1. [Capability and VM Type](#capability-and-vm-type)
2. [RME Sub-commands](#rme-sub-commands)
3. [RME Configuration Structs](#rme-configuration-structs)
4. [vCPU Features](#vcpu-features)
5. [KVM Exit Reasons](#kvm-exit-reasons)

---

## Capability and VM Type

### KVM_CAP_ARM_RME

```c
// linux/kvm.h
#define KVM_CAP_ARM_RME 300

// VM type for realm VMs
#define KVM_VM_TYPE_ARM_REALM  KVM_VM_TYPE_ARM(1)
```

Check with `kvm_check_extension(kvm_state, KVM_CAP_ARM_RME)`.

All RME operations use `kvm_vm_enable_cap()` with `KVM_CAP_ARM_RME` as the
capability, and a sub-command as the first argument.

---

## RME Sub-commands

All invoked via:
```c
kvm_vm_enable_cap(kvm_state, KVM_CAP_ARM_RME, 0, <SUB_COMMAND>, (intptr_t)&args);
```

| Sub-command | Value | Args struct | Description |
|---|---|---|---|
| `KVM_CAP_ARM_RME_CONFIG_REALM` | 0 | `struct arm_rme_config` | Configure realm parameters |
| `KVM_CAP_ARM_RME_CREATE_REALM` | 1 | none | Create Realm Descriptor |
| `KVM_CAP_ARM_RME_INIT_RIPAS_REALM` | 2 | `struct arm_rme_init_ripas` | Initialize IPA space |
| `KVM_CAP_ARM_RME_POPULATE_REALM` | 3 | `struct arm_rme_populate_realm` | Populate memory pages |
| `KVM_CAP_ARM_RME_ACTIVATE_REALM` | 4 | none | Activate the realm |
| `KVM_CAP_ARM_RME_MAP_RAM_HISI_CCA` | 5 | `struct kvm_cap_arm_rme_map_ram_args` | Map RAM for DMA (HiSi CCA) |

### Configuration Items (for CONFIG_REALM)

| Config item | Value | Description |
|---|---|---|
| `ARM_RME_CONFIG_RPV` | 0 | Realm Personalization Value |
| `ARM_RME_CONFIG_HASH_ALGO` | 1 | Measurement hash algorithm |
| `ARM_RME_CONFIG_HISI_CCA` | 2 | HiSi CCA extension enable |

### Measurement Algorithms

| Algorithm | Value |
|---|---|
| `ARM_RME_CONFIG_MEASUREMENT_ALGO_SHA256` | 0 |
| `ARM_RME_CONFIG_MEASUREMENT_ALGO_SHA512` | 1 |

---

## RME Configuration Structs

### arm_rme_config

```c
#define ARM_RME_CONFIG_RPV_SIZE 64

struct arm_rme_config {
    __u32 cfg;
    union {
        /* cfg == ARM_RME_CONFIG_RPV */
        struct {
            __u8 rpv[ARM_RME_CONFIG_RPV_SIZE];
        };

        /* cfg == ARM_RME_CONFIG_HASH_ALGO */
        struct {
            __u32 hash_algo;
        };

        /* cfg == ARM_RME_CONFIG_HISI_CCA */
        struct {
            __u8 hisi_cca_enable;
        };

        __u8 reserved[256];
    };
};
```

### arm_rme_init_ripas

Declares the IPA range that will be used as Realm RAM:

```c
struct arm_rme_init_ripas {
    __u64 base;       // Page-aligned start address
    __u64 size;       // Page-aligned size
    __u64 reserved[2];
};
```

### arm_rme_populate_realm

Populates (and optionally measures) a memory range:

```c
#define KVM_ARM_RME_POPULATE_FLAGS_MEASURE  (1 << 0)

struct arm_rme_populate_realm {
    __u64 base;       // Page-aligned start address
    __u64 size;       // Page-aligned size
    __u32 flags;      // KVM_ARM_RME_POPULATE_FLAGS_MEASURE to include in RIM
    __u32 reserved[3];
};
```

When `MEASURE` flag is set, the page contents are included in the Realm Initial
Measurement (RIM). Use this for kernel, initrd, firmware, DTB. Omit for the
measurement log itself.

### kvm_cap_arm_rme_map_ram_args

For HiSi CCA DMA remapping:

```c
struct kvm_cap_arm_rme_map_ram_args {
    __u64 ram_base;
    __u64 ram_size;
    __u32 reserved[4];
};
```

---

## vCPU Features

### KVM_ARM_VCPU_REC

```c
// Set during vCPU initialization to create a Realm Execution Context
cpu->kvm_init_features[0] |= (1 << KVM_ARM_VCPU_REC);
```

### vCPU Finalization

After boot PC and registers are set:

```c
kvm_arm_vcpu_finalize(cs, KVM_ARM_VCPU_REC);
```

### Register Access Restrictions

Realm vCPUs only expose core registers (GPRs + PC) via special KVM interfaces.
Normal `KVM_GET_REGS` / `KVM_SET_REGS` may not work for all registers.

In QEMU, this is handled by:
- `kvm_arm_rme_get_core_regs()` — read core registers from realm vCPU
- `kvm_arm_rme_put_core_regs()` — write core registers to realm vCPU

Skip normal ID register writable synchronization for realm vCPUs.

---

## KVM Exit Reasons

### KVM_EXIT_ARM_RME_DEV

```c
case KVM_EXIT_ARM_RME_DEV:
    // Host BDF resolution for VFIO passthrough
    run->rme_dev.vfio_dev = get_vfio_dev_bdf(
        run->rme_dev.guest_dev_bdf, &run->rme_dev.dev_bdf);
    break;
```

This exit occurs when a realm VM needs device assignment setup. The VMM must
resolve the guest BDF to a host BDF for VFIO.


