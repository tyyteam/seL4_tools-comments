/*
 * Copyright 2020, Data61, CSIRO (ABN 41 687 119 230)
 *
 * SPDX-License-Identifier: GPL-2.0-only
 */

#include <autoconf.h>
#include <elfloader/gen_config.h>

.extern main
.extern __global_pointer$
.extern elfloader_stack_alloc
.extern hsm_exists

#define BIT(n) (1 << (n))

/* SBI commands */
#define SBI_HSM_BASE 0x48534DULL
#define SBI_HSM_BASE_HART_START 0
#define SBI_HSM_BASE_HART_STOP 1
#define SBI_EXT_BASE 0x10
#define SBI_EXT_BASE_PROBE_EXT 3

.section ".text.start"

/* OpenSBI starts us these parameters:
 *   a0: hart id
 *   a1: dtb
 *
 * On RISC-V, only M-Mode can access the CSR mhartid to get the actual hart ID,
 * the SBI running there is responsible for passing this ID up. In S-Mode there
 * is no way to ever query it again, so we have to preserve what we get passed
 * here. This is a RISC-V design decision, more background can be found at
 * https://github.com/riscv/riscv-sbi-doc/issues/25.
 * It seems that OpenSBI starts us at a random hart and keeps all other harts
 * suspended or spinning. However, even on non-SMP configurations there might
 * be an expectation that we are running on CONFIG_FIRST_HART_ID. If the current
 * hart turns out to be a different one, we have to switch harts somehow. The
 * SBI Heart State Management (HSM) extension exists for this, but it might not
 * be implemented. In this case, there is nothing we can do here in the assembly
 * startup code, but C boot code might still have platform specific proprietary
 * ways to switch harts.
 */

.global _start
_start:

.option push
.option norelax
1:auipc gp, %pcrel_hi(__global_pointer$)
  addi  gp, gp, %pcrel_lo(1b)
.option pop

  /*CY opensbi会把hart id 和 dtb地址放在a0和a1 */
  /* save the parameters passed */
  mv s0, a0 /* preserve a0 (hart id) in s0 */
  mv s2, a1 /* preserve a1 (dtb) in s2 */

  /* Attach the stack to sp before calling any C functions */
  la sp, (elfloader_stack_alloc + BIT(12))  /*CY elfloader_stack_alloc定义在boot.c中 */

/*CY elfloader如果是以image binary的形式装载 */
#ifdef CONFIG_IMAGE_BINARY
/* Clear the BSS before we get to do anything more specific */
  jal clear_bss
#endif

  /* Check if the Heart State Management (HSM) extension exists, so it can be
   * used to switch harts if we are not running on hart CONFIG_FIRST_HART_ID.
   * The SBI returns SBI_SUCCESS (0) in a0 if the call could be processed or an
   * error code if not. On SBI_SUCCESS the value in a1 is 0 if the extension is
   * not available or an extension-specific non-zero value if it is available.
   */
  li a7, SBI_EXT_BASE
  li a6, SBI_EXT_BASE_PROBE_EXT
  li a0, SBI_HSM_BASE
  ecall /* call SBI to probe for HSM extension */
  mv a2, a0 /* move SBI call generic return code to a2 as we need a0 */
  mv a3, a1 /* move SBI call error return code to a3 as we need a1 */
  mv a0, s0 /* restore a0 to hold hart ID passed by the boot loader */
  mv a1, s2 /* restore a1 to hold dtb address passed by the boot loader */
  bnez a2, _start1 /* goto _start1 if SBI did not return SBI_SUCCESS (0) */
  beqz a3, _start1 /* goto _start1 if HSM extension is missing */

  /* Update global bool variable to tell boot code the HSM extension exists. */
  la t1, hsm_exists  /*CY hsm_exists定义在boot.c中 */
  li t2, 1
  /*CY 将内存中hsm_exists这个变量的值+1 */
  amoadd.w t1, t2, (t1)  /*CY amoadd.w rd, rs2, (rs1) 进行如下的原子操作：将内存中地址为 x[rs1]中的字记为 t，把这个字变为 t+x[rs2]，把 x[rd] 设为符号位扩展的 t。 */

  /*  Check if we are on CONFIG_FIRST_HART_ID */
  li s1, CONFIG_FIRST_HART_ID
  beq  a0, s1, _start1 /* goto _start1 if we are on CONFIG_FIRST_HART_ID */

  /*CY 如果不在CONFIG_FIRST_HART_ID这个hart下运行要进行切换 */
  /* Use HSM extension to start hart CONFIG_FIRST_HART_ID. */
hsm_switch_hart:
  li a7, SBI_HSM_BASE
  li a6, SBI_HSM_BASE_HART_START  /*CY 执行HSM中 HART_START这个程序用来启动要切换的hart */
  li a0, CONFIG_FIRST_HART_ID /* hart id to start */
  mv a2, s2 /* dtb address to be passed in a1 when new hart starts is 3rd parameter */
  la a1, _start1 /* where to start the hart */
  ecall /* call SBI to start hart FIRST_HART_ID */

  /* Since we are not the designated primary hart, continue the boot process as
   * secondary hart
   */
  mv a0, s0 /* restore a0 to hold hart ID passed by OpenSBI */
  j secondary_harts

/*CY CONFIG_FIRST_HART_ID执行的启动代码 */
_start1: /* a0 must hold current hard ID passed by bootloader */
         /* a1 must hold dtb address passed by bootloader */
.option push
.option norelax
1:auipc gp, %pcrel_hi(__global_pointer$)
  addi  gp, gp, %pcrel_lo(1b)
.option pop

  /* Attach the stack to sp before calling any C functions */
  /* This HART may be a different HART to the one that started at _start
   * If we've switched HARTs then the other HART will get a different stack
   * region in secondary_harts. */
  la sp, (elfloader_stack_alloc + BIT(12))
  /* The C code expects the registers to be set up as:
   *   a0 = hart id
   *   a1 = dtb
   */
  la s0, main
  /*CY 这里跳转到main函数了，后面初始化其它核的代码就不会再继续执行了，而是通过c语言启动代码中再跳转过来（boot.c的sbi_hart_start） */
  jr s0  /*CY jr rs1 把 pc 设置为 x[rs1]，等同于 jalr x0, 0(rs1)。 */

#if CONFIG_MAX_NUM_NODES > 1
.extern next_logical_core_id  /*CY 定义在boot.c中，默认为1 */
.data  /*CY 接下来的代码存放在data段 */
/*CY 为其余的各个核开辟一块data段中的空间 */
bootstack_secondary_cores:
.align 12  /*CY 后续代码12字节对齐 */
.space 4096 * (CONFIG_MAX_NUM_NODES - 1)
#endif

.text  /*CY 接下来代码定义在text段 */

.global secondary_harts  /*CY secondary_harts声明为一个全局符号 */
secondary_harts:

.option push
.option norelax
1:auipc gp, %pcrel_hi(__global_pointer$)
  addi  gp, gp, %pcrel_lo(1b)
.option pop

#if CONFIG_MAX_NUM_NODES > 1
  la a1, next_logical_core_id  /*CY next_logical_core_id定义在boot.c中 */
  li t2, 1
  amoadd.w t0, t2, (a1)  /*CY next_logical_core_id++ */
  /* now a1 has the logical core id */
  li t2, CONFIG_MAX_NUM_NODES
  /*CY 当前hart id大于等于CONFIG_MAX_NUM_NODES时把当前hart挂起 */
  bge t0, t2, hsm_suspend_hart  /*CY bge rs1, rs2, offset 大于等于时分支；由上面的amoadd.w，此时t0中存的是（a1）中经过符号拓展的值，而a1中存的是变量next_logical_core_id的地址 */

  mv a1, t0  /*CY t0中存的是next_logical_core_id的值 */
  slli t0, t0, 12  /*CY slli rd, rs1, shamt 立即数逻辑左移， x[rd] = x[rs1] ≪ shamt */
  la sp, bootstack_secondary_cores  /*CY bootstack_secondary_cores定义在上面 */
  add sp, sp, t0  /*CY t0原来存的hart id在上面逻辑左移了12位，每个核占用data段大小为2^12B = 4KB */
  la s0, secondary_entry
  jr s0  /*CY 跳转到其它核的入口 */
#endif
/*CY 能执行到这里说明HSM extension肯定存在并且当前hart不再被使用了，所以要把挂起 */
/* If we get here then the HSM extension exists and the current
 * HART is not going to be used and needs to be suspended. */
hsm_suspend_hart:
  li a7, SBI_HSM_BASE
  li a6, SBI_HSM_BASE_HART_STOP
  ecall /* call SBI to suspend current HART */

/*CY 空转当前核 */
spin_hart:
  wfi
  j spin_hart
