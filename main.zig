const std = @import("std");

//
// Framebuffer (/dev/fb0)
//
const Framebuffer = struct {
    file: std.fs.File,
    buffer: []u8,
    width: usize,
    height: usize,

    pub fn init() !Framebuffer {
        const fb = try std.fs.cwd().openFile("/dev/fb0", .{ .mode = .read_write });
        const w: usize = 1920;
        const h: usize = 1080;
        const buffer = try std.heap.page_allocator.alloc(u8, w * h * 4);
        
        return .{ 
            .file = fb,
            .buffer = buffer,
            .width = w,
            .height = h,
        };
    }

    pub fn deinit(self: *Framebuffer) void {
        std.heap.page_allocator.free(self.buffer);
        self.file.close();
    }
    
    pub fn flush(self: *Framebuffer) !void {
        try self.file.seekTo(0);
        try self.file.writeAll(self.buffer);
    }
};

//
// Texture Loading
//
const Texture = struct {
    width: usize,
    height: usize,
    pixels: []u32,
    
    pub fn loadPPM(alloc: std.mem.Allocator, path: []const u8) !Texture {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        
        const content = try file.readToEndAlloc(alloc, 10 * 1024 * 1024);
        defer alloc.free(content);
        
        var lines = std.mem.splitScalar(u8, content, '\n');
        
        const magic = lines.next() orelse return error.InvalidPPM;
        if (!std.mem.eql(u8, std.mem.trim(u8, magic, &std.ascii.whitespace), "P3") and
            !std.mem.eql(u8, std.mem.trim(u8, magic, &std.ascii.whitespace), "P6")) {
            return error.InvalidPPM;
        }
        const is_binary = std.mem.eql(u8, std.mem.trim(u8, magic, &std.ascii.whitespace), "P6");
        
        var dims_line: []const u8 = undefined;
        while (true) {
            dims_line = lines.next() orelse return error.InvalidPPM;
            if (dims_line.len > 0 and dims_line[0] != '#') break;
        }
        
        var dims = std.mem.splitScalar(u8, std.mem.trim(u8, dims_line, &std.ascii.whitespace), ' ');
        const w = try std.fmt.parseInt(usize, dims.next() orelse return error.InvalidPPM, 10);
        const h = try std.fmt.parseInt(usize, dims.next() orelse return error.InvalidPPM, 10);
        
        while (true) {
            const max_line = lines.next() orelse return error.InvalidPPM;
            if (max_line.len > 0 and max_line[0] != '#') break;
        }
        
        const data = try alloc.alloc(u32, w * h);
        
        if (is_binary) {
            const pixel_data_start = content.len - (w * h * 3);
            for (0..h) |y| {
                for (0..w) |x| {
                    const idx = y * w + x;
                    const offset = pixel_data_start + idx * 3;
                    const r = content[offset];
                    const g = content[offset + 1];
                    const b = content[offset + 2];
                    data[idx] = (@as(u32, r) << 24) | (@as(u32, g) << 16) | (@as(u32, b) << 8) | 0xff;
                }
            }
        } else {
            var idx: usize = 0;
            while (idx < w * h) : (idx += 1) {
                const r_str = lines.next() orelse return error.InvalidPPM;
                const g_str = lines.next() orelse return error.InvalidPPM;
                const b_str = lines.next() orelse return error.InvalidPPM;
                
                const r = try std.fmt.parseInt(u8, std.mem.trim(u8, r_str, &std.ascii.whitespace), 10);
                const g = try std.fmt.parseInt(u8, std.mem.trim(u8, g_str, &std.ascii.whitespace), 10);
                const b = try std.fmt.parseInt(u8, std.mem.trim(u8, b_str, &std.ascii.whitespace), 10);
                
                data[idx] = (@as(u32, r) << 24) | (@as(u32, g) << 16) | (@as(u32, b) << 8) | 0xff;
            }
        }
        
        return .{
            .width = w,
            .height = h,
            .pixels = data,
        };
    }
    
    pub fn deinit(self: *Texture, alloc: std.mem.Allocator) void {
        alloc.free(self.pixels);
    }
    
    pub inline fn sample(self: *const Texture, u: f32, v: f32) u32 {
        // Clamp UV coordinates to [0, 1]
        const u_clamped = @max(0.0, @min(0.9999, u));
        const v_clamped = @max(0.0, @min(0.9999, v));
        
        const x = @as(usize, @intFromFloat(u_clamped * @as(f32, @floatFromInt(self.width))));
        const y = @as(usize, @intFromFloat(v_clamped * @as(f32, @floatFromInt(self.height))));
        const idx = y * self.width + x;
        
        if (idx >= self.pixels.len) {
            std.debug.print("WARNING: Texture sample out of bounds! u={d:.4} v={d:.4} x={} y={} idx={} len={}\n", 
                .{u, v, x, y, idx, self.pixels.len});
            return 0xFF00FFFF; // Magenta for debug
        }
        
        return self.pixels[idx];
    }
    
    pub fn debugPrint(self: *const Texture) void {
        std.debug.print("Texture Debug: {}x{}\n", .{self.width, self.height});
        
        // Print first 5 pixels
        for (0..@min(5, self.pixels.len)) |i| {
            const sample_pixel = self.pixels[i];
            const r = (sample_pixel >> 24) & 0xFF;
            const g = (sample_pixel >> 16) & 0xFF;
            const b = (sample_pixel >> 8) & 0xFF;
            std.debug.print("  Pixel {} RGB: ({}, {}, {}) = 0x{X:0>8}\n", .{i, r, g, b, sample_pixel});
        }
        
        // Print middle row sample
        const mid_idx = (self.height / 2) * self.width + (self.width / 2);
        if (mid_idx < self.pixels.len) {
            const sample_pixel = self.pixels[mid_idx];
            const r = (sample_pixel >> 24) & 0xFF;
            const g = (sample_pixel >> 16) & 0xFF;
            const b = (sample_pixel >> 8) & 0xFF;
            std.debug.print("  Middle pixel RGB: ({}, {}, {}) = 0x{X:0>8}\n", .{r, g, b, sample_pixel});
        }
    }
};

//
// Map Loading
//
const Map = struct {
    width: usize,
    height: usize,
    pixels: []u32,
    
    pub fn loadPPM(alloc: std.mem.Allocator, path: []const u8) !Map {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        
        const content = try file.readToEndAlloc(alloc, 10 * 1024 * 1024);
        defer alloc.free(content);
        
        var lines = std.mem.splitScalar(u8, content, '\n');
        
        const magic = lines.next() orelse return error.InvalidPPM;
        if (!std.mem.eql(u8, std.mem.trim(u8, magic, &std.ascii.whitespace), "P3") and
            !std.mem.eql(u8, std.mem.trim(u8, magic, &std.ascii.whitespace), "P6")) {
            return error.InvalidPPM;
        }
        const is_binary = std.mem.eql(u8, std.mem.trim(u8, magic, &std.ascii.whitespace), "P6");
        
        var dims_line: []const u8 = undefined;
        while (true) {
            dims_line = lines.next() orelse return error.InvalidPPM;
            if (dims_line.len > 0 and dims_line[0] != '#') break;
        }
        
        var dims = std.mem.splitScalar(u8, std.mem.trim(u8, dims_line, &std.ascii.whitespace), ' ');
        const w = try std.fmt.parseInt(usize, dims.next() orelse return error.InvalidPPM, 10);
        const h = try std.fmt.parseInt(usize, dims.next() orelse return error.InvalidPPM, 10);
        
        while (true) {
            const max_line = lines.next() orelse return error.InvalidPPM;
            if (max_line.len > 0 and max_line[0] != '#') break;
        }
        
        const data = try alloc.alloc(u32, w * h);
        
        if (is_binary) {
            const pixel_data_start = content.len - (w * h * 3);
            for (0..h) |y| {
                for (0..w) |x| {
                    const idx = y * w + x;
                    const offset = pixel_data_start + idx * 3;
                    const r = content[offset];
                    const g = content[offset + 1];
                    const b = content[offset + 2];
                    data[idx] = (@as(u32, r) << 24) | (@as(u32, g) << 16) | (@as(u32, b) << 8) | 0xff;
                }
            }
        } else {
            var idx: usize = 0;
            while (idx < w * h) : (idx += 1) {
                const r_str = lines.next() orelse return error.InvalidPPM;
                const g_str = lines.next() orelse return error.InvalidPPM;
                const b_str = lines.next() orelse return error.InvalidPPM;
                
                const r = try std.fmt.parseInt(u8, std.mem.trim(u8, r_str, &std.ascii.whitespace), 10);
                const g = try std.fmt.parseInt(u8, std.mem.trim(u8, g_str, &std.ascii.whitespace), 10);
                const b = try std.fmt.parseInt(u8, std.mem.trim(u8, b_str, &std.ascii.whitespace), 10);
                
                data[idx] = (@as(u32, r) << 24) | (@as(u32, g) << 16) | (@as(u32, b) << 8) | 0xff;
            }
        }
        
        return .{
            .width = w,
            .height = h,
            .pixels = data,
        };
    }
    
    pub fn deinit(self: *Map, alloc: std.mem.Allocator) void {
        alloc.free(self.pixels);
    }
    
    pub inline fn isWall(self: *const Map, x: i32, y: i32) bool {
        if (x < 0 or y < 0 or x >= @as(i32, @intCast(self.width)) or y >= @as(i32, @intCast(self.height))) return true;
        const idx = @as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x));
        const pixel = self.pixels[idx];
        // Black (or near-black) is floor, everything else is a wall
        return ((pixel & 0xFFFFFF00) >= 0x10101000) or ((pixel & 0xFFFFFF00) == 0x0000FF00);

    }
    
    pub inline fn getWallColor(self: *const Map, x: i32, y: i32) u32 {
        if (x < 0 or y < 0 or x >= @as(i32, @intCast(self.width)) or y >= @as(i32, @intCast(self.height))) return 0xFFFFFFFF;
        const idx = @as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x));
        return self.pixels[idx];
    }
};

//
// Fast DDA Raycasting
//
const RayHit = struct {
    distance: f32,
    hit: bool,
    wall_x: f32, // Where exactly the wall was hit (for texture mapping)
    side: u8,    // Which side of wall was hit (0=x, 1=y)
    map_x: i32,  // Grid position of the hit wall
    map_y: i32,
};

fn castRayDDA(map: *const Map, start_x: f32, start_y: f32, angle: f32, max_dist: f32) RayHit {
    const dx = @cos(angle);
    const dy = @sin(angle);
    
    var map_x = @as(i32, @intFromFloat(start_x));
    var map_y = @as(i32, @intFromFloat(start_y));
    
    const delta_dist_x = if (dx == 0) 1e30 else @abs(1.0 / dx);
    const delta_dist_y = if (dy == 0) 1e30 else @abs(1.0 / dy);
    
    var step_x: i32 = undefined;
    var step_y: i32 = undefined;
    var side_dist_x: f32 = undefined;
    var side_dist_y: f32 = undefined;
    
    if (dx < 0) {
        step_x = -1;
        side_dist_x = (start_x - @as(f32, @floatFromInt(map_x))) * delta_dist_x;
    } else {
        step_x = 1;
        side_dist_x = (@as(f32, @floatFromInt(map_x)) + 1.0 - start_x) * delta_dist_x;
    }
    
    if (dy < 0) {
        step_y = -1;
        side_dist_y = (start_y - @as(f32, @floatFromInt(map_y))) * delta_dist_y;
    } else {
        step_y = 1;
        side_dist_y = (@as(f32, @floatFromInt(map_y)) + 1.0 - start_y) * delta_dist_y;
    }
    
    var hit = false;
    var perp_wall_dist: f32 = 0;
    var side: u8 = 0;
    
    var iterations: usize = 0;
    const max_iterations = @as(usize, @intFromFloat(max_dist * 2));
    
    while (!hit and iterations < max_iterations) : (iterations += 1) {
        if (side_dist_x < side_dist_y) {
            side_dist_x += delta_dist_x;
            map_x += step_x;
            perp_wall_dist = side_dist_x - delta_dist_x;
            side = 0;
        } else {
            side_dist_y += delta_dist_y;
            map_y += step_y;
            perp_wall_dist = side_dist_y - delta_dist_y;
            side = 1;
        }
        
        if (map.isWall(map_x, map_y)) {
            hit = true;
        }
        
        if (perp_wall_dist > max_dist) break;
    }
    
    // Calculate exact hit position for texture mapping
    var wall_x: f32 = undefined;
    if (side == 0) {
        wall_x = start_y + perp_wall_dist * dy;
    } else {
        wall_x = start_x + perp_wall_dist * dx;
    }
    wall_x -= @floor(wall_x);
    
    return .{ 
        .distance = perp_wall_dist, 
        .hit = hit,
        .wall_x = wall_x,
        .side = side,
        .map_x = map_x,
        .map_y = map_y,
    };
}

//
// Texture mapping based on wall color
//
const TextureMap = struct {
    textures: [8]?Texture,
    
    pub fn init() TextureMap {
        return .{
            .textures = [_]?Texture{null} ** 8,
        };
    }
    
    pub fn deinit(self: *TextureMap, alloc: std.mem.Allocator) void {
        for (&self.textures) |*tex| {
            if (tex.*) |*t| t.deinit(alloc);
        }
    }
    
    // Map wall colors to texture indices
    pub fn getTextureForColor(self: *const TextureMap, color: u32) ?*const Texture {
        // Extract RGB (ignore alpha)
        const r = (color >> 24) & 0xFF;
        const g = (color >> 16) & 0xFF;
        const b = (color >> 8) & 0xFF;
        
        // Map common colors to texture slots
        // White/gray -> slot 0
        if (r > 200 and g > 200 and b > 200) {
            return if (self.textures[0]) |*tex| tex else null;
        }
        // Red -> slot 1
        if (r > 200 and g < 100 and b < 100) {
            return if (self.textures[1]) |*tex| tex else null;
        }
        // Green -> slot 2
        if (r < 100 and g > 200 and b < 100) {
            return if (self.textures[2]) |*tex| tex else null;
        }
        // Blue -> slot 3
        if (r < 100 and g < 100 and b > 200) {
            return if (self.textures[3]) |*tex| tex else null;
        }
        // Yellow -> slot 4
        if (r > 200 and g > 200 and b < 100) {
            return if (self.textures[4]) |*tex| tex else null;
        }
        // Cyan -> slot 5
        if (r < 100 and g > 200 and b > 200) {
            return if (self.textures[5]) |*tex| tex else null;
        }
        // Magenta -> slot 6
        if (r > 200 and g < 100 and b > 200) {
            return if (self.textures[6]) |*tex| tex else null;
        }
        // Orange/brown -> slot 7
        if (r > 150 and g > 75 and g < 150 and b < 100) {
            return if (self.textures[7]) |*tex| tex else null;
        }
        
        // Default: try slot 0
        return if (self.textures[0]) |*tex| tex else null;
    }
};

//
// Direct rendering with texture support
//
pub fn render3DScene(
    fb: *Framebuffer,
    map: *const Map,
    texture_map: *const TextureMap,
    player_x: f32,
    player_y: f32,
    player_angle: f32,
) !void {
    const screen_w = fb.width;
    const screen_h = fb.height;
    const fov: f32 = std.math.pi / 3.0;
    const max_distance: f32 = 10.0;

    // Clear buffer to black
    @memset(fb.buffer, 0);

    // signed version for clamping arithmetic
    const screen_h_i32: i32 = @as(i32, @intCast(screen_h));

    // Cast rays directly to framebuffer
    for (0..screen_w) |x| {
        const camera_x = 2.0 * @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(screen_w)) - 1.0;
        const ray_angle = player_angle + std.math.atan(camera_x * @tan(fov / 2.0));

        const hit = castRayDDA(map, player_x, player_y, ray_angle, max_distance);

        if (!hit.hit) continue;

        // compute projected line height (signed)
        const line_height = @as(i32, @intFromFloat(@as(f32, @floatFromInt(screen_h)) / (hit.distance + 0.1)));

        // draw start/end in signed space
        const draw_start: i32 = @divTrunc(-line_height, 2) + @as(i32, @intCast(screen_h / 2));
        const draw_end:   i32 = @divTrunc(line_height, 2) + @as(i32, @intCast(screen_h / 2));

        // Clamp to screen vertically (signed clamp, then convert)
        const clamped_start: i32 = std.math.clamp(draw_start, 0, screen_h_i32 - 1);
        const clamped_end:   i32 = std.math.clamp(draw_end,   0, screen_h_i32 - 1);

        // If the clamped range is empty, skip this column
        if (clamped_end < clamped_start) continue;

        const start_y: usize = @intCast(clamped_start);
        const end_y:   usize = @intCast(clamped_end);

        // Calculate lighting
        const depth_normalized = @min(1.0, hit.distance / max_distance);
        const lighting = 1.0 - depth_normalized * 0.8;

        // Side shading (darker for y-sides)
        const side_shade: f32 = if (hit.side == 1) 0.7 else 1.0;

        // Get wall color and corresponding texture
        const wall_color = map.getWallColor(hit.map_x, hit.map_y);
        const texture = texture_map.getTextureForColor(wall_color);

        // Texture mapping
        const tex_x = hit.wall_x;

        // Draw vertical column safely from start_y to end_y (inclusive).
        for (start_y..end_y + 1) |y| {
            // Convert y to signed to compute tex_y consistently
            const y_i32: i32 = @as(i32, @intCast(y));
            const screen_mid_i32: i32 = @as(i32, @intCast(screen_h / 2));

            // Calculate texture y coordinate (0..1)
            const d = @as(f32, @floatFromInt(y_i32 - screen_mid_i32)) + @as(f32, @floatFromInt(line_height)) / 2.0;
            const tex_y = d / @as(f32, @floatFromInt(line_height));

            if (texture) |tex| {
                // Sample texture
                const color = tex.sample(tex_x, tex_y);

                // Extract original channels
                const r_u8 = @as(u8, @intCast((color >> 24) & 0xff));
                const g_u8 = @as(u8, @intCast((color >> 16) & 0xff));
                const b_u8 = @as(u8, @intCast((color >> 8) & 0xff));

                // Compute lit channels as f32
                var lit_r_f: f32 = @as(f32, @floatFromInt(r_u8)) * lighting * side_shade;
                var lit_g_f: f32 = @as(f32, @floatFromInt(g_u8)) * lighting * side_shade;
                var lit_b_f: f32 = @as(f32, @floatFromInt(b_u8)) * lighting * side_shade;

                // Defensively handle NaN/Inf
                if (!std.math.isFinite(lit_r_f)) lit_r_f = 0.0;
                if (!std.math.isFinite(lit_g_f)) lit_g_f = 0.0;
                if (!std.math.isFinite(lit_b_f)) lit_b_f = 0.0;

                // Clamp to 0..255 before converting to integer
                const lit_r_clamped: f32 = std.math.clamp(lit_r_f, 0.0, 255.0);
                const lit_g_clamped: f32 = std.math.clamp(lit_g_f, 0.0, 255.0);
                const lit_b_clamped: f32 = std.math.clamp(lit_b_f, 0.0, 255.0);

                const lit_r: u8 = @intFromFloat(lit_r_clamped);
                const lit_g: u8 = @intFromFloat(lit_g_clamped);
                const lit_b: u8 = @intFromFloat(lit_b_clamped);

                const offset = (y * screen_w + x) * 4;
                fb.buffer[offset] = lit_b;
                fb.buffer[offset + 1] = lit_g;
                fb.buffer[offset + 2] = lit_r;
                fb.buffer[offset + 3] = 0xff;
            } else {
                // Use wall color with lighting (defensive like above)
                const r_u8 = @as(u8, @intCast((wall_color >> 24) & 0xff));
                const g_u8 = @as(u8, @intCast((wall_color >> 16) & 0xff));
                const b_u8 = @as(u8, @intCast((wall_color >> 8) & 0xff));

                var lit_r_f: f32 = @as(f32, @floatFromInt(r_u8)) * lighting * side_shade;
                var lit_g_f: f32 = @as(f32, @floatFromInt(g_u8)) * lighting * side_shade;
                var lit_b_f: f32 = @as(f32, @floatFromInt(b_u8)) * lighting * side_shade;

                if (!std.math.isFinite(lit_r_f)) lit_r_f = 0.0;
                if (!std.math.isFinite(lit_g_f)) lit_g_f = 0.0;
                if (!std.math.isFinite(lit_b_f)) lit_b_f = 0.0;

                const lit_r_clamped: f32 = std.math.clamp(lit_r_f, 0.0, 255.0);
                const lit_g_clamped: f32 = std.math.clamp(lit_g_f, 0.0, 255.0);
                const lit_b_clamped: f32 = std.math.clamp(lit_b_f, 0.0, 255.0);

                const lit_r: u8 = @intFromFloat(lit_r_clamped);
                const lit_g: u8 = @intFromFloat(lit_g_clamped);
                const lit_b: u8 = @intFromFloat(lit_b_clamped);

                const offset = (y * screen_w + x) * 4;
                fb.buffer[offset] = lit_b;
                fb.buffer[offset + 1] = lit_g;
                fb.buffer[offset + 2] = lit_r;
                fb.buffer[offset + 3] = 0xff;
            }
        }
    }

    try fb.flush();
}


//
// Input handling
//
const termios = std.posix.termios;

fn setupRawMode() !termios {
    const stdin_fd = std.posix.STDIN_FILENO;
    const original = try std.posix.tcgetattr(stdin_fd);
    var raw = original;
    
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    
    try std.posix.tcsetattr(stdin_fd, .FLUSH, raw);
    return original;
}

fn restoreMode(original: termios) void {
    const stdin_fd = std.posix.STDIN_FILENO;
    std.posix.tcsetattr(stdin_fd, .FLUSH, original) catch {};
}

fn readKey() ?u8 {
    var buf: [1]u8 = undefined;
    const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch return null;
    if (n == 0) return null;
    return buf[0];
}



//
// Main
//

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    
    var fb = try Framebuffer.init();
    defer fb.deinit();
    
    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    
    _ = args.skip();
    
    var won: bool = false; // Track win state

    var player_x: f32 = 16.0;
    var player_y: f32 = 16.0;
    var player_angle: f32 = 0.0;
    
    if (args.next()) |x_str| {
        player_x = try std.fmt.parseFloat(f32, x_str);
    }
    if (args.next()) |y_str| {
        player_y = try std.fmt.parseFloat(f32, y_str);
    }
    if (args.next()) |angle_str| {
        player_angle = try std.fmt.parseFloat(f32, angle_str);
    }
    
    const map_path = if (args.next()) |path| path else "map.ppm";
    var map = Map.loadPPM(alloc, map_path) catch |err| blk: {
        std.debug.print("Failed to load map '{s}': {}\n", .{map_path, err});
        std.debug.print("Creating default test map...\n", .{});
        
        const w: usize = 32;
        const h: usize = 32;
        const data = try alloc.alloc(u32, w * h);
        
        for (0..h) |y| {
            for (0..w) |x| {
                const idx = y * w + x;
                if (x == 0 or x == w - 1 or y == 0 or y == h - 1) {
                    data[idx] = 0xFFFFFFFF;
                } else if ((x == 10 or x == 20) and y > 5 and y < 25) {
                    data[idx] = 0xFFFFFFFF;
                } else {
                    data[idx] = 0x000000FF;
                }
            }
        }
        
        break :blk Map{
            .width = w,
            .height = h,
            .pixels = data,
        };
    };
    defer map.deinit(alloc);
    
    // Load wall texture
    var texture_map = TextureMap.init();
    defer texture_map.deinit(alloc);
    
    // Try to load textures for different wall colors
    const texture_files = [_][]const u8{
        "wall_white.ppm",  // slot 0 - white/gray walls
        "wall_red.ppm",    // slot 1 - red walls
        "wall_green.ppm",  // slot 2 - green walls
        "wall_blue.ppm",   // slot 3 - blue walls
        "wall_yellow.ppm", // slot 4 - yellow walls
        "wall_cyan.ppm",   // slot 5 - cyan walls
        "wall_magenta.ppm",// slot 6 - magenta walls
        "wall_brown.ppm",  // slot 7 - orange/brown walls
    };
    
    for (texture_files, 0..) |tex_file, i| {
        if (Texture.loadPPM(alloc, tex_file)) |tex| {
            texture_map.textures[i] = tex;
            std.debug.print("Loaded texture {}: {s} ({}x{})\n", .{i, tex_file, tex.width, tex.height});
            tex.debugPrint();
        } else |_| {
            // Texture file not found, skip
        }
    }
    
    if (map.isWall(@as(i32, @intFromFloat(player_x)), @as(i32, @intFromFloat(player_y)))) {
        outer: for (0..map.height) |y| {
            for (0..map.width) |x| {
                if (!map.isWall(@as(i32, @intCast(x)), @as(i32, @intCast(y)))) {
                    player_x = @as(f32, @floatFromInt(x)) + 0.5;
                    player_y = @as(f32, @floatFromInt(y)) + 0.5;
                    break :outer;
                }
            }
        }
    }
    
    std.debug.print("Controls: W/A/S/D to move, Q/E to rotate, F to break green tiles, ESC to quit\n", .{});
    std.debug.print("Starting position: ({d:.2}, {d:.2}) facing {d:.2} rad\n", .{player_x, player_y, player_angle});

    const original_term = try setupRawMode();
    defer restoreMode(original_term);

    const move_speed: f32 = 0.3;
    const rot_speed: f32 = 0.15;

    var running = true;
    var frame_count: u64 = 0;
    var last_time = std.time.milliTimestamp();

    // Track key states with frame counter (keys stay active for 2 frames)
    var key_w: u8 = 0;
    var key_s: u8 = 0;
    var key_a: u8 = 0;
    var key_d: u8 = 0;
    var key_q: u8 = 0;
    var key_e: u8 = 0;
    var key_f: u8 = 0; // F key

    while (running) {
        // Read all available keys this frame
        while (readKey()) |key| {
            switch (key) {
                'w', 'W' => key_w = 2,
                's', 'S' => key_s = 2,
                'a', 'A' => key_a = 2,
                'd', 'D' => key_d = 2,
                'q', 'Q' => key_q = 2,
                'e', 'E' => key_e = 2,
                'f', 'F' => key_f = 2,
                27 => {
                    running = false;
                    break;
                },
                else => {},
            }
        }

        if (!running) break;

        // Process movement based on key states
        const old_x = player_x;
        const old_y = player_y;
        var moved = false;

        if (key_w > 0) {
            player_x += @cos(player_angle) * move_speed;
            player_y += @sin(player_angle) * move_speed;
            moved = true;
        }
        if (key_s > 0) {
            player_x -= @cos(player_angle) * move_speed;
            player_y -= @sin(player_angle) * move_speed;
            moved = true;
        }
        if (key_a > 0) {
            player_x += @cos(player_angle - std.math.pi / 2.0) * move_speed;
            player_y += @sin(player_angle - std.math.pi / 2.0) * move_speed;
            moved = true;
        }
        if (key_d > 0) {
            player_x += @cos(player_angle + std.math.pi / 2.0) * move_speed;
            player_y += @sin(player_angle + std.math.pi / 2.0) * move_speed;
            moved = true;
        }
        if (key_q > 0) {
            player_angle -= rot_speed;
            moved = true;
        }
        if (key_e > 0) {
            player_angle += rot_speed;
            moved = true;
        }


        // Inside the main loop, F-key handling:
        if (key_f > 0 and !won) {
            const reach: f32 = 10.0; 
            const hit = castRayDDA(&map, player_x, player_y, player_angle, reach);
            if (hit.hit) {
                const color = map.getWallColor(hit.map_x, hit.map_y);
                const r = (color >> 24) & 0xFF;
                const g = (color >> 16) & 0xFF;
                const b = (color >> 8) & 0xFF;
        
                const idx = @as(usize, @intCast(hit.map_y)) * map.width + @as(usize, @intCast(hit.map_x));
        
                // Green tiles: just break
                if (r < 100 and g > 200 and b < 100) {
                    map.pixels[idx] = 0x000000FF; 
                } 
                // Blue tiles: break and trigger win
                else if (r < 100 and g < 100 and b > 200) {
                    map.pixels[idx] = 0x000000FF; 
                    won = true;
                    running = false;
                    std.debug.print("\nYou win! You broke the blue tile at ({d}, {d})!\n", .{hit.map_x, hit.map_y});
                }
            }
        }



        // Decrement key frame counters
        if (key_w > 0) key_w -= 1;
        if (key_s > 0) key_s -= 1;
        if (key_a > 0) key_a -= 1;
        if (key_d > 0) key_d -= 1;
        if (key_q > 0) key_q -= 1;
        if (key_e > 0) key_e -= 1;
        if (key_f > 0) key_f -= 1;

        
        if (moved and map.isWall(@as(i32, @intFromFloat(player_x)), @as(i32, @intFromFloat(player_y)))) {
            player_x = old_x;
            player_y = old_y;
        }
        
        try render3DScene(&fb, &map, &texture_map, player_x, player_y, player_angle);
        
        frame_count += 1;
        const current_time = std.time.milliTimestamp();
        if (current_time - last_time >= 1000) {
            frame_count = 0;
            last_time = current_time;
        }
        
        std.posix.nanosleep(0, 8_333_333); // ~120 FPS cap
    }
    
    std.debug.print("\nExiting...\n", .{});
}

