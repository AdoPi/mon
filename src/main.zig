const std = @import("std");
const mon = @import("mon");

fn autoDetectEnvWithGit(allocator: std.mem.Allocator) !?[]const u8 {
    const argv = [_][]const u8{ "git", "rev-parse", "--abbrev-ref", "HEAD" };
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    _ = try child.spawn();
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1000);
    std.debug.print("stdout: {s}\n", .{stdout});
    const branchName = std.mem.trim(u8, stdout, " \n");

    if (branchName.len == 0) {
        return error.GitBranchError;
    }
    std.debug.print("Current branch: {s}\n", .{branchName});

    return branchName;
}

fn autoDetectProjectWithGit(allocator: std.mem.Allocator) !?[]const u8 {
    const argv = [_][]const u8{ "git", "rev-parse", "--show-toplevel" };
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    _ = try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1000);
    std.debug.print("stdout: {s}\n", .{stdout});
    const repoPath = std.mem.trim(u8, stdout, " \n");
    var it = std.mem.splitAny(u8, repoPath, "/");

    var repoName: ?[]const u8 = "";

    while (it.next()) |p| {
        repoName = p;
    }

    if (repoName.?.len == 0) {
        return error.NotAGitRepository;
    }
    std.debug.print("Repo name: {s}\n", .{repoName.?});

    return repoName;
}

fn computeTemplate(allocator: std.mem.Allocator, template: []const u8, project: []const u8, env: []const u8) ![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, 10000);
    // template engine :)
    var i: usize = 0;
    while (i < template.len) {
        if (std.mem.startsWith(u8, template[i..], "{project}")) {
            try buf.appendSlice(allocator, project);
            i += "{project}".len;
        } else if (std.mem.startsWith(u8, template[i..], "{env}")) {
            try buf.appendSlice(allocator, env);
            i += "{env}".len;
        } else {
            try buf.append(allocator, template[i]);
            i += 1;
        }
    }
    return buf.toOwnedSlice(allocator);
}

fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !std.json.Value {
    std.debug.print("Loading config\n", .{});
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const file_data = try file.readToEndAlloc(allocator, 60 * 1024);
    defer allocator.free(file_data);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, file_data, .{
        .allocate = .alloc_always,
    });

    // TODO: deinit
    return parsed.value;
}

// todo: build and run
fn runCommand(allocator: std.mem.Allocator, project: []const u8, env: []const u8, mode: []const u8, no_bastion: bool, exec_cmd: ?[]const u8) !void {
    // TODO: load config.json from XDG folder or a given path from args
    const tree = try loadConfig(allocator, "config.json");
    const root = tree;

    const bastion = root.object.get("bastion") orelse return error.MissingBastion;
    const bastion_user = bastion.object.get("user").?.string;
    const bastion_host = bastion.object.get("host").?.string;

    const defaults = root.object.get("defaults") orelse return error.MissingDefaults;
    const default_shell = defaults.object.get("shell_cmd").?.string;
    const default_console = defaults.object.get("console_cmd").?.string;

    const projects = root.object.get("projects") orelse return error.MissingProjects;

    const project_obj = projects.object.get(project) orelse {
        std.debug.print("Unknown project: {s}\n", .{project});
        return error.UnknownProject;
    };

    const env_obj = project_obj.object.get(env) orelse {
        std.debug.print("Unknown env: {s}\n", .{env});
        return error.UnknownObject;
    };

    const user = env_obj.object.get("user").?.string; // could be a default user
    const server = env_obj.object.get("server").?.string;

    var raw_cmd: []const u8 = "";
    // switch ?
    if (std.mem.eql(u8, mode, "shell")) {
        raw_cmd = if (env_obj.object.get("shell_cmd")) |v| v.string else default_shell;
    } else if (std.mem.eql(u8, mode, "console")) {
        raw_cmd = if (env_obj.object.get("console_cmd")) |v| v.string else default_console;
    } else {
        return error.InvalidMode;
    }

    const base_cmd = try computeTemplate(allocator, raw_cmd, project, env);
    defer allocator.free(base_cmd);

    const final_cmd = if (exec_cmd) |extra|
        try std.fmt.allocPrint(allocator, "{s} {s}", .{ base_cmd, extra })
    else
        try std.fmt.allocPrint(allocator, "{s}", .{base_cmd});
    defer allocator.free(final_cmd);

    var ssh_cmd: []u8 = undefined;
    if (no_bastion) {
        ssh_cmd = try std.fmt.allocPrint(allocator, "ssh -t {s}@{s} \"{s}\"", .{ user, server, final_cmd });
    } else {
        ssh_cmd = try std.fmt.allocPrint(allocator, "ssh -t {s}@{s} ssh {s}@{s} \"{s}\"", .{ bastion_user, bastion_host, user, server, final_cmd });
    }
    defer allocator.free(ssh_cmd);

    var argv = [_][]const u8{ "sh", "-c", ssh_cmd };

    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    _ = try child.wait();
}

fn handleShell(allocator: std.mem.Allocator, a: [][:0]u8) !void {
    const args = a[1..];
    if (args.len == 1) {
        std.debug.print("Usage: shell <project> <env> [--no-bastion] --exec \"cmd\"\n", .{});
        return;
    }

    var no_bastion = false;
    var exec_cmd: ?[]const u8 = null;
    var project: ?[]const u8 = null;
    var env: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            std.debug.print("Usage: shell <project> <env> [--no-bastion] --exec \"cmd\"\n", .{});
            return;
        } else if (std.mem.eql(u8, args[i], "--no-bastion")) {
            no_bastion = true;
        } else if (std.mem.eql(u8, args[i], "--exec")) {
            if (i + 1 >= args.len) {
                std.debug.print("--exec requires an argument\n", .{});
                return;
            }
            exec_cmd = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--env") or std.mem.eql(u8, args[i], "-e")) {
            if (i + 1 >= args.len) {
                std.debug.print("--env requires an argument\n", .{});
                return;
            }
            env = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--project") or std.mem.eql(u8, args[i], "-p")) {
            if (i + 1 >= args.len) {
                std.debug.print("--env requires an argument\n", .{});
                return;
            }
            project = args[i + 1];
            i += 1;
        }
        i += 1;
    }
    std.debug.print("Autodetecting...\n", .{});

    if (env == null) {
        env = try autoDetectEnvWithGit(allocator);
    }

    // if project is null, try to autodect it, could try also to detect the env
    if (project == null) {
        project = try autoDetectProjectWithGit(allocator);
    }
    std.debug.print("Project = {s}, env = {s} \n", .{ project.?, env.? });

    try runCommand(std.heap.page_allocator, project.?, env.?, "shell", no_bastion, exec_cmd);
}

fn handleConsole(_: std.mem.Allocator, a: [][:0]u8) !void {
    const args = a[1..];
    if (args.len < 3) {
        std.debug.print("Usage: console <project> <env> [--no-bastion] --exec \"cmd\"\n", .{});
        return;
    }

    var no_bastion = false;
    var exec_cmd: ?[]const u8 = null;
    var project: ?[]const u8 = null;
    var env: ?[]const u8 = null;

    var i: usize = 3;
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "--no-bastion")) {
            no_bastion = true;
        } else if (std.mem.eql(u8, args[i], "--exec")) {
            if (i + 1 >= args.len) {
                std.debug.print("--exec requires an argument\n", .{});
                return;
            }
            exec_cmd = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--env") or std.mem.eql(u8, args[i], "-e")) {
            if (i + 1 >= args.len) {
                std.debug.print("--env requires an argument\n", .{});
                return;
            }
            env = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--project") or std.mem.eql(u8, args[i], "-p")) {
            if (i + 1 >= args.len) {
                std.debug.print("--env requires an argument\n", .{});
                return;
            }
            project = args[i + 1];
            i += 1;
        }
        i += 1;
    }

    try runCommand(std.heap.page_allocator, project.?, env.?, "console", no_bastion, exec_cmd);
}

fn handleRepo(_: std.mem.Allocator, a: [][:0]u8) !void {
    const args = a[1..];

    if (args.len < 2 or !std.mem.eql(u8, args[1], "--sync")) {
        std.debug.print("Usage: repo --sync\n", .{});
        return;
    }

    std.debug.print("Syncing file config.json...\n", .{});
    // TODO: Set repo url in config.json or in the command args

    std.debug.print("Not implemented yet\n", .{});
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <command>\n", .{args[0]});
        std.debug.print("Commands: shell, console, repo\n", .{});
        return;
    }

    if (std.mem.eql(u8, args[1], "shell")) {
        try handleShell(gpa, args);
    } else if (std.mem.eql(u8, args[1], "console")) {
        try handleConsole(gpa, args);
    } else if (std.mem.eql(u8, args[1], "repo")) {
        try handleRepo(gpa, args);
    } else {
        std.debug.print("Unknown command: {s}\n", .{args[1]});
    }
}
