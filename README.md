# dav1d

[dav1d](https://code.videolan.org/videolan/dav1d) on the [Zig Build System](https://ziglang.org/learn/build-system/).

## Usage

Add this package to `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/KNnut/dav1d
```

And then import `dav1d` in `build.zig` with:

```zig
const dav1d_dep = b.dependency("dav1d", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.linkLibrary(dav1d_dep.artifact("dav1d"));
```
