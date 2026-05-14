const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn BoundedQueue(comptime T: type) type {
	return struct {
		const Self = @This();

		items: []T,
		allocator: Allocator,
		io: std.Io,
		mutex: std.Io.Mutex,
		not_empty: std.Io.Condition,
		not_full: std.Io.Condition,
		capacity: usize,
		closed: bool,
		head: usize,
		tail: usize,
		count: usize,

		pub fn init(allocator: Allocator, io: std.Io, capacity: usize) !Self {
			const cap = @max(@as(usize, 1), capacity);
			const items = try allocator.alloc(T, cap);
			return .{
				.items = items,
				.allocator = allocator,
				.io = io,
				.mutex = .init,
				.not_empty = .init,
				.not_full = .init,
				.capacity = cap,
				.closed = false,
				.head = 0,
				.tail = 0,
				.count = 0,
			};
		}

		pub fn deinit(self: *Self) void {
			self.allocator.free(self.items);
		}

		pub fn enqueue(self: *Self, item: T) bool {
			self.mutex.lockUncancelable(self.io);
			defer self.mutex.unlock(self.io);

			while (self.count >= self.capacity and !self.closed) {
				self.not_full.waitUncancelable(self.io, &self.mutex);
			}

			if (self.closed) {
				return false;
			}

			self.items[self.tail] = item;
			self.tail = (self.tail + 1) % self.capacity;
			self.count += 1;

			self.not_empty.signal(self.io);
			return true;
		}

		pub fn dequeue(self: *Self) ?T {
			self.mutex.lockUncancelable(self.io);
			defer self.mutex.unlock(self.io);

			while (self.count == 0 and !self.closed) {
				self.not_empty.waitUncancelable(self.io, &self.mutex);
			}

			if (self.count == 0) {
				return null;
			}

			const item = self.items[self.head];
			self.head = (self.head + 1) % self.capacity;
			self.count -= 1;

			self.not_full.signal(self.io);
			return item;
		}

		pub fn tryDequeue(self: *Self) ?T {
			self.mutex.lockUncancelable(self.io);
			defer self.mutex.unlock(self.io);

			if (self.count == 0) {
				return null;
			}

			const item = self.items[self.head];
			self.head = (self.head + 1) % self.capacity;
			self.count -= 1;

			self.not_full.signal(self.io);
			return item;
		}

		pub fn close(self: *Self) void {
			self.mutex.lockUncancelable(self.io);
			defer self.mutex.unlock(self.io);

			self.closed = true;
			self.not_empty.broadcast(self.io);
			self.not_full.broadcast(self.io);
		}

		pub fn isClosed(self: *Self) bool {
			self.mutex.lockUncancelable(self.io);
			defer self.mutex.unlock(self.io);
			return self.closed;
		}

		pub fn len(self: *Self) usize {
			self.mutex.lockUncancelable(self.io);
			defer self.mutex.unlock(self.io);
			return self.count;
		}
	};
}
