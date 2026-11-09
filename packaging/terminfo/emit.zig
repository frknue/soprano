//! Prints Ghostty's terminfo source (`xterm-ghostty`) to stdout, the same text Ghostty's own
//! build gets from `ghostty +terminfo`, without building Ghostty. scripts/stage-resources.sh
//! runs it with the submodule's `src/terminfo/main.zig` as the `terminfo` module and compiles
//! the output with `tic -x`.

const std = @import("std");
const terminfo = @import("terminfo");

pub fn main(init: std.process.Init) !void {
    var buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try terminfo.ghostty.encode(&stdout_writer.interface);
    try stdout_writer.end();
}
