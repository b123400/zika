const std = @import("std");
const mqtt = @import("mqtt.zig");
const driver = @import("driver.zig");
const config = @import("config.zig");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Ip4Address = std.net.Ip4Address;
const Base64UrlEncoder = std.base64.url_safe_no_pad.Encoder;
const Config = config.Config;
const NetInterface = driver.NetInterface;
const IpHeader = driver.IpHeader;
const Mqtt = mqtt.Mqtt;

pub fn Tunnel(comptime T: type) type {
    return struct {
        const Self = @This();
        const Conf = config.ClientTunnel;

        conf: Conf,
        bind_addr: u32,
        id: []u8,
        up_topic_cstr: []u8,
        dn_topic_cstr: []u8,
        
        ifce: *NetInterface(T),
        mqtt: *Mqtt(T),

        pub fn create(alloc: *Allocator, ifce: *NetInterface(T), broker: *Mqtt(T), conf: Conf) !*Self {
            const self = try alloc.create(Self);
            self.conf = conf;
            self.ifce = ifce;
            self.mqtt = broker;
            self.id = try alloc.alloc(u8, conf.id_length);
            self.bind_addr = (try Ip4Address.parse(conf.bind_addr, 0)).sa.addr;

            std.crypto.random.bytes(self.id);
            const b64_len = Base64UrlEncoder.calcSize(conf.id_length);
            const b64_id = try alloc.alloc(u8, b64_len);
            _ = Base64UrlEncoder.encode(b64_id, self.id);

            const up_topic = try std.fmt.allocPrint(alloc, "{s}/{s}", .{conf.topic, b64_id});
            self.up_topic_cstr = try std.cstr.addNullByte(alloc, up_topic);
            self.dn_topic_cstr = try std.cstr.addNullByte(alloc, conf.topic);
            try self.mqtt.subscribe(self.dn_topic_cstr);

            std.log.info("Tunnel: {s} -> {s} ({s})", .{conf.bind_addr, conf.topic, b64_id});
            return self;
        }

        pub fn up(self: *Self, pkt: []u8) !bool {
            const hdr = @ptrCast(*IpHeader, pkt);
            if(hdr.dst != self.bind_addr) return false;
            try self.mqtt.send(self.up_topic_cstr, pkt);
            return true;
        }

        pub fn down(self: *Self, msg: []u8) !bool {
            const id = msg[0..self.conf.id_length];
            if(!std.mem.eql(u8, self.id, id)) return false;
            try self.ifce.inject(self.bind_addr, msg[id.len..]);
            return true;
        }
    };
}

pub const Client = struct {
    const Self = @This();
    const Error = error {
        ConfigMissing
    };
    
    arena: ArenaAllocator,
    ifce: ?*NetInterface(*Self),
    mqtt: ?*Mqtt(*Self),
    tunnels: []*Tunnel(*Self),

    pub fn init(alloc: *Allocator, conf: * const Config) !*Self {
        const client_conf = conf.client orelse {
            std.log.err("missing client config", .{});
            return Error.ConfigMissing;
        };

        var arena = ArenaAllocator.init(alloc);
        const self = try arena.allocator.create(Self);
        self.arena = arena;
        errdefer self.deinit();

        std.log.info("== Client Config =================================", .{});
        self.ifce = try NetInterface(*Self).init(&arena.allocator, conf, self, @ptrCast(driver.PacketHandler(*Self), &up));
        self.mqtt = try Mqtt(*Self).init(&arena.allocator, conf, self, @ptrCast(mqtt.PacketHandler(*Self), &down));
        self.tunnels = try alloc.alloc(*Tunnel(*Self), client_conf.tunnels.len);
        for (client_conf.tunnels) |tunnel, idx| {
            self.tunnels[idx] = try Tunnel(*Self).create(
                &arena.allocator,
                self.ifce orelse unreachable,
                self.mqtt orelse unreachable,
                .{
                    .id_length = tunnel.id_length,
                    .topic = tunnel.topic,
                    .bind_addr = tunnel.bind_addr,
                }
            );
        }
        std.log.info("==================================================", .{});

        return self;
    }

    pub fn deinit(self: *Self) void {
        if(self.mqtt) |m| m.deinit();
        if(self.ifce) |i| i.deinit();
        self.arena.deinit();
    }

    pub fn run(self: *Self) !void {
        if(self.mqtt) |m| try m.connect();
        if(self.ifce) |i| try i.run();
    }

    fn up(self: *Self, pkt: []u8) void {
        for (self.tunnels) |tunnel| {
            const handled = tunnel.up(pkt) catch |err| blk: {
                std.log.warn("up: {s}", .{err});
                break :blk false;
            };
            if(handled) break;
        }
    }

    fn down(self: *Self, pkt: []u8) void {
        for (self.tunnels) |tunnel| {
            const handled = tunnel.down(pkt) catch |err| blk: {
                std.log.warn("down: {s}", .{err});
                break :blk false;
            };
            if(handled) break;
        }
    }

};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = &gpa.allocator;
    const conf_path = try std.fs.cwd().realpathAlloc(alloc, "zika_config.json");
    const conf = try config.get(alloc, conf_path);
    const client = try Client.init(alloc, &conf);
    try client.run();
}
