const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const upstream_dep = b.dependency("dav1d", .{});

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "dav1d",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const config_h = b.addConfigHeader(.{
        .include_path = "config.h",
        .style = .blank,
    }, .{
        .CONFIG_8BPC = true,
        .CONFIG_16BPC = true,
        .HAVE_ASM = true,
        .TRIM_DSP_FUNCTIONS = true,
        .CONFIG_LOG = true,
        // Used by tests
        // .CONFIG_MACOS_KPERF = false,
        .HAVE_SYS_TYPES_H = .@"__has_include(<sys/types.h>)",
        .HAVE_UNISTD_H = .@"__has_include(<unistd.h>)",
        .HAVE_IO_H = .@"__has_include(<io.h>)",
        .HAVE_PTHREAD_NP_H = .@"__has_include(<pthread_np.h>)",
        .HAVE_DLSYM = .@"__has_include(<dlfcn.h>)",
        .HAVE_GETAUXVAL = target.result.os.tag == .linux,
        .HAVE_ELF_AUX_INFO = switch (target.result.os.tag) {
            .freebsd, .openbsd => true,
            else => false,
        },
        .HAVE_PTHREAD_GETAFFINITY_NP = switch (target.result.os.tag) {
            .linux, .freebsd, .netbsd => true,
            else => false,
        },
        .HAVE_PTHREAD_SETAFFINITY_NP = .HAVE_PTHREAD_GETAFFINITY_NP,
        .HAVE_PTHREAD_SETNAME_NP = switch (target.result.os.tag) {
            .linux, .freebsd, .netbsd => true,
            else => |tag| tag.isDarwin(),
        },
        .HAVE_PTHREAD_SET_NAME_NP = switch (target.result.os.tag) {
            .freebsd, .openbsd => true,
            else => false,
        },
        .HAVE_C11_GENERIC = true,
        // Used by tools
        // .ENDIANNESS_BIG = target.result.cpu.arch.endian() == .big,
        .ARCH_AARCH64 = target.result.cpu.arch.isAARCH64(),
        .ARCH_ARM = switch (target.result.cpu.arch) {
            .arm, .armeb => true,
            else => false,
        },
        .ARCH_X86 = switch (target.result.cpu.arch) {
            .x86, .x86_64 => true,
            else => false,
        },
        .ARCH_X86_64 = target.result.cpu.arch == .x86_64,
        .ARCH_X86_32 = target.result.cpu.arch == .x86,
        .ARCH_PPC64LE = target.result.cpu.arch == .powerpc64le,
        .ARCH_RISCV = target.result.cpu.arch.isRISCV(),
        .ARCH_RV32 = target.result.cpu.arch.isRiscv32(),
        .ARCH_RV64 = target.result.cpu.arch.isRiscv64(),
        .ARCH_LOONGARCH = target.result.cpu.arch.isLoongArch(),
        .ARCH_LOONGARCH32 = target.result.cpu.arch == .loongarch32,
        .ARCH_LOONGARCH64 = target.result.cpu.arch == .loongarch64,
    });
    lib.root_module.addConfigHeader(config_h);

    const config_asm = b.addConfigHeader(
        .{ .style = .nasm, .include_path = "config.asm" },
        .{
            .private_prefix = .dav1d,
            .ARCH_X86_64 = target.result.cpu.arch == .x86_64,
            .ARCH_X86_32 = target.result.cpu.arch == .x86,
            .PIC = true,
            .FORCE_VEX_ENCODING = target.result.cpu.has(.x86, .avx),
            .STACK_ALIGNMENT = if (target.result.cpu.arch == .x86_64 or target.result.os.tag == .linux or target.result.os.tag.isDarwin()) @as(u8, 16) else 4,
        },
    );
    lib.root_module.addConfigHeader(config_asm);

    if (target.result.os.tag.isDarwin() or (target.result.os.tag == .windows and target.result.cpu.arch.isX86())) {
        config_h.addValue("PREFIX", bool, true);
        config_asm.addValue("PREFIX", bool, true);
    }

    const dav1d_url = @import("build.zig.zon").dependencies.dav1d.url;
    const vcs_version_h = b.addConfigHeader(.{
        .style = .{ .autoconf_at = upstream_dep.path("include/vcs_version.h.in") },
    }, .{
        .VCS_TAG = dav1d_url[std.mem.findScalarLast(u8, dav1d_url, '#').? + 1 ..][0..7],
    });
    lib.root_module.addConfigHeader(vcs_version_h);

    if (target.result.os.tag == .windows) {
        config_h.addValues(.{
            .UNICODE = true,
            ._UNICODE = true,
            .HAVE_CLOCK_GETTIME = false,
            .HAVE_POSIX_MEMALIGN = false,
            .HAVE_MEMALIGN = false,
            .HAVE_ALIGNED_ALLOC = false,
        });
        switch (target.result.abi) {
            .gnu => config_h.addValues(.{
                .__USE_MINGW_ANSI_STDIO = true,
                ._FILE_OFFSET_BITS = 64,
            }),
            .msvc => config_h.addValues(.{
                ._CRT_DECLARE_NONSTDC_NAMES = true,
                // Used by tools
                // .fseeko = "_fseeki64",
                // .ftello = "_ftelli64",
            }),
            else => unreachable,
        }
        lib.root_module.addCSourceFile(.{
            .language = .c,
            .file = upstream_dep.path("src/win32/thread.c"),
        });
    } else {
        config_h.addValues(.{
            .HAVE_CLOCK_GETTIME = true,
            .HAVE_POSIX_MEMALIGN = true,
            .HAVE_MEMALIGN = !target.result.os.tag.isBSD(),
            .HAVE_ALIGNED_ALLOC = !target.result.os.tag.isDarwin(),
        });
    }

    lib.root_module.addCSourceFiles(.{
        .language = .c,
        .root = upstream_dep.path("src"),
        .files = dav1d_srcs,
    });
    inline for (&.{ "8", "16" }) |depth|
        lib.root_module.addCSourceFiles(.{
            .language = .c,
            .root = upstream_dep.path("src"),
            .files = tmpl_srcs,
            .flags = &.{"-DBITDEPTH=" ++ depth},
        });
    lib.root_module.addIncludePath(upstream_dep.path(""));
    lib.root_module.addIncludePath(upstream_dep.path("include"));

    switch (target.result.cpu.arch) {
        .x86, .x86_64 => {
            config_h.addValue("HAVE_ASM", bool, true);
            lib.root_module.addCSourceFiles(.{
                .language = .c,
                .root = upstream_dep.path("src/x86"),
                .files = x86_c_srcs,
            });
            inline for (&.{ x86_nasm_srcs, x86_8bpc_nasm_srcs, x86_16bpc_nasm_srcs }) |srcs|
                addNasmSources(b, target.result, lib.root_module, "src/x86", srcs, &.{ config_asm.getOutputDir(), upstream_dep.path("src") });
        },
        .arm, .aarch64 => |arch| {
            config_h.addValue("HAVE_ASM", bool, true);
            lib.root_module.addCSourceFiles(.{
                .language = .c,
                .root = upstream_dep.path("src/arm"),
                .files = arm_srcs,
            });
            if (arch == .arm) {
                inline for (&.{ arm_32_srcs, arm_32_8bpc_srcs, arm_32_16bpc_srcs }) |srcs|
                    lib.root_module.addCSourceFiles(.{
                        .language = .assembly_with_preprocessor,
                        .root = upstream_dep.path("src/arm/32"),
                        .files = srcs,
                    });
            } else {
                inline for (&.{ arm_64_srcs, arm_64_8bpc_srcs, arm_64_16bpc_srcs }) |srcs|
                    lib.root_module.addCSourceFiles(.{
                        .language = .assembly_with_preprocessor,
                        .root = upstream_dep.path("src/arm/64"),
                        .files = srcs,
                    });
            }
        },
        .riscv64 => {
            config_h.addValue("HAVE_ASM", bool, true);
            lib.root_module.addCSourceFiles(.{
                .language = .c,
                .root = upstream_dep.path("src/riscv"),
                .files = riscv_srcs,
            });
            inline for (&.{ riscv_64_srcs, riscv_64_8bpc_srcs, riscv_64_16bpc_srcs }) |srcs|
                lib.root_module.addCSourceFiles(.{
                    .language = .assembly_with_preprocessor,
                    .root = upstream_dep.path("src/riscv/64"),
                    .files = srcs,
                });
        },
        .loongarch64 => {
            config_h.addValue("HAVE_ASM", bool, true);
            lib.root_module.addCSourceFiles(.{
                .language = .c,
                .root = upstream_dep.path("src/loongarch"),
                .files = loongarch_c_srcs,
            });
            lib.root_module.addCSourceFiles(.{
                .language = .assembly_with_preprocessor,
                .root = upstream_dep.path("src/loongarch"),
                .files = loongarch_asm_srcs,
            });
            inline for (&.{ "8", "16" }) |depth|
                lib.root_module.addCSourceFiles(.{
                    .language = .c,
                    .root = upstream_dep.path("src/loongarch"),
                    .files = loongarch_tmpl_srcs,
                    .flags = &.{"-DBITDEPTH=" ++ depth},
                });
        },
        .powerpc64le => {
            config_h.addValue("HAVE_ASM", bool, true);
            lib.root_module.addCSourceFiles(.{
                .language = .c,
                .root = upstream_dep.path("src/ppc"),
                .files = ppc64le_c_srcs,
            });
            inline for (&.{ "8", "16" }) |depth| {
                lib.root_module.addCSourceFiles(.{
                    .language = .c,
                    .root = upstream_dep.path("src/ppc"),
                    .files = ppc64le_vsx_tmpl_srcs,
                    .flags = &.{ "-DAV1D_VSX", "-DBITDEPTH=" ++ depth },
                });
                lib.root_module.addCSourceFiles(.{
                    .language = .c,
                    .root = upstream_dep.path("src/ppc"),
                    .files = ppc64le_pwr9_tmpl_srcs,
                    .flags = &.{
                        "-Xclang",      "-target-feature",      "-Xclang", "+isa-v30-instructions",
                        "-Xclang",      "-target-feature",      "-Xclang", "+power9-altivec",
                        "-Xclang",      "-target-feature",      "-Xclang", "+power9-vector",
                        "-DDAV1D_PWR9", "-DBITDEPTH=" ++ depth,
                    },
                });
            }
        },
        else => config_h.addValue("HAVE_ASM", bool, false),
    }

    lib.installHeadersDirectory(upstream_dep.path("include/dav1d"), "dav1d", .{});
    b.installArtifact(lib);
}

fn addNasmSources(b: *std.Build, target: std.Target, m: *std.Build.Module, comptime root: []const u8, comptime srcs: []const []const u8, includes: []const std.Build.LazyPath) void {
    const upstream_dep = b.dependency("dav1d", .{});
    const format = b.fmt("-f{s}{s}", .{ switch (target.ofmt) {
        .coff => "win",
        .macho => "macho",
        .elf => "elf",
        else => unreachable,
    }, if (target.cpu.arch == .x86_64) "64" else "32" });
    inline for (srcs) |src| {
        if (runNasm(b)) |run_nasm| {
            run_nasm.setCwd(upstream_dep.path(root));
            run_nasm.addArg(format);
            for (includes) |include| {
                run_nasm.addArg("-i");
                run_nasm.addDirectoryArg(include);
            }
            run_nasm.addFileArg(upstream_dep.path(root ++ "/" ++ src));
            run_nasm.addArg("-o");
            m.addObjectFile(run_nasm.addOutputFileArg(src ++ ".o"));
        }
    }
}

fn runNasm(b: *std.Build) ?*std.Build.Step.Run {
    return if (b.systemIntegrationOption("nasm", .{}))
        b.addSystemCommand(&.{"nasm"})
    else if (b.lazyDependency("nasm", .{ .optimize = .ReleaseFast })) |nasm_dep|
        b.addRunArtifact(nasm_dep.artifact("nasm"))
    else
        null;
}

const dav1d_srcs = &.{
    "cdf.c",
    "cpu.c",
    "ctx.c",
    "data.c",
    "decode.c",
    "dequant_tables.c",
    "getbits.c",
    "intra_edge.c",
    "itx_1d.c",
    "lf_mask.c",
    "lib.c",
    "log.c",
    "mem.c",
    "msac.c",
    "obu.c",
    "pal.c",
    "picture.c",
    "qm.c",
    "ref.c",
    "refmvs.c",
    "scan.c",
    "tables.c",
    "thread_task.c",
    "warpmv.c",
    "wedge.c",
};

const tmpl_srcs = &.{
    "cdef_apply_tmpl.c",
    "cdef_tmpl.c",
    "fg_apply_tmpl.c",
    "filmgrain_tmpl.c",
    "ipred_prepare_tmpl.c",
    "ipred_tmpl.c",
    "itx_tmpl.c",
    "lf_apply_tmpl.c",
    "loopfilter_tmpl.c",
    "looprestoration_tmpl.c",
    "lr_apply_tmpl.c",
    "mc_tmpl.c",
    "recon_tmpl.c",
};

const arm_srcs = &.{
    "cpu.c",
};
const arm_32_srcs = &.{
    "itx.S",
    "looprestoration_common.S",
    "msac.S",
    "refmvs.S",
};
const arm_32_8bpc_srcs = &.{
    "cdef.S",
    "filmgrain.S",
    "ipred.S",
    "loopfilter.S",
    "looprestoration.S",
    "mc.S",
};
const arm_32_16bpc_srcs = &.{
    "cdef16.S",
    "filmgrain16.S",
    "ipred16.S",
    "itx16.S",
    "loopfilter16.S",
    "looprestoration16.S",
    "mc16.S",
};
const arm_64_srcs = &.{
    "itx.S",
    "looprestoration_common.S",
    "msac.S",
    "refmvs.S",
};
const arm_64_8bpc_srcs = &.{
    "cdef.S",
    "filmgrain.S",
    "ipred.S",
    "loopfilter.S",
    "looprestoration.S",
    "mc.S",
    "mc_dotprod.S",
};
const arm_64_16bpc_srcs = &.{
    "cdef16.S",
    "filmgrain16.S",
    "ipred16.S",
    "itx16.S",
    "loopfilter16.S",
    "looprestoration16.S",
    "mc16.S",
    "mc16_sve.S",
};

const x86_c_srcs = &.{
    "cpu.c",
};
const x86_nasm_srcs = &.{
    "cpuid.asm",
    "msac.asm",
    "pal.asm",
    "refmvs.asm",
    "itx_avx512.asm",
    "cdef_avx2.asm",
    "itx_avx2.asm",
    "cdef_sse.asm",
    "itx_sse.asm",
};
const x86_8bpc_nasm_srcs = &.{
    "cdef_avx512.asm",
    "filmgrain_avx512.asm",
    "ipred_avx512.asm",
    "loopfilter_avx512.asm",
    "looprestoration_avx512.asm",
    "mc_avx512.asm",
    "filmgrain_avx2.asm",
    "ipred_avx2.asm",
    "loopfilter_avx2.asm",
    "looprestoration_avx2.asm",
    "mc_avx2.asm",
    "filmgrain_sse.asm",
    "ipred_sse.asm",
    "loopfilter_sse.asm",
    "looprestoration_sse.asm",
    "mc_sse.asm",
};
const x86_16bpc_nasm_srcs = &.{
    "cdef16_avx512.asm",
    "filmgrain16_avx512.asm",
    "ipred16_avx512.asm",
    "itx16_avx512.asm",
    "loopfilter16_avx512.asm",
    "looprestoration16_avx512.asm",
    "mc16_avx512.asm",
    "cdef16_avx2.asm",
    "filmgrain16_avx2.asm",
    "ipred16_avx2.asm",
    "itx16_avx2.asm",
    "loopfilter16_avx2.asm",
    "looprestoration16_avx2.asm",
    "mc16_avx2.asm",
    "cdef16_sse.asm",
    "filmgrain16_sse.asm",
    "ipred16_sse.asm",
    "itx16_sse.asm",
    "loopfilter16_sse.asm",
    "looprestoration16_sse.asm",
    "mc16_sse.asm",
};

const riscv_srcs = &.{
    "cpu.c",
};
const riscv_64_srcs = &.{
    "cpu.S",
    "pal.S",
};
const riscv_64_8bpc_srcs = &.{
    "cdef.S",
    "ipred.S",
    "itx.S",
    "mc.S",
};
const riscv_64_16bpc_srcs = &.{
    "cdef16.S",
    "ipred16.S",
    "mc16.S",
};

const loongarch_c_srcs = &.{
    "cpu.c",
};
const loongarch_tmpl_srcs = &.{
    "looprestoration_inner.c",
};
const loongarch_asm_srcs = &.{
    "cdef.S",
    "ipred.S",
    "mc.S",
    "loopfilter.S",
    "looprestoration.S",
    "msac.S",
    "refmvs.S",
    "itx.S",
};

const ppc64le_c_srcs = &.{
    "cpu.c",
};
const ppc64le_vsx_tmpl_srcs = &.{
    "cdef_tmpl.c",
    "looprestoration_tmpl.c",
};
const ppc64le_pwr9_tmpl_srcs = &.{
    "itx_tmpl.c",
    "loopfilter_tmpl.c",
    "mc_tmpl.c",
};
