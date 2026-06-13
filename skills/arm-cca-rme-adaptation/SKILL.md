---
name: arm-cca-rme-adaptation
description: >
  Guide VMM (Virtual Machine Monitor) developers through adapting ARM CCA
  (Confidential Compute Architecture) RME (Realm Management Extension) support.
  Covers the full adaptation surface: KVM interface, realm lifecycle, memory
  management, measurement/attestation, boot flow, device assignment, and
  migration. Based on Jean-Philippe Brucker's upstream QEMU patch series.
  Use this skill whenever: adding CCA/RME/realm support to a VMM, integrating
  ARM confidential computing, working with KVM_CAP_ARM_RME, implementing realm
  VM creation, adapting boot flow for confidential guests, or any task involving
  ARM CCA RME virtualization. Also trigger when user mentions "realm VM",
  "confidential VM on ARM", "RME support", "CCA adaptation", "granule
  protection", "RIPAS", "REC", or "realm activation".
---

# ARM CCA RME VMM Adaptation Guide

## What is ARM CCA RME?

ARM CCA (Confidential Compute Architecture) introduces a new security state —
**Realm** — that allows VMs to run with memory and CPU state protected from the
hypervisor. RME (Realm Management Extension) is the hardware feature set that
enables this. The key actors are:

- **RMM** (Realm Management Monitor): Firmware at EL3 that manages granule
  protection and realm state
- **KVM**: The hypervisor kernel module that exposes RME to userspace via ioctls
- **VMM** (QEMU, Cloud Hypervisor, etc.): Userspace component that orchestrates
  realm VM creation, memory population, and activation

A VMM adapting CCA must coordinate with KVM through a well-defined ioctl
interface to create, configure, populate, and activate Realm VMs.

## Adaptation Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│                    VMM (Userspace)                    │
│  ┌──────────┐  ┌──────────┐  ┌───────────────────┐  │
│  │ Realm    │  │ Memory   │  │ Measurement/      │  │
│  │ Config   │  │ Populate │  │ Attestation Log   │  │
│  └────┬─────┘  └────┬─────┘  └────────┬──────────┘  │
│       │              │                 │              │
│       └──────────────┼─────────────────┘              │
│                      │ KVM ioctls                     │
├──────────────────────┼────────────────────────────────┤
│              KVM (Kernel)                             │
│       KVM_CAP_ARM_RME interface                       │
├───────────────────────────────────────────────────────┤
│              RMM (EL3 Firmware)                       │
│       Granule Protection Table (GPT)                  │
└───────────────────────────────────────────────────────┘
```

## The 8 Adaptation Layers

Every VMM adapting CCA RME must implement these 8 layers. They are ordered by
dependency — each layer builds on the previous ones.

### Layer 1: KVM Capability Detection

Before anything else, detect whether KVM supports RME:

```c
if (!kvm_check_extension(kvm_state, KVM_CAP_ARM_RME)) {
    // RME not available, fall back to normal VM
    return -ENODEV;
}
```

`KVM_CAP_ARM_RME` (value 300) is the single capability that gates all RME
functionality. If it's absent, no RME operations are possible.

### Layer 2: VM Type Selection

RME requires creating the VM with a special type flag:

```c
#define KVM_VM_TYPE_ARM_REALM  KVM_VM_TYPE_ARM(1)

// When creating the VM:
vm_type = is_realm_vm ? KVM_VM_TYPE_ARM_REALM : 0;
vmfd = ioctl(kvmfd, KVM_CREATE_VM, ipa_size | vm_type);
```

The VM type tells KVM to create a Realm Descriptor (RD) instead of a normal VM.
This must be decided at VM creation time — you cannot convert a running VM into a
realm.

**IPA address space consideration**: RME uses the upper GPA bit to differentiate
Realm from Non-Secure memory. Reserve one extra bit:

```c
if (rme_enabled) {
    rme_reserve_bit = 1;
    requested_pa_size = 64 - clz64(highest_gpa) + rme_reserve_bit;
}
```

### Layer 3: vCPU Initialization (REC)

Each vCPU in a realm VM must be initialized as a **REC** (Realm Execution
Context) instead of a normal vCPU:

```c
#define KVM_ARM_VCPU_REC  /* feature bit for realm vCPU */

// During vCPU init:
if (rme_enabled) {
    cpu->kvm_init_features[0] |= (1 << KVM_ARM_VCPU_REC);
}
```

After the boot PC and registers are set, finalize each REC:

```c
CPU_FOREACH(cs) {
    ret = kvm_arm_vcpu_finalize(cs, KVM_ARM_VCPU_REC);
}
```

**Important**: Realm vCPUs have restricted register access. The VMM cannot
freely read/write all CPU registers — only the core GPRs and PC are accessible
via special KVM interfaces. Skip normal register synchronization for realm vCPUs.

### Layer 4: Realm Configuration

Before creating the realm, configure its security parameters:

```c
struct arm_rme_config args;

// 1. Realm Personalization Value (RPV) — 64 bytes, base64-encoded
args.cfg = ARM_RME_CONFIG_RPV;
memcpy(args.rpv, guest_rpv, ARM_RME_CONFIG_RPV_SIZE);
kvm_vm_enable_cap(kvm_state, KVM_CAP_ARM_RME, 0,
                  KVM_CAP_ARM_RME_CONFIG_REALM, (intptr_t)&args);

// 2. Measurement hash algorithm
args.cfg = ARM_RME_CONFIG_HASH_ALGO;
args.hash_algo = ARM_RME_CONFIG_MEASUREMENT_ALGO_SHA512; // or SHA256
kvm_vm_enable_cap(kvm_state, KVM_CAP_ARM_RME, 0,
                  KVM_CAP_ARM_RME_CONFIG_REALM, (intptr_t)&args);
```

The RPV allows the VM owner to bind the realm to a specific identity. The
measurement algorithm determines how the Realm Initial Measurement (RIM) is
computed.

### Layer 5: Realm Creation and Memory Management

This is the most complex layer. The sequence is:

1. **Create Realm Descriptor**
2. **Initialize RIPAS** (Realm IPA Space) — declare the RAM range
3. **Populate** — load images and mark pages as measured
4. **Activate** — transition to running state

```c
// Step 1: Create the realm
kvm_vm_enable_cap(kvm_state, KVM_CAP_ARM_RME, 0,
                  KVM_CAP_ARM_RME_CREATE_REALM);

// Step 2: Initialize RIPAS for the main RAM region
struct arm_rme_init_ripas init_args = {
    .base = QEMU_ALIGN_DOWN(ram_base, PAGE_SIZE),
    .size = QEMU_ALIGN_UP(ram_end, PAGE_SIZE) - init_args.base,
};
kvm_vm_enable_cap(kvm_state, KVM_CAP_ARM_RME, 0,
                  KVM_CAP_ARM_RME_INIT_RIPAS_REALM, (intptr_t)&init_args);

// Step 3: Populate each loaded image region (kernel, initrd, firmware, DTB)
struct arm_rme_populate_realm pop_args = {
    .base = QEMU_ALIGN_DOWN(image_base, PAGE_SIZE),
    .size = QEMU_ALIGN_UP(image_end, PAGE_SIZE) - pop_args.base,
    .flags = KVM_ARM_RME_POPULATE_FLAGS_MEASURE,
};
kvm_vm_enable_cap(kvm_state, KVM_CAP_ARM_RME, 0,
                  KVM_CAP_ARM_RME_POPULATE_REALM, (intptr_t)&pop_args);

// Step 4: Activate the realm
kvm_vm_enable_cap(kvm_state, KVM_CAP_ARM_RME, 0,
                  KVM_CAP_ARM_RME_ACTIVATE_REALM);
kvm_mark_guest_state_protected();
```

**Memory alignment**: All addresses must be page-aligned. The RMM manages memory
at granule granularity (typically 4KB or 16KB pages).

**ROM load notification**: Use a notifier to track when images are loaded into
guest memory, then populate those regions. Sort regions by GPA to ensure
deterministic measurement.

For detailed KVM interface definitions, see `references/kvm-interface.md`.

### Layer 6: Measurement and Attestation

CCA uses a TPM-style event log to record what was measured into the realm:

1. **Log realm creation parameters** (IPA bits, SVE, PMU, breakpoints, hash algo)
2. **Log each image** (firmware, kernel, initrd, DTB) with its type and content
3. **Log RIPAS initialization** (which memory ranges were declared as RAM)
4. **Log REC creation** (initial PC, GPRs, runnable flag)
5. **Close the log** and populate it into guest memory (unmeasured)

The event log uses TCG (Trusted Computing Group) standard event types:
- `TCG_EV_NO_ACTION` — VMM version info
- `TCG_EV_EVENT_TAG` — Tagged events (realm create, RIPAS, REC)
- `TCG_EV_POST_CODE2` — Loaded images (kernel, initrd, DTB)
- `TCG_EV_EFI_PLATFORM_FIRMWARE_BLOB2` — Firmware blob

A verifier can independently calculate the RIM by replaying the log.

### Layer 7: Boot Flow Adaptation

Confidential VMs require significant boot flow changes:

1. **No bootloader**: Skip the normal ARM bootloader setup. The firmware runs
   directly and handles its own boot protocol.

2. **Firmware in RAM**: Instead of flash (pflash), load firmware into a RAM
   region so it can be measured and remains private:
   ```c
   // Create RAM region at flash address instead of using pflash
   fw_ram = memory_region_init_ram(NULL, "fw_ram", fw_size, NULL);
   memory_region_add_subregion(sysmem, fw_base, fw_ram);
   ```

3. **DTB handling**: Load DTB as-is (no randomness) for confidential VMs. The
   DTB is measured, so any modification would break attestation.

4. **Skip DTB randomness**: Normal VMs add randomness to DTB for security;
   confidential VMs skip this because the DTB is part of the measurement.

### Layer 8: Device Assignment and Migration

**Device Assignment (CCA-DA)**:
- RME VMs can have devices assigned via VFIO
- KVM exits with `KVM_EXIT_ARM_RME_DEV` when device assignment setup is needed
- The VMM resolves the guest BDF to host BDF and passes it to KVM
- For SMMU/IOMMU scenarios, map RAM ranges for DMA using
  `KVM_CAP_ARM_RME_MAP_RAM_HISI_CCA`

**Migration**:
- Migration is **not supported** — add a migration blocker

**Reset**: Realm VMs cannot be reset. Block CPU reset checks:
```c
if (kvm_arm_rme_enabled()) {
    return false; // CPUs are not resettable
}
```

## QOM Object Pattern

The confidential guest object follows the QOM pattern:

```c
// Define the type
#define TYPE_RME_GUEST "rme-guest"
OBJECT_DECLARE_SIMPLE_TYPE(RmeGuest, RME_GUEST)

// Inherit from ConfidentialGuestSupport
struct RmeGuest {
    ConfidentialGuestSupport parent_obj;
    // ... realm-specific fields
};

// Register with interfaces
OBJECT_DEFINE_SIMPLE_TYPE_WITH_INTERFACES(RmeGuest, rme_guest, RME_GUEST,
    CONFIDENTIAL_GUEST_SUPPORT, { TYPE_USER_CREATABLE }, { })
```

The user creates this object and passes it to the machine:
```bash
qemu-system-aarch64 \
  -object rme-guest,id=cgs0,measurement-algorithm=sha512 \
  -machine virt,confidential-guest-support=cgs0
```

## Deferred Activation Pattern

Realm activation must happen **after** all images are loaded and all vCPUs are
finalized. Use a VM state change handler:

```c
static void rme_vm_state_change(void *opaque, bool running, RunState state) {
    if (!running) return;
    // All images loaded, all vCPUs finalized — now create and activate realm
    rme_create_realm(&err);
}

// Register during init:
qemu_add_vm_change_state_handler(rme_vm_state_change, NULL);
```

This ensures the measurement covers the complete initial state.

## Adaptation Checklist

When adapting a new VMM for CCA RME, work through this checklist:

- [ ] **KVM headers**: Import `KVM_CAP_ARM_RME` definitions and structs
- [ ] **Capability check**: Detect `KVM_CAP_ARM_RME` at startup
- [ ] **VM creation**: Pass `KVM_VM_TYPE_ARM_REALM` to `KVM_CREATE_VM`
- [ ] **IPA sizing**: Reserve upper GPA bit for realm/NS differentiation
- [ ] **vCPU init**: Set `KVM_ARM_VCPU_REC` feature, finalize after boot setup
- [ ] **Register access**: Implement restricted get/put for realm vCPUs
- [ ] **Configuration**: Set RPV and measurement algorithm
- [ ] **Realm create**: Call `KVM_CAP_ARM_RME_CREATE_REALM`
- [ ] **RIPAS init**: Declare RAM ranges via `INIT_RIPAS_REALM`
- [ ] **Image loading**: Track ROM loads, populate with `MEASURE` flag
- [ ] **Measurement log**: Implement TPM-style event log (optional but recommended)
- [ ] **Firmware boot**: Load firmware into RAM, skip bootloader
- [ ] **DTB handling**: Load as-is, disable randomness
- [ ] **Activation**: Call `ACTIVATE_REALM` after all setup complete
- [ ] **Migration blocker**: Block migration
- [ ] **Reset blocker**: Prevent CPU reset for realm VMs
- [ ] **Device assignment**: Handle `KVM_EXIT_ARM_RME_DEV` exits (optional)

## Reference Files

- `references/kvm-interface.md` — Complete KVM ioctl definitions, structs, and
  constants for CCA RME. Read this when implementing the KVM interface layer.
- `references/lifecycle.md` — Detailed realm lifecycle state machine with
  sequencing diagrams. Read this when implementing the activation flow.
- `references/implementation-patterns.md` — Code patterns from QEMU's
  implementation including QOM registration, deferred activation, measurement
  log, and boot adaptation. Read this when writing the actual code.
