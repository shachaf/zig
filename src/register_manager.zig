const std = @import("std");
const math = std.math;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ir = @import("ir.zig");
const Type = @import("type.zig").Type;
const Module = @import("Module.zig");
const LazySrcLoc = Module.LazySrcLoc;

const log = std.log.scoped(.register_manager);

pub fn RegisterManager(
    comptime Function: type,
    comptime Register: type,
    comptime callee_preserved_regs: []const Register,
) type {
    return struct {
        /// The key must be canonical register.
        registers: std.AutoHashMapUnmanaged(Register, *ir.Inst) = .{},
        free_registers: FreeRegInt = math.maxInt(FreeRegInt),
        /// Tracks all registers allocated in the course of this function
        allocated_registers: FreeRegInt = 0,

        const Self = @This();

        /// An integer whose bits represent all the registers and whether they are free.
        const FreeRegInt = std.meta.Int(.unsigned, callee_preserved_regs.len);
        const ShiftInt = math.Log2Int(FreeRegInt);

        fn getFunction(self: *Self) *Function {
            return @fieldParentPtr(Function, "register_manager", self);
        }

        pub fn deinit(self: *Self, allocator: *Allocator) void {
            self.registers.deinit(allocator);
        }

        fn isTracked(reg: Register) bool {
            return reg.allocIndex() != null;
        }

        fn markRegUsed(self: *Self, reg: Register) void {
            if (FreeRegInt == u0) return;
            const index = reg.allocIndex() orelse return;
            const shift = @intCast(ShiftInt, index);
            const mask = @as(FreeRegInt, 1) << shift;
            self.free_registers &= ~mask;
            self.allocated_registers |= mask;
        }

        fn markRegFree(self: *Self, reg: Register) void {
            if (FreeRegInt == u0) return;
            const index = reg.allocIndex() orelse return;
            const shift = @intCast(ShiftInt, index);
            self.free_registers |= @as(FreeRegInt, 1) << shift;
        }

        /// Returns true when this register is not tracked
        pub fn isRegFree(self: Self, reg: Register) bool {
            if (FreeRegInt == u0) return true;
            const index = reg.allocIndex() orelse return true;
            const shift = @intCast(ShiftInt, index);
            return self.free_registers & @as(FreeRegInt, 1) << shift != 0;
        }

        /// Returns whether this register was allocated in the course
        /// of this function.
        /// Returns false when this register is not tracked
        pub fn isRegAllocated(self: Self, reg: Register) bool {
            if (FreeRegInt == u0) return false;
            const index = reg.allocIndex() orelse return false;
            const shift = @intCast(ShiftInt, index);
            return self.allocated_registers & @as(FreeRegInt, 1) << shift != 0;
        }

        /// Before calling, must ensureCapacity + count on self.registers.
        /// Returns `null` if all registers are allocated.
        pub fn tryAllocRegs(self: *Self, comptime count: comptime_int, insts: [count]*ir.Inst) ?[count]Register {
            if (self.tryAllocRegsWithoutTracking(count)) |regs| {
                for (regs) |reg, i| {
                    self.markRegUsed(reg);
                    self.registers.putAssumeCapacityNoClobber(reg, insts[i]);
                }

                return regs;
            } else {
                return null;
            }
        }

        /// Before calling, must ensureCapacity + 1 on self.registers.
        /// Returns `null` if all registers are allocated.
        pub fn tryAllocReg(self: *Self, inst: *ir.Inst) ?Register {
            return if (tryAllocRegs(self, 1, .{inst})) |regs| regs[0] else null;
        }

        /// Before calling, must ensureCapacity + count on self.registers.
        pub fn allocRegs(self: *Self, comptime count: comptime_int, insts: [count]*ir.Inst) ![count]Register {
            comptime assert(count > 0 and count <= callee_preserved_regs.len);

            return self.tryAllocRegs(count, insts) orelse blk: {
                // We'll take over the first count registers. Spill
                // the instructions that were previously there to a
                // stack allocations.
                var regs: [count]Register = undefined;
                std.mem.copy(Register, &regs, callee_preserved_regs[0..count]);

                for (regs) |reg, i| {
                    if (self.isRegFree(reg)) {
                        self.markRegUsed(reg);
                        self.registers.putAssumeCapacityNoClobber(reg, insts[i]);
                    } else {
                        const regs_entry = self.registers.getEntry(reg).?;
                        const spilled_inst = regs_entry.value;
                        regs_entry.value = insts[i];
                        try self.getFunction().spillInstruction(spilled_inst.src, reg, spilled_inst);
                    }
                }

                break :blk regs;
            };
        }

        /// Before calling, must ensureCapacity + 1 on self.registers.
        pub fn allocReg(self: *Self, inst: *ir.Inst) !Register {
            return (try allocRegs(self, 1, .{inst}))[0];
        }

        /// Does not track the registers.
        /// Returns `null` if not enough registers are free.
        pub fn tryAllocRegsWithoutTracking(self: *Self, comptime count: comptime_int) ?[count]Register {
            comptime if (callee_preserved_regs.len == 0) return null;
            comptime assert(count > 0 and count <= callee_preserved_regs.len);

            const free_registers = @popCount(FreeRegInt, self.free_registers);
            if (free_registers < count) return null;

            var regs: [count]Register = undefined;
            var i: usize = 0;
            for (callee_preserved_regs) |reg| {
                if (i >= count) break;
                if (self.isRegFree(reg)) {
                    regs[i] = reg;
                    i += 1;
                }
            }
            return regs;
        }

        /// Does not track the register.
        /// Returns `null` if all registers are allocated.
        pub fn tryAllocRegWithoutTracking(self: *Self) ?Register {
            return if (tryAllocRegsWithoutTracking(self, 1)) |regs| regs[0] else null;
        }

        /// Does not track the register.
        pub fn allocRegWithoutTracking(self: *Self) !Register {
            return self.tryAllocRegWithoutTracking() orelse b: {
                // We'll take over the first register. Move the instruction that was previously
                // there to a stack allocation.
                const reg = callee_preserved_regs[0];
                const regs_entry = self.registers.remove(reg).?;
                const spilled_inst = regs_entry.value;
                try self.getFunction().spillInstruction(spilled_inst.src, reg, spilled_inst);
                self.markRegFree(reg);

                break :b reg;
            };
        }

        /// Allocates the specified register with the specified
        /// instruction. Spills the register if it is currently
        /// allocated.
        /// Before calling, must ensureCapacity + 1 on self.registers.
        pub fn getReg(self: *Self, reg: Register, inst: *ir.Inst) !void {
            if (!isTracked(reg)) return;

            if (!self.isRegFree(reg)) {
                // Move the instruction that was previously there to a
                // stack allocation.
                const regs_entry = self.registers.getEntry(reg).?;
                const spilled_inst = regs_entry.value;
                regs_entry.value = inst;
                try self.getFunction().spillInstruction(spilled_inst.src, reg, spilled_inst);
            } else {
                self.getRegAssumeFree(reg, inst);
            }
        }

        /// Spills the register if it is currently allocated.
        /// Does not track the register.
        pub fn getRegWithoutTracking(self: *Self, reg: Register) !void {
            if (!isTracked(reg)) return;

            if (!self.isRegFree(reg)) {
                // Move the instruction that was previously there to a
                // stack allocation.
                const regs_entry = self.registers.remove(reg).?;
                const spilled_inst = regs_entry.value;
                try self.getFunction().spillInstruction(spilled_inst.src, reg, spilled_inst);
                self.markRegFree(reg);
            }
        }

        /// Allocates the specified register with the specified
        /// instruction. Assumes that the register is free and no
        /// spilling is necessary.
        /// Before calling, must ensureCapacity + 1 on self.registers.
        pub fn getRegAssumeFree(self: *Self, reg: Register, inst: *ir.Inst) void {
            if (!isTracked(reg)) return;

            self.registers.putAssumeCapacityNoClobber(reg, inst);
            self.markRegUsed(reg);
        }

        /// Marks the specified register as free
        pub fn freeReg(self: *Self, reg: Register) void {
            if (!isTracked(reg)) return;

            _ = self.registers.remove(reg);
            self.markRegFree(reg);
        }
    };
}

const MockRegister = enum(u2) {
    r0,
    r1,
    r2,
    r3,

    pub fn allocIndex(self: MockRegister) ?u2 {
        inline for (mock_callee_preserved_regs) |cpreg, i| {
            if (self == cpreg) return i;
        }
        return null;
    }
};

const mock_callee_preserved_regs = [_]MockRegister{ .r2, .r3 };

const MockFunction = struct {
    allocator: *Allocator,
    register_manager: RegisterManager(Self, MockRegister, &mock_callee_preserved_regs) = .{},
    spilled: std.ArrayListUnmanaged(MockRegister) = .{},

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.register_manager.deinit(self.allocator);
        self.spilled.deinit(self.allocator);
    }

    pub fn spillInstruction(self: *Self, src: LazySrcLoc, reg: MockRegister, inst: *ir.Inst) !void {
        try self.spilled.append(self.allocator, reg);
    }
};

test "tryAllocReg: no spilling" {
    const allocator = std.testing.allocator;

    var function = MockFunction{
        .allocator = allocator,
    };
    defer function.deinit();

    var mock_instruction = ir.Inst{
        .tag = .breakpoint,
        .ty = Type.initTag(.void),
        .src = .unneeded,
    };

    std.testing.expect(!function.register_manager.isRegAllocated(.r2));
    std.testing.expect(!function.register_manager.isRegAllocated(.r3));

    try function.register_manager.registers.ensureCapacity(allocator, function.register_manager.registers.count() + 2);
    std.testing.expectEqual(@as(?MockRegister, .r2), function.register_manager.tryAllocReg(&mock_instruction));
    std.testing.expectEqual(@as(?MockRegister, .r3), function.register_manager.tryAllocReg(&mock_instruction));
    std.testing.expectEqual(@as(?MockRegister, null), function.register_manager.tryAllocReg(&mock_instruction));

    std.testing.expect(function.register_manager.isRegAllocated(.r2));
    std.testing.expect(function.register_manager.isRegAllocated(.r3));

    function.register_manager.freeReg(.r2);
    function.register_manager.freeReg(.r3);

    std.testing.expect(function.register_manager.isRegAllocated(.r2));
    std.testing.expect(function.register_manager.isRegAllocated(.r3));
}

test "allocReg: spilling" {
    const allocator = std.testing.allocator;

    var function = MockFunction{
        .allocator = allocator,
    };
    defer function.deinit();

    var mock_instruction = ir.Inst{
        .tag = .breakpoint,
        .ty = Type.initTag(.void),
        .src = .unneeded,
    };

    std.testing.expect(!function.register_manager.isRegAllocated(.r2));
    std.testing.expect(!function.register_manager.isRegAllocated(.r3));

    try function.register_manager.registers.ensureCapacity(allocator, function.register_manager.registers.count() + 2);
    std.testing.expectEqual(@as(?MockRegister, .r2), try function.register_manager.allocReg(&mock_instruction));
    std.testing.expectEqual(@as(?MockRegister, .r3), try function.register_manager.allocReg(&mock_instruction));

    // Spill a register
    std.testing.expectEqual(@as(?MockRegister, .r2), try function.register_manager.allocReg(&mock_instruction));
    std.testing.expectEqualSlices(MockRegister, &[_]MockRegister{.r2}, function.spilled.items);

    // No spilling necessary
    function.register_manager.freeReg(.r3);
    std.testing.expectEqual(@as(?MockRegister, .r3), try function.register_manager.allocReg(&mock_instruction));
    std.testing.expectEqualSlices(MockRegister, &[_]MockRegister{.r2}, function.spilled.items);
}

test "getReg" {
    const allocator = std.testing.allocator;

    var function = MockFunction{
        .allocator = allocator,
    };
    defer function.deinit();

    var mock_instruction = ir.Inst{
        .tag = .breakpoint,
        .ty = Type.initTag(.void),
        .src = .unneeded,
    };

    std.testing.expect(!function.register_manager.isRegAllocated(.r2));
    std.testing.expect(!function.register_manager.isRegAllocated(.r3));

    try function.register_manager.registers.ensureCapacity(allocator, function.register_manager.registers.count() + 2);
    try function.register_manager.getReg(.r3, &mock_instruction);

    std.testing.expect(!function.register_manager.isRegAllocated(.r2));
    std.testing.expect(function.register_manager.isRegAllocated(.r3));

    // Spill r3
    try function.register_manager.registers.ensureCapacity(allocator, function.register_manager.registers.count() + 2);
    try function.register_manager.getReg(.r3, &mock_instruction);

    std.testing.expect(!function.register_manager.isRegAllocated(.r2));
    std.testing.expect(function.register_manager.isRegAllocated(.r3));
    std.testing.expectEqualSlices(MockRegister, &[_]MockRegister{.r3}, function.spilled.items);
}
